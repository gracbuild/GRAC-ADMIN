namespace ControlManagement.Web.Models;

public sealed record RepositoryScreen(string Key, string Title, string Description, string Icon, string[] Columns)
{
    public static readonly RepositoryScreen[] All =
    [
        new("authorities","Authority","Issuing and supervisory bodies","building",["Code","Name","Jurisdiction","Status"]),
       new("artifacts","Artifacts","Regulations, standards, laws, directives and programs","file-text",["Code","Name","Authority","Category","Status"]),
       new("releases","Releases","Versioned publications and effective dates","tags",["Artifact","Version","EffectiveDate","EndDate","Status"]),
       new("statement-classifications","Source Classification","Release-specific statement categories and levels","layer-group",["Release","ClassificationScheme","ClassificationName","Description"]),
       new("source-structure","Source Structure","Native hierarchy only; framework statements carry the regulatory text","diagram-project",["NodeReference","NodeTitle","Description","Status"]),
       new("framework-statements","Source Statements","Actual regulatory statements captured under source structure nodes","file-lines",["Source Structure / Statement Reference","Statement Title","Statement Text","Classification","Status"]),
        new("requirements","Practices","Atomic assessable compliance practices","list-check",["Code","Name","Statement","Status"]),
        new("obligations","Obligation Master","Reusable obligations with execution frequency, retention and evidence","calendar-check",["ObligationName","ExecutionFrequency","AssuranceFrequency","RetentionPeriod","EvidenceCount","MappingCount","Status"]),
        new("obligation-mappings","Practices - Obligation Mapping","Mapped obligations grouped by Obligation; expand a row to see its Practice/Release mappings","list-tree",["ObligationName","ExecutionFrequency","AssuranceFrequency","RetentionPeriod","EvidenceCount","MappingCount","Status"]),
        new("source-control-mappings","Practices - Statement Mapping","Map practices to source statements","sitemap",["SourceReference","Control","Status"]),
        new("user-management","User Management","Manage Repository Management users and role assignments","users",["UserName","LoginId","Email","Roles","Status"]),
        new("role-management","Role Management","Manage Repository Management roles","user-tag",["RoleName","Description","Status"]),
        new("menu-management","Menu Management","Manage database-driven Repository Management navigation","bars",["MenuName","MenuCode","ParentMenu","RouteUrl","DisplayOrder","Status"]),
        new("role-permissions","Role Permission Management","Configure menu permission matrix by role","key",["RoleName","MenuName","CanView","CanAdd","CanEdit","CanInactive","CanApprove","Status"]),
        new("change-management","Change Management","Review pending and historical maker-checker change requests","code-branch",["ChangeRequestNumber","Module","RecordReference","ActionType","Maker","SubmittedOn","Checker","CheckedOn","Status"]),
        new("approval-workflow","Approval Workflow Configuration","Configure maker-checker approval rules by module","user-check",["ModuleLabel","ApprovalRequired","SelfApprovalAllowed","MinimumApprovers","Status"]),
        new("audit-trace","Audit Traceability","Who changed what, from which value to which value, and when","clock-rotate-left",["EntityType","RecordReference","ActionType","ChangedBy","ChangedOn","Status"])
    ];
}
