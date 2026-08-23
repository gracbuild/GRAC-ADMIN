using System.Net.Http.Headers;
using ControlManagement.Security;
using ControlManagement.Web.Security;
using ControlManagement.Web.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;

namespace ControlManagement.Web.Controllers;

// -----------------------------------------------------------------------------
// Web-tier controller for the Single-Form Upload page.
//   GET /Repository/SingleFormUpload            -> renders the page.
// -----------------------------------------------------------------------------

public sealed class SingleFormUploadController(PermissionPolicy permissionPolicy, ControlMenuService menuService) : Controller
{
    // Same "at least one uploadable form" gate as the layout uses.
    // Note: obligation-evidence child form maps to the "obligations"
    // permission area, so no new area needs listing here.
    private static readonly string[] SingleFormAreas =
    [
        "source-structure", "framework-statements", "requirements",
        "obligations", "source-control-mappings", "obligation-mappings"
    ];

    [HttpGet("/Repository/SingleFormUpload")]
    public async Task<IActionResult> Index(CancellationToken cancellationToken)
    {
        if (!IsSignedIn()) return RedirectToAction("Index", "Login", new { returnUrl = (Request.PathBase + Request.Path).Value });
        var roles = Roles();
        if (!SingleFormAreas.Any(a => permissionPolicy.IsAllowed(roles, a, "ADD"))) return Forbid();

        var menuItems = await menuService.GetVisibleMenuAsync(Token(), UserLoginId(), roles, cancellationToken);
        ViewBag.MenuItems = menuItems;
        ViewBag.Screens = Array.Empty<ControlManagement.Web.Models.RepositoryScreen>();
        ViewBag.UserName = HttpContext.Session.GetString(SessionIdentity.UserNameKey) ?? UserLoginId();
        ViewBag.CurrentArea = "single-form-upload";
        ViewBag.GatewayBaseUrl = $"{Request.PathBase}/single-form-upload-gateway";
        return View("~/Views/Repository/SingleFormUpload.cshtml");
    }

    private bool IsSignedIn() => HttpContext.Session.GetString(SessionIdentity.UserKey) is not null;
    private string UserLoginId() => HttpContext.Session.GetString(SessionIdentity.UserKey) ?? "";
    private string Token() => HttpContext.Session.GetString(SessionIdentity.TokenKey) ?? "";
    private string[] Roles() => (HttpContext.Session.GetString(SessionIdentity.RolesKey) ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries);
}

[ApiController]
[Route("single-form-upload-gateway")]
[EnableRateLimiting("gateway")]
public sealed class SingleFormUploadGatewayController(PermissionPolicy permissionPolicy,
    IHttpClientFactory httpClientFactory, IConfiguration configuration,
    ILogger<SingleFormUploadGatewayController> logger) : ControllerBase
{
    private static readonly Dictionary<string, string> EntityToArea = new(StringComparer.OrdinalIgnoreCase)
    {
        ["source-structure"] = "source-structure",
        ["framework-statements"] = "framework-statements",
        ["requirements"] = "requirements",
        ["obligations"] = "obligations",
        ["obligation-evidence"] = "obligations",
        ["source-control-mappings"] = "source-control-mappings",
        ["obligation-mappings"] = "obligation-mappings"
    };

    // ---- Simple JSON proxies -----------------------------------------------
    [HttpGet("forms")]
    public Task<IActionResult> Forms(CancellationToken ct) => JsonProxyGet("/forms", null, ct);

    [HttpGet("releases")]
    public Task<IActionResult> Releases(CancellationToken ct) => JsonProxyGet("/releases", null, ct);

    // ---- Template download -------------------------------------------------
    [HttpGet("template")]
    public async Task<IActionResult> Template([FromQuery] string entity, [FromQuery] long? releaseId, CancellationToken ct)
    {
        if (!TrySession(out var token, out var roles)) return Unauthorized(new { success = false, message = "Session expired." });
        if (!IsAllowedForEntity(entity, roles)) return Forbid();
        var query = $"?entity={Uri.EscapeDataString(entity)}" + (releaseId.HasValue ? $"&releaseId={releaseId.Value}" : "");
        var http = httpClientFactory.CreateClient();
        using var msg = new HttpRequestMessage(HttpMethod.Get, BuildUrl("/template" + query));
        msg.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await http.SendAsync(msg, ct);
        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync(ct);
            return StatusCode((int)response.StatusCode, string.IsNullOrWhiteSpace(body)
                ? "{\"success\":false,\"message\":\"Template download failed.\"}"
                : body);
        }
        var bytes = await response.Content.ReadAsByteArrayAsync(ct);
        var mediaType = response.Content.Headers.ContentType?.MediaType ?? "application/octet-stream";
        var fileName = response.Content.Headers.ContentDisposition?.FileName?.Trim('"') ?? "single-form-template.xlsx";
        return File(bytes, mediaType, fileName);
    }

    // ---- Validate / Commit (multipart) -------------------------------------
    [HttpPost("validate")]
    [ValidateAntiForgeryToken]
    [RequestSizeLimit(52428800)]
    public Task<IActionResult> Validate([FromForm] string entity, [FromForm] long? releaseId, [FromForm] IFormFile file, CancellationToken ct) =>
        ProxyMultipart("/validate", entity, releaseId, file, ct);

    [HttpPost("commit")]
    [ValidateAntiForgeryToken]
    [RequestSizeLimit(52428800)]
    public Task<IActionResult> Commit(
        [FromForm] string entity,
        [FromForm] long? releaseId,
        [FromForm] string? mode,
        [FromForm] string? confirmReleaseCode,
        [FromForm] IFormFile file,
        CancellationToken ct) => ProxyMultipart("/commit", entity, releaseId, file, ct, mode, confirmReleaseCode);

    [HttpGet("preview-replace")]
    public async Task<IActionResult> PreviewReplace([FromQuery] string entity, [FromQuery] long? releaseId, CancellationToken ct)
    {
        if (!TrySession(out var token, out var roles)) return Unauthorized(new { success = false, message = "Session expired." });
        if (!IsAllowedForEntity(entity, roles)) return Forbid();
        var query = "?entity=" + Uri.EscapeDataString(entity) + (releaseId.HasValue ? "&releaseId=" + releaseId.Value : "");
        return await JsonProxyGet("/preview-replace" + query, null, ct);
    }

    // ---- Helpers -----------------------------------------------------------
    private async Task<IActionResult> ProxyMultipart(string path, string entity, long? releaseId, IFormFile file, CancellationToken ct, string? mode = null, string? confirmReleaseCode = null)
    {
        if (!TrySession(out var token, out var roles)) return Unauthorized(new { success = false, message = "Session expired." });
        if (!IsAllowedForEntity(entity, roles)) return Forbid();
        if (file is null || file.Length == 0) return BadRequest(new { success = false, message = "No file uploaded." });

        var http = httpClientFactory.CreateClient();
        http.Timeout = TimeSpan.FromMinutes(10);
        using var msg = new HttpRequestMessage(HttpMethod.Post, BuildUrl(path));
        msg.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        using var content = new MultipartFormDataContent();
        content.Add(new StringContent(entity ?? ""), "entity");
        if (releaseId.HasValue) content.Add(new StringContent(releaseId.Value.ToString()), "releaseId");
        if (!string.IsNullOrWhiteSpace(mode)) content.Add(new StringContent(mode), "mode");
        if (!string.IsNullOrWhiteSpace(confirmReleaseCode)) content.Add(new StringContent(confirmReleaseCode), "confirmReleaseCode");
        var streamContent = new StreamContent(file.OpenReadStream());
        streamContent.Headers.ContentType = new MediaTypeHeaderValue(string.IsNullOrWhiteSpace(file.ContentType) ? "application/octet-stream" : file.ContentType);
        content.Add(streamContent, "file", file.FileName);
        msg.Content = content;

        using var response = await http.SendAsync(msg, ct);
        var body = await response.Content.ReadAsStringAsync(ct);
        if (!response.IsSuccessStatusCode)
            logger.LogWarning("Single-form proxy {Path} failed with {StatusCode}: {Body}", path, response.StatusCode, body);
        return Content(string.IsNullOrWhiteSpace(body) ? "{\"success\":false,\"message\":\"Empty response.\"}" : body, "application/json");
    }

    private async Task<IActionResult> JsonProxyGet(string path, string? query, CancellationToken ct)
    {
        if (!TrySession(out var token, out _)) return Unauthorized(new { success = false, message = "Session expired." });
        var http = httpClientFactory.CreateClient();
        using var msg = new HttpRequestMessage(HttpMethod.Get, BuildUrl(path + (query ?? "")));
        msg.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await http.SendAsync(msg, ct);
        var body = await response.Content.ReadAsStringAsync(ct);
        return Content(string.IsNullOrWhiteSpace(body) ? "{\"success\":false,\"message\":\"Empty response.\"}" : body, "application/json");
    }

    private bool IsAllowedForEntity(string entity, string[] roles)
    {
        if (!EntityToArea.TryGetValue(entity ?? "", out var area)) return false;
        return permissionPolicy.IsAllowed(roles, area, "ADD");
    }

    private string BuildUrl(string path)
    {
        var baseUrl = (configuration["ApiBaseUrl"] ?? "https://localhost:7192/api/control-management").TrimEnd('/');
        return baseUrl + "/single-form-upload" + path;
    }

    private bool TrySession(out string token, out string[] roles)
    {
        token = HttpContext.Session.GetString(SessionIdentity.TokenKey) ?? "";
        roles = (HttpContext.Session.GetString(SessionIdentity.RolesKey) ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries);
        return !string.IsNullOrWhiteSpace(HttpContext.Session.GetString(SessionIdentity.UserKey))
            && !string.IsNullOrWhiteSpace(token);
    }
}
