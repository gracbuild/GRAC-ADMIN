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
public sealed class Obligation { public long ObligationId { get; set; } public long RequirementId { get; set; } public long ReleaseId { get; set; } public bool MandatoryFlag { get; set; } public string Severity { get; set; } = ""; }
