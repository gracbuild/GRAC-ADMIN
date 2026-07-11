using ControlManagement.Web.Models;
using ControlManagement.Web.Security;
using ControlManagement.Web.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;

namespace ControlManagement.Web.Controllers;

public sealed class AccountController(AuthApiClient authClient,
    ILogger<AccountController> logger) : Controller
{
    [HttpGet]
    public IActionResult ChangePassword(string? returnUrl = null)
    {
        var loginId = HttpContext.Session.GetString(SessionIdentity.UserKey);
        if (string.IsNullOrWhiteSpace(loginId)) return RedirectToAction("Index", "Login");
        var isFirstLogin = !string.IsNullOrEmpty(HttpContext.Session.GetString(SessionIdentity.PasswordChangeRequiredKey));
        return View(new ChangePasswordViewModel { ReturnUrl = returnUrl, IsFirstLogin = isFirstLogin });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [EnableRateLimiting("login")]
    public async Task<IActionResult> ChangePassword(ChangePasswordViewModel model, CancellationToken cancellationToken)
    {
        var loginId = HttpContext.Session.GetString(SessionIdentity.UserKey);
        var token   = HttpContext.Session.GetString(SessionIdentity.TokenKey);
        if (string.IsNullOrWhiteSpace(loginId) || string.IsNullOrWhiteSpace(token))
            return RedirectToAction("Index", "Login");
        model.IsFirstLogin = !string.IsNullOrEmpty(HttpContext.Session.GetString(SessionIdentity.PasswordChangeRequiredKey));
        if (!ModelState.IsValid) return View(model);

        var result = await authClient.ChangePasswordAsync(token, model.CurrentPassword, model.NewPassword, cancellationToken);
        if (!result.Success)
        {
            ModelState.AddModelError("", result.Message);
            return View(model);
        }
        logger.LogInformation("Password change succeeded via API for {LoginId}.", loginId);
        HttpContext.Session.Remove(SessionIdentity.PasswordChangeRequiredKey);
        TempData["AccountMessage"] = "Password updated successfully.";
        if (Url.IsLocalUrl(model.ReturnUrl)) return LocalRedirect(model.ReturnUrl!);
        return RedirectToAction("Index", "Repository");
    }
}
