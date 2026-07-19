using System.Text.Json;
using ControlManagement.Security;

namespace ControlManagement.Api.Validation;

public sealed class RepositoryCommandValidator
{
    private static readonly HashSet<string> Statuses = new(StringComparer.OrdinalIgnoreCase)
        { "Active", "Inactive", "Draft", "Published", "Retired", "Open", "Closed", "Pending", "Sent", "Read" };

    private static readonly Dictionary<string, string[]> Required = new(StringComparer.OrdinalIgnoreCase)
    {
        ["authorities"] = ["code", "name"],
        ["artifacts"] = ["authorityId", "code", "name", "category"],
        ["releases"] = ["artifactId", "version"],
        ["statement-classifications"] = ["releaseId", "name"],
        ["source-structure"] = ["releaseId", "nodeType", "reference", "title"],
        ["framework-statements"] = ["releaseId", "structureNodeId", "statementReference", "statementText"],
        ["controls"] = ["code", "name"],
        ["control-domains"] = ["name"],
        ["control-sub-domains"] = ["domainId", "name"],
        ["requirements"] = ["code", "name", "statement"],
        ["obligations"] = ["obligationName"],
        ["obligation-mappings"] = ["obligationId", "requirementId", "releaseId"],
        ["obligation-mapping-bulk"] = ["requirementId"],
        ["control-requirement-mappings"] = ["controlId"],
        // 'source-control-mappings' now stores mappings against Framework Statements
        // (framework_statement_control_map).  The legacy 'structureNodeId' payload
        // path is still accepted by the SP for backward compatibility (used by the
        // in-form Source Structure section on Add/Edit Control), so this required
        // list only asserts the presence of the target controls.  Presence of
        // frameworkStatementId OR structureNodeId is enforced at the SP layer.
        ["source-control-mappings"] = ["controlIds"],
        ["applicability-rules"] = ["name", "expression", "priority", "outcome"],
        ["user-management"] = ["userName", "loginId", "email"],
        ["role-management"] = ["roleName"],
        ["menu-management"] = ["menuName", "menuCode", "displayOrder"],
        ["role-permissions"] = ["roleId", "menuId"],
        ["changes"] = ["entityType", "entityId", "changeType", "summary", "severity", "status"],
        ["impact-analysis"] = ["changeEventId", "impactedEntityType", "impactedEntityId", "status"],
        ["notifications"] = ["type", "subject", "message", "severity", "status"],
        ["approval-workflow"] = ["moduleName", "approvalRequired", "selfApprovalAllowed", "minimumApprovers"]
    };

    public string? Validate(SecureRepositoryRequest request)
    {
        if (request.EntityType.Equals("audit-trace", StringComparison.OrdinalIgnoreCase)
            || request.EntityType.Equals("lookups", StringComparison.OrdinalIgnoreCase))
            return "This repository area is read-only.";
        if (request.Action.Equals("APPROVE", StringComparison.OrdinalIgnoreCase))
        {
            if (request.Id.GetValueOrDefault() <= 0) return "A valid record identifier is required.";
            if (request.Data.TryGetProperty("comments", out var comments) && comments.GetString()?.Length > 1000)
                return "Approval comments cannot exceed 1000 characters.";
            return null;
        }
        if (request.Action.Equals("REJECT", StringComparison.OrdinalIgnoreCase)
            || request.Action.Equals("SEND_BACK", StringComparison.OrdinalIgnoreCase))
        {
            if (request.Id.GetValueOrDefault() <= 0) return "A valid record identifier is required.";
            if (!request.Data.TryGetProperty("comments", out var comments) || string.IsNullOrWhiteSpace(comments.GetString()))
                return "Checker comments are mandatory.";
            if (comments.GetString()?.Length > 1000) return "Checker comments cannot exceed 1000 characters.";
            return null;
        }
        if (request.Action.Equals("RETIRE", StringComparison.OrdinalIgnoreCase))
            return request.Id.GetValueOrDefault() > 0 ? null : "A valid record identifier is required.";
        if (!request.Action.Equals("SAVE", StringComparison.OrdinalIgnoreCase)) return "Unsupported repository action.";
        if (request.Data.ValueKind != JsonValueKind.Object) return "A valid request payload is required.";
        if (request.Data.GetRawText().Length > 100_000) return "The request payload is too large.";

        // 'obligations' is now a standalone master form.  No Requirement / Release
        // is required at save-time; the maker maps Obligation -> Requirement +
        // Release later through the 'obligation-mappings' entity.

        foreach (var name in Required.GetValueOrDefault(request.EntityType, []))
            if (!request.Data.TryGetProperty(name, out var value) || IsEmpty(value))
                return $"{name} is required.";

        if (request.EntityType.Equals("authorities", StringComparison.OrdinalIgnoreCase)
            && request.Data.TryGetProperty("code", out var authorityCode)
            && authorityCode.GetString()?.Trim().Length > 80)
            return "Authority Code cannot exceed 80 characters.";
        if (request.EntityType.Equals("artifacts", StringComparison.OrdinalIgnoreCase)
            && request.Data.TryGetProperty("code", out var artifactCode)
            && artifactCode.GetString()?.Trim().Length > 100)
            return "Artifact Code cannot exceed 100 characters.";

        if (request.Data.TryGetProperty("status", out var status)
            && status.ValueKind == JsonValueKind.String
            && !Statuses.Contains(status.GetString() ?? ""))
            return "The selected status is invalid.";
        return null;
    }

    private static bool IsEmpty(JsonElement value) =>
        value.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined
        || value.ValueKind == JsonValueKind.String && string.IsNullOrWhiteSpace(value.GetString())
        || value.ValueKind == JsonValueKind.Array && value.GetArrayLength() == 0
        || value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number) && number <= 0;
}
