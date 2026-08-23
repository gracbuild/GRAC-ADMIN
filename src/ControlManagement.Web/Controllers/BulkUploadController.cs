using System.Net.Http.Headers;
using System.Text.Json;
using ControlManagement.Security;
using ControlManagement.Web.Security;
using ControlManagement.Web.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;

namespace ControlManagement.Web.Controllers;

// -----------------------------------------------------------------------------
// Web-tier controller for the Bulk Upload page.
//   * GET  /Repository/BulkUpload             -> renders the page.
//   * GET  /bulk-upload-gateway/template      -> proxies template download.
//   * POST /bulk-upload-gateway/validate      -> proxies validate.
//   * POST /bulk-upload-gateway/commit        -> proxies commit.
//   * POST /bulk-upload-gateway/error-report  -> proxies error-report download.
//
// The proxy forwards the caller's Bearer token to the API so the same signed
// principal is used for permission checks on the API side.  The Web tier
// enforces the Admin/Manager gate before we ever touch the API.
// -----------------------------------------------------------------------------

public sealed class BulkUploadController(PermissionPolicy permissionPolicy, ControlMenuService menuService) : Controller
{
    private static readonly string[] GatedAreas =
    [
        "authorities", "artifacts", "releases", "source-structure",
        "framework-statements", "requirements", "obligations",
        "source-control-mappings", "obligation-mappings"
    ];

    // ---- Page --------------------------------------------------------------
    [HttpGet("/Repository/BulkUpload")]
    public async Task<IActionResult> Index(CancellationToken cancellationToken)
    {
        if (!IsSignedIn()) return RedirectToAction("Index", "Login", new { returnUrl = (Request.PathBase + Request.Path).Value });
        if (!IsAdminUploader()) return Forbid();

        var menuItems = await menuService.GetVisibleMenuAsync(Token(), UserLoginId(), Roles(), cancellationToken);
        ViewBag.MenuItems = menuItems;
        ViewBag.Screens = Array.Empty<ControlManagement.Web.Models.RepositoryScreen>();
        ViewBag.UserName = HttpContext.Session.GetString(SessionIdentity.UserNameKey) ?? UserLoginId();
        ViewBag.CurrentArea = "bulk-upload";
        ViewBag.GatewayBaseUrl = $"{Request.PathBase}/bulk-upload-gateway";
        return View("~/Views/Repository/BulkUpload.cshtml");
    }

    private bool IsSignedIn() => HttpContext.Session.GetString(SessionIdentity.UserKey) is not null;
    private string UserLoginId() => HttpContext.Session.GetString(SessionIdentity.UserKey) ?? "";
    private string Token() => HttpContext.Session.GetString(SessionIdentity.TokenKey) ?? "";
    private string[] Roles() => (HttpContext.Session.GetString(SessionIdentity.RolesKey) ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries);
    private bool IsAdminUploader() => GatedAreas.All(a => permissionPolicy.IsAllowed(Roles(), a, "ADD"));
}

// -----------------------------------------------------------------------------
// The multipart gateway lives as its own controller class so it can carry
// [ApiController] semantics + rate limiting like the existing gateway.
// -----------------------------------------------------------------------------
[ApiController]
[Route("bulk-upload-gateway")]
[EnableRateLimiting("gateway")]
public sealed class BulkUploadGatewayController(PermissionPolicy permissionPolicy,
    IHttpClientFactory httpClientFactory, IConfiguration configuration,
    ILogger<BulkUploadGatewayController> logger) : ControllerBase
{
    private static readonly string[] GatedAreas =
    [
        "authorities", "artifacts", "releases", "source-structure",
        "framework-statements", "requirements", "obligations",
        "source-control-mappings", "obligation-mappings"
    ];

    [HttpGet("template")]
    public async Task<IActionResult> Template(CancellationToken cancellationToken)
    {
        if (!TrySession(out var token, out var roles)) return Unauthorized(new { success = false, message = "Session expired." });
        if (!GatedAreas.All(a => permissionPolicy.IsAllowed(roles, a, "ADD"))) return Forbid();
        var (bytes, mediaType) = await ProxyGetAsync("/template", token, cancellationToken);
        return File(bytes, mediaType, "control-management-bulk-upload-template.xlsx");
    }

    [HttpPost("validate")]
    [ValidateAntiForgeryToken]
    [RequestSizeLimit(52428800)]
    public async Task<IActionResult> Validate([FromForm] IFormFile file, CancellationToken cancellationToken)
    {
        if (!TrySession(out var token, out var roles)) return Unauthorized(new { success = false, message = "Session expired." });
        if (!GatedAreas.All(a => permissionPolicy.IsAllowed(roles, a, "ADD"))) return Forbid();
        if (file is null || file.Length == 0) return BadRequest(new { success = false, message = "No file uploaded." });
        var json = await ProxyPostFileAsync("/validate", token, file, cancellationToken);
        return Content(json, "application/json");
    }

    [HttpPost("commit")]
    [ValidateAntiForgeryToken]
    [RequestSizeLimit(52428800)]
    public async Task<IActionResult> Commit([FromForm] IFormFile file, CancellationToken cancellationToken)
    {
        if (!TrySession(out var token, out var roles)) return Unauthorized(new { success = false, message = "Session expired." });
        if (!GatedAreas.All(a => permissionPolicy.IsAllowed(roles, a, "ADD"))) return Forbid();
        if (file is null || file.Length == 0) return BadRequest(new { success = false, message = "No file uploaded." });
        var json = await ProxyPostFileAsync("/commit", token, file, cancellationToken);
        return Content(json, "application/json");
    }

    [HttpPost("error-report")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ErrorReport([FromBody] JsonElement payload, CancellationToken cancellationToken)
    {
        if (!TrySession(out var token, out var roles)) return Unauthorized(new { success = false, message = "Session expired." });
        if (!GatedAreas.All(a => permissionPolicy.IsAllowed(roles, a, "ADD"))) return Forbid();
        var (bytes, mediaType) = await ProxyPostJsonAsync("/error-report", token, payload.GetRawText(), cancellationToken);
        return File(bytes, mediaType, "bulk-upload-errors.xlsx");
    }

    private async Task<(byte[] Body, string MediaType)> ProxyGetAsync(string path, string token, CancellationToken ct)
    {
        var http = httpClientFactory.CreateClient();
        using var msg = new HttpRequestMessage(HttpMethod.Get, BuildUrl(path));
        msg.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await http.SendAsync(msg, ct);
        response.EnsureSuccessStatusCode();
        var bytes = await response.Content.ReadAsByteArrayAsync(ct);
        return (bytes, response.Content.Headers.ContentType?.MediaType ?? "application/octet-stream");
    }

    private async Task<string> ProxyPostFileAsync(string path, string token, IFormFile file, CancellationToken ct)
    {
        var http = httpClientFactory.CreateClient();
        http.Timeout = TimeSpan.FromMinutes(10);
        using var msg = new HttpRequestMessage(HttpMethod.Post, BuildUrl(path));
        msg.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var content = new MultipartFormDataContent();
        var stream = file.OpenReadStream();
        var streamContent = new StreamContent(stream);
        streamContent.Headers.ContentType = new MediaTypeHeaderValue(string.IsNullOrWhiteSpace(file.ContentType) ? "application/octet-stream" : file.ContentType);
        content.Add(streamContent, "file", file.FileName);
        msg.Content = content;
        using var response = await http.SendAsync(msg, ct);
        var body = await response.Content.ReadAsStringAsync(ct);
        if (!response.IsSuccessStatusCode)
        {
            logger.LogWarning("Bulk upload proxy {Path} failed with {StatusCode}: {Body}", path, response.StatusCode, body);
        }
        return string.IsNullOrWhiteSpace(body) ? "{\"success\":false,\"message\":\"Empty response.\"}" : body;
    }

    private async Task<(byte[] Body, string MediaType)> ProxyPostJsonAsync(string path, string token, string json, CancellationToken ct)
    {
        var http = httpClientFactory.CreateClient();
        using var msg = new HttpRequestMessage(HttpMethod.Post, BuildUrl(path))
        {
            Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json")
        };
        msg.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await http.SendAsync(msg, ct);
        response.EnsureSuccessStatusCode();
        var bytes = await response.Content.ReadAsByteArrayAsync(ct);
        return (bytes, response.Content.Headers.ContentType?.MediaType ?? "application/octet-stream");
    }

    private string BuildUrl(string path)
    {
        // ApiBaseUrl in config points at .../api/control-management; the
        // bulk-upload controller lives at .../api/control-management/bulk-upload.
        var baseUrl = (configuration["ApiBaseUrl"] ?? "https://localhost:7192/api/control-management").TrimEnd('/');
        return baseUrl + "/bulk-upload" + path;
    }

    private bool TrySession(out string token, out string[] roles)
    {
        token = HttpContext.Session.GetString(SessionIdentity.TokenKey) ?? "";
        roles = (HttpContext.Session.GetString(SessionIdentity.RolesKey) ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries);
        return !string.IsNullOrWhiteSpace(HttpContext.Session.GetString(SessionIdentity.UserKey))
            && !string.IsNullOrWhiteSpace(token);
    }
}
