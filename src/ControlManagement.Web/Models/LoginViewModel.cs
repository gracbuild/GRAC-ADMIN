using System.ComponentModel.DataAnnotations;

namespace ControlManagement.Web.Models;

public sealed class LoginViewModel
{
    // Accepts either a Login ID (plain text, no @ required) or an Email
    // address.  The server matches against cm_user.login_id OR cm_user.email.
    [Required, StringLength(250, MinimumLength = 1), Display(Name = "Login ID or Email")]
    public string Email { get; set; } = "";

    [Required, DataType(DataType.Password)]
    public string Password { get; set; } = "";

    public string? ReturnUrl { get; set; }
}
