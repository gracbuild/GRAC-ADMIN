(() => {
  "use strict";
  const rows = document.querySelector("#repositoryRows");
  const panel = document.querySelector(".panel");
  const dialog = document.querySelector("#recordDialog");
  const form = document.querySelector("#recordForm");
  const fieldsHost = document.querySelector("#recordFields");
  const saveButton = document.querySelector("#saveRecord");
  const closeButton = document.querySelector("#closeRecord");
  const cancelButton = document.querySelector("#cancelRecord");
  const editButton = document.querySelector("#editRecord");
  const modeChip = document.querySelector("#dialogModeChip");
  const message = document.querySelector("#formMessage");
  const pageTitle = document.querySelector("#pageTitle");
  const authoritySelect = document.querySelector("#authority");
  const artifactSelect = document.querySelector("#artifact");
  const releaseSelect = document.querySelector("#release");
  const changeModuleSelect = document.querySelector("#changeModule");
  const changeActionTypeSelect = document.querySelector("#changeActionType");
  const addRecordButton = document.querySelector("#addRecord");
  const backButton = document.querySelector("#backToParent");
  const gridPagerHost = document.querySelector("#gridPager");
  const query = new URLSearchParams(window.location.search);
  // Screens whose stored procedures already accept page/pageSize and return a
  // TotalCount row.  Everything else is paged client-side over the records the
  // API returned — same control, same look, same behaviour.
  const paginatedAreas = new Set(["user-management","role-management","menu-management","role-permissions"]);
  // source-structure is paged by top-level node via pageTreeRoots() so a tree
  // is never split across two pages; its descendants always travel with their
  // root.  framework-statements is hierarchical too, but its records are the
  // statements rather than the nodes, so it pages by statement and carries the
  // hosting nodes along as headers -- see renderFrameworkStatementRows().
  const GRID_PAGE_SIZE = 10;
  const state = { id: 0, mode: "add", lookups: {}, records: [], gridPage: 1, gridPageSize: GRID_PAGE_SIZE, gridTotal: 0, changeModules: [], loadVersion: 0, collapsed: new Set(), formContext: {}, navigationCode: query.get("code") || "", navigationContext: null, similarControls: [], similarFilters: {}, similarSort: { key: "MatchCount", direction: "desc" }, frameworkStatementNodes: [], frameworkStatementReleases: [] };
  // "Practices - Statement Mapping" screen state.  The subject of the mapping is
  // a Practice (requirements table) — the property is named practiceId here to
  // match the on-screen label.  Mapping is persisted via
  // framework_statement_requirement_map (Statement -> Practice).
  const sourceMapState = { practiceId: "", practice: null, nodes: [], statements: [], mapped: [], collapsed: new Set(), leftSelected: new Set(), rightSelected: new Set() };
  const controlSourceMapState = { nodes: [], releases: [], artifacts: [], selected: new Set(), existing: new Map(), collapsed: new Set(), readonly: false };
  const frameworkStatementTreeState = { nodes: [], selected: "", collapsed: new Set(), readonly: false };
  const obligationState = { requirement: null, contexts: [] };
  // Obligation ids that have already had the "start collapsed" default applied,
  // so a user's expand survives the next render (see renderObligationRows).
  const obligationCollapseSeeded = new Set();
  const requirementMapState = { nodes: [], statements: [], collapsed: new Set(), readonly: false };
  const approvalAreas = new Set(["changes", "impact-analysis", "change-management"]);
  // Read-only screens: their records are never edited from the dialog, so the
  // View dialog must not offer an Edit button.
  const nonEditableAreas = new Set(["change-management", "audit-trace", "assurance-version-history"]);
  // ---------------------------------------------------------------- paging --
  // One pager instance drives every screen.  Server-paged screens reload from
  // the API on change; client-paged screens simply re-render the current rows.
  const gridPager = window.GracPager?.mount(gridPagerHost, {
    pageSize: GRID_PAGE_SIZE,
    onChange: ({ page, pageSize }) => {
      state.gridPage = page;
      state.gridPageSize = pageSize;
      if (paginatedAreas.has(cmScreen.Key)) { load(); return; }
      rows.innerHTML = renderRows();
      updateGridPager();
    }
  });
  function isServerPaged() { return paginatedAreas.has(cmScreen.Key); }
  function gridPageStart() { return (Math.max(1, state.gridPage) - 1) * Math.max(1, state.gridPageSize); }
  /* Rows for the current page of a flat (non-hierarchical) list. Server-paged
     screens already receive exactly one page, so they pass straight through. */
  function pageRows(items) {
    const list = items || [];
    if (isServerPaged()) { return list; }
    state.gridTotal = list.length;
    const size = Math.max(1, state.gridPageSize);
    const lastPage = Math.max(1, Math.ceil(list.length / size));
    if (state.gridPage > lastPage) state.gridPage = lastPage;
    return list.slice(gridPageStart(), gridPageStart() + size);
  }
  /* Page a hierarchy by its root nodes: slice the roots, then carry every
     descendant of the surviving roots along so no tree is ever cut in half. */
  function pageTreeRoots(records) {
    const list = records || [];
    if (!list.length) { state.gridTotal = 0; return list; }
    const ids = new Set(list.map(row => String(row.Id)));
    const roots = list.filter(row => {
      const parent = String(row.ParentNodeId || "");
      return !parent || !ids.has(parent);
    });
    state.gridTotal = roots.length;
    const size = Math.max(1, state.gridPageSize);
    const lastPage = Math.max(1, Math.ceil(roots.length / size));
    if (state.gridPage > lastPage) state.gridPage = lastPage;
    const keep = new Set(roots.slice(gridPageStart(), gridPageStart() + size).map(row => String(row.Id)));
    let grew = true;
    while (grew) {
      grew = false;
      list.forEach(row => {
        const id = String(row.Id), parent = String(row.ParentNodeId || "");
        if (parent && keep.has(parent) && !keep.has(id)) { keep.add(id); grew = true; }
      });
    }
    return list.filter(row => keep.has(String(row.Id)));
  }
  let actionPopover = null, actionTrigger = null;
  const permissions = new Set(window.cmPermissions || []);
  const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || "";
  const authorityFilteredAreas = new Set(["authorities","artifacts","releases","statement-classifications","source-structure","framework-statements","controls","requirements","obligations","control-requirement-mappings","source-control-mappings","applicability-rules"]);
  const statementScopedAreas = new Set(["framework-statements"]);
  const artifactFilterAreas = new Set(["releases","source-structure","statement-classifications","framework-statements","obligations","source-control-mappings","applicability-rules"]);
  const releaseFilterAreas = new Set(["source-structure","statement-classifications","framework-statements","obligations","source-control-mappings","applicability-rules"]);
  const text = (name, label, required = false, extra = {}) => ({ name, label, type: "text", required, ...extra });
  const area = (name, label, required = false, extra = {}) => ({ name, label, type: "textarea", required, full: true, ...extra });
  const select = (name, label, lookup, required = false, extra = {}) => ({ name, label, type: extra.multiple ? "multiselect" : "select", lookup, required, ...extra });
  const number = (name, label, required = false, extra = {}) => ({ name, label, type: "number", required, ...extra });
  const date = (name, label, required = false) => ({ name, label, type: "date", required });
  const check = (name, label) => ({ name, label, type: "checkbox" });
  const tags = (name, label, required = false, extra = {}) => ({ name, label, type: "tags", required, full: true, ...extra });
  const schemas = {
    "authorities": [text("code","Code",true),text("name","Name",true),area("description","Description"),select("jurisdiction","Jurisdiction","jurisdictions"),text("website","Website",false,{ inputType:"url" }),select("status","Status","status-repository",true)],
    "artifacts": [select("authorityId","Authority","authorities",true),text("code","Code",true),text("name","Name",true),area("description","Description"),select("category","Category","artifact-categories",true),select("industries","Industries","industries",false,{ multiple:true, compact:true }),select("jurisdictions","Jurisdictions","jurisdictions",false,{ multiple:true, compact:true }),select("status","Status","status-repository",true)],
    "releases": [select("artifactId","Artifact","artifacts",true),text("version","Version",true),date("effectiveDate","Effective Date"),date("endDate","End Date"),area("releaseNotes","Release Notes"),select("status","Status","release-status",true)],
    "statement-classifications": [select("releaseId","Release","releases",true),text("scheme","Classification Scheme"),text("name","Classification Name",true),area("description","Description")],
    // Release is picked on the form itself so Add Source Node no longer
    // depends on the grid's Release filter.  It is locked (read-only) for
    // Add Child Node and for Edit / View -- see openForm().
    "source-structure": [select("releaseId","Release","releases",true),select("nodeType","Node Type","node-types",true),text("reference","Node Reference",true),text("title","Node Title",true),area("description","Description"),select("status","Status","status-repository",true)],
    "framework-statements": [select("releaseId","Release","releases",true),{ name:"structureNodeId", label:"Source Structure", type:"source-tree", required:true, full:true },select("classificationId","Statement Classification","statement-classifications"),text("statementReference","Statement Reference",true),text("statementTitle","Statement Title"),area("statementText","Statement Text",true),text("remarks","Remarks"),select("status","Status","status-repository",true)],
    "controls": [text("code","Code",true),text("name","Name",true),area("description","Description"),area("objective","Objective"),select("domainId","Domain","control-domains",false,{ addButton:"Add New Domain" }),select("subDomainId","Sub Domain","control-sub-domains",false,{ addButton:"Add New Sub Domain" }),tags("keywords","Keywords",false,{ placeholder:"MFA, privileged access, password, authentication" }),select("status","Status","status-repository",true)],
    // Practice Code is generated by the save procedure (PR-001, PR-002, ...).
    // formSchema() drops it on Add; on Edit / View it is shown read-only.
    "requirements": [text("code","Practice Code",false,{ readonly:true }),text("name","Practice Name",true),area("statement","Description",true),area("objective","Objective"),tags("keywords","Keywords",false,{ placeholder:"access review, KYC, vendor due diligence, evidence review" }),select("status","Status","status-repository",true)],
    "obligations": [text("obligationName","Obligation Name",true),select("executionFrequencyId","Execution Frequency","frequency-master",true),text("retentionRequirement","Retention Period"),area("remarks","Remarks"),tags("keywords","Keywords",false,{ placeholder:"access review, KYC, vendor due diligence, evidence review" }),{ name:"evidenceRequirements", label:"Evidence Details", type:"evidence-grid", full:true },select("status","Status","status-repository",true)],
    "obligation-mappings": [select("obligationId","Obligation","obligations",true,{ full:true }),select("requirementId","Requirement","requirements",true),select("releaseId","Release","releases",true),select("status","Status","status-repository",true)],
    "control-requirement-mappings": [select("controlId","Control","controls",true,{ full:true }),select("requirementIds","Requirements","requirements",false,{ multiple:true, compact:true, full:true, search:true, listbox:true })],
    "source-control-mappings": [select("frameworkStatementId","Framework Statement","framework-statements",true),select("requirementIds","Practices","requirements",true,{ multiple:true, full:true }),select("status","Status","status-repository",true)],
    "user-management": [text("userName","User Name",true),text("loginId","Login ID",true),text("email","Email",true,{ inputType:"email" }),select("roleIds","Roles","cm-roles",false,{ multiple:true, compact:true, full:true, search:true, listbox:true }),area("remarks","Remarks"),select("status","Status","status-admin",true)],
    "role-management": [text("roleName","Role Name",true),area("description","Description"),select("status","Status","status-admin",true)],
    "menu-management": [select("parentMenuId","Parent Menu","cm-menus"),text("menuName","Menu Name",true),text("menuCode","Menu Code",true),text("routeUrl","Route / URL"),number("displayOrder","Display Order",true,{ min:"0" }),text("icon","Icon"),select("status","Status","status-admin",true)],
    "role-permissions": [select("roleId","Role","cm-roles",true),select("menuId","Menu","cm-menus",true),select("canView","View","yes-no",true),select("canAdd","Add","yes-no",true),select("canEdit","Edit","yes-no",true),select("canInactive","Inactive/Delete","yes-no",true),select("canApprove","Approve","yes-no",true),select("status","Status","status-admin",true)],
    "applicability-rules": [select("artifactId","Artifact","artifacts"),select("releaseId","Release","releases"),text("name","Rule Name",true),area("expression","Rule Expression",true,{ placeholder:"Example: industry = Banking AND geography = India" }),number("priority","Priority",true,{ min:"1" }),select("outcome","Outcome","applicability-outcomes",true),select("status","Status","status-repository",true)],
    "changes": [select("entityType","Entity Type","entity-types",true),number("entityId","Entity ID",true,{ min:"1" }),select("changeType","Change Type","change-types",true),area("summary","Change Summary",true),date("effectiveDate","Effective Date"),select("severity","Severity","severity",true),select("status","Status","change-status",true)],
    "impact-analysis": [select("changeEventId","Change Event","changes",true),select("impactedEntityType","Impacted Entity Type","entity-types",true),number("impactedEntityId","Impacted Entity ID",true,{ min:"1" }),select("organizationId","Organization","organizations"),area("summary","Impact Summary"),area("recommendedAction","Recommended Action"),select("status","Status","change-status",true)],
    "notifications": [select("impactAnalysisId","Impact Analysis","impact-analysis"),select("organizationId","Organization","organizations"),select("type","Notification Type","notification-types",true),text("subject","Subject",true),area("message","Message",true),select("severity","Severity","severity",true),area("recommendedAction","Recommended Action"),select("status","Status","notification-status",true)],
    "change-management": [text("ChangeRequestNumber","Change Request Number"),text("Module","Module"),text("RecordReference","Record Reference"),text("ActionType","Action Type"),text("Maker","Maker"),text("SubmittedOn","Submitted On"),text("Checker","Checker"),text("CheckedOn","Checked On"),select("Status","Status","change-approval-status"),area("FieldChangesJson","Field-level Changes"),area("OldDataJson","Old Data"),area("ProposedDataJson","Proposed Data"),area("CheckerComments","Checker Comments")],
    "approval-workflow": [select("moduleName","Module","modules",true),area("makerRoles","Maker Roles"),area("makerUsers","Maker Users"),area("checkerRoles","Checker Roles"),area("checkerUsers","Checker Users"),select("approvalRequired","Approval Required","yes-no",true),select("selfApprovalAllowed","Self Approval Allowed","yes-no",true),number("minimumApprovers","Minimum Approvers",true,{ min:"1" }),select("status","Status","status-admin",true)],
    "audit-trace": [text("entityType","Entity Type"),text("entityId","Entity ID"),text("actionType","Action Type"),text("status","Status"),text("enteredBy","Entered By"),text("enteredDt","Entered Date")],
    // -----------------------------------------------------------
    // Assurance Management (Phase 1 - Admin / Authority Control Module)
    // Every metadata master is defined by Code + Name and a status.
    // Lifecycle fields (version, lifecycleStatus) are managed by the
    // API/SP; the form only exposes the editable business attributes.
    // -----------------------------------------------------------
    "assurance-categories": [text("code","Category Code",true),text("name","Category Name",true),area("description","Description"),number("displayOrder","Display Order",false,{ min:"0" }),select("status","Status","status-repository",true)],
    "assurance-scoring-models": [text("code","Model Code",true),text("name","Model Name",true),area("description","Description"),text("formulaType","Formula Type",false,{ placeholder:"Percentage / PassFail / WeightedAvg / RiskMatrix / Maturity / Compliance" }),area("formulaDefinition","Formula Definition",false,{ placeholder:"Configuration JSON only. Free-text SQL is rejected by the API." }),text("ratingScale","Rating Scale",false,{ placeholder:"e.g. 0-100 or Low;Medium;High;Critical" }),number("passThreshold","Pass Threshold",false,{ step:"0.01", min:"0" }),select("status","Status","status-repository",true)],
    "assurance-severity": [text("code","Severity Code",true),text("name","Severity Name",true),area("description","Description"),number("severityRank","Severity Rank",false,{ min:"1" }),text("colorCode","Color Code",false,{ placeholder:"#c92a2a" }),select("status","Status","status-repository",true)],
    "assurance-gap-categories": [text("code","Gap Code",true),text("name","Gap Name",true),area("description","Description"),number("displayOrder","Display Order",false,{ min:"0" }),select("status","Status","status-repository",true)],
    "assurance-workflow-templates": [text("code","Template Code",true),text("name","Template Name",true),area("description","Description"),number("slaHours","SLA (hours)",false,{ min:"0" }),area("escalationRule","Escalation Rule"),select("status","Status","status-repository",true)],
    "assurance-question-types": [text("code","Question Code",true),text("name","Question Name",true),area("description","Description"),text("answerShape","Answer Shape",false,{ placeholder:"Boolean / Choice / Text / Number / Date / Rating / Observation / Evidence / Checklist" }),select("requiresEvidence","Requires Evidence","yes-no"),number("displayOrder","Display Order",false,{ min:"0" }),select("status","Status","status-repository",true)],
    "assurance-sampling-models": [text("code","Sampling Code",true),text("name","Sampling Name",true),area("description","Description"),area("methodology","Methodology"),select("status","Status","status-repository",true)],
    "assurance-frequency-types": [text("code","Frequency Code",true),text("name","Frequency Name",true),area("description","Description"),number("intervalDays","Interval (days)",false,{ min:"0" }),number("displayOrder","Display Order",false,{ min:"0" }),select("status","Status","status-repository",true)],
    "assurance-report-templates": [text("code","Template Code",true),text("name","Template Name",true),area("description","Description"),text("reportScope","Report Scope",false,{ placeholder:"Executive / Engagement / Register / Dashboard" }),area("layoutDefinition","Layout Definition"),select("status","Status","status-repository",true)],
    "assurance-starter-templates": [text("code","Template Code",true),text("name","Template Name",true),area("description","Description"),select("categoryId","Assurance Category","assurance-categories"),select("scoringModelId","Scoring Model","assurance-scoring-models"),select("workflowTemplateId","Workflow Template","assurance-workflow-templates"),select("samplingModelId","Sampling Model","assurance-sampling-models"),select("frequencyTypeId","Frequency Type","assurance-frequency-types"),select("reportTemplateId","Report Template","assurance-report-templates"),select("status","Status","status-repository",true)],
    "assurance-version-history": [text("entityType","Entity Type"),text("entityId","Entity ID"),text("version","Version"),text("lifecycleStatus","Lifecycle Status"),text("actionCode","Action"),text("enteredBy","Changed By"),text("enteredDt","Changed On"),area("remarks","Remarks")],
    // SLA Master (043).  Not rendered by the generic modal -- openForm() redirects
    // to /Repository/SlaMaster.  Kept here as a fallback in case the redirect
    // path ever misses a mode, so the modal shows fields instead of a blank pane.
    "sla-master": [text("processCode","Process",true),select("classification","Classification","sla-classification",true),number("durationValue","Duration Value",true,{ min:"1" }),select("durationUnit","Duration Unit","sla-duration-units",true),select("timeBasis","Time Basis","sla-time-bases",true),number("warningPct","Warning %",true,{ min:"1", max:"99" }),number("escalationPct","Escalation %",true,{ min:"2", max:"100" }),date("effectiveFrom","Effective From"),area("remarks","Remarks"),select("status","Status","status-repository",true)]
  };
  const entityLabels = {
    "authorities": { singular: "Authority", add: "Add Authority", edit: "Edit Authority", view: "View Authority", saved: "Authority saved successfully." },
    "artifacts": { singular: "Artifact", add: "Add Artifact", edit: "Edit Artifact", view: "View Artifact", saved: "Artifact saved successfully." },
    "releases": { singular: "Release", add: "Add Release", edit: "Edit Release", view: "View Release", saved: "Release saved successfully." },
    "statement-classifications": { singular: "Source Classification", add: "Add Source Classification", edit: "Edit Source Classification", view: "View Source Classification", saved: "Source classification saved successfully." },
    "source-structure": { singular: "Source Node", add: "Add Source Node", addChild: "Add Child Node", edit: "Edit Source Node", view: "View Source Node", saved: "Source node saved successfully." },
    // The screen is titled "Source Statements" (RepositoryScreen.cs), so the
    // buttons and dialog titles on it say Source Statement too.  The entity key
    // stays framework-statements.
    "framework-statements": { singular: "Source Statement", add: "Add Source Statement", edit: "Edit Source Statement", view: "View Source Statement", saved: "Source statement saved successfully." },
    "controls": { singular: "Control", add: "Add Control", edit: "Edit Control", view: "View Control", saved: "Control saved successfully." },
    // The screen is titled "Practices" (RepositoryScreen.cs) and this is the
    // Practice module, so every button, dialog title and message says Practice.
    // The entity key stays requirements.
    "requirements": { singular: "Practice", add: "Add Practice", edit: "Edit Practice", view: "View Practice", saved: "Practice saved successfully." },
    "obligations": { singular: "Obligation", add: "Add Obligation", edit: "Edit Obligation", view: "View Obligation", saved: "Obligation saved successfully." },
    "obligation-evidence": { singular: "Evidence", add: "Add Evidence", edit: "Edit Evidence", view: "View Evidence", saved: "Evidence saved successfully." },
    "control-requirement-mappings": { singular: "Mapping", add: "Add Mapping", edit: "Update Mapping", view: "View Mapping", saved: "Mapping saved successfully." },
    "source-control-mappings": { singular: "Mapping", add: "Add Mapping", edit: "Update Mapping", view: "View Mapping", saved: "Mapping saved successfully." },
    "user-management": { singular: "User", add: "Add User", edit: "Edit User", view: "View User", saved: "User saved successfully." },
    "role-management": { singular: "Role", add: "Add Role", edit: "Edit Role", view: "View Role", saved: "Role saved successfully." },
    "menu-management": { singular: "Menu", add: "Add Menu", edit: "Edit Menu", view: "View Menu", saved: "Menu saved successfully." },
    "role-permissions": { singular: "Role Permission", add: "Add Role Permission", edit: "Edit Role Permission", view: "View Role Permission", saved: "Role permission saved successfully." },
    "applicability-rules": { singular: "Applicability Rule", add: "Add Applicability Rule", edit: "Edit Applicability Rule", view: "View Applicability Rule", saved: "Applicability rule saved successfully." },
    "changes": { singular: "Change", add: "Add Change", edit: "Edit Change", view: "View Change", saved: "Change saved successfully." },
    "impact-analysis": { singular: "Impact Analysis", add: "Add Impact Analysis", edit: "Edit Impact Analysis", view: "View Impact Analysis", saved: "Impact analysis saved successfully." },
    "notifications": { singular: "Notification", add: "Add Notification", edit: "Edit Notification", view: "View Notification", saved: "Notification saved successfully." },
    "change-management": { singular: "Change Request", add: "Add Change Request", edit: "Edit Change Request", view: "View Change Request", saved: "Change request saved successfully." },
    "approval-workflow": { singular: "Approval Workflow", add: "Add Approval Workflow", edit: "Edit Approval Workflow", view: "View Approval Workflow", saved: "Approval workflow saved successfully." },
    // Assurance Management (Phase 1) labels
    "assurance-categories": { singular: "Assurance Category", add: "Add Assurance Category", edit: "Edit Assurance Category", view: "View Assurance Category", saved: "Assurance category saved successfully." },
    "assurance-scoring-models": { singular: "Scoring Model", add: "Add Scoring Model", edit: "Edit Scoring Model", view: "View Scoring Model", saved: "Scoring model saved successfully." },
    "assurance-severity": { singular: "Observation Severity", add: "Add Observation Severity", edit: "Edit Observation Severity", view: "View Observation Severity", saved: "Observation severity saved successfully." },
    "assurance-gap-categories": { singular: "Gap Category", add: "Add Gap Category", edit: "Edit Gap Category", view: "View Gap Category", saved: "Gap category saved successfully." },
    "assurance-workflow-templates": { singular: "Workflow Template", add: "Add Workflow Template", edit: "Edit Workflow Template", view: "View Workflow Template", saved: "Workflow template saved successfully." },
    "assurance-question-types": { singular: "Question Type", add: "Add Question Type", edit: "Edit Question Type", view: "View Question Type", saved: "Question type saved successfully." },
    "assurance-sampling-models": { singular: "Sampling Model", add: "Add Sampling Model", edit: "Edit Sampling Model", view: "View Sampling Model", saved: "Sampling model saved successfully." },
    "assurance-frequency-types": { singular: "Frequency Type", add: "Add Frequency Type", edit: "Edit Frequency Type", view: "View Frequency Type", saved: "Frequency type saved successfully." },
    "assurance-report-templates": { singular: "Report Template", add: "Add Report Template", edit: "Edit Report Template", view: "View Report Template", saved: "Report template saved successfully." },
    "assurance-starter-templates": { singular: "Starter Assurance Template", add: "Add Starter Template", edit: "Edit Starter Template", view: "View Starter Template", saved: "Starter template saved successfully." },
    "assurance-version-history": { singular: "Version History Entry", add: "Add Entry", edit: "Edit Entry", view: "View Entry", saved: "Version history entry saved successfully." },
    "sla-master": { singular: "SLA", add: "Add SLA", edit: "Edit SLA", view: "View SLA", saved: "SLA saved successfully." }
  };
  const escapeHtml = value => String(value ?? "").replace(/[&<>"']/g, char => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;" })[char]);
  // Resolved against the application root (see gracUrl in site.js).
  const appUrl = path => window.gracUrl.app(path);
  const appAlert = (message, type = "info", title = "") => window.gracAlert ? window.gracAlert({ message, type, title }) : Promise.resolve(window.alert(message));
  const appConfirm = (message, options = {}) => window.gracConfirm ? window.gracConfirm({ message, type: options.type || "warning", title: options.title || "Please confirm", confirmText: options.confirmText || "Continue", cancelText: options.cancelText || "Cancel" }) : Promise.resolve(window.confirm(message));
  const appPrompt = (message, options = {}) => window.gracPrompt ? window.gracPrompt({ message, type: options.type || "info", title: options.title || "Comments", defaultValue: options.defaultValue || "", confirmText: options.confirmText || "Continue", cancelText: options.cancelText || "Cancel" }) : Promise.resolve(window.prompt(message, options.defaultValue || ""));
  /* Status badges carry their state in the colour so an inactive row is
     recognisable at a glance — which matters now that the 3-dots menu offers
     Activate or Inactive depending on it.  Unknown values keep the default. */
  const badgeTone = value => {
    const text = String(value || "").trim().toLowerCase();
    if (["inactive", "retired", "archived", "rejected", "cancelled", "canceled"].includes(text)) return " badge-muted";
    if (["pending approval", "draft", "review", "in review", "sent back"].includes(text)) return " badge-pending";
    return "";
  };
  const badge = value => `<span class="badge${badgeTone(value)}">${escapeHtml(value)}</span>`;
  const apiData = result => result.data?.[0] || result.Data?.[0] || [];
  const valueOf = (row, name) => row[name] ?? row[name[0].toUpperCase() + name.slice(1)] ?? "";
  const formatIstDateTime = value => {
    if (!value) return "";
    const text = String(value);
    const date = new Date(/[zZ]|[+-]\d\d:?\d\d$/.test(text) ? text : `${text}Z`);
    if (Number.isNaN(date.getTime())) return text;
    return date.toLocaleString("en-IN", {
      timeZone: "Asia/Kolkata",
      day: "2-digit",
      month: "2-digit",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      hour12: true
    }).replace(",", "") + " IST";
  };
  const formatDateOnly = value => {
    if (!value) return "";
    const text = String(value);
    const datePart = text.includes("T") ? text.split("T")[0] : text.split(" ")[0];
    if (/^\d{4}-\d{2}-\d{2}$/.test(datePart)) {
      const [year, month, day] = datePart.split("-");
      return `${day}/${month}/${year}`;
    }
    const date = new Date(/[zZ]|[+-]\d\d:?\d\d$/.test(text) ? text : `${text}Z`);
    if (Number.isNaN(date.getTime())) return text;
    return date.toLocaleDateString("en-IN", {
      timeZone: "Asia/Kolkata",
      day: "2-digit",
      month: "2-digit",
      year: "numeric"
    });
  };
  const parseJsonObject = value => {
    if (!value) return {};
    if (typeof value === "object") return value;
    try { return JSON.parse(value); } catch { return {}; }
  };
  const auditJsonKey = fieldName => {
    const normalized = String(fieldName || "").trim().toLowerCase().replace(/[^a-z0-9]/g, "");
    const map = {
      authorityname: "name", name: "name", code: "code", authoritycode: "code",
      jurisdiction: "jurisdiction", website: "website", description: "description", status: "status",
      artifact: "artifactId", artifactid: "artifactId", release: "releaseId", releaseid: "releaseId",
      sourcestucture: "structureNodeId", sourcestructure: "structureNodeId", statementreference: "statementReference",
      statementtitle: "statementTitle", statementtext: "statementText", statementtype: "statementType",
      statementclassification: "classificationId", displayorder: "displayOrder", domain: "domainId",
      subdomain: "subDomainId", practice: "requirementId", obligationname: "obligationText",
      executionfrequency: "frequencyType", evidencerequirement: "evidenceRequirement",
      retentionrequirement: "retentionRequirement", effectivedate: "effectiveDate", enddate: "endDate",
      releasenotes: "releaseNotes", changetype: "changeType", impactedentitytype: "impactedEntityType",
      impactedentityid: "impactedEntityId", recommendedaction: "recommendedAction"
    };
    return map[normalized] || (normalized ? `${normalized[0]}${normalized.slice(1)}` : "");
  };
  const auditValue = (row, column) => {
    const direct = row[column];
    if (direct !== null && direct !== undefined && String(direct) !== "") return direct;
    const key = auditJsonKey(row.FieldName);
    const json = parseJsonObject(column === "FromValue" ? row.BeforeJson : row.AfterJson);
    return key && Object.prototype.hasOwnProperty.call(json, key) ? json[key] : "";
  };
  const cellValue = (row, column) => {
    const value = cmScreen.Key === "audit-trace" && (column === "FromValue" || column === "ToValue") ? auditValue(row, column) : row[column];
    if (column === "Status" || column === "Severity" || column === "LifecycleStatus") return badge(value);
    if (cmScreen.Key === "releases" && (column === "EffectiveDate" || column === "EndDate")) return escapeHtml(formatDateOnly(value));
    if (column === "ChangedOn" || column === "SubmittedOn" || column === "CheckedOn" || column === "EnteredDt" || column.endsWith("Date") || column.endsWith("Dt")) return escapeHtml(formatIstDateTime(value));
    return escapeHtml(value);
  };
  const standardFrequencyMap = {
    "Daily": { value: 1, unit: "Day" },
    "Weekly": { value: 1, unit: "Week" },
    "Monthly": { value: 1, unit: "Month" },
    "Quarterly": { value: 3, unit: "Month" },
    "Half-Yearly": { value: 6, unit: "Month" },
    "Annual": { value: 12, unit: "Month" },
    "Event Driven": { value: "", unit: "" },
    "Continuous": { value: "", unit: "" }
  };
  const formValueOf = (row, field) => {
    const value = valueOf(row, field.name);
    if (field.type === "tags") {
      if (Array.isArray(value)) return value;
      try { return JSON.parse(value || "[]"); } catch { return String(value || "").split(",").map(item => item.trim()).filter(Boolean); }
    }
    if (field.type === "evidence-grid") {
      // SP returns the saved evidence as EvidenceRequirementsJson on the row.
      // Accept either evidenceRequirements (camelCase) or the JSON string column.
      if (Array.isArray(value)) return value;
      const raw = value || row?.EvidenceRequirementsJson || row?.evidenceRequirementsJson || "[]";
      try { const parsed = JSON.parse(raw); return Array.isArray(parsed) ? parsed : []; } catch { return []; }
    }
    if (field.type !== "multiselect" || Array.isArray(value)) return value;
    try { return JSON.parse(value || "[]"); } catch { return []; }
  };
  const formEntityKey = () => state.formContext.entityKey || cmScreen.Key;
  const entityLabel = (key = formEntityKey()) => entityLabels[key] || { singular: cmScreen.Title || "Record", add: `Add ${cmScreen.Title || "Record"}`, edit: `Edit ${cmScreen.Title || "Record"}`, view: `View ${cmScreen.Title || "Record"}`, saved: `${cmScreen.Title || "Record"} saved successfully.` };
  const dialogTitleFor = (mode, key = formEntityKey()) => {
    const labels = entityLabel(key);
    if (mode === "add-child") return labels.addChild || labels.add;
    if (mode === "add") return labels.add;
    if (mode === "edit") return labels.edit;
    return labels.view;
  };
  const addDefaultStatusEntities = new Set(["authorities","artifacts","releases","statement-classifications","source-structure","framework-statements","controls","control-domains","control-sub-domains","requirements","source-control-mappings","applicability-rules","user-management","role-management","menu-management","role-permissions","approval-workflow"]);
  const changeActionTypes = ["Add", "Edit", "Inactive", "Activate", "Approve", "Reject", "Send Back"];
  const auditActionTypes = ["Add", "Edit", "Inactivate", "Activate", "Status Change", "Delete"];
  const formSchema = key => {
    const schema = schemas[key] || [];
    if (state.mode !== "add") return schema;
    return schema.filter(field => {
      const name = String(field.name).toLowerCase();
      if (name.endsWith("status") || name === "status") return false;
      if (name === "displayorder" && key !== "menu-management") return false;
      // Practice Code is auto-generated on save, so it is not on the Add form.
      if (name === "code" && key === "requirements") return false;
      return true;
    });
  };
  const saveTextFor = () => state.id ? "Update" : "Save";
  const addButtonLabel = () => {
    if (cmScreen.Key === "source-structure") return releaseSelect.value ? "Add Source Node" : "Add Source Node";
    if (cmScreen.Key === "source-control-mappings") return "Add Mapping";
    return entityLabel(cmScreen.Key).add;
  };
  const refreshAddButtonLabel = () => {
    if (addRecordButton) addRecordButton.innerHTML = `<i class="fa-solid fa-plus"></i> ${addButtonLabel()}`;
  };

  async function fetchJson(url, options) {
    let response;
    try {
      response = await fetch(url, options);
    } catch {
      throw new Error(`Unable to reach the ControlManagement API at ${cmApi}. Start the API project and refresh this page.`);
    }
    let result;
    try { result = await response.json(); }
    catch { throw new Error("The repository service returned an invalid response."); }
    if (response.status === 401) throw new Error("Your session has expired. Please sign in again.");
    if (response.status === 403) throw new Error("You do not have permission to perform this action.");
    if (!(result.success ?? result.Success)) throw new Error(result.message || result.Message || "Request failed.");
    return result;
  }
  async function fetchRows(entity, params = {}) {
    const qs = new URLSearchParams(params);
    return apiData(await fetchJson(`${cmApi}/${entity}?${qs}`));
  }
  async function createNavigationCode(payload) {
    const result = await fetchJson(`${cmApi}/navigation-code`, {
      method: "POST",
      headers: { "Content-Type":"application/json", "X-CSRF-TOKEN":csrfToken },
      body: JSON.stringify(payload)
    });
    return result.code || result.Code || "";
  }
  async function loadNavigationContext() {
    if (!state.navigationCode) return;
    const result = await fetchJson(`${cmApi}/navigation-context?code=${encodeURIComponent(state.navigationCode)}&targetArea=${encodeURIComponent(cmScreen.Key)}`);
    state.navigationContext = {
      filterType: result.filterType || result.FilterType || "",
      filterId: result.filterId || result.FilterId || "",
      parentAuthorityId: result.parentAuthorityId || result.ParentAuthorityId || "",
      parentArtifactId: result.parentArtifactId || result.ParentArtifactId || "",
      displayCode: result.displayCode || result.DisplayCode || "",
      displayName: result.displayName || result.DisplayName || ""
    };
  }
  async function loadLookups() {
    const result = await fetchJson(`${cmApi}/lookups`);
    const items = apiData(result);
    state.lookups = items.reduce((all, item) => {
      const key = item.LookupKey ?? item.lookupKey;
      (all[key] ||= []).push({ value: item.Value ?? item.value, label: item.Label ?? item.label });
      return all;
    }, {});
    const [artifactRows, releaseRows] = await Promise.all([
      fetchRows("artifacts", { status: "Active" }),
      fetchRows("releases", { status: "" })
    ]);
    state.lookups.artifacts = artifactRows.map(row => ({
      value: row.Id,
      label: [row.Code, row.Name].filter(Boolean).join(" - ") || row.Artifact || row.Name || row.Id,
      authorityId: row.AuthorityId
    }));
    state.lookups.releases = releaseRows.map(row => ({
      value: row.Id,
      label: [row.ArtifactCode || row.Artifact, row.Version].filter(Boolean).join(" / ") || row.Release || row.Version || row.Id,
      authorityId: row.AuthorityId,
      artifactId: row.ArtifactId
    }));
    state.lookups["frequency-types"] = [
      { value: "Daily", label: "Daily" },
      { value: "Weekly", label: "Weekly" },
      { value: "Monthly", label: "Monthly" },
      { value: "Quarterly", label: "Quarterly" },
      { value: "Half-Yearly", label: "Half-Yearly" },
      { value: "Annual", label: "Annual" },
      { value: "Event Driven", label: "Event Driven" },
      { value: "Continuous", label: "Continuous" },
      { value: "Custom", label: "Custom" }
    ];
    if (!state.lookups["frequency-master"]?.length) state.lookups["frequency-master"] = state.lookups["frequency-types"];

    // Assurance Management (Phase 1) lookups.  Fetched from the dedicated
    // dbo.cm_get_assurance_repository procedure and merged into the shared
    // lookup catalogue so Starter Template forms can bind to Assurance
    // categories, scoring models, workflow templates, etc.
    try {
      const assurance = await fetchJson(`${cmApi}/assurance-lookups`);
      const assuranceItems = apiData(assurance);
      assuranceItems.forEach(item => {
        const key = item.LookupKey ?? item.lookupKey;
        if (!key) return;
        (state.lookups[key] ||= []).push({ value: item.Value ?? item.value, label: item.Label ?? item.label });
      });
    } catch (assuranceLookupError) {
      // Assurance lookups are only required for Assurance screens.  Do not
      // block the rest of the Repository Management if the endpoint is not
      // yet available in this environment.
      console.warn("Assurance lookups unavailable", assuranceLookupError);
    }
  }
  function optionsFor(key, selected) {
    const values = Array.isArray(selected) ? selected.map(String) : [String(selected ?? "")];
    return [`<option value="">Select...</option>`, ...(state.lookups[key] || []).map(item =>
      `<option value="${escapeHtml(item.value)}"${values.includes(String(item.value)) ? " selected" : ""}>${escapeHtml(item.label)}</option>`)].join("");
  }
  function releaseLabelFromSelect() {
    if (state.navigationContext?.filterType === "Release") return [state.navigationContext.displayName, state.navigationContext.displayCode].filter(Boolean).join(" / ");
    if (!["source-structure","statement-classifications"].includes(cmScreen.Key) || !releaseSelect.value) return "";
    return releaseSelect.selectedOptions[0]?.textContent || "";
  }
  function classificationReleaseId() {
    return document.querySelector("#field-releaseId")?.value || releaseSelect.value || "";
  }
  async function refreshStatementClassificationOptions(selected = "", readonly = false) {
    const select = document.querySelector("#field-classificationId");
    if (!select) return;
    const wrapper = select.closest(".form-field");
    const releaseId = classificationReleaseId();
    if (wrapper) wrapper.hidden = false;
    const items = releaseId ? await fetchRows("statement-classifications", { releaseId, status: "Active" }) : [];
    if (!items.length) {
      select.innerHTML = `<option value="">No classifications configured</option>`;
      select.disabled = true;
      return;
    }
    select.disabled = readonly;
    select.innerHTML = `<option value="">None</option>${items.map(item => `<option value="${escapeHtml(item.Id)}"${String(item.Id) === String(selected) ? " selected" : ""}>${escapeHtml(item.ClassificationName || item.Name || `Classification #${item.Id}`)}</option>`).join("")}`;
  }
  function buildTree(records) {
    const map = new Map(records.map(row => [String(row.Id), { row, children: [] }]));
    const roots = [];
    map.forEach(node => {
      const parentId = String(node.row.ParentNodeId || "");
      if (parentId && map.has(parentId) && parentId !== String(node.row.Id)) map.get(parentId).children.push(node);
      else roots.push(node);
    });
    const sort = items => {
      items.sort((a, b) => Number(a.row.DisplayOrder || 0) - Number(b.row.DisplayOrder || 0)
        || String(a.row.Reference || "").localeCompare(String(b.row.Reference || "")));
      items.forEach(item => sort(item.children));
    };
    sort(roots);
    return roots;
  }
  function flattenTree(records, includeCollapsed = false) {
    const output = [];
    const walk = (items, depth) => items.forEach(item => {
      output.push({ row: item.row, depth, hasChildren: item.children.length > 0 });
      if (includeCollapsed || !state.collapsed.has(String(item.row.Id))) walk(item.children, depth + 1);
    });
    walk(buildTree(records), 0);
    return output;
  }
  function leafIds(records) {
    const parents = new Set(records.map(row => String(row.ParentNodeId || "")).filter(Boolean));
    return new Set(records.filter(row => !parents.has(String(row.Id))).map(row => String(row.Id)));
  }
  function sourceTreeLabel(row) {
    return [row.Reference, row.Title].filter(Boolean).join(" - ") || row.NodeType || `Node #${row.Id}`;
  }
  function sourceTreePath(id) {
    const byId = new Map(frameworkStatementTreeState.nodes.map(row => [String(row.Id), row]));
    const parts = [];
    let current = byId.get(String(id));
    const guard = new Set();
    while (current && !guard.has(String(current.Id))) {
      guard.add(String(current.Id));
      parts.unshift(sourceTreeLabel(current));
      current = byId.get(String(current.ParentNodeId || ""));
    }
    return parts.join(" / ");
  }
  function sourceTreeRow(id) {
    return frameworkStatementTreeState.nodes.find(row => String(row.Id) === String(id));
  }
  function sourceTreeReference(id) {
    const row = sourceTreeRow(id);
    return row ? String(row.Reference || row.Code || "").trim() : "";
  }
  function initializeStatementReferenceAutoState() {
    const referenceInput = document.querySelector("#field-statementReference");
    const selectedReference = sourceTreeReference(frameworkStatementTreeState.selected);
    state.formContext.autoStatementReference = referenceInput && selectedReference && referenceInput.value.trim() === selectedReference
      ? selectedReference
      : "";
  }
  function syncStatementReferenceFromSource(id) {
    const referenceInput = document.querySelector("#field-statementReference");
    if (!referenceInput || referenceInput.readOnly || referenceInput.disabled) return;
    const nextReference = sourceTreeReference(id);
    if (!nextReference) return;
    const previousAuto = state.formContext.autoStatementReference || "";
    const currentReference = referenceInput.value.trim();
    if (!currentReference || currentReference === previousAuto) {
      referenceInput.value = nextReference;
      state.formContext.autoStatementReference = nextReference;
    }
  }
  function clearAutoStatementReference() {
    const referenceInput = document.querySelector("#field-statementReference");
    const previousAuto = state.formContext.autoStatementReference || "";
    if (referenceInput && (!referenceInput.value.trim() || referenceInput.value.trim() === previousAuto)) {
      referenceInput.value = "";
    }
    state.formContext.autoStatementReference = "";
  }
  function renderFrameworkStatementSourceTree() {
    const host = document.querySelector("#frameworkStatementSourceTree");
    const input = document.querySelector("#field-structureNodeId");
    if (!host || !input) return;
    const releaseId = document.querySelector("#field-releaseId")?.value || "";
    if (!releaseId) {
      host.innerHTML = `<div class="source-tree-empty">Select a Release to load Source Structure.</div>`;
      return;
    }
    if (!frameworkStatementTreeState.nodes.length) {
      host.innerHTML = `<div class="source-tree-empty">No source structure configured for this release.</div>`;
      return;
    }
    const selectedPath = frameworkStatementTreeState.selected ? sourceTreePath(frameworkStatementTreeState.selected) : "";
    if (frameworkStatementTreeState.readonly && selectedPath) {
      host.innerHTML = `<div class="source-tree-selected readonly"><strong>Selected:</strong> ${escapeHtml(selectedPath)}</div>`;
      input.value = frameworkStatementTreeState.selected || "";
      return;
    }
    const walk = (items, depth = 0) => items.map(item => {
      const row = item.row;
      const id = String(row.Id);
      const hasChildren = item.children.length > 0;
      const collapsed = frameworkStatementTreeState.collapsed.has(id);
      const selected = frameworkStatementTreeState.selected === id;
      const toggle = hasChildren ? `<button type="button" class="map-tree-toggle" data-fs-source-toggle="${escapeHtml(id)}"><i class="fa-solid fa-chevron-${collapsed ? "right" : "down"}"></i></button>` : `<span class="map-tree-spacer"></span>`;
      return `<div class="map-tree-row source-tree-option${hasChildren ? " parent" : ""}${selected ? " selected" : ""}" role="radio" aria-checked="${selected ? "true" : "false"}" tabindex="${frameworkStatementTreeState.readonly ? "-1" : "0"}" style="--tree-depth:${depth}" data-fs-source-row="${escapeHtml(id)}">
        ${toggle}
        <span class="source-tree-check" aria-hidden="true">${selected ? `<i class="fa-solid fa-check"></i>` : ""}</span>
        <span class="map-node-text" title="${escapeHtml(sourceTreePath(id))}">${escapeHtml(sourceTreeLabel(row))}</span>
      </div>${collapsed ? "" : walk(item.children, depth + 1)}`;
    }).join("");
    host.innerHTML = `<div class="source-tree-selected">${selectedPath ? `<strong>Selected:</strong> ${escapeHtml(selectedPath)}` : "Select one source structure node."}</div><div class="source-tree-list">${walk(buildTree(frameworkStatementTreeState.nodes))}</div>`;
    input.value = frameworkStatementTreeState.selected || "";
  }
  function selectFrameworkStatementSourceNode(id) {
    if (frameworkStatementTreeState.readonly || !id) return;
    frameworkStatementTreeState.selected = String(id);
    const input = document.querySelector("#field-structureNodeId");
    if (input) input.value = frameworkStatementTreeState.selected;
    syncStatementReferenceFromSource(id);
    renderFrameworkStatementSourceTree();
  }
  async function loadFrameworkStatementSourceTree(releaseId, selectedId = "", readonly = false) {
    frameworkStatementTreeState.readonly = readonly;
    frameworkStatementTreeState.selected = selectedId ? String(selectedId) : "";
    frameworkStatementTreeState.nodes = releaseId ? await fetchRows("source-structure", { releaseId, status: "Active" }) : [];
    if (frameworkStatementTreeState.selected && !frameworkStatementTreeState.nodes.some(row => String(row.Id) === frameworkStatementTreeState.selected)) {
      frameworkStatementTreeState.selected = "";
    }
    renderFrameworkStatementSourceTree();
  }
  function checkboxComboMarkup(field, value, readonly) {
    const values = Array.isArray(value) ? value.map(String) : [];
    const options = (state.lookups[field.lookup] || []).map(item =>
      `<label class="checkbox-combo-option"><input type="checkbox" value="${escapeHtml(item.value)}"${values.includes(String(item.value)) ? " checked" : ""}${readonly ? " disabled" : ""}> <span>${escapeHtml(item.label)}</span></label>`).join("");
    return `<div class="checkbox-combo${field.listbox ? " checkbox-combo-listbox" : ""}" id="field-${field.name}" data-checkbox-combo><button type="button" class="checkbox-combo-trigger" aria-haspopup="listbox" aria-expanded="false"${readonly ? " disabled" : ""}><span data-checkbox-combo-summary>Select...</span><i class="fa-solid fa-chevron-down" aria-hidden="true"></i></button><div class="checkbox-combo-menu" role="listbox" aria-multiselectable="true">${field.search ? `<input class="checkbox-combo-search" type="search" placeholder="Search..." aria-label="Search ${escapeHtml(field.label)}">` : ""}<div class="checkbox-combo-options" data-checkbox-combo-options>${options}</div></div></div>`;
  }
  function checkboxComboMenu(combo) {
    return combo?.querySelector(".checkbox-combo-menu") || (combo?.dataset.comboId ? document.querySelector(`.checkbox-combo-menu[data-combo-id="${combo.dataset.comboId}"]`) : null);
  }
  function checkboxComboInputs(combo) {
    const menu = checkboxComboMenu(combo);
    return menu ? menu.querySelectorAll('input[type="checkbox"]') : combo.querySelectorAll('input[type="checkbox"]');
  }
  function updateCheckboxCombo(combo) {
    const labels = Array.from(checkboxComboInputs(combo)).filter(option => option.checked).map(option => option.closest(".checkbox-combo-option")?.querySelector("span")?.textContent?.trim() || option.value);
    combo.querySelector("[data-checkbox-combo-summary]").textContent = labels.length > 3 ? `${labels.slice(0, 3).join(", ")} +${labels.length - 3} more` : labels.join(", ") || combo.dataset.emptyLabel || "Select...";
  }
  function filterCheckboxCombo(combo, term) {
    const queryText = term.trim().toLowerCase();
    checkboxComboMenu(combo)?.querySelectorAll(".checkbox-combo-option").forEach(option => {
      option.hidden = queryText && !option.textContent.toLowerCase().includes(queryText);
    });
  }
  function setCheckboxComboOptions(combo, items, selected = [], disabled = false) {
    const selectedSet = new Set(selected.map(String));
    const host = combo.querySelector("[data-checkbox-combo-options]") || combo.querySelector(".checkbox-combo-menu");
    host.innerHTML = items.map(item => `<label class="checkbox-combo-option"><input type="checkbox" value="${escapeHtml(item.value)}"${selectedSet.has(String(item.value)) ? " checked" : ""}${disabled ? " disabled" : ""}> <span>${escapeHtml(item.label)}</span></label>`).join("");
    combo.querySelector(".checkbox-combo-trigger").disabled = disabled;
    updateCheckboxCombo(combo);
  }
  function tagList(value) {
    return Array.isArray(value) ? value.map(String).filter(Boolean) : String(value || "").split(",").map(item => item.trim()).filter(Boolean);
  }
  function tagsMarkup(field, value, readonly) {
    const tagsValue = tagList(value).join(", ");
    return `<div class="tag-input-wrap" id="field-${field.name}" data-tag-input>
      <input type="text" value="${escapeHtml(tagsValue)}" placeholder="${escapeHtml(field.placeholder || "Enter keywords separated by comma")}"${readonly ? " disabled" : ""}>
      <div class="tag-preview" data-tag-preview></div>
    </div>`;
  }
  // ---------- Evidence grid (used by the Obligation Master form) ----------
  function parseEvidenceRows(value) {
    if (!value) return [];
    if (Array.isArray(value)) return value;
    try { const parsed = JSON.parse(value); return Array.isArray(parsed) ? parsed : []; } catch { return []; }
  }
  function evidenceRowMarkup(row = {}, readonly = false) {
    const evidenceTypeOptions = optionsFor("evidence-types", row.EvidenceTypeId ?? row.evidenceTypeId ?? "");
    const frequencyOptions    = optionsFor("frequency-master", row.FrequencyId ?? row.frequencyId ?? "");
    const retention           = row.RetentionRequirement ?? row.retentionRequirement ?? "";
    const remarks             = row.Remarks ?? row.remarks ?? "";
    return `<div class="evidence-row" data-evidence-row>
      <div class="evidence-cell"><select data-evidence-field="evidenceTypeId"${readonly ? " disabled" : ""}>${evidenceTypeOptions}</select></div>
      <div class="evidence-cell"><select data-evidence-field="frequencyId"${readonly ? " disabled" : ""}>${frequencyOptions}</select></div>
      <div class="evidence-cell"><input type="text" data-evidence-field="retentionRequirement" placeholder="e.g. retain 7 years" value="${escapeHtml(retention)}"${readonly ? " disabled" : ""}></div>
      <div class="evidence-cell"><input type="text" data-evidence-field="remarks" placeholder="Notes for this evidence" value="${escapeHtml(remarks)}"${readonly ? " disabled" : ""}></div>
      <div class="evidence-cell evidence-actions">${readonly ? "" : `<button type="button" class="mini-icon danger" data-evidence-remove title="Remove evidence row"><i class="fa-solid fa-xmark"></i></button>`}</div>
    </div>`;
  }
  function evidenceGridMarkup(field, value, readonly) {
    const rows = parseEvidenceRows(value);
    const rowsHtml = (rows.length ? rows : [{}]).map(row => evidenceRowMarkup(row, readonly)).join("");
    const addBtn = readonly ? "" : `<button type="button" class="button" data-evidence-add><i class="fa-solid fa-plus"></i> Add Evidence</button>`;
    return `<div class="evidence-grid" id="field-${field.name}" data-evidence-grid>
      <div class="evidence-grid-head">
        <div>Evidence Type</div><div>Assurance Frequency</div><div>Retention</div><div>Remarks</div><div></div>
      </div>
      <div class="evidence-grid-body">${rowsHtml}</div>
      <div class="evidence-grid-foot">${addBtn}</div>
    </div>`;
  }
  function collectEvidenceGrid(host) {
    const rows = Array.from(host.querySelectorAll("[data-evidence-row]"));
    return rows.map(row => ({
      evidenceTypeId:       row.querySelector('[data-evidence-field="evidenceTypeId"]')?.value || "",
      frequencyId:          row.querySelector('[data-evidence-field="frequencyId"]')?.value || "",
      retentionRequirement: row.querySelector('[data-evidence-field="retentionRequirement"]')?.value?.trim() || "",
      remarks:              row.querySelector('[data-evidence-field="remarks"]')?.value?.trim() || ""
    })).filter(item => item.evidenceTypeId);
  }
  function bindEvidenceGrids(scope) {
    scope.querySelectorAll("[data-evidence-grid]").forEach(grid => {
      const body = grid.querySelector(".evidence-grid-body");
      grid.querySelector("[data-evidence-add]")?.addEventListener("click", () => {
        body.insertAdjacentHTML("beforeend", evidenceRowMarkup({}, false));
      });
      grid.addEventListener("click", event => {
        const btn = event.target.closest("[data-evidence-remove]");
        if (!btn) return;
        const row = btn.closest("[data-evidence-row]");
        if (row && body.children.length > 1) row.remove();
      });
    });
  }
  function updateTagPreview(host) {
    const values = tagList(host.querySelector("input")?.value || "");
    host.querySelector("[data-tag-preview]").innerHTML = values.map(item => `<span>${escapeHtml(item)}</span>`).join("");
  }
  function closeCheckboxCombos(except) {
    document.querySelectorAll("[data-checkbox-combo].open").forEach(combo => {
      if (combo === except) return;
      combo.classList.remove("open");
      const menu = checkboxComboMenu(combo);
      if (menu) {
        menu.style.top = "";
        menu.style.left = "";
        menu.style.width = "";
        menu.style.display = "";
        delete menu.dataset.floatingCheckboxMenu;
        if (!combo.contains(menu)) combo.appendChild(menu);
      }
      combo.closest(".obligation-grid-wrap")?.classList.remove("combo-open");
      fieldsHost.classList.remove("combo-open");
      combo.querySelector(".checkbox-combo-trigger")?.setAttribute("aria-expanded", "false");
    });
  }
  function positionCheckboxCombo(combo) {
    if (!combo.classList.contains("obligation-evidence-combo")) return;
    combo.closest(".obligation-grid-wrap")?.classList.add("combo-open");
    fieldsHost.classList.add("combo-open");
  }
  function resetFormState() {
    message.hidden = true;
    message.textContent = "";
    fieldsHost.querySelectorAll(".field-error").forEach(field => field.classList.remove("field-error"));
    dialog.classList.remove("compact-statement-dialog");
    dialog.classList.remove("practice-dialog");
    // Brings the Practice grid and its page heading back when the in-page form
    // closes (Save, Cancel or Esc).
    document.body.classList.remove("practice-form-open");
    dialog.classList.remove("obligation-matrix-dialog");
    // Also covers an Esc-key close while in Edit Mode.
    state.formReturnToView = false;
    closeCheckboxCombos();
  }
  function closeForm() {
    resetFormState();
    dialog.close();
  }
  /* ------------------------------------------------------------------ view/edit
     The record dialog is a single surface with two modes.  Opening a record
     always lands in View Mode; the Edit button re-renders the same dialog in
     Edit Mode without navigating away.  Save and Cancel both come back to
     View Mode, so the user never loses their place in the grid. */
  function canEditInDialog() {
    return permissions.has("EDIT") && !nonEditableAreas.has(cmScreen.Key);
  }
  /* The heading carries the mode chip as a child element, so the title text has
     to be replaced without dropping it. */
  function setDialogTitle(text) {
    const host = document.querySelector("#dialogTitle");
    host.textContent = `${text} `;
    if (modeChip) host.appendChild(modeChip);
  }
  /* Legacy obligation-matrix dialogs drive their own buttons and have no
     in-place edit switch — reset the shared chrome before they render. */
  function resetDialogChrome() {
    state.formReturnToView = false;
    state.pendingModeSwitch = false;
    if (editButton) editButton.hidden = true;
    if (modeChip) modeChip.hidden = true;
    cancelButton.textContent = "Cancel / Back";
    dialog.classList.remove("record-dialog-view-mode");
  }
  function applyDialogMode(mode) {
    const readonly = mode === "view";
    // Edit is offered only on a saved record the user is allowed to edit.
    if (editButton) editButton.hidden = !(readonly && state.id && canEditInDialog());
    if (modeChip) {
      modeChip.hidden = !(readonly || state.formReturnToView);
      modeChip.textContent = readonly ? "View Mode" : "Edit Mode";
      modeChip.classList.toggle("is-edit", !readonly);
    }
    // Returning from Edit Mode is a cancel; leaving View Mode is a close.
    cancelButton.textContent = readonly ? "Close" : state.formReturnToView ? "Cancel" : "Cancel / Back";
    dialog.classList.toggle("record-dialog-view-mode", readonly);
    // Short cross-fade so the switch reads as one surface changing state
    // rather than a new dialog appearing.
    fieldsHost.classList.remove("mode-switching");
    void fieldsHost.offsetWidth;
    fieldsHost.classList.add("mode-switching");
  }
  async function switchDialogMode(mode) {
    if (!state.id) return;
    // openForm() resets the flag from here, so a fresh open from the grid still
    // starts with a clean slate.
    state.pendingModeSwitch = mode !== "view";
    try {
      await openForm(mode, state.id, state.formContext);
    } catch (error) {
      message.textContent = error.message;
      message.hidden = false;
    }
  }
  function isFieldLocked(name) {
    return (state.formContext.lockedFields || []).map(String).includes(String(name));
  }
  function lookupLabel(key, id) {
    if (!id) return "";
    return state.lookups[key]?.find(item => String(item.value) === String(id))?.label || "";
  }
  function sourceContextParts(record = {}) {
    const releaseId = state.formContext.releaseId || record.ReleaseId || record.releaseId || releaseSelect.value || "";
    // The releases lookup carries the owning artifact and authority, so the
    // banner follows whatever Release the user picks on the form rather than
    // whatever the grid happens to be filtered to.
    const releaseLookup = state.lookups.releases?.find(item => String(item.value) === String(releaseId));
    const artifactId = state.formContext.parentArtifactId || record.ArtifactId || record.artifactId || releaseLookup?.artifactId || releaseArtifactId() || artifactSelect.value || "";
    const authorityId = state.formContext.parentAuthorityId || record.AuthorityId || record.authorityId || releaseLookup?.authorityId || releaseAuthorityId() || authoritySelect.value || "";
    return {
      authority: state.formContext.authorityLabel || record.Authority || record.authority || lookupLabel("authorities", authorityId),
      artifact: state.formContext.artifactLabel || [record.ArtifactCode || record.artifactCode, record.Artifact || record.artifact].filter(Boolean).join(" - ") || lookupLabel("artifacts", artifactId),
      release: state.formContext.releaseLabel || record.Version || record.version || record.Release || record.release || lookupLabel("releases", releaseId) || releaseLabelFromSelect()
    };
  }
  function renderSourceNodeContext(record = {}) {
    if (formEntityKey() !== "source-structure") return;
    // Re-rendered whenever the Release changes, so clear the previous banner.
    fieldsHost.querySelector(".source-node-context")?.remove();
    const context = sourceContextParts(record);
    if (!context.authority && !context.artifact && !context.release) return;
    fieldsHost.insertAdjacentHTML("afterbegin", `<section class="source-node-context full" aria-label="Selected release context">
      <div><span>Authority</span><strong>${escapeHtml(context.authority || "Not available")}</strong></div>
      <div><span>Artifact</span><strong>${escapeHtml(context.artifact || "Not available")}</strong></div>
      <div><span>Release</span><strong>${escapeHtml(context.release || "Not available")}</strong></div>
    </section>`);
  }
  function fieldMarkup(field, value, readonly) {
    if (field.type === "date" && value) value = String(value).slice(0, 10);
    const id = `field-${field.name}`, required = field.required ? `<span class="required"> *</span>` : "";
    const disabled = readonly || field.disabled || isFieldLocked(field.name);
    const common = `${disabled ? " disabled" : field.readonly ? " readonly" : ""}${field.required ? " required" : ""}`;
    let control;
    if (field.type === "textarea") control = `<textarea id="${id}" name="${field.name}" rows="3"${common} placeholder="${escapeHtml(field.placeholder || "")}">${escapeHtml(value)}</textarea>`;
    else if (field.type === "source-tree") control = `<input id="${id}" name="${field.name}" type="hidden" value="${escapeHtml(value || "")}"${field.required ? " required" : ""}><div class="source-tree-select" id="frameworkStatementSourceTree"></div>`;
    else if (field.type === "multiselect" && field.compact) control = checkboxComboMarkup(field, value, readonly);
    else if (field.type === "select" || field.type === "multiselect") control = `<select id="${id}" name="${field.name}"${field.type === "multiselect" ? " multiple size=\"6\"" : ""}${common}>${optionsFor(field.lookup, value)}</select>`;
    else if (field.type === "checkbox") control = `<span><input id="${id}" name="${field.name}" type="checkbox"${value === true || value === 1 || value === "1" ? " checked" : ""}${readonly ? " disabled" : ""}> Yes</span>`;
    else if (field.type === "tags") control = tagsMarkup(field, value, readonly);
    else if (field.type === "evidence-grid") control = evidenceGridMarkup(field, value, readonly);
    else control = `<input id="${id}" name="${field.name}" type="${field.inputType || field.type}" value="${escapeHtml(value)}"${common}${field.placeholder ? ` placeholder="${escapeHtml(field.placeholder)}"` : ""}${field.min !== undefined ? ` min="${field.min}"` : ""}>`;
    const addButton = field.addButton && !readonly ? `<button type="button" class="inline-add-master" data-add-master="${field.name}"><i class="fa-solid fa-plus"></i> ${escapeHtml(field.addButton)}</button>` : "";
    return `<div class="form-field${field.full ? " full" : ""}${field.listbox ? " listbox-field" : ""}" data-field-name="${escapeHtml(field.name)}"><span class="form-field-label">${escapeHtml(field.label)}${required}</span>${control}${addButton}</div>`;
  }

  function updateFrequencyFields(scope = fieldsHost) {
    if (cmScreen.Key !== "obligations" || state.mode === "obligation-mapping") return;
    const frequency = scope.querySelector("[name='frequencyType']")?.value || "";
    const isCustom = frequency === "Custom";
    ["frequencyValue", "frequencyUnit"].forEach(name => {
      const wrapper = scope.querySelector(`[data-field-name='${name}']`);
      const input = scope.querySelector(`[name='${name}']`);
      if (!wrapper || !input) return;
      wrapper.hidden = !isCustom;
      input.required = isCustom;
      if (!isCustom) {
        const mapped = standardFrequencyMap[frequency] || { value: "", unit: "" };
        input.value = name === "frequencyValue" ? mapped.value : mapped.unit;
      }
    });
  }

  function normalizeFrequencyPayload(data) {
    const frequency = data.frequencyType || "";
    if (frequency !== "Custom") {
      const mapped = standardFrequencyMap[frequency] || { value: "", unit: "" };
      data.frequencyValue = mapped.value === "" ? "" : Number(mapped.value);
      data.frequencyUnit = mapped.unit;
      return data;
    }
    if (!String(data.frequencyValue || "").trim()) throw new Error("Frequency Value is required when Frequency is Custom.");
    if (!String(data.frequencyUnit || "").trim()) throw new Error("Frequency Unit is required when Frequency is Custom.");
    return data;
  }
  async function openForm(mode, id = 0, preset = {}) {
    if (cmScreen.Key === "obligation-mappings") {
      // Open the full-page form instead of the modal - the matrix needs the
      // whole content area to render the per-Statement obligation grid.
      const params = new URLSearchParams();
      params.set("mode", mode || "add");
      if (id) params.set("id", id);
      if (preset && preset.requirementId) params.set("requirementId", preset.requirementId);
      window.location.assign(appUrl(`/Repository/ObligationMapping?${params.toString()}`));
      return;
    }
    if (cmScreen.Key === "obligations") {
      // Phase 3: Obligation Master is now a full-page form that captures the
      // master fields, the taxonomy type, that type's typed detail and the
      // evidence links in one save (entity type 'obligation-composite').
      // The old generic dialog could not express the conditional typed-detail
      // section, and the separate "Manage Obligation Type Details" page it
      // used to rely on has been retired.
      const params = new URLSearchParams();
      params.set("mode", mode || "add");
      if (id) params.set("id", id);
      window.location.assign(appUrl(`/Repository/ObligationMaster?${params.toString()}`));
      return;
    }
    if (cmScreen.Key === "sla-master") {
      // SLA Master uses a full-page form (Views/Repository/SlaMasterForm) so
      // the identity / duration / thresholds sections can be laid out with
      // their own cards instead of a flat modal grid.  Matches the
      // ObligationMaster redirect pattern above.
      const params = new URLSearchParams();
      params.set("mode", mode || "add");
      if (id) params.set("id", id);
      window.location.assign(appUrl(`/Repository/SlaMaster?${params.toString()}`));
      return;
    }
    if (cmScreen.Key === "assurance-occurrences") {
      // Event Checklists (Phase B).  "Add" raises an event -- its own page
      // because the subject picker depends on the chosen event type, which
      // the generic dialog cannot express.  "view"/"edit" open the checklist.
      if (mode === "add") { window.location.assign(appUrl("/Repository/RaiseEvent")); return; }
      window.location.assign(appUrl(`/Repository/EventChecklist?id=${encodeURIComponent(id)}`));
      return;
    }
    // The legacy openRequirementObligationForm is left in the source for
    // backward-compat with the deprecated obligation-mapping mode.
    resetFormState();
    // True only while Edit Mode was entered from View Mode — it tells Save and
    // Cancel to come back to View Mode instead of closing the dialog.
    state.formReturnToView = state.pendingModeSwitch === true;
    state.pendingModeSwitch = false;
    state.id = id; state.mode = mode; state.formContext = { ...preset }; message.hidden = true;
    const activeKey = formEntityKey();
    let record = { ...preset };
    if (id) {
      record = apiData(await fetchJson(`${cmApi}/${activeKey}?id=${id}`))[0] || {};
      if (activeKey === "source-structure") {
        state.formContext = {
          releaseId: record.ReleaseId,
          parentNodeId: record.ParentNodeId || ""
        };
      }
    }
    if (!id && activeKey === "framework-statements" && releaseSelect.value && !record.releaseId && !record.ReleaseId) {
      record.releaseId = releaseSelect.value;
    }
    if (!id && activeKey === "statement-classifications" && releaseSelect.value && !record.releaseId && !record.ReleaseId) {
      record.releaseId = releaseSelect.value;
    }
    if (activeKey === "statement-classifications" && record.ClassificationScheme && !record.scheme) {
      record.scheme = record.ClassificationScheme;
    }
    // Source Structure: the Release is only selectable when adding a ROOT node.
    // A child node always belongs to its parent's release, and moving an
    // existing node between releases would orphan its descendants and the
    // Source Statements captured under it, so both are locked read-only.
    if (activeKey === "source-structure" && (id || state.formContext.parentNodeId)) {
      state.formContext.lockedFields = [...(state.formContext.lockedFields || []), "releaseId"];
    }
    const readonly = mode === "view";
    setDialogTitle(dialogTitleFor(mode));
    document.querySelector("#dialogDescription").textContent = readonly ? "Review repository details." : "Complete the required fields and save your changes.";
    applyDialogMode(mode);
    fieldsHost.innerHTML = formSchema(activeKey).map(field => fieldMarkup(field, formValueOf(record, field), readonly)).join("");
    renderSourceNodeContext(record);
    dialog.classList.toggle("compact-statement-dialog", activeKey === "framework-statements");
    // Practice Add / Edit / View is an in-page form, not a pop-up: it carries
    // the Framework Statement mapping tree and needs the room, but the sidebar
    // menu and the top bar have to stay visible and usable.  The class pair
    // below lays the form out inside .content and hides the grid behind it.
    const practiceInline = activeKey === "requirements";
    dialog.classList.toggle("practice-dialog", practiceInline);
    document.body.classList.toggle("practice-form-open", practiceInline);
    fieldsHost.querySelectorAll("[data-checkbox-combo]").forEach(updateCheckboxCombo);
    fieldsHost.querySelectorAll("[data-tag-input]").forEach(updateTagPreview);
    bindEvidenceGrids(fieldsHost);
    updateFrequencyFields();
    saveButton.hidden = readonly; saveButton.textContent = saveTextFor();
    // Re-rendering for a mode switch keeps the dialog open — showModal() throws
    // if it is called on a dialog that is already showing.
    if (!dialog.open) {
      // show() keeps the Practice form out of the top layer so it flows with
      // the page; every other screen stays a modal dialog.
      if (practiceInline) { dialog.show(); window.scrollTo({ top: 0 }); }
      else dialog.showModal();
    }
    try {
      if (activeKey === "control-requirement-mappings") await refreshRequirementMappingCombo(readonly);
      if (activeKey === "controls") await initControlClassificationForm(record, readonly);
      if (activeKey === "requirements") {
        await initRequirementControlMapping(readonly);
        // Similar-records helper: warns about potential duplicate Practices
        // as the user types keywords.  Never blocks Save.
        initSimilarRecords(readonly);
      }
      if (activeKey === "obligations") {
        // Similar-records helper for Obligation Master.
        initSimilarRecords(readonly);
      }
      if (activeKey === "framework-statements") {
        await loadFrameworkStatementSourceTree(document.querySelector("#field-releaseId")?.value || "", record.StructureNodeId || record.structureNodeId || "", readonly);
        await refreshStatementClassificationOptions(record.ClassificationId || record.classificationId || "", readonly);
        initializeStatementReferenceAutoState();
      }
      if (activeKey === "statement-classifications" && (state.navigationContext?.filterType === "Release" || state.formContext.releaseId || state.formContext.ReleaseId)) {
        const releaseField = document.querySelector("#field-releaseId");
        if (releaseField) releaseField.disabled = true;
      }
    } catch (error) {
      message.textContent = error.message;
      message.hidden = false;
    }
  }
  function collect() {
    const data = {}, missing = [];
    const key = formEntityKey();
    for (const field of formSchema(key)) {
      const element = document.querySelector(`#field-${field.name}`);
      if (field.type === "source-tree") element.value = frameworkStatementTreeState.selected || element.value || "";
      if (field.type === "evidence-grid") {
        const rows = collectEvidenceGrid(element);
        data[field.name] = rows;
        continue;
      }
      const value = field.type === "checkbox" ? element.checked : field.type === "tags" ? tagList(element.querySelector("input")?.value || "") : field.type === "multiselect" && field.compact ? Array.from(element.querySelectorAll('input[type="checkbox"]:checked')).map(option => option.value) : field.type === "multiselect" ? Array.from(element.selectedOptions).map(option => option.value).filter(Boolean) : element.value.trim();
      element.classList.remove("field-error");
      if (field.type === "source-tree") document.querySelector("#frameworkStatementSourceTree")?.classList.remove("field-error");
      if (field.required && (value === "" || value === null || Array.isArray(value) && !value.length)) {
        element.classList.add("field-error");
        if (field.type === "source-tree") document.querySelector("#frameworkStatementSourceTree")?.classList.add("field-error");
        missing.push(field.label);
      }
      data[field.name] = field.type === "number" && value !== "" ? Number(value) : value;
    }
    if (key === "source-structure") {
      // The Release now comes from the form field; the form context and the
      // grid filter are only fallbacks for callers that lock the field.
      data.releaseId = data.releaseId || state.formContext.releaseId || releaseSelect.value;
      data.parentNodeId = state.formContext.parentNodeId || "";
      if (state.formContext.contextCode) data.contextCode = state.formContext.contextCode;
    }
    if (["artifacts","releases"].includes(key) && state.formContext.contextCode) data.contextCode = state.formContext.contextCode;
    if (key === "statement-classifications") {
      data.code = data.name;
      data.displayOrder = 0;
    }
    if (!state.id && key === "source-structure" && !data.displayOrder) data.displayOrder = 0;
    if (!state.id && key === "framework-statements" && !data.displayOrder) data.displayOrder = 0;
    if (!state.id && addDefaultStatusEntities.has(key) && !data.status && !data.Status) data.status = "Active";
    if (key === "requirements") {
      syncRequirementStatementSelection();
      data.statementIds = requirementMapState.statements.filter(statement => statement.IsMapped === true || statement.IsMapped === 1 || statement.IsMapped === "1").map(statement => statement.FrameworkStatementId || statement.Id);
    }
    if (key === "controls") data.sourceStructureNodeIds = Array.from(controlSourceMapState.selected || []);
    if (key === "obligations") normalizeFrequencyPayload(data);
    if (missing.length) throw new Error(`Complete the required fields: ${missing.join(", ")}.`);
    return data;
  }
  // ----- Requirement-first Obligation Mapping matrix -------------------
  const obligationMatrixState = { requirementId: "", rows: [] };
  async function openObligationMappingMatrix(mode, id = 0, preset = {}) {
    resetFormState();
    state.id = id;
    state.mode = mode === "view" ? "view" : "obligation-matrix";
    state.formContext = { ...preset, entityKey: "obligation-mappings" };
    obligationMatrixState.requirementId = "";
    obligationMatrixState.rows = [];

    // If editing, derive the Requirement from the picked mapping row.
    if (id) {
      const existing = (await fetchRows("obligation-mappings", { id, status: "" }))[0] || {};
      obligationMatrixState.requirementId = String(existing.RequirementId || existing.requirementId || preset.requirementId || "");
    } else if (preset.requirementId) {
      obligationMatrixState.requirementId = String(preset.requirementId);
    }

    resetDialogChrome();
    setDialogTitle(mode === "view" ? "View Obligation Mapping" : id ? "Edit Obligation Mapping" : "Add Obligation Mapping");
    document.querySelector("#dialogDescription").textContent = "Pick a Requirement, then select the Obligation that applies on each Statement / Release row.";
    saveButton.hidden = mode === "view";
    saveButton.textContent = "Save Mappings";

    renderObligationMatrix();
    if (obligationMatrixState.requirementId) await loadObligationMatrixRows();
    dialog.showModal();
  }

  function renderObligationMatrix() {
    const readonly = state.mode === "view";
    const reqOptions = optionsFor("requirements", obligationMatrixState.requirementId || "");
    // Widen the dialog while the matrix is visible.  Class is removed on close
    // by resetFormState() (see closeForm).
    dialog.classList.add("obligation-matrix-dialog");
    const rowsHtml = obligationMatrixState.rows.length
      ? obligationMatrixState.rows.map((row, index) => obligationMatrixRowHtml(row, index, readonly)).join("")
      : `<tr><td colspan="6" class="empty">${obligationMatrixState.requirementId ? "No mapped Framework Statements found for this Requirement." : "Pick a Requirement to load mapped statement releases."}</td></tr>`;
    fieldsHost.innerHTML = `<div class="obligation-matrix full">
      <div class="form-field full">
        <span class="form-field-label">Requirement<span class="required"> *</span></span>
        <select id="obligation-matrix-requirement"${readonly ? " disabled" : ""}>${reqOptions}</select>
      </div>
      <table class="obligation-matrix-table">
        <colgroup>
          <col class="col-authority">
          <col class="col-artifact">
          <col class="col-release">
          <col class="col-stref">
          <col class="col-sttitle">
          <col class="col-obligation">
        </colgroup>
        <thead><tr>
          <th>Authority</th>
          <th>Artifact / Framework</th>
          <th>Release / Version</th>
          <th>Statement Reference</th>
          <th>Statement Title</th>
          <th>Mapped Obligation</th>
        </tr></thead>
        <tbody id="obligation-matrix-body">${rowsHtml}</tbody>
      </table>
    </div>`;
    const requirementSelect = document.querySelector("#obligation-matrix-requirement");
    if (requirementSelect && !readonly) {
      requirementSelect.addEventListener("change", async () => {
        obligationMatrixState.requirementId = requirementSelect.value;
        obligationMatrixState.rows = [];
        renderObligationMatrix();
        if (obligationMatrixState.requirementId) await loadObligationMatrixRows();
      });
    }
  }

  function obligationMatrixRowHtml(row, index, readonly) {
    const obligationId = row.MappedObligationId || row.mappedObligationId || "";
    const artifactLabel = [row.ArtifactCode, row.Artifact].filter(Boolean).join(" - ");
    const dropdown = `<select data-matrix-row="${index}"${readonly ? " disabled" : ""}>
      <option value="">-- Select Obligation --</option>
      ${optionsFor("obligations", obligationId)}
    </select>`;
    return `<tr>
      <td class="col-authority-cell" title="${escapeHtml(row.Authority || "")}">${escapeHtml(row.Authority || "")}</td>
      <td class="col-artifact-cell"  title="${escapeHtml(artifactLabel)}">${escapeHtml(artifactLabel)}</td>
      <td class="col-release-cell">${escapeHtml(row.Release || "")}</td>
      <td class="col-stref-cell">${escapeHtml(row.StatementReference || "")}</td>
      <td class="col-sttitle-cell" title="${escapeHtml(row.StatementTitle || "")}">${escapeHtml(row.StatementTitle || "")}</td>
      <td class="col-obligation-cell">${dropdown}</td>
    </tr>`;
  }

  async function loadObligationMatrixRows() {
    const requirementId = Number(obligationMatrixState.requirementId);
    if (!requirementId) { obligationMatrixState.rows = []; renderObligationMatrix(); return; }
    try {
      obligationMatrixState.rows = await fetchRows("obligation-mapping-matrix", { requirementId, status: "" });
    } catch (error) {
      obligationMatrixState.rows = [];
      message.textContent = error.message || "Could not load the obligation matrix."; message.hidden = false;
    }
    renderObligationMatrix();
  }

  async function saveObligationMappingMatrix() {
    message.hidden = true;
    const requirementId = Number(obligationMatrixState.requirementId);
    if (!requirementId) { message.textContent = "Requirement is required."; message.hidden = false; return; }
    const selects = Array.from(fieldsHost.querySelectorAll("[data-matrix-row]"));
    const mappings = selects.map(sel => {
      const idx = Number(sel.dataset.matrixRow);
      const row = obligationMatrixState.rows[idx] || {};
      const obligationId = Number(sel.value || 0);
      if (!obligationId) return null;
      return {
        releaseId: Number(row.ReleaseId || row.releaseId || 0),
        frameworkStatementId: Number(row.FrameworkStatementId || row.frameworkStatementId || 0) || null,
        obligationId
      };
    }).filter(Boolean);

    try {
      await fetchJson(`${cmApi}/obligation-mapping-bulk`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ id: null, data: { requirementId, mappings } })
      });
      closeForm();
      await loadLookups();
      await appAlert(mappings.length
        ? "Obligation mappings saved."
        : "All obligation mappings for this Requirement were cleared.", "success", "Saved");
      await load();
    } catch (error) {
      message.textContent = error.message || "Could not save the obligation mappings.";
      message.hidden = false;
    }
  }

  async function save() {
    if (state.mode === "obligation-matrix") { await saveObligationMappingMatrix(); return; }
    if (state.mode === "obligation-mapping") { await saveObligationMappings(); return; }
    try {
      message.hidden = true;
      const key = formEntityKey();
      const data = collect();
      if (key === "controls" && controlSourceMapState.nodes.length && !controlSourceMapState.selected.size) {
        if (!await appConfirm("No source structure nodes are selected. Save this control as unmapped?", { confirmText: "Save Unmapped" })) return;
      }
      const result = await fetchJson(`${cmApi}/${key}`, { method:"POST", headers:{ "Content-Type":"application/json", "X-CSRF-TOKEN":csrfToken }, body:JSON.stringify({ id: state.id || null, data }) });
      const resultRow = apiData(result)[0] || {};
      const resultStatus = String(resultRow.Status || resultRow.status || "").toLowerCase();
      const submittedForApproval = resultStatus === "pending approval";
      const autoApproved = resultStatus === "auto approved";
      // When the workflow auto-approves, the SP returns AppliedRecordId pointing
      // at the newly inserted main-table row.  Use it for any post-save sync
      // (e.g. source-control mappings) that needs the real id.
      const appliedRecordId = resultRow.AppliedRecordId || resultRow.appliedRecordId || 0;
      const savedId = state.id || (autoApproved ? appliedRecordId : 0) || resultRow.Id || result.Id || result.id;
      const afterSaveUrl = state.formContext.afterSaveUrl || "";
      // Edit Mode entered from View Mode returns to View Mode after a
      // successful save instead of closing.
      const returnToView = state.formReturnToView && !afterSaveUrl && savedId;
      const returnContext = { ...state.formContext };
      if (!submittedForApproval && key === "controls" && savedId && controlSourceMapState.nodes.length) await syncControlSourceMappings(savedId);
      closeForm(); await loadLookups();
      if (autoApproved) {
        await appAlert("Change saved and auto-approved.", "success", "Auto Approved");
      } else if (submittedForApproval) {
        await appAlert("Change submitted for approval. The main record will update after checker approval.", "success", "Submitted");
      }
      if (afterSaveUrl) {
        window.location.assign(afterSaveUrl);
        return;
      }
      await load();
      if (returnToView) await openForm("view", savedId, returnContext);
    } catch (error) { message.textContent = error.message; message.hidden = false; }
  }
  async function refreshSubDomainOptions(selected = "") {
    const domainId = document.querySelector("#field-domainId")?.value || "";
    const subDomain = document.querySelector("#field-subDomainId");
    if (!subDomain) return;
    if (!domainId) {
      subDomain.innerHTML = `<option value="">Select Domain first...</option>`;
      subDomain.disabled = true;
      return;
    }
    const items = await fetchRows("control-sub-domains", { domainId, status: "Active" });
    subDomain.disabled = false;
    subDomain.innerHTML = `<option value="">Select...</option>${items.map(item => `<option value="${escapeHtml(item.Id)}"${String(item.Id) === String(selected) ? " selected" : ""}>${escapeHtml(item.Name)}</option>`).join("")}`;
  }
  function controlKeywords() {
    return tagList(document.querySelector("#field-keywords input")?.value || "");
  }
  function similarControlValue(row, key) {
    return row[key] ?? row[key?.[0]?.toUpperCase() + key?.slice(1)] ?? "";
  }
  function similarControlsFiltered() {
    const filters = state.similarFilters || {};
    const rows = [...(state.similarControls || [])].filter(row =>
      ["Code","Name","Domain","SubDomain"].every(key => {
        const filter = String(filters[key] || "").trim().toLowerCase();
        return !filter || String(similarControlValue(row, key) || "").toLowerCase().includes(filter);
      }));
    const sort = state.similarSort || { key: "MatchCount", direction: "desc" };
    rows.sort((a, b) => {
      const left = similarControlValue(a, sort.key);
      const right = similarControlValue(b, sort.key);
      const result = Number.isFinite(Number(left)) && Number.isFinite(Number(right))
        ? Number(left) - Number(right)
        : String(left || "").localeCompare(String(right || ""), undefined, { sensitivity: "base" });
      return sort.direction === "desc" ? -result : result;
    });
    return rows;
  }
  function renderSimilarControlRows() {
    const host = document.querySelector("#similarControls");
    if (!host) return;
    const rows = similarControlsFiltered();
    const total = state.similarControls?.length || 0;
    const count = host.querySelector("[data-similar-count]");
    if (count) count.textContent = `${rows.length} of ${total} record${total === 1 ? "" : "s"}`;
    const body = host.querySelector("[data-similar-body]");
    if (!body) return;
    body.innerHTML = rows.length ? rows.map(row => `<tr>
        <td title="${escapeHtml(row.Code)}"><strong>${escapeHtml(row.Code)}</strong></td>
        <td title="${escapeHtml(row.Name)}">${escapeHtml(row.Name)}</td>
        <td title="${escapeHtml(row.Domain || "No domain")}">${escapeHtml(row.Domain || "No domain")}</td>
        <td title="${escapeHtml(row.SubDomain || "No sub domain")}">${escapeHtml(row.SubDomain || "No sub domain")}</td>
        <td>${badge(row.Status)}</td>
      </tr>`).join("") : `<tr><td colspan="5" class="similar-empty-cell">No records match the current filters.</td></tr>`;
    host.querySelectorAll("[data-similar-sort]").forEach(button => {
      const icon = button.querySelector("i");
      if (!icon) return;
      const key = button.dataset.similarSort;
      icon.className = state.similarSort?.key === key
        ? `fa-solid fa-sort-${state.similarSort.direction === "desc" ? "down" : "up"}`
        : "fa-solid fa-sort";
    });
  }
  function renderSimilarControlsGrid() {
    const host = document.querySelector("#similarControls");
    if (!host) return;
    const total = state.similarControls?.length || 0;
    if (!total) {
      host.innerHTML = `<div class="similar-empty">No similar controls found for the entered keywords.</div>`;
      return;
    }
    const columns = [
      ["Code","Control Code"],
      ["Name","Control Name"],
      ["Domain","Domain"],
      ["SubDomain","Sub Domain"],
      ["Status","Status"]
    ];
    const sortIcon = key => state.similarSort?.key === key ? `<i class="fa-solid fa-sort-${state.similarSort.direction === "desc" ? "down" : "up"}"></i>` : `<i class="fa-solid fa-sort"></i>`;
    host.innerHTML = `<div class="similar-grid-header">
        <div>
          <div class="similar-title">Similar Controls Found</div>
          <div class="similar-count" data-similar-count></div>
        </div>
      </div>
      <div class="similar-grid-wrap">
        <table class="similar-grid">
          <thead>
            <tr>${columns.map(([key, label]) => `<th><button type="button" data-similar-sort="${key}">${escapeHtml(label)} ${sortIcon(key)}</button></th>`).join("")}</tr>
            <tr class="similar-filter-row">${columns.map(([key]) => key === "Status"
              ? `<th></th>`
              : `<th><input type="search" data-similar-filter="${key}" value="${escapeHtml(state.similarFilters?.[key] || "")}" placeholder="Filter..."></th>`).join("")}</tr>
          </thead>
          <tbody data-similar-body></tbody>
        </table>
      </div>`;
    renderSimilarControlRows();
  }
  async function refreshSimilarControls() {
    const host = document.querySelector("#similarControls");
    if (!host) return;
    const keywords = controlKeywords();
    if (!keywords.length) {
      state.similarControls = [];
      host.innerHTML = `<div class="similar-empty">Enter keywords to check for similar existing controls.</div>`;
      return;
    }
    state.similarControls = await fetchRows("control-similar", { search: keywords.join(","), controlId: state.id || "" });
    renderSimilarControlsGrid();
  }
  function scheduleSimilarControlsRefresh() {
    clearTimeout(state.similarTimer);
    state.similarTimer = setTimeout(() => refreshSimilarControls().catch(error => {
      const host = document.querySelector("#similarControls");
      if (host) host.innerHTML = `<div class="similar-empty">${escapeHtml(error.message)}</div>`;
    }), 300);
  }
  // ---------------------------------------------------------------------
  // Generic "Similar records" helper for Obligation Master & Practices.
  //   * Mirrors the visual language of the Control "similar controls" grid
  //     (same CSS classes) so it stays consistent with GracPlusNew style.
  //   * Config-driven: each entity supplies its search endpoint, host id,
  //     column list and empty-state copy.
  //   * The grid is read-only and never blocks Save - it is a warn-only
  //     helper to surface potential duplicates as the user types.
  // ---------------------------------------------------------------------
  const similarConfigs = {
    "obligations": {
      hostId: "similarObligations",
      entity: "obligations-similar",
      title: "Similar Obligations Found",
      emptyPrompt: "Enter keywords to check for similar existing obligations.",
      emptyResult: "No similar records found.",
      warnMessage: "Similar records found. Please review before saving.",
      columns: [
        ["ObligationName",     "Obligation Name"],
        ["ExecutionFrequency", "Execution Frequency"],
        ["AssuranceFrequency", "Assurance Frequency"],
        ["RetentionPeriod",    "Retention Period"],
        ["EvidenceCount",      "Evidence Count"],
        ["Keywords",           "Existing Keywords"],
        ["Status",             "Status"]
      ]
    },
    "requirements": {
      hostId: "similarPractices",
      entity: "requirements-similar",
      title: "Similar Practices Found",
      emptyPrompt: "Enter keywords to check for similar existing practices.",
      emptyResult: "No similar records found.",
      warnMessage: "Similar records found. Please review before saving.",
      columns: [
        ["Code",        "Practice Code"],
        ["Name",        "Practice Name"],
        ["Description", "Description"],
        ["Keywords",    "Existing Keywords"],
        ["Status",      "Status"]
      ]
    }
  };
  function similarRecordValue(row, key) {
    return row?.[key] ?? row?.[key?.[0]?.toUpperCase() + key?.slice(1)] ?? "";
  }
  function similarRecordsKeywords() {
    return tagList(document.querySelector("#field-keywords input")?.value || "");
  }
  // Highlight substrings of `text` that match any of the current keywords.
  // Wraps matches in <mark class="similar-highlight"> after HTML-escaping so
  // arbitrary user input can never inject markup.  Case-insensitive.
  function highlightKeywords(text) {
    const escaped = escapeHtml(text ?? "");
    const keywords = (state.similarKeywords || []).map(k => String(k || "").trim()).filter(Boolean);
    if (!escaped || !keywords.length) return escaped;
    // Escape regex specials in each keyword so ".", "*", etc. match literally.
    const pattern = keywords.map(k => k.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");
    try {
      return escaped.replace(new RegExp(`(${pattern})`, "gi"),
        match => `<mark class="similar-highlight">${match}</mark>`);
    } catch { return escaped; }
  }
  function similarRecordsFiltered(config) {
    // Quick-filter narrows the grid by matching the term against any column
    // in the row.  Kept intentionally simple - a single search box preserves
    // the "compact grid" the spec asks for.
    const quick = String(state.similarQuickFilter || "").trim().toLowerCase();
    const searchableKeys = config.columns.map(([key]) => key);
    const rows = [...(state.similarRecords || [])].filter(row => !quick || searchableKeys.some(key =>
      String(similarRecordValue(row, key) || "").toLowerCase().includes(quick)));
    const sort = state.similarSort || { key: "MatchCount", direction: "desc" };
    rows.sort((a, b) => {
      const left = similarRecordValue(a, sort.key);
      const right = similarRecordValue(b, sort.key);
      const result = Number.isFinite(Number(left)) && Number.isFinite(Number(right))
        ? Number(left) - Number(right)
        : String(left || "").localeCompare(String(right || ""), undefined, { sensitivity: "base" });
      return sort.direction === "desc" ? -result : result;
    });
    return rows;
  }
  function renderSimilarRecordsRows(config) {
    const host = document.querySelector(`#${config.hostId}`);
    if (!host) return;
    const rows = similarRecordsFiltered(config);
    const total = state.similarRecords?.length || 0;
    const count = host.querySelector("[data-similar-count]");
    if (count) count.textContent = `${rows.length} of ${total} record${total === 1 ? "" : "s"}`;
    const body = host.querySelector("[data-similar-body]");
    if (!body) return;
    body.innerHTML = rows.length ? rows.map(row => `<tr>${config.columns.map(([key], columnIndex) => {
        const raw = similarRecordValue(row, key);
        const display = raw === null || raw === undefined || raw === "" ? "-" : String(raw);
        if (key === "Status") return `<td>${badge(display)}</td>`;
        // Highlight matches on every non-status cell so the user immediately
        // spots which existing record shares which term with their input.
        const cell = display === "-" ? "-" : highlightKeywords(display);
        return `<td title="${escapeHtml(display)}">${columnIndex === 0 ? `<strong>${cell}</strong>` : cell}</td>`;
      }).join("")}</tr>`).join("")
      : `<tr><td colspan="${config.columns.length}" class="similar-empty-cell">No records match the current filters.</td></tr>`;
    host.querySelectorAll("[data-similar-sort]").forEach(button => {
      const icon = button.querySelector("i");
      if (!icon) return;
      const key = button.dataset.similarSort;
      icon.className = state.similarSort?.key === key
        ? `fa-solid fa-sort-${state.similarSort.direction === "desc" ? "down" : "up"}`
        : "fa-solid fa-sort";
    });
  }
  function renderSimilarRecordsGrid(config) {
    const host = document.querySelector(`#${config.hostId}`);
    if (!host) return;
    const total = state.similarRecords?.length || 0;
    if (!total) {
      host.innerHTML = `<div class="similar-empty">${escapeHtml(config.emptyResult)}</div>`;
      return;
    }
    const sortIcon = key => state.similarSort?.key === key ? `<i class="fa-solid fa-sort-${state.similarSort.direction === "desc" ? "down" : "up"}"></i>` : `<i class="fa-solid fa-sort"></i>`;
    host.innerHTML = `<div class="similar-grid-header">
        <div>
          <div class="similar-title">${escapeHtml(config.title)}</div>
          <div class="similar-count" data-similar-count></div>
          <div class="similar-warn">${escapeHtml(config.warnMessage)}</div>
        </div>
        <div class="similar-toolbar">
          <input type="search" class="similar-quick-filter" data-similar-quick-filter placeholder="Search similar..." value="${escapeHtml(state.similarQuickFilter || "")}">
        </div>
      </div>
      <div class="similar-grid-wrap">
        <table class="similar-grid">
          <thead>
            <tr>${config.columns.map(([key, label]) => `<th><button type="button" data-similar-sort="${key}">${escapeHtml(label)} ${sortIcon(key)}</button></th>`).join("")}</tr>
          </thead>
          <tbody data-similar-body></tbody>
        </table>
      </div>`;
    renderSimilarRecordsRows(config);
  }
  async function refreshSimilarRecords() {
    const config = similarConfigs[cmScreen.Key];
    if (!config) return;
    const host = document.querySelector(`#${config.hostId}`);
    if (!host) return;
    const keywords = similarRecordsKeywords();
    // Empty keyword textbox -> collapse the section entirely so the form
    // layout looks the same as before the user started typing.
    if (!keywords.length) {
      state.similarRecords = [];
      state.similarKeywords = [];
      host.hidden = true;
      host.innerHTML = "";
      return;
    }
    state.similarKeywords = keywords;
    host.hidden = false;
    state.similarRecords = await fetchRows(config.entity, { search: keywords.join(","), id: state.id || 0 });
    renderSimilarRecordsGrid(config);
  }
  function scheduleSimilarRecordsRefresh() {
    if (!similarConfigs[cmScreen.Key]) return;
    clearTimeout(state.similarRecordsTimer);
    state.similarRecordsTimer = setTimeout(() => refreshSimilarRecords().catch(error => {
      const config = similarConfigs[cmScreen.Key];
      const host = config && document.querySelector(`#${config.hostId}`);
      if (host) host.innerHTML = `<div class="similar-empty">${escapeHtml(error.message)}</div>`;
    }), 300);
  }
  function initSimilarRecords(readonly) {
    const config = similarConfigs[cmScreen.Key];
    if (!config) return;
    // Reset per-open state so the grid does not leak filters between records.
    state.similarRecords = [];
    state.similarFilters = {};
    state.similarQuickFilter = "";
    state.similarSort = { key: "MatchCount", direction: "desc" };
    const container = document.createElement("div");
    container.id = config.hostId;
    // "similar-inline" pins the grid directly below the Keywords field so the
    // duplicate suggestion is visible immediately while the user types instead
    // of being hidden below the rest of the form.
    container.className = "similar-controls similar-inline full";
    // Anchor the grid as the next sibling of the Keywords .form-field so it
    // sits between Keywords and the field that follows (Evidence Details for
    // Obligation Master, Status for Practices).  Falling back to fieldsHost
    // keeps the widget alive if the Keywords field cannot be located.
    const keywordsField = fieldsHost.querySelector('[data-field-name="keywords"]');
    if (keywordsField) keywordsField.insertAdjacentElement("afterend", container);
    else fieldsHost.append(container);
    // Start hidden - refresh reveals it as soon as the first keyword is typed.
    container.hidden = true;
    if (!readonly) scheduleSimilarRecordsRefresh();
    else refreshSimilarRecords().catch(error => {
      container.hidden = false;
      container.innerHTML = `<div class="similar-empty">${escapeHtml(error.message)}</div>`;
    });
  }
  async function addControlDomain() {
    const name = await appPrompt("Enter the new domain name.", { title: "Add Domain", confirmText: "Add" });
    if (!name?.trim()) return;
    const result = await fetchJson(`${cmApi}/control-domains`, {
      method:"POST",
      headers:{ "Content-Type":"application/json", "X-CSRF-TOKEN":csrfToken },
      body:JSON.stringify({ data:{ name:name.trim(), description:"", status:"Active" } })
    });
    await loadLookups();
    const newId = apiData(result)[0]?.Id || result.id || result.Id || "";
    const domain = document.querySelector("#field-domainId");
    domain.innerHTML = optionsFor("control-domains", newId);
    domain.value = String(newId || "");
    await refreshSubDomainOptions();
  }
  async function addControlSubDomain() {
    const domainId = document.querySelector("#field-domainId")?.value || "";
    if (!domainId) { await appAlert("Select a Domain before adding a Sub Domain.", "info"); return; }
    const name = await appPrompt("Enter the new sub domain name.", { title: "Add Sub Domain", confirmText: "Add" });
    if (!name?.trim()) return;
    const result = await fetchJson(`${cmApi}/control-sub-domains`, {
      method:"POST",
      headers:{ "Content-Type":"application/json", "X-CSRF-TOKEN":csrfToken },
      body:JSON.stringify({ data:{ domainId, name:name.trim(), description:"", status:"Active" } })
    });
    await loadLookups();
    const newId = apiData(result)[0]?.Id || result.id || result.Id || "";
    await refreshSubDomainOptions(newId);
  }
  async function initControlClassificationForm(record, readonly) {
    await refreshSubDomainOptions(valueOf(record, "subDomainId"));
    const similar = document.createElement("div");
    similar.id = "similarControls";
    similar.className = "similar-controls full";
    fieldsHost.append(similar);
    await initControlSourceMapping(readonly);
    if (!readonly) scheduleSimilarControlsRefresh();
    else await refreshSimilarControls();
  }
  function sourceNodeRelease(row) {
    return controlSourceMapState.releases.find(release => String(release.Id) === String(row.ReleaseId)) || {};
  }
  function sourceNodeArtifact(row) {
    const release = sourceNodeRelease(row);
    return controlSourceMapState.artifacts.find(artifact => String(artifact.Id) === String(release.ArtifactId)) || {};
  }
  function controlSourceLabel(row) {
    return `${row.Reference || ""}${row.Title ? " - " + row.Title : ""}`.trim();
  }
  function renderControlSourceNodes(records, leaves, depth = 0) {
    const tree = buildTree(records);
    const walk = (items, currentDepth) => items.map(item => {
      const row = item.row, id = String(row.Id), isLeaf = leaves.has(id), hasChildren = item.children.length > 0;
      const collapsed = controlSourceMapState.collapsed.has(`n:${id}`);
      const toggle = hasChildren ? `<button type="button" class="map-tree-toggle" data-control-source-toggle="n:${escapeHtml(id)}"><i class="fa-solid fa-chevron-${collapsed ? "right" : "down"}"></i></button>` : `<span class="map-tree-spacer"></span>`;
      const selector = isLeaf ? `<input type="checkbox" data-control-source-node="${escapeHtml(id)}"${controlSourceMapState.selected.has(id) ? " checked" : ""}${controlSourceMapState.readonly ? " disabled" : ""}>` : `<span class="map-parent-dot" title="Only leaf-level source structure nodes can be mapped."></span>`;
      return `<div class="map-tree-row${hasChildren ? " parent" : ""}" style="--tree-depth:${currentDepth}" data-node-id="${escapeHtml(id)}">${toggle}${selector}<span class="map-node-text" title="${escapeHtml(controlSourceLabel(row))}">${escapeHtml(controlSourceLabel(row))}</span></div>${collapsed ? "" : walk(item.children, currentDepth + 1)}`;
    }).join("");
    return walk(tree, depth);
  }
  function renderControlSourceMappingTree() {
    const host = document.querySelector("#controlSourceTree");
    if (!host) return;
    const search = (document.querySelector("#controlSourceSearch")?.value || "").trim().toLowerCase();
    const leaves = leafIds(controlSourceMapState.nodes);
    const byRelease = new Map();
    for (const node of controlSourceMapState.nodes) {
      const release = sourceNodeRelease(node);
      const artifact = sourceNodeArtifact(node);
      const authority = artifact.Authority || "Repository";
      const artifactLabel = [release.ArtifactCode || artifact.Code, release.Artifact || artifact.Name].filter(Boolean).join(" - ") || node.Artifact || "Artifact";
      const releaseLabel = release.Version || node.Version || "Release";
      const haystack = `${authority} ${artifactLabel} ${releaseLabel} ${node.Reference} ${node.Title}`.toLowerCase();
      if (search && !haystack.includes(search)) continue;
      const authorityGroup = byRelease.get(authority) || byRelease.set(authority, new Map()).get(authority);
      const artifactGroup = authorityGroup.get(artifactLabel) || authorityGroup.set(artifactLabel, new Map()).get(artifactLabel);
      const releaseGroup = artifactGroup.get(String(node.ReleaseId)) || artifactGroup.set(String(node.ReleaseId), { label: releaseLabel, nodes: [] }).get(String(node.ReleaseId));
      releaseGroup.nodes.push(node);
    }
    let html = "";
    byRelease.forEach((artifacts, authority) => {
      const authorityKey = `a:${authority}`, authorityCollapsed = controlSourceMapState.collapsed.has(authorityKey);
      html += `<div class="map-tree-row parent control-source-group" style="--tree-depth:0"><button type="button" class="map-tree-toggle" data-control-source-toggle="${escapeHtml(authorityKey)}"><i class="fa-solid fa-chevron-${authorityCollapsed ? "right" : "down"}"></i></button><span class="map-tree-spacer"></span><span class="map-node-text">${escapeHtml(authority)}</span></div>`;
      if (authorityCollapsed) return;
      artifacts.forEach((releases, artifact) => {
        const artifactKey = `ar:${authority}:${artifact}`, artifactCollapsed = controlSourceMapState.collapsed.has(artifactKey);
        html += `<div class="map-tree-row parent control-source-group" style="--tree-depth:1"><button type="button" class="map-tree-toggle" data-control-source-toggle="${escapeHtml(artifactKey)}"><i class="fa-solid fa-chevron-${artifactCollapsed ? "right" : "down"}"></i></button><span class="map-tree-spacer"></span><span class="map-node-text">${escapeHtml(artifact)}</span></div>`;
        if (artifactCollapsed) return;
        releases.forEach((release, releaseId) => {
          const releaseKey = `r:${releaseId}`, releaseCollapsed = controlSourceMapState.collapsed.has(releaseKey);
          html += `<div class="map-tree-row parent control-source-group" style="--tree-depth:2"><button type="button" class="map-tree-toggle" data-control-source-toggle="${escapeHtml(releaseKey)}"><i class="fa-solid fa-chevron-${releaseCollapsed ? "right" : "down"}"></i></button><span class="map-tree-spacer"></span><span class="map-node-text">${escapeHtml(release.label)}</span></div>`;
          if (!releaseCollapsed) html += renderControlSourceNodes(release.nodes, leaves, 3);
        });
      });
    });
    host.innerHTML = html || `<div class="map-empty">No source structure nodes found.</div>`;
    const count = document.querySelector("#controlSourceSelectedCount");
    if (count) count.textContent = `${controlSourceMapState.selected.size} selected`;
  }
  async function initControlSourceMapping(readonly) {
    controlSourceMapState.readonly = readonly;
    controlSourceMapState.collapsed.clear();
    controlSourceMapState.selected.clear();
    controlSourceMapState.existing.clear();
    const [nodes, releases, artifacts, mapped] = await Promise.all([
      fetchRows("source-structure", { status: "Active" }),
      fetchRows("releases", { status: "Active" }),
      fetchRows("artifacts", { status: "Active" }),
      state.id ? fetchRows("source-control-mappings", { controlId: state.id, status: "Active" }) : []
    ]);
    controlSourceMapState.nodes = nodes;
    controlSourceMapState.releases = releases;
    controlSourceMapState.artifacts = artifacts;
    for (const mapping of mapped) {
      controlSourceMapState.selected.add(String(mapping.StructureNodeId));
      controlSourceMapState.existing.set(String(mapping.StructureNodeId), mapping.Id);
    }
    const section = document.createElement("section");
    section.className = "control-source-map full";
    section.innerHTML = `<div class="requirement-control-head"><div><strong>Source Structure Mapping</strong><small id="controlSourceSelectedCount">0 selected</small></div><input type="search" id="controlSourceSearch" placeholder="Search authority, artifact, release or source node..."></div><div class="control-source-note">Select only leaf-level source structure nodes. Parent nodes are for expand/collapse only.</div><div id="controlSourceTree" class="source-map-tree control-source-tree"></div>`;
    fieldsHost.append(section);
    renderControlSourceMappingTree();
  }
  async function syncControlSourceMappings(controlId) {
    const selected = new Set(controlSourceMapState.selected);
    for (const [nodeId, mappingId] of controlSourceMapState.existing.entries()) {
      if (!selected.has(nodeId)) await fetchJson(`${cmApi}/source-control-mappings/${mappingId}/retire`, { method:"POST", headers:{ "Content-Type":"application/json", "X-CSRF-TOKEN":csrfToken }, body:"{}" });
    }
    for (const nodeId of selected) {
      if (controlSourceMapState.existing.has(nodeId)) continue;
      await fetchJson(`${cmApi}/source-control-mappings`, { method:"POST", headers:{ "Content-Type":"application/json", "X-CSRF-TOKEN":csrfToken }, body:JSON.stringify({ data:{ structureNodeId:nodeId, controlIds:[controlId], status:"Active" } }) });
    }
  }
  function updateRequirementSelectedCount() {
    const count = fieldsHost.querySelectorAll("[data-req-statement]:checked").length;
    const label = document.querySelector("#reqSelectedCount");
    if (label) label.textContent = `${count} selected`;
  }
  function syncRequirementStatementSelection() {
    const selected = new Set(Array.from(fieldsHost.querySelectorAll("[data-req-statement]:checked")).map(input => String(input.value)));
    for (const statement of requirementMapState.statements) statement.IsMapped = selected.has(String(statement.FrameworkStatementId || statement.Id));
  }
  function isMirrorFrameworkStatement(statement, node) {
    const statementReference = statement.StatementReference ?? statement.statementReference;
    const statementTitle = statement.StatementTitle ?? statement.statementTitle ?? statement.Title ?? statement.title ?? statement.Name ?? statement.name;
    const statementText = statement.StatementText ?? statement.statementText ?? statement.Statement ?? statement.statement ?? statement.Description ?? statement.description;
    const sameText = (left, right) => String(left || "").trim().toLowerCase() === String(right || "").trim().toLowerCase();
    return sameText(statementReference, node.Reference)
      && sameText(statementTitle, node.Title)
      && (!String(statementText || "").trim()
        || sameText(statementText, node.Description)
        || sameText(statementText, node.Title));
  }
  function isPlaceholderFrameworkStatement(statement, node) {
    const statementReference = statement.StatementReference ?? statement.statementReference ?? statement.Reference ?? statement.reference;
    const title = String(statement.StatementTitle ?? statement.statementTitle ?? statement.Title ?? statement.title ?? statement.Name ?? statement.name ?? "").trim();
    const text = String(statement.StatementText ?? statement.statementText ?? statement.Statement ?? statement.statement ?? statement.Description ?? statement.description ?? "").trim();
    const sameText = (left, right) => String(left || "").trim().toLowerCase() === String(right || "").trim().toLowerCase();
    if (!title && !text && sameText(statementReference, node.Reference)) return true;
    if (title.toLowerCase() === "framework statement" || text.toLowerCase() === "framework statement") return true;
    const display = String(title || text).trim().toLowerCase();
    if (display !== "framework statement") return false;
    if (!text) return true;
    return sameText(statementReference, node.Reference)
      || sameText(text, node.Title)
      || sameText(text, node.Description);
  }
  function frameworkStatementId(statement) {
    return String(statement?.FrameworkStatementId || statement?.Id || "");
  }
  function statementIsMapped(statement) {
    return statement?.IsMapped === true || statement?.IsMapped === 1 || statement?.IsMapped === "1";
  }
  function sourceStatementBacking(row, statementsByNode, hasChildren) {
    if (row.IsAuthorityGroup || row.IsReleaseGroup || hasChildren) return null;
    const nodeId = String(row.Id);
    const statements = statementsByNode[nodeId] || [];
    if (!statements.length) return null;
    const nodeType = String(row.NodeType || row.nodeType || row.Type || row.type || "").trim().toLowerCase();
    return statements.find(statement => statementIsMapped(statement))
      || statements.find(statement => isMirrorFrameworkStatement(statement, row) || isPlaceholderFrameworkStatement(statement, row))
      || (nodeType.includes("statement") ? statements[0] : null);
  }
  function renderRequirementStatementRow(statement, depth, labelOverride, referenceOverride, extraClass = "") {
    const statementId = frameworkStatementId(statement);
    if (!statementId) return "";
    const checked = statementIsMapped(statement);
    const statementReference = referenceOverride ?? statement.StatementReference ?? statement.statementReference ?? "";
    const statementLabel = labelOverride ?? statement.StatementTitle ?? statement.statementTitle ?? statement.Title ?? statement.title ?? statement.Name ?? statement.name ?? statement.StatementText ?? statement.statementText ?? statement.Statement ?? statement.statement ?? "Framework Statement";
    return `<label class="req-tree-control req-tree-statement${extraClass ? ` ${extraClass}` : ""}" style="--tree-depth:${depth}"><input type="checkbox" value="${escapeHtml(statementId)}" data-req-statement${checked ? " checked" : ""}${requirementMapState.readonly ? " disabled" : ""}><i class="fa-solid fa-file-lines"></i><span><strong>${escapeHtml(statementReference)}</strong>${statementReference ? " - " : ""}${escapeHtml(statementLabel)}</span>${badge(checked ? "Mapped" : "Available")}</label>`;
  }
  function requirementMappingHierarchy(nodes) {
    const records = [];
    const authorityKeys = new Set();
    const releaseKeys = new Set();
    for (const node of nodes) {
      const authorityId = node.AuthorityId || node.authorityId || "unknown";
      const authorityKey = `authority:${authorityId}`;
      if (!authorityKeys.has(authorityKey)) {
        authorityKeys.add(authorityKey);
        records.push({
          Id: authorityKey,
          Reference: "",
          Title: node.Authority || "Authority",
          ParentNodeId: null,
          IsAuthorityGroup: true
        });
      }
      const releaseId = node.ReleaseId || node.releaseId || "unknown";
      const releaseKey = `release:${releaseId}`;
      if (!releaseKeys.has(releaseKey)) {
        releaseKeys.add(releaseKey);
        records.push({
          Id: releaseKey,
          Reference: node.ArtifactCode || "",
          Title: [node.Artifact || "", node.Version || node.Release || ""].filter(Boolean).join(" / "),
          ParentNodeId: authorityKey,
          IsReleaseGroup: true
        });
      }
      records.push({
        ...node,
        ParentNodeId: node.ParentNodeId || releaseKey
      });
    }
    return records;
  }
  function renderRequirementControlTree() {
    const host = document.querySelector("#requirementControlTree");
    if (!host) return;
    const search = document.querySelector("#requirementControlSearch")?.value.trim().toLowerCase() || "";
    const statementsByNode = requirementMapState.statements.reduce((map, statement) => {
      const key = String(statement.StructureNodeId || "");
      (map[key] ||= []).push(statement);
      return map;
    }, {});
    const matchingNodeIds = new Set();
    for (const node of requirementMapState.nodes) {
      const nodeText = `${node.Authority || ""} ${node.Reference || ""} ${node.Title || ""} ${node.ArtifactCode || ""} ${node.Artifact || ""} ${node.Version || node.Release || ""}`.toLowerCase();
      if (!search || nodeText.includes(search)) matchingNodeIds.add(String(node.Id));
    }
    for (const statement of requirementMapState.statements) {
      const statementText = `${statement.Authority || ""} ${statement.StatementReference || ""} ${statement.StatementTitle || ""} ${statement.StatementText || ""} ${statement.ArtifactCode || ""} ${statement.Release || ""}`.toLowerCase();
      if (!search || statementText.includes(search)) matchingNodeIds.add(String(statement.StructureNodeId || ""));
    }
    const visibleNodes = search ? includeAncestors(requirementMapState.nodes, matchingNodeIds) : requirementMapState.nodes;
    const hierarchy = requirementMappingHierarchy(visibleNodes);
    const flat = flattenTree(hierarchy);
    const html = flat.map(({ row, depth, hasChildren }) => {
      const nodeId = String(row.Id);
      const collapsed = requirementMapState.collapsed.has(nodeId);
      // Always render the Source Structure / Release / Authority row as a folder.
      // Framework Statements are rendered as leaf rows underneath so users can see
      // and toggle them individually — do not swap the node for a "backing"
      // statement, and do not hide mirror/placeholder statements: users asked for
      // statements to be visible alongside source structure nodes.
      const toggle = hasChildren ? `<button type="button" class="req-tree-toggle" data-req-toggle="${escapeHtml(nodeId)}"><i class="fa-solid fa-chevron-${collapsed ? "right" : "down"}"></i></button>` : `<span class="tree-toggle-spacer"></span>`;
      const folderIcon = row.IsAuthorityGroup ? "fa-building-columns" : row.IsReleaseGroup ? "fa-tags" : "fa-folder";
      const nodeRow = `<div class="req-tree-source${row.IsAuthorityGroup ? " authority" : row.IsReleaseGroup ? " release" : ""}" style="--tree-depth:${depth}">${toggle}<i class="fa-solid ${folderIcon}"></i><span><strong>${escapeHtml(row.Reference || "")}</strong>${row.Reference ? " - " : ""}${escapeHtml(row.Title || "")}</span></div>`;
      const statementRows = (statementsByNode[nodeId] || [])
        .filter(statement => {
          if (!search) return true;
          return `${statement.StatementReference || ""} ${statement.StatementTitle || ""} ${statement.StatementText || ""} ${statement.ArtifactCode || ""} ${statement.Release || ""}`.toLowerCase().includes(search);
        })
        .map(statement => renderRequirementStatementRow(statement, depth + 1))
        .join("");
      return `${nodeRow}${collapsed ? "" : statementRows}`;
    }).join("");
    host.innerHTML = html || `<div class="similar-empty">No framework statements found.</div>`;
    updateRequirementSelectedCount();
  }
  async function initRequirementControlMapping(readonly) {
    requirementMapState.readonly = readonly;
    requirementMapState.collapsed.clear();
    const [nodes, statements] = await Promise.all([
      fetchRows("source-structure", { status: "" }),
      fetchRows("framework-statement-requirement-mappings", { requirementId: state.id || 0, status: "" })
    ]);
    requirementMapState.nodes = nodes.filter(node => !["inactive", "retired"].includes(String(node.Status || "").toLowerCase()));
    requirementMapState.statements = statements;
    const section = document.createElement("section");
    section.className = "requirement-control-map full";
    section.innerHTML = `<div class="requirement-control-head"><div><strong>Framework Statement Mapping</strong><small id="reqSelectedCount">0 selected</small></div><input type="search" id="requirementControlSearch" placeholder="Search source structure or framework statements..."></div><div class="control-source-note">Release → Source Structure → Framework Statements. Source Structure nodes act as folders; select Framework Statements to map them to this Practice.</div><div id="requirementControlTree" class="requirement-control-tree"></div>`;
    fieldsHost.append(section);
    renderRequirementControlTree();
  }
  async function refreshRequirementMappingCombo(readonly = false) {
    if (cmScreen.Key !== "control-requirement-mappings") return;
    const controlId = document.querySelector("#field-controlId")?.value || "";
    const combo = document.querySelector("#field-requirementIds");
    if (!combo) return;
    if (!controlId) {
      setCheckboxComboOptions(combo, [], [], true);
      combo.querySelector("[data-checkbox-combo-summary]").textContent = "Select a control first";
      return;
    }
    const items = await fetchRows("control-requirement-mappings", { controlId, status: "" });
    const selected = items.filter(item => item.IsMapped === true || item.IsMapped === 1 || item.IsMapped === "1").map(item => item.RequirementId);
    setCheckboxComboOptions(combo, items.map(item => ({ value: item.RequirementId, label: `${item.RequirementCode} - ${item.RequirementName}` })), selected, readonly);
  }
  function compactSelect(name, lookup, selected) {
    return `<select data-obligation-field="${name}">${optionsFor(lookup, selected)}</select>`;
  }
  function obligationChecked(value) {
    return value === true || value === 1 || value === "1" || String(value).toLowerCase() === "true" || String(value).toLowerCase() === "yes";
  }
  function obligationValue(context, name) {
    const pascal = name[0].toUpperCase() + name.slice(1);
    return context[name] ?? context[pascal] ?? "";
  }
  function obligationContextLabel(context) {
    return [context.ArtifactCode || context.Artifact, context.Release, context.SourceTitle].filter(Boolean).join(" / ");
  }
  function obligationEvidenceRows(context) {
    const value = obligationValue(context, "evidenceRequirementsJson");
    if (Array.isArray(value)) return value;
    try { return JSON.parse(value || "[]"); }
    catch { return []; }
  }
  function obligationEvidenceRowHtml(row = {}) {
    return `<tr data-obligation-evidence-row>
      <td>${compactSelect("evidenceTypeId", "evidence-types", row.EvidenceTypeId || row.evidenceTypeId || "")}</td>
      <td>${compactSelect("frequencyId", "frequency-master", row.FrequencyId || row.frequencyId || "")}</td>
      <td><input type="text" data-obligation-field="evidenceRetentionRequirement" value="${escapeHtml(row.RetentionRequirement || row.retentionRequirement || "")}" placeholder="e.g. retain 7 years"></td>
      <td><input type="text" data-obligation-field="evidenceRemarks" value="${escapeHtml(row.Remarks || row.remarks || "")}" placeholder="Notes for this evidence"></td>
      <td><button type="button" class="mini-icon danger" data-obligation-remove-evidence title="Remove evidence requirement"><i class="fa-solid fa-xmark"></i></button></td>
    </tr>`;
  }
  function renderObligationEvidenceGrid(context) {
    const evidence = obligationEvidenceRows(context);
    const rows = evidence.length ? evidence.map(obligationEvidenceRowHtml).join("") : obligationEvidenceRowHtml();
    return `<div class="obligation-evidence-grid">
      <div class="obligation-evidence-head"><strong>Evidence</strong><button type="button" class="btn-small" data-obligation-add-evidence><i class="fa-solid fa-plus"></i> Add Evidence</button></div>
      <table>
        <thead><tr><th>Evidence Type</th><th>Assurance Frequency</th><th>Retention Requirement</th><th>Remarks</th><th>Actions</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>`;
  }
  function obligationQualifierValue(context, name) {
    const pascal = name[0].toUpperCase() + name.slice(1);
    return context[name] ?? context[pascal] ?? "";
  }
  function obligationInput(name, context, placeholder = "", type = "text", readonly = false) {
    const value = obligationQualifierValue(context, name);
    if (type === "textarea") return `<textarea data-obligation-field="${name}" rows="1"${readonly ? " disabled" : ""} placeholder="${escapeHtml(placeholder)}">${escapeHtml(value)}</textarea>`;
    return `<input data-obligation-field="${name}" type="${type}" value="${escapeHtml(value)}"${readonly ? " disabled" : ""} placeholder="${escapeHtml(placeholder)}">`;
  }
  function obligationFrequencySelect(context, readonly = false) {
    const selected = obligationQualifierValue(context, "frequencyType");
    return `<select data-obligation-field="frequencyType"${readonly ? " disabled" : ""}>${optionsFor("frequency-types", selected)}</select>`;
  }
  function obligationCardHtml(context = {}, index = 0, readonly = false) {
    const id = Number(context.Id || context.id || 0);
    return `<section class="obligation-release-card statement-obligation-card" data-obligation-index="${index}" data-obligation-id="${id}">
      <div class="obligation-evidence-head">
        <strong>${escapeHtml(obligationContextLabel(context) || `Release ${index + 1}`)}</strong>
        ${readonly ? "" : `<button type="button" class="mini-icon danger" data-obligation-remove title="Remove obligation"><i class="fa-solid fa-xmark"></i></button>`}
      </div>
      <div class="obligation-qualifier-grid">
        <label><span>Obligation Name</span>${obligationInput("obligationText", context, "e.g. Quarterly Access Review", "text", readonly)}</label>
        <label><span>Execution Frequency</span>${obligationFrequencySelect(context, readonly)}</label>
      </div>
      ${renderObligationEvidenceGrid(context)}
    </section>`;
  }
  function renderObligationMapping() {
    const requirement = obligationState.requirement || {};
    const readonly = state.mode === "view";
    const contexts = obligationState.contexts?.length ? obligationState.contexts : [{}];
    const rowsHtml = contexts.map((context, index) => obligationCardHtml(context, index, readonly)).join("");
    const requirementId = requirement.Id || requirement.id || state.formContext.requirementId || "";
    const selectorDisabled = readonly || state.formContext.lockRequirement ? " disabled" : "";
    fieldsHost.innerHTML = `<div class="obligation-mapping statement-obligation-mapping full">
      <section class="statement-obligation-context">
        <div class="form-field statement-selector" data-field-name="requirementId">
          <span class="form-field-label">Requirement<span class="required"> *</span></span>
          <select id="field-requirementId" name="requirementId"${selectorDisabled}>${optionsFor("requirements", requirementId)}</select>
        </div>
        <div class="requirement-summary-card statement-summary-card">
          <div><span>Code</span><strong>${escapeHtml(requirement.Code || requirement.RequirementCode || "")}</strong></div>
          <div><span>Name</span><strong>${escapeHtml(requirement.Name || requirement.RequirementName || "")}</strong></div>
          <div><span>Status</span>${badge(requirement.Status || "")}</div>
          <p title="${escapeHtml(requirement.Statement || requirement.Objective || "")}">${escapeHtml(requirement.Statement || requirement.Objective || "")}</p>
        </div>
      </section>
      <div class="obligation-evidence-head"><strong>Release Obligations</strong></div>
      <div class="obligation-release-list">${rowsHtml || `<div class="similar-empty">Select a requirement with mapped framework releases.</div>`}</div>
    </div>`;
  }
  async function openRequirementObligationForm(mode, id = 0, preset = {}) {
    resetFormState();
    state.id = id;
    state.mode = "obligation-mapping";
    state.formContext = { ...preset, lockRequirement: false };
    let requirementId = preset.requirementId || preset.RequirementId || "";
    if (id) {
      const record = (await fetchRows("obligations", { id, status: "" }))[0] || {};
      requirementId = record.RequirementId || record.requirementId || requirementId;
    }
    obligationState.requirement = requirementId ? (await fetchRows("requirements", { id: requirementId }))[0] || {} : {};
    obligationState.contexts = requirementId ? await hydrateObligationEvidence(await fetchRows("obligations", { requirementId, status: "" })) : [];
    resetDialogChrome();
    setDialogTitle(mode === "view" ? "View Obligation" : id ? "Edit Obligation" : "Add Obligation");
    document.querySelector("#dialogDescription").textContent = mode === "view" ? "Review obligation details." : "Capture obligation and evidence details for each mapped framework release.";
    saveButton.hidden = mode === "view";
    saveButton.textContent = id ? "Update" : "Save";
    renderObligationMapping();
    dialog.showModal();
  }
  async function openRequirementObligations(id) {
    resetFormState();
    state.id = id;
    state.mode = "obligation-mapping";
    state.formContext = { requirementId: id, lockRequirement: true };
    obligationState.requirement = (await fetchRows("requirements", { id }))[0] || null;
    obligationState.contexts = await hydrateObligationEvidence(await fetchRows("obligations", { requirementId: id, status: "" }));
    resetDialogChrome();
    setDialogTitle("Practice Obligations");
    document.querySelector("#dialogDescription").textContent = "Capture release-specific obligations and evidence expectations for this practice.";
    saveButton.hidden = false;
    saveButton.textContent = "Save Obligations";
    renderObligationMapping();
    dialog.showModal();
  }
  async function hydrateObligationEvidence(contexts) {
    const hydrated = Array.isArray(contexts) ? contexts : [];
    const requirementId = Number(hydrated.find(context => Number(context.RequirementId || context.requirementId || 0))?.RequirementId || hydrated.find(context => Number(context.requirementId || 0))?.requirementId || obligationState.requirement?.Id || obligationState.requirement?.id || state.id || 0);
    let savedEvidence = [];
    if (requirementId > 0) {
      try {
        savedEvidence = await fetchRows("obligation-evidence", { requirementId, status: "" });
      } catch {
        savedEvidence = [];
      }
    }
    const evidenceByContext = new Map();
    savedEvidence.forEach(row => {
      const contextId = String(row.ObligationId || row.obligationId || row.ReleaseId || row.releaseId || "");
      if (!contextId) return;
      if (!evidenceByContext.has(contextId)) evidenceByContext.set(contextId, []);
      evidenceByContext.get(contextId).push(row);
    });
    for (const context of hydrated) {
      const contextId = String(context.Id || context.id || context.ReleaseId || context.releaseId || "");
      const childRows = evidenceByContext.get(contextId);
      if (childRows?.length) {
        context.Id = context.Id || context.id || childRows[0].ObligationId || childRows[0].obligationId || 0;
        context.EvidenceRequirementsJson = JSON.stringify(childRows);
        context.IsMapped = true;
        context.Status = "Active";
        continue;
      }
      const rows = obligationEvidenceRows(context);
      const obligationId = Number(context.Id || context.id || 0);
      if (obligationId > 0 && !rows.length) {
        const saved = (await fetchRows("obligations", { id: obligationId, status: "" }))[0];
        if (saved?.EvidenceRequirementsJson || saved?.evidenceRequirementsJson) {
          context.EvidenceRequirementsJson = saved.EvidenceRequirementsJson || saved.evidenceRequirementsJson;
        }
      }
    }
    return hydrated;
  }
  function collectObligationRow(row, context) {
    const read = name => {
      const element = row.querySelector(`[data-obligation-field="${name}"]`);
      if (!element) return "";
      return element.type === "checkbox" ? element.checked : element.value?.trim() || "";
    };
    const evidenceRequirements = Array.from(row.querySelectorAll("[data-obligation-evidence-row]")).map(evidenceRow => ({
      evidenceTypeId: evidenceRow.querySelector('[data-obligation-field="evidenceTypeId"]')?.value || "",
      frequencyId: evidenceRow.querySelector('[data-obligation-field="frequencyId"]')?.value || "",
      retentionRequirement: evidenceRow.querySelector('[data-obligation-field="evidenceRetentionRequirement"]')?.value?.trim() || "",
      remarks: evidenceRow.querySelector('[data-obligation-field="evidenceRemarks"]')?.value?.trim() || ""
    })).filter(item => item.evidenceTypeId);
    const selectedRequirementId = fieldsHost.querySelector("#field-requirementId")?.value || obligationState.requirement?.Id || state.formContext.requirementId || state.id;
    const data = {
      requirementId: context.RequirementId || selectedRequirementId,
      releaseId: context.ReleaseId,
      obligationText: row.querySelector('[data-obligation-field="obligationText"]')?.value?.trim() || "",
      frequencyType: row.querySelector('[data-obligation-field="frequencyType"]')?.value || "",
      approvalAuthority: row.querySelector('[data-obligation-field="approvalAuthority"]')?.value?.trim() || "",
      responsibility: row.querySelector('[data-obligation-field="responsibility"]')?.value?.trim() || "",
      triggerEvent: row.querySelector('[data-obligation-field="triggerEvent"]')?.value?.trim() || "",
      reportingTarget: row.querySelector('[data-obligation-field="reportingTarget"]')?.value?.trim() || "",
      retentionRequirement: "",
      evidenceRequirement: row.querySelector('[data-obligation-field="evidenceRequirement"]')?.value?.trim() || "",
      isMapped: evidenceRequirements.length > 0,
      // Compatibility for older published API validators. Severity is no longer part of the obligation model.
      severity: "Medium",
      // Compatibility for older published API validators. Status is internal for obligations now.
      status: "Active",
      evidenceRequirements
    };
    return data;
  }
  async function saveObligationMappings() {
    try {
      message.hidden = true;
      const selectedRequirement = fieldsHost.querySelector("#field-requirementId")?.value || "";
      if (!selectedRequirement) { message.textContent = "Requirement is required."; message.hidden = false; return; }
      const rowsToSave = Array.from(fieldsHost.querySelectorAll("[data-obligation-index]"))
        .map(row => ({ row, context: obligationState.contexts[Number(row.dataset.obligationIndex)] || { RequirementId: selectedRequirement } }))
        .map(item => ({ ...item, data: item.context ? collectObligationRow(item.row, item.context) : null }))
        .filter(item => item.context && (
          Number(item.context.Id || item.row.dataset.obligationId || 0) > 0
          || item.data?.evidenceRequirements?.length
          || item.data?.obligationText
          || item.data?.frequencyType
          || item.data?.approvalAuthority
          || item.data?.responsibility
          || item.data?.triggerEvent
          || item.data?.reportingTarget
          || item.data?.retentionRequirement
          || item.data?.evidenceRequirement
        ));
      if (!rowsToSave.length) { message.textContent = "Add at least one obligation before saving."; message.hidden = false; return; }
      for (const item of rowsToSave) {
        const id = Number(item.context.Id || item.row.dataset.obligationId || 0) || null;
        const data = item.data;
        const evidenceTypes = data.evidenceRequirements.map(evidence => String(evidence.evidenceTypeId));
        if (new Set(evidenceTypes).size !== evidenceTypes.length) {
          message.textContent = "Duplicate Evidence Type is not allowed under the same Requirement + Release obligation.";
          message.hidden = false;
          return;
        }
        const saveResult = await fetchJson(`${cmApi}/obligations`, {
          method: "POST",
          headers: { "Content-Type":"application/json", "X-CSRF-TOKEN":csrfToken },
          body: JSON.stringify({ id, data })
        });
        const savedRows = apiData(saveResult);
        const saved = savedRows[0] || {};
        const savedObligationId = Number(saved.ObligationId || saved.obligationId || saved.Id || saved.id || 0);
        const evidenceRowCount = Number(saved.EvidenceRowCount ?? saved.evidenceRowCount ?? -1);
        if (!savedObligationId || evidenceRowCount < data.evidenceRequirements.length) {
          throw new Error("Obligation save did not return the expected saved evidence count. Please confirm the API and 002 SQL procedure are updated and pointing to the same database.");
        }
      }
      state.id = Number(selectedRequirement);
      obligationState.requirement = (await fetchRows("requirements", { id: selectedRequirement }))[0] || obligationState.requirement || {};
      obligationState.contexts = await hydrateObligationEvidence(await fetchRows("obligations", { requirementId: selectedRequirement, status: "" }));
      renderObligationMapping();
      message.textContent = "Obligation saved successfully.";
      message.hidden = false;
    } catch (error) { message.textContent = error.message; message.hidden = false; }
  }
  // Labels for the entity keys the cascade preview reports back.
  const cascadeEntityLabels = {
    "artifacts": ["Regulatory Artifact", "Regulatory Artifacts"],
    "releases": ["Artifact Release", "Artifact Releases"],
    "source-structure": ["Source Structure node", "Source Structure nodes"],
    "statement-classifications": ["Source Classification", "Source Classifications"],
    "framework-statements": ["Source Statement", "Source Statements"],
    "source-control-map": ["Source - Control mapping", "Source - Control mappings"],
    "statement-control-map": ["Statement - Control mapping", "Statement - Control mappings"],
    "statement-requirement-map": ["Statement - Practice mapping", "Statement - Practice mappings"]
  };
  function cascadeLine(row) {
    const key = String(row.EntityType ?? row.entityType ?? "");
    const count = Number(row.RecordCount ?? row.recordCount ?? 0);
    const label = cascadeEntityLabels[key] || [key, key];
    return `${count} ${count === 1 ? label[0] : label[1]}`;
  }
  /* Deactivating a parent takes its whole subtree down with it, so ask the
     server what that subtree contains and put the numbers in front of the user
     before they confirm. A failed preview must not block the action itself. */
  async function cascadeImpact(id) {
    try {
      const result = await fetchJson(`${cmApi}/${cmScreen.Key}/${id}/deactivation-impact`, { method:"POST", headers:{ "Content-Type":"application/json", "X-CSRF-TOKEN":csrfToken }, body:"{}" });
      return apiData(result).filter(row => Number(row.RecordCount ?? row.recordCount ?? 0) > 0);
    } catch { return []; }
  }
  /* Retire and Activate both run through the maker-checker gate, which parks
     the request as a change request instead of changing the record.  Without
     this the grid simply reloads unchanged and it looks like the action did
     nothing — the single most confusing thing about these two buttons. */
  async function reportWorkflowOutcome(result, pendingMessage, approvedMessage) {
    const status = String(apiData(result)[0]?.Status || apiData(result)[0]?.status || "").toLowerCase();
    if (status === "pending approval") await appAlert(pendingMessage, "success", "Submitted for Approval");
    else if (status === "auto approved") await appAlert(approvedMessage, "success", "Auto Approved");
    return status;
  }
  async function retire(id) {
    const label = entityLabel().singular.toLowerCase();
    const impact = await cascadeImpact(id);
    const warning = impact.length
      ? `\n\nThis will also deactivate everything beneath it:\n${impact.map(row => `• ${cascadeLine(row)}`).join("\n")}\n\nActivating this ${label} again will restore them.`
      : "";
    if (!await appConfirm(`Mark this ${label} inactive or retired? Historical data will remain available.${warning}`, {
      confirmText: "Mark Inactive",
      title: impact.length ? "This will deactivate more than one record" : "Please confirm"
    })) return;
    try {
      const result = await fetchJson(`${cmApi}/${cmScreen.Key}/${id}/retire`, { method:"POST", headers:{ "Content-Type":"application/json", "X-CSRF-TOKEN":csrfToken }, body:"{}" });
      await loadLookups(); await load();
      await reportWorkflowOutcome(result,
        `Deactivation submitted for approval. This ${label} stays Active until a checker approves the request in Change Management.`,
        "Deactivation saved and auto-approved.");
    } catch (error) { await appAlert(error.message, "error"); }
  }
  /* Mirror of retire().  On the maker-checker areas the SP raises an 'Activate'
     change request instead of flipping the status, so report that back rather
     than implying the record is already live. */
  async function activate(id) {
    const label = entityLabel().singular.toLowerCase();
    if (!await appConfirm(`Activate this ${label}? Its status will be set back to Active, along with anything its deactivation took down.`, { confirmText: "Activate" })) return;
    try {
      const result = await fetchJson(`${cmApi}/${cmScreen.Key}/${id}/activate`, { method:"POST", headers:{ "Content-Type":"application/json", "X-CSRF-TOKEN":csrfToken }, body:"{}" });
      await loadLookups(); await load();
      await reportWorkflowOutcome(result,
        `Activation submitted for approval. This ${label} stays inactive until a checker approves the request in Change Management.`,
        "Activation saved and auto-approved.");
    } catch (error) { await appAlert(error.message, "error"); }
  }
  async function resetUserPassword(id) {
    const row = state.records.find(item => String(item.Id) === String(id)) || {};
    const label = row.UserName || row.LoginId || `user #${id}`;
    if (!await appConfirm(`Reset password for ${label} to the default? The user will be required to change it on their next sign-in.`, { confirmText: "Reset Password", type: "warning" })) return;
    try {
      const result = await fetchJson(`${cmApi}/user-management/${id}/reset-password`, { method:"POST", headers:{ "Content-Type":"application/json", "X-CSRF-TOKEN":csrfToken }, body:"{}" });
      await appAlert((result && result.message) || `Password for ${label} has been reset to the default.`, "success");
      await load();
    } catch (error) { await appAlert(error.message, "error"); }
  }
  // How many change requests a checker action will actually affect.  Bundled
  // rows (031/032) are approved / rejected as one unit by the database, so
  // the prompt must say so -- the checker is never actioning just the row
  // they clicked.
  function bundleScopeNote(id) {
    if (cmScreen.Key !== "change-management") return "";
    const row = (state.records || []).find(r => String(r.Id) === String(id));
    const count = Number(row?.BundleCount ?? row?.bundleCount ?? 1);
    if (!row?.BundleId || count <= 1) return "";
    return `This change request is part of a linked set of ${count}. `
         + `All ${count} will be actioned together — they cannot be actioned individually.\n\n`;
  }
  async function approve(id) {
    const scope = bundleScopeNote(id);
    const comments = await appPrompt(`${scope}Approval comments are optional.`, { title: scope ? "Approve Linked Changes" : "Approve Change", confirmText: "Approve" });
    if (comments === null) return;
    try {
      await fetchJson(`${cmApi}/${cmScreen.Key}/${id}/approve`, { method:"POST", headers:{ "Content-Type":"application/json", "X-CSRF-TOKEN":csrfToken }, body:JSON.stringify({ comments }) });
      await load();
    } catch (error) { await appAlert(error.message, "error"); }
  }
  async function checkerAction(id, action) {
    const label = action === "reject" ? "Reject" : "Send Back";
    const scope = bundleScopeNote(id);
    const comments = await appPrompt(`${scope}${label} comments are mandatory.`, { title: scope ? `${label} Linked Changes` : label, confirmText: label });
    if (comments === null) return;
    if (!comments.trim()) { await appAlert("Checker comments are mandatory.", "warning"); return; }
    try {
      await fetchJson(`${cmApi}/${cmScreen.Key}/${id}/${action === "send-back" ? "send-back" : "reject"}`, { method:"POST", headers:{ "Content-Type":"application/json", "X-CSRF-TOKEN":csrfToken }, body:JSON.stringify({ comments }) });
      await load();
    } catch (error) { await appAlert(error.message, "error"); }
  }
  /* ------------------------------------------------------- status toggle ---
     A row is either Active or it is not, and the 3-dots menu offers exactly one
     of the two transitions accordingly:  Active -> Inactive,  Inactive ->
     Activate.  Both are gated on the DELETE permission, so whoever may
     deactivate a record may also bring it back. */
  const inactiveStatuses = new Set(["inactive", "retired", "archived"]);
  function rowById(id) {
    return (state.records || []).find(row => String(row.Id ?? row.id) === String(id)) || {};
  }
  function isRowInactive(id) {
    return inactiveStatuses.has(String(rowById(id).Status ?? rowById(id).status ?? "").trim().toLowerCase());
  }
  function statusToggleAction(id) {
    if (!permissions.has("DELETE")) return "";
    return isRowInactive(id)
      ? `<button type="button" class="action-menu-item" data-action="activate" data-id="${id}"><i class="fa-solid fa-rotate-left"></i> Activate</button>`
      : `<button type="button" class="action-menu-item danger" data-action="retire" data-id="${id}"><i class="fa-solid fa-ban"></i> Inactive</button>`;
  }
  function actionMenuItems(id, kind = "") {
    if (cmScreen.Key === "authorities") {
      const label = entityLabel(cmScreen.Key);
      const addArtifactAction = permissions.has("ADD") ? `<button type="button" class="action-menu-item" data-action="add-artifact" data-id="${id}"><i class="fa-solid fa-file-circle-plus"></i> Add Artifact</button>` : "";
      return `<button type="button" class="action-menu-item" data-action="view" data-id="${id}"><i class="fa-solid fa-eye"></i> ${escapeHtml(label.view)}</button>${addArtifactAction}${permissions.has("EDIT") ? `<button type="button" class="action-menu-item" data-action="edit" data-id="${id}"><i class="fa-solid fa-pen"></i> ${escapeHtml(label.edit)}</button>` : ""}${statusToggleAction(id)}`;
    }
    if (cmScreen.Key === "artifacts") {
      const label = entityLabel(cmScreen.Key);
      const addReleaseAction = permissions.has("ADD") ? `<button type="button" class="action-menu-item" data-action="add-release" data-id="${id}"><i class="fa-solid fa-tag"></i> Add Release</button>` : "";
      return `<button type="button" class="action-menu-item" data-action="view" data-id="${id}"><i class="fa-solid fa-eye"></i> ${escapeHtml(label.view)}</button>${addReleaseAction}${permissions.has("EDIT") ? `<button type="button" class="action-menu-item" data-action="edit" data-id="${id}"><i class="fa-solid fa-pen"></i> ${escapeHtml(label.edit)}</button>` : ""}${statusToggleAction(id)}`;
    }
    if (cmScreen.Key === "source-structure") {
      const childAction = permissions.has("ADD") ? `<button type="button" class="action-menu-item" data-action="add-child" data-id="${id}"><i class="fa-solid fa-plus"></i> Add Child Node</button>` : "";
      const statementAction = permissions.has("ADD") ? `<button type="button" class="action-menu-item" data-action="add-statement" data-id="${id}"><i class="fa-solid fa-file-lines"></i> Add Source Statement</button>` : "";
      const editAction = permissions.has("EDIT") ? `<button type="button" class="action-menu-item" data-action="edit" data-id="${id}"><i class="fa-solid fa-pen"></i> Edit Source Node</button>` : "";
      const deleteAction = statusToggleAction(id);
      return `${childAction}${statementAction}<button type="button" class="action-menu-item" data-action="view" data-id="${id}"><i class="fa-solid fa-eye"></i> View Source Node</button>${editAction}${deleteAction}`;
    }
    if (cmScreen.Key === "obligations" && kind === "requirement") {
      return permissions.has("EDIT") ? `<button type="button" class="action-menu-item" data-action="obligations" data-id="${id}"><i class="fa-solid fa-calendar-check"></i> Manage Obligations</button>` : "";
    }
    if (cmScreen.Key === "releases") {
      const sourceStructureAction = permissions.has("ADD") ? `<button type="button" class="action-menu-item" data-action="add-source-structure" data-id="${id}"><i class="fa-solid fa-diagram-project"></i> Add Source Structure</button>` : "";
      const classificationAction = permissions.has("ADD") ? `<button type="button" class="action-menu-item" data-action="add-statement-classification" data-id="${id}"><i class="fa-solid fa-layer-group"></i> Add Source Classification</button>` : "";
      const label = entityLabel(cmScreen.Key);
      return `<button type="button" class="action-menu-item" data-action="view" data-id="${id}"><i class="fa-solid fa-eye"></i> ${escapeHtml(label.view)}</button>${sourceStructureAction}${classificationAction}${permissions.has("EDIT") ? `<button type="button" class="action-menu-item" data-action="edit" data-id="${id}"><i class="fa-solid fa-pen"></i> ${escapeHtml(label.edit)}</button>` : ""}${statusToggleAction(id)}`;
    }
    if (cmScreen.Key === "change-management") {
      const row = state.records.find(item => String(item.Id) === String(id)) || {};
      const pending = String(row.Status || "").toLowerCase() === "pending approval";
      const approve = pending && permissions.has("APPROVE") ? `<button type="button" class="action-menu-item" data-action="approve" data-id="${id}"><i class="fa-solid fa-check"></i> Approve</button>` : "";
      const reject = pending && permissions.has("REJECT") ? `<button type="button" class="action-menu-item danger" data-action="reject" data-id="${id}"><i class="fa-solid fa-xmark"></i> Reject</button><button type="button" class="action-menu-item" data-action="send-back" data-id="${id}"><i class="fa-solid fa-reply"></i> Send Back</button>` : "";
      return `<button type="button" class="action-menu-item" data-action="view" data-id="${id}"><i class="fa-solid fa-eye"></i> View Change</button>${approve}${reject}`;
    }
    const childAction = "";
    // Obligations are maintained on the Obligation Master and the
    // Practices - Obligation Mapping screens; the Practices row menu keeps
    // only Practice actions.
    const obligationAction = "";
    const mapControlsAction = cmScreen.Key === "framework-statements" && permissions.has("EDIT") ? `<button type="button" class="action-menu-item" data-action="map-controls" data-id="${id}"><i class="fa-solid fa-sitemap"></i> Map Controls</button>` : "";
    const approveAction = approvalAreas.has(cmScreen.Key) && permissions.has("APPROVE")
      ? `<button type="button" class="action-menu-item" data-action="approve" data-id="${id}"><i class="fa-solid fa-check"></i> Approve</button>`
      : "";
    const resetPasswordAction = cmScreen.Key === "user-management" && permissions.has("EDIT")
      ? `<button type="button" class="action-menu-item" data-action="reset-password" data-id="${id}"><i class="fa-solid fa-key"></i> Reset Password</button>`
      : "";
    // Assurance Management (Phase 1) lifecycle actions.  Draft -> Review ->
    // Approved -> Published -> Retired.  Buttons are visible only when the
    // current row lifecycle allows the transition AND the user has the
    // matching permission on the area.
    let assuranceActions = "";
    if (typeof cmScreen.Key === "string" && cmScreen.Key.startsWith("assurance-") && cmScreen.Key !== "assurance-version-history") {
      const row = state.records.find(item => String(item.Id) === String(id)) || {};
      const lc = String(row.LifecycleStatus || "").toLowerCase();
      if (lc === "draft" && permissions.has("EDIT"))
        assuranceActions += `<button type="button" class="action-menu-item" data-action="assurance-submit" data-id="${id}"><i class="fa-solid fa-paper-plane"></i> Submit for Review</button>`;
      if (lc === "review" && permissions.has("APPROVE"))
        assuranceActions += `<button type="button" class="action-menu-item" data-action="approve" data-id="${id}"><i class="fa-solid fa-check"></i> Approve</button><button type="button" class="action-menu-item danger" data-action="reject" data-id="${id}"><i class="fa-solid fa-xmark"></i> Reject</button>`;
      if ((lc === "approved" || lc === "published") && permissions.has("APPROVE"))
        assuranceActions += `<button type="button" class="action-menu-item" data-action="assurance-publish" data-id="${id}"><i class="fa-solid fa-upload"></i> ${lc === "published" ? "Publish New Version" : "Publish"}</button>`;
      if (lc === "published" && permissions.has("APPROVE"))
        assuranceActions += `<button type="button" class="action-menu-item danger" data-action="assurance-retire-published" data-id="${id}"><i class="fa-solid fa-box-archive"></i> Retire</button>`;
    }
    const label = entityLabel(cmScreen.Key);
    const editActions = cmScreen.Key === "audit-trace" || cmScreen.Key === "assurance-version-history" ? "" : `${childAction}${obligationAction}${mapControlsAction}${permissions.has("EDIT") ? `<button type="button" class="action-menu-item" data-action="edit" data-id="${id}"><i class="fa-solid fa-pen"></i> ${escapeHtml(label.edit)}</button>` : ""}${resetPasswordAction}${approveAction}${assuranceActions}${statusToggleAction(id)}`;
    return `<button type="button" class="action-menu-item" data-action="view" data-id="${id}"><i class="fa-solid fa-eye"></i> ${escapeHtml(label.view)}</button>${editActions}`;
  }
  async function assuranceLifecycleAction(id, action) {
    // Ask for optional remarks — checker comments / publication notes are
    // captured on the immutable version history row.
    const titles = { "submit": "Submit for Review", "publish": "Publish", "retire-published": "Retire Published" };
    const comments = await appPrompt(`${titles[action] || "Lifecycle Action"} - optional remarks.`, { title: titles[action] || "Lifecycle Action", confirmText: titles[action] || "Continue" });
    if (comments === null) return;
    const endpoint = action === "retire-published" ? "retire-published" : action;
    try {
      await fetchJson(`${cmApi}/${cmScreen.Key}/${id}/${endpoint}`, { method:"POST", headers:{ "Content-Type":"application/json", "X-CSRF-TOKEN":csrfToken }, body:JSON.stringify({ comments }) });
      await load();
    } catch (error) { await appAlert(error.message, "error"); }
  }
  function actionMenu(id, kind = "") {
    return `<div class="row-actions"><button type="button" class="action-menu-trigger" aria-label="Open actions menu" aria-haspopup="true" aria-expanded="false" data-menu-trigger data-id="${id}" data-menu-kind="${escapeHtml(kind)}"><i class="fas fa-ellipsis-v fa-solid fa-ellipsis-vertical" aria-hidden="true"></i></button></div>`;
  }
  function closeMenus() {
    actionPopover?.remove();
    actionPopover = null;
    actionTrigger?.setAttribute("aria-expanded", "false");
    actionTrigger = null;
  }
  function openActionMenu(trigger) {
    const shouldOpen = trigger !== actionTrigger;
    closeMenus();
    if (!shouldOpen) return;
    actionTrigger = trigger;
    actionPopover = document.createElement("div");
    actionPopover.className = "action-menu";
    actionPopover.setAttribute("role", "menu");
    actionPopover.innerHTML = actionMenuItems(trigger.dataset.id, trigger.dataset.menuKind || "");
    document.body.append(actionPopover);
    const triggerRect = trigger.getBoundingClientRect(), menuRect = actionPopover.getBoundingClientRect();
    const top = triggerRect.bottom + menuRect.height + 4 <= window.innerHeight ? triggerRect.bottom + 4 : Math.max(8, triggerRect.top - menuRect.height - 4);
    const left = Math.min(window.innerWidth - menuRect.width - 8, Math.max(8, triggerRect.right - menuRect.width));
    actionPopover.style.top = `${top}px`;
    actionPopover.style.left = `${left}px`;
    trigger.setAttribute("aria-expanded", "true");
  }
  function performAction(button) {
    closeMenus();
    const id = Number(button.dataset.id);
    if (button.dataset.action === "retire") retire(id);
    else if (button.dataset.action === "activate") activate(id);
    else if (button.dataset.action === "reset-password") resetUserPassword(id);
    else if (button.dataset.action === "approve") approve(id);
    else if (button.dataset.action === "reject") checkerAction(id, "reject");
    else if (button.dataset.action === "send-back") checkerAction(id, "send-back");
    else if (button.dataset.action === "assurance-submit") assuranceLifecycleAction(id, "submit");
    else if (button.dataset.action === "assurance-publish") assuranceLifecycleAction(id, "publish");
    else if (button.dataset.action === "assurance-retire-published") assuranceLifecycleAction(id, "retire-published");
    else if (button.dataset.action === "add-child") addChildNode(id);
    else if (button.dataset.action === "add-artifact") openArtifactForAuthority(state.records.find(row => String(row.Id) === String(id)) || { Id: id }).catch(error => alert(error.message));
    else if (button.dataset.action === "add-release") openReleaseForArtifact(state.records.find(row => String(row.Id) === String(id)) || { Id: id }).catch(error => alert(error.message));
    else if (button.dataset.action === "add-source-structure") openSourceStructureForRelease(state.records.find(row => String(row.Id) === String(id)) || { Id: id }).catch(error => alert(error.message));
    else if (button.dataset.action === "add-statement") openStatementFromSourceNode(id).catch(error => alert(error.message));
    else if (button.dataset.action === "obligations") openRequirementObligations(id).catch(error => alert(error.message));
    else if (button.dataset.action === "add-statement-classification") openStatementClassificationForRelease(state.records.find(row => String(row.Id) === String(id)) || { Id: id }).catch(error => alert(error.message));
    else if (button.dataset.action === "statement-classifications") drillDownToStatementClassifications(state.records.find(row => String(row.Id) === String(id)) || {}).catch(error => alert(error.message));
    else if (button.dataset.action === "map-controls") window.location.assign(appUrl("/Repository/Index/source-control-mappings"));
    else if (cmScreen.Key === "framework-statements" && ["add","edit","view"].includes(button.dataset.action)) navigateStatementForm(button.dataset.action, id);
    else if (cmScreen.Key === "obligation-mappings" && button.dataset.action === "view") openObligationDetailsPanel(id);
    else openForm(button.dataset.action, id);
  }
  // ---------- View Obligation Details (shared side panel) ----------
  function findObligationParentRow(id) {
    return (state.records || []).find(row => String(row.Id || row.ObligationId) === String(id)) || null;
  }
  function ensureObligationDetailsPanel() {
    let panel = document.getElementById("obligationDetailsPanel");
    if (panel) return panel;
    panel = document.createElement("div");
    panel.id = "obligationDetailsPanel";
    panel.className = "om-side-panel";
    panel.setAttribute("aria-hidden", "true");
    panel.innerHTML = `
      <div class="om-side-panel-overlay" data-obligation-panel-close></div>
      <div class="om-side-panel-card" role="dialog" aria-modal="true" aria-labelledby="obligationDetailsPanelTitle">
        <div class="om-side-panel-head">
          <h2 id="obligationDetailsPanelTitle">Obligation Details</h2>
          <button type="button" class="om-side-panel-close" data-obligation-panel-close aria-label="Close">x</button>
        </div>
        <div class="om-side-panel-body" id="obligationDetailsPanelBody"></div>
      </div>`;
    document.body.appendChild(panel);
    panel.addEventListener("click", event => {
      if (event.target.closest("[data-obligation-panel-close]")) closeObligationDetailsPanel();
    });
    document.addEventListener("keydown", event => {
      if (event.key === "Escape" && panel.classList.contains("is-open")) closeObligationDetailsPanel();
    });
    return panel;
  }
  function closeObligationDetailsPanel() {
    const panel = document.getElementById("obligationDetailsPanel");
    if (!panel) return;
    panel.classList.remove("is-open");
    panel.setAttribute("aria-hidden", "true");
  }
  function openObligationDetailsPanel(obligationId) {
    const ob = findObligationParentRow(obligationId);
    if (!ob) return;
    const panel = ensureObligationDetailsPanel();
    const body = panel.querySelector("#obligationDetailsPanelBody");
    if (body) body.innerHTML = renderObligationDetailsBody(ob);
    panel.classList.add("is-open");
    panel.setAttribute("aria-hidden", "false");
  }
  function renderObligationDetailsBody(ob) {
    const name = obligationName(ob);
    const exec = ob.ExecutionFrequency || "";
    const assurance = ob.AssuranceFrequency || "";
    const retention = ob.RetentionPeriod || ob.RetentionRequirement || "";
    const remarks = ob.Remarks || "";
    const evidence = parseObligationEvidence(ob);
    const evidenceTypes = ob.EvidenceTypes || "";
    let evidenceTable;
    if (evidence.length) {
      evidenceTable = `<table class="om-side-evidence">
        <thead><tr><th>Evidence Type</th><th>Assurance Frequency</th><th>Retention</th><th>Remarks</th></tr></thead>
        <tbody>${evidence.map(e => `<tr>
          <td>${escapeHtml(e.EvidenceType || "")}</td>
          <td>${escapeHtml(e.Frequency || "")}</td>
          <td>${escapeHtml(e.RetentionRequirement || "")}</td>
          <td>${escapeHtml(e.Remarks || "")}</td>
        </tr>`).join("")}</tbody>
      </table>`;
    } else if (evidenceTypes) {
      // Aggregate fallback when child JSON isn't loaded.
      evidenceTable = `<dl class="om-side-grid"><div class="full"><dt>Evidence Types</dt><dd>${escapeHtml(evidenceTypes)}</dd></div></dl>`;
    } else {
      evidenceTable = `<p class="om-side-panel-empty">No evidence requirements configured.</p>`;
    }
    return `
      <h3 class="om-side-name">${escapeHtml(name)}</h3>
      <dl class="om-side-grid">
        <div><dt>Execution Frequency</dt><dd>${exec ? escapeHtml(exec) : `<span class="muted">Not set</span>`}</dd></div>
        <div><dt>Assurance Frequency</dt><dd>${assurance ? escapeHtml(assurance) : `<span class="muted">Not set</span>`}</dd></div>
        <div><dt>Retention Period</dt><dd>${retention ? escapeHtml(retention) : `<span class="muted">Not set</span>`}</dd></div>
        <div><dt>Status</dt><dd>${badge(ob.Status || "Active")}</dd></div>
        ${remarks ? `<div class="full"><dt>Remarks</dt><dd>${escapeHtml(remarks)}</dd></div>` : ""}
      </dl>
      <h4 class="om-side-section">Evidence Details</h4>
      ${evidenceTable}`;
  }
  async function openArtifactForAuthority(row) {
    if (!row.Id) return;
    const contextCode = await createNavigationCode({
      sourceArea:"authorities",
      targetArea:"artifacts",
      filterType:"Authority",
      filterId:Number(row.Id),
      displayCode:row.Code || "",
      displayName:row.Name || ""
    });
    await openForm("add", 0, {
      entityKey: "artifacts",
      authorityId: row.Id,
      contextCode,
      afterSaveUrl: appUrl(`/Repository/Index/artifacts?code=${encodeURIComponent(contextCode)}`),
      lockedFields: ["authorityId"],
      status: "Active"
    });
  }
  async function openReleaseForArtifact(row) {
    if (!row.Id) return;
    const contextCode = await createNavigationCode({
      sourceArea:"artifacts",
      targetArea:"releases",
      filterType:"Artifact",
      filterId:Number(row.Id),
      parentAuthorityId:Number(row.AuthorityId || authoritySelect.value || 0) || null,
      displayCode:row.Code || "",
      displayName:row.Name || ""
    });
    await openForm("add", 0, {
      entityKey: "releases",
      artifactId: row.Id,
      contextCode,
      afterSaveUrl: appUrl(`/Repository/Index/releases?code=${encodeURIComponent(contextCode)}`),
      lockedFields: ["artifactId"],
      status: "Active"
    });
  }
  async function openSourceStructureForRelease(row) {
    if (!row.Id) return;
    const contextCode = await createNavigationCode({
      sourceArea:"releases",
      targetArea:"source-structure",
      filterType:"Release",
      filterId:Number(row.Id),
      parentAuthorityId:Number(row.AuthorityId || authoritySelect.value || 0) || null,
      parentArtifactId:Number(row.ArtifactId || artifactSelect.value || 0) || null,
      displayCode:row.Version || "",
      displayName:row.ArtifactCode || row.Artifact || ""
    });
    await openForm("add", 0, {
      entityKey: "source-structure",
      releaseId: row.Id,
      parentAuthorityId:Number(row.AuthorityId || authoritySelect.value || 0) || "",
      parentArtifactId:Number(row.ArtifactId || artifactSelect.value || 0) || "",
      authorityLabel: row.Authority || lookupLabel("authorities", row.AuthorityId || authoritySelect.value),
      artifactLabel: [row.ArtifactCode, row.Artifact].filter(Boolean).join(" - ") || lookupLabel("artifacts", row.ArtifactId || artifactSelect.value),
      releaseLabel: row.Version || row.Release || lookupLabel("releases", row.Id),
      contextCode,
      parentNodeId: "",
      afterSaveUrl: appUrl(`/Repository/Index/source-structure?code=${encodeURIComponent(contextCode)}`),
      lockedFields: ["releaseId"],
      status: "Active"
    });
  }
  function artifactAuthorityCode() {
    if (state.navigationContext?.filterType === "Authority") return state.navigationContext.displayCode;
    if (cmScreen.Key !== "artifacts" || !authoritySelect.value) return "";
    return (authoritySelect.selectedOptions[0]?.textContent || "").split(" - ", 1)[0];
  }
  function updateArtifactContext() {
    if (cmScreen.Key !== "artifacts") return;
    const authorityCode = artifactAuthorityCode();
    pageTitle.textContent = authorityCode ? `Regulatory Artifacts under ${authorityCode}` : cmScreen.Title;
  }
  async function drillDownToArtifacts(row) {
    if (!row.Id) return;
    const code = await createNavigationCode({ sourceArea:"authorities", targetArea:"artifacts", filterType:"Authority", filterId:Number(row.Id), displayCode:row.Code || "", displayName:row.Name || "" });
    window.location.assign(appUrl(`/Repository/Index/artifacts?code=${encodeURIComponent(code)}`));
  }
  function synchronizeArtifactFilterUrl() {
    if (cmScreen.Key !== "artifacts") return;
    state.navigationCode = ""; state.navigationContext = null;
    window.history.replaceState({}, "", appUrl("/Repository/Index/artifacts"));
  }
  function releaseArtifactCode() {
    if (state.navigationContext?.filterType === "Artifact") return state.navigationContext.displayCode;
    if (cmScreen.Key !== "releases" || !artifactSelect.value) return "";
    return (artifactSelect.selectedOptions[0]?.textContent || "").split(" - ", 1)[0];
  }
  function updateReleaseContext() {
    if (cmScreen.Key !== "releases") return;
    const artifactCode = releaseArtifactCode();
    pageTitle.textContent = artifactCode ? `Releases under ${artifactCode}` : cmScreen.Title;
  }
  async function drillDownToReleases(row) {
    if (!row.Id) return;
    const code = await createNavigationCode({ sourceArea:"artifacts", targetArea:"releases", filterType:"Artifact", filterId:Number(row.Id), parentAuthorityId:Number(row.AuthorityId || authoritySelect.value || 0) || null, displayCode:row.Code || "", displayName:row.Name || "" });
    window.location.assign(appUrl(`/Repository/Index/releases?code=${encodeURIComponent(code)}`));
  }
  function synchronizeReleaseFilterUrl() {
    if (cmScreen.Key !== "releases") return;
    state.navigationCode = ""; state.navigationContext = null;
    window.history.replaceState({}, "", appUrl("/Repository/Index/releases"));
  }
  function updateSourceStructureContext() {
    if (!["source-structure","statement-classifications"].includes(cmScreen.Key)) return;
    const releaseLabel = releaseLabelFromSelect();
    pageTitle.textContent = releaseLabel ? `${cmScreen.Title} under ${releaseLabel}` : cmScreen.Title;
    backButton.hidden = !releaseSelect.value;
    refreshAddButtonLabel();
  }
  async function drillDownToSourceStructure(row) {
    if (!row.Id) return;
    const code = await createNavigationCode({ sourceArea:"releases", targetArea:"source-structure", filterType:"Release", filterId:Number(row.Id), parentAuthorityId:Number(row.AuthorityId || authoritySelect.value || 0) || null, parentArtifactId:Number(row.ArtifactId || artifactSelect.value || 0) || null, displayCode:row.Version || "", displayName:row.ArtifactCode || row.Artifact || "" });
    window.location.assign(appUrl(`/Repository/Index/source-structure?code=${encodeURIComponent(code)}`));
  }
  async function drillDownToStatementClassifications(row) {
    if (!row.Id) return;
    const code = await createNavigationCode({ sourceArea:"releases", targetArea:"statement-classifications", filterType:"Release", filterId:Number(row.Id), parentAuthorityId:Number(row.AuthorityId || authoritySelect.value || 0) || null, parentArtifactId:Number(row.ArtifactId || artifactSelect.value || 0) || null, displayCode:row.Version || "", displayName:row.ArtifactCode || row.Artifact || "" });
    window.location.assign(appUrl(`/Repository/Index/statement-classifications?code=${encodeURIComponent(code)}`));
  }
  async function openStatementClassificationForRelease(row) {
    if (!row.Id) return;
    await openForm("add", 0, {
      entityKey: "statement-classifications",
      releaseId: row.Id,
      ReleaseId: row.Id,
      status: "Active"
    });
  }
  function synchronizeSourceStructureFilterUrl() {
    if (!["source-structure","statement-classifications"].includes(cmScreen.Key)) return;
    state.navigationCode = ""; state.navigationContext = null;
    window.history.replaceState({}, "", appUrl(`/Repository/Index/${cmScreen.Key}`));
  }
  function addRootNode() {
    // The Release is chosen on the form.  Whatever the grid is filtered to --
    // the filter dropdown or a drill-down from Releases -- is pre-selected as
    // a convenience, but no filter is required to open the form.
    // contextCode is deliberately not sent: the gateway would overwrite
    // releaseId with the context's release and silently ignore the user's
    // choice (see ApplyNavigationContext).
    const contextReleaseId = state.navigationContext?.filterType === "Release"
      ? String(state.navigationContext.filterId || "")
      : "";
    const releaseId = releaseSelect.value || contextReleaseId || "";
    openForm("add", 0, { releaseId, parentNodeId: "", status: "Active" });
  }
  function addChildNode(id) {
    const parent = state.records.find(row => Number(row.Id) === id);
    if (!parent) return;
    openForm("add-child", 0, {
      releaseId: parent.ReleaseId,
      parentNodeId: parent.Id,
      displayOrder: 0,
      status: "Active"
    });
  }
  function nextStatementReference(baseReference, statements) {
    const base = String(baseReference || "").trim();
    if (!base) return "";
    const used = new Set(statements.map(statement => String(statement.StatementReference || statement.statementReference || "").trim().toLowerCase()).filter(Boolean));
    if (!used.has(base.toLowerCase())) return base;
    for (let index = 1; index < 1000; index++) {
      const candidate = `${base}.${index}`;
      if (!used.has(candidate.toLowerCase())) return candidate;
    }
    return "";
  }
  function navigateStatementForm(mode = "add", id = 0) {
    const params = new URLSearchParams({ mode });
    if (id) params.set("id", id);
    if (!id && releaseSelect.value) params.set("releaseId", releaseSelect.value);
    window.location.assign(appUrl(`/Repository/Statement?${params}`));
  }
  async function openStatementFromSourceNode(id) {
    const node = state.records.find(row => Number(row.Id) === id);
    if (!node) throw new Error("Source Structure Node was not found.");
    window.location.assign(appUrl(`/Repository/Statement?mode=add&releaseId=${encodeURIComponent(node.ReleaseId || "")}&nodeId=${encodeURIComponent(node.Id || "")}`));
  }
  function renderSourceStructureRows() {
    const flattened = flattenTree(pageTreeRoots(state.records));
    if (!flattened.length) return `<tr><td colspan="${cmScreen.Columns.length + 1}" class="empty">No records found</td></tr>`;
    return flattened.map(({ row, depth, hasChildren }) => {
      const nodeId = String(row.Id), collapsed = state.collapsed.has(nodeId);
      const toggle = hasChildren ? `<button type="button" class="tree-toggle" data-tree-toggle="${escapeHtml(nodeId)}" aria-label="${collapsed ? "Expand" : "Collapse"} ${escapeHtml(row.Reference)}"><i class="fa-solid fa-chevron-${collapsed ? "right" : "down"}"></i></button>` : `<span class="tree-toggle-spacer"></span>`;
      return `<tr class="tree-row${hasChildren ? " tree-parent-row" : ""}" data-tree-node-id="${escapeHtml(nodeId)}" data-tree-depth="${depth}">
        <td><span class="tree-node" style="--tree-depth:${depth}">${toggle}<span class="tree-reference">${escapeHtml(row.Reference)}</span></span></td>
        <td><span class="tree-title" title="${escapeHtml(row.Title || "")}">${escapeHtml(row.Title || "")}</span></td>
        <td><span class="tree-description" title="${escapeHtml(row.Description || "")}">${escapeHtml(row.Description || "")}</span></td>
        <td>${badge(row.Status)}</td>
        <td>${actionMenu(row.Id)}</td>
      </tr>`;
    }).join("");
  }
  function renderFrameworkStatementRows() {
    const nodes = state.frameworkStatementNodes || [];
    const statements = state.records || [];
    // Both early returns clear the total: the pager is refreshed from
    // state.gridTotal straight after this render, and a stale count from the
    // previous filter would leave it advertising pages that no longer exist.
    if (!nodes.length) {
      state.gridTotal = 0;
      return `<tr><td colspan="${cmScreen.Columns.length + 1}" class="empty">No source structure configured for the selected filters.</td></tr>`;
    }
    const statementsByNode = statements.reduce((map, statement) => {
      const key = String(statement.StructureNodeId || statement.structureNodeId || "");
      (map[key] ||= []).push(statement);
      return map;
    }, {});
    Object.values(statementsByNode).forEach(items => items.sort((a, b) =>
      Number(a.DisplayOrder || 0) - Number(b.DisplayOrder || 0)
      || String(a.StatementReference || "").localeCompare(String(b.StatementReference || ""))));
    const sameText = (left, right) => String(left || "").trim().toLowerCase() === String(right || "").trim().toLowerCase();
    const isMirrorStatement = (statement, node) =>
      sameText(statement.StatementReference, node.Reference)
      && sameText(statement.StatementTitle, node.Title)
      && (!String(statement.StatementText || "").trim()
        || sameText(statement.StatementText, node.Description)
        || sameText(statement.StatementText, node.Title));
    const statementRowMarkup = (statement, depth) => `<tr class="tree-row framework-statement-row" data-statement-id="${escapeHtml(statement.Id)}" data-tree-depth="${depth}">
        <td><span class="tree-node statement-node" style="--tree-depth:${depth}"><span class="tree-toggle-spacer"></span><span class="tree-reference">${escapeHtml(statement.StatementReference || "")}</span></span></td>
        <td><span class="tree-title" title="${escapeHtml(statement.StatementText || statement.StatementTitle || "")}">${escapeHtml(statement.StatementTitle || "")}</span></td>
        <td>${escapeHtml(statement.Classification || "")}</td>
        <td>${badge(statement.Status || "")}</td>
        <td>${actionMenu(statement.Id)}</td>
      </tr>`;
    const search = document.querySelector("#search")?.value.trim().toLowerCase() || "";
    const matchedNodeIds = new Set();
    if (search) {
      statements.forEach(statement => {
        const text = `${statement.StatementReference || ""} ${statement.StatementTitle || ""} ${statement.StatementText || ""} ${statement.SourceReference || ""} ${statement.SourceNode || ""}`.toLowerCase();
        if (text.includes(search)) matchedNodeIds.add(String(statement.StructureNodeId || ""));
      });
    }
    if (search && !matchedNodeIds.size) {
      state.gridTotal = 0;
      return `<tr><td colspan="${cmScreen.Columns.length + 1}" class="empty">No Source Statements found.</td></tr>`;
    }
    const flattened = flattenTree(search ? includeAncestors(nodes, matchedNodeIds) : nodes);
    // This grid is paged by STATEMENT, not by structure node.  The statements
    // are the records the user counts, so they are what the pager reports and
    // slices; node rows are headers that travel with whichever statements land
    // on the current page, so a statement is never shown without the branch it
    // belongs to.  Source Structure, whose rows really are nodes, still pages
    // by root -- see renderSourceStructureRows() / pageTreeRoots().
    //
    // Paging by node root here reported the root count (a handful) as the
    // record count while rendering every statement underneath, which left the
    // pager stuck on a single page reading "1-3 of 3" over ~93 visible rows.
    const plan = flattened.map(({ row, depth, hasChildren }) => {
      const nodeId = String(row.Id), collapsed = state.collapsed.has(nodeId);
      const nodeStatements = statementsByNode[nodeId] || [];
      // A "mirror" statement just repeats the node's own reference/title, so it is
      // filtered out at every level -- the node row already shows that text.  This
      // used to be applied only to parent nodes, which meant a leaf node carrying
      // real statements lost its own row (see the leaf branch below).
      const visibleStatements = nodeStatements.filter(statement => !isMirrorStatement(statement, row));
      // Leaf node whose only statements mirror the node itself: the statement rows
      // stand in for the node row, otherwise the same text would render twice and
      // the mirrored record would have no action menu.
      const mirrorLeaf = !hasChildren && !visibleStatements.length && nodeStatements.length > 0;
      // A collapsed node contributes nothing to the page, so the count matches
      // what is actually on screen.
      const pageable = mirrorLeaf ? nodeStatements : (collapsed ? [] : visibleStatements);
      return { row, depth, hasChildren, nodeId, collapsed, mirrorLeaf, pageable };
    });
    const pageableStatements = plan.flatMap(entry => entry.pageable);
    state.gridTotal = pageableStatements.length;
    const pageSize = Math.max(1, state.gridPageSize);
    const lastStatementPage = Math.max(1, Math.ceil(pageableStatements.length / pageSize));
    if (state.gridPage > lastStatementPage) state.gridPage = lastStatementPage;
    const onPageIds = new Set(pageableStatements
      .slice(gridPageStart(), gridPageStart() + pageSize)
      .map(statement => String(statement.Id)));
    // Keep the nodes hosting this page's statements, plus their ancestors, so
    // the branch still reads top-down instead of starting mid-tree.
    const parentOf = new Map(nodes.map(item => [String(item.Id), String(item.ParentNodeId || "")]));
    const keepNodes = new Set();
    plan.forEach(entry => {
      if (!entry.pageable.some(statement => onPageIds.has(String(statement.Id)))) return;
      let current = entry.nodeId;
      while (current && !keepNodes.has(current)) { keepNodes.add(current); current = parentOf.get(current) || ""; }
    });
    // Structure but no statements yet: keep showing the tree, so the screen
    // still tells the user where statements would go.
    const structureOnly = pageableStatements.length === 0;
    const sourceRows = plan.map(entry => {
      const { row, depth, hasChildren, nodeId, collapsed, mirrorLeaf } = entry;
      if (!structureOnly && !keepNodes.has(nodeId)) return "";
      const statementsOnPage = entry.pageable.filter(statement => onPageIds.has(String(statement.Id)));
      if (mirrorLeaf) return statementsOnPage.map(statement => statementRowMarkup(statement, depth)).join("");
      const toggle = hasChildren ? `<button type="button" class="tree-toggle" data-tree-toggle="${escapeHtml(nodeId)}" aria-label="${collapsed ? "Expand" : "Collapse"} ${escapeHtml(row.Reference)}"><i class="fa-solid fa-chevron-${collapsed ? "right" : "down"}"></i></button>` : `<span class="tree-toggle-spacer"></span>`;
      // The node itself is context, not an editable row here — but its status
      // has to be visible, or a deactivated branch looks identical to a live one.
      const nodeInactive = inactiveStatuses.has(String(row.Status || "").trim().toLowerCase());
      const nodeRow = `<tr class="tree-row framework-node-row${hasChildren ? " tree-parent-row" : ""}${nodeInactive ? " tree-row-inactive" : ""}" data-tree-node-id="${escapeHtml(nodeId)}" data-tree-depth="${depth}">
        <td><span class="tree-node" style="--tree-depth:${depth}">${toggle}<span class="tree-reference">${escapeHtml(row.Reference)}</span></span></td>
        <td colspan="3"><span class="tree-title" title="${escapeHtml(row.Title || "")}">${escapeHtml(row.Title || "")}</span></td>
        <td>${nodeInactive ? badge(row.Status) : ""}</td>
      </tr>`;
      return `${nodeRow}${statementsOnPage.map(statement => statementRowMarkup(statement, depth + 1)).join("")}`;
    }).join("");
    return sourceRows || `<tr><td colspan="${cmScreen.Columns.length + 1}" class="empty">No Source Statements found.</td></tr>`;
  }
  function parseEvidenceRows(row) {
    try {
      const parsed = JSON.parse(row.EvidenceRequirementsJson || row.evidenceRequirementsJson || "[]");
      return Array.isArray(parsed) ? parsed : [];
    } catch {
      return [];
    }
  }
  function obligationName(row) {
    return row.ObligationName
      || row.obligationName
      || row.ObligationText
      || row.obligationText
      || row.EvidenceRequirement
      || row.evidenceRequirement
      || [row.RequirementCode, row.RequirementName].filter(Boolean).join(" - ")
      || "Requirement Obligation";
  }
  function obligationFrequency(row) {
    return row.ExecutionFrequency || row.executionFrequency || row.FrequencyType || row.frequencyType || "";
  }
  function obligationEvidenceCount(row, evidence) {
    const count = Number(row.EvidenceCount ?? row.evidenceCount ?? evidence.length ?? 0);
    return Number.isFinite(count) ? count : evidence.length;
  }
  function renderObligationRows() {
    const obligations = state.records || [];
    const colCount = cmScreen.Columns.length + 1;   // +1 for the Actions column
    if (!obligations.length) return `<tr><td colspan="${colCount}" class="empty">No Practice Obligations found.</td></tr>`;
    // Mapping children start collapsed.  The pager counts obligations, so with
    // every obligation expanded a page of 10 could put fifty-odd rows on screen
    // and the row count stopped matching the "of N records" label.  Collapsed by
    // default, a page shows exactly the obligations it says it does.
    //
    // Seeding is per obligation id and remembered, so this only applies the
    // default once: an obligation the user has expanded stays expanded across
    // re-renders and reloads, while obligations arriving from a new filter are
    // still collapsed when they first appear.
    obligations.forEach(ob => {
      const id = String(ob.Id || ob.ObligationId || "");
      if (!id || obligationCollapseSeeded.has(id)) return;
      obligationCollapseSeeded.add(id);
      state.collapsed.add(`obligation-${id}`);
    });
    // Parent rows are sorted alphabetically by Obligation Name.
    const sorted = pageRows([...obligations].sort((a, b) =>
      String(obligationName(a)).localeCompare(String(obligationName(b)))));
    return sorted.map(ob => {
      const id = String(ob.Id || ob.ObligationId || "");
      const toggleKey = `obligation-${id}`;
      const collapsed = state.collapsed.has(toggleKey);
      const mappings = parseObligationMappings(ob);
      const evidenceCount = Number(ob.EvidenceCount ?? ob.evidenceCount ?? 0);
      const mappingCount  = Number(ob.MappingCount  ?? ob.mappingCount  ?? mappings.length);
      const parent = `<tr class="tree-row tree-parent-row obligation-parent-row" data-obligation-id="${escapeHtml(id)}" data-tree-depth="0">
        <td><span class="tree-node" style="--tree-depth:0">
          <button type="button" class="tree-toggle" data-tree-toggle="${escapeHtml(toggleKey)}" aria-label="${collapsed ? "Expand" : "Collapse"} mappings">
            <i class="fa-solid fa-chevron-${collapsed ? "right" : "down"}"></i>
          </button>
          <span class="tree-reference">${escapeHtml(obligationName(ob))}</span>
        </span></td>
        <td>${evidenceCount}</td>
        <td>${mappingCount}</td>
        <td>${badge(ob.Status || "Active")}</td>
        <td>${actionMenu(id)}</td>
      </tr>`;
      if (collapsed) return parent;
      // Child rows reuse the parent's columns for entirely different values --
      // a Practice sits under "Obligation Name", and the release context plus
      // its source statement occupy the two count columns.  One grid header
      // cannot describe both shapes, so the child block carries its own rather
      // than leaving the reader to match values against labels that never
      // applied to them.  Rendered only when there is at least one mapping.
      //
      // Authority / Artifact / Release used to have a column each, back when
      // the parent row had seven columns to lend.  With four they share one
      // cell above the statement: they are the address of the statement, not
      // four independent facts, so stacking them reads better than three
      // cramped columns would.
      const childHeader = mappings.length ? `<tr class="obligation-child-header-row">
        <td><span class="tree-node" style="--tree-depth:1"><span class="tree-toggle-spacer"></span>Practice</span></td>
        <td colspan="2">Release / Source Statement</td>
        <td>Status</td>
        <td></td>
      </tr>` : "";
      let childRows;
      if (mappings.length === 0) {
        childRows = `<tr class="tree-row obligation-mapping-row" data-obligation-id="${escapeHtml(id)}" data-tree-depth="1">
          <td><span class="tree-node" style="--tree-depth:1"><span class="tree-toggle-spacer"></span><span class="tree-reference muted">No Practice / Release mappings yet.</span></span></td>
          <td colspan="${colCount - 1}"></td>
        </tr>`;
      } else {
        // The Source Statement is what separates two mappings that share the
        // same Practice, Artifact and Release.  Migration 021 replaced the old
        // UNIQUE(obligation, requirement, release) with
        // UNIQUE(requirement, release, framework_statement, obligation), so the
        // same practice/release pair may legitimately appear once per statement.
        // Without it those rows look like duplicated data, which is why it
        // stays on screen even though the grid is now four columns wide.
        childRows = mappings.map(m => {
          const statement = [m.StatementReference, m.StatementTitle].filter(Boolean).join(" - ");
          // Authority / Artifact / Release, in narrowing order, as one line.
          const source = [
            m.Authority,
            [m.ArtifactCode, m.Artifact].filter(Boolean).join(" - "),
            m.ReleaseLabel || m.Release
          ].filter(Boolean).join("  /  ");
          return `<tr class="tree-row obligation-mapping-row" data-obligation-id="${escapeHtml(id)}" data-tree-depth="1">
          <td><span class="tree-node" style="--tree-depth:1">
            <span class="tree-toggle-spacer"></span>
            <i class="fa-solid fa-link" aria-hidden="true"></i>
            <span class="tree-reference">${escapeHtml(m.Practice || [m.RequirementCode, m.RequirementName].filter(Boolean).join(" - "))}</span>
          </span></td>
          <td colspan="2">
            <span class="obligation-child-source" title="${escapeHtml(source)}">${escapeHtml(source)}</span>
            ${statement
              ? `<span class="tree-title" title="${escapeHtml(statement)}">${escapeHtml(statement)}</span>`
              : `<span class="muted">No source statement</span>`}
          </td>
          <td>${badge(m.Status || "Active")}</td>
          <td></td>
        </tr>`;
        }).join("");
      }
      return parent + childHeader + childRows;
    }).join("");
  }
  function parseObligationMappings(obligation) {
    if (!obligation) return [];
    const raw = obligation.MappingsJson ?? obligation.mappingsJson;
    if (Array.isArray(raw)) return raw;
    if (!raw) return [];
    try { const parsed = JSON.parse(raw); return Array.isArray(parsed) ? parsed : []; } catch { return []; }
  }
  function parseObligationEvidence(obligation) {
    if (!obligation) return [];
    const raw = obligation.EvidenceRequirementsJson ?? obligation.evidenceRequirementsJson ?? obligation.EvidenceJson;
    if (Array.isArray(raw)) return raw;
    if (!raw) return [];
    try { const parsed = JSON.parse(raw); return Array.isArray(parsed) ? parsed : []; } catch { return []; }
  }
  // ----- Practice-Obligation Mapping list (tree-grid grouped by Obligation) -----
  // Parent = one Obligation (from Obligation Master).  Child rows are the
  // Practice / Release contexts the obligation is mapped to.  Obligations with
  // zero mappings still appear with MappingCount = 0 and a single "no mappings"
  // child row so the user can see the master obligation exists.
  function renderObligationMappingsRows() {
    const obligations = state.records || [];
    const colCount = cmScreen.Columns.length + 1;
    if (!obligations.length) return `<tr><td colspan="${colCount}" class="empty">No Obligations found.</td></tr>`;
    const sorted = pageRows([...obligations].sort((a, b) =>
      String(obligationName(a)).localeCompare(String(obligationName(b)))));
    return sorted.map(ob => {
      const id = String(ob.Id || ob.ObligationId || "");
      const toggleKey = `obligation-mapping-${id}`;
      const collapsed = state.collapsed.has(toggleKey);
      const mappings = parseObligationMappings(ob);
      const evidenceCount = Number(ob.EvidenceCount ?? ob.evidenceCount ?? 0);
      const mappingCount  = Number(ob.MappingCount  ?? ob.mappingCount  ?? mappings.length);
      const parent = `<tr class="tree-row tree-parent-row obligation-parent-row" data-obligation-id="${escapeHtml(id)}" data-tree-depth="0">
        <td><span class="tree-node" style="--tree-depth:0">
          <button type="button" class="tree-toggle" data-tree-toggle="${escapeHtml(toggleKey)}" aria-label="${collapsed ? "Expand" : "Collapse"} mappings">
            <i class="fa-solid fa-chevron-${collapsed ? "right" : "down"}"></i>
          </button>
          <a href="#" class="obligation-name-link" data-obligation-view="${escapeHtml(id)}" title="View Obligation Details">${escapeHtml(obligationName(ob))}</a>
        </span></td>
        <td>${escapeHtml(ob.ExecutionFrequency || "")}</td>
        <td>${escapeHtml(ob.AssuranceFrequency || "")}</td>
        <td>${escapeHtml(ob.RetentionPeriod || ob.RetentionRequirement || "")}</td>
        <td>${evidenceCount}</td>
        <td>${mappingCount}</td>
        <td>${badge(ob.Status || "Active")}</td>
        <td>${actionMenu(id)}</td>
      </tr>`;
      if (collapsed) return parent;
      // Child rows reuse the parent's columns for entirely different values --
      // Authority sits under "Execution Frequency", Artifact under "Assurance
      // Frequency", Release under "Retention Period".  One grid header cannot
      // describe both shapes, so the child block carries its own rather than
      // leaving the reader to match values against labels that never applied to
      // them.  Rendered only when there is at least one mapping to head.
      const childHeader = mappings.length ? `<tr class="obligation-child-header-row">
        <td><span class="tree-node" style="--tree-depth:1"><span class="tree-toggle-spacer"></span>Practice</span></td>
        <td>Authority</td>
        <td>Artifact</td>
        <td>Release</td>
        <td colspan="2"></td>
        <td>Status</td>
        <td></td>
      </tr>` : "";
      let childRows;
      if (mappings.length === 0) {
        childRows = `<tr class="tree-row obligation-mapping-row" data-obligation-id="${escapeHtml(id)}" data-tree-depth="1">
          <td><span class="tree-node" style="--tree-depth:1"><span class="tree-toggle-spacer"></span><span class="tree-reference muted">No Practice / Release mappings yet.</span></span></td>
          <td colspan="${colCount - 1}"></td>
        </tr>`;
      } else {
        // Child columns aligned under the parent grid so the tree reads cleanly:
        //   col 1  Practice / Requirement (indented, chained link icon)
        //   col 2  Authority                (under Execution Frequency)
        //   col 3  Artifact / Framework     (under Assurance Frequency)
        //   col 4  Release / Version        (under Retention Period)
        //   col 5,6 empty (Evidence Count, Mapping Count are parent-only)
        //   col 7  Status
        //   col 8  Actions (empty for children)
        childRows = mappings.map(m => {
          const practice  = m.Practice || [m.RequirementCode, m.RequirementName].filter(Boolean).join(" - ");
          const authority = m.Authority || "";
          const artifact  = [m.ArtifactCode, m.Artifact].filter(Boolean).join(" - ");
          const release   = m.ReleaseLabel || m.Release || "";
          return `<tr class="tree-row obligation-mapping-row" data-obligation-id="${escapeHtml(id)}" data-mapping-id="${escapeHtml(m.MapId || "")}" data-tree-depth="1">
            <td><span class="tree-node" style="--tree-depth:1">
              <span class="tree-toggle-spacer"></span>
              <i class="fa-solid fa-link" aria-hidden="true"></i>
              <span class="tree-reference">${escapeHtml(practice)}</span>
            </span></td>
            <td>${escapeHtml(authority)}</td>
            <td>${escapeHtml(artifact)}</td>
            <td>${escapeHtml(release)}</td>
            <td></td>
            <td></td>
            <td>${badge(m.Status || "Active")}</td>
            <td></td>
          </tr>`;
        }).join("");
      }
      return parent + childHeader + childRows;
    }).join("");
  }
  // ---------- Change Management: atomic approval bundles ----------
  // A composite save (e.g. the merged Obligation Master form) emits ONE
  // change_management row per sub-entity, all sharing a BundleId.  Those rows
  // must be actioned together, so the checker queue collapses them into a
  // single parent row: one card, one Approve / Reject / Send Back.
  //
  // The atomicity itself is enforced in SQL -- cm_manage_repository's
  // change-management branch detects bundle_id and delegates to
  // sp_cm_change_bundle_*.  This grouping is the matching UX so the checker
  // is never presented with a partial-approval affordance in the first place.
  function changeManagementGroups() {
    const groups = [];
    const byBundle = new Map();
    (state.records || []).forEach(row => {
      const bundleId = String(row.BundleId ?? row.bundleId ?? "").trim();
      if (!bundleId) { groups.push({ key: `cr-${row.Id}`, parent: row, children: [], bundled: false }); return; }
      if (!byBundle.has(bundleId)) {
        const group = { key: `bundle-${bundleId}`, parent: row, children: [], bundled: true, bundleId };
        byBundle.set(bundleId, group);
        groups.push(group);
      }
      const group = byBundle.get(bundleId);
      group.children.push(row);
      // The master row (lowest BundleSeq) supplies the summary line.
      const seq = Number(row.BundleSeq ?? row.bundleSeq ?? 0);
      const parentSeq = Number(group.parent.BundleSeq ?? group.parent.bundleSeq ?? 0);
      if (seq < parentSeq) group.parent = row;
    });
    groups.forEach(g => g.children.sort((a, b) =>
      Number(a.BundleSeq ?? 0) - Number(b.BundleSeq ?? 0)));
    return groups;
  }

  function renderChangeManagementRows() {
    // Paged by bundle: a bundled change request and its members stay together.
    const groups = pageRows(changeManagementGroups());
    const colCount = cmScreen.Columns.length + 1;
    if (!groups.length) return `<tr><td colspan="${colCount}" class="empty">No records found</td></tr>`;

    return groups.map(group => {
      const row = group.parent;
      if (!group.bundled)
        return `<tr>${cmScreen.Columns.map(c => `<td>${cellValue(row, c)}</td>`).join("")}<td>${actionMenu(row.Id)}</td></tr>`;

      const collapsed = state.collapsed.has(group.key);
      const count = group.children.length;
      // Action menu is driven by the parent row's id; the SQL layer expands
      // any bundle member to the whole bundle, so this is safe.
      const parentRow = `<tr class="tree-row tree-parent-row cm-bundle-parent-row" data-bundle-id="${escapeHtml(group.bundleId)}" data-tree-depth="0">
        ${cmScreen.Columns.map((column, index) => {
          if (index !== 0) return `<td>${cellValue(row, column)}</td>`;
          return `<td><span class="tree-node" style="--tree-depth:0">
            <button type="button" class="tree-toggle" data-tree-toggle="${escapeHtml(group.key)}" aria-label="${collapsed ? "Expand" : "Collapse"} bundled change requests">
              <i class="fa-solid fa-chevron-${collapsed ? "right" : "down"}"></i>
            </button>
            <span class="tree-reference">${cellValue(row, column)}</span>
            <span class="cm-bundle-badge" title="These ${count} change requests were submitted together and are approved or rejected as one unit.">
              <i class="fa-solid fa-layer-group" aria-hidden="true"></i> ${count} linked
            </span>
          </span></td>`;
        }).join("")}
        <td>${actionMenu(row.Id)}</td>
      </tr>`;

      if (collapsed) return parentRow;

      const childRows = group.children.map(child => {
        const label = String(child.EntityType ?? child.entityType ?? "").trim()
          || String(child.RecordReference ?? "").trim()
          || `Change ${child.Id}`;
        return `<tr class="tree-row cm-bundle-child-row" data-tree-depth="1">
          <td><span class="tree-node" style="--tree-depth:1">
            <span class="tree-toggle-spacer"></span>
            <i class="fa-solid fa-diagram-next" aria-hidden="true"></i>
            <span class="tree-reference">${escapeHtml(label)}</span>
          </span></td>
          ${cmScreen.Columns.slice(1).map(column => `<td>${cellValue(child, column)}</td>`).join("")}
          <td></td>
        </tr>`;
      }).join("");

      return parentRow + childRows;
    }).join("");
  }

  function renderRows() {
    // Client-paged screens recompute their own total while rendering; reset it
    // first so the "no records" branches leave the pager showing zero.
    if (!isServerPaged()) state.gridTotal = 0;
    if (cmScreen.Key === "source-structure") return renderSourceStructureRows();
    if (cmScreen.Key === "framework-statements") return renderFrameworkStatementRows();
    if (cmScreen.Key === "obligations") return renderObligationRows();
    if (cmScreen.Key === "obligation-mappings") return renderObligationMappingsRows();
    if (cmScreen.Key === "change-management") return renderChangeManagementRows();
    if (cmScreen.Key === "audit-trace") return renderAuditRows();
    if (!state.records.length) { if (!isServerPaged()) state.gridTotal = 0; return `<tr><td colspan="${cmScreen.Columns.length + 1}" class="empty">No records found</td></tr>`; }
    return pageRows(state.records).map(row => `<tr${cmScreen.Key === "authorities" ? ` class="drill-down-row" data-authority-id="${row.Id}" title="View regulatory artifacts" tabindex="0" role="link" aria-label="View regulatory artifacts under ${escapeHtml(row.Name)}"` : cmScreen.Key === "artifacts" ? ` class="drill-down-row" data-artifact-id="${row.Id}" title="View releases" tabindex="0" role="link" aria-label="View releases under ${escapeHtml(row.Code)}"` : cmScreen.Key === "releases" ? ` class="drill-down-row" data-release-id="${row.Id}" title="View framework source structure" tabindex="0" role="link" aria-label="View framework source structure under ${escapeHtml(row.Version)}"` : ""}>${cmScreen.Columns.map(column => `<td>${cellValue(row, column)}</td>`).join("")}<td>${actionMenu(row.Id)}</td></tr>`).join("");
  }
  function auditGroups() {
    const groups = new Map();
    state.records.forEach((row, index) => {
      const key = String(row.Id || row.AuditTraceId || row.AuditEventId || `${row.EntityType || ""}-${row.RecordReference || ""}-${row.ActionType || ""}-${row.ChangedUtc || row.ChangedOn || index}`);
      if (!groups.has(key)) groups.set(key, { key, parent: row, details: [] });
      const group = groups.get(key);
      if (!group.parent.FieldName && row.FieldName) group.parent = row;
      if (row.FieldName || row.FromValue || row.ToValue) group.details.push(row);
    });
    return [...groups.values()];
  }
  function renderAuditRows() {
    // Paged by audit event: the parent row and its field-level detail rows
    // always render on the same page.
    const pageGroups = pageRows(auditGroups());
    if (!pageGroups.length) return `<tr><td colspan="${cmScreen.Columns.length + 1}" class="empty">No records found</td></tr>`;
    return pageGroups.map(group => {
      const row = group.parent;
      const key = `audit:${group.key}`;
      const collapsed = state.collapsed.has(key);
      const details = group.details.filter(detail => detail.FieldName && !["Add","Edit","SAVE","RETIRE"].includes(String(detail.FieldName)));
      const parentRow = `<tr class="tree-row tree-parent-row audit-parent-row" data-audit-id="${escapeHtml(group.key)}">
        <td><span class="tree-node" style="--tree-depth:0"><button type="button" class="tree-toggle" data-tree-toggle="${escapeHtml(key)}" aria-label="${collapsed ? "Expand" : "Collapse"} audit details"><i class="fa-solid fa-chevron-${collapsed ? "right" : "down"}"></i></button><span class="tree-reference">${escapeHtml(row.EntityType || "")}</span></span></td>
        <td>${escapeHtml(row.RecordReference || "")}</td>
        <td>${escapeHtml(row.ActionType || "")}</td>
        <td>${escapeHtml(row.ChangedBy || "")}</td>
        <td>${escapeHtml(formatIstDateTime(row.ChangedOn || row.ChangedUtc))}</td>
        <td>${badge(row.Status || "Active")}</td>
        <td></td>
      </tr>`;
      const childRows = collapsed ? "" : (details.length
        ? details.map(detail => `<tr class="tree-row audit-detail-row" data-audit-parent="${escapeHtml(group.key)}">
          <td><span class="tree-node audit-detail-field" style="--tree-depth:1"><span class="tree-toggle-spacer"></span><span class="tree-reference">${escapeHtml(detail.FieldName || "")}</span></span></td>
          <td>${escapeHtml(auditValue(detail, "FromValue"))}</td>
          <td>${escapeHtml(auditValue(detail, "ToValue"))}</td>
          <td></td>
          <td></td>
          <td></td>
          <td></td>
        </tr>`).join("")
        : `<tr class="tree-row audit-detail-row audit-detail-empty-row" data-audit-parent="${escapeHtml(group.key)}">
          <td><span class="tree-node audit-detail-field" style="--tree-depth:1"><span class="tree-toggle-spacer"></span><span class="tree-reference">No field-level changes captured.</span></span></td>
          <td></td>
          <td></td>
          <td></td>
          <td></td>
          <td></td>
          <td></td>
        </tr>`);
      return `${parentRow}${childRows}`;
    }).join("");
  }
  function includeAncestors(records, ids) {
    const byId = new Map(records.map(row => [String(row.Id), row])), keep = new Set(ids);
    ids.forEach(id => {
      let current = byId.get(String(id));
      while (current?.ParentNodeId) {
        keep.add(String(current.ParentNodeId));
        current = byId.get(String(current.ParentNodeId));
      }
    });
    return records.filter(row => keep.has(String(row.Id)));
  }
  function sourceMapShell() {
    panel.innerHTML = `<div class="source-map-screen">
      <div class="source-map-top">
        <label><span>Practice</span><select id="mappingControl"><option value="">Select practice...</option>${(state.lookups.requirements || []).map(item => `<option value="${escapeHtml(item.value)}">${escapeHtml(item.label)}</option>`).join("")}</select></label>
        <div class="control-summary" id="mappingControlSummary"><span>Select a Practice to manage its Framework Statement mappings.</span></div>
      </div>
      <div class="source-map-message" id="sourceMapMessage" hidden></div>
      <div class="source-map-actions"><button type="button" class="button small" data-expand-all>Expand all</button><button type="button" class="button small" data-collapse-all>Collapse all</button></div>
      <div class="source-map-panels">
        <section class="source-map-panel"><div class="source-map-panel-head"><div><strong>Unmapped Framework Nodes</strong><small id="leftCount">0 selected</small><small class="map-hint">Release → Source Structure → Framework Statements. Only Framework Statements are selectable.</small></div><input id="leftSearch" placeholder="Search unmapped..." /></div><div class="source-map-tree" id="leftTree"></div></section>
        <section class="source-map-panel"><div class="source-map-panel-head"><div><strong>Mapped Framework Nodes</strong><small id="rightCount">0 selected</small><small class="map-hint">Framework Statements already mapped to this control.</small></div><input id="rightSearch" placeholder="Search mapped..." /></div><div class="source-map-tree" id="rightTree"></div></section>
      </div>
      <div class="source-map-footer"><button type="button" class="button primary" id="mapNodes">Map <i class="fa-solid fa-arrow-right"></i></button><button type="button" class="button" id="removeNodes"><i class="fa-solid fa-arrow-left"></i> Remove</button></div>
    </div>`;
  }
  function sourceNodeLabel(row) {
    const prefix = [row.ArtifactCode || row.Artifact, row.Version].filter(Boolean).join(" / ");
    return row.ParentNodeId ? `${row.Reference} - ${row.Title || ""}` : `${prefix} ${row.Reference ? "/ " + row.Reference : ""} ${row.Title || ""}`;
  }
  function statementNodeLabel(row) {
    return `${row.StatementReference || ""} - ${row.StatementTitle || row.StatementText || ""}`.trim();
  }
  // The mapping tree combines source-structure "folder" nodes with framework-statement
  // "leaf" nodes.  Statements are synthesized as pseudo-tree records with a stable
  // composite id (fs-<statementId>) so they can flow through the shared buildTree /
  // flattenTree helpers alongside their parent structure node without colliding.
  function buildMappingTreeRecords() {
    const structureRecords = (sourceMapState.nodes || []).map(row => ({
      ...row,
      Id: `sn-${row.Id}`,
      ParentNodeId: row.ParentNodeId ? `sn-${row.ParentNodeId}` : "",
      __kind: "structure",
      __sourceId: String(row.Id)
    }));
    const statementRecords = (sourceMapState.statements || []).map(statement => ({
      Id: `fs-${statement.Id}`,
      ParentNodeId: `sn-${statement.StructureNodeId}`,
      Reference: statement.StatementReference,
      Title: statement.StatementTitle,
      DisplayOrder: statement.DisplayOrder,
      __kind: "statement",
      __statementId: String(statement.Id),
      __statement: statement
    }));
    return { records: [...structureRecords, ...statementRecords], structureRecords, statementRecords };
  }
  function renderMappingTree(host, records, side) {
    const search = document.querySelector(side === "left" ? "#leftSearch" : "#rightSearch")?.value.trim().toLowerCase() || "";
    const selected = side === "left" ? sourceMapState.leftSelected : sourceMapState.rightSelected;
    const mappedByStatement = new Map(sourceMapState.mapped
      .filter(row => row.Status === "Active" && row.FrameworkStatementId != null)
      .map(row => [String(row.FrameworkStatementId), row]));
    const matchesSearch = row => {
      if (!search) return true;
      if (row.__kind === "statement") {
        const s = row.__statement || {};
        return `${s.StatementReference || ""} ${s.StatementTitle || ""} ${s.StatementText || ""} ${s.SourceReference || ""} ${s.SourceNode || ""}`.toLowerCase().includes(search);
      }
      return `${row.Reference || ""} ${row.Title || ""} ${row.ArtifactCode || ""} ${row.Artifact || ""} ${row.Version || ""}`.toLowerCase().includes(search);
    };
    const filtered = search ? includeAncestors(records, new Set(records.filter(matchesSearch).map(row => String(row.Id)))) : records;
    const flat = flattenTree(filtered, false);
    // Only statement rows are meaningful leaves; suppress structure "folders" that
    // have no visible statement children so the tree does not show empty branches.
    const visible = flat.filter(({ row, hasChildren }) => row.__kind === "statement" || hasChildren);
    host.innerHTML = visible.length ? visible.map(({ row, depth, hasChildren }) => {
      const id = String(row.Id), collapsed = sourceMapState.collapsed.has(id);
      const isStatement = row.__kind === "statement";
      const toggle = !isStatement && hasChildren
        ? `<button type="button" class="map-tree-toggle" data-map-toggle="${escapeHtml(id)}"><i class="fa-solid fa-chevron-${collapsed ? "right" : "down"}"></i></button>`
        : `<span class="map-tree-spacer"></span>`;
      const checkbox = isStatement
        ? `<input type="checkbox" data-map-node="${escapeHtml(id)}" data-statement-id="${escapeHtml(row.__statementId)}" data-side="${side}"${selected.has(id) ? " checked" : ""}>`
        : `<span class="map-parent-dot map-folder-dot" title="Source Structure node - only Framework Statements can be mapped."><i class="fa-solid fa-folder"></i></span>`;
      const label = isStatement ? statementNodeLabel(row.__statement) : sourceNodeLabel(row);
      const mapMeta = isStatement ? mappedByStatement.get(row.__statementId) : null;
      const statusPill = side === "right" && mapMeta ? `<span class="map-pill">${escapeHtml(mapMeta.Status)}</span>` : "";
      return `<div class="map-tree-row${!isStatement ? " parent" : " leaf-statement"}" style="--tree-depth:${depth}" data-node-id="${escapeHtml(id)}">${toggle}${checkbox}<span class="map-node-text" title="${escapeHtml(label)}">${escapeHtml(label)}</span>${statusPill}</div>`;
    }).join("") : `<div class="map-empty">No framework statements found</div>`;
  }
  function refreshMappingTrees() {
    const { records } = buildMappingTreeRecords();
    const mappedStatementIds = new Set(sourceMapState.mapped
      .filter(row => row.Status === "Active" && row.FrameworkStatementId != null)
      .map(row => String(row.FrameworkStatementId)));
    // Both sides show the same Release -> Source Structure -> Framework Statement
    // hierarchy; left keeps only unmapped statement leaves, right keeps only mapped
    // statement leaves, and includeAncestors preserves the shared parent context.
    const unmappedStatementRecordIds = new Set(records
      .filter(row => row.__kind === "statement" && !mappedStatementIds.has(row.__statementId))
      .map(row => String(row.Id)));
    const mappedStatementRecordIds = new Set(records
      .filter(row => row.__kind === "statement" && mappedStatementIds.has(row.__statementId))
      .map(row => String(row.Id)));
    const unmappedRecords = includeAncestors(records, unmappedStatementRecordIds)
      .filter(row => row.__kind !== "statement" || unmappedStatementRecordIds.has(String(row.Id)));
    const mappedRecords = includeAncestors(records, mappedStatementRecordIds)
      .filter(row => row.__kind !== "statement" || mappedStatementRecordIds.has(String(row.Id)));
    renderMappingTree(document.querySelector("#leftTree"), unmappedRecords, "left");
    renderMappingTree(document.querySelector("#rightTree"), mappedRecords, "right");
    document.querySelector("#leftCount").textContent = `${sourceMapState.leftSelected.size} selected`;
    document.querySelector("#rightCount").textContent = `${sourceMapState.rightSelected.size} selected`;
  }
  function showSourceMapMessage(text, ok = false) {
    const el = document.querySelector("#sourceMapMessage");
    el.textContent = text; el.hidden = false; el.classList.toggle("success", ok);
  }
  async function loadSourceMappings() {
    if (!sourceMapState.practiceId) return;
    sourceMapState.practice = (await fetchRows("requirements", { id: sourceMapState.practiceId }))[0] || null;
    // Reuse the existing Framework Statement query so both the source-structure
    // hierarchy AND the statements that live under it are available for the tree.
    const [nodes, statements, mapped] = await Promise.all([
      fetchRows("source-structure", { status: "Active" }),
      fetchRows("framework-statements", { status: "Active" }),
      fetchRows("source-control-mappings", { requirementId: sourceMapState.practiceId, status: "Active" })
    ]);
    sourceMapState.nodes = nodes;
    sourceMapState.statements = statements;
    sourceMapState.mapped = mapped;
    sourceMapState.leftSelected.clear(); sourceMapState.rightSelected.clear();
    const p = sourceMapState.practice;
    document.querySelector("#mappingControlSummary").innerHTML = p ? `<strong>${escapeHtml(p.Code)}</strong><span>${escapeHtml(p.Name)}</span><small>Status: ${escapeHtml(p.Status)}</small>` : `<span>Select a Practice to manage its Framework Statement mappings.</span>`;
    refreshMappingTrees();
  }
  async function initSourceControlMappings() {
    sourceMapShell();
    document.querySelector("#mappingControl").addEventListener("change", async event => { sourceMapState.practiceId = event.target.value; await loadSourceMappings(); });
    document.querySelector("#leftSearch").addEventListener("input", refreshMappingTrees);
    document.querySelector("#rightSearch").addEventListener("input", refreshMappingTrees);
    panel.addEventListener("click", async event => {
      if (event.target.closest(".map-parent-dot")) { showSourceMapMessage("Only Framework Statements can be mapped to a Practice. Source Structure nodes act as folders."); return; }
      const toggle = event.target.closest("[data-map-toggle]");
      if (toggle) { const id = toggle.dataset.mapToggle; sourceMapState.collapsed.has(id) ? sourceMapState.collapsed.delete(id) : sourceMapState.collapsed.add(id); refreshMappingTrees(); return; }
      if (event.target.matches("[data-expand-all]")) { sourceMapState.collapsed.clear(); refreshMappingTrees(); return; }
      if (event.target.matches("[data-collapse-all]")) { (sourceMapState.nodes || []).forEach(row => sourceMapState.collapsed.add(`sn-${row.Id}`)); refreshMappingTrees(); return; }
      if (event.target.closest("#mapNodes")) { await mapSelectedNodes(); return; }
      if (event.target.closest("#removeNodes")) { await removeSelectedNodes(); }
    });
    panel.addEventListener("change", event => {
      const box = event.target.closest("[data-map-node]");
      if (!box) return;
      const set = box.dataset.side === "left" ? sourceMapState.leftSelected : sourceMapState.rightSelected;
      box.checked ? set.add(box.dataset.mapNode) : set.delete(box.dataset.mapNode);
      refreshMappingTrees();
    });
  }
  async function mapSelectedNodes() {
    if (!sourceMapState.practiceId) { showSourceMapMessage("Select a Practice first."); return; }
    if (!sourceMapState.leftSelected.size) { showSourceMapMessage("Select one or more Framework Statements to map."); return; }
    const statementIds = [...sourceMapState.leftSelected]
      .map(id => id.startsWith("fs-") ? id.slice(3) : "")
      .filter(Boolean);
    if (!statementIds.length) { showSourceMapMessage("Only Framework Statements can be mapped to a Practice."); return; }
    if (!await appConfirm(`Map ${statementIds.length} selected Framework Statement(s) to this Practice?`, { confirmText: "Map" })) return;
    for (const statementId of statementIds) await fetchJson(`${cmApi}/source-control-mappings`, { method:"POST", headers:{ "Content-Type":"application/json", "X-CSRF-TOKEN":csrfToken }, body:JSON.stringify({ data:{ frameworkStatementId:statementId, requirementIds:[sourceMapState.practiceId], status:"Active" } }) });
    await loadSourceMappings(); showSourceMapMessage("Mapping saved successfully.", true);
  }
  async function removeSelectedNodes() {
    if (!sourceMapState.rightSelected.size) { showSourceMapMessage("Select one or more mapped Framework Statements to remove."); return; }
    if (!await appConfirm(`Remove ${sourceMapState.rightSelected.size} selected mapping(s)?`, { confirmText: "Remove" })) return;
    const mapByStatement = new Map(sourceMapState.mapped
      .filter(row => row.FrameworkStatementId != null)
      .map(row => [String(row.FrameworkStatementId), row.Id]));
    for (const compositeId of sourceMapState.rightSelected) {
      const statementId = compositeId.startsWith("fs-") ? compositeId.slice(3) : compositeId;
      const mappingId = mapByStatement.get(String(statementId));
      if (mappingId) await fetchJson(`${cmApi}/source-control-mappings/${mappingId}/retire`, { method:"POST", headers:{ "Content-Type":"application/json", "X-CSRF-TOKEN":csrfToken }, body:"{}" });
    }
    await loadSourceMappings(); showSourceMapMessage("Mapping removed successfully.", true);
  }
  async function load() {
    closeMenus();
    const loadVersion = ++state.loadVersion;
    rows.innerHTML = `<tr><td colspan="${cmScreen.Columns.length + 1}" class="empty">Loading...</td></tr>`;
    const search = encodeURIComponent(document.querySelector("#search").value), status = encodeURIComponent(document.querySelector("#status").value), authorityId = encodeURIComponent(authoritySelect.value), artifactId = encodeURIComponent(artifactSelect.value), releaseId = encodeURIComponent(releaseSelect.value), code = encodeURIComponent(state.navigationCode);
    const changeModule = encodeURIComponent(changeModuleSelect?.value || "");
    const changeActionType = encodeURIComponent(changeActionTypeSelect?.value || "");
    try {
      if (statementScopedAreas.has(cmScreen.Key)) {
        const [nodes, statements, obligations] = await Promise.all([
          // All statuses, not just Active: a deactivated node still has to appear
          // here, otherwise every statement under it silently vanishes from the
          // grid and there is no way to reach it to activate it again.
          fetchRows("source-structure", { authorityId: authoritySelect.value, artifactId: artifactSelect.value, releaseId: releaseSelect.value, status: "" }),
          fetchRows("framework-statements", { search: cmScreen.Key === "framework-statements" ? document.querySelector("#search").value : "", authorityId: authoritySelect.value, artifactId: artifactSelect.value, releaseId: releaseSelect.value, status: "" }),
          cmScreen.Key === "obligations"
            ? fetchRows("obligations", { search: document.querySelector("#search").value, authorityId: authoritySelect.value, artifactId: artifactSelect.value, releaseId: releaseSelect.value, status: "" })
            : Promise.resolve([])
        ]);
        if (loadVersion !== state.loadVersion) return;
        state.frameworkStatementNodes = nodes;
        state.frameworkStatementStatements = statements;
        state.records = cmScreen.Key === "obligations" ? obligations : statements;
        rows.innerHTML = renderRows();
        updateGridPager();
        return;
      }
      const extra = ["change-management","audit-trace"].includes(cmScreen.Key) ? `&module=${changeModule}&actionType=${changeActionType}` : "";
      const paged = paginatedAreas.has(cmScreen.Key);
      const pager = paged ? `&page=${state.gridPage}&pageSize=${state.gridPageSize}` : "";
      const result = await fetchJson(`${cmApi}/${cmScreen.Key}?search=${search}&status=${status}&authorityId=${authorityId}&artifactId=${artifactId}&releaseId=${releaseId}&code=${code}${extra}${pager}`);
      if (loadVersion !== state.loadVersion) return;
      state.records = apiData(result);
      if (paged) {
        const tables = result.data || result.Data || [];
        const totalRow = (tables[1] || [])[0] || {};
        state.gridTotal = Number(totalRow.TotalCount ?? totalRow.totalCount ?? state.records.length) || 0;
      }
      if (["change-management","audit-trace"].includes(cmScreen.Key)) await populateChangeManagementFilters();
      rows.innerHTML = renderRows();
      updateGridPager();
    } catch (error) { if (loadVersion === state.loadVersion) rows.innerHTML = `<tr><td colspan="${cmScreen.Columns.length + 1}" class="empty">${escapeHtml(error.message)}</td></tr>`; }
  }
  /* Called after every render.  `state.gridTotal` is set by the API for
     server-paged screens and by pageRows()/pageTreeRoots() for the rest. */
  function updateGridPager() {
    if (!gridPager) return;
    state.gridPage = gridPager.update({
      page: state.gridPage,
      pageSize: state.gridPageSize,
      total: Number(state.gridTotal) || 0
    });
  }
  function resetGridPage() { state.gridPage = 1; gridPager?.setPage(1); }
  /* The Status filter and the Status field on the form must offer the same
     vocabulary, so both read the screen's schema.  A few screens have no Status
     field of their own — they get an explicit group here rather than inheriting
     a vocabulary their rows never use. */
  const statusLookupOverrides = {
    "change-management": "status-change-request"
  };
  // Screens where filtering by status is meaningless: the immutable log views.
  const statusFilterHiddenAreas = new Set(["audit-trace", "assurance-version-history"]);
  function statusLookupKey() {
    if (statusLookupOverrides[cmScreen.Key]) return statusLookupOverrides[cmScreen.Key];
    const field = (schemas[cmScreen.Key] || []).find(item => item.name === "status");
    return field?.lookup || "status-repository";
  }
  function populateStatusFilter() {
    const statusSelect = document.querySelector("#status");
    if (statementScopedAreas.has(cmScreen.Key) || statusFilterHiddenAreas.has(cmScreen.Key)) {
      statusSelect.hidden = true;
      statusSelect.innerHTML = `<option value="">All statuses</option>`;
      return;
    }
    // Use the lookup group this screen's own Status field is bound to.  The
    // previous version merged every group whose key contained "status", so a
    // grid offered values its table never holds (Draft and Archived on a
    // Practice, Inactive on an Artifact, and so on).
    const values = state.lookups[statusLookupKey()] || [];
    statusSelect.hidden = false;
    statusSelect.innerHTML = `<option value="">All statuses</option>${values.map(item => `<option value="${escapeHtml(item.value)}">${escapeHtml(item.label)}</option>`).join("")}`;
  }
  async function populateChangeManagementFilters() {
    if (!changeModuleSelect || !changeActionTypeSelect) return;
    const isFilterableAudit = cmScreen.Key === "audit-trace";
    const isChangeManagement = cmScreen.Key === "change-management" || isFilterableAudit;
    changeModuleSelect.hidden = !isChangeManagement;
    changeActionTypeSelect.hidden = !isChangeManagement;
    if (!isChangeManagement) return;
    if (!state.changeModules.length) {
      const rowsForModules = apiData(await fetchJson(`${cmApi}/${cmScreen.Key}?status=&search=`));
      state.changeModules = [...new Set(rowsForModules.map(row => isFilterableAudit ? row.EntityType : row.Module).filter(Boolean))].sort((a, b) => String(a).localeCompare(String(b)));
    }
    const modules = state.changeModules;
    const currentModule = changeModuleSelect.value;
    const currentAction = changeActionTypeSelect.value;
    const actionTypes = isFilterableAudit ? auditActionTypes : changeActionTypes;
    changeModuleSelect.innerHTML = `<option value="">${isFilterableAudit ? "All entity types" : "All modules"}</option>${modules.map(item => `<option value="${escapeHtml(item)}">${escapeHtml(item)}</option>`).join("")}`;
    changeActionTypeSelect.innerHTML = `<option value="">${isFilterableAudit ? "All change types" : "All action types"}</option>${actionTypes.map(item => `<option value="${escapeHtml(item)}">${escapeHtml(item)}</option>`).join("")}`;
    changeModuleSelect.value = modules.includes(currentModule) ? currentModule : "";
    changeActionTypeSelect.value = actionTypes.includes(currentAction) ? currentAction : "";
  }
  function artifactAuthorityId(artifactId) {
    if (state.navigationContext?.parentAuthorityId) return String(state.navigationContext.parentAuthorityId);
    const row = state.records.find(item => String(item.Id) === String(artifactId));
    if (row?.AuthorityId) return String(row.AuthorityId);
    const artifact = state.lookups.artifacts?.find(item => String(item.value) === String(artifactId));
    return artifact?.authorityId ? String(artifact.authorityId) : "";
  }
  function releaseAuthorityId() {
    if (state.navigationContext?.parentAuthorityId) return String(state.navigationContext.parentAuthorityId);
    const releaseId = state.navigationContext?.filterType === "Release" ? state.navigationContext.filterId : releaseSelect.value;
    const row = state.records.find(item => String(item.Id) === String(releaseId));
    return row?.AuthorityId ? String(row.AuthorityId) : "";
  }
  function releaseArtifactId() {
    if (state.navigationContext?.parentArtifactId) return String(state.navigationContext.parentArtifactId);
    const releaseId = state.navigationContext?.filterType === "Release" ? state.navigationContext.filterId : releaseSelect.value;
    const row = state.records.find(item => String(item.Id) === String(releaseId));
    return row?.ArtifactId ? String(row.ArtifactId) : "";
  }
  function filteredArtifacts() {
    const selectedAuthorityId = authoritySelect.value || "";
    if (!selectedAuthorityId) return [];
    return (state.lookups.artifacts || []).filter(item => String(item.authorityId || "") === String(selectedAuthorityId));
  }
  function filteredReleases() {
    const selectedArtifactId = artifactSelect.value || "";
    if (!selectedArtifactId) return [];
    return (state.lookups.releases || []).filter(item => String(item.artifactId || "") === String(selectedArtifactId));
  }
  function populateAuthorityFilter() {
    authoritySelect.hidden = !authorityFilteredAreas.has(cmScreen.Key);
    const authorityHasContext = ["Authority","Artifact","Release"].includes(state.navigationContext?.filterType);
    authoritySelect.innerHTML = `${authorityHasContext ? "" : `<option value="">All authorities</option>`}${(state.lookups.authorities || []).map(item => `<option value="${escapeHtml(item.value)}">${escapeHtml(item.label)}</option>`).join("")}`;
    if (state.navigationContext?.filterType === "Authority") authoritySelect.value = String(state.navigationContext.filterId || "");
    else if (state.navigationContext?.filterType === "Artifact") authoritySelect.value = artifactAuthorityId(state.navigationContext.filterId);
    else if (state.navigationContext?.filterType === "Release") authoritySelect.value = releaseAuthorityId();
    else authoritySelect.value = "";
    updateArtifactContext();
  }
  function populateArtifactFilter() {
    artifactSelect.hidden = !artifactFilterAreas.has(cmScreen.Key);
    artifactSelect.innerHTML = `<option value="">All artifacts</option>${filteredArtifacts().map(item => `<option value="${escapeHtml(item.value)}">${escapeHtml(item.label)}</option>`).join("")}`;
    if (state.navigationContext?.filterType === "Artifact") artifactSelect.value = String(state.navigationContext.filterId || "");
    else if (state.navigationContext?.filterType === "Release") artifactSelect.value = releaseArtifactId();
    else artifactSelect.value = "";
    if (artifactSelect.value && !Array.from(artifactSelect.options).some(option => option.value === artifactSelect.value)) artifactSelect.value = "";
    updateReleaseContext();
  }
  function populateReleaseFilter() {
    releaseSelect.hidden = !releaseFilterAreas.has(cmScreen.Key);
    const releaseHasContext = state.navigationContext?.filterType === "Release";
    releaseSelect.innerHTML = `<option value="">All releases</option>${filteredReleases().map(item => `<option value="${escapeHtml(item.value)}">${escapeHtml(item.label)}</option>`).join("")}`;
    releaseSelect.value = releaseHasContext ? String(state.navigationContext.filterId || "") : "";
    if (releaseSelect.value && !Array.from(releaseSelect.options).some(option => option.value === releaseSelect.value)) releaseSelect.value = "";
    updateSourceStructureContext();
  }
  function updateFrameworkStatementContext() {
    if (!statementScopedAreas.has(cmScreen.Key)) return;
    const authorityLabel = authoritySelect.selectedOptions[0]?.textContent || "";
    const releaseLabel = releaseSelect.selectedOptions[0]?.textContent || "";
    pageTitle.textContent = releaseLabel ? `${cmScreen.Title} under ${releaseLabel}` : cmScreen.Title;
    refreshAddButtonLabel();
  }
  async function refreshFrameworkStatementReleases() {
    if (!statementScopedAreas.has(cmScreen.Key)) return;
    updateFrameworkStatementContext();
  }
  const reloadFromFilter = () => { resetGridPage(); load(); };
  document.querySelector("#refresh").addEventListener("click", load);
  document.querySelector("#search").addEventListener("input", reloadFromFilter);
  document.querySelector("#status").addEventListener("change", reloadFromFilter);
  // Page navigation and rows-per-page are handled by the GracPager instance
  // created above (see its onChange handler).
  changeModuleSelect?.addEventListener("change", reloadFromFilter);
  changeActionTypeSelect?.addEventListener("change", reloadFromFilter);
  document.querySelector("#clearFilters")?.addEventListener("click", () => {
    document.querySelector("#search").value = "";
    document.querySelector("#status").value = "";
    if (changeModuleSelect) changeModuleSelect.value = "";
    if (changeActionTypeSelect) changeActionTypeSelect.value = "";
    if (!state.navigationContext) {
      authoritySelect.value = "";
      populateArtifactFilter();
      populateReleaseFilter();
    }
    resetGridPage();
    load();
  });
  authoritySelect.addEventListener("change", () => {
    state.navigationCode = "";
    state.navigationContext = null;
    if (cmScreen.Key === "releases") {
      populateArtifactFilter();
      artifactSelect.value = "";
      updateReleaseContext();
      window.history.replaceState({}, "", appUrl("/Repository/Index/releases"));
    } else if (artifactFilterAreas.has(cmScreen.Key)) {
      populateArtifactFilter();
      artifactSelect.value = "";
      populateReleaseFilter();
      releaseSelect.value = "";
      updateSourceStructureContext();
      updateFrameworkStatementContext();
      window.history.replaceState({}, "", appUrl(`/Repository/Index/${cmScreen.Key}`));
    } else {
      synchronizeArtifactFilterUrl();
      updateArtifactContext();
    }
    load();
  });
  artifactSelect.addEventListener("change", () => {
    state.navigationCode = "";
    state.navigationContext = null;
    if (releaseFilterAreas.has(cmScreen.Key)) {
      populateReleaseFilter();
      releaseSelect.value = "";
      updateSourceStructureContext();
      updateFrameworkStatementContext();
      window.history.replaceState({}, "", appUrl(`/Repository/Index/${cmScreen.Key}`));
    } else {
      synchronizeReleaseFilterUrl();
      updateReleaseContext();
    }
    load();
  });
  releaseSelect.addEventListener("change", () => {
    synchronizeSourceStructureFilterUrl(); updateSourceStructureContext(); updateFrameworkStatementContext(); load();
  });
  backButton.addEventListener("click", () => window.location.assign(appUrl("/Repository/Index/releases")));
  addRecordButton?.addEventListener("click", () => {
    const action = cmScreen.Key === "source-structure"
      ? addRootNode()
      : cmScreen.Key === "framework-statements"
        ? navigateStatementForm("add")
        : openForm("add");
    Promise.resolve(action).catch(error => alert(error.message));
  });
  form.addEventListener("submit", event => event.preventDefault());
  dialog.addEventListener("close", resetFormState);
  closeButton.addEventListener("click", closeForm);
  // Cancel discards the in-progress edits and drops back to View Mode when the
  // edit was started from there; otherwise it closes the dialog as before.
  cancelButton.addEventListener("click", () => {
    if (state.formReturnToView && state.mode !== "view") {
      switchDialogMode("view").catch(error => alert(error.message));
      return;
    }
    closeForm();
  });
  editButton?.addEventListener("click", () => {
    switchDialogMode("edit").catch(error => alert(error.message));
  });
  saveButton.addEventListener("click", save);
  fieldsHost.addEventListener("click", event => {
    const similarSort = event.target.closest("[data-similar-sort]");
    if (similarSort) {
      const key = similarSort.dataset.similarSort;
      state.similarSort = state.similarSort?.key === key
        ? { key, direction: state.similarSort.direction === "asc" ? "desc" : "asc" }
        : { key, direction: "asc" };
      // Route to the correct renderer so Obligations/Practices use the
      // generic grid while Controls keep using their legacy grid.
      const config = similarConfigs[cmScreen.Key];
      if (config) renderSimilarRecordsRows(config); else renderSimilarControlRows();
      return;
    }
    const addMaster = event.target.closest("[data-add-master]");
    if (addMaster) {
      const action = addMaster.dataset.addMaster === "domainId" ? addControlDomain : addControlSubDomain;
      action().catch(error => { message.textContent = error.message; message.hidden = false; });
      return;
    }
    const addEvidence = event.target.closest("[data-obligation-add-evidence]");
    if (addEvidence) {
      addEvidence.closest(".obligation-evidence-grid")?.querySelector("tbody")?.insertAdjacentHTML("beforeend", obligationEvidenceRowHtml());
      return;
    }
    const addObligation = event.target.closest("[data-obligation-add]");
    if (addObligation) {
      obligationState.contexts.push({ RequirementId: fieldsHost.querySelector("#field-requirementId")?.value || obligationState.requirement?.Id || state.id });
      renderObligationMapping();
      return;
    }
    const removeObligation = event.target.closest("[data-obligation-remove]");
    if (removeObligation) {
      const card = removeObligation.closest("[data-obligation-index]");
      const index = Number(card?.dataset.obligationIndex || -1);
      const existingId = Number(card?.dataset.obligationId || 0);
      if (existingId > 0) {
        message.textContent = "Saved obligations can be inactivated from the row action menu.";
        message.hidden = false;
        return;
      }
      if (index >= 0) obligationState.contexts.splice(index, 1);
      if (!obligationState.contexts.length) obligationState.contexts.push({ RequirementId: fieldsHost.querySelector("#field-requirementId")?.value || "" });
      renderObligationMapping();
      return;
    }
    const removeEvidence = event.target.closest("[data-obligation-remove-evidence]");
    if (removeEvidence) {
      const tbody = removeEvidence.closest("tbody");
      removeEvidence.closest("[data-obligation-evidence-row]")?.remove();
      if (tbody && !tbody.querySelector("[data-obligation-evidence-row]")) tbody.insertAdjacentHTML("beforeend", obligationEvidenceRowHtml());
      return;
    }
    const sourceToggle = event.target.closest("[data-fs-source-toggle]");
    if (sourceToggle) {
      const id = sourceToggle.dataset.fsSourceToggle;
      frameworkStatementTreeState.collapsed.has(id) ? frameworkStatementTreeState.collapsed.delete(id) : frameworkStatementTreeState.collapsed.add(id);
      renderFrameworkStatementSourceTree();
      return;
    }
    const sourceRow = event.target.closest("[data-fs-source-row]");
    if (sourceRow && !frameworkStatementTreeState.readonly) {
      selectFrameworkStatementSourceNode(sourceRow.dataset.fsSourceRow);
      return;
    }
    const reqToggle = event.target.closest("[data-req-toggle]");
    if (reqToggle) {
      syncRequirementStatementSelection();
      const key = reqToggle.dataset.reqToggle;
      requirementMapState.collapsed.has(key) ? requirementMapState.collapsed.delete(key) : requirementMapState.collapsed.add(key);
      renderRequirementControlTree();
      return;
    }
    const controlSourceToggle = event.target.closest("[data-control-source-toggle]");
    if (controlSourceToggle) {
      const key = controlSourceToggle.dataset.controlSourceToggle;
      controlSourceMapState.collapsed.has(key) ? controlSourceMapState.collapsed.delete(key) : controlSourceMapState.collapsed.add(key);
      renderControlSourceMappingTree();
      return;
    }
    if (event.target.closest(".control-source-map .map-parent-dot")) {
      message.textContent = "Only leaf-level source structure nodes can be mapped to a control.";
      message.hidden = false;
      return;
    }
    const trigger = event.target.closest(".checkbox-combo-trigger");
    if (trigger) {
      const combo = trigger.closest("[data-checkbox-combo]"), shouldOpen = !combo.classList.contains("open");
      if (!shouldOpen) {
        closeCheckboxCombos();
        return;
      }
      closeCheckboxCombos(combo);
      combo.classList.add("open");
      trigger.setAttribute("aria-expanded", String(shouldOpen));
      positionCheckboxCombo(combo);
      return;
    }
    const option = event.target.closest('[data-checkbox-combo] input[type="checkbox"]');
    if (option) updateCheckboxCombo(option.closest("[data-checkbox-combo]"));
  });
  fieldsHost.addEventListener("input", event => {
    const search = event.target.closest(".checkbox-combo-search");
    if (search) filterCheckboxCombo(search.closest("[data-checkbox-combo]"), search.value);
    const tagInput = event.target.closest("[data-tag-input] input");
    if (tagInput) {
      updateTagPreview(tagInput.closest("[data-tag-input]"));
      if (cmScreen.Key === "controls") scheduleSimilarControlsRefresh();
      // Keywords on the Obligation/Practice forms drive the similar-records grid.
      if (similarConfigs[cmScreen.Key] && tagInput.closest("#field-keywords")) scheduleSimilarRecordsRefresh();
    }
    const similarFilter = event.target.closest("[data-similar-filter]");
    if (similarFilter) {
      // Legacy per-column filter (Controls form only).  Obligation/Practice
      // grids use the compact quick-filter box handled below.
      state.similarFilters[similarFilter.dataset.similarFilter] = similarFilter.value;
      renderSimilarControlRows();
    }
    const similarQuick = event.target.closest("[data-similar-quick-filter]");
    if (similarQuick) {
      state.similarQuickFilter = similarQuick.value;
      const config = similarConfigs[cmScreen.Key];
      if (config) renderSimilarRecordsRows(config);
    }
    if (event.target?.id === "requirementControlSearch") { syncRequirementStatementSelection(); renderRequirementControlTree(); }
    if (event.target?.id === "controlSourceSearch") renderControlSourceMappingTree();
    if (formEntityKey() === "framework-statements" && event.target?.id === "field-statementReference" && event.target.value.trim() !== (state.formContext.autoStatementReference || "")) {
      state.formContext.autoStatementReference = "";
    }
  });
  fieldsHost.addEventListener("keydown", event => {
    const sourceRow = event.target.closest("[data-fs-source-row]");
    if (!sourceRow || frameworkStatementTreeState.readonly) return;
    if (event.key !== "Enter" && event.key !== " ") return;
    event.preventDefault();
    selectFrameworkStatementSourceNode(sourceRow.dataset.fsSourceRow);
  });
  fieldsHost.addEventListener("change", event => {
    const comboCheckbox = event.target.closest('[data-checkbox-combo] input[type="checkbox"]');
    if (comboCheckbox) updateCheckboxCombo(comboCheckbox.closest("[data-checkbox-combo]"));
    if (cmScreen.Key === "obligations" && event.target?.id === "field-frequencyType") updateFrequencyFields();
    if (cmScreen.Key === "obligations" && event.target?.id === "field-requirementId") {
      const requirementId = event.target.value;
      state.id = Number(requirementId || 0);
      (async () => {
        obligationState.requirement = requirementId ? (await fetchRows("requirements", { id: requirementId }))[0] || {} : {};
        obligationState.contexts = requirementId ? await hydrateObligationEvidence(await fetchRows("obligations", { requirementId, status: "" })) : [];
        renderObligationMapping();
      })().catch(error => { message.textContent = error.message; message.hidden = false; });
    }
    if (cmScreen.Key === "control-requirement-mappings" && event.target?.id === "field-controlId") {
      refreshRequirementMappingCombo(state.mode === "view").catch(error => { message.textContent = error.message; message.hidden = false; });
    }
    if (cmScreen.Key === "controls" && event.target?.id === "field-domainId") {
      refreshSubDomainOptions().catch(error => { message.textContent = error.message; message.hidden = false; });
    }
    // Picking a Release on Add Source Node re-points the Authority / Artifact /
    // Release banner at the top of the form.
    if (formEntityKey() === "source-structure" && event.target?.id === "field-releaseId") {
      state.formContext.releaseId = event.target.value;
      state.formContext.releaseLabel = "";
      state.formContext.artifactLabel = "";
      state.formContext.authorityLabel = "";
      state.formContext.parentArtifactId = "";
      state.formContext.parentAuthorityId = "";
      renderSourceNodeContext();
    }
    if (formEntityKey() === "framework-statements" && event.target?.id === "field-releaseId") {
      frameworkStatementTreeState.selected = "";
      frameworkStatementTreeState.collapsed.clear();
      document.querySelector("#field-structureNodeId").value = "";
      const classificationField = document.querySelector("#field-classificationId");
      if (classificationField) classificationField.value = "";
      clearAutoStatementReference();
      Promise.all([
        loadFrameworkStatementSourceTree(event.target.value, "", state.mode === "view"),
        refreshStatementClassificationOptions("", state.mode === "view")
      ])
        .catch(error => { message.textContent = error.message; message.hidden = false; });
    }
    if (event.target?.matches("[data-req-statement]")) { syncRequirementStatementSelection(); updateRequirementSelectedCount(); }
    const sourceNode = event.target.closest("[data-control-source-node]");
    if (sourceNode) {
      sourceNode.checked ? controlSourceMapState.selected.add(sourceNode.dataset.controlSourceNode) : controlSourceMapState.selected.delete(sourceNode.dataset.controlSourceNode);
      renderControlSourceMappingTree();
    }
  });
  document.addEventListener("change", event => {
    const floatingMenu = event.target.closest("[data-floating-checkbox-menu]");
    if (!floatingMenu || !event.target.matches('input[type="checkbox"]')) return;
    const combo = document.querySelector(`[data-checkbox-combo][data-combo-id="${floatingMenu.dataset.comboId || ""}"]`);
    if (combo) updateCheckboxCombo(combo);
  });
  document.addEventListener("input", event => {
    const floatingSearch = event.target.closest("[data-floating-checkbox-menu] .checkbox-combo-search");
    if (!floatingSearch) return;
    const combo = document.querySelector(`[data-checkbox-combo][data-combo-id="${floatingSearch.closest("[data-floating-checkbox-menu]")?.dataset.comboId || ""}"]`);
    if (combo) filterCheckboxCombo(combo, floatingSearch.value);
  });
  rows.addEventListener("click", event => {
    const trigger = event.target.closest("[data-menu-trigger]");
    if (trigger) {
      openActionMenu(trigger);
      return;
    }
    // Obligation name link → View Obligation Details side panel (Practice-Obligation Mapping list).
    const obligationLink = event.target.closest("[data-obligation-view]");
    if (obligationLink) {
      event.preventDefault();
      openObligationDetailsPanel(obligationLink.dataset.obligationView);
      return;
    }
    const button = event.target.closest("[data-action]");
    if (!button) {
      const toggle = event.target.closest("[data-tree-toggle]");
      if (toggle && (cmScreen.Key === "source-structure" || cmScreen.Key === "framework-statements" || cmScreen.Key === "obligations" || cmScreen.Key === "obligation-mappings" || cmScreen.Key === "change-management" || cmScreen.Key === "audit-trace")) {
        const id = toggle.dataset.treeToggle;
        state.collapsed.has(id) ? state.collapsed.delete(id) : state.collapsed.add(id);
        rows.innerHTML = renderRows();
        updateGridPager();
        return;
      }
      const authorityRow = event.target.closest("[data-authority-id]");
      if (authorityRow && cmScreen.Key === "authorities") drillDownToArtifacts(state.records.find(row => String(row.Id) === authorityRow.dataset.authorityId) || {}).catch(error => alert(error.message));
      const artifactRow = event.target.closest("[data-artifact-id]");
      if (artifactRow && cmScreen.Key === "artifacts") drillDownToReleases(state.records.find(row => String(row.Id) === artifactRow.dataset.artifactId) || {}).catch(error => alert(error.message));
      const releaseRow = event.target.closest("[data-release-id]");
      if (releaseRow && cmScreen.Key === "releases") drillDownToSourceStructure(state.records.find(row => String(row.Id) === releaseRow.dataset.releaseId) || {}).catch(error => alert(error.message));
      return;
    }
    performAction(button);
  });
  window.addEventListener("resize", () => document.querySelectorAll("[data-checkbox-combo].open").forEach(positionCheckboxCombo));
  window.addEventListener("scroll", () => document.querySelectorAll("[data-checkbox-combo].open").forEach(positionCheckboxCombo), true);
  rows.addEventListener("keydown", event => {
    if (event.key !== "Enter" && event.key !== " ") return;
    const authorityRow = event.target.closest("[data-authority-id]");
    const artifactRow = event.target.closest("[data-artifact-id]");
    const releaseRow = event.target.closest("[data-release-id]");
    if ((!authorityRow && !artifactRow && !releaseRow) || event.target.closest(".row-actions")) return;
    event.preventDefault();
    if (authorityRow && cmScreen.Key === "authorities") drillDownToArtifacts(state.records.find(row => String(row.Id) === authorityRow.dataset.authorityId) || {}).catch(error => alert(error.message));
    if (artifactRow && cmScreen.Key === "artifacts") drillDownToReleases(state.records.find(row => String(row.Id) === artifactRow.dataset.artifactId) || {}).catch(error => alert(error.message));
    if (releaseRow && cmScreen.Key === "releases") drillDownToSourceStructure(state.records.find(row => String(row.Id) === releaseRow.dataset.releaseId) || {}).catch(error => alert(error.message));
  });
  document.addEventListener("click", event => {
    const floatingComboMenu = event.target.closest("[data-floating-checkbox-menu]");
    if (floatingComboMenu) {
      const combo = document.querySelector(`[data-checkbox-combo][data-combo-id="${floatingComboMenu.dataset.comboId || ""}"]`);
      const option = event.target.closest('input[type="checkbox"]');
      if (combo && option) updateCheckboxCombo(combo);
      return;
    }
    const action = event.target.closest(".action-menu [data-action]");
    if (action) { performAction(action); return; }
    if (!event.target.closest(".row-actions") && !event.target.closest(".action-menu")) closeMenus();
    if (!event.target.closest("[data-checkbox-combo]")) closeCheckboxCombos();
  });
  document.addEventListener("keydown", event => { if (event.key === "Escape") { closeMenus(); closeCheckboxCombos(); } });
  window.addEventListener("resize", closeMenus);
  window.addEventListener("scroll", closeMenus, true);
  // Render the source-control-mappings tree shell up front so the screen never
  // stays stuck on the standard grid's "Loading..." placeholder while lookups
  // are in flight.  Any failure during initSourceControlMappings is surfaced
  // inline instead of leaving the panel blank.
  if (cmScreen.Key === "source-control-mappings") {
    try { sourceMapShell(); }
    catch (error) { rows.innerHTML = `<tr><td colspan="${cmScreen.Columns.length + 1}" class="empty">${escapeHtml(error.message || "Unable to render mapping screen.")}</td></tr>`; }
  }
  loadLookups().then(async () => {
    if (cmScreen.Key === "source-control-mappings") { await initSourceControlMappings(); return; }
    await loadNavigationContext();
    populateStatusFilter();
    populateAuthorityFilter();
    populateArtifactFilter();
    populateReleaseFilter();
    if (statementScopedAreas.has(cmScreen.Key)) await refreshFrameworkStatementReleases();
    refreshAddButtonLabel();
    await load();
  }).catch(error => {
    if (cmScreen.Key === "source-control-mappings") {
      const host = document.querySelector("#sourceMapMessage");
      if (host) { host.textContent = error.message || "Failed to load lookups."; host.hidden = false; }
      else rows.innerHTML = `<tr><td colspan="${cmScreen.Columns.length + 1}" class="empty">${escapeHtml(error.message)}</td></tr>`;
      return;
    }
    rows.innerHTML = `<tr><td colspan="${cmScreen.Columns.length + 1}" class="empty">${escapeHtml(error.message)}</td></tr>`;
  });
})();
