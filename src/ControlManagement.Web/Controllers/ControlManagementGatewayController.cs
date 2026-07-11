using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ControlManagement.Security;
using ControlManagement.Web.Security;
using ControlManagement.Web.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;

namespace ControlManagement.Web.Controllers;

[ApiController]
[Route("control-management-gateway")]
[EnableRateLimiting("gateway")]
public sealed class ControlManagementGatewayController(SecureRepositoryClient client, PermissionPolicy permissionPolicy,
    NavigationContextProtector navigationContextProtector,
    AuthApiClient authClient,
    IConfiguration configuration,
    ILogger<ControlManagementGatewayController> logger) : ControllerBase
{
    [HttpGet("{entityType}")]
    public async Task<IActionResult> Query(string entityType, [FromQuery] int? id, [FromQuery] string search = "",
        [FromQuery] string status = "", [FromQuery] int? authorityId = null, [FromQuery] int? artifactId = null,
        [FromQuery] int? releaseId = null, [FromQuery] int? controlId = null, [FromQuery] int? requirementId = null,
        [FromQuery] int? frameworkStatementId = null,
        [FromQuery] int? domainId = null, [FromQuery] string module = "", [FromQuery] string actionType = "",
        [FromQuery] string code = "", [FromQuery] int? page = null, [FromQuery] int? pageSize = null,
        CancellationToken cancellationToken = default)
    {
        if (!TrySession(out var token, out var roles)) return Unauthorized(new { success = false, message = "Your session has expired. Please sign in again." });
        // The "-similar" read-only lookups piggy-back on the master area's VIEW
        // permission so a user with VIEW on Obligations/Practices can see
        // potential duplicates while adding or editing a record.
        var permissionArea = entityType.Equals("framework-statement-requirement-mappings", StringComparison.OrdinalIgnoreCase)
            ? "requirements"
            : entityType.Equals("obligations-similar", StringComparison.OrdinalIgnoreCase)
                ? "obligations"
                : entityType.Equals("requirements-similar", StringComparison.OrdinalIgnoreCase)
                    ? "requirements"
                    : entityType;
        if (!permissionPolicy.IsAllowed(roles, permissionArea, "VIEW")) return Forbid();
        NavigationContext? context;
        try { context = ResolveNavigationContext(token, code, entityType); }
        catch (CryptographicException) { return BadRequest(new { success = false, message = "The navigation context is invalid or has expired." }); }
        if (context is not null)
        {
            authorityId = context.FilterType.Equals("Authority", StringComparison.OrdinalIgnoreCase) ? context.FilterId : authorityId;
            artifactId = context.FilterType.Equals("Artifact", StringComparison.OrdinalIgnoreCase) ? context.FilterId : artifactId;
            releaseId = context.FilterType.Equals("Release", StringComparison.OrdinalIgnoreCase) ? context.FilterId : releaseId;
        }
        return await InvokeAsync(() => client.QueryAsync(token, new SecureRepositoryRequest
        {
            EntityType = entityType, Id = id, Search = search, Status = status, Module = module, ActionType = actionType, AuthorityId = authorityId,
            ArtifactId = artifactId, ReleaseId = releaseId, ControlId = controlId, RequirementId = requirementId,
            FrameworkStatementId = frameworkStatementId, DomainId = domainId,
            Page = page, PageSize = pageSize
        }, cancellationToken));
    }

    [HttpPost("navigation-code")]
    [ValidateAntiForgeryToken]
    public IActionResult NavigationCode([FromBody] NavigationCodeRequest request)
    {
        if (!TrySession(out var token, out var roles)) return Unauthorized(new { success = false, message = "Your session has expired. Please sign in again." });
        if (!IsAllowedNavigation(request, roles)) return Forbid();
        var code = navigationContextProtector.Protect(token, new NavigationContext
        {
            SourceArea = request.SourceArea,
            TargetArea = request.TargetArea,
            FilterType = request.FilterType,
            FilterId = request.FilterId,
            ParentAuthorityId = request.ParentAuthorityId,
            ParentArtifactId = request.ParentArtifactId,
            DisplayCode = request.DisplayCode,
            DisplayName = request.DisplayName
        });
        return Ok(new { success = true, code });
    }

    [HttpGet("navigation-context")]
    public IActionResult NavigationContext([FromQuery] string code, [FromQuery] string targetArea)
    {
        if (!TrySession(out var token, out var roles)) return Unauthorized(new { success = false, message = "Your session has expired. Please sign in again." });
        NavigationContext? context;
        try { context = ResolveNavigationContext(token, code, targetArea); }
        catch (CryptographicException) { return BadRequest(new { success = false, message = "The navigation context is invalid or has expired." }); }
        if (context is null) return BadRequest(new { success = false, message = "The navigation context is invalid or has expired." });
        if (!permissionPolicy.IsAllowed(roles, context.TargetArea, "VIEW")) return Forbid();
        return Ok(new { success = true, filterType = context.FilterType, filterId = context.FilterId, parentAuthorityId = context.ParentAuthorityId, parentArtifactId = context.ParentArtifactId, displayCode = context.DisplayCode, displayName = context.DisplayName });
    }

    [HttpGet("diagnostics/security")]
    public async Task<IActionResult> SecurityDiagnostics(CancellationToken cancellationToken)
    {
        if (!TrySession(out var token, out var roles)) return Unauthorized(new { success = false, message = "Your session has expired. Please sign in again." });
        var key = configuration["Security:TokenSigningKey"] ?? "";
        try
        {
            using var apiResult = JsonDocument.Parse(await client.SecurityDiagnosticsAsync(token, cancellationToken));
            return Ok(new
            {
                success = true,
                web = new
                {
                    tokenPresent = !string.IsNullOrWhiteSpace(token),
                    tokenPrefixValid = token.StartsWith("cm01.", StringComparison.Ordinal),
                    roles,
                    signingKeyConfigured = key.Length >= 32,
                    signingKeyLength = key.Length,
                    signingKeyFingerprint = Fingerprint(key)
                },
                api = apiResult.RootElement.Clone()
            });
        }
        catch (RepositoryApiException ex)
        {
            return StatusCode(StatusCodes.Status502BadGateway, new { success = false, message = ex.Message });
        }
    }

    [HttpPost("{entityType}")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(string entityType, [FromBody] BrowserCommand command, CancellationToken cancellationToken)
    {
        if (!TrySession(out var token, out var roles)) return Unauthorized(new { success = false, message = "Your session has expired. Please sign in again." });
        var action = command.Id.GetValueOrDefault() > 0 ? "EDIT" : "ADD";
        if (!permissionPolicy.IsAllowed(roles, entityType, action)) return Forbid();
        JsonElement data;
        try { data = ApplyNavigationContext(token, entityType, command.Data); }
        catch (CryptographicException) { return BadRequest(new { success = false, message = "The navigation context is invalid or has expired." }); }
        // The Web tier never injects passwords.  For Add User, the API tier
        // resolves Security:DefaultUserPassword and hashes it just before
        // calling the SP.
        return await InvokeAsync(() => client.ManageAsync(token, new SecureRepositoryRequest
        {
            EntityType = entityType, Id = command.Id, Action = "SAVE", Data = data
        }, cancellationToken));
    }

    /// <summary>
    /// Admin reset to default password.  Only valid for user-management.
    /// Forwards to API /auth/admin-reset-password using the caller's session
    /// token so the API can enforce the user-management:EDIT permission check.
    /// </summary>
    [HttpPost("user-management/{id:long}/reset-password")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ResetUserPassword(long id, CancellationToken cancellationToken)
    {
        if (!TrySession(out var token, out var roles)) return Unauthorized(new { success = false, message = "Your session has expired. Please sign in again." });
        if (!permissionPolicy.IsAllowed(roles, "user-management", "EDIT"))
            return StatusCode(StatusCodes.Status403Forbidden, new { success = false, message = "You do not have permission to reset user passwords." });
        if (id <= 0) return BadRequest(new { success = false, message = "A valid user identifier is required." });

        var result = await authClient.AdminResetPasswordAsync(token, id, cancellationToken);
        if (!result.Success) return BadRequest(new { success = result.Success, message = result.Message });
        return Ok(new { success = true, message = result.Message, userId = result.UserId });
    }

    [HttpPost("{entityType}/{id:int}/retire")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Retire(string entityType, int id, CancellationToken cancellationToken)
    {
        if (!TrySession(out var token, out var roles)) return Unauthorized(new { success = false, message = "Your session has expired. Please sign in again." });
        if (!permissionPolicy.IsAllowed(roles, entityType, "DELETE")) return Forbid();
        return await InvokeAsync(() => client.ManageAsync(token, new SecureRepositoryRequest
        {
            EntityType = entityType, Id = id, Action = "RETIRE", Data = JsonSerializer.SerializeToElement(new { })
        }, cancellationToken));
    }

    [HttpPost("{entityType}/{id:int}/approve")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Approve(string entityType, int id, [FromBody] ApprovalCommand command, CancellationToken cancellationToken)
    {
        if (!TrySession(out var token, out var roles)) return Unauthorized(new { success = false, message = "Your session has expired. Please sign in again." });
        if (!permissionPolicy.IsAllowed(roles, entityType, "APPROVE")) return Forbid();
        return await InvokeAsync(() => client.ManageAsync(token, new SecureRepositoryRequest
        {
            EntityType = entityType, Id = id, Action = "APPROVE", Data = JsonSerializer.SerializeToElement(new { command.Comments })
        }, cancellationToken));
    }

    [HttpPost("{entityType}/{id:int}/reject")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Reject(string entityType, int id, [FromBody] ApprovalCommand command, CancellationToken cancellationToken)
    {
        if (!TrySession(out var token, out var roles)) return Unauthorized(new { success = false, message = "Your session has expired. Please sign in again." });
        if (!permissionPolicy.IsAllowed(roles, entityType, "REJECT")) return Forbid();
        return await InvokeAsync(() => client.ManageAsync(token, new SecureRepositoryRequest
        {
            EntityType = entityType, Id = id, Action = "REJECT", Data = JsonSerializer.SerializeToElement(new { command.Comments })
        }, cancellationToken));
    }

    [HttpPost("{entityType}/{id:int}/send-back")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SendBack(string entityType, int id, [FromBody] ApprovalCommand command, CancellationToken cancellationToken)
    {
        if (!TrySession(out var token, out var roles)) return Unauthorized(new { success = false, message = "Your session has expired. Please sign in again." });
        if (!permissionPolicy.IsAllowed(roles, entityType, "REJECT")) return Forbid();
        return await InvokeAsync(() => client.ManageAsync(token, new SecureRepositoryRequest
        {
            EntityType = entityType, Id = id, Action = "SEND_BACK", Data = JsonSerializer.SerializeToElement(new { command.Comments })
        }, cancellationToken));
    }

    private async Task<IActionResult> InvokeAsync(Func<Task<string>> action)
    {
        try { return Content(await action(), "application/json"); }
        catch (UnauthorizedAccessException ex)
        {
            HttpContext.Session.Clear();
            return Unauthorized(new { success = false, message = ex.Message });
        }
        catch (RepositoryApiException ex)
        {
            return StatusCode(StatusCodes.Status502BadGateway, new { success = false, message = ex.Message });
        }
        catch (Exception ex)
        {
            var correlationId = HttpContext.TraceIdentifier;
            logger.LogError(ex, "ControlManagement gateway request failed {CorrelationId}", correlationId);
            return StatusCode(StatusCodes.Status502BadGateway,
                new { success = false, message = $"The repository service is currently unavailable. Gateway reference: {correlationId}" });
        }
    }

    private NavigationContext? ResolveNavigationContext(string token, string code, string targetArea)
    {
        if (string.IsNullOrWhiteSpace(code)) return null;
        var context = navigationContextProtector.Unprotect(token, code);
        if (!context.TargetArea.Equals(targetArea, StringComparison.OrdinalIgnoreCase))
            throw new CryptographicException("Navigation context target does not match the requested area.");
        return context;
    }

    private JsonElement ApplyNavigationContext(string token, string entityType, JsonElement data)
    {
        if (!data.TryGetProperty("contextCode", out var codeElement)
            || string.IsNullOrWhiteSpace(codeElement.GetString()))
            return data;

        var context = ResolveNavigationContext(token, codeElement.GetString()!, entityType)
            ?? throw new CryptographicException("Missing navigation context.");

        var values = JsonSerializer.Deserialize<Dictionary<string, object?>>(data.GetRawText()) ?? [];
        values.Remove("contextCode");
        if (entityType.Equals("artifacts", StringComparison.OrdinalIgnoreCase)
            && context.FilterType.Equals("Authority", StringComparison.OrdinalIgnoreCase))
        {
            values["authorityId"] = context.FilterId;
        }
        else if (entityType.Equals("releases", StringComparison.OrdinalIgnoreCase)
            && context.FilterType.Equals("Artifact", StringComparison.OrdinalIgnoreCase))
        {
            values["artifactId"] = context.FilterId;
        }
        else if (entityType.Equals("source-structure", StringComparison.OrdinalIgnoreCase)
            && context.FilterType.Equals("Release", StringComparison.OrdinalIgnoreCase))
        {
            values["releaseId"] = context.FilterId;
        }
        else
        {
            throw new CryptographicException("Invalid navigation context.");
        }
        return JsonSerializer.SerializeToElement(values);
    }

    private bool IsAllowedNavigation(NavigationCodeRequest request, string[] roles) =>
        request.FilterId > 0
        && permissionPolicy.IsAllowed(roles, request.SourceArea, "VIEW")
        && permissionPolicy.IsAllowed(roles, request.TargetArea, "VIEW")
        && request switch
        {
            { SourceArea: "authorities", TargetArea: "artifacts", FilterType: "Authority" } => true,
            { SourceArea: "artifacts", TargetArea: "releases", FilterType: "Artifact" } => true,
            { SourceArea: "releases", TargetArea: "source-structure", FilterType: "Release" } => true,
            { SourceArea: "releases", TargetArea: "statement-classifications", FilterType: "Release" } => true,
            _ => false
        };

    private bool TrySession(out string token, out string[] roles)
    {
        token = HttpContext.Session.GetString(SessionIdentity.TokenKey) ?? "";
        roles = (HttpContext.Session.GetString(SessionIdentity.RolesKey) ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries);
        return !string.IsNullOrWhiteSpace(HttpContext.Session.GetString(SessionIdentity.UserKey))
            && !string.IsNullOrWhiteSpace(token);
    }

    private static string Fingerprint(string value)
    {
        if (string.IsNullOrEmpty(value)) return "";
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(value));
        return Convert.ToHexString(hash)[..16];
    }

    public sealed class BrowserCommand
    {
        public int? Id { get; set; }
        public JsonElement Data { get; set; }
    }

    public sealed class ApprovalCommand
    {
        public string Comments { get; set; } = "";
    }

    public sealed class NavigationCodeRequest
    {
        public string SourceArea { get; set; } = "";
        public string TargetArea { get; set; } = "";
        public string FilterType { get; set; } = "";
        public int FilterId { get; set; }
        public int? ParentAuthorityId { get; set; }
        public int? ParentArtifactId { get; set; }
        public string DisplayCode { get; set; } = "";
        public string DisplayName { get; set; } = "";
    }
}
