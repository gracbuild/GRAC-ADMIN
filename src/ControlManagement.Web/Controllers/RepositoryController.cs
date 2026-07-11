using ControlManagement.Web.Models;
using ControlManagement.Security;
using ControlManagement.Web.Security;
using ControlManagement.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace ControlManagement.Web.Controllers;

public sealed class RepositoryController(PermissionPolicy permissionPolicy, ControlMenuService menuService) : Controller
{
    public async Task<IActionResult> Index(string? areaKey = null, CancellationToken cancellationToken = default)
    {
        if (!IsSignedIn()) return RedirectToAction("Index", "Login", new { returnUrl = Request.Path });
        ViewBag.ApiBaseUrl = GatewayBaseUrl();
        var roles = Roles();
        var menuItems = await menuService.GetVisibleMenuAsync(Token(), UserLoginId(), roles, cancellationToken);
        var menuScreens = ScreensFromMenu(menuItems);
        ViewBag.Screens = menuScreens;
        ViewBag.MenuItems = menuItems;
        ViewBag.UserName = HttpContext.Session.GetString(SessionIdentity.UserNameKey) ?? UserLoginId();
        ViewBag.CanViewAudit = permissionPolicy.IsAllowed(Roles(), "audit-trace", "VIEW");
        if (string.IsNullOrWhiteSpace(areaKey)) return View("Dashboard");
        var screen = RepositoryScreen.All.FirstOrDefault(x => x.Key.Equals(areaKey, StringComparison.OrdinalIgnoreCase));
        if (screen is null) return NotFound();
        if (!permissionPolicy.IsAllowed(Roles(), screen.Key, "VIEW")) return Forbid();
        ViewBag.Permissions = permissionPolicy.ActionsFor(Roles(), screen.Key);
        return View("Manage", screen);
    }

    [HttpGet]
    public async Task<IActionResult> Statement(string mode = "add", int? id = null, int? releaseId = null, int? nodeId = null, CancellationToken cancellationToken = default)
    {
        if (!IsSignedIn()) return RedirectToAction("Index", "Login", new { returnUrl = Request.Path });
        var normalizedMode = string.IsNullOrWhiteSpace(mode) ? "add" : mode.ToLowerInvariant();
        var requiredAction = normalizedMode switch
        {
            "view" => "VIEW",
            "edit" => "EDIT",
            _ => "ADD"
        };
        if (!permissionPolicy.IsAllowed(Roles(), "framework-statements", requiredAction)) return Forbid();

        ViewBag.ApiBaseUrl = GatewayBaseUrl();
        var roles = Roles();
        var menuItems = await menuService.GetVisibleMenuAsync(Token(), UserLoginId(), roles, cancellationToken);
        ViewBag.Screens = ScreensFromMenu(menuItems);
        ViewBag.MenuItems = menuItems;
        ViewBag.UserName = HttpContext.Session.GetString(SessionIdentity.UserNameKey) ?? UserLoginId();
        ViewBag.Permissions = permissionPolicy.ActionsFor(Roles(), "framework-statements");
        ViewBag.CurrentArea = "framework-statements";
        ViewBag.Mode = normalizedMode;
        ViewBag.StatementId = id.GetValueOrDefault();
        ViewBag.ReleaseId = releaseId.GetValueOrDefault();
        ViewBag.NodeId = nodeId.GetValueOrDefault();
        ViewBag.ReturnUrl = Request.Headers.Referer.ToString();
        return View("StatementForm");
    }

    [HttpGet]
    public async Task<IActionResult> ObligationMapping(string mode = "add", int? id = null, int? requirementId = null, CancellationToken cancellationToken = default)
    {
        if (!IsSignedIn()) return RedirectToAction("Index", "Login", new { returnUrl = Request.Path });
        var normalizedMode = string.IsNullOrWhiteSpace(mode) ? "add" : mode.ToLowerInvariant();
        var requiredAction = normalizedMode switch
        {
            "view" => "VIEW",
            "edit" => "EDIT",
            _ => "ADD"
        };
        if (!permissionPolicy.IsAllowed(Roles(), "obligation-mappings", requiredAction)) return Forbid();

        ViewBag.ApiBaseUrl = GatewayBaseUrl();
        var roles = Roles();
        var menuItems = await menuService.GetVisibleMenuAsync(Token(), UserLoginId(), roles, cancellationToken);
        ViewBag.Screens = ScreensFromMenu(menuItems);
        ViewBag.MenuItems = menuItems;
        ViewBag.UserName = HttpContext.Session.GetString(SessionIdentity.UserNameKey) ?? UserLoginId();
        ViewBag.Permissions = permissionPolicy.ActionsFor(Roles(), "obligation-mappings");
        ViewBag.CurrentArea = "obligation-mappings";
        ViewBag.Mode = normalizedMode;
        ViewBag.MappingId = id.GetValueOrDefault();
        ViewBag.RequirementId = requirementId.GetValueOrDefault();
        ViewBag.ReturnUrl = Request.Headers.Referer.ToString();
        return View("ObligationMappingForm");
    }

    [HttpGet("audit-trace")]
    public IActionResult AuditTrace()
    {
        if (!IsSignedIn()) return RedirectToAction("Index", "Login", new { returnUrl = Request.Path });
        if (!permissionPolicy.IsAllowed(Roles(), "audit-trace", "VIEW")) return Forbid();
        return RedirectToAction(nameof(Index), new { areaKey = "audit-trace" });
    }

    private bool IsSignedIn() => HttpContext.Session.GetString(SessionIdentity.UserKey) is not null;
    private string UserLoginId() => HttpContext.Session.GetString(SessionIdentity.UserKey) ?? "";
    private string Token() => HttpContext.Session.GetString(SessionIdentity.TokenKey) ?? "";
    private string[] Roles() => (HttpContext.Session.GetString(SessionIdentity.RolesKey) ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries);
    private RepositoryScreen[] VisibleScreens(string[] roles) => RepositoryScreen.All.Where(screen => permissionPolicy.IsAllowed(roles, screen.Key, "VIEW")).ToArray();
    private static RepositoryScreen[] ScreensFromMenu(IReadOnlyList<ControlMenuItem> menuItems) =>
        menuItems.SelectMany(Flatten).Select(item => item.Screen).OfType<RepositoryScreen>().DistinctBy(screen => screen.Key).ToArray();
    private static IEnumerable<ControlMenuItem> Flatten(ControlMenuItem item) =>
        new[] { item }.Concat(item.Children.SelectMany(Flatten));
    private string GatewayBaseUrl() => $"{Request.PathBase}/control-management-gateway";
}
