using ControlManagement.Api.Models;
using ControlManagement.Api.Services;
using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;

namespace ControlManagement.Api.Controllers;

// -----------------------------------------------------------------------------
// Single-Form Upload endpoints.
//   GET  /forms                          -> list uploadable entities
//   GET  /releases                       -> Draft/Active releases for dropdown
//   GET  /template?entity=&releaseId=    -> download signed per-entity template
//   POST /validate  (multipart)          -> validate uploaded file
//   POST /commit    (multipart)          -> validate + atomic commit
//
// Permission gate is per-entity: the caller only needs ADD on the entity
// they're actually uploading, so a user with rights to add framework
// statements does NOT need rights to add authorities.
// -----------------------------------------------------------------------------

[ApiController]
[Route("api/control-management/single-form-upload")]
public sealed class SingleFormUploadController(
    ISingleFormUploadService service,
    SignedAccessTokenService tokenService,
    PermissionPolicy permissionPolicy,
    ILogger<SingleFormUploadController> logger) : ControllerBase
{
    [HttpGet("forms")]
    public IActionResult Forms()
    {
        if (!TryAuthenticate(out var principal)) return Unauthorized(new { success = false, message = "Authorization failed." });
        var forms = service.ListForms()
            .Where(f => permissionPolicy.IsAllowed(principal!.Roles, f.PermissionArea, "ADD"))
            .Select(f => new
            {
                entityKey = f.EntityKey,
                displayName = f.DisplayName,
                releaseScoped = f.ReleaseScoped,
                instructions = f.Instructions,
                replaceAllowed = f.ReplaceStrategy != ReplaceStrategy.NotAllowed
                                 && f.ReleaseScoped
                                 && permissionPolicy.IsAllowed(principal.Roles, f.PermissionArea, "DELETE"),
                deleteStrategy = f.ReplaceStrategy.ToString()
            });
        return Ok(new { success = true, forms });
    }

    [HttpGet("releases")]
    public async Task<IActionResult> Releases(CancellationToken cancellationToken)
    {
        if (!TryAuthenticate(out _)) return Unauthorized(new { success = false, message = "Authorization failed." });
        var releases = await service.ListReleasesAsync(cancellationToken);
        return Ok(new { success = true, releases });
    }

    [HttpGet("template")]
    public async Task<IActionResult> Template([FromQuery] string entity, [FromQuery] long? releaseId, CancellationToken cancellationToken)
    {
        if (!TryAuthenticate(out var principal)) return Unauthorized();
        var def = SingleFormUploadSchema.Find(entity ?? "");
        if (def is null) return BadRequest(new { success = false, message = "Unknown entity." });
        if (!permissionPolicy.IsAllowed(principal!.Roles, def.PermissionArea, "ADD"))
            return StatusCode(StatusCodes.Status403Forbidden, new { success = false, message = $"You do not have permission to add '{def.DisplayName}'." });

        try
        {
            var bytes = await service.BuildTemplateAsync(entity, releaseId, cancellationToken);
            var fileName = def.ReleaseScoped
                ? $"{def.EntityKey}-release-{releaseId}-template.xlsx"
                : $"{def.EntityKey}-template.xlsx";
            return File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", fileName);
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new { success = false, message = ex.Message });
        }
    }

    [HttpPost("validate")]
    [RequestSizeLimit(52428800)]
    public async Task<IActionResult> Validate([FromForm] string entity, [FromForm] long? releaseId, IFormFile file, CancellationToken cancellationToken)
    {
        if (!TryAuthenticate(out var principal)) return Unauthorized(new BulkUploadReport { Success = false, Message = "Authorization failed." });
        var def = SingleFormUploadSchema.Find(entity ?? "");
        if (def is null) return BadRequest(new BulkUploadReport { Success = false, Message = "Unknown entity." });
        if (!permissionPolicy.IsAllowed(principal!.Roles, def.PermissionArea, "ADD"))
            return StatusCode(StatusCodes.Status403Forbidden, new BulkUploadReport { Success = false, Message = $"You do not have permission to add '{def.DisplayName}'." });
        if (file is null || file.Length == 0) return BadRequest(new BulkUploadReport { Success = false, Message = "No file uploaded." });

        await using var stream = file.OpenReadStream();
        var report = await service.ValidateAsync(entity!, releaseId, stream, cancellationToken);
        return Ok(report);
    }

    [HttpPost("commit")]
    [RequestSizeLimit(52428800)]
    public async Task<IActionResult> Commit(
        [FromForm] string entity,
        [FromForm] long? releaseId,
        [FromForm] string? mode,
        [FromForm] string? confirmReleaseCode,
        IFormFile file,
        CancellationToken cancellationToken)
    {
        if (!TryAuthenticate(out var principal)) return Unauthorized(new BulkUploadReport { Success = false, Message = "Authorization failed." });
        var def = SingleFormUploadSchema.Find(entity ?? "");
        if (def is null) return BadRequest(new BulkUploadReport { Success = false, Message = "Unknown entity." });
        if (!permissionPolicy.IsAllowed(principal!.Roles, def.PermissionArea, "ADD"))
            return StatusCode(StatusCodes.Status403Forbidden, new BulkUploadReport { Success = false, Message = $"You do not have permission to add '{def.DisplayName}'." });
        // Replace mode also acts as a destructive delete — additionally require DELETE.
        var normalizedMode = string.IsNullOrWhiteSpace(mode) ? "Insert" : mode.Trim();
        if (normalizedMode.Equals("Replace", StringComparison.OrdinalIgnoreCase)
            && !permissionPolicy.IsAllowed(principal.Roles, def.PermissionArea, "DELETE"))
            return StatusCode(StatusCodes.Status403Forbidden, new BulkUploadReport { Success = false, Message = $"You do not have permission to delete '{def.DisplayName}'." });
        if (file is null || file.Length == 0) return BadRequest(new BulkUploadReport { Success = false, Message = "No file uploaded." });

        await using var stream = file.OpenReadStream();
        var report = await service.CommitAsync(entity!, releaseId, normalizedMode, confirmReleaseCode, stream, principal.Subject, cancellationToken);
        if (!report.Success)
            logger.LogWarning("Single-form upload rejected for {Subject}: {Message}", principal.Subject, report.Message);
        return Ok(report);
    }

    [HttpGet("preview-replace")]
    public async Task<IActionResult> PreviewReplace([FromQuery] string entity, [FromQuery] long? releaseId, CancellationToken cancellationToken)
    {
        if (!TryAuthenticate(out var principal)) return Unauthorized(new { success = false, message = "Authorization failed." });
        var def = SingleFormUploadSchema.Find(entity ?? "");
        if (def is null) return BadRequest(new { success = false, message = "Unknown entity." });
        if (!permissionPolicy.IsAllowed(principal!.Roles, def.PermissionArea, "ADD"))
            return StatusCode(StatusCodes.Status403Forbidden, new { success = false, message = $"You do not have permission for '{def.DisplayName}'." });
        try
        {
            var preview = await service.PreviewReplaceAsync(entity!, releaseId, cancellationToken);
            return Ok(new { success = true, preview });
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new { success = false, message = ex.Message });
        }
    }

    private bool TryAuthenticate(out AccessPrincipal? principal)
    {
        principal = null;
        var authorization = Request.Headers.Authorization.ToString();
        var token = authorization.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) ? authorization[7..] : authorization;
        if (!tokenService.TryValidate(token, out var p)) return false;
        principal = p;
        return true;
    }
}
