using System.Data;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using ClosedXML.Excel;
using ControlManagement.Api.Models;
using Microsoft.Data.SqlClient;

namespace ControlManagement.Api.Services;

// -----------------------------------------------------------------------------
// Bulk upload orchestrator.
//   * BuildTemplate      -> multi-sheet .xlsx with instructions + headers.
//   * ValidateAsync      -> parse + validate against schema and existing DB.
//                           Never touches the database beyond reads.
//   * CommitAsync        -> validate again, then INSERT every row inside a
//                           single SqlTransaction.  Any failure rolls the
//                           whole workbook back so we never leave a partial
//                           upload behind.  This is the "all-or-nothing"
//                           guarantee the user asked for.
//
// The insert path deliberately bypasses dbo.cm_manage_repository so that a
// large upload does not spawn hundreds of maker-checker change requests.  It
// writes directly to the same tables with status='Active' and the current
// admin as entered_by, which matches how a fully-approved single-record add
// eventually lands in the master tables.
// -----------------------------------------------------------------------------

public interface IBulkUploadService
{
    byte[] BuildTemplate();
    Task<BulkUploadReport> ValidateAsync(Stream workbook, CancellationToken cancellationToken);
    Task<BulkUploadReport> CommitAsync(Stream workbook, string enteredBy, CancellationToken cancellationToken);
    byte[] BuildErrorReport(IEnumerable<BulkUploadIssue> issues);
}

public sealed class BulkUploadService(IConfiguration configuration, ILogger<BulkUploadService> logger) : IBulkUploadService
{
    // ----------------------- Template generation -----------------------------
    public byte[] BuildTemplate()
    {
        using var workbook = new XLWorkbook();

        var readme = workbook.Worksheets.Add("README");
        readme.Cell(1, 1).Value = "GRAC Control Management — Bulk Upload Template";
        readme.Cell(1, 1).Style.Font.Bold = true;
        readme.Cell(1, 1).Style.Font.FontSize = 14;
        readme.Cell(3, 1).Value = "Fill only the sheets you want to upload. Empty sheets are ignored.";
        readme.Cell(4, 1).Value = "Do not rename sheets, add/remove/reorder columns, or edit the header row.";
        readme.Cell(5, 1).Value = "Dates must be in YYYY-MM-DD format. Boolean columns accept true/false/1/0.";
        readme.Cell(6, 1).Value = "Foreign-key columns (authorityCode, artifactCode, versionNo, etc.) must match either an existing active record OR another row inside the same workbook.";
        readme.Cell(7, 1).Value = "Uploads are all-or-nothing: if any row fails validation, the entire workbook is rejected and nothing is inserted.";
        readme.Cell(9, 1).Value = "Sheets in this template:";
        readme.Cell(9, 1).Style.Font.Bold = true;

        var row = 10;
        foreach (var sheet in BulkUploadSchema.Sheets)
        {
            readme.Cell(row, 1).Value = sheet.SheetName;
            readme.Cell(row, 2).Value = sheet.TableLabel;
            readme.Cell(row, 3).Value = sheet.Instructions;
            row++;
        }
        readme.Columns().AdjustToContents();

        foreach (var sheet in BulkUploadSchema.Sheets)
        {
            var ws = workbook.Worksheets.Add(sheet.SheetName);
            // Row 1: sheet-level instructions banner.
            ws.Cell(1, 1).Value = sheet.Instructions;
            ws.Cell(1, 1).Style.Font.Italic = true;
            ws.Range(1, 1, 1, Math.Max(1, sheet.Columns.Length)).Merge();
            ws.Row(1).Style.Fill.BackgroundColor = XLColor.LightYellow;

            // Row 2: column headers.
            for (var c = 0; c < sheet.Columns.Length; c++)
            {
                var col = sheet.Columns[c];
                var cell = ws.Cell(2, c + 1);
                cell.Value = col.Header + (col.Required ? " *" : "");
                cell.Style.Font.Bold = true;
                cell.Style.Fill.BackgroundColor = col.Required ? XLColor.LightBlue : XLColor.LightGray;
                if (!string.IsNullOrWhiteSpace(col.Help)) cell.GetComment().AddText(col.Help);
            }

            // Row 3: helper hint per column so first-time users know the type.
            for (var c = 0; c < sheet.Columns.Length; c++)
            {
                var col = sheet.Columns[c];
                var hint = col.Type switch
                {
                    BulkColumnType.Integer => "(integer)",
                    BulkColumnType.Decimal => "(number)",
                    BulkColumnType.Date    => "(YYYY-MM-DD)",
                    BulkColumnType.Boolean => "(true/false)",
                    _                       => col.MaxLength > 0 ? $"(text, max {col.MaxLength})" : "(text)"
                };
                ws.Cell(3, c + 1).Value = hint;
                ws.Cell(3, c + 1).Style.Font.Italic = true;
                ws.Cell(3, c + 1).Style.Font.FontColor = XLColor.Gray;
            }

            ws.Row(1).Height = 32;
            ws.SheetView.FreezeRows(3);
            ws.Columns(1, sheet.Columns.Length).Width = 24;
        }

        using var ms = new MemoryStream();
        workbook.SaveAs(ms);
        return ms.ToArray();
    }

    // ----------------------- Error report workbook ---------------------------
    public byte[] BuildErrorReport(IEnumerable<BulkUploadIssue> issues)
    {
        using var workbook = new XLWorkbook();
        var ws = workbook.Worksheets.Add("Errors");
        ws.Cell(1, 1).Value = "Sheet";
        ws.Cell(1, 2).Value = "Row";
        ws.Cell(1, 3).Value = "Column";
        ws.Cell(1, 4).Value = "Message";
        ws.Range(1, 1, 1, 4).Style.Font.Bold = true;
        ws.Range(1, 1, 1, 4).Style.Fill.BackgroundColor = XLColor.LightSalmon;
        var r = 2;
        foreach (var issue in issues)
        {
            ws.Cell(r, 1).Value = issue.Sheet;
            ws.Cell(r, 2).Value = issue.Row;
            ws.Cell(r, 3).Value = issue.Column;
            ws.Cell(r, 4).Value = issue.Message;
            r++;
        }
        ws.Columns().AdjustToContents();
        using var ms = new MemoryStream();
        workbook.SaveAs(ms);
        return ms.ToArray();
    }

    // ----------------------- Validate only -----------------------------------
    public async Task<BulkUploadReport> ValidateAsync(Stream workbook, CancellationToken cancellationToken)
    {
        var (parsed, report) = ParseWorkbook(workbook);
        if (report.Issues.Count > 0)
        {
            report.Success = false;
            report.Message = "The uploaded workbook has structural issues — see the error report.";
            return report;
        }

        await using var connection = OpenConnection();
        await connection.OpenAsync(cancellationToken);
        var lookups = await LoadLookupsAsync(connection, null, cancellationToken);
        ValidateAllSheets(parsed, lookups, report);

        report.Success = report.Issues.Count == 0;
        report.Message = report.Success
            ? "Validation passed. Ready to commit."
            : $"Validation failed with {report.Issues.Count} issue(s). No data will be inserted.";
        return report;
    }

    // ----------------------- Validate + commit -------------------------------
    public async Task<BulkUploadReport> CommitAsync(Stream workbook, string enteredBy, CancellationToken cancellationToken)
    {
        var (parsed, report) = ParseWorkbook(workbook);
        if (report.Issues.Count > 0)
        {
            report.Success = false;
            report.Message = "The uploaded workbook has structural issues — see the error report.";
            return report;
        }

        await using var connection = OpenConnection();
        await connection.OpenAsync(cancellationToken);
        var lookups = await LoadLookupsAsync(connection, null, cancellationToken);
        ValidateAllSheets(parsed, lookups, report);
        if (report.Issues.Count > 0)
        {
            report.Success = false;
            report.Message = $"Validation failed with {report.Issues.Count} issue(s). No data was inserted.";
            return report;
        }

        // All-or-nothing: single serializable-safe transaction across every
        // sheet.  Any failure -> rollback everything.
        await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, cancellationToken);
        try
        {
            var counts = await InsertAllAsync(connection, transaction, parsed, lookups, enteredBy, cancellationToken);
            await transaction.CommitAsync(cancellationToken);
            report.InsertedCounts = counts;
            report.Success = true;
            report.Message = $"Upload committed. Inserted {counts.Values.Sum()} record(s) across {counts.Count} table(s).";
            return report;
        }
        catch (Exception ex)
        {
            try { await transaction.RollbackAsync(cancellationToken); } catch { /* swallowed — surfaced via original ex */ }
            logger.LogError(ex, "Bulk upload commit rolled back for user {EnteredBy}", enteredBy);
            report.Success = false;
            report.Message = $"Upload rolled back: {ex.Message}. No data was inserted.";
            report.Issues.Add(new BulkUploadIssue { Sheet = "(commit)", Row = 0, Column = "", Message = ex.Message });
            return report;
        }
    }

    // ==========================================================================
    // Parsing
    // ==========================================================================
    private static (Dictionary<string, List<Dictionary<string, string?>>> Parsed, BulkUploadReport Report) ParseWorkbook(Stream stream)
    {
        var report = new BulkUploadReport();
        var parsed = new Dictionary<string, List<Dictionary<string, string?>>>(StringComparer.OrdinalIgnoreCase);
        XLWorkbook workbook;
        try
        {
            workbook = new XLWorkbook(stream);
        }
        catch (Exception ex)
        {
            report.Issues.Add(new BulkUploadIssue { Sheet = "(workbook)", Row = 0, Column = "", Message = "Unable to open the uploaded file. Please upload the exact template. Detail: " + ex.Message });
            return (parsed, report);
        }

        using (workbook)
        {
            foreach (var sheet in BulkUploadSchema.Sheets)
            {
                if (!workbook.Worksheets.TryGetWorksheet(sheet.SheetName, out var ws))
                {
                    report.Issues.Add(new BulkUploadIssue { Sheet = sheet.SheetName, Row = 0, Column = "", Message = $"Sheet '{sheet.SheetName}' is missing. Use the latest template." });
                    continue;
                }
                var rows = new List<Dictionary<string, string?>>();
                var used = ws.RangeUsed();
                if (used is null) { parsed[sheet.SheetName] = rows; continue; }

                // Header row is row 2 in the template.  Row 1 is banner, row 3 is
                // helper hint.  Data starts at row 4.
                var headerRow = ws.Row(2);
                var lastHeaderCol = headerRow.LastCellUsed()?.Address.ColumnNumber ?? sheet.Columns.Length;
                var headerMap = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
                foreach (var col in sheet.Columns)
                {
                    var colIndex = -1;
                    for (var c = 1; c <= lastHeaderCol; c++)
                    {
                        var text = (headerRow.Cell(c).GetString() ?? "").Trim().TrimEnd('*').Trim();
                        if (text.Equals(col.Header, StringComparison.OrdinalIgnoreCase)) { colIndex = c; break; }
                    }
                    if (colIndex < 0)
                    {
                        report.Issues.Add(new BulkUploadIssue { Sheet = sheet.SheetName, Row = 2, Column = col.Header, Message = $"Column '{col.Header}' is missing from the header row." });
                    }
                    else
                    {
                        headerMap[col.PropertyName] = colIndex;
                    }
                }
                if (report.Issues.Any(i => i.Sheet == sheet.SheetName)) { parsed[sheet.SheetName] = rows; continue; }

                var lastRow = ws.LastRowUsed()?.RowNumber() ?? 0;
                for (var r = 4; r <= lastRow; r++)
                {
                    var record = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
                    var hasAny = false;
                    foreach (var col in sheet.Columns)
                    {
                        var cell = ws.Cell(r, headerMap[col.PropertyName]);
                        var raw = ReadCell(cell, col.Type);
                        if (!string.IsNullOrWhiteSpace(raw)) hasAny = true;
                        record[col.PropertyName] = raw;
                    }
                    record["__row"] = r.ToString(CultureInfo.InvariantCulture);
                    if (hasAny) rows.Add(record);
                }
                parsed[sheet.SheetName] = rows;
                report.Sheets.Add(new BulkSheetSummary { SheetName = sheet.SheetName, TableLabel = sheet.TableLabel, TotalRows = rows.Count });
            }
        }
        return (parsed, report);
    }

    private static string? ReadCell(IXLCell cell, BulkColumnType type)
    {
        if (cell.IsEmpty()) return null;
        try
        {
            return type switch
            {
                BulkColumnType.Date when cell.DataType == XLDataType.DateTime => cell.GetDateTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                BulkColumnType.Integer when cell.DataType == XLDataType.Number => ((long)cell.GetDouble()).ToString(CultureInfo.InvariantCulture),
                BulkColumnType.Decimal when cell.DataType == XLDataType.Number => cell.GetDouble().ToString(CultureInfo.InvariantCulture),
                _ => cell.GetString()?.Trim()
            };
        }
        catch { return cell.GetString()?.Trim(); }
    }

    // ==========================================================================
    // Validation — pure in-memory, using pre-loaded DB lookups.
    // ==========================================================================
    private void ValidateAllSheets(Dictionary<string, List<Dictionary<string, string?>>> parsed, DbLookups lookups, BulkUploadReport report)
    {
        // Prime new-record maps from the workbook itself so a row referring to
        // another new row in the same file resolves correctly.
        foreach (var row in parsed.GetValueOrDefault("Authority") ?? new()) lookups.NewAuthorityCodes.Add((row["authorityCode"] ?? "").Trim());
        foreach (var row in parsed.GetValueOrDefault("Artifact") ?? new()) lookups.NewArtifactCodes.Add((row["artifactCode"] ?? "").Trim());
        foreach (var row in parsed.GetValueOrDefault("Release") ?? new()) lookups.NewReleaseKeys.Add(BuildReleaseKey(row["artifactCode"], row["versionNo"]));
        foreach (var row in parsed.GetValueOrDefault("SourceStructure") ?? new())
            lookups.NewNodeKeys.Add(BuildNodeKey(row["artifactCode"], row["versionNo"], row["nodeReference"]));
        foreach (var row in parsed.GetValueOrDefault("SourceStatement") ?? new())
            lookups.NewStatementKeys.Add(BuildStatementKey(row["artifactCode"], row["versionNo"], row["statementReference"]));
        foreach (var row in parsed.GetValueOrDefault("Practice") ?? new())
            lookups.NewRequirementCodes.Add((row["requirementCode"] ?? "").Trim());
        // Obligation Master is now a global entity — count the name occurrences
        // so we can flag ambiguous references from Mapping / Evidence sheets.
        foreach (var row in parsed.GetValueOrDefault("Obligation") ?? new())
        {
            var name = (row["obligationName"] ?? "").Trim();
            if (!string.IsNullOrEmpty(name))
                lookups.NewObligationNameCounts[name] = lookups.NewObligationNameCounts.GetValueOrDefault(name, 0) + 1;
        }

        foreach (var sheet in BulkUploadSchema.Sheets)
        {
            if (!parsed.TryGetValue(sheet.SheetName, out var rows) || rows.Count == 0)
            {
                var s = report.Sheets.FirstOrDefault(x => x.SheetName == sheet.SheetName);
                if (s is not null) { s.ValidRows = 0; s.InvalidRows = 0; }
                continue;
            }
            // Track sheet-level duplicates within the same file.
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var valid = 0;
            var invalid = 0;

            foreach (var row in rows)
            {
                var rowNumber = int.Parse(row["__row"]!, CultureInfo.InvariantCulture);
                var before = report.Issues.Count;

                // Column-level checks (required, length, type).
                foreach (var col in sheet.Columns)
                {
                    var value = row[col.PropertyName];
                    if (col.Required && string.IsNullOrWhiteSpace(value))
                    {
                        report.Issues.Add(new BulkUploadIssue { Sheet = sheet.SheetName, Row = rowNumber, Column = col.Header, Message = "Required value is missing." });
                        continue;
                    }
                    if (string.IsNullOrWhiteSpace(value)) continue;
                    if (col.MaxLength > 0 && value!.Length > col.MaxLength)
                        report.Issues.Add(new BulkUploadIssue { Sheet = sheet.SheetName, Row = rowNumber, Column = col.Header, Message = $"Value exceeds maximum length of {col.MaxLength} characters." });
                    if (col.Type == BulkColumnType.Integer && !long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out _))
                        report.Issues.Add(new BulkUploadIssue { Sheet = sheet.SheetName, Row = rowNumber, Column = col.Header, Message = "Expected a whole number." });
                    if (col.Type == BulkColumnType.Decimal && !double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out _))
                        report.Issues.Add(new BulkUploadIssue { Sheet = sheet.SheetName, Row = rowNumber, Column = col.Header, Message = "Expected a number." });
                    if (col.Type == BulkColumnType.Date && !DateTime.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out _))
                        report.Issues.Add(new BulkUploadIssue { Sheet = sheet.SheetName, Row = rowNumber, Column = col.Header, Message = "Expected a date in YYYY-MM-DD format." });
                }

                // Sheet-specific referential / uniqueness checks.
                ValidateReferences(sheet, row, rowNumber, lookups, seen, report);

                if (report.Issues.Count == before) valid++; else invalid++;
            }

            var summary = report.Sheets.FirstOrDefault(x => x.SheetName == sheet.SheetName);
            if (summary is not null) { summary.ValidRows = valid; summary.InvalidRows = invalid; }
        }
    }

    private static void ValidateReferences(BulkSheet sheet, Dictionary<string, string?> row, int rowNumber, DbLookups lookups, HashSet<string> seen, BulkUploadReport report)
    {
        void Add(string col, string message) => report.Issues.Add(new BulkUploadIssue { Sheet = sheet.SheetName, Row = rowNumber, Column = col, Message = message });
        string? V(string k) => row.TryGetValue(k, out var v) ? v?.Trim() : null;

        switch (sheet.SheetName)
        {
            case "Authority":
                {
                    var code = V("authorityCode") ?? "";
                    if (!seen.Add(code)) Add("authorityCode", "Duplicate authorityCode within this sheet.");
                    if (lookups.ExistingAuthorityCodes.Contains(code)) Add("authorityCode", "authorityCode already exists in the database.");
                    break;
                }
            case "Artifact":
                {
                    var code = V("artifactCode") ?? "";
                    if (!seen.Add(code)) Add("artifactCode", "Duplicate artifactCode within this sheet.");
                    if (lookups.ExistingArtifactCodes.Contains(code)) Add("artifactCode", "artifactCode already exists in the database.");
                    var auth = V("authorityCode") ?? "";
                    if (!lookups.ExistingAuthorityCodes.Contains(auth) && !lookups.NewAuthorityCodes.Contains(auth))
                        Add("authorityCode", $"authorityCode '{auth}' is not defined in the Authority sheet or in the database.");
                    break;
                }
            case "Release":
                {
                    var key = BuildReleaseKey(V("artifactCode"), V("versionNo"));
                    if (!seen.Add(key)) Add("versionNo", "Duplicate (artifactCode, versionNo) within this sheet.");
                    if (lookups.ExistingReleaseKeys.Contains(key)) Add("versionNo", "This (artifactCode, versionNo) already exists in the database.");
                    var art = V("artifactCode") ?? "";
                    if (!lookups.ExistingArtifactCodes.Contains(art) && !lookups.NewArtifactCodes.Contains(art))
                        Add("artifactCode", $"artifactCode '{art}' is not defined in the Artifact sheet or in the database.");
                    break;
                }
            case "SourceStructure":
                {
                    var releaseKey = BuildReleaseKey(V("artifactCode"), V("versionNo"));
                    if (!lookups.ExistingReleaseKeys.Contains(releaseKey) && !lookups.NewReleaseKeys.Contains(releaseKey))
                        Add("versionNo", "Release is not defined in the Release sheet or in the database.");
                    var nodeKey = BuildNodeKey(V("artifactCode"), V("versionNo"), V("nodeReference"));
                    if (!seen.Add(nodeKey)) Add("nodeReference", "Duplicate nodeReference within the same release.");
                    if (lookups.ExistingNodeKeys.Contains(nodeKey)) Add("nodeReference", "nodeReference already exists in this release.");
                    var parent = V("parentNodeReference");
                    if (!string.IsNullOrWhiteSpace(parent))
                    {
                        var parentKey = BuildNodeKey(V("artifactCode"), V("versionNo"), parent);
                        if (!lookups.ExistingNodeKeys.Contains(parentKey) && !lookups.NewNodeKeys.Contains(parentKey))
                            Add("parentNodeReference", $"parentNodeReference '{parent}' must exist in the same release (in this file or the database).");
                    }
                    break;
                }
            case "SourceStatement":
                {
                    var releaseKey = BuildReleaseKey(V("artifactCode"), V("versionNo"));
                    if (!lookups.ExistingReleaseKeys.Contains(releaseKey) && !lookups.NewReleaseKeys.Contains(releaseKey))
                        Add("versionNo", "Release is not defined in the Release sheet or in the database.");
                    var nodeKey = BuildNodeKey(V("artifactCode"), V("versionNo"), V("structureNodeReference"));
                    if (!lookups.ExistingNodeKeys.Contains(nodeKey) && !lookups.NewNodeKeys.Contains(nodeKey))
                        Add("structureNodeReference", "structureNodeReference must exist in the same release (SourceStructure sheet or database).");
                    var stmtKey = BuildStatementKey(V("artifactCode"), V("versionNo"), V("statementReference"));
                    if (!seen.Add(stmtKey)) Add("statementReference", "Duplicate statementReference within this release.");
                    if (lookups.ExistingStatementKeys.Contains(stmtKey)) Add("statementReference", "statementReference already exists in this release.");
                    var classification = V("classificationCode");
                    if (!string.IsNullOrWhiteSpace(classification))
                    {
                        var classKey = BuildReleaseKey(V("artifactCode"), V("versionNo")) + "||" + classification;
                        if (!lookups.ExistingClassificationKeys.Contains(classKey))
                            Add("classificationCode", $"classificationCode '{classification}' is not an active classification in this release.");
                    }
                    break;
                }
            case "Practice":
                {
                    var code = V("requirementCode") ?? "";
                    if (!seen.Add(code)) Add("requirementCode", "Duplicate requirementCode within this sheet.");
                    if (lookups.ExistingRequirementCodes.ContainsKey(code))
                        Add("requirementCode", "requirementCode already exists in the database.");
                    break;
                }
            case "Obligation":
                {
                    // Uniqueness check on obligationName within-file only.  The
                    // DB has no unique constraint on obligation_name, so a
                    // name-collision with an existing DB obligation is not an
                    // insert error — but it will make Mapping/Evidence lookups
                    // ambiguous.  We warn (not fail) via ambiguity detection
                    // in the referencing sheets.
                    var name = V("obligationName") ?? "";
                    if (!seen.Add(name)) Add("obligationName", "Duplicate obligationName within this sheet. Rename one of them or Mapping/Evidence references will be ambiguous.");
                    var freq = V("executionFrequencyCode");
                    if (!string.IsNullOrWhiteSpace(freq) && !lookups.FrequencyIdByKey.ContainsKey(freq!))
                        Add("executionFrequencyCode", $"executionFrequencyCode '{freq}' is not an active option in reference_option (option_group='frequency-types').");
                    break;
                }
            case "ObligationEvidence":
                {
                    var name = V("obligationName") ?? "";
                    var (found, ambiguous) = ResolveObligationRef(name, lookups);
                    if (!found) Add("obligationName", $"obligationName '{name}' does not match an obligation in this workbook or the database.");
                    else if (ambiguous) Add("obligationName", $"obligationName '{name}' is ambiguous — more than one active obligation shares this name. Rename the duplicates before uploading.");
                    var evCode = V("evidenceTypeCode") ?? "";
                    if (!lookups.EvidenceTypeIdByCode.ContainsKey(evCode))
                        Add("evidenceTypeCode", $"evidenceTypeCode '{evCode}' does not match an evidence_type_master row.");
                    var freq = V("assuranceFrequencyCode");
                    if (!string.IsNullOrWhiteSpace(freq) && !lookups.FrequencyIdByKey.ContainsKey(freq!))
                        Add("assuranceFrequencyCode", $"assuranceFrequencyCode '{freq}' is not an active option in reference_option (option_group='frequency-types').");
                    var key = name.ToLowerInvariant() + "||" + evCode.ToLowerInvariant() + "||" + (freq ?? "").ToLowerInvariant();
                    if (!seen.Add(key)) Add("evidenceTypeCode", "Duplicate (obligationName, evidenceTypeCode, assuranceFrequencyCode) within this sheet.");
                    break;
                }
            case "PracticeSourceStatementMapping":
                {
                    var stmtKey = BuildStatementKey(V("artifactCode"), V("versionNo"), V("statementReference"));
                    if (!lookups.ExistingStatementKeys.Contains(stmtKey) && !lookups.NewStatementKeys.Contains(stmtKey))
                        Add("statementReference", "statementReference must exist in the given release (SourceStatement sheet or database).");
                    var req = V("requirementCode") ?? "";
                    if (!lookups.ExistingRequirementCodes.ContainsKey(req) && !lookups.NewRequirementCodes.Contains(req))
                        Add("requirementCode", $"requirementCode '{req}' is not an existing active Practice (in this file or the database).");
                    var key = stmtKey + "||" + req;
                    if (!seen.Add(key)) Add("requirementCode", "Duplicate (statement, requirement) mapping within this sheet.");
                    break;
                }
            case "PracticeObligationMapping":
                {
                    var name = V("obligationName") ?? "";
                    var (found, ambiguous) = ResolveObligationRef(name, lookups);
                    if (!found) Add("obligationName", $"obligationName '{name}' does not match an obligation in this workbook or the database.");
                    else if (ambiguous) Add("obligationName", $"obligationName '{name}' is ambiguous — more than one active obligation shares this name.");
                    var targetReq = V("targetRequirementCode") ?? "";
                    if (!lookups.ExistingRequirementCodes.ContainsKey(targetReq) && !lookups.NewRequirementCodes.Contains(targetReq))
                        Add("targetRequirementCode", $"targetRequirementCode '{targetReq}' is not an existing active Practice (in this file or the database).");
                    var targetRelease = BuildReleaseKey(V("targetArtifactCode"), V("targetVersionNo"));
                    if (!lookups.ExistingReleaseKeys.Contains(targetRelease) && !lookups.NewReleaseKeys.Contains(targetRelease))
                        Add("targetVersionNo", "Target release is not defined.");
                    var targetStmt = V("targetStatementReference");
                    var stmtLower = "";
                    if (!string.IsNullOrWhiteSpace(targetStmt))
                    {
                        var stmtKey = BuildStatementKey(V("targetArtifactCode"), V("targetVersionNo"), targetStmt);
                        if (!lookups.ExistingStatementKeys.Contains(stmtKey) && !lookups.NewStatementKeys.Contains(stmtKey))
                            Add("targetStatementReference", "targetStatementReference must exist in the target release.");
                        stmtLower = targetStmt!.Trim().ToLowerInvariant();
                    }
                    // Uniqueness: (req, rel, stmt, obl) - active rows.
                    var key = targetReq + "||" + targetRelease + "||" + stmtLower + "||" + name.ToLowerInvariant();
                    if (!seen.Add(key)) Add("obligationName", "Duplicate (targetRequirementCode, targetRelease, targetStatementReference, obligationName) within this sheet.");
                    break;
                }
        }
    }

    // Resolve an obligation name against workbook + DB.  Returns (found,
    // ambiguous).  Ambiguous = > 1 matches across (workbook new rows) + (DB
    // active rows).
    private static (bool Found, bool Ambiguous) ResolveObligationRef(string name, DbLookups lookups)
    {
        if (string.IsNullOrWhiteSpace(name)) return (false, false);
        var trimmed = name.Trim();
        var inFile = lookups.NewObligationNameCounts.GetValueOrDefault(trimmed, 0);
        var inDb = lookups.ExistingObligationNameCounts.GetValueOrDefault(trimmed, 0);
        var total = inFile + inDb;
        return (total >= 1, total > 1);
    }

    // ==========================================================================
    // Commit — direct INSERTs, all inside one SqlTransaction.
    // ==========================================================================
    private async Task<Dictionary<string, int>> InsertAllAsync(SqlConnection conn, SqlTransaction tx,
        Dictionary<string, List<Dictionary<string, string?>>> parsed, DbLookups lookups, string enteredBy, CancellationToken ct)
    {
        var counts = new Dictionary<string, int>();
        var newAuth = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        var newArt = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        var newRelease = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        var newNode = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        var newStatement = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);

        long ResolveAuthorityId(string? code)
        {
            code = (code ?? "").Trim();
            if (newAuth.TryGetValue(code, out var id)) return id;
            return lookups.AuthorityIdByCode.TryGetValue(code, out var existing) ? existing : 0;
        }
        long ResolveArtifactId(string? code)
        {
            code = (code ?? "").Trim();
            if (newArt.TryGetValue(code, out var id)) return id;
            return lookups.ArtifactIdByCode.TryGetValue(code, out var existing) ? existing : 0;
        }
        long ResolveReleaseId(string? artifactCode, string? versionNo)
        {
            var key = BuildReleaseKey(artifactCode, versionNo);
            if (newRelease.TryGetValue(key, out var id)) return id;
            return lookups.ReleaseIdByKey.TryGetValue(key, out var existing) ? existing : 0;
        }
        long ResolveNodeId(string? artifactCode, string? versionNo, string? nodeReference)
        {
            var key = BuildNodeKey(artifactCode, versionNo, nodeReference);
            if (newNode.TryGetValue(key, out var id)) return id;
            return lookups.NodeIdByKey.TryGetValue(key, out var existing) ? existing : 0;
        }
        long ResolveStatementId(string? artifactCode, string? versionNo, string? statementReference)
        {
            var key = BuildStatementKey(artifactCode, versionNo, statementReference);
            if (newStatement.TryGetValue(key, out var id)) return id;
            return lookups.StatementIdByKey.TryGetValue(key, out var existing) ? existing : 0;
        }
        // ---- Authority ----
        foreach (var row in parsed.GetValueOrDefault("Authority") ?? new())
        {
            var id = await ExecScalarAsync(conn, tx, ct,
                @"INSERT INTO GRAC_New.authority(authority_name,authority_code,description,jurisdiction,website,status,entered_by,entered_dt)
                  VALUES(@name,@code,@desc,@juris,@site,'Active',@by,SYSUTCDATETIME());
                  SELECT CAST(SCOPE_IDENTITY() AS BIGINT);",
                new Dictionary<string, object?>
                {
                    ["@name"] = row["authorityName"],
                    ["@code"] = row["authorityCode"],
                    ["@desc"] = (object?)row["description"] ?? DBNull.Value,
                    ["@juris"] = (object?)row["jurisdiction"] ?? DBNull.Value,
                    ["@site"] = (object?)row["website"] ?? DBNull.Value,
                    ["@by"] = enteredBy
                });
            newAuth[(row["authorityCode"] ?? "").Trim()] = id;
        }
        if (newAuth.Count > 0) counts["authorities"] = newAuth.Count;

        // ---- Artifact ----
        foreach (var row in parsed.GetValueOrDefault("Artifact") ?? new())
        {
            var authId = ResolveAuthorityId(row["authorityCode"]);
            var id = await ExecScalarAsync(conn, tx, ct,
                @"INSERT INTO GRAC_New.artifact(authority_id,artifact_name,artifact_code,description,artifact_category,industry,jurisdiction,status,entered_by,entered_dt)
                  VALUES(@auth,@name,@code,@desc,@cat,@ind,@juris,'Active',@by,SYSUTCDATETIME());
                  SELECT CAST(SCOPE_IDENTITY() AS BIGINT);",
                new Dictionary<string, object?>
                {
                    ["@auth"] = authId,
                    ["@name"] = row["artifactName"],
                    ["@code"] = row["artifactCode"],
                    ["@desc"] = (object?)row["description"] ?? DBNull.Value,
                    ["@cat"]  = row["artifactCategory"],
                    ["@ind"]  = (object?)row["industry"] ?? DBNull.Value,
                    ["@juris"]= (object?)row["jurisdiction"] ?? DBNull.Value,
                    ["@by"]   = enteredBy
                });
            newArt[(row["artifactCode"] ?? "").Trim()] = id;
        }
        if (newArt.Count > 0) counts["artifacts"] = newArt.Count;

        // ---- Release ----
        foreach (var row in parsed.GetValueOrDefault("Release") ?? new())
        {
            var artId = ResolveArtifactId(row["artifactCode"]);
            var id = await ExecScalarAsync(conn, tx, ct,
                @"INSERT INTO GRAC_New.release(artifact_id,version_no,effective_dt,end_dt,release_notes,status,entered_by,entered_dt)
                  VALUES(@art,@ver,@eff,@end,@notes,'Draft',@by,SYSUTCDATETIME());
                  SELECT CAST(SCOPE_IDENTITY() AS BIGINT);",
                new Dictionary<string, object?>
                {
                    ["@art"] = artId,
                    ["@ver"] = row["versionNo"],
                    ["@eff"] = ParseDate(row["effectiveDate"]),
                    ["@end"] = ParseDate(row["endDate"]),
                    ["@notes"] = (object?)row["releaseNotes"] ?? DBNull.Value,
                    ["@by"] = enteredBy
                });
            newRelease[BuildReleaseKey(row["artifactCode"], row["versionNo"])] = id;
        }
        if (newRelease.Count > 0) counts["releases"] = newRelease.Count;

        // ---- SourceStructure — insert parents before children so the
        //      self-referencing FK resolves.  Rows are processed in a wave loop:
        //      each pass emits every row whose parent is either blank or has
        //      already landed (in this workbook or the DB); loop until empty.
        var structureRows = parsed.GetValueOrDefault("SourceStructure") ?? new();
        var pending = new List<Dictionary<string, string?>>(structureRows);
        var safety = 0;
        while (pending.Count > 0 && safety++ < 20000)
        {
            var progressed = false;
            for (var i = pending.Count - 1; i >= 0; i--)
            {
                var row = pending[i];
                var parentRef = row["parentNodeReference"];
                if (!string.IsNullOrWhiteSpace(parentRef))
                {
                    var pKey = BuildNodeKey(row["artifactCode"], row["versionNo"], parentRef);
                    if (!newNode.ContainsKey(pKey) && !lookups.NodeIdByKey.ContainsKey(pKey)) continue; // wait for parent
                }
                var parentId = string.IsNullOrWhiteSpace(parentRef)
                    ? (object)DBNull.Value
                    : ResolveNodeId(row["artifactCode"], row["versionNo"], parentRef);
                var releaseId = ResolveReleaseId(row["artifactCode"], row["versionNo"]);
                var id = await ExecScalarAsync(conn, tx, ct,
                    @"INSERT INTO GRAC_New.source_structure_node(release_id,parent_node_id,node_level,node_type,node_reference,node_title,description,display_order,status,entered_by,entered_dt)
                      VALUES(@rel,@parent,@level,@type,@ref,@title,@desc,@ord,'Active',@by,SYSUTCDATETIME());
                      SELECT CAST(SCOPE_IDENTITY() AS BIGINT);",
                    new Dictionary<string, object?>
                    {
                        ["@rel"] = releaseId,
                        ["@parent"] = parentId,
                        ["@level"] = ParseLong(row["nodeLevel"]) ?? 1,
                        ["@type"] = row["nodeType"],
                        ["@ref"] = row["nodeReference"],
                        ["@title"] = (object?)row["nodeTitle"] ?? DBNull.Value,
                        ["@desc"] = (object?)row["description"] ?? DBNull.Value,
                        ["@ord"] = ParseLong(row["displayOrder"]) ?? 0,
                        ["@by"] = enteredBy
                    });
                newNode[BuildNodeKey(row["artifactCode"], row["versionNo"], row["nodeReference"])] = id;
                pending.RemoveAt(i);
                progressed = true;
            }
            if (!progressed) throw new InvalidOperationException("SourceStructure: unresolved parentNodeReference chain (circular or missing).");
        }
        if (newNode.Count > 0) counts["source-structure"] = newNode.Count;

        // ---- SourceStatement ----
        foreach (var row in parsed.GetValueOrDefault("SourceStatement") ?? new())
        {
            var releaseId = ResolveReleaseId(row["artifactCode"], row["versionNo"]);
            var nodeId    = ResolveNodeId(row["artifactCode"], row["versionNo"], row["structureNodeReference"]);
            long? classificationId = null;
            var classification = row["classificationCode"];
            if (!string.IsNullOrWhiteSpace(classification))
            {
                var ckey = BuildReleaseKey(row["artifactCode"], row["versionNo"]) + "||" + classification;
                if (lookups.ClassificationIdByKey.TryGetValue(ckey, out var cid)) classificationId = cid;
            }
            var id = await ExecScalarAsync(conn, tx, ct,
                @"INSERT INTO GRAC_New.framework_statement(release_id,structure_node_id,classification_id,statement_reference,statement_title,statement_text,statement_type,remarks,display_order,status,entered_by,entered_dt)
                  VALUES(@rel,@node,@class,@ref,@title,@text,@type,@rem,@ord,'Active',@by,SYSUTCDATETIME());
                  SELECT CAST(SCOPE_IDENTITY() AS BIGINT);",
                new Dictionary<string, object?>
                {
                    ["@rel"] = releaseId,
                    ["@node"] = nodeId,
                    ["@class"] = (object?)classificationId ?? DBNull.Value,
                    ["@ref"] = row["statementReference"],
                    ["@title"] = (object?)row["statementTitle"] ?? DBNull.Value,
                    ["@text"] = row["statementText"],
                    ["@type"] = (object?)row["statementType"] ?? DBNull.Value,
                    ["@rem"] = (object?)row["remarks"] ?? DBNull.Value,
                    ["@ord"] = ParseLong(row["displayOrder"]) ?? 0,
                    ["@by"] = enteredBy
                });
            newStatement[BuildStatementKey(row["artifactCode"], row["versionNo"], row["statementReference"])] = id;
        }
        if (newStatement.Count > 0) counts["framework-statements"] = newStatement.Count;

        // ---- Practice (requirement) - global master ----
        var newRequirements = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        foreach (var row in parsed.GetValueOrDefault("Practice") ?? new())
        {
            var id = await ExecScalarAsync(conn, tx, ct,
                @"INSERT INTO GRAC_New.requirement(requirement_code,requirement_name,requirement_statement,objective,keywords,status,entered_by,entered_dt)
                  VALUES(@code,@name,@stmt,@obj,@kw,'Active',@by,SYSUTCDATETIME());
                  SELECT CAST(SCOPE_IDENTITY() AS BIGINT);",
                new Dictionary<string, object?>
                {
                    ["@code"] = row["requirementCode"],
                    ["@name"] = row["requirementName"],
                    ["@stmt"] = row["requirementStatement"],
                    ["@obj"] = (object?)row["objective"] ?? DBNull.Value,
                    ["@kw"] = (object?)row["keywords"] ?? DBNull.Value,
                    ["@by"] = enteredBy
                });
            newRequirements[(row["requirementCode"] ?? "").Trim()] = id;
        }
        if (newRequirements.Count > 0) counts["requirements"] = newRequirements.Count;

        long ResolveRequirementId(string? code)
        {
            code = (code ?? "").Trim();
            if (newRequirements.TryGetValue(code, out var id)) return id;
            return lookups.ExistingRequirementCodes.TryGetValue(code, out var existing) ? existing : 0;
        }

        // ---- Obligation Master (requirement_obligation) - GLOBAL (post-019) --
        // No more requirement_id / release_id / frequency_type triggers.
        // The frequency_type text column is retained as a cache of the label
        // so legacy UI code that reads it stays happy.
        var newObligationIdByName = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        var newObligationNameDupCounter = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var row in parsed.GetValueOrDefault("Obligation") ?? new())
        {
            long? freqId = null;
            string? freqLabel = null;
            var freq = row["executionFrequencyCode"];
            if (!string.IsNullOrWhiteSpace(freq)
                && lookups.FrequencyIdByKey.TryGetValue(freq!.Trim(), out var fid))
            {
                freqId = fid;
                freqLabel = lookups.FrequencyLabelById.TryGetValue(fid, out var lbl) ? lbl : freq;
            }
            var id = await ExecScalarAsync(conn, tx, ct,
                @"INSERT INTO GRAC_New.requirement_obligation(obligation_name,obligation_text,execution_frequency_id,frequency_type,retention_requirement,remarks,status,entered_by,entered_dt)
                  VALUES(@name,@text,@fid,@ftext,@ret,@rem,'Active',@by,SYSUTCDATETIME());
                  SELECT CAST(SCOPE_IDENTITY() AS BIGINT);",
                new Dictionary<string, object?>
                {
                    ["@name"] = row["obligationName"],
                    ["@text"] = (object?)row["obligationText"] ?? DBNull.Value,
                    ["@fid"] = (object?)freqId ?? DBNull.Value,
                    ["@ftext"] = (object?)freqLabel ?? DBNull.Value,
                    ["@ret"] = (object?)row["retentionRequirement"] ?? DBNull.Value,
                    ["@rem"] = (object?)row["remarks"] ?? DBNull.Value,
                    ["@by"] = enteredBy
                });
            var name = (row["obligationName"] ?? "").Trim();
            newObligationIdByName[name] = id; // last-write-wins; ambiguity is caught in validation
        }
        if (newObligationIdByName.Count > 0) counts["obligations"] = newObligationIdByName.Count;

        long ResolveObligationIdByName(string? name)
        {
            name = (name ?? "").Trim();
            if (newObligationIdByName.TryGetValue(name, out var id)) return id;
            return lookups.ObligationIdByName.TryGetValue(name, out var existing) ? existing : 0;
        }

        // ---- ObligationEvidence (requirement_obligation_evidence) ------------
        var evidenceCount = 0;
        foreach (var row in parsed.GetValueOrDefault("ObligationEvidence") ?? new())
        {
            var obligationId = ResolveObligationIdByName(row["obligationName"]);
            var evId = lookups.EvidenceTypeIdByCode[(row["evidenceTypeCode"] ?? "").Trim()];
            long? freqId = null;
            var freq = row["assuranceFrequencyCode"];
            if (!string.IsNullOrWhiteSpace(freq)
                && lookups.FrequencyIdByKey.TryGetValue(freq!.Trim(), out var fid))
                freqId = fid;
            await ExecScalarAsync(conn, tx, ct,
                @"INSERT INTO GRAC_New.requirement_obligation_evidence(obligation_id,evidence_type_id,frequency_id,retention_requirement,remarks,status,entered_by,entered_dt)
                  VALUES(@ob,@ev,@fq,@ret,@rem,'Active',@by,SYSUTCDATETIME());
                  SELECT CAST(SCOPE_IDENTITY() AS BIGINT);",
                new Dictionary<string, object?>
                {
                    ["@ob"] = obligationId,
                    ["@ev"] = evId,
                    ["@fq"] = (object?)freqId ?? DBNull.Value,
                    ["@ret"] = (object?)row["retentionRequirement"] ?? DBNull.Value,
                    ["@rem"] = (object?)row["remarks"] ?? DBNull.Value,
                    ["@by"] = enteredBy
                });
            evidenceCount++;
        }
        if (evidenceCount > 0) counts["obligation-evidence"] = evidenceCount;

        // ---- PracticeSourceStatementMapping (framework_statement_requirement_map) ----
        var mappingCount = 0;
        foreach (var row in parsed.GetValueOrDefault("PracticeSourceStatementMapping") ?? new())
        {
            var stmtId = ResolveStatementId(row["artifactCode"], row["versionNo"], row["statementReference"]);
            var reqId = ResolveRequirementId(row["requirementCode"]);
            await ExecScalarAsync(conn, tx, ct,
                @"INSERT INTO GRAC_New.framework_statement_requirement_map(framework_statement_id,requirement_id,status,entered_by,entered_dt)
                  VALUES(@stmt,@req,'Active',@by,SYSUTCDATETIME());
                  SELECT CAST(SCOPE_IDENTITY() AS BIGINT);",
                new Dictionary<string, object?>
                {
                    ["@stmt"] = stmtId,
                    ["@req"] = reqId,
                    ["@by"] = enteredBy
                });
            mappingCount++;
        }
        if (mappingCount > 0) counts["source-control-mappings"] = mappingCount;

        // ---- PracticeObligationMapping (obligation_requirement_release_map) --
        var obligationMappingCount = 0;
        foreach (var row in parsed.GetValueOrDefault("PracticeObligationMapping") ?? new())
        {
            var obligationId = ResolveObligationIdByName(row["obligationName"]);
            var reqId = ResolveRequirementId(row["targetRequirementCode"]);
            var releaseId = ResolveReleaseId(row["targetArtifactCode"], row["targetVersionNo"]);
            long? statementId = null;
            var stmtRef = row["targetStatementReference"];
            if (!string.IsNullOrWhiteSpace(stmtRef))
            {
                var sid = ResolveStatementId(row["targetArtifactCode"], row["targetVersionNo"], stmtRef);
                if (sid > 0) statementId = sid;
            }
            await ExecScalarAsync(conn, tx, ct,
                @"IF OBJECT_ID('GRAC_New.obligation_requirement_release_map','U') IS NOT NULL
                  BEGIN
                      INSERT INTO GRAC_New.obligation_requirement_release_map(obligation_id,requirement_id,release_id,framework_statement_id,status,entered_by,entered_dt)
                      VALUES(@ob,@req,@rel,@stmt,'Active',@by,SYSUTCDATETIME());
                      SELECT CAST(SCOPE_IDENTITY() AS BIGINT);
                  END
                  ELSE SELECT CAST(0 AS BIGINT);",
                new Dictionary<string, object?>
                {
                    ["@ob"] = obligationId,
                    ["@req"] = reqId,
                    ["@rel"] = releaseId,
                    ["@stmt"] = (object?)statementId ?? DBNull.Value,
                    ["@by"] = enteredBy
                });
            obligationMappingCount++;
        }
        if (obligationMappingCount > 0) counts["obligation-mappings"] = obligationMappingCount;

        return counts;
    }

    // ==========================================================================
    // Helpers
    // ==========================================================================
    private static string BuildReleaseKey(string? artifactCode, string? versionNo) =>
        ((artifactCode ?? "").Trim() + "||" + (versionNo ?? "").Trim()).ToLowerInvariant();
    private static string BuildNodeKey(string? artifactCode, string? versionNo, string? nodeReference) =>
        (BuildReleaseKey(artifactCode, versionNo) + "||" + (nodeReference ?? "").Trim()).ToLowerInvariant();
    private static string BuildStatementKey(string? artifactCode, string? versionNo, string? statementReference) =>
        (BuildReleaseKey(artifactCode, versionNo) + "||" + (statementReference ?? "").Trim()).ToLowerInvariant();

    private static object ParseDate(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return DBNull.Value;
        return DateTime.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out var dt) ? dt.Date : DBNull.Value;
    }

    private static long? ParseLong(string? value) =>
        long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : null;

    private static async Task<long> ExecScalarAsync(SqlConnection conn, SqlTransaction tx, CancellationToken ct, string sql, Dictionary<string, object?> parameters)
    {
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = sql;
        cmd.Transaction = tx;
        foreach (var (name, value) in parameters)
        {
            var p = cmd.CreateParameter();
            p.ParameterName = name;
            p.Value = value ?? DBNull.Value;
            cmd.Parameters.Add(p);
        }
        var result = await cmd.ExecuteScalarAsync(ct);
        return result is null || result == DBNull.Value ? 0 : Convert.ToInt64(result);
    }

    // ==========================================================================
    // DB access
    // ==========================================================================
    private SqlConnection OpenConnection()
    {
        var connectionString = GetConnectionString()
            ?? throw new InvalidOperationException("Configure ConnectionStrings:ControlManagement or the GRAC DbConnection and Password settings before using bulk upload.");
        var builder = new SqlConnectionStringBuilder(connectionString)
        {
            Encrypt = configuration.GetValue("Database:Encrypt", true),
            TrustServerCertificate = configuration.GetValue("Database:TrustServerCertificate", false)
        };
        return new SqlConnection(builder.ConnectionString);
    }

    private string? GetConnectionString()
    {
        var connectionString = configuration.GetConnectionString("ControlManagement");
        if (!string.IsNullOrWhiteSpace(connectionString)) return connectionString;
        var gracConnection = configuration.GetConnectionString("DbConnection");
        var encryptedPassword = configuration.GetConnectionString("Password");
        if (string.IsNullOrWhiteSpace(gracConnection) || string.IsNullOrWhiteSpace(encryptedPassword)) return null;
        var parts = encryptedPassword.Split('~', 2);
        if (parts.Length != 2) throw new InvalidOperationException("ConnectionStrings:Password must contain the GRAC encryption key and encrypted password.");
        return gracConnection + DecryptPassword(parts[1], parts[0]);
    }

    private static string DecryptPassword(string encryptedPassword, string key)
    {
        using var aes = Aes.Create();
        aes.Key = Encoding.UTF8.GetBytes(key.Substring(4, 32));
        aes.IV = Encoding.UTF8.GetBytes(key.ToLowerInvariant().Substring(4, 16));
        aes.Mode = CipherMode.CBC;
        aes.Padding = PaddingMode.PKCS7;
        using var decryptor = aes.CreateDecryptor(aes.Key, aes.IV);
        using var ms = new MemoryStream(Convert.FromBase64String(encryptedPassword));
        using var cs = new CryptoStream(ms, decryptor, CryptoStreamMode.Read);
        using var reader = new StreamReader(cs);
        return reader.ReadToEnd();
    }

    // Preload every reference we need for FK/uniqueness validation so we can
    // then validate the entire workbook in memory in one pass.
    private static async Task<DbLookups> LoadLookupsAsync(SqlConnection conn, SqlTransaction? tx, CancellationToken ct)
    {
        var lk = new DbLookups();
        async Task Read(string sql, Action<SqlDataReader> apply)
        {
            await using var cmd = conn.CreateCommand();
            cmd.CommandText = sql;
            if (tx is not null) cmd.Transaction = tx;
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct)) apply(reader);
        }

        await Read("SELECT authority_id,authority_code FROM GRAC_New.authority WHERE status='Active'", r =>
        {
            var code = r.GetString(1);
            lk.AuthorityIdByCode[code] = r.GetInt64(0);
            lk.ExistingAuthorityCodes.Add(code);
        });
        await Read("SELECT artifact_id,artifact_code FROM GRAC_New.artifact WHERE status='Active'", r =>
        {
            var code = r.GetString(1);
            lk.ArtifactIdByCode[code] = r.GetInt64(0);
            lk.ExistingArtifactCodes.Add(code);
        });
        await Read(@"SELECT r.release_id,a.artifact_code,r.version_no
                     FROM GRAC_New.release r JOIN GRAC_New.artifact a ON a.artifact_id=r.artifact_id
                     WHERE r.status IN ('Draft','Active')", r =>
        {
            var key = BuildReleaseKey(r.GetString(1), r.GetString(2));
            lk.ReleaseIdByKey[key] = r.GetInt64(0);
            lk.ExistingReleaseKeys.Add(key);
        });
        await Read(@"SELECT n.structure_node_id,a.artifact_code,r.version_no,n.node_reference
                     FROM GRAC_New.source_structure_node n
                     JOIN GRAC_New.release r ON r.release_id=n.release_id
                     JOIN GRAC_New.artifact a ON a.artifact_id=r.artifact_id
                     WHERE n.status='Active'", r =>
        {
            var key = BuildNodeKey(r.GetString(1), r.GetString(2), r.GetString(3));
            lk.NodeIdByKey[key] = r.GetInt64(0);
            lk.ExistingNodeKeys.Add(key);
        });
        await Read(@"SELECT sc.statement_classification_id,a.artifact_code,rl.version_no,sc.classification_code
                     FROM GRAC_New.statement_classification sc
                     JOIN GRAC_New.release rl ON rl.release_id=sc.release_id
                     JOIN GRAC_New.artifact a ON a.artifact_id=rl.artifact_id
                     WHERE sc.status='Active'", r =>
        {
            var key = BuildReleaseKey(r.GetString(1), r.GetString(2)) + "||" + r.GetString(3);
            lk.ClassificationIdByKey[key] = r.GetInt64(0);
            lk.ExistingClassificationKeys.Add(key);
        });
        await Read(@"SELECT fs.framework_statement_id,a.artifact_code,rl.version_no,fs.statement_reference
                     FROM GRAC_New.framework_statement fs
                     JOIN GRAC_New.release rl ON rl.release_id=fs.release_id
                     JOIN GRAC_New.artifact a ON a.artifact_id=rl.artifact_id
                     WHERE fs.status='Active'", r =>
        {
            var key = BuildStatementKey(r.GetString(1), r.GetString(2), r.GetString(3));
            lk.StatementIdByKey[key] = r.GetInt64(0);
            lk.ExistingStatementKeys.Add(key);
        });
        await Read("SELECT requirement_id,requirement_code FROM GRAC_New.requirement WHERE status='Active'", r =>
        {
            lk.ExistingRequirementCodes[r.GetString(1)] = r.GetInt64(0);
        });
        // Obligation Master is a GLOBAL entity post-019.  We track name -> id
        // for the last-wins lookup and count occurrences so mapping/evidence
        // references can flag ambiguity when > 1 active obligation shares a
        // name (across file + DB).
        await Read(@"SELECT obligation_id, obligation_name FROM GRAC_New.requirement_obligation WHERE status='Active' AND obligation_name IS NOT NULL", r =>
        {
            var name = r.GetString(1).Trim();
            if (name.Length == 0) return;
            lk.ObligationIdByName[name] = r.GetInt64(0);
            lk.ExistingObligationNameCounts[name] = lk.ExistingObligationNameCounts.GetValueOrDefault(name, 0) + 1;
        });
        // Frequency options: both option_value and option_label resolve to the
        // same id so users may type either.
        await Read("SELECT reference_option_id, option_value, option_label FROM GRAC_New.reference_option WHERE option_group='frequency-types' AND status='Active'", r =>
        {
            var id = r.GetInt64(0);
            var value = r.GetString(1);
            var label = r.GetString(2);
            lk.FrequencyIdByKey[value] = id;
            lk.FrequencyIdByKey[label] = id;
            lk.FrequencyLabelById[id] = label;
        });
        await Read("SELECT evidence_type_id, evidence_type_code FROM GRAC_New.evidence_type_master WHERE is_active=1", r =>
        {
            lk.EvidenceTypeIdByCode[r.GetString(1)] = r.GetInt32(0);
        });
        return lk;
    }

    private sealed class DbLookups
    {
        public HashSet<string> ExistingAuthorityCodes { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> ExistingArtifactCodes { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> ExistingReleaseKeys { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> ExistingNodeKeys { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> ExistingClassificationKeys { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> ExistingStatementKeys { get; } = new(StringComparer.OrdinalIgnoreCase);

        public Dictionary<string, long> AuthorityIdByCode { get; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, long> ArtifactIdByCode { get; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, long> ReleaseIdByKey { get; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, long> NodeIdByKey { get; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, long> ClassificationIdByKey { get; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, long> StatementIdByKey { get; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, long> ExistingRequirementCodes { get; } = new(StringComparer.OrdinalIgnoreCase);

        // Obligation Master is a global entity (post-019) referenced by name.
        // We keep both an id-lookup (last write wins) and a per-name count so
        // callers can detect ambiguity.
        public Dictionary<string, long> ObligationIdByName { get; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, int>  ExistingObligationNameCounts { get; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, int>  NewObligationNameCounts { get; } = new(StringComparer.OrdinalIgnoreCase);

        // reference_option (frequency-types) and evidence_type_master.
        public Dictionary<string, long> FrequencyIdByKey { get; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<long,   string> FrequencyLabelById { get; } = new();
        public Dictionary<string, int>  EvidenceTypeIdByCode { get; } = new(StringComparer.OrdinalIgnoreCase);

        // Populated from the incoming workbook so cross-sheet references resolve.
        public HashSet<string> NewAuthorityCodes { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> NewArtifactCodes { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> NewReleaseKeys { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> NewNodeKeys { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> NewStatementKeys { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> NewRequirementCodes { get; } = new(StringComparer.OrdinalIgnoreCase);
    }
}
