namespace ControlManagement.Api.Services;

// -----------------------------------------------------------------------------
// Declarative sheet schema for the bulk upload workbook.
// One entry per business table: sheet name, friendly label, and column
// definitions (header text, required flag, data type hint, help text).  The
// same declarations drive both template generation and upload validation so
// the two paths cannot drift out of sync.
// -----------------------------------------------------------------------------

public enum BulkColumnType { Text, Integer, Decimal, Date, Boolean }

public sealed record BulkColumn(
    string Header,
    string PropertyName,
    bool Required,
    BulkColumnType Type = BulkColumnType.Text,
    int MaxLength = 0,
    string Help = "",
    string[]? AllowedValues = null);

public sealed record BulkSheet(
    string SheetName,
    string TableLabel,
    string EntityKey,
    string Instructions,
    BulkColumn[] Columns);

public static class BulkUploadSchema
{
    // Sheet order matters at commit time — parent rows must be inserted before
    // their children so foreign-key lookups can find them.
    public static readonly BulkSheet[] Sheets =
    [
        new BulkSheet("Authority", "Authority", "authorities",
            "One row per issuing/regulatory body. authorityCode must be unique.",
            new BulkColumn[]
            {
                new("authorityCode",   "authorityCode",   true,  BulkColumnType.Text, 80,  "Unique short code, e.g. 'RBI'."),
                new("authorityName",   "authorityName",   true,  BulkColumnType.Text, 250, "Full display name."),
                new("description",     "description",     false, BulkColumnType.Text, 4000),
                new("jurisdiction",    "jurisdiction",    false, BulkColumnType.Text, 160),
                new("website",         "website",         false, BulkColumnType.Text, 500)
            }),

        new BulkSheet("Artifact", "Artifact", "artifacts",
            "One row per regulation/standard/directive. authorityCode must exist in Authority sheet or database.",
            new BulkColumn[]
            {
                new("authorityCode",   "authorityCode",   true,  BulkColumnType.Text, 80,  "Must match an Authority row in this file or an active authority in the database."),
                new("artifactCode",    "artifactCode",    true,  BulkColumnType.Text, 100, "Unique across all artifacts."),
                new("artifactName",    "artifactName",    true,  BulkColumnType.Text, 300),
                new("description",     "description",     false, BulkColumnType.Text, 4000),
                new("artifactCategory","artifactCategory",true,  BulkColumnType.Text, 80),
                new("industry",        "industry",        false, BulkColumnType.Text, 160),
                new("jurisdiction",    "jurisdiction",    false, BulkColumnType.Text, 160)
            }),

        new BulkSheet("Release", "Release Source", "releases",
            "Versioned publications under an Artifact. (artifactCode, versionNo) must be unique.",
            new BulkColumn[]
            {
                new("artifactCode", "artifactCode", true,  BulkColumnType.Text, 100, "Existing or newly-added Artifact code."),
                new("versionNo",    "versionNo",    true,  BulkColumnType.Text, 80),
                new("effectiveDate","effectiveDate",false, BulkColumnType.Date,  0,   "YYYY-MM-DD."),
                new("endDate",      "endDate",      false, BulkColumnType.Date,  0,   "YYYY-MM-DD (leave blank if open)."),
                new("releaseNotes", "releaseNotes", false, BulkColumnType.Text, 4000)
            }),

        new BulkSheet("SourceStructure", "Source Structure", "source-structure",
            "Native hierarchy of the release. parentNodeReference (if provided) must match nodeReference of another row in the same release.",
            new BulkColumn[]
            {
                new("artifactCode",        "artifactCode",        true,  BulkColumnType.Text,    100),
                new("versionNo",           "versionNo",           true,  BulkColumnType.Text,    80,  "Combined with artifactCode identifies the release."),
                new("parentNodeReference", "parentNodeReference", false, BulkColumnType.Text,    160, "Blank for root nodes; otherwise must match another nodeReference in the same release."),
                new("nodeLevel",           "nodeLevel",           true,  BulkColumnType.Integer, 0,   "1 for top-level; increase by 1 per depth."),
                new("nodeType",            "nodeType",            true,  BulkColumnType.Text,    100, "e.g. Chapter, Section, Clause."),
                new("nodeReference",       "nodeReference",       true,  BulkColumnType.Text,    160, "Unique within a release."),
                new("nodeTitle",           "nodeTitle",           false, BulkColumnType.Text,    500),
                new("description",         "description",         false, BulkColumnType.Text,    4000),
                new("displayOrder",        "displayOrder",        false, BulkColumnType.Integer, 0)
            }),

        new BulkSheet("SourceStatement", "Source Statement", "framework-statements",
            "Regulatory statements captured under source structure nodes. statementReference is unique within a release.",
            new BulkColumn[]
            {
                new("artifactCode",           "artifactCode",           true,  BulkColumnType.Text,    100),
                new("versionNo",              "versionNo",              true,  BulkColumnType.Text,    80),
                new("structureNodeReference", "structureNodeReference", true,  BulkColumnType.Text,    160, "Must match a nodeReference in the same release (from SourceStructure)."),
                new("classificationCode",     "classificationCode",     false, BulkColumnType.Text,    80,  "Optional. Must match an existing classification in the release when provided."),
                new("statementReference",     "statementReference",     true,  BulkColumnType.Text,    160),
                new("statementTitle",         "statementTitle",         false, BulkColumnType.Text,    500),
                new("statementText",          "statementText",          true,  BulkColumnType.Text,    4000),
                new("statementType",          "statementType",          false, BulkColumnType.Text,    100),
                new("remarks",                "remarks",                false, BulkColumnType.Text,    4000),
                new("displayOrder",           "displayOrder",           false, BulkColumnType.Integer, 0)
            }),

        new BulkSheet("Practice", "Practice (Requirement)", "requirements",
            "Global Practices master. requirementCode is unique across all releases.",
            new BulkColumn[]
            {
                new("requirementCode",     "requirementCode",     true,  BulkColumnType.Text, 100, "Unique across all Practices."),
                new("requirementName",     "requirementName",     true,  BulkColumnType.Text, 300),
                new("requirementStatement","requirementStatement",true,  BulkColumnType.Text, 4000),
                new("objective",           "objective",           false, BulkColumnType.Text, 4000),
                new("keywords",            "keywords",            false, BulkColumnType.Text, 4000, "Comma-separated.")
            }),

        // ---------------------------------------------------------------------
        // Migration 019 decoupled the Obligation Master from (Requirement,
        // Release).  A row here inserts one Obligation into
        // requirement_obligation with no legacy scope columns; mappings and
        // evidence live in their own sheets below.
        // ---------------------------------------------------------------------
        new BulkSheet("Obligation", "Obligation Master", "obligations",
            "Global Obligation master (post-019 shape). obligationName is the display key and should be unique across the workbook and the database.",
            new BulkColumn[]
            {
                new("obligationName",         "obligationName",         true,  BulkColumnType.Text, 500,  "Unique display key. If more than one active obligation exists with the same name (in file or DB), mapping/evidence rows referencing it will be rejected as ambiguous."),
                new("obligationText",         "obligationText",         false, BulkColumnType.Text, 4000, "Obligation Description. Shown and edited on the Obligation Master screen since migration 055; before that the save path overwrote it with obligationName."),
                new("executionFrequencyCode", "executionFrequencyCode", false, BulkColumnType.Text, 100,  "Optional. Match option_value OR option_label from reference_option WHERE option_group='frequency-types'."),
                new("retentionRequirement",   "retentionRequirement",   false, BulkColumnType.Text, 250),
                new("remarks",                "remarks",                false, BulkColumnType.Text, 4000)
            }),

        new BulkSheet("ObligationEvidence", "Obligation Evidence Types", "obligations",
            "Evidence types attached to an Obligation. Uniqueness: (obligationName, evidenceTypeCode, assuranceFrequencyCode) — same evidence type may repeat under one obligation when the frequency differs.",
            new BulkColumn[]
            {
                new("obligationName",         "obligationName",         true,  BulkColumnType.Text, 500, "Must match an obligationName in the Obligation sheet OR an existing active obligation in the DB. Must be unambiguous."),
                new("evidenceTypeCode",       "evidenceTypeCode",       true,  BulkColumnType.Text, 60,  "Must match evidence_type_master.evidence_type_code."),
                new("assuranceFrequencyCode", "assuranceFrequencyCode", false, BulkColumnType.Text, 100, "Optional. Match option_value OR option_label from reference_option WHERE option_group='frequency-types'."),
                new("retentionRequirement",   "retentionRequirement",   false, BulkColumnType.Text, 250),
                new("remarks",                "remarks",                false, BulkColumnType.Text, 4000)
            }),

        new BulkSheet("PracticeSourceStatementMapping", "Practice - Source Statement Mapping", "source-control-mappings",
            "Map an existing Practice (requirement) to a Source Statement in a release. (statement, requirement) must be unique.",
            new BulkColumn[]
            {
                new("artifactCode",       "artifactCode",       true, BulkColumnType.Text, 100),
                new("versionNo",          "versionNo",          true, BulkColumnType.Text, 80),
                new("statementReference", "statementReference", true, BulkColumnType.Text, 160, "Must match a statementReference in the same release."),
                new("requirementCode",    "requirementCode",    true, BulkColumnType.Text, 100, "Must match an existing active Practice/Requirement.")
            }),

        new BulkSheet("PracticeObligationMapping", "Practice Obligation Mapping", "obligation-mappings",
            "Map an Obligation (by name) onto a Practice + Release combination, optionally scoped to a Source Statement. Uniqueness: (requirementCode, release, statementReference, obligationName) - active rows.",
            new BulkColumn[]
            {
                new("obligationName",       "obligationName",       true, BulkColumnType.Text, 500, "Obligation master name. Rejected if ambiguous."),
                new("targetRequirementCode","targetRequirementCode",true, BulkColumnType.Text, 100, "Existing Practice/Requirement code."),
                new("targetArtifactCode",   "targetArtifactCode",   true, BulkColumnType.Text, 100),
                new("targetVersionNo",      "targetVersionNo",      true, BulkColumnType.Text, 80),
                new("targetStatementReference","targetStatementReference",false, BulkColumnType.Text, 160, "Optional Source Statement scope inside the target release.")
            })
    ];

    public static BulkSheet? FindByEntity(string entityKey) =>
        Array.Find(Sheets, s => s.EntityKey.Equals(entityKey, StringComparison.OrdinalIgnoreCase));
}
