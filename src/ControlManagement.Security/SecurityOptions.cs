namespace ControlManagement.Security;

public sealed class SecurityOptions
{
    public const string SectionName = "Security";
    public string TokenSigningKey { get; set; } = "";
    public int TokenLifetimeMinutes { get; set; } = 30;
    public int RequestValidityMinutes { get; set; } = 5;
    public Dictionary<string, string[]> RolePermissions { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}
