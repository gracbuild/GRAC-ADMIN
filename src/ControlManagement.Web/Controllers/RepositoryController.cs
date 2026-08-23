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
        if (!IsSignedIn()) return RedirectToAction("Index", "Login", new { returnUrl = (Request.PathBase + Request.Path).Value });
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
        if (!IsSignedIn()) return RedirectToAction("Index", "Login", new { returnUrl = (Request.PathBase + Request.Path).Value });
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
        if (!IsSignedIn()) return RedirectToAction("Index", "Login", new { returnUrl = (Request.PathBase + Request.Path).Value });
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

    /// <summary>
    /// Merged Obligation Master form (Phase 3).  Captures the master fields,
    /// the taxonomy type, that type's typed detail, and evidence links on a
    /// single page saved through the 'obligation-composite' entity type.
    /// Replaces the previous two-step flow (Obligation Master dialog, then
    /// the separate Manage Obligation Type Details page).
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> ObligationMaster(string mode = "add", int? id = null, CancellationToken cancellationToken = default)
    {
        if (!IsSignedIn()) return RedirectToAction("Index", "Login", new { returnUrl = (Request.PathBase + Request.Path).Value });
        var normalizedMode = string.IsNullOrWhiteSpace(mode) ? "add" : mode.ToLowerInvariant();
        var requiredAction = normalizedMode switch
        {
            "view" => "VIEW",
            "edit" => "EDIT",
            _ => "ADD"
        };
        if (!permissionPolicy.IsAllowed(Roles(), "obligations", requiredAction)) return Forbid();

        ViewBag.ApiBaseUrl = GatewayBaseUrl();
        var roles = Roles();
        var menuItems = await menuService.GetVisibleMenuAsync(Token(), UserLoginId(), roles, cancellationToken);
        ViewBag.Screens = ScreensFromMenu(menuItems);
        ViewBag.MenuItems = menuItems;
        ViewBag.UserName = HttpContext.Session.GetString(SessionIdentity.UserNameKey) ?? UserLoginId();
        ViewBag.Permissions = permissionPolicy.ActionsFor(Roles(), "obligations");
        ViewBag.CurrentArea = "obligations";
        ViewBag.Mode = normalizedMode;
        ViewBag.ObligationId = id.GetValueOrDefault();
        ViewBag.ReturnUrl = Request.Headers.Referer.ToString();
        return View("ObligationMasterForm");
    }

    /// <summary>
    /// Event checklist fill page (Phase B).  Lists every assurance generated
    /// for one event occurrence and lets the operator record Pass / Fail /
    /// Not Applicable against each.  Writes directly - checklist completion is
    /// operational evidence, not policy, and does not route through
    /// maker-checker (see migration 035).
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> EventChecklist(int id, CancellationToken cancellationToken = default)
    {
        if (!IsSignedIn()) return RedirectToAction("Index", "Login", new { returnUrl = (Request.PathBase + Request.Path).Value });
        if (!permissionPolicy.IsAllowed(Roles(), "assurance-occurrences", "VIEW")) return Forbid();

        ViewBag.ApiBaseUrl = GatewayBaseUrl();
        var roles = Roles();
        var menuItems = await menuService.GetVisibleMenuAsync(Token(), UserLoginId(), roles, cancellationToken);
        ViewBag.Screens = ScreensFromMenu(menuItems);
        ViewBag.MenuItems = menuItems;
        ViewBag.UserName = HttpContext.Session.GetString(SessionIdentity.UserNameKey) ?? UserLoginId();
        ViewBag.Permissions = permissionPolicy.ActionsFor(Roles(), "assurance-occurrences");
        ViewBag.CurrentArea = "assurance-occurrences";
        ViewBag.OccurrenceId = id;
        ViewBag.ReturnUrl = Request.Headers.Referer.ToString();
        return View("EventChecklistForm");
    }

    /// <summary>
    /// Raise an event occurrence (Phase B).  Its own page rather than the
    /// shared dialog because the subject picker depends on the chosen event
    /// type - the generic schema-driven dialog has no way to express a
    /// dependent lookup.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> RaiseEvent(CancellationToken cancellationToken = default)
    {
        if (!IsSignedIn()) return RedirectToAction("Index", "Login", new { returnUrl = (Request.PathBase + Request.Path).Value });
        if (!permissionPolicy.IsAllowed(Roles(), "assurance-occurrences", "ADD")) return Forbid();

        ViewBag.ApiBaseUrl = GatewayBaseUrl();
        var roles = Roles();
        var menuItems = await menuService.GetVisibleMenuAsync(Token(), UserLoginId(), roles, cancellationToken);
        ViewBag.Screens = ScreensFromMenu(menuItems);
        ViewBag.MenuItems = menuItems;
        ViewBag.UserName = HttpContext.Session.GetString(SessionIdentity.UserNameKey) ?? UserLoginId();
        ViewBag.Permissions = permissionPolicy.ActionsFor(Roles(), "assurance-occurrences");
        ViewBag.CurrentArea = "assurance-occurrences";
        ViewBag.ReturnUrl = Request.Headers.Referer.ToString();
        return View("RaiseEventForm");
    }

    /// <summary>
    /// SLA Master form.  Captures the process / classification pair and the
    /// duration, time basis and warning / escalation thresholds that drive
    /// breach alerts across the assurance runtime.  Supports add, edit, view
    /// and inactive modes; the inactive flow reuses the same view chrome so
    /// deactivation carries a mandatory reason (remarks) captured as evidence.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> SlaMaster(string mode = "add", int? id = null, CancellationToken cancellationToken = default)
    {
        if (!IsSignedIn()) return RedirectToAction("Index", "Login", new { returnUrl = (Request.PathBase + Request.Path).Value });
        var normalizedMode = string.IsNullOrWhiteSpace(mode) ? "add" : mode.ToLowerInvariant();
        var requiredAction = normalizedMode switch
        {
            "view"     => "VIEW",
            "edit"     => "EDIT",
            "inactive" => "INACTIVE",
            _          => "ADD"
        };
        if (!permissionPolicy.IsAllowed(Roles(), "sla-master", requiredAction)) return Forbid();

        ViewBag.ApiBaseUrl = GatewayBaseUrl();
        var roles = Roles();
        var menuItems = await menuService.GetVisibleMenuAsync(Token(), UserLoginId(), roles, cancellationToken);
        ViewBag.Screens = ScreensFromMenu(menuItems);
        ViewBag.MenuItems = menuItems;
        ViewBag.UserName = HttpContext.Session.GetString(SessionIdentity.UserNameKey) ?? UserLoginId();
        ViewBag.Permissions = permissionPolicy.ActionsFor(Roles(), "sla-master");
        ViewBag.CurrentArea = "sla-master";
        ViewBag.Mode = normalizedMode;
        ViewBag.SlaId = id.GetValueOrDefault();
        ViewBag.ReturnUrl = Request.Headers.Referer.ToString();
        return View("SlaMasterForm");
    }

    [HttpGet]
    public async Task<IActionResult> ObligationTypeDetail(string mode = "edit", int? obligationId = null, CancellationToken cancellationToken = default)
    {
        if (!IsSignedIn()) return RedirectToAction("Index", "Login", new { returnUrl = (Request.PathBase + Request.Path).Value });
        var normalizedMode = string.IsNullOrWhiteSpace(mode) ? "edit" : mode.ToLowerInvariant();
        var requiredAction = normalizedMode switch
        {
            "view" => "VIEW",
            _      => "EDIT"
        };
        // Typed detail authoring rides on the Obligation Master permission area
        // -- matches the API's ObligationTaxonomyPermissionAliases policy.
        if (!permissionPolicy.IsAllowed(Roles(), "obligations", requiredAction)) return Forbid();

        ViewBag.ApiBaseUrl = GatewayBaseUrl();
        var roles = Roles();
        var menuItems = await menuService.GetVisibleMenuAsync(Token(), UserLoginId(), roles, cancellationToken);
        ViewBag.Screens = ScreensFromMenu(menuItems);
        ViewBag.MenuItems = menuItems;
        ViewBag.UserName = HttpContext.Session.GetString(SessionIdentity.UserNameKey) ?? UserLoginId();
        ViewBag.Permissions = permissionPolicy.ActionsFor(Roles(), "obligations");
        ViewBag.CurrentArea = "obligations";
        ViewBag.Mode = normalizedMode;
        ViewBag.ObligationId = obligationId.GetValueOrDefault();
        ViewBag.ReturnUrl = Request.Headers.Referer.ToString();
        return View("ObligationTypeDetailForm");
    }

    [HttpGet("audit-trace")]
    public IActionResult AuditTrace()
    {
        if (!IsSignedIn()) return RedirectToAction("Index", "Login", new { returnUrl = (Request.PathBase + Request.Path).Value });
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
