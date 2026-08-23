using System.Data;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using ClosedXML.Excel;
using ControlManagement.Api.Models;
using Microsoft.Data.SqlClient;

namespace ControlManagement.Api.Services;

// -----------------------------------------------------------------------------
// Single-Form Upload orchestrator.
//   * ListReleasesAsync -> Draft/Active releases the admin can select.
//   * BuildTemplate     -> one data sheet + hidden signed context sheet.
//                          Release-scoped forms carry Release (label) and
//                          ReleaseId (numeric, locked style) as columns 1-2.
//   * ValidateAsync     -> verify signature, verify posted context matches
//                          the workbook context, verify every row's
//                          ReleaseId, then run per-entity referential checks.
//   * CommitAsync       -> after validation, INSERT every row inside a single
//                          SqlTransaction with rollback-on-any-failure.
// -----------------------------------------------------------------------------

public sealed record SingleFormReleaseOption(long ReleaseId, string ArtifactCode, string ArtifactName, string VersionNo, string AuthorityName, string Label, string Status);

public interface ISingleFormUploadService
{
    Task<IReadOnlyList<SingleFormReleaseOption>> ListReleasesAsync(CancellationToken cancellationToken);
    IReadOnlyList<SingleFormDefinition> ListForms();
    Task<byte[]> BuildTemplateAsync(string entityKey, long? releaseId, CancellationToken cancellationToken);
    Task<BulkUploadReport> ValidateAsync(string entityKey, long? releaseId, Stream file, CancellationToken cancellationToken);
    Task<BulkUploadReport> CommitAsync(string entityKey, long? releaseId, string uploadMode, string? confirmReleaseCode, Stream file, string enteredBy, CancellationToken cancellationToken);
    Task<ReplacePreview> PreviewReplaceAsync(string entityKey, long? releaseId, CancellationToken cancellationToken);
}

public sealed class SingleFormUploadService(IConfiguration configuration, ILogger<SingleFormUploadService> logger) : ISingleFormUploadService
{
    private const string ContextSheet = "__context__";

    public IReadOnlyList<SingleFormDefinition> ListForms() => SingleFormUploadSchema.Forms;

    public async Task<IReadOnlyList<SingleFormReleaseOption>> ListReleasesAsync(CancellationToken ct)
    {
        await using var conn = OpenConnection();
        await conn.OpenAsync(ct);
        var list = new List<SingleFormReleaseOption>();
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
            SELECT r.release_id, a.artifact_code, a.artifact_name, r.version_no, au.authority_name, r.status
            FROM GRAC_New.release r
            JOIN GRAC_New.artifact a ON a.artifact_id = r.artifact_id
            JOIN GRAC_New.authority au ON au.authority_id = a.authority_id
            WHERE r.status IN ('Draft','Active')
            ORDER BY au.authority_name, a.artifact_code, r.version_no";
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            var artifactCode = reader.GetString(1);
            var versionNo    = reader.GetString(3);
            list.Add(new SingleFormReleaseOption(
                reader.GetInt64(0),
                artifactCode,
                reader.GetString(2),
                versionNo,
                reader.GetString(4),
                $"{artifactCode} / {versionNo}",
                reader.GetString(5)));
        }
        return list;
    }

    // ---------------------------- Template ---------------------------------
    public async Task<byte[]> BuildTemplateAsync(string entityKey, long? releaseId, CancellationToken ct)
    {
        var def = SingleFormUploadSchema.Find(entityKey)
            ?? throw new InvalidOperationException($"Unknown entity '{entityKey}'.");

        SingleFormReleaseOption? release = null;
        if (def.ReleaseScoped)
        {
            if (!releaseId.HasValue || releaseId.Value <= 0)
                throw new InvalidOperationException($"Release is required for '{def.DisplayName}'.");
            release = await FindReleaseAsync(releaseId.Value, ct)
                ?? throw new InvalidOperationException("The selected release does not exist or is not Draft/Active.");
        }

        using var wb = new XLWorkbook();
        var ws = wb.Worksheets.Add(def.DisplayName.Length > 30 ? def.DisplayName[..30] : def.DisplayName);

        // Row 1: banner
        ws.Cell(1, 1).Value = def.Instructions;
        ws.Cell(1, 1).Style.Font.Italic = true;
        ws.Row(1).Style.Fill.BackgroundColor = XLColor.LightYellow;

        // Compose columns: prepend Release + ReleaseId for release-scoped forms.
        var columns = new List<BulkColumn>();
        if (def.ReleaseScoped)
        {
            columns.Add(new BulkColumn("Release", "__releaseLabel", true, BulkColumnType.Text, 250, "Read-only. Do not edit."));
            columns.Add(new BulkColumn("ReleaseId", "__releaseId", true, BulkColumnType.Integer, 0, "Read-only. Do not edit. The upload is bound to this Release."));
        }
        columns.AddRange(def.Columns);

        var lastCol = columns.Count;
        ws.Range(1, 1, 1, Math.Max(1, lastCol)).Merge();

        // Row 2: headers
        for (var c = 0; c < columns.Count; c++)
        {
            var col = columns[c];
            var cell = ws.Cell(2, c + 1);
            cell.Value = col.Header + (col.Required ? " *" : "");
            cell.Style.Font.Bold = true;
            cell.Style.Fill.BackgroundColor = col.Required ? XLColor.LightBlue : XLColor.LightGray;
            if (!string.IsNullOrWhiteSpace(col.Help)) cell.GetComment().AddText(col.Help);
        }

        // Row 3: type hint
        for (var c = 0; c < columns.Count; c++)
        {
            var col = columns[c];
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

        // Pre-fill Release + ReleaseId for a handful of data rows so the user
        // sees the auto-fill; column style flags them as read-only visually
        // (real tamper protection is via the signed context sheet + server
        // side row-level verification).
        if (def.ReleaseScoped && release is not null)
        {
            for (var r = 4; r <= 33; r++)
            {
                ws.Cell(r, 1).Value = release.Label;
                ws.Cell(r, 2).Value = release.ReleaseId;
            }
            var lockRange = ws.Range(4, 1, 33, 2);
            lockRange.Style.Fill.BackgroundColor = XLColor.FromArgb(240, 240, 240);
            lockRange.Style.Font.FontColor = XLColor.FromArgb(96, 96, 96);
        }

        ws.Row(1).Height = 32;
        ws.SheetView.FreezeRows(3);
        ws.Columns(1, lastCol).Width = 24;

        // Hidden signed context sheet. Any change to entity, releaseId or the
        // signature invalidates the workbook at commit time.
        var ctx = wb.Worksheets.Add(ContextSheet);
        var timestamp = DateTimeOffset.UtcNow.ToString("O", CultureInfo.InvariantCulture);
        var contextReleaseId = release?.ReleaseId ?? 0;
        var payload = BuildContextPayload(def.EntityKey, contextReleaseId, timestamp);
        var signature = SignContext(payload);
        ctx.Cell(1, 1).Value = "entity";       ctx.Cell(1, 2).Value = def.EntityKey;
        ctx.Cell(2, 1).Value = "releaseId";    ctx.Cell(2, 2).Value = contextReleaseId;
        ctx.Cell(3, 1).Value = "timestampUtc"; ctx.Cell(3, 2).Value = timestamp;
        ctx.Cell(4, 1).Value = "signature";    ctx.Cell(4, 2).Value = signature;
        ctx.Cell(5, 1).Value = "DO NOT EDIT THIS SHEET";
        ctx.Cell(5, 1).Style.Font.Bold = true;
        ctx.Cell(5, 1).Style.Font.FontColor = XLColor.Red;
        ctx.Visibility = XLWorksheetVisibility.Hidden;

        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return ms.ToArray();
    }

    // ---------------------------- Validate / Commit -------------------------
    public async Task<BulkUploadReport> ValidateAsync(string entityKey, long? releaseId, Stream file, CancellationToken ct)
    {
        var def = SingleFormUploadSchema.Find(entityKey);
        if (def is null) return Fail("Unknown entity type.");
        var parsed = ParseWorkbook(def, releaseId, file, out var contextReleaseId, out var parseReport);
        if (!parseReport.Success) return parseReport;

        await using var conn = OpenConnection();
        await conn.OpenAsync(ct);
        var lookups = await LoadLookupsAsync(conn, ct);
        ValidateRows(def, contextReleaseId, parsed, lookups, parseReport);
        parseReport.Success = parseReport.Issues.Count == 0;
        parseReport.Message = parseReport.Success
            ? $"Validation passed. Ready to commit {parsed.Count} row(s)."
            : $"Validation failed with {parseReport.Issues.Count} issue(s). No data will be inserted.";
        return parseReport;
    }

    public async Task<BulkUploadReport> CommitAsync(string entityKey, long? releaseId, string uploadMode, string? confirmReleaseCode, Stream file, string enteredBy, CancellationToken ct)
    {
        var def = SingleFormUploadSchema.Find(entityKey);
        if (def is null) return Fail("Unknown entity type.");
        var mode = (uploadMode ?? "Insert").Trim();
        var isReplace = mode.Equals("Replace", StringComparison.OrdinalIgnoreCase);

        var parsed = ParseWorkbook(def, releaseId, file, out var contextReleaseId, out var parseReport);
        if (!parseReport.Success) return parseReport;

        await using var conn = OpenConnection();
        await conn.OpenAsync(ct);
        var lookups = await LoadLookupsAsync(conn, ct);
        ValidateRows(def, contextReleaseId, parsed, lookups, parseReport);
        if (parseReport.Issues.Count > 0)
        {
            parseReport.Success = false;
            parseReport.Message = $"Validation failed with {parseReport.Issues.Count} issue(s). No data was inserted.";
            return parseReport;
        }

        // Replace-mode guards: strategy must permit it, release code must match
        // exactly, and external references must be zero.  All three checks
        // happen server-side even if the UI already ran them — never trust the
        // client for destructive operations.
        SingleFormReleaseOption? releaseInfo = null;
        if (isReplace)
        {
            if (def.ReplaceStrategy == ReplaceStrategy.NotAllowed)
                return Fail($"Replace mode is not allowed for {def.DisplayName}.");
            if (!def.ReleaseScoped)
                return Fail("Replace mode is only supported for release-scoped forms.");
            releaseInfo = await FindReleaseAsync(contextReleaseId, ct)
                ?? throw new InvalidOperationException("The selected release does not exist or is not Draft/Active.");
            var typed = (confirmReleaseCode ?? "").Trim();
            var expected = releaseInfo.Label;
            if (!typed.Equals(expected, StringComparison.Ordinal))
                return Fail($"Replace confirmation failed. Type the release code exactly: '{expected}'.");

            var preview = await BuildReplacePreviewAsync(def, contextReleaseId, releaseInfo, conn, ct);
            if (preview.Blocked)
            {
                parseReport.Success = false;
                parseReport.Message = "Replace blocked: external references exist. " + string.Join("; ", preview.Blockers.Select(b => $"{b.Table} ({b.Count})"));
                foreach (var b in preview.Blockers)
                    parseReport.Issues.Add(new BulkUploadIssue { Sheet = def.DisplayName, Row = 0, Column = "external-ref", Message = b.Reason });
                return parseReport;
            }
        }

        await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        try
        {
            var deleted = 0;
            if (isReplace)
            {
                // Re-run the blocker check WITH the transaction lock so a
                // concurrent write between the preview and here cannot slip
                // in a new external reference.
                var underLock = await BuildReplacePreviewAsync(def, contextReleaseId, releaseInfo!, conn, ct, tx);
                if (underLock.Blocked)
                    throw new InvalidOperationException("Replace blocked while committing: " + string.Join("; ", underLock.Blockers.Select(b => $"{b.Table} ({b.Count})")));
                deleted = await DeleteScopeAsync(def, contextReleaseId, conn, tx, enteredBy, ct);
            }
            var count = await InsertAllAsync(def, contextReleaseId, parsed, lookups, conn, tx, enteredBy, ct);
            await tx.CommitAsync(ct);
            parseReport.InsertedCounts = new Dictionary<string, int> { [def.EntityKey] = count };
            if (isReplace) parseReport.InsertedCounts[def.EntityKey + " (deleted)"] = deleted;
            parseReport.Success = true;
            parseReport.Message = isReplace
                ? $"Replace committed. Removed {deleted}, inserted {count} record(s) into {def.DisplayName}."
                : $"Committed. Inserted {count} record(s) into {def.DisplayName}.";
            return parseReport;
        }
        catch (Exception ex)
        {
            try { await tx.RollbackAsync(ct); } catch { /* surfaced via ex */ }
            logger.LogError(ex, "Single-form upload commit rolled back for {Entity} release {ReleaseId} mode {Mode} user {User}", def.EntityKey, contextReleaseId, mode, enteredBy);
            parseReport.Success = false;
            parseReport.Message = $"Upload rolled back: {ex.Message}. No data was inserted.";
            parseReport.Issues.Add(new BulkUploadIssue { Sheet = def.DisplayName, Row = 0, Column = "", Message = ex.Message });
            return parseReport;
        }
    }

    // -------------------------- Replace preview ---------------------------
    public async Task<ReplacePreview> PreviewReplaceAsync(string entityKey, long? releaseId, CancellationToken ct)
    {
        var def = SingleFormUploadSchema.Find(entityKey)
            ?? throw new InvalidOperationException($"Unknown entity '{entityKey}'.");
        var preview = new ReplacePreview
        {
            EntityKey = def.EntityKey,
            DisplayName = def.DisplayName,
            DeleteStrategy = def.ReplaceStrategy.ToString()
        };
        if (def.ReplaceStrategy == ReplaceStrategy.NotAllowed)
        {
            preview.Allowed = false;
            preview.Blocked = true;
            preview.Message = $"Replace mode is not permitted for {def.DisplayName}.";
            return preview;
        }
        if (!def.ReleaseScoped || releaseId is null or <= 0)
        {
            preview.Allowed = false;
            preview.Blocked = true;
            preview.Message = "Replace mode is only supported for release-scoped forms.";
            return preview;
        }
        preview.Allowed = true;
        preview.ReleaseId = releaseId.Value;

        await using var conn = OpenConnection();
        await conn.OpenAsync(ct);
        var release = await FindReleaseAsync(releaseId.Value, ct);
        if (release is null)
        {
            preview.Blocked = true;
            preview.Message = "Release not found or not in Draft/Active status.";
            return preview;
        }
        preview.ReleaseCode = release.Label;
        preview.ReleaseLabel = release.Label;

        var built = await BuildReplacePreviewAsync(def, releaseId.Value, release, conn, ct);
        preview.ExistingRowsInScope = built.ExistingRowsInScope;
        preview.Blockers = built.Blockers;
        preview.Blocked = built.Blocked;
        preview.Message = built.Message;
        return preview;
    }

    // Count existing rows in scope + check every documented external
    // reference table.  Any blocker with Count > 0 sets Blocked = true and
    // populates the human-readable reason.
    private async Task<ReplacePreview> BuildReplacePreviewAsync(SingleFormDefinition def, long releaseId, SingleFormReleaseOption release, SqlConnection conn, CancellationToken ct, SqlTransaction? tx = null)
    {
        var preview = new ReplacePreview
        {
            Allowed = true,
            EntityKey = def.EntityKey,
            DisplayName = def.DisplayName,
            ReleaseId = releaseId,
            ReleaseCode = release.Label,
            ReleaseLabel = release.Label,
            DeleteStrategy = def.ReplaceStrategy.ToString()
        };

        async Task<int> Count(string sql)
        {
            await using var cmd = conn.CreateCommand();
            cmd.CommandText = sql;
            if (tx is not null) cmd.Transaction = tx;
            var p = cmd.CreateParameter(); p.ParameterName = "@rel"; p.Value = releaseId; cmd.Parameters.Add(p);
            var result = await cmd.ExecuteScalarAsync(ct);
            return result is null || result == DBNull.Value ? 0 : Convert.ToInt32(result);
        }

        switch (def.EntityKey)
        {
            case "source-structure":
                {
                    preview.ExistingRowsInScope = await Count("SELECT COUNT(1) FROM GRAC_New.source_structure_node WHERE release_id=@rel AND status='Active'");
                    // External references — any of these being > 0 blocks Replace.
                    await AddBlocker(preview, "framework_statement",
                        "SELECT COUNT(1) FROM GRAC_New.framework_statement WHERE release_id=@rel AND status='Active'",
                        "framework_statement rows in this release reference source structure nodes",
                        conn, tx, releaseId, ct);
                    await AddBlocker(preview, "source_control_map",
                        "SELECT COUNT(1) FROM GRAC_New.source_control_map m JOIN GRAC_New.source_structure_node n ON n.structure_node_id=m.structure_node_id WHERE n.release_id=@rel AND m.status='Active'",
                        "source-control-map rows reference nodes in this release",
                        conn, tx, releaseId, ct);
                    await AddBlocker(preview, "obligation.structure_node_id",
                        "SELECT COUNT(1) FROM GRAC_New.obligation WHERE release_id=@rel AND structure_node_id IS NOT NULL AND status='Active'",
                        "obligation rows in this release reference structure nodes",
                        conn, tx, releaseId, ct);
                    break;
                }
            case "framework-statements":
                {
                    preview.ExistingRowsInScope = await Count("SELECT COUNT(1) FROM GRAC_New.framework_statement WHERE release_id=@rel AND status='Active'");
                    await AddBlocker(preview, "framework_statement_requirement_map",
                        "SELECT COUNT(1) FROM GRAC_New.framework_statement_requirement_map m JOIN GRAC_New.framework_statement fs ON fs.framework_statement_id=m.framework_statement_id WHERE fs.release_id=@rel AND m.status='Active'",
                        "practice→statement mapping rows reference statements in this release",
                        conn, tx, releaseId, ct);
                    await AddBlockerIfTableExists(preview, "obligation_requirement_release_map",
                        "SELECT COUNT(1) FROM GRAC_New.obligation_requirement_release_map m JOIN GRAC_New.framework_statement fs ON fs.framework_statement_id=m.framework_statement_id WHERE fs.release_id=@rel AND m.status='Active'",
                        "obligation mapping rows reference statements in this release",
                        conn, tx, releaseId, ct);
                    await AddBlocker(preview, "obligation.framework_statement_id",
                        "SELECT COUNT(1) FROM GRAC_New.obligation o JOIN GRAC_New.framework_statement fs ON fs.framework_statement_id=o.framework_statement_id WHERE fs.release_id=@rel AND o.status='Active'",
                        "obligation rows reference statements in this release",
                        conn, tx, releaseId, ct);
                    break;
                }
            // NB: 'obligations' Replace was removed post-019.  Obligation
            // Master is now a global entity with no release scope, so a
            // scoped-by-release replace no longer has meaning.
            case "source-control-mappings":
                {
                    preview.ExistingRowsInScope = await Count(
                        "SELECT COUNT(1) FROM GRAC_New.framework_statement_requirement_map m JOIN GRAC_New.framework_statement fs ON fs.framework_statement_id=m.framework_statement_id WHERE fs.release_id=@rel AND m.status='Active'");
                    // Deleting these mapping rows has no downstream refs.
                    break;
                }
            case "obligation-mappings":
                {
                    preview.ExistingRowsInScope = await CountIfTableExists(
                        "SELECT COUNT(1) FROM GRAC_New.obligation_requirement_release_map WHERE release_id=@rel AND status='Active'",
                        conn, tx, releaseId, ct);
                    break;
                }
        }

        preview.Blocked = preview.Blockers.Any(b => b.Count > 0);
        preview.Message = preview.Blocked
            ? $"Replace is blocked because {preview.Blockers.Count(b => b.Count > 0)} external reference(s) exist."
            : $"Replace will delete {preview.ExistingRowsInScope} existing row(s) in this scope, then insert new rows.";
        return preview;
    }

    private static async Task AddBlocker(ReplacePreview preview, string table, string sql, string reason, SqlConnection conn, SqlTransaction? tx, long releaseId, CancellationToken ct)
    {
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = sql;
        if (tx is not null) cmd.Transaction = tx;
        var p = cmd.CreateParameter(); p.ParameterName = "@rel"; p.Value = releaseId; cmd.Parameters.Add(p);
        var raw = await cmd.ExecuteScalarAsync(ct);
        var count = raw is null || raw == DBNull.Value ? 0 : Convert.ToInt32(raw);
        if (count > 0)
            preview.Blockers.Add(new ReplaceBlocker { Table = table, Count = count, Reason = $"{count} {reason}." });
    }

    private static async Task AddBlockerIfTableExists(ReplacePreview preview, string table, string sql, string reason, SqlConnection conn, SqlTransaction? tx, long releaseId, CancellationToken ct)
    {
        // Some tables (obligation_requirement_release_map) are added by later
        // migrations; if the table isn't present, skip the blocker rather
        // than throwing.
        var wrapped = $"IF OBJECT_ID('GRAC_New.{table}','U') IS NOT NULL {sql} ELSE SELECT CAST(0 AS INT);";
        await AddBlocker(preview, table, wrapped, reason, conn, tx, releaseId, ct);
    }

    private static async Task<int> CountIfTableExists(string sql, SqlConnection conn, SqlTransaction? tx, long releaseId, CancellationToken ct)
    {
        var wrapped = $"IF OBJECT_ID('GRAC_New.obligation_requirement_release_map','U') IS NOT NULL {sql} ELSE SELECT CAST(0 AS INT);";
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = wrapped;
        if (tx is not null) cmd.Transaction = tx;
        var p = cmd.CreateParameter(); p.ParameterName = "@rel"; p.Value = releaseId; cmd.Parameters.Add(p);
        var raw = await cmd.ExecuteScalarAsync(ct);
        return raw is null || raw == DBNull.Value ? 0 : Convert.ToInt32(raw);
    }

    // -------------------------- Delete within scope --------------------------
    private async Task<int> DeleteScopeAsync(SingleFormDefinition def, long releaseId, SqlConnection conn, SqlTransaction tx, string enteredBy, CancellationToken ct)
    {
        switch (def.EntityKey)
        {
            case "source-structure":
                {
                    // Delete children before parents so the self-FK
                    // (parent_node_id) does not block.
                    var totalDeleted = 0;
                    for (var pass = 0; pass < 50; pass++)
                    {
                        var deleted = await Exec(conn, tx, ct,
                            @"DELETE FROM GRAC_New.source_structure_node
                              WHERE release_id=@rel
                                AND structure_node_id NOT IN (
                                    SELECT parent_node_id FROM GRAC_New.source_structure_node
                                    WHERE release_id=@rel AND parent_node_id IS NOT NULL);
                              SELECT CAST(@@ROWCOUNT AS BIGINT);",
                            new() { ["@rel"] = releaseId });
                        totalDeleted += (int)deleted;
                        if (deleted == 0) break;
                    }
                    return totalDeleted;
                }
            case "framework-statements":
                return (int)await Exec(conn, tx, ct,
                    @"DELETE FROM GRAC_New.framework_statement WHERE release_id=@rel;
                      SELECT CAST(@@ROWCOUNT AS BIGINT);",
                    new() { ["@rel"] = releaseId });
            // NB: 'obligations' Replace was removed — post-019 the master is
            // global and the old (requirement_id, release_id) unique index
            // was dropped, so a scoped soft-retire no longer makes sense.
            case "source-control-mappings":
                return (int)await Exec(conn, tx, ct,
                    @"DELETE m FROM GRAC_New.framework_statement_requirement_map m
                      JOIN GRAC_New.framework_statement fs ON fs.framework_statement_id=m.framework_statement_id
                      WHERE fs.release_id=@rel;
                      SELECT CAST(@@ROWCOUNT AS BIGINT);",
                    new() { ["@rel"] = releaseId });
            case "obligation-mappings":
                return (int)await Exec(conn, tx, ct,
                    @"IF OBJECT_ID('GRAC_New.obligation_requirement_release_map','U') IS NOT NULL
                      BEGIN
                          DELETE FROM GRAC_New.obligation_requirement_release_map WHERE release_id=@rel;
                          SELECT CAST(@@ROWCOUNT AS BIGINT);
                      END
                      ELSE SELECT CAST(0 AS BIGINT);",
                    new() { ["@rel"] = releaseId });
            default:
                throw new InvalidOperationException($"Replace not implemented for {def.EntityKey}.");
        }
    }

    // ==========================================================================
    // Parsing + tamper checks
    // ==========================================================================
    private List<Dictionary<string, string?>> ParseWorkbook(SingleFormDefinition def, long? postedReleaseId, Stream file,
        out long contextReleaseId, out BulkUploadReport report)
    {
        report = new BulkUploadReport();
        contextReleaseId = 0;
        var rows = new List<Dictionary<string, string?>>();

        XLWorkbook wb;
        try { wb = new XLWorkbook(file); }
        catch (Exception ex)
        {
            report.Issues.Add(Issue(def, 0, "", "Unable to open the uploaded file. Please upload the exact template. Detail: " + ex.Message));
            return rows;
        }
        using (wb)
        {
            // -- Step 1: read the hidden signed context ---------------------
            if (!wb.Worksheets.TryGetWorksheet(ContextSheet, out var ctx))
            {
                report.Issues.Add(Issue(def, 0, "", "The workbook is missing its signed context. Re-download the template."));
                return rows;
            }
            var ctxEntity = ctx.Cell(1, 2).GetString()?.Trim() ?? "";
            // If the releaseId cell was blanked or replaced with non-numeric
            // text, treat it as 0 — the signature check below will catch the
            // tampering because 0 won't be what we signed.
            var ctxRelease = ParseLongSafe(ctx.Cell(2, 2).GetString()) ?? 0L;
            var ctxTimestamp = ctx.Cell(3, 2).GetString()?.Trim() ?? "";
            var ctxSignature = ctx.Cell(4, 2).GetString()?.Trim() ?? "";

            if (!ctxEntity.Equals(def.EntityKey, StringComparison.OrdinalIgnoreCase))
            {
                report.Issues.Add(Issue(def, 0, "entity", $"The uploaded template was generated for entity '{ctxEntity}', not '{def.EntityKey}'. Download a fresh template."));
                return rows;
            }
            if (def.ReleaseScoped)
            {
                if (!postedReleaseId.HasValue || postedReleaseId.Value <= 0)
                {
                    report.Issues.Add(Issue(def, 0, "release", "A Release must be selected for this form."));
                    return rows;
                }
                if (ctxRelease != postedReleaseId.Value)
                {
                    report.Issues.Add(Issue(def, 0, "release", "The Release selected does not match the template's signed context. Download a fresh template for the selected Release."));
                    return rows;
                }
            }
            else if (ctxRelease != 0)
            {
                report.Issues.Add(Issue(def, 0, "release", "This form is not release-scoped, but the template carries a Release. Download a fresh template."));
                return rows;
            }

            var expected = SignContext(BuildContextPayload(ctxEntity, ctxRelease, ctxTimestamp));
            if (!CryptographicEquals(expected, ctxSignature))
            {
                report.Issues.Add(Issue(def, 0, "signature", "The template's signed context has been tampered with. Download a fresh template and try again."));
                return rows;
            }
            contextReleaseId = ctxRelease;

            // -- Step 2: read the data sheet --------------------------------
            var dataSheetName = wb.Worksheets.First(w => !w.Name.Equals(ContextSheet, StringComparison.OrdinalIgnoreCase)).Name;
            if (!wb.Worksheets.TryGetWorksheet(dataSheetName, out var ws))
            {
                report.Issues.Add(Issue(def, 0, "", "Data sheet not found."));
                return rows;
            }

            // Rebuild the header set the template rendered so parsing lines
            // up with what was written (Release + ReleaseId prepend, then the
            // form's declared columns).
            var columns = new List<BulkColumn>();
            if (def.ReleaseScoped)
            {
                columns.Add(new BulkColumn("Release", "__releaseLabel", true, BulkColumnType.Text, 250));
                columns.Add(new BulkColumn("ReleaseId", "__releaseId", true, BulkColumnType.Integer, 0));
            }
            columns.AddRange(def.Columns);

            var headerRow = ws.Row(2);
            var lastHeaderCol = headerRow.LastCellUsed()?.Address.ColumnNumber ?? columns.Count;
            var headerMap = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (var col in columns)
            {
                var colIndex = -1;
                for (var c = 1; c <= lastHeaderCol; c++)
                {
                    var text = (headerRow.Cell(c).GetString() ?? "").Trim().TrimEnd('*').Trim();
                    if (text.Equals(col.Header, StringComparison.OrdinalIgnoreCase)) { colIndex = c; break; }
                }
                if (colIndex < 0)
                {
                    report.Issues.Add(Issue(def, 2, col.Header, $"Column '{col.Header}' is missing from the header row."));
                }
                else
                {
                    headerMap[col.PropertyName] = colIndex;
                }
            }
            if (report.Issues.Count > 0) return rows;

            var lastRow = ws.LastRowUsed()?.RowNumber() ?? 0;
            for (var r = 4; r <= lastRow; r++)
            {
                var record = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
                var hasAny = false;
                foreach (var col in columns)
                {
                    var cell = ws.Cell(r, headerMap[col.PropertyName]);
                    var raw = ReadCell(cell, col.Type);
                    if (!string.IsNullOrWhiteSpace(raw) && !col.PropertyName.StartsWith("__release")) hasAny = true;
                    record[col.PropertyName] = raw;
                }
                record["__row"] = r.ToString(CultureInfo.InvariantCulture);
                if (hasAny) rows.Add(record);
            }
            report.Sheets.Add(new BulkSheetSummary { SheetName = dataSheetName, TableLabel = def.DisplayName, TotalRows = rows.Count });
        }
        report.Success = true;
        return rows;
    }

    private void ValidateRows(SingleFormDefinition def, long contextReleaseId, List<Dictionary<string, string?>> rows, DbLookups lookups, BulkUploadReport report)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var summary = report.Sheets.FirstOrDefault();
        var valid = 0;
        var invalid = 0;

        foreach (var row in rows)
        {
            var rowNumber = int.Parse(row["__row"]!, CultureInfo.InvariantCulture);
            var before = report.Issues.Count;

            // Row-level ReleaseId anti-tamper: if the user edited row 4's
            // ReleaseId in Excel, the workbook could contain rows referring to
            // a different release than the context declares.  Reject those.
            if (def.ReleaseScoped)
            {
                var raw = row["__releaseId"];
                var idFromRow = ParseLongSafe(raw);
                if (idFromRow != contextReleaseId)
                    report.Issues.Add(Issue(def, rowNumber, "ReleaseId",
                        $"ReleaseId does not match the selected release ({contextReleaseId}). Do not edit the Release / ReleaseId columns."));
            }

            // Column-level checks.
            foreach (var col in def.Columns)
            {
                var value = row[col.PropertyName];
                if (col.Required && string.IsNullOrWhiteSpace(value))
                {
                    report.Issues.Add(Issue(def, rowNumber, col.Header, "Required value is missing."));
                    continue;
                }
                if (string.IsNullOrWhiteSpace(value)) continue;
                if (col.MaxLength > 0 && value!.Length > col.MaxLength)
                    report.Issues.Add(Issue(def, rowNumber, col.Header, $"Value exceeds maximum length of {col.MaxLength} characters."));
                if (col.Type == BulkColumnType.Integer && !long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out _))
                    report.Issues.Add(Issue(def, rowNumber, col.Header, "Expected a whole number."));
                if (col.Type == BulkColumnType.Decimal && !double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out _))
                    report.Issues.Add(Issue(def, rowNumber, col.Header, "Expected a number."));
                if (col.Type == BulkColumnType.Date && !DateTime.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out _))
                    report.Issues.Add(Issue(def, rowNumber, col.Header, "Expected a date in YYYY-MM-DD format."));
            }

            ValidateEntityReferences(def, contextReleaseId, row, rowNumber, lookups, seen, report);

            if (report.Issues.Count == before) valid++; else invalid++;
        }
        if (summary is not null) { summary.ValidRows = valid; summary.InvalidRows = invalid; }
    }

    private static void ValidateEntityReferences(SingleFormDefinition def, long releaseId, Dictionary<string, string?> row, int rowNumber, DbLookups lookups, HashSet<string> seen, BulkUploadReport report)
    {
        string? V(string k) => row.TryGetValue(k, out var v) ? v?.Trim() : null;
        void Add(string col, string msg) => report.Issues.Add(new BulkUploadIssue { Sheet = def.DisplayName, Row = rowNumber, Column = col, Message = msg });

        switch (def.EntityKey)
        {
            case "source-structure":
                {
                    var reference = V("nodeReference") ?? "";
                    if (!seen.Add(reference)) Add("nodeReference", "Duplicate nodeReference within this file.");
                    var existingKey = releaseId + "||" + reference.ToLowerInvariant();
                    if (lookups.NodeIdByKey.ContainsKey(existingKey))
                        Add("nodeReference", "nodeReference already exists in this release.");
                    var parent = V("parentNodeReference");
                    if (!string.IsNullOrWhiteSpace(parent))
                    {
                        var parentKey = releaseId + "||" + parent!.ToLowerInvariant();
                        if (!lookups.NodeIdByKey.ContainsKey(parentKey) && !seen.Contains(parent))
                            Add("parentNodeReference", $"parentNodeReference '{parent}' must exist in this release (in this file or the database).");
                    }
                    break;
                }
            case "framework-statements":
                {
                    var nodeRef = V("structureNodeReference") ?? "";
                    var nodeKey = releaseId + "||" + nodeRef.ToLowerInvariant();
                    if (!lookups.NodeIdByKey.ContainsKey(nodeKey))
                        Add("structureNodeReference", "structureNodeReference must exist in the selected release.");
                    var stmtRef = V("statementReference") ?? "";
                    if (!seen.Add(stmtRef)) Add("statementReference", "Duplicate statementReference within this file.");
                    var stmtKey = releaseId + "||" + stmtRef.ToLowerInvariant();
                    if (lookups.StatementIdByKey.ContainsKey(stmtKey))
                        Add("statementReference", "statementReference already exists in this release.");
                    var classification = V("classificationCode");
                    if (!string.IsNullOrWhiteSpace(classification))
                    {
                        var classKey = releaseId + "||" + classification!;
                        if (!lookups.ClassificationIdByKey.ContainsKey(classKey))
                            Add("classificationCode", $"classificationCode '{classification}' is not an active classification in this release.");
                    }
                    break;
                }
            case "requirements":
                {
                    var code = V("requirementCode") ?? "";
                    if (!seen.Add(code)) Add("requirementCode", "Duplicate requirementCode within this file.");
                    if (lookups.RequirementIdByCode.ContainsKey(code)) Add("requirementCode", "requirementCode already exists.");
                    break;
                }
            case "obligations":
                {
                    // Global master; only within-file name-duplicate check.
                    var name = V("obligationName") ?? "";
                    if (!seen.Add(name)) Add("obligationName", "Duplicate obligationName within this file. Rename one or Mapping/Evidence references will be ambiguous.");
                    var freq = V("executionFrequencyCode");
                    if (!string.IsNullOrWhiteSpace(freq) && !lookups.FrequencyIdByKey.ContainsKey(freq!))
                        Add("executionFrequencyCode", $"executionFrequencyCode '{freq}' is not an active option in reference_option (option_group='frequency-types').");
                    break;
                }
            case "obligation-evidence":
                {
                    var name = V("obligationName") ?? "";
                    var (found, ambiguous) = ResolveObligationRef(name, lookups);
                    if (!found) Add("obligationName", $"obligationName '{name}' does not match an existing active obligation.");
                    else if (ambiguous) Add("obligationName", $"obligationName '{name}' is ambiguous — more than one active obligation shares this name.");
                    var evCode = V("evidenceTypeCode") ?? "";
                    if (!lookups.EvidenceTypeIdByCode.ContainsKey(evCode))
                        Add("evidenceTypeCode", $"evidenceTypeCode '{evCode}' does not match an evidence_type_master row.");
                    var freq = V("assuranceFrequencyCode");
                    if (!string.IsNullOrWhiteSpace(freq) && !lookups.FrequencyIdByKey.ContainsKey(freq!))
                        Add("assuranceFrequencyCode", $"assuranceFrequencyCode '{freq}' is not an active option in reference_option (option_group='frequency-types').");
                    var key = name.ToLowerInvariant() + "||" + evCode.ToLowerInvariant() + "||" + (freq ?? "").ToLowerInvariant();
                    if (!seen.Add(key)) Add("evidenceTypeCode", "Duplicate (obligationName, evidenceTypeCode, assuranceFrequencyCode) within this file.");
                    break;
                }
            case "source-control-mappings":
                {
                    var stmtRef = V("statementReference") ?? "";
                    var stmtKey = releaseId + "||" + stmtRef.ToLowerInvariant();
                    if (!lookups.StatementIdByKey.ContainsKey(stmtKey))
                        Add("statementReference", "statementReference must exist in the selected release.");
                    var req = V("requirementCode") ?? "";
                    if (!lookups.RequirementIdByCode.ContainsKey(req))
                        Add("requirementCode", $"requirementCode '{req}' is not an existing active Practice.");
                    var uniqueKey = stmtKey + "||" + req;
                    if (!seen.Add(uniqueKey)) Add("requirementCode", "Duplicate (statementReference, requirementCode) within this file.");
                    break;
                }
            case "obligation-mappings":
                {
                    var name = V("obligationName") ?? "";
                    var (found, ambiguous) = ResolveObligationRef(name, lookups);
                    if (!found) Add("obligationName", $"obligationName '{name}' does not match an existing active obligation.");
                    else if (ambiguous) Add("obligationName", $"obligationName '{name}' is ambiguous — more than one active obligation shares this name.");
                    var targetReq = V("targetRequirementCode") ?? "";
                    if (!lookups.RequirementIdByCode.ContainsKey(targetReq))
                        Add("targetRequirementCode", $"targetRequirementCode '{targetReq}' is not an existing active Practice.");
                    var targetStmt = V("targetStatementReference");
                    if (!string.IsNullOrWhiteSpace(targetStmt))
                    {
                        var stmtKey = releaseId + "||" + targetStmt!.ToLowerInvariant();
                        if (!lookups.StatementIdByKey.ContainsKey(stmtKey))
                            Add("targetStatementReference", "targetStatementReference must exist in the selected (target) release.");
                    }
                    var uniqueKey = targetReq + "||" + releaseId + "||" + (targetStmt ?? "").ToLowerInvariant() + "||" + name.ToLowerInvariant();
                    if (!seen.Add(uniqueKey)) Add("obligationName", "Duplicate (targetRequirementCode, release, statement, obligation) within this file.");
                    break;
                }
        }
    }

    // Resolve obligationName against DB.  Ambiguous = >1 active DB rows share the name.
    private static (bool Found, bool Ambiguous) ResolveObligationRef(string name, DbLookups lookups)
    {
        if (string.IsNullOrWhiteSpace(name)) return (false, false);
        var count = lookups.ObligationNameCounts.GetValueOrDefault(name.Trim(), 0);
        return (count >= 1, count > 1);
    }

    // ==========================================================================
    // Insert
    // ==========================================================================
    private async Task<int> InsertAllAsync(SingleFormDefinition def, long releaseId, List<Dictionary<string, string?>> rows, DbLookups lookups, SqlConnection conn, SqlTransaction tx, string enteredBy, CancellationToken ct)
    {
        var count = 0;
        switch (def.EntityKey)
        {
            case "source-structure":
                {
                    // Wave loop so parent inserts land before children.
                    var pending = new List<Dictionary<string, string?>>(rows);
                    var newIds = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
                    var safety = 0;
                    while (pending.Count > 0 && safety++ < 20000)
                    {
                        var progressed = false;
                        for (var i = pending.Count - 1; i >= 0; i--)
                        {
                            var row = pending[i];
                            var parentRef = row["parentNodeReference"];
                            long? parentId = null;
                            if (!string.IsNullOrWhiteSpace(parentRef))
                            {
                                var pKey = releaseId + "||" + parentRef!.Trim().ToLowerInvariant();
                                if (lookups.NodeIdByKey.TryGetValue(pKey, out var existing)) parentId = existing;
                                else if (newIds.TryGetValue(parentRef!.Trim(), out var freshly)) parentId = freshly;
                                else continue;
                            }
                            var id = await Exec(conn, tx, ct,
                                @"INSERT INTO GRAC_New.source_structure_node(release_id,parent_node_id,node_level,node_type,node_reference,node_title,description,display_order,status,entered_by,entered_dt)
                                  VALUES(@rel,@parent,@level,@type,@ref,@title,@desc,@ord,'Active',@by,SYSUTCDATETIME());
                                  SELECT CAST(SCOPE_IDENTITY() AS BIGINT);",
                                new()
                                {
                                    ["@rel"] = releaseId,
                                    ["@parent"] = (object?)parentId ?? DBNull.Value,
                                    ["@level"] = ParseLongSafe(row["nodeLevel"]) ?? 1,
                                    ["@type"] = row["nodeType"],
                                    ["@ref"] = row["nodeReference"],
                                    ["@title"] = (object?)row["nodeTitle"] ?? DBNull.Value,
                                    ["@desc"] = (object?)row["description"] ?? DBNull.Value,
                                    ["@ord"] = ParseLongSafe(row["displayOrder"]) ?? 0,
                                    ["@by"] = enteredBy
                                });
                            newIds[(row["nodeReference"] ?? "").Trim()] = id;
                            pending.RemoveAt(i);
                            count++;
                            progressed = true;
                        }
                        if (!progressed) throw new InvalidOperationException("source-structure: unresolved parentNodeReference chain (circular or missing).");
                    }
                    break;
                }
            case "framework-statements":
                {
                    foreach (var row in rows)
                    {
                        var nodeRef = (row["structureNodeReference"] ?? "").Trim().ToLowerInvariant();
                        var nodeId = lookups.NodeIdByKey[releaseId + "||" + nodeRef];
                        long? classificationId = null;
                        var classification = row["classificationCode"];
                        if (!string.IsNullOrWhiteSpace(classification)
                            && lookups.ClassificationIdByKey.TryGetValue(releaseId + "||" + classification!.Trim(), out var cid))
                            classificationId = cid;
                        await Exec(conn, tx, ct,
                            @"INSERT INTO GRAC_New.framework_statement(release_id,structure_node_id,classification_id,statement_reference,statement_title,statement_text,statement_type,remarks,display_order,status,entered_by,entered_dt)
                              VALUES(@rel,@node,@class,@ref,@title,@text,@type,@rem,@ord,'Active',@by,SYSUTCDATETIME());
                              SELECT CAST(SCOPE_IDENTITY() AS BIGINT);",
                            new()
                            {
                                ["@rel"] = releaseId,
                                ["@node"] = nodeId,
                                ["@class"] = (object?)classificationId ?? DBNull.Value,
                                ["@ref"] = row["statementReference"],
                                ["@title"] = (object?)row["statementTitle"] ?? DBNull.Value,
                                ["@text"] = row["statementText"],
                                ["@type"] = (object?)row["statementType"] ?? DBNull.Value,
                                ["@rem"] = (object?)row["remarks"] ?? DBNull.Value,
                                ["@ord"] = ParseLongSafe(row["displayOrder"]) ?? 0,
                                ["@by"] = enteredBy
                            });
                        count++;
                    }
                    break;
                }
            case "requirements":
                {
                    foreach (var row in rows)
                    {
                        await Exec(conn, tx, ct,
                            @"INSERT INTO GRAC_New.requirement(requirement_code,requirement_name,requirement_statement,objective,keywords,status,entered_by,entered_dt)
                              VALUES(@code,@name,@stmt,@obj,@kw,'Active',@by,SYSUTCDATETIME());
                              SELECT CAST(SCOPE_IDENTITY() AS BIGINT);",
                            new()
                            {
                                ["@code"] = row["requirementCode"],
                                ["@name"] = row["requirementName"],
                                ["@stmt"] = row["requirementStatement"],
                                ["@obj"] = (object?)row["objective"] ?? DBNull.Value,
                                ["@kw"] = (object?)row["keywords"] ?? DBNull.Value,
                                ["@by"] = enteredBy
                            });
                        count++;
                    }
                    break;
                }
            case "obligations":
                {
                    // Global master (post-019).  frequency_type text column is
                    // populated as a cache of the resolved label so legacy UI
                    // reads keep working.
                    foreach (var row in rows)
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
                        await Exec(conn, tx, ct,
                            @"INSERT INTO GRAC_New.requirement_obligation(obligation_name,obligation_text,execution_frequency_id,frequency_type,retention_requirement,remarks,status,entered_by,entered_dt)
                              VALUES(@name,@text,@fid,@ftext,@ret,@rem,'Active',@by,SYSUTCDATETIME());
                              SELECT CAST(SCOPE_IDENTITY() AS BIGINT);",
                            new()
                            {
                                ["@name"] = row["obligationName"],
                                ["@text"] = (object?)row["obligationText"] ?? DBNull.Value,
                                ["@fid"] = (object?)freqId ?? DBNull.Value,
                                ["@ftext"] = (object?)freqLabel ?? DBNull.Value,
                                ["@ret"] = (object?)row["retentionRequirement"] ?? DBNull.Value,
                                ["@rem"] = (object?)row["remarks"] ?? DBNull.Value,
                                ["@by"] = enteredBy
                            });
                        count++;
                    }
                    break;
                }
            case "obligation-evidence":
                {
                    foreach (var row in rows)
                    {
                        var name = (row["obligationName"] ?? "").Trim();
                        var obligationId = lookups.ObligationIdByName[name];
                        var evId = lookups.EvidenceTypeIdByCode[(row["evidenceTypeCode"] ?? "").Trim()];
                        long? freqId = null;
                        var freq = row["assuranceFrequencyCode"];
                        if (!string.IsNullOrWhiteSpace(freq)
                            && lookups.FrequencyIdByKey.TryGetValue(freq!.Trim(), out var fid))
                            freqId = fid;
                        await Exec(conn, tx, ct,
                            @"INSERT INTO GRAC_New.requirement_obligation_evidence(obligation_id,evidence_type_id,frequency_id,retention_requirement,remarks,status,entered_by,entered_dt)
                              VALUES(@ob,@ev,@fq,@ret,@rem,'Active',@by,SYSUTCDATETIME());
                              SELECT CAST(SCOPE_IDENTITY() AS BIGINT);",
                            new()
                            {
                                ["@ob"] = obligationId,
                                ["@ev"] = evId,
                                ["@fq"] = (object?)freqId ?? DBNull.Value,
                                ["@ret"] = (object?)row["retentionRequirement"] ?? DBNull.Value,
                                ["@rem"] = (object?)row["remarks"] ?? DBNull.Value,
                                ["@by"] = enteredBy
                            });
                        count++;
                    }
                    break;
                }
            case "source-control-mappings":
                {
                    foreach (var row in rows)
                    {
                        var stmtRef = (row["statementReference"] ?? "").Trim().ToLowerInvariant();
                        var stmtId = lookups.StatementIdByKey[releaseId + "||" + stmtRef];
                        var reqId = lookups.RequirementIdByCode[(row["requirementCode"] ?? "").Trim()];
                        await Exec(conn, tx, ct,
                            @"INSERT INTO GRAC_New.framework_statement_requirement_map(framework_statement_id,requirement_id,status,entered_by,entered_dt)
                              VALUES(@stmt,@req,'Active',@by,SYSUTCDATETIME());
                              SELECT CAST(SCOPE_IDENTITY() AS BIGINT);",
                            new()
                            {
                                ["@stmt"] = stmtId,
                                ["@req"] = reqId,
                                ["@by"] = enteredBy
                            });
                        count++;
                    }
                    break;
                }
            case "obligation-mappings":
                {
                    foreach (var row in rows)
                    {
                        var name = (row["obligationName"] ?? "").Trim();
                        var obligationId = lookups.ObligationIdByName[name];
                        var targetReq = lookups.RequirementIdByCode[(row["targetRequirementCode"] ?? "").Trim()];
                        long? statementId = null;
                        var targetStmt = row["targetStatementReference"];
                        if (!string.IsNullOrWhiteSpace(targetStmt)
                            && lookups.StatementIdByKey.TryGetValue(releaseId + "||" + targetStmt!.Trim().ToLowerInvariant(), out var sid))
                            statementId = sid;
                        await Exec(conn, tx, ct,
                            @"IF OBJECT_ID('GRAC_New.obligation_requirement_release_map','U') IS NOT NULL
                              BEGIN
                                  INSERT INTO GRAC_New.obligation_requirement_release_map(obligation_id,requirement_id,release_id,framework_statement_id,status,entered_by,entered_dt)
                                  VALUES(@ob,@req,@rel,@stmt,'Active',@by,SYSUTCDATETIME());
                                  SELECT CAST(SCOPE_IDENTITY() AS BIGINT);
                              END
                              ELSE SELECT CAST(0 AS BIGINT);",
                            new()
                            {
                                ["@ob"] = obligationId,
                                ["@req"] = targetReq,
                                ["@rel"] = releaseId,
                                ["@stmt"] = (object?)statementId ?? DBNull.Value,
                                ["@by"] = enteredBy
                            });
                        count++;
                    }
                    break;
                }
        }
        return count;
    }

    // ==========================================================================
    // Helpers
    // ==========================================================================
    private static BulkUploadReport Fail(string message) =>
        new() { Success = false, Message = message };

    private static BulkUploadIssue Issue(SingleFormDefinition def, int row, string column, string message) =>
        new() { Sheet = def.DisplayName, Row = row, Column = column, Message = message };

    private static long? ParseLongSafe(string? value) =>
        long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : null;

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

    private static async Task<long> Exec(SqlConnection conn, SqlTransaction tx, CancellationToken ct, string sql, Dictionary<string, object?> parameters)
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

    // --------- Signing ------------------------------------------------------
    private string GetSigningKey()
    {
        // Reuse the same secret used elsewhere for signed access tokens. This
        // is fine — it's a HMAC key, and we're only signing template context
        // (entity + releaseId + timestamp), not exchanging it with anyone.
        var key = configuration["Security:BulkUploadSigningKey"];
        if (string.IsNullOrWhiteSpace(key)) key = configuration["Security:TokenSigningKey"];
        if (string.IsNullOrWhiteSpace(key))
            throw new InvalidOperationException("Security:TokenSigningKey (or Security:BulkUploadSigningKey) must be configured.");
        return key;
    }

    private static string BuildContextPayload(string entity, long releaseId, string timestamp) =>
        $"entity={entity}|releaseId={releaseId}|timestampUtc={timestamp}";

    private string SignContext(string payload)
    {
        using var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(GetSigningKey()));
        var bytes = hmac.ComputeHash(Encoding.UTF8.GetBytes(payload));
        return Convert.ToBase64String(bytes);
    }

    private static bool CryptographicEquals(string a, string b)
    {
        // Constant-time compare of the base64 signatures using
        // CryptographicOperations.FixedTimeEquals to prevent timing side
        // channels.  Length mismatch is not a secret so returning early is OK.
        if (string.IsNullOrEmpty(a) || string.IsNullOrEmpty(b)) return false;
        var aBytes = Encoding.UTF8.GetBytes(a);
        var bBytes = Encoding.UTF8.GetBytes(b);
        return aBytes.Length == bBytes.Length && CryptographicOperations.FixedTimeEquals(aBytes, bBytes);
    }

    private async Task<SingleFormReleaseOption?> FindReleaseAsync(long releaseId, CancellationToken ct)
    {
        await using var conn = OpenConnection();
        await conn.OpenAsync(ct);
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
            SELECT r.release_id, a.artifact_code, a.artifact_name, r.version_no, au.authority_name, r.status
            FROM GRAC_New.release r
            JOIN GRAC_New.artifact a ON a.artifact_id = r.artifact_id
            JOIN GRAC_New.authority au ON au.authority_id = a.authority_id
            WHERE r.release_id=@id AND r.status IN ('Draft','Active')";
        var p = cmd.CreateParameter();
        p.ParameterName = "@id";
        p.Value = releaseId;
        cmd.Parameters.Add(p);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return null;
        var artifactCode = reader.GetString(1);
        var versionNo    = reader.GetString(3);
        return new SingleFormReleaseOption(
            reader.GetInt64(0),
            artifactCode,
            reader.GetString(2),
            versionNo,
            reader.GetString(4),
            $"{artifactCode} / {versionNo}",
            reader.GetString(5));
    }

    // --------- Lookups ------------------------------------------------------
    private async Task<DbLookups> LoadLookupsAsync(SqlConnection conn, CancellationToken ct)
    {
        var lk = new DbLookups();
        async Task Read(string sql, Action<SqlDataReader> apply)
        {
            await using var cmd = conn.CreateCommand();
            cmd.CommandText = sql;
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct)) apply(reader);
        }

        await Read(@"SELECT n.structure_node_id,n.release_id,n.node_reference
                     FROM GRAC_New.source_structure_node n WHERE n.status='Active'", r =>
        {
            var key = r.GetInt64(1) + "||" + r.GetString(2).ToLowerInvariant();
            lk.NodeIdByKey[key] = r.GetInt64(0);
        });
        await Read(@"SELECT sc.statement_classification_id, sc.release_id, sc.classification_code
                     FROM GRAC_New.statement_classification sc WHERE sc.status='Active'", r =>
        {
            lk.ClassificationIdByKey[r.GetInt64(1) + "||" + r.GetString(2)] = r.GetInt64(0);
        });
        await Read(@"SELECT fs.framework_statement_id, fs.release_id, fs.statement_reference
                     FROM GRAC_New.framework_statement fs WHERE fs.status='Active'", r =>
        {
            lk.StatementIdByKey[r.GetInt64(1) + "||" + r.GetString(2).ToLowerInvariant()] = r.GetInt64(0);
        });
        await Read("SELECT requirement_id,requirement_code FROM GRAC_New.requirement WHERE status='Active'", r =>
        {
            lk.RequirementIdByCode[r.GetString(1)] = r.GetInt64(0);
        });
        // Obligation Master is GLOBAL post-019.  Look up by obligation_name;
        // per-name count feeds the ambiguity detector.
        await Read("SELECT obligation_id, obligation_name FROM GRAC_New.requirement_obligation WHERE status='Active' AND obligation_name IS NOT NULL", r =>
        {
            var name = r.GetString(1).Trim();
            if (name.Length == 0) return;
            lk.ObligationIdByName[name] = r.GetInt64(0);
            lk.ObligationNameCounts[name] = lk.ObligationNameCounts.GetValueOrDefault(name, 0) + 1;
        });
        // Frequency options (reference_option): user may type either
        // option_value or option_label; both resolve to the same id.
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
        public Dictionary<string, long> NodeIdByKey { get; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, long> ClassificationIdByKey { get; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, long> StatementIdByKey { get; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, long> RequirementIdByCode { get; } = new(StringComparer.OrdinalIgnoreCase);

        // Obligation Master (global, post-019) — name is the display key,
        // may not be unique; count feeds ambiguity detection.
        public Dictionary<string, long> ObligationIdByName { get; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, int>  ObligationNameCounts { get; } = new(StringComparer.OrdinalIgnoreCase);

        // reference_option (frequency-types) and evidence_type_master.
        public Dictionary<string, long> FrequencyIdByKey { get; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<long, string> FrequencyLabelById { get; } = new();
        public Dictionary<string, int>  EvidenceTypeIdByCode { get; } = new(StringComparer.OrdinalIgnoreCase);
    }

    // --------- Connection ---------------------------------------------------
    private SqlConnection OpenConnection()
    {
        var cs = GetConnectionString()
            ?? throw new InvalidOperationException("Configure ConnectionStrings:ControlManagement or the GRAC DbConnection/Password settings before using single-form upload.");
        var b = new SqlConnectionStringBuilder(cs)
        {
            Encrypt = configuration.GetValue("Database:Encrypt", true),
            TrustServerCertificate = configuration.GetValue("Database:TrustServerCertificate", false)
        };
        return new SqlConnection(b.ConnectionString);
    }

    private string? GetConnectionString()
    {
        var cs = configuration.GetConnectionString("ControlManagement");
        if (!string.IsNullOrWhiteSpace(cs)) return cs;
        var grac = configuration.GetConnectionString("DbConnection");
        var pwd = configuration.GetConnectionString("Password");
        if (string.IsNullOrWhiteSpace(grac) || string.IsNullOrWhiteSpace(pwd)) return null;
        var parts = pwd.Split('~', 2);
        if (parts.Length != 2) throw new InvalidOperationException("ConnectionStrings:Password must contain the GRAC encryption key and encrypted password.");
        return grac + DecryptPassword(parts[1], parts[0]);
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
}
