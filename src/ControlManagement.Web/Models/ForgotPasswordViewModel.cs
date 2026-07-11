using System.ComponentModel.DataAnnotations;

namespace ControlManagement.Web.Models;

public sealed class ForgotPasswordViewModel
{
    // Login ID OR Email - matched the same way as the login form.
    [Required, StringLength(250, MinimumLength = 1), Display(Name = "Login ID or Email")]
    public string Identifier { get; set; } = "";

    /// <summary>
    /// True after a successful submit.  The success view is intentionally
    /// generic ("if the account exists, an admin has been notified") so we do
    /// not reveal whether the identifier is valid (user enumeration defence).
    /// </summary>
    public bool Submitted { get; set; }
}
