using System.Text.Json;
using ControlManagement.Api.Models;
using ControlManagement.Api.Services;
using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;

namespace ControlManagement.Api.Controllers;

// -----------------------------------------------------------------------------
// Bulk upload endpoints.  Same signed-token / signed-header security posture
// as RepositoryController, but the file transport is a plain multipart form
// so browsers can post XLSX bytes without encrypting them (the file itself
// carries no secrets — only reference data).
//
// The Web tier keeps the "Admin/Manager only" gate by rejecting anyone who
// does not hold ADD+APPROVE on the affected repository areas; the API tier
// double-checks the same permission set to stop a rogue caller who bypasses
// the browser.
// -----------------------------------------------------------------------------

[ApiController]
[Route("api/control-management/bulk-upload")]
public sealed class BulkUploadController(
    IBulkUploadService bulkUpload,
    SignedAccessTokenService tokenService,
    PermissionPolicy permissionPolicy,
    ILogger<BulkUploadController> logger) : ControllerBase
{
    // Areas the uploader can write to; the caller must hold ADD on every one.
    private static readonly string[] GatedAreas =
    [
        "authorities", "artifacts", "releases", "source-structure",
        "framework-statements", "requirements", "obligations",
        "source-control-mappings", "obligation-mappings"
    ];

    [HttpGet("template")]
    public IActionResult Template()
    {
        if (!Authorize(out _, out var reason)) return reason;
        var bytes = bulkUpload.BuildTemplate();
        return File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "control-management-bulk-upload-template.xlsx");
    }

    [HttpPost("validate")]
    [RequestSizeLimit(52428800)] // 50 MB
    public async Task<IActionResult> Validate(IFormFile file, CancellationToken cancellationToken)
    {
        if (!Authorize(out _, out var reason)) return reason;
        if (file is null || file.Length == 0) return BadRequest(new BulkUploadReport { Success = false, Message = "No file was uploaded." });
        await using var stream = file.OpenReadStream();
        var report = await bulkUpload.ValidateAsync(stream, cancellationToken);
        return Ok(report);
    }

    [HttpPost("commit")]
    [RequestSizeLimit(52428800)]
    public async Task<IActionResult> Commit(IFormFile file, CancellationToken cancellationToken)
    {
        if (!Authorize(out var principal, out var reason)) return reason;
        if (file is null || file.Length == 0) return BadRequest(new BulkUploadReport { Success = false, Message = "No file was uploaded." });
        await using var stream = file.OpenReadStream();
        var report = await bulkUpload.CommitAsync(stream, principal!.Subject, cancellationToken);
        if (!report.Success)
        {
            logger.LogWarning("Bulk upload rejected for {Subject}: {Message} ({IssueCount} issues)", principal.Subject, report.Message, report.Issues.Count);
        }
        return Ok(report);
    }

    [HttpPost("error-report")]
    public IActionResult ErrorReport([FromBody] BulkUploadReport report)
    {
        if (!Authorize(out _, out var reason)) return reason;
        var bytes = bulkUpload.BuildErrorReport(report?.Issues ?? new());
        return File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "bulk-upload-errors.xlsx");
    }

    private bool Authorize(out AccessPrincipal? principal, out IActionResult failure)
    {
        principal = null;
        failure = Unauthorized(new BulkUploadReport { Success = false, Message = "Authorization failed." });
        var authorization = Request.Headers.Authorization.ToString();
        var token = authorization.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) ? authorization[7..] : authorization;
        if (!tokenService.TryValidate(token, out var p)) return false;
        principal = p;
        // Bulk upload writes across every gated area, so the caller must have
        // ADD on all of them.  Effectively this means CM_ADMIN today.
        foreach (var area in GatedAreas)
        {
            if (!permissionPolicy.IsAllowed(p.Roles, area, "ADD"))
            {
                failure = StatusCode(StatusCodes.Status403Forbidden, new BulkUploadReport { Success = false, Message = $"You do not have permission to bulk upload to '{area}'." });
                return false;
            }
        }
        return true;
    }
}
