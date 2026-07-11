using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ControlManagement.Api.Models;
using ControlManagement.Api.Security;
using ControlManagement.Api.Services;
using ControlManagement.Api.Validation;
using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Caching.Memory;

namespace ControlManagement.Api.Controllers;

[ApiController]
[Route("api/control-management")]
public sealed class RepositoryController(
    IRegulatoryRepositoryService service,
    SignedAccessTokenService tokenService,
    EnvelopeCrypto crypto,
    PermissionPolicy permissionPolicy,
    RepositoryCommandValidator validator,
    PasswordHasher passwordHasher,
    IMemoryCache cache,
    IConfiguration configuration,
    IWebHostEnvironment appEnvironment,
    ILogger<RepositoryController> logger) : ControllerBase
{
    private static readonly HashSet<string> Supported = new(StringComparer.OrdinalIgnoreCase)
    {
        "authorities", "artifacts", "releases", "statement-classifications", "source-structure", "framework-statements", "controls", "requirements", "requirements-similar", "obligations", "obligations-similar", "obligation-mappings", "obligation-mapping-matrix", "obligation-mapping-bulk", "obligation-evidence",
        "control-domains", "control-sub-domains", "control-similar", "control-tree",
        "control-requirement-mappings", "source-control-mappings", "framework-statement-requirement-mappings", "applicability-rules",
        "user-management", "role-management", "menu-management", "role-permissions",
        "changes", "impact-analysis", "notifications", "change-management", "approval-workflow", "audit-trace", "lookups"
    };

    [HttpGet]
    public IActionResult Index() => Ok(new { status = "ready" });

    [HttpGet("diagnostics/security")]
    public IActionResult SecurityDiagnostics()
    {
        var token = ReadAuthorizationToken();
        var key = configuration["Security:TokenSigningKey"] ?? "";
        var tokenValid = tokenService.TryValidate(token, out var principal);
        return Ok(new
        {
            environment = appEnvironment.EnvironmentName,
            authorizationHeaderPresent = !string.IsNullOrWhiteSpace(Request.Headers.Authorization.ToString()),
            tokenPrefixValid = token.StartsWith("cm01.", StringComparison.Ordinal),
            tokenValid,
            subject = tokenValid ? principal.Subject : "",
            roles = tokenValid ? principal.Roles : Array.Empty<string>(),
            signingKeyConfigured = key.Length >= 32,
            signingKeyLength = key.Length,
            signingKeyFingerprint = Fingerprint(key),
            utcNow = DateTimeOffset.UtcNow
        });
    }

    [HttpPost("secure/query")]
    public Task<IActionResult> Query([FromBody] EncryptedRequest envelope, CancellationToken cancellationToken) =>
        ExecuteAsync(envelope, "VIEW", async (request, principal) =>
            await service.QueryAsync(new RepositoryQuery
            {
                EntityType = request.EntityType,
                Id = request.Id,
                Search = request.Search,
                Status = request.Status,
                Module = request.Module,
                ActionType = request.ActionType,
                AuthorityId = request.AuthorityId,
                ArtifactId = request.ArtifactId,
                ReleaseId = request.ReleaseId,
                ControlId = request.ControlId,
                RequirementId = request.RequirementId,
                FrameworkStatementId = request.FrameworkStatementId,
                DomainId = request.DomainId,
                Page = request.Page,
                PageSize = request.PageSize
            }, cancellationToken));

    [HttpPost("secure/manage")]
    public Task<IActionResult> Manage([FromBody] EncryptedRequest envelope, CancellationToken cancellationToken) =>
        ExecuteAsync(envelope, null, async (request, principal) =>
        {
            var action = request.Action.Equals("APPROVE", StringComparison.OrdinalIgnoreCase)
                ? "APPROVE"
                : request.Action.Equals("REJECT", StringComparison.OrdinalIgnoreCase) || request.Action.Equals("SEND_BACK", StringComparison.OrdinalIgnoreCase)
                    ? "REJECT"
                : request.Action.Equals("RETIRE", StringComparison.OrdinalIgnoreCase) ? "DELETE"
                : request.Id.GetValueOrDefault() > 0 ? "EDIT" : "ADD";
            if (!permissionPolicy.IsAllowed(principal.Roles, request.EntityType, action))
                return new RepositoryResult(false, "You do not have permission to perform this action.");

            var validation = validator.Validate(request);
            if (validation is not null) return new RepositoryResult(false, validation);

            // Add User must never accept a browser-supplied password.  Inject a
            // hash of Security:DefaultUserPassword here in the API tier so the
            // Web layer never sees a hashing primitive.
            var data = request.Data;
            if (request.EntityType.Equals("user-management", StringComparison.OrdinalIgnoreCase)
                && request.Action.Equals("SAVE", StringComparison.OrdinalIgnoreCase)
                && request.Id.GetValueOrDefault() <= 0)
                data = InjectDefaultUserPassword(data);

            // Maker-checker auto-approval: the SP runs the workflow gate and will
            // auto-approve a SAVE/RETIRE only when it sees __autoApproveAllowed=1
            // AND the workflow row has self_approval_allowed=1.  The API has the
            // role-to-permission map, so we tell the SP whether *this* maker also
            // holds APPROVE on the area; the SP keeps the final say because it
            // owns the workflow config.
            var managePermissionArea = request.EntityType.Equals("framework-statement-requirement-mappings", StringComparison.OrdinalIgnoreCase)
                ? "requirements"
                : request.EntityType;
            if ((request.Action.Equals("SAVE", StringComparison.OrdinalIgnoreCase)
                  || request.Action.Equals("RETIRE", StringComparison.OrdinalIgnoreCase))
                && permissionPolicy.IsAllowed(principal.Roles, managePermissionArea, "APPROVE"))
            {
                data = InjectAutoApproveFlag(data);
            }

            return await service.ManageAsync(new RepositoryCommand
            {
                EntityType = request.EntityType,
                Action = request.Action,
                Id = request.Id,
                EnteredBy = principal.Subject,
                Data = data
            }, cancellationToken);
        });

    private async Task<IActionResult> ExecuteAsync(EncryptedRequest envelope, string? requiredAction,
        Func<SecureRepositoryRequest, AccessPrincipal, Task<RepositoryResult>> execute)
    {
        var correlationId = HttpContext.TraceIdentifier;
        try
        {
            var token = ReadAuthorizationToken();
            if (!tokenService.TryValidate(token, out var principal))
            {
                logger.LogWarning("Rejected ControlManagement token {CorrelationId}. Authorization header present: {HasAuthorization}. Token prefix valid: {HasTokenPrefix}.",
                    correlationId,
                    !string.IsNullOrWhiteSpace(Request.Headers.Authorization.ToString()),
                    token.StartsWith("cm01.", StringComparison.Ordinal));
                return Unauthorized(new { message = "Authorization failed.", correlationId });
            }

            var request = JsonSerializer.Deserialize<SecureRepositoryRequest>(crypto.DecryptRequest(envelope, token),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            if (request is null || !Supported.Contains(request.EntityType))
                return BadRequest(crypto.EncryptResponse("FAIL", JsonSerializer.Serialize(new RepositoryResult(false, "Unsupported repository area.")), token));
            if (!IsValidQuery(request))
                return BadRequest(crypto.EncryptResponse("FAIL", JsonSerializer.Serialize(new RepositoryResult(false, "The request parameters are invalid.")), token));
            if (!IsFresh(request) || !RegisterNonce(request.Nonce))
                return BadRequest(crypto.EncryptResponse("FAIL", JsonSerializer.Serialize(new RepositoryResult(false, "The request is invalid or has expired.")), token));
            // "Similar records" helpers are read-only lookups that piggy-back on
            // the master area's VIEW permission (a user who can view Obligations
            // may also see potential duplicates).  Same treatment as the legacy
            // framework-statement-requirement-mappings alias.
            var permissionArea = request.EntityType.Equals("framework-statement-requirement-mappings", StringComparison.OrdinalIgnoreCase)
                ? "requirements"
                : request.EntityType.Equals("obligations-similar", StringComparison.OrdinalIgnoreCase)
                    ? "obligations"
                    : request.EntityType.Equals("requirements-similar", StringComparison.OrdinalIgnoreCase)
                        ? "requirements"
                        : request.EntityType;
            if (requiredAction is not null && !permissionPolicy.IsAllowed(principal.Roles, permissionArea, requiredAction))
                return StatusCode(StatusCodes.Status403Forbidden,
                    crypto.EncryptResponse("FAIL", JsonSerializer.Serialize(new RepositoryResult(false, "You do not have permission to access this area.")), token));

            var result = await execute(request, principal);
            return Ok(crypto.EncryptResponse(result.Success ? "SUCCESS" : "FAIL", JsonSerializer.Serialize(result), token));
        }
        catch (CryptographicException ex)
        {
            logger.LogWarning(ex, "Rejected invalid encrypted ControlManagement request {CorrelationId}", correlationId);
            return BadRequest(new { message = "The encrypted request is invalid.", correlationId });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "ControlManagement request failed {CorrelationId}", correlationId);
            return StatusCode(StatusCodes.Status500InternalServerError,
                new { message = "The request could not be completed.", correlationId });
        }
    }

    private string ReadAuthorizationToken()
    {
        var authorization = Request.Headers.Authorization.ToString();
        return authorization.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) ? authorization[7..] : authorization;
    }

    private bool IsFresh(SecureRepositoryRequest request)
    {
        var validity = configuration.GetValue("Security:RequestValidityMinutes", 5);
        return !string.IsNullOrWhiteSpace(request.Nonce)
            && request.Nonce.Length <= 128
            && Math.Abs((DateTimeOffset.UtcNow - request.TimestampUtc).TotalMinutes) <= validity;
    }

    private bool RegisterNonce(string nonce)
    {
        var key = $"cm-replay:{nonce}";
        if (cache.TryGetValue(key, out _)) return false;
        cache.Set(key, true, TimeSpan.FromMinutes(configuration.GetValue("Security:RequestValidityMinutes", 5)));
        return true;
    }

    private static readonly HashSet<int> AllowedPageSizes = [0, 10, 25, 50, 100];

    private static bool IsValidQuery(SecureRepositoryRequest request) =>
        request.Id.GetValueOrDefault() >= 0
        && request.AuthorityId.GetValueOrDefault() >= 0
        && request.ArtifactId.GetValueOrDefault() >= 0
        && request.ReleaseId.GetValueOrDefault() >= 0
        && request.ControlId.GetValueOrDefault() >= 0
        && request.RequirementId.GetValueOrDefault() >= 0
        && request.DomainId.GetValueOrDefault() >= 0
        && request.Search.Length <= 250
        && request.Module.Length <= 200
        && request.ActionType.Length <= 50
        && request.Status.Length <= 40
        && request.Page.GetValueOrDefault() >= 0
        && request.Page.GetValueOrDefault() <= 100000
        && AllowedPageSizes.Contains(request.PageSize.GetValueOrDefault());

    private static string Fingerprint(string value)
    {
        if (string.IsNullOrEmpty(value)) return "";
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(value));
        return Convert.ToHexString(hash)[..16];
    }

    private JsonElement InjectDefaultUserPassword(JsonElement data)
    {
        var defaultPassword = configuration["Security:DefaultUserPassword"] ?? "";
        if (string.IsNullOrEmpty(defaultPassword)) defaultPassword = "Welcome@123";
        var values = JsonSerializer.Deserialize<Dictionary<string, object?>>(data.GetRawText()) ?? [];
        values["passwordHash"] = passwordHasher.Hash(defaultPassword);
        return JsonSerializer.SerializeToElement(values);
    }

    private static JsonElement InjectAutoApproveFlag(JsonElement data)
    {
        // We deliberately keep this as a JSON int (1) so JSON_VALUE in T-SQL reads
        // the literal '1' that the SP's CASE expression matches against.
        var values = JsonSerializer.Deserialize<Dictionary<string, object?>>(data.GetRawText()) ?? [];
        values["__autoApproveAllowed"] = 1;
        return JsonSerializer.SerializeToElement(values);
    }
}
