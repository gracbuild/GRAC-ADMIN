using Microsoft.Extensions.Options;

namespace ControlManagement.Security;

public sealed class PermissionPolicy(IOptions<SecurityOptions> options)
{
    private readonly SecurityOptions _options = options.Value;

    public bool IsAllowed(IEnumerable<string> roles, string area, string action) =>
        roles.Any(role => PermissionsFor(role).Any(permission => Matches(permission, area, action)));

    public string[] ActionsFor(IEnumerable<string> roles, string area) =>
        new[] { "VIEW", "ADD", "EDIT", "DELETE", "APPROVE", "REJECT" }
            .Where(action => IsAllowed(roles, area, action))
            .ToArray();

    private IEnumerable<string> PermissionsFor(string role)
    {
        if (string.IsNullOrWhiteSpace(role)) return [];

        if (_options.RolePermissions.TryGetValue(role, out var permissions))
            return role.Contains(':', StringComparison.Ordinal) ? permissions.Append(role) : permissions;

        return role.Contains(':', StringComparison.Ordinal) ? [role] : [];
    }

    private static bool Matches(string permission, string area, string action)
    {
        var parts = permission.Split(':', 2);
        return parts.Length == 2
            && (parts[0] == "*" || parts[0].Equals(area, StringComparison.OrdinalIgnoreCase))
            && (parts[1] == "*" || parts[1].Equals(action, StringComparison.OrdinalIgnoreCase));
    }
}
