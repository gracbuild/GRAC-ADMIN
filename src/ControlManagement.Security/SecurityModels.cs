using System.Text.Json;

namespace ControlManagement.Security;

public sealed class EncryptedRequest
{
    public string RequestStr { get; set; } = "";
    public string Signature { get; set; } = "";
}

public sealed class EncryptedResponse
{
    public string Status { get; set; } = "";
    public string ResponseStr { get; set; } = "";
    public string Signature { get; set; } = "";
}

public sealed class SecureRepositoryRequest
{
    public DateTimeOffset TimestampUtc { get; set; }
    public string Nonce { get; set; } = "";
    public string EntityType { get; set; } = "";
    public string Action { get; set; } = "QUERY";
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
    public int? OrganizationId { get; set; }
    public int? PracticeId { get; set; }
    public int? PracticeInstanceId { get; set; }
    public int? Page { get; set; }
    public int? PageSize { get; set; }
    public JsonElement Data { get; set; } = JsonSerializer.SerializeToElement(new { });
}

public sealed class AccessPrincipal
{
    public string Subject { get; set; } = "";
    public string[] Roles { get; set; } = [];
    public long ExpiresUtc { get; set; }
}
