namespace ControlManagement.Web.Models;

public sealed record ControlMenuItem(
    long Id,
    long? ParentMenuId,
    string MenuKey,
    string MenuName,
    string? MenuUrl,
    string? IconClass,
    int DisplayOrder,
    RepositoryScreen? Screen,
    IReadOnlyList<ControlMenuItem> Children);
