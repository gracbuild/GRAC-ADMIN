using System.Data;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using ControlManagement.Security;
using ControlManagement.Web.Models;

namespace ControlManagement.Web.Services;

public sealed class ControlMenuService(IConfiguration configuration, SecureRepositoryClient client, PermissionPolicy permissionPolicy, ILogger<ControlMenuService> logger)
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    public async Task<IReadOnlyList<ControlMenuItem>> GetVisibleMenuAsync(string token, string userLoginId, IReadOnlyCollection<string> permissions, CancellationToken cancellationToken)
    {
        var rows = new List<MenuRow>();
        if (!string.IsNullOrWhiteSpace(token))
        {
            try
            {
                rows = await LoadMenuRowsFromApiAsync(token, cancellationToken);
                logger.LogInformation("Control Management API menu loaded {DbRowCount} active rows for {UserLoginId}.", rows.Count, userLoginId);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Could not load Control Management menu from API for {UserLoginId}.", userLoginId);
            }
        }

        if (rows.Count == 0)
        {
            var connectionString = GetConnectionString();
            if (!string.IsNullOrWhiteSpace(connectionString))
            {
                try
                {
                    rows = await LoadMenuRowsAsync(connectionString, cancellationToken);
                    logger.LogInformation("Control Management direct DB menu loaded {DbRowCount} active rows for {UserLoginId}.", rows.Count, userLoginId);
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "Could not load Control Management direct DB menu for {UserLoginId}.", userLoginId);
                }
            }
        }

        if (rows.Count == 0)
        {
            logger.LogWarning("Control Management menu returned zero active rows for {UserLoginId}. No database menu will be rendered.", userLoginId);
            return [];
        }

        var visibleIds = rows
            .Where(row => HasMenuViewPermission(permissions, row))
            .Select(row => row.Id)
            .ToHashSet();
        var byId = rows.ToDictionary(row => row.Id);
        foreach (var id in visibleIds.ToArray())
        {
            var current = byId[id];
            while (current.ParentMenuId.HasValue && byId.TryGetValue(current.ParentMenuId.Value, out var parent))
            {
                if (!visibleIds.Add(parent.Id)) break;
                current = parent;
            }
        }
        var visible = rows.Where(row => visibleIds.Contains(row.Id)).ToList();
        logger.LogInformation("Control Management menu loaded {DbRowCount} active rows; {VisibleRowCount} rows are visible for {UserLoginId}.", rows.Count, visible.Count, userLoginId);
        return BuildTree(visible);
    }

    private async Task<List<MenuRow>> LoadMenuRowsFromApiAsync(string token, CancellationToken cancellationToken)
    {
        var response = await client.QueryAsync(token, new SecureRepositoryRequest
        {
            EntityType = "menu-management",
            Status = "Active"
        }, cancellationToken);

        using var document = JsonDocument.Parse(response);
        if (!document.RootElement.TryGetProperty("Data", out var data) && !document.RootElement.TryGetProperty("data", out data))
            return [];
        var rows = data.ValueKind == JsonValueKind.Array && data.GetArrayLength() > 0 && data[0].ValueKind == JsonValueKind.Array
            ? data[0]
            : data;
        if (rows.ValueKind != JsonValueKind.Array) return [];

        var apiRows = rows.Deserialize<List<ApiMenuRow>>(JsonOptions) ?? [];
        return apiRows
            .Select(row => row.ToMenuRow())
            .Where(row => !string.IsNullOrWhiteSpace(row.MenuKey))
            .ToList();
    }

    private async Task<List<MenuRow>> LoadMenuRowsAsync(string connectionString, CancellationToken cancellationToken)
    {
        await using var connection = new SqlConnection(ConfigureConnectionString(connectionString));
        await connection.OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT menu_id,
                   parent_menu_id,
                   menu_name,
                   menu_code,
                   route_url,
                   display_order,
                   icon,
                   status
            FROM GRAC_New.cm_menu
            WHERE status = 'Active'
            ORDER BY display_order, menu_name;
            """;
        var rows = new List<MenuRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new MenuRow(
                Convert.ToInt64(reader["menu_id"]),
                reader["parent_menu_id"] == DBNull.Value ? null : Convert.ToInt64(reader["parent_menu_id"]),
                Convert.ToString(reader["menu_code"]) ?? "",
                Convert.ToString(reader["menu_name"]) ?? "",
                Convert.ToString(reader["route_url"]),
                Convert.ToString(reader["icon"]),
                Convert.ToInt32(reader["display_order"])));
        }
        return rows;
    }

    private static IReadOnlyList<ControlMenuItem> BuildTree(List<MenuRow> rows)
    {
        var screens = RepositoryScreen.All.ToDictionary(screen => screen.Key, StringComparer.OrdinalIgnoreCase);
        var childrenByParent = rows
            .OrderBy(row => row.DisplayOrder)
            .ThenBy(row => row.MenuName)
            .GroupBy(row => row.ParentMenuId ?? 0)
            .ToDictionary(group => group.Key, group => group.ToList());

        IReadOnlyList<ControlMenuItem> BuildChildren(long? parentId)
        {
            if (!childrenByParent.TryGetValue(parentId ?? 0, out var children)) return [];
            return children.Select(row =>
            {
                screens.TryGetValue(row.MenuKey, out var screen);
                var childItems = BuildChildren(row.Id);
                return new ControlMenuItem(
                    row.Id,
                    row.ParentMenuId,
                    row.MenuKey,
                    string.IsNullOrWhiteSpace(row.MenuName) ? screen?.Title ?? row.MenuKey : row.MenuName,
                    row.MenuUrl,
                    row.IconClass,
                    row.DisplayOrder,
                    screen,
                    childItems);
            }).Where(item => item.Screen is not null || item.Children.Count > 0 || !string.IsNullOrWhiteSpace(item.MenuUrl)).ToArray();
        }

        return BuildChildren(null);
    }

    private IReadOnlyList<ControlMenuItem> BuildFallbackMenu(IReadOnlyCollection<string> permissions)
    {
        var children = RepositoryScreen.All
            .Where(screen => HasPermission(permissions, screen.Key, "VIEW"))
            .Select((screen, index) => new ControlMenuItem(
                index + 2,
                1,
                screen.Key,
                screen.Title,
                null,
                screen.Icon,
                index + 1,
                screen,
                []))
            .ToArray();

        return
        [
            new ControlMenuItem(1, null, "control-management", "Repository Management", null, "shield-alt", 1, null, children)
        ];
    }

    private bool HasPermission(IReadOnlyCollection<string> permissions, string area, string action) =>
        permissionPolicy.IsAllowed(permissions, area, action);

    private bool HasMenuViewPermission(IReadOnlyCollection<string> permissions, MenuRow row)
    {
        if (HasPermission(permissions, row.MenuKey, "VIEW")) return true;

        var areaKey = ExtractAreaKey(row.MenuUrl);
        return !string.IsNullOrWhiteSpace(areaKey) && HasPermission(permissions, areaKey, "VIEW");
    }

    private static string? ExtractAreaKey(string? menuUrl)
    {
        if (string.IsNullOrWhiteSpace(menuUrl)) return null;

        const string marker = "areaKey=";
        var index = menuUrl.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
        if (index < 0) return null;

        var value = menuUrl[(index + marker.Length)..];
        var ampIndex = value.IndexOf('&');
        if (ampIndex >= 0) value = value[..ampIndex];

        return Uri.UnescapeDataString(value).Trim();
    }

    private string? GetConnectionString()
    {
        var connectionString = configuration.GetConnectionString("ControlManagement");
        if (!string.IsNullOrWhiteSpace(connectionString)) return connectionString;

        var gracConnection = configuration.GetConnectionString("DbConnection");
        var encryptedPassword = configuration.GetConnectionString("Password");
        if (string.IsNullOrWhiteSpace(gracConnection) || string.IsNullOrWhiteSpace(encryptedPassword)) return null;

        var passwordParts = encryptedPassword.Split('~', 2);
        if (passwordParts.Length != 2) throw new InvalidOperationException("ConnectionStrings:Password must contain the GRAC encryption key and encrypted password.");
        return gracConnection + DecryptPassword(passwordParts[1], passwordParts[0]);
    }

    private string ConfigureConnectionString(string connectionString)
    {
        var builder = new SqlConnectionStringBuilder(connectionString)
        {
            Encrypt = configuration.GetValue("Database:Encrypt", true),
            TrustServerCertificate = configuration.GetValue("Database:TrustServerCertificate", false)
        };
        return builder.ConnectionString;
    }

    private static string DecryptPassword(string encryptedPassword, string key)
    {
        using var aes = Aes.Create();
        aes.Key = Encoding.UTF8.GetBytes(key.Substring(4, 32));
        aes.IV = Encoding.UTF8.GetBytes(key.ToLowerInvariant().Substring(4, 16));
        aes.Mode = CipherMode.CBC;
        aes.Padding = PaddingMode.PKCS7;
        using var decryptor = aes.CreateDecryptor(aes.Key, aes.IV);
        using var memoryStream = new MemoryStream(Convert.FromBase64String(encryptedPassword));
        using var cryptoStream = new CryptoStream(memoryStream, decryptor, CryptoStreamMode.Read);
        using var streamReader = new StreamReader(cryptoStream);
        return streamReader.ReadToEnd();
    }

    private sealed record MenuRow(long Id, long? ParentMenuId, string MenuKey, string MenuName, string? MenuUrl, string? IconClass, int DisplayOrder);

    private sealed class ApiMenuRow
    {
        public long Id { get; set; }
        public long? ParentMenuId { get; set; }
        public string? MenuKey { get; set; }
        public string? MenuCode { get; set; }
        public string? MenuName { get; set; }
        public string? MenuUrl { get; set; }
        public string? RouteUrl { get; set; }
        public string? IconClass { get; set; }
        public string? Icon { get; set; }
        public int DisplayOrder { get; set; }

        public MenuRow ToMenuRow() => new(
            Id,
            ParentMenuId,
            MenuKey ?? MenuCode ?? "",
            MenuName ?? MenuKey ?? MenuCode ?? "",
            MenuUrl ?? RouteUrl,
            IconClass ?? Icon,
            DisplayOrder);
    }
}
