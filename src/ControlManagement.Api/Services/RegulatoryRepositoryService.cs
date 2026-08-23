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
    // Assurance Management (Phase 1) entities are served by dedicated procedures
    // so the existing Regulatory Repository procedure stays untouched.  The
    // 'assurance-lookups' entry point is the assurance equivalent of the shared
    // 'lookups' catalogue.
    private static readonly HashSet<string> AssuranceEntities = new(StringComparer.OrdinalIgnoreCase)
    {
        "assurance-categories",
        "assurance-scoring-models",
        "assurance-severity",
        "assurance-gap-categories",
        "assurance-workflow-templates",
        "assurance-question-types",
        "assurance-sampling-models",
        "assurance-frequency-types",
        "assurance-report-templates",
        "assurance-starter-templates",
        "assurance-version-history",
        "assurance-lookups"
    };

    // Obligation Taxonomy (Phase 2B) typed detail entities routed to the
    // dedicated dispatchers cm_get_obligation_taxonomy /
    // cm_manage_obligation_taxonomy.  The legacy Obligation MASTER entity
    // types ('obligations', 'obligation-mappings', 'obligation-evidence',
    // 'obligations-similar', 'obligation-mapping-matrix',
    // 'obligation-mapping-bulk') continue to flow through the standard
    // cm_get_repository / cm_manage_repository so nothing existing breaks.
    private static readonly HashSet<string> ObligationTaxonomyEntities = new(StringComparer.OrdinalIgnoreCase)
    {
        "obligation-types",
        "obligation-type-assignment",
        "obligation-state",
        "obligation-execution",
        "obligation-assurance",
        "obligation-event-response",
        "obligation-constraint",
        "obligation-retention",
        "obligation-evidence-links",
        // Event-driven assurance (033): the event taxonomy tree that drives the
        // Trigger Mode -> Domain -> Event cascade.  Read-only reference data,
        // routed here because it is consumed by the obligation typed-detail form.
        "event-types"
    };

    // Obligation Composite (Phase 2) -- the merged "Obligation Master +
    // Type + Typed Detail + Evidence Links" save.  Routed to its own
    // dispatcher cm_manage_obligation_composite, which emits ONE
    // change_management row per sub-entity tied together by a bundle_id
    // and approved atomically (see migrations 031 / 032).
    //
    // SAVE-only: there is no composite read.  The merged page loads via
    // the existing per-entity GET calls ('obligations',
    // 'obligation-<type>', 'obligation-evidence-links'), so QueryAsync
    // deliberately does NOT consult this set.
    //
    // The legacy 'obligations' entity type is untouched and still flows
    // through cm_manage_repository with its original payload contract.
    private static readonly HashSet<string> ObligationCompositeEntities = new(StringComparer.OrdinalIgnoreCase)
    {
        "obligation-composite"
    };

    // Event-driven Assurance runtime (035/036).  Occurrences of an event and
    // the checklists they generate, routed to cm_get_assurance_runtime /
    // cm_manage_assurance_runtime.
    //
    // These are DIRECT WRITE by design -- registered in cm_entity_master with
    // is_maker_checker = 0.  Routing checklist completion through
    // change_management would raise one approval per assurance per subject,
    // which would swamp the checker queue.  The rules stay governed; recording
    // that a rule was carried out does not.
    private static readonly HashSet<string> AssuranceRuntimeEntities = new(StringComparer.OrdinalIgnoreCase)
    {
        "assurance-occurrences",
        "assurance-checklist",
        "event-subjects"
    };

    // SLA Master (043) - process / classification SLA definitions.  Routed to
    // its own dispatcher (cm_get_sla_master / cm_manage_sla_master) so the
    // existing cm_get_repository / cm_manage_repository stay untouched.
    // Simple config master - no version / draft / publish lifecycle, just
    // Active <-> Inactive.
    private static readonly HashSet<string> SlaMasterEntities = new(StringComparer.OrdinalIgnoreCase)
    {
        "sla-master"
    };

    // Obligation Source Statement mapping (056) -- which Framework Statements
    // an obligation is written against.  Routed to its own read procedure
    // dbo.cm_get_obligation_statement_map so the 1100-line cm_get_repository
    // does not have to be re-emitted for this feature, mirroring the split
    // already used by the SLA Master and obligation taxonomy reads.
    //
    // READ-ONLY.  There is no manage counterpart: the write travels inside the
    // obligation master payload as $.sourceStatements and is applied by
    // cm_manage_repository's 'obligations' branch, which is what keeps the
    // mapping inside the master's maker-checker bundle.  ManageAsync therefore
    // does not consult this set.
    private static readonly HashSet<string> ObligationStatementMapEntities = new(StringComparer.OrdinalIgnoreCase)
    {
        "obligation-statement-mappings",
        "obligation-statement-releases"
    };

    public async Task<RepositoryResult> QueryAsync(RepositoryQuery request, CancellationToken cancellationToken)
    {
        var procedure = IsAssuranceRuntime(request.EntityType)
            ? "dbo.cm_get_assurance_runtime"
            : IsObligationTaxonomy(request.EntityType)
                ? "dbo.cm_get_obligation_taxonomy"
                : IsObligationStatementMap(request.EntityType)
                    ? "dbo.cm_get_obligation_statement_map"
                    : IsAssurance(request.EntityType)
                        ? "dbo.cm_get_assurance_repository"
                        : IsSlaMaster(request.EntityType)
                            ? "dbo.cm_get_sla_master"
                            : "dbo.cm_get_repository";
        var payload = JsonSerializer.Serialize(new
        {
            request.AuthorityId,
            request.ArtifactId,
            request.ReleaseId,
            request.ControlId,
            request.RequirementId,
            request.FrameworkStatementId,
            request.DomainId,
            request.Module,
            request.ActionType,
            LifecycleStatus = request.Status,
            CategoryId = request.DomainId,
            WorkflowTemplateId = request.ControlId
        });
        var result = await ExecuteAsync(procedure, request.EntityType, "QUERY", request.Id, request.Search, request.Status,
            payload, "", request.Page, request.PageSize, cancellationToken);
        if (!request.EntityType.Equals("source-structure", StringComparison.OrdinalIgnoreCase)
            || result.Data is not List<List<Dictionary<string, object?>>> tables
            || tables.Count == 0)
            return result;

        tables.Add(BuildSourceStructureTree(tables[0]));
        return result;
    }

    public Task<RepositoryResult> ManageAsync(RepositoryCommand request, CancellationToken cancellationToken)
    {
        var procedure = IsAssuranceRuntime(request.EntityType)
            ? "dbo.cm_manage_assurance_runtime"
            : IsObligationComposite(request.EntityType)
                ? "dbo.cm_manage_obligation_composite"
                : IsObligationTaxonomy(request.EntityType)
                    ? "dbo.cm_manage_obligation_taxonomy"
                    : IsAssurance(request.EntityType)
                        ? "dbo.cm_manage_assurance_repository"
                        : IsSlaMaster(request.EntityType)
                            ? "dbo.cm_manage_sla_master"
                            : "dbo.cm_manage_repository";
        return ExecuteAsync(procedure, request.EntityType, request.Action, request.Id, "", "",
            request.Data.GetRawText(), request.EnteredBy, null, null, cancellationToken);
    }

    private static bool IsAssurance(string entityType) =>
        AssuranceEntities.Contains(entityType);

    private static bool IsObligationTaxonomy(string entityType) =>
        ObligationTaxonomyEntities.Contains(entityType);

    private static bool IsObligationComposite(string entityType) =>
        ObligationCompositeEntities.Contains(entityType);

    private static bool IsAssuranceRuntime(string entityType) =>
        AssuranceRuntimeEntities.Contains(entityType);

    private static bool IsSlaMaster(string entityType) =>
        SlaMasterEntities.Contains(entityType);

    private static bool IsObligationStatementMap(string entityType) =>
        ObligationStatementMapEntities.Contains(entityType);

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
            if (procedure.EndsWith("cm_get_repository", StringComparison.OrdinalIgnoreCase)
                || procedure.EndsWith("cm_get_obligation_taxonomy", StringComparison.OrdinalIgnoreCase))
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
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 50008 or 50009 or 50010 or 50011 or 50012 or 50013 or 50014 or 50015 or 50016 or 50017 or 50018 or 50020 or 50021 or 50022 or 50023 or 50024 or 50025 or 50026 or 50027 or 50028 or 50029 or 50030 or 50031 or 50032 or 50033 or 50034 or 50035 or 50036 or 50037 or 50038 or 50039 or 50043 or 50044 or 50045 or 50046 or 50047 or 50048 or 50070 or 50071 or 50072 or 50073 or 50074 or 50075 or 50076 or 50077 or 50078 or 50079 or 50080 or 50081 or 50082 or 50083 or 50084 or 50085 or 50086 or 50087 or 50088 or 50089 or 50090 or 50091 or 50092 or 50093 or 50094 or 50095 or 50096 or 50097 or 50098 or 50099 or 50100 or 50101 or 50102 or 50103 or 50104 or 50105 or 50106 or 50107 or 50108 or 50109 or 50110 or 50130 or 2601 or 2627)
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
                50070 => "The assurance entity type is not recognized.",
                50071 => "Only Draft records can be submitted for review.",
                50072 => "Only records in Review can be Approved.",
                50073 => "Only records in Review can be Rejected.",
                50074 => "Only Approved or Published records can be Published.",
                50075 => "Only Published records can be Retired.",
                50076 => "This assurance entity does not support that lifecycle action.",
                50077 => "This assurance entity does not support Retire.",
                50078 => "Approved, Published or Retired records cannot be edited directly. Create a new version instead.",
                50079 => "This assurance entity does not support save.",
                50080 => "Category Code is required.",
                50081 => "Category Name is required.",
                50082 => "Category Code already exists.",
                50083 => "Scoring Model Code is required.",
                50084 => "Scoring Model Name is required.",
                50085 => "Formula definition must be configuration data, not executable SQL.",
                50086 => "Scoring Model Code already exists.",
                50087 => "Severity Code is required.",
                50088 => "Severity Name is required.",
                50089 => "Severity Code already exists.",
                50090 => "Gap Code is required.",
                50091 => "Gap Name is required.",
                50092 => "Gap Code already exists.",
                50093 => "Workflow Template Code is required.",
                50094 => "Workflow Template Name is required.",
                50095 => "Workflow Template Code already exists.",
                50096 => "Question Type Code is required.",
                50097 => "Question Type Name is required.",
                50098 => "Question Type Code already exists.",
                50099 => "Sampling Model Code is required.",
                50100 => "Sampling Model Name is required.",
                50101 => "Sampling Model Code already exists.",
                50102 => "Frequency Code is required.",
                50103 => "Frequency Name is required.",
                50104 => "Frequency Code already exists.",
                50105 => "Report Template Code is required.",
                50106 => "Report Template Name is required.",
                50107 => "Report Template Code already exists.",
                50108 => "Starter Template Code is required.",
                50109 => "Starter Template Name is required.",
                50110 => "Starter Template Code already exists.",
                // 056.  Reachable when a statement is retired between the
                // Obligation Master form loading its tree and the maker saving.
                50130 => "One or more selected Source Statements no longer exist. Reload the form and select them again.",
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
