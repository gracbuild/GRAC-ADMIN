using System.Text.Json;

namespace ControlManagement.Api.Models;

public sealed class RepositoryQuery
{
    public string EntityType { get; set; } = "";
    public int? Id { get; set; }
    public string Search { get; set; } = "";
    public string Status { get; set; } = "";
    public string Module { get; set; } = "";
    public string ActionType { get; set; } = "";
    public int? AuthorityId { get; set; }
    public int? ArtifactId { get; set; }
    public int? ReleaseId { get; set; }
    public int? ControlId { get; set; }
    public int? RequirementId { get; set; }
    public int? FrameworkStatementId { get; set; }
    public int? DomainId { get; set; }
    public int? Page { get; set; }
    public int? PageSize { get; set; }
    public JsonElement? Filters { get; set; }
}

public sealed class RepositoryCommand
{
    public string EntityType { get; set; } = "";
    public string Action { get; set; } = "SAVE";
    public int? Id { get; set; }
    public string EnteredBy { get; set; } = "";
    public JsonElement Data { get; set; }
}

public sealed record RepositoryResult(bool Success, string Message, object? Data = null);

public sealed class Authority { public long AuthorityId { get; set; } public string AuthorityName { get; set; } = ""; public string Status { get; set; } = ""; }
public sealed class RegulatoryArtifact { public long ArtifactId { get; set; } public long AuthorityId { get; set; } public string ArtifactName { get; set; } = ""; public string ArtifactCategory { get; set; } = ""; }
public sealed class RegulatoryRelease { public long ReleaseId { get; set; } public long ArtifactId { get; set; } public string VersionNo { get; set; } = ""; public string Status { get; set; } = ""; }
public sealed class SourceStructureNode { public long StructureNodeId { get; set; } public long ReleaseId { get; set; } public long? ParentNodeId { get; set; } public string NodeType { get; set; } = ""; public string NodeReference { get; set; } = ""; }
public sealed class Control { public long ControlId { get; set; } public string ControlCode { get; set; } = ""; public string ControlName { get; set; } = ""; public string Status { get; set; } = ""; }
public sealed class Requirement { public long RequirementId { get; set; } public string RequirementCode { get; set; } = ""; public string RequirementStatement { get; set; } = ""; }
public sealed class Obligation { public long ObligationId { get; set; } public long RequirementId { get; set; } public long ReleaseId { get; set; } public bool MandatoryFlag { get; set; } public string Severity { get; set; } = ""; public long? ObligationTypeId { get; set; } public string TypeCode { get; set; } = ""; public string TypeName { get; set; } = ""; }

// ---------------------------------------------------------------------
// Obligation Taxonomy (Phase 2B) DTOs.  Each typed detail shape returned
// by dbo.cm_get_obligation_taxonomy is expressed here for consumers that
// want strong typing; the controller flow still returns generic
// Dictionary rows in RepositoryResult.Data (matching the assurance and
// standard repository patterns), so these classes are optional and
// primarily document the contract.
// ---------------------------------------------------------------------

public sealed class ObligationType
{
    public long Id { get; set; }
    public string TypeCode { get; set; } = "";
    public string TypeName { get; set; } = "";
    public string Description { get; set; } = "";
    public int DisplayOrder { get; set; }
    public string Status { get; set; } = "";
}

public sealed class ObligationStateRule
{
    public long Id { get; set; }
    public long ObligationId { get; set; }
    public string Attribute { get; set; } = "";
    public string Operator { get; set; } = "";
    public string Value { get; set; } = "";
    public string Unit { get; set; } = "";
    public string Tolerance { get; set; } = "";
    public string Remarks { get; set; } = "";
    public string Status { get; set; } = "";
}

public sealed class ObligationExecutionSpec
{
    public long Id { get; set; }
    public long ObligationId { get; set; }
    public string Action { get; set; } = "";
    public long? ExecutionFrequencyId { get; set; }
    public string ExecutionFrequency { get; set; } = "";
    public string TriggerCondition { get; set; } = "";
    public string ResponsibleParty { get; set; } = "";
    public string DueWithin { get; set; } = "";
    public string Remarks { get; set; } = "";
    public string Status { get; set; } = "";
}

public sealed class ObligationAssuranceSpec
{
    public long Id { get; set; }
    public long ObligationId { get; set; }
    public string VerificationMethod { get; set; } = "";
    public string Scope { get; set; } = "";
    public long? AssuranceFrequencyId { get; set; }
    public string AssuranceFrequency { get; set; } = "";
    public string AssuranceParty { get; set; } = "";
    public string Remarks { get; set; } = "";
    public string Status { get; set; } = "";
}

public sealed class ObligationEventResponse
{
    public long Id { get; set; }
    public long ObligationId { get; set; }
    public string TriggerEvent { get; set; } = "";
    public string ResponseAction { get; set; } = "";
    public int? SlaValue { get; set; }
    public string SlaUnit { get; set; } = "";
    public string EscalationPath { get; set; } = "";
    public string Remarks { get; set; } = "";
    public string Status { get; set; } = "";
}

public sealed class ObligationConstraintRule
{
    public long Id { get; set; }
    public long ObligationId { get; set; }
    public string ProhibitedCondition { get; set; } = "";
    public string Scope { get; set; } = "";
    public string ExceptionPolicy { get; set; } = "";
    public string Remarks { get; set; } = "";
    public string Status { get; set; } = "";
}

public sealed class ObligationRetentionSpec
{
    public long Id { get; set; }
    public long ObligationId { get; set; }
    public string RetainedObject { get; set; } = "";
    public int? MinRetentionValue { get; set; }
    public string MinRetentionUnit { get; set; } = "";
    public int? MaxRetentionValue { get; set; }
    public string MaxRetentionUnit { get; set; } = "";
    public string DisposalPolicy { get; set; } = "";
    public string Remarks { get; set; } = "";
    public string Status { get; set; } = "";
}

public sealed class ObligationEvidenceLink
{
    public string TypeCode { get; set; } = "";           // which per-type link table
    public long LinkId { get; set; }
    public long ObligationId { get; set; }
    public long ObligationEvidenceId { get; set; }
    public long? EvidenceTypeId { get; set; }
    public string EvidenceType { get; set; } = "";
    public long? FrequencyId { get; set; }
    public string Frequency { get; set; } = "";
    public string RetentionRequirement { get; set; } = "";
    public string EvidenceRemarks { get; set; } = "";
    public string LinkRemarks { get; set; } = "";
    public string Status { get; set; } = "";
}
