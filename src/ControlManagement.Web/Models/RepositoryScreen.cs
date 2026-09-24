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
       // Statement Text is long-form prose — it is on the View / Edit dialog and
       // in the row tooltip, not as a grid column.
       new("framework-statements","Source Statements","Actual regulatory statements captured under source structure nodes","file-lines",["Source Structure / Statement Reference","Statement Title","Classification","Status"]),
        // Description (requirement_statement) is long-form prose — it is on the
        // View / Edit dialog, not as a grid column.  Code is system-generated.
        new("requirements","Practices","Atomic assessable compliance practices","list-check",["Code","Name","Status"]),
        // Execution Frequency, Assurance Frequency and Retention Period were
        // dropped from this grid.  None of the three is a property of the
        // obligation any more: execution cadence lives on the Execution typed
        // panel, assurance cadence on the Assurance panel, and retention is
        // stated per evidence specification.  A column can only show one of
        // those, so on any obligation of another type it was simply blank --
        // four columns of mostly-empty grid between the name and the counts
        // that actually distinguish one record from another.
        //
        // The Practices - Obligation Mapping screen below still carries them;
        // it is a different screen and was left alone deliberately.
        new("obligations","Obligation Master","Reusable obligations with their evidence specifications and practice mappings","calendar-check",["ObligationName","EvidenceCount","MappingCount","Status"]),
        new("obligation-mappings","Practices - Obligation Mapping","Mapped obligations grouped by Obligation; expand a row to see its Practice/Release mappings","list-tree",["ObligationName","ExecutionFrequency","AssuranceFrequency","RetentionPeriod","EvidenceCount","MappingCount","Status"]),
        // Event-driven assurance runtime (035/036).  One row per event that
        // occurred, with completion progress across its generated checklist.
        new("assurance-occurrences","Event Checklists","Assurance checklists raised each time a tracked event occurs","clipboard-check",["EventName","SubjectLabel","OccurredOn","NextDueOn","CompletedItems","PendingItems","OverdueItems","Status"]),
        new("source-control-mappings","Practices - Statement Mapping","Map Practices to Framework Statements grouped under their Source Structure hierarchy","sitemap",["SourceReference","StatementReference","StatementTitle","PracticeName","Status"]),
        new("user-management","User Management","Manage Repository Management users and role assignments","users",["UserName","LoginId","Email","Roles","Status"]),
        new("role-management","Role Management","Manage Repository Management roles","user-tag",["RoleName","Description","Status"]),
        new("menu-management","Menu Management","Manage database-driven Repository Management navigation","bars",["MenuName","MenuCode","ParentMenu","RouteUrl","DisplayOrder","Status"]),
        new("role-permissions","Role Permission Management","Configure menu permission matrix by role","key",["RoleName","MenuName","CanView","CanAdd","CanEdit","CanInactive","CanApprove","Status"]),
        new("change-management","Change Management","Review pending and historical maker-checker change requests","code-branch",["ChangeRequestNumber","Module","RecordReference","ActionType","Maker","SubmittedOn","Checker","CheckedOn","Status"]),
        new("approval-workflow","Approval Workflow Configuration","Configure maker-checker approval rules by module","user-check",["ModuleLabel","ApprovalRequired","SelfApprovalAllowed","MinimumApprovers","Status"]),
        new("audit-trace","Audit Traceability","Who changed what, from which value to which value, and when","clock-rotate-left",["EntityType","RecordReference","ActionType","ChangedBy","ChangedOn","Status"]),
        // -----------------------------------------------------------
        // Assurance Management (Phase 1 - Admin / Authority Control Module)
        // -----------------------------------------------------------
        new("assurance-categories","Assurance Categories","Reusable assurance category master","list-check",["Code","Name","Description","Version","LifecycleStatus","Status"]),
        new("assurance-scoring-models","Scoring Models","Reusable scoring methodologies","chart-simple",["Code","Name","FormulaType","RatingScale","PassThreshold","Version","LifecycleStatus","Status"]),
        new("assurance-severity","Observation Severity","Default observation severity classifications","triangle-exclamation",["Code","Name","SeverityRank","Version","LifecycleStatus","Status"]),
        new("assurance-gap-categories","Gap Categories","Standard gap classification master","circle-exclamation",["Code","Name","Description","Version","LifecycleStatus","Status"]),
        new("assurance-workflow-templates","Workflow Templates","Reusable workflow models with stages, SLA and escalation","diagram-project",["Code","Name","StageCount","SlaHours","Version","LifecycleStatus","Status"]),
        new("sla-master","SLA Master","Service level agreements by process and severity classification","stopwatch",["SlaCode","Process","Classification","Duration","TimeBasis","WarningPct","EscalationPct","Status"]),
        new("assurance-question-types","Question Types","Supported question types for assurance questionnaires","circle-question",["Code","Name","AnswerShape","RequiresEvidence","Version","LifecycleStatus","Status"]),
        new("assurance-sampling-models","Sampling Models","Reusable sampling methodologies","shuffle",["Code","Name","Description","Version","LifecycleStatus","Status"]),
        new("assurance-frequency-types","Frequency Types","Reusable execution frequencies","calendar-days",["Code","Name","IntervalDays","Version","LifecycleStatus","Status"]),
        new("assurance-report-templates","Report Templates","Reusable report templates","file-lines",["Code","Name","ReportScope","Version","LifecycleStatus","Status"]),
        new("assurance-starter-templates","Starter Assurance Templates","Ready-to-subscribe starter templates that bundle assurance metadata","copy",["Code","Name","Category","ScoringModel","WorkflowTemplate","Version","LifecycleStatus","Status"]),
        new("assurance-version-history","Version History","Immutable lifecycle audit trail of every assurance metadata item","clock-rotate-left",["EntityType","EntityId","Version","LifecycleStatus","ActionCode","EnteredBy","EnteredDt"]),
        // Time Zone Master (058/059) -- standardized IANA time zones shared
        // across every GRAC module. Global reference data, not owned by any
        // one organisation, which is why it lives here (Security
        // Administration) rather than in PracticeManagement: that module
        // only references GRAC_New.time_zone_master to feed a Location's
        // Time Zone dropdown, it does not manage the master itself.
        new("time-zone-master","Time Zone Master","Standardized IANA time zones referenced by Location and other GRAC modules","clock",["TimeZoneName","IanaTimeZone","UtcOffset","Status"])
    ];
}
