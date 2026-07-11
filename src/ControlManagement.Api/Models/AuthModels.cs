namespace ControlManagement.Api.Models;

public sealed class LoginRequest
{
    public string LoginId { get; set; } = "";
    public string Password { get; set; } = "";
}

public sealed class LoginResponse
{
    public bool Success { get; set; }
    public string Message { get; set; } = "";
    public long UserId { get; set; }
    public string UserName { get; set; } = "";
    public string LoginId { get; set; } = "";
    public string Email { get; set; } = "";
    public IReadOnlyList<string> Roles { get; set; } = [];
    public IReadOnlyList<string> Permissions { get; set; } = [];
    public string Token { get; set; } = "";
    public bool IsPasswordChangeRequired { get; set; }
}

public sealed class ChangePasswordRequest
{
    public string LoginId { get; set; } = "";
    public string CurrentPassword { get; set; } = "";
    public string NewPassword { get; set; } = "";
}

public sealed class ChangePasswordResponse
{
    public bool Success { get; set; }
    public string Message { get; set; } = "";
}

public sealed class AdminResetPasswordRequest
{
    public long UserId { get; set; }
}

public sealed class AdminResetPasswordResponse
{
    public bool Success { get; set; }
    public string Message { get; set; } = "";
    public long UserId { get; set; }
}
