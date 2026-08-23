namespace ControlManagement.Api.Services;

// -----------------------------------------------------------------------------
// Single-Form Upload schema.
//
// Unlike the multi-sheet workbook upload, the single-form flow lets an admin
// pick one entity + (optionally) a Release, download a lean template scoped
// to that release, and upload only that one form.
//
// Every release-scoped template carries two read-only helper columns as the
// first two columns:
//   * Release       -> the human label (artifactCode / versionNo), so the
//                       reader knows what release they are filling for.
//   * ReleaseId     -> the numeric BIGINT release_id, auto-filled by the
//                       server.  It is verified against a signed context
//                       sheet at commit time so it cannot be silently
//                       retargeted.
//
// The metadata sheet '__context__' carries entity + releaseId + a UTC
// timestamp + a HMAC signature.  Any tampering (edited ReleaseId, edited
// entity, edited timestamp, replaced signature) is rejected on commit.
// -----------------------------------------------------------------------------

public enum ReplaceStrategy
{
    NotAllowed,   // Practices - global master, too many downstream refs
    HardDelete,   // Structure / Statement / Mapping tables
    SoftRetire    // Obligations - partial unique index allows soft-delete + insert
}

public sealed record SingleFormDefinition(
    string EntityKey,
    string DisplayName,
    string PermissionArea,
    bool ReleaseScoped,
    string Instructions,
    BulkColumn[] Columns,
    ReplaceStrategy ReplaceStrategy = ReplaceStrategy.NotAllowed);

public static class SingleFormUploadSchema
{
    public static readonly SingleFormDefinition[] Forms =
    [
        new SingleFormDefinition("source-structure", "Source Structure", "source-structure", true,
            "Add source-structure nodes to the selected Release. parentNodeReference must either be blank (root) or match nodeReference of another row in this file or an existing active node in the same release.",
            new BulkColumn[]
            {
                new("parentNodeReference","parentNodeReference",false,BulkColumnType.Text,160,"Blank for root nodes; otherwise nodeReference of another row/existing node in the same release."),
                new("nodeLevel",           "nodeLevel",          true, BulkColumnType.Integer,0,  "1 for top-level; increment by 1 per depth."),
                new("nodeType",            "nodeType",           true, BulkColumnType.Text,100,  "e.g. Chapter, Section, Clause."),
                new("nodeReference",       "nodeReference",      true, BulkColumnType.Text,160,  "Unique within a release."),
                new("nodeTitle",           "nodeTitle",          false,BulkColumnType.Text,500),
                new("description",         "description",        false,BulkColumnType.Text,4000),
                new("displayOrder",        "displayOrder",       false,BulkColumnType.Integer,0)
            }, ReplaceStrategy.HardDelete),

        new SingleFormDefinition("framework-statements", "Source Statement", "framework-statements", true,
            "Add source (framework) statements to the selected Release. structureNodeReference must exist in the selected release.",
            new BulkColumn[]
            {
                new("structureNodeReference","structureNodeReference",true, BulkColumnType.Text,160,  "Must match a source-structure nodeReference in this release."),
                new("classificationCode",    "classificationCode",    false,BulkColumnType.Text,80,   "Optional. Must match an active classification in this release when provided."),
                new("statementReference",    "statementReference",    true, BulkColumnType.Text,160,  "Unique within this release."),
                new("statementTitle",        "statementTitle",        false,BulkColumnType.Text,500),
                new("statementText",         "statementText",         true, BulkColumnType.Text,4000),
                new("statementType",         "statementType",         false,BulkColumnType.Text,100),
                new("remarks",               "remarks",               false,BulkColumnType.Text,4000),
                new("displayOrder",          "displayOrder",          false,BulkColumnType.Integer,0)
            }, ReplaceStrategy.HardDelete),

        new SingleFormDefinition("requirements", "Practices", "requirements", false,
            "Add Practices (Requirements). requirementCode is a global unique code across all releases.",
            new BulkColumn[]
            {
                new("requirementCode",     "requirementCode",     true, BulkColumnType.Text,100,"Unique across all practices."),
                new("requirementName",     "requirementName",     true, BulkColumnType.Text,300),
                new("requirementStatement","requirementStatement",true, BulkColumnType.Text,4000),
                new("objective",           "objective",           false,BulkColumnType.Text,4000),
                new("keywords",            "keywords",            false,BulkColumnType.Text,4000,"Comma-separated.")
            }),

        // Obligation Master is GLOBAL post-migration-019.  obligationName is
        // the display key; it need not be unique in the DB, but if it
        // collides with another Active obligation the Mapping / Evidence
        // referencing sheets will refuse to resolve it.
        new SingleFormDefinition("obligations", "Obligation Master", "obligations", false,
            "Global Obligation Master (post-019 shape). obligationName is the display key. executionFrequencyCode resolves against reference_option WHERE option_group='frequency-types'.",
            new BulkColumn[]
            {
                new("obligationName",         "obligationName",         true,  BulkColumnType.Text, 500,  "Display key; keep unique across the DB to avoid ambiguity in mapping/evidence."),
                new("obligationText",         "obligationText",         false, BulkColumnType.Text, 4000, "Long-form description (legacy column, still populated)."),
                new("executionFrequencyCode", "executionFrequencyCode", false, BulkColumnType.Text, 100,  "Optional. option_value OR option_label from reference_option WHERE option_group='frequency-types'."),
                new("retentionRequirement",   "retentionRequirement",   false, BulkColumnType.Text, 250),
                new("remarks",                "remarks",                false, BulkColumnType.Text, 4000)
            }, ReplaceStrategy.NotAllowed),

        new SingleFormDefinition("obligation-evidence", "Obligation Evidence Types", "obligations", false,
            "Evidence types attached to an existing Obligation. Uniqueness: (obligationName, evidenceTypeCode, assuranceFrequencyCode) among active rows.",
            new BulkColumn[]
            {
                new("obligationName",         "obligationName",         true,  BulkColumnType.Text, 500, "Must resolve to exactly one active obligation by name."),
                new("evidenceTypeCode",       "evidenceTypeCode",       true,  BulkColumnType.Text, 60,  "Must match evidence_type_master.evidence_type_code."),
                new("assuranceFrequencyCode", "assuranceFrequencyCode", false, BulkColumnType.Text, 100, "Optional. option_value OR option_label from reference_option WHERE option_group='frequency-types'."),
                new("retentionRequirement",   "retentionRequirement",   false, BulkColumnType.Text, 250),
                new("remarks",                "remarks",                false, BulkColumnType.Text, 4000)
            }, ReplaceStrategy.NotAllowed),

        new SingleFormDefinition("source-control-mappings", "Practice - Source Statement Mapping", "source-control-mappings", true,
            "Map an existing Practice to a Source Statement in the selected Release. (statementReference, requirementCode) must be unique.",
            new BulkColumn[]
            {
                new("statementReference","statementReference",true,BulkColumnType.Text,160,"Must exist in the selected release."),
                new("requirementCode",   "requirementCode",   true,BulkColumnType.Text,100,"Existing active Practice code.")
            }, ReplaceStrategy.HardDelete),

        new SingleFormDefinition("obligation-mappings", "Practice Obligation Mapping", "obligation-mappings", true,
            "Map an existing Obligation (by name) onto (target release, target practice, optional target source statement). Uniqueness (active): (requirement, release, statement, obligation). The Release dropdown selects the TARGET release.",
            new BulkColumn[]
            {
                new("obligationName",        "obligationName",        true, BulkColumnType.Text, 500,"Obligation master name. Rejected if ambiguous."),
                new("targetRequirementCode", "targetRequirementCode", true, BulkColumnType.Text, 100,"Existing Practice code."),
                new("targetStatementReference","targetStatementReference",false,BulkColumnType.Text,160,"Optional Source Statement scope inside the target release.")
            }, ReplaceStrategy.HardDelete)
    ];

    public static SingleFormDefinition? Find(string entityKey) =>
        Array.Find(Forms, f => f.EntityKey.Equals(entityKey, StringComparison.OrdinalIgnoreCase));
}
