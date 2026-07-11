using ControlManagement.Web.Models;
using ControlManagement.Web.Security;
using ControlManagement.Web.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;

namespace ControlManagement.Web.Controllers;

/// <summary>
/// Login is delegated to the API.  This controller only handles the form/session
/// shell - it has no direct database access, no password hashing, and no
/// file-based fallback user list.
/// </summary>
public sealed class LoginController(AuthApiClient authClient,
    ILogger<LoginController> logger) : Controller
{
    [HttpGet]
    public IActionResult Index(string? returnUrl = null)
    {
        if (HttpContext.Session.GetString(SessionIdentity.UserKey) is not null)
            return RedirectToAction("Index", "Repository");
        return View(new LoginViewModel { ReturnUrl = returnUrl });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [EnableRateLimiting("login")]
    public async Task<IActionResult> Index(LoginViewModel model, CancellationToken cancellationToken)
    {
        if (!ModelState.IsValid) return View(model);

        var result = await authClient.LoginAsync(model.Email, model.Password, cancellationToken);
        if (!result.Success)
        {
            logger.LogWarning("API login rejected for '{Identifier}' from {Remote}: {Message}",
                model.Email, HttpContext.Connection.RemoteIpAddress, result.Message);
            ModelState.AddModelError("", string.IsNullOrWhiteSpace(result.Message)
                ? "Invalid Login ID / Email or Password."
                : result.Message);
            return View(model);
        }

        HttpContext.Session.Clear();
        HttpContext.Session.SetString(SessionIdentity.UserKey, result.LoginId);
        HttpContext.Session.SetString(SessionIdentity.UserNameKey, result.UserName);
        HttpContext.Session.SetString(SessionIdentity.RolesKey, string.Join(',',
            result.Roles.Concat(result.Permissions).Distinct(StringComparer.OrdinalIgnoreCase)));
        HttpContext.Session.SetString(SessionIdentity.TokenKey, result.Token);
        if (result.IsPasswordChangeRequired)
            HttpContext.Session.SetString(SessionIdentity.PasswordChangeRequiredKey, "1");

        logger.LogInformation("Sign-in via API succeeded for {LoginId} (changeRequired={ChangeRequired}).",
            result.LoginId, result.IsPasswordChangeRequired);

        if (result.IsPasswordChangeRequired)
            return RedirectToAction("ChangePassword", "Account", new { returnUrl = model.ReturnUrl });
        if (Url.IsLocalUrl(model.ReturnUrl)) return LocalRedirect(model.ReturnUrl!);
        return RedirectToAction("Index", "Repository");
    }

    [HttpGet]
    public IActionResult ForgotPassword() => View(new ForgotPasswordViewModel());

    [HttpPost]
    [ValidateAntiForgeryToken]
    [EnableRateLimiting("login")]
    public IActionResult ForgotPassword(ForgotPasswordViewModel model)
    {
        // Until email/SMS integration is wired the user-facing message is
        // intentionally generic ("if the account exists, an admin has been
        // notified") and the admin must run the Reset Password action on the
        // User Management grid.  We log the request so the admin can act on it.
        if (!ModelState.IsValid) return View(model);
        logger.LogWarning("Forgot Password requested for identifier '{Identifier}' from {Remote}. Admin must run Reset Password on User Management.",
            model.Identifier, HttpContext.Connection.RemoteIpAddress);
        model.Submitted = true;
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public IActionResult Logout()
    {
        logger.LogInformation("Sign-out for {User}.", HttpContext.Session.GetString(SessionIdentity.UserKey));
        HttpContext.Session.Clear();
        return RedirectToAction(nameof(Index));
    }
}
