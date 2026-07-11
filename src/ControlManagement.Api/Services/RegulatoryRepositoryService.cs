using System.Data;
using System.Data.Common;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ControlManagement.Api.Models;

namespace ControlManagement.Api.Services;

public interface IRegulatoryRepositoryService
{
    Task<RepositoryResult> QueryAsync(RepositoryQuery request, CancellationToken cancellationToken);
    Task<RepositoryResult> ManageAsync(RepositoryCommand request, CancellationToken cancellationToken);
}

public sealed class RegulatoryRepositoryService(IConfiguration configuration, ILogger<RegulatoryRepositoryService> logger, IHostEnvironment environment) : IRegulatoryRepositoryService
{
    public async Task<RepositoryResult> QueryAsync(RepositoryQuery request, CancellationToken cancellationToken)
    {
        var result = await ExecuteAsync("dbo.cm_get_repository", request.EntityType, "QUERY", request.Id, request.Search, request.Status,
            JsonSerializer.Serialize(new { request.AuthorityId, request.ArtifactId, request.ReleaseId, request.ControlId, request.RequirementId, request.FrameworkStatementId, request.DomainId, request.Module, request.ActionType }), "",
            request.Page, request.PageSize, cancellationToken);
        if (!request.EntityType.Equals("source-structure", StringComparison.OrdinalIgnoreCase)
            || result.Data is not List<List<Dictionary<string, object?>>> tables
            || tables.Count == 0)
            return result;

        tables.Add(BuildSourceStructureTree(tables[0]));
        return result;
    }

    public Task<RepositoryResult> ManageAsync(RepositoryCommand request, CancellationToken cancellationToken) =>
        ExecuteAsync("dbo.cm_manage_repository", request.EntityType, request.Action, request.Id, "", "",
            request.Data.GetRawText(), request.EnteredBy, null, null, cancellationToken);

    private async Task<RepositoryResult> ExecuteAsync(string procedure, string entityType, string action, int? id,
        string search, string status, string payload, string enteredBy, int? page, int? pageSize, CancellationToken cancellationToken)
    {
        try
        {
            var provider = configuration["Database:Provider"] ?? "Microsoft.Data.SqlClient";
            var connectionString = GetConnectionString();
            if (string.IsNullOrWhiteSpace(connectionString))
                return new(false, "Configure ConnectionStrings:ControlManagement or the GRAC DbConnection and Password settings before using repository endpoints.");

            var factory = provider.Equals("Microsoft.Data.SqlClient", StringComparison.OrdinalIgnoreCase)
                ? Microsoft.Data.SqlClient.SqlClientFactory.Instance
                : DbProviderFactories.GetFactory(provider);
            await using var connection = factory.CreateConnection() ?? throw new InvalidOperationException("Unable to create database connection.");
            connection.ConnectionString = ConfigureConnectionString(provider, connectionString);
            await connection.OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandText = procedure;
            command.CommandType = CommandType.StoredProcedure;
            Add(command, "@p_entity_type", entityType);
            Add(command, "@p_action", action);
            Add(command, "@p_id", id ?? 0);
            Add(command, "@p_search", search);
            Add(command, "@p_status", status);
            Add(command, "@p_payload", payload);
            Add(command, "@p_usr_id", enteredBy);
            if (procedure.EndsWith("cm_get_repository", StringComparison.OrdinalIgnoreCase))
            {
                Add(command, "@p_page", page.GetValueOrDefault(1));
                Add(command, "@p_page_size", pageSize.GetValueOrDefault(0));
            }
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            var tables = new List<List<Dictionary<string, object?>>>();
            do
            {
                var rows = new List<Dictionary<string, object?>>();
                while (await reader.ReadAsync(cancellationToken))
                {
                    var row = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
                    for (var i = 0; i < reader.FieldCount; i++) row[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
                    rows.Add(row);
                }
                tables.Add(rows);
            } while (await reader.NextResultAsync(cancellationToken));
            return new(true, "Success", tables);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 50008 or 50009 or 50010 or 50011 or 50012 or 50013 or 50014 or 50015 or 50016 or 50017 or 50018 or 50020 or 50021 or 50022 or 50023 or 50024 or 50025 or 50026 or 50027 or 50028 or 50029 or 50030 or 50031 or 50032 or 50033 or 50034 or 50035 or 50036 or 50037 or 50038 or 50039 or 50043 or 50044 or 50045 or 50046 or 50047 or 50048 or 2601 or 2627)
        {
            logger.LogWarning(ex, "Rejected invalid repository data for {EntityType} {Action}", entityType, action);
            return new(false, ex.Number switch
            {
                50008 => "Authority Code is required.",
                50009 => "Authority Code already exists.",
                50010 => "Artifact Code is required.",
                50011 => "Artifact Code already exists.",
                50012 => "The selected Industry is invalid.",
                50013 => "The selected Jurisdiction is invalid.",
                50014 => "Parent node must belong to the selected release.",
                50015 => "Only leaf-level source structure nodes can be mapped to a control.",
                50016 => "Control is required.",
                50017 => "Requirement and Release are required for obligation mapping.",
                50018 => "Invalid evidence frequency selected.",
                50020 => "Duplicate Evidence Type is not allowed under the same Requirement + Release obligation.",
                50021 => "Release is required for Framework Statement.",
                50022 => "Source Structure Node is required for Framework Statement.",
                50023 => "Statement Reference is required.",
                50024 => "Source Structure Node must belong to the selected Release.",
                50025 => "Statement Reference already exists for this Release. Enter a unique statement reference.",
                50026 => "Checker comments are mandatory.",
                50027 => "Self approval is not allowed for this module.",
                50028 => "Module Name is required.",
                50029 => "Approval workflow already exists for this module.",
                50030 => "Password Hash is required for new users.",
                50031 => "Login ID or Email already exists.",
                50032 => "Role Name already exists.",
                50033 => "Menu Code already exists.",
                50034 => "Role permission already exists for this menu.",
                50035 => "Approve the parent change request before approving or saving this child record.",
                50036 => "The parent change request was rejected. This child change request cannot be approved.",
                50037 => "Role is required.",
                50038 => "Menu is required.",
                50039 => "Select a valid Module from the master list.",
                50043 => "User Name is required.",
                50044 => "Login ID is required.",
                50045 => "Email is required.",
                50046 => "Role Name is required.",
                50047 => "Menu Name is required.",
                50048 => "Menu Code is required.",
                _ => "A record with the same unique value already exists."
            });
        }
        catch (Exception ex)
        {
            var correlationId = Guid.NewGuid().ToString("N");
            logger.LogError(ex, "Repository database operation failed {CorrelationId} for {EntityType} {Action}", correlationId, entityType, action);
            var detail = environment.IsDevelopment() ? $" Detail: {ex.Message}" : "";
            return new(false, $"The repository operation could not be completed. Reference: {correlationId}{detail}");
        }
    }

    private string ConfigureConnectionString(string provider, string connectionString)
    {
        if (!provider.Equals("Microsoft.Data.SqlClient", StringComparison.OrdinalIgnoreCase)) return connectionString;

        var builder = new Microsoft.Data.SqlClient.SqlConnectionStringBuilder(connectionString)
        {
            Encrypt = configuration.GetValue("Database:Encrypt", true),
            TrustServerCertificate = configuration.GetValue("Database:TrustServerCertificate", false)
        };
        return builder.ConnectionString;
    }

    private static List<Dictionary<string, object?>> BuildSourceStructureTree(List<Dictionary<string, object?>> rows)
    {
        var nodes = rows.Select(row => new Dictionary<string, object?>(row, StringComparer.OrdinalIgnoreCase)
        {
            ["Children"] = new List<Dictionary<string, object?>>()
        }).ToDictionary(row => Convert.ToInt64(row["Id"] ?? 0), row => row);
        var roots = new List<Dictionary<string, object?>>();

        foreach (var node in nodes.Values.OrderBy(row => Convert.ToInt32(row["DisplayOrder"] ?? 0)).ThenBy(row => row["Reference"]?.ToString()))
        {
            var parentValue = node.TryGetValue("ParentNodeId", out var parent) ? parent : null;
            if (parentValue is not null && parentValue != DBNull.Value && long.TryParse(parentValue.ToString(), out var parentId)
                && nodes.TryGetValue(parentId, out var parentNode)
                && parentId != Convert.ToInt64(node["Id"] ?? 0))
            {
                ((List<Dictionary<string, object?>>)parentNode["Children"]!).Add(node);
            }
            else
            {
                roots.Add(node);
            }
        }

        return [new Dictionary<string, object?> { ["Tree"] = roots }];
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
        using var reader = new StreamReader(cryptoStream);
        return reader.ReadToEnd();
    }

    private static void Add(DbCommand command, string name, object value)
    {
        var parameter = command.CreateParameter();
        parameter.ParameterName = name;
        parameter.Value = value;
        command.Parameters.Add(parameter);
    }
}
