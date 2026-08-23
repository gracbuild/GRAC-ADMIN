namespace ControlManagement.Api.Models;

// -----------------------------------------------------------------------------
// Bulk Upload payload contracts.
// The bulk uploader accepts a single multi-sheet Excel workbook that carries
// data for eight repository areas: Authority, Artifact, Release,
// SourceStructure, SourceStatement, PracticeObligation,
// PracticeSourceStatementMapping and PracticeObligationMapping.
//
// Validation reports (Success == false) never touch the database; commits
// (Success == true) run inside a single transaction and roll back on any
// failure so the workbook is either fully accepted or fully rejected.
// -----------------------------------------------------------------------------

public sealed class BulkUploadReport
{
    public bool Success { get; set; }
    public string Message { get; set; } = "";
    public List<BulkSheetSummary> Sheets { get; set; } = new();
    public List<BulkUploadIssue> Issues { get; set; } = new();
    public Dictionary<string, int> InsertedCounts { get; set; } = new();
}

public sealed class BulkSheetSummary
{
    public string SheetName { get; set; } = "";
    public string TableLabel { get; set; } = "";
    public int TotalRows { get; set; }
    public int ValidRows { get; set; }
    public int InvalidRows { get; set; }
}

public sealed class BulkUploadIssue
{
    public string Sheet { get; set; } = "";
    public int Row { get; set; }
    public string Column { get; set; } = "";
    public string Message { get; set; } = "";
}

// -----------------------------------------------------------------------------
// Replace-mode preview: how many rows would be deleted from the target scope,
// and how many external references block the Replace.  If Blocked == true,
// the UI must not offer a Commit button.  Blockers lists the human-readable
// reasons ("N framework_statement rows in this release reference these
// nodes").
// -----------------------------------------------------------------------------
public sealed class ReplacePreview
{
    public bool Allowed { get; set; }
    public bool Blocked { get; set; }
    public string EntityKey { get; set; } = "";
    public string DisplayName { get; set; } = "";
    public long ReleaseId { get; set; }
    public string ReleaseCode { get; set; } = "";
    public string ReleaseLabel { get; set; } = "";
    public int ExistingRowsInScope { get; set; }
    public List<ReplaceBlocker> Blockers { get; set; } = new();
    public string DeleteStrategy { get; set; } = "";   // "HardDelete" | "SoftRetire" | "NotAllowed"
    public string Message { get; set; } = "";
}

public sealed class ReplaceBlocker
{
    public string Table { get; set; } = "";
    public int Count { get; set; }
    public string Reason { get; set; } = "";
}
