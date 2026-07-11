using ControlManagement.Api.Models;
using ControlManagement.Api.Services;
using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;
using PermissionPolicy = ControlManagement.Security.PermissionPolicy;

namespace ControlManagement.Api.Controllers;

/// <summary>
/// All authentication endpoints.  The Web tier calls these via HTTPS; it does
/// not (and must not) hold a database connection string.
///
/// POST /api/control-management/auth/login            (no Bearer required)
/// POST /api/control-management/auth/change-password  (Bearer required)
/// </summary>
[ApiController]
[Route("api/control-management/auth")]
public sealed class AuthController(IAuthService authService,
    SignedAccessTokenService tokenService,
    PermissionPolicy permissionPolicy,
    ILogger<AuthController> logger) : ControllerBase
{
    [HttpPost("login")]
    public async Task<IActionResult> Login([FromBody] LoginRequest request, CancellationToken cancellationToken)
    {
        if (request is null)
            return BadRequest(new LoginResponse { Success = false, Message = "Request body is required." });

        var result = await authService.LoginAsync(request, cancellationToken);
        if (!result.Success)
            return Unauthorized(result);
        return Ok(result);
    }

    [HttpPost("change-password")]
    public async Task<IActionResult> ChangePassword([FromBody] ChangePasswordRequest request, CancellationToken cancellationToken)
    {
        if (request is null)
            return BadRequest(new ChangePasswordResponse { Success = false, Message = "Request body is required." });

        // Require the same signed Bearer token format that secure/manage uses.
        var token = ReadAuthorizationToken();
        if (!tokenService.TryValidate(token, out var principal))
            return Unauthorized(new ChangePasswordResponse { Success = false, Message = "Authorization failed." });

        // Defence in depth: ignore any LoginId in the body - the change always
        // applies to the principal that holds the token.
        request.LoginId = principal.Subject;

        var result = await authService.ChangePasswordAsync(request, cancellationToken);
        if (!result.Success)
        {
            logger.LogInformation("change-password rejected for {LoginId}: {Message}", principal.Subject, result.Message);
            return BadRequest(result);
        }
        return Ok(result);
    }

    /// <summary>
    /// Admin-initiated reset of a user's password to Security:DefaultUserPassword.
    /// Requires a valid signed Bearer token from a principal that holds the
    /// user-management EDIT permission (or *:*).  Sets IsPasswordChangeRequired=1
    /// so the target user is forced through Change Password on next sign-in.
    /// </summary>
    [HttpPost("admin-reset-password")]
    public async Task<IActionResult> AdminResetPassword([FromBody] AdminResetPasswordRequest request, CancellationToken cancellationToken)
    {
        if (request is null)
            return BadRequest(new AdminResetPasswordResponse { Success = false, Message = "Request body is required." });

        var token = ReadAuthorizationToken();
        if (!tokenService.TryValidate(token, out var principal))
            return Unauthorized(new AdminResetPasswordResponse { Success = false, Message = "Authorization failed." });

        if (!permissionPolicy.IsAllowed(principal.Roles, "user-management", "EDIT"))
        {
            logger.LogWarning("admin-reset-password forbidden for {Acting} (lacks user-management:EDIT).", principal.Subject);
            return StatusCode(StatusCodes.Status403Forbidden,
                new AdminResetPasswordResponse { Success = false, Message = "You do not have permission to reset user passwords." });
        }

        var result = await authService.AdminResetPasswordAsync(request, principal.Subject, cancellationToken);
        if (!result.Success) return BadRequest(result);
        return Ok(result);
    }

    private string ReadAuthorizationToken()
    {
        var authorization = Request.Headers.Authorization.ToString();
        return authorization.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) ? authorization[7..] : authorization;
    }
}
