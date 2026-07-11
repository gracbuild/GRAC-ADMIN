using System.ComponentModel.DataAnnotations;

namespace ControlManagement.Web.Models;

public sealed class ChangePasswordViewModel
{
    [Required, DataType(DataType.Password), Display(Name = "Current Password")]
    public string CurrentPassword { get; set; } = "";

    [Required, DataType(DataType.Password), Display(Name = "New Password"),
     StringLength(128, MinimumLength = 8, ErrorMessage = "New password must be at least 8 characters long.")]
    public string NewPassword { get; set; } = "";

    [Required, DataType(DataType.Password), Display(Name = "Confirm New Password"),
     Compare(nameof(NewPassword), ErrorMessage = "Password and confirmation do not match.")]
    public string ConfirmPassword { get; set; } = "";

    public string? ReturnUrl { get; set; }

    public bool IsFirstLogin { get; set; }
}
