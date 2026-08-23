/*
  Obligation Master -- merged full-page form (Phase 3).

  Replaces the previous two-step flow:
      Obligation Master (generic dialog)  ->  Manage Obligation Type Details (page)

  Everything an obligation IS now lives on one page and saves in one click:
      * master fields      (name, description, execution frequency, retention, keywords, status)
      * taxonomy type      (one of the 7 atomic types)
      * typed detail       (fields specific to that type)
      * evidence details   (master-owned specs)
      * evidence links     (M:M attachments to specs owned elsewhere)

  Save posts ONE payload to the 'obligation-composite' entity type.  Under
  maker-checker that dispatcher emits one change_management row per
  sub-entity, tied together by a bundle_id and approved atomically -- so the
  checker can never approve the master while rejecting its typed detail.
  See migrations 031 / 032.

  Reads still use the per-entity GET endpoints ('obligations',
  'obligation-<type>', 'obligation-evidence-links') -- there is deliberately
  no composite read.

  TYPE_SCHEMA below mirrors the SP contract in cm_manage_obligation_taxonomy.
  Keep the two in sync when adding fields.
*/
(function () {
    const ctx = window.cmObligationMasterForm || {};
    const api = (ctx.api || "").replace(/\/$/, "");
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || "";
    // Resolved against the application root (see gracUrl in site.js).
    const appUrl = path => window.gracUrl.app(path);
    const readonly = ctx.mode === "view";

    const message        = document.querySelector("#omfMessage");
    const nameInput      = document.querySelector("#omf-name");
    // Execution Frequency has no common control any more (see the note in
    // ObligationMasterForm.cshtml).  This is now a hidden input: it carries the
    // value loaded from the server and, for an Execution obligation, mirrors
    // whatever the typed panel's Execution Frequency is set to.
    const execFreqField  = document.querySelector("#omf-execution-frequency");
    const retentionInput = document.querySelector("#omf-retention");
    const keywordsInput  = document.querySelector("#omf-keywords");
    // Obligation Description -- bound to requirement_obligation.obligation_text.
    // Replaced the Remarks box in migration 055; remarks is a back-end column
    // now and this form neither reads nor posts it.
    const descriptionInput = document.querySelector("#omf-description");
    const statusSelect   = document.querySelector("#omf-status");
    const typeSelect     = document.querySelector("#omf-type");
    const typeDescription= document.querySelector("#omf-type-description");
    const typedWrap      = document.querySelector("#omf-typed-detail-wrap");
    const typedHeading   = document.querySelector("#omf-typed-heading");
    const typedSubheading= document.querySelector("#omf-typed-subheading");
    const typedFields    = document.querySelector("#omf-typed-fields");
    const typeChip       = document.querySelector("#omf-type-chip");
    const evidenceNote   = document.querySelector("#omf-evidence-type-note");
    const evidenceBody   = document.querySelector("#omf-evidence-body");
    const addEvidenceBtn = document.querySelector("#omfAddEvidence");
    // Source Statement Mapping (056).
    const statementTreeHost   = document.querySelector("#omfStatementTree");
    const statementSearchBox  = document.querySelector("#omfStatementSearch");
    const statementCountLabel = document.querySelector("#omfStatementCount");
    const saveBtn        = document.querySelector("#omfSave");
    const cancelBtn      = document.querySelector("#omfCancel");
    const confirmHost    = document.querySelector("#omfConfirm");
    const confirmBody    = document.querySelector("#omfConfirmBody");
    const confirmAccept  = document.querySelector("#omfConfirmAccept");

    // Per-type field schemas.  Mirrors dbo.cm_manage_obligation_taxonomy.
    // 'Evidence' is intentionally absent: standalone Evidence obligations
    // carry no typed-detail row, they express themselves through the
    // master-owned Evidence Details grid.
    //
    // ---- `hidden: true` ------------------------------------------------
    // A field retired from the UI but KEPT in the schema.  It is never drawn,
    // never required, and never blocks Save -- but its stored value is still
    // read on load and written straight back on save.
    //
    // Deleting the entry instead would destroy data.  Every
    // sp_cm_obligation_<type>_save assigns every column on UPDATE rather than
    // COALESCEing them, so a field the form stops sending is written back as
    // NULL.  A plain deletion would therefore wipe that column on the next
    // edit of every existing obligation of that type -- silently, and only
    // for the records someone happened to re-save, which is the worst
    // possible distribution for a data loss.
    //
    // `hidden` is NOT the same as `showWhen` returning false.  showWhen means
    // "this no longer applies, clear it" and DOES send NULL (the Assurance
    // cascade depends on that).  hidden means "the form no longer asks, keep
    // what is stored".  See buildTypedDetailPayload.
    //
    // To genuinely retire a column: drop the entry here AND write a migration
    // that nulls it, so the intent is recorded rather than inferred from
    // whoever edited last.
    const TYPE_SCHEMA = {
        State: {
            heading: "State Rule",
            subheading: "Positive parametric assertion (e.g. password.length >= 12).",
            fields: [
                { name: "attribute", label: "Attribute", type: "text", required: true, hint: "e.g. password.length" },
                { name: "operator",  label: "Operator",  type: "text", required: true, hint: "e.g. >=, =, in, contains" },
                { name: "value",     label: "Value",     type: "text", required: true, hint: "e.g. 12, true, AES-256" },
                { name: "unit",      label: "Unit",      type: "text", hint: "e.g. characters, days" },
                { name: "tolerance", label: "Tolerance", type: "text" }
            ]
        },
        Execution: {
            heading: "Execution Spec",
            subheading: "What must be done and when.",
            fields: [
                { name: "action",               label: "Action",              type: "textarea", required: true, full: true },
                { name: "executionFrequencyId", label: "Execution Frequency", type: "reference", refGroup: "frequency-types" },
                { name: "dueWithin",            label: "Due Within",          type: "text", hint: "e.g. 30 days, quarter-end" },
                // Removed from the panel; see the `hidden: true` note above.
                { name: "triggerCondition",     label: "Trigger Condition",   type: "text", hidden: true },
                { name: "responsibleParty",     label: "Responsible Party",   type: "text", hidden: true }
            ]
        },
        // Assurance carries a cascade the other types do not:
        //   Trigger Mode -> (Scheduled ? Frequency : Domain -> Event)
        // `controls: true` re-renders the panel on change; `showWhen` decides
        // which half of the cascade is live.  Every option comes from a table
        // -- trigger modes from reference_option, domains and events from
        // event_type_master -- so a new domain is a data change, not a release.
        Assurance: {
            heading: "Assurance Spec",
            subheading: "What must be verified, and what triggers it.",
            fields: [
                { name: "verificationMethod", label: "Verification Method", type: "textarea", required: true, full: true },
                { name: "triggerMode",        label: "Trigger Mode",        type: "trigger-mode", required: true, controls: true,
                  hint: "Scheduled runs on a frequency; event driven runs each time the event occurs." },
                { name: "assuranceFrequencyId", label: "Assurance Frequency", type: "reference", refGroup: "frequency-types",
                  required: true, showWhen: () => triggerModeCode() === "Scheduled" },
                // Domain is a UI-only step: the server stores only the leaf
                // event, which already knows its parent.
                { name: "eventDomainId",      label: "Event Domain",        type: "event-domain", required: true, controls: true, transient: true,
                  showWhen: () => triggerModeCode() === "EventDriven" },
                { name: "eventTypeId",        label: "Event",               type: "event-leaf", required: true,
                  showWhen: () => triggerModeCode() === "EventDriven",
                  hint: "This assurance is raised every time the selected event occurs." },
                // Interval, not a date: the rule applies to every future
                // occurrence, so the runtime layer resolves this against the
                // event date into a concrete due date per checklist item.
                { name: "slaDays",            label: "Due Within (days)",   type: "number",
                  showWhen: () => triggerModeCode() === "EventDriven",
                  hint: "Days after the event to complete this. Leave blank for no deadline." },
                // Removed from the panel; see the `hidden: true` note above.
                { name: "scope",              label: "Scope",               type: "text", hidden: true },
                { name: "assuranceParty",     label: "Assurance Party",     type: "text", hidden: true }
            ]
        },
        EventResponse: {
            heading: "Event Response",
            subheading: "If X occurs, do Y within SLA.",
            fields: [
                { name: "triggerEvent",   label: "Trigger Event",   type: "textarea", required: true, full: true },
                { name: "responseAction", label: "Response Action", type: "textarea", required: true, full: true },
                { name: "slaValue",       label: "SLA Value",       type: "number" },
                { name: "slaUnit",        label: "SLA Unit",        type: "select", options: ["", "Hours", "Days", "Weeks", "Months", "Years"] },
                // Removed from the panel; see the `hidden: true` note above.
                { name: "escalationPath", label: "Escalation Path", type: "text", hidden: true }
            ]
        },
        Constraint: {
            heading: "Constraint Rule",
            subheading: "A prohibition -- what must never be true.",
            fields: [
                { name: "prohibitedCondition", label: "Prohibited Condition", type: "textarea", required: true, full: true },
                // Removed from the panel; see the `hidden: true` note above.
                // Constraint is left with a single visible field, which is
                // fine: a prohibition IS the condition, and the panel heading
                // already says so.
                { name: "scope",               label: "Scope",                type: "text", hidden: true },
                { name: "exceptionPolicy",     label: "Exception Policy",     type: "text", hidden: true }
            ]
        },
        Retention: {
            heading: "Retention Spec",
            subheading: "What must be preserved and for how long.",
            fields: [
                { name: "retainedObject",    label: "Retained Object",     type: "text", required: true, hint: "e.g. audit_log, contract_pdf" },
                { name: "minRetentionValue", label: "Min Retention Value", type: "number" },
                { name: "minRetentionUnit",  label: "Min Retention Unit",  type: "select", options: ["", "Days", "Weeks", "Months", "Years"] },
                { name: "maxRetentionValue", label: "Max Retention Value", type: "number" },
                { name: "maxRetentionUnit",  label: "Max Retention Unit",  type: "select", options: ["", "Days", "Weeks", "Months", "Years"] },
                { name: "disposalPolicy",    label: "Disposal Policy",     type: "text" }
            ]
        }
    };

    // ---- state -------------------------------------------------------
    let typeOptions       = [];
    let frequencyOptions  = [];
    let statusOptions     = [];
    let evidenceTypeOptions = [];
    // Assurance trigger cascade vocabulary (033).
    let triggerModeOptions = [];      // [{ value: code, label }]
    let eventTypes         = [];      // flat tree rows from event_type_master
    let evidenceRows      = [];   // [{ evidenceTypeId, frequencyId, retentionRequirement, remarks }]
    let currentTypeCode   = "";   // the type currently rendered
    let loadedTypeCode    = "";   // the type as loaded from the server
    let typedDetailId     = 0;
    let typedDetailValues = {};
    let evidenceSeq       = 0;

    // ---- Source Statement Mapping state (056) ------------------------
    // statementNodes  -- Source Structure folders, from 'source-structure'.
    // statementRows   -- every Framework Statement with an IsMapped flag,
    //                    from 'obligation-statement-mappings'.
    // statementSelected is the live selection and the ONLY thing Save reads;
    // IsMapped on statementRows is just the server's starting position, left
    // untouched so a re-render never has to guess what the user changed.
    let statementNodes    = [];
    let statementRows     = [];
    let statementSelected = new Set();      // Set<string frameworkStatementId>
    const statementCollapsed = new Set();   // Set<string node key>, collapsed folders

    // ---- Similar Obligations (duplicate detection) -------------------
    // Ported from the shared dialog's similarConfigs["obligations"] wiring.
    // Warn-only: surfaces existing obligations that share the keywords being
    // typed so the maker can spot a duplicate before saving.  Never blocks Save.
    const SIMILAR = {
        hostId: "similarObligations",
        entity: "obligations-similar",
        title: "Similar Obligations Found",
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
    };
    let similarRecords     = [];
    let similarKeywords    = [];
    let similarQuickFilter = "";
    let similarSort        = { key: "MatchCount", direction: "desc" };
    let similarTimer       = null;

    init().catch(error => showError(error.message));

    async function init() {
        await Promise.all([loadTypes(), loadLookups(), loadEventTypes()]);

        if (ctx.obligationId) await loadObligation(ctx.obligationId);

        renderEvidence();

        // Independent of the obligation load above: the tree is the same for a
        // new obligation, it just starts with nothing ticked.  Failing to read
        // it must not take the whole form down -- the maker can still save
        // everything else -- so loadStatementMap swallows into an inline
        // message of its own.
        await loadStatementMap();

        // Duplicate detection: run once on open (so an edited record with saved
        // keywords shows its peers immediately) and on every keystroke after.
        scheduleSimilarRefresh();

        if (!readonly) {
            keywordsInput.addEventListener("input", scheduleSimilarRefresh);
            typeSelect.addEventListener("change", onTypeChanged);
            addEvidenceBtn?.addEventListener("click", () => {
                evidenceRows.push({ key: `new-${evidenceSeq++}`, evidenceTypeId: "", frequencyId: "", retentionRequirement: "", remarks: "" });
                renderEvidence();
            });
            saveBtn?.addEventListener("click", save);
        }
        cancelBtn.addEventListener("click", goBack);

        confirmHost.addEventListener("click", event => {
            if (event.target.closest("[data-confirm-dismiss]")) dismissConfirm(false);
        });
    }

    // ---- plumbing ----------------------------------------------------
    function buildBaseUrl() { return api || "/control-management-gateway"; }

    async function fetchJson(url, init = {}) {
        const response = await fetch(url, { credentials: "same-origin", ...init });
        const text = await response.text();
        const data = text ? safeParse(text) : {};
        if (!response.ok || data?.success === false) {
            throw new Error(data?.message || data?.error || text || `HTTP ${response.status}`);
        }
        return data;
    }
    function safeParse(text) { try { return JSON.parse(text); } catch { return null; } }
    function apiRows(result) { return result?.data?.[0] || result?.Data?.[0] || []; }

    async function fetchRows(entity, params = {}) {
        const query = Object.entries(params)
            .filter(([, v]) => v !== undefined && v !== null && v !== "")
            .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
            .join("&");
        return apiRows(await fetchJson(`${buildBaseUrl()}/${entity}${query ? `?${query}` : ""}`));
    }

    // ---- lookups -----------------------------------------------------
    // Retired Obligation Types.  Both are cross-cutting concerns, not kinds of
    // obligation, and neither is a valid choice on this form:
    //   * Evidence  -- every type attaches evidence through the master-owned
    //                  Evidence Details grid, so a standalone Evidence
    //                  obligation is a duplicate way to say the same thing.
    //   * Retention -- retention is captured by the Retention Period field.
    // Filtered here rather than deactivated in obligation_type_master so that
    // records already saved under either code still read back correctly; see
    // the reinstate branch below.
    const RETIRED_TYPE_CODES = new Set(["Evidence", "Retention"]);

    async function loadTypes() {
        const rows = await fetchRows("obligation-types");
        const seen = new Set();
        typeOptions = rows.map(r => ({
            code: String(r.TypeCode ?? r.typeCode ?? ""),
            name: String(r.TypeName ?? r.typeName ?? ""),
            description: String(r.Description ?? r.description ?? "")
        })).filter(t => t.code && !seen.has(t.code) && seen.add(t.code))
           .filter(t => !RETIRED_TYPE_CODES.has(t.code));
        renderTypeOptions();
    }

    // Kept separate from loadTypes so an existing obligation saved under a
    // retired type can put its own code back on the list before the form binds
    // to it -- dropping the option would silently blank the field on edit.
    function renderTypeOptions() {
        typeSelect.innerHTML = `<option value="">-- Select Type --</option>` + typeOptions
            .map(t => `<option value="${escapeHtml(t.code)}">${escapeHtml(t.name)}</option>`).join("");
    }

    function reinstateRetiredType(code) {
        if (!code || !RETIRED_TYPE_CODES.has(code)) return;
        if (typeOptions.some(t => t.code === code)) return;
        typeOptions.push({ code, name: `${code} (retired)`, description: "This obligation type is no longer offered for new records." });
        renderTypeOptions();
    }

    // One /lookups round-trip serves frequency, status and evidence-type
    // options -- the endpoint returns every group in a single result set
    // keyed by LookupKey.
    async function loadLookups() {
        const rows = apiRows(await fetchJson(`${buildBaseUrl()}/lookups`));
        // De-duplicated on Value.  /lookups is a UNION of branches and a
        // catch-all over reference_option, so a group can legitimately come
        // back twice (an older deployment of cm_get_reference_data, or a
        // duplicate reference_option row entered through admin).  Trigger Mode
        // showed Scheduled / Event Driven twice for exactly this reason.
        // Filtering here fixes every group at once instead of one dropdown.
        const byKey = key => {
            const seen = new Set();
            return rows
                .filter(r => String(r.LookupKey ?? r.lookupKey ?? "").toLowerCase() === key)
                .map(r => ({ value: String(r.Value ?? r.value ?? ""), label: String(r.Label ?? r.label ?? "") }))
                .filter(o => o.value && !seen.has(o.value) && seen.add(o.value));
        };

        frequencyOptions = byKey("frequency-master");
        if (frequencyOptions.length === 0) frequencyOptions = byKey("frequency-types");
        statusOptions = byKey("status-active");
        if (statusOptions.length === 0) statusOptions = [{ value: "Active", label: "Active" }, { value: "Inactive", label: "Inactive" }];
        evidenceTypeOptions = byKey("evidence-types");

        // The lookup value IS the stable code ('Scheduled' / 'EventDriven') --
        // obligation_assurance_spec stores the code rather than an FK, because
        // a CHECK constraint cannot resolve a foreign key (see migration 033).
        // The label is free to be renamed in admin without breaking the cascade.
        triggerModeOptions = byKey("assurance-trigger-modes");

        statusSelect.innerHTML = statusOptions
            .map(o => `<option value="${escapeHtml(o.value)}">${escapeHtml(o.label)}</option>`).join("");
        statusSelect.value = "Active";
    }

    // ---- event taxonomy (033) ----------------------------------------
    // One flat read; the cascade is derived client-side from
    // ParentEventTypeId so a single call serves every level.
    async function loadEventTypes() {
        try {
            const rows = await fetchRows("event-types");
            eventTypes = rows.map(r => ({
                id: String(r.EventTypeId ?? r.Id ?? ""),
                parentId: r.ParentEventTypeId === null || r.ParentEventTypeId === undefined
                    ? "" : String(r.ParentEventTypeId),
                code: String(r.EventCode ?? ""),
                name: String(r.EventName ?? ""),
                subjectEntity: String(r.SubjectEntity ?? ""),
                isDomain: r.IsDomain === true || r.IsDomain === 1 || String(r.IsDomain) === "1"
            })).filter(e => e.id);
        } catch { eventTypes = []; }
    }

    function eventDomains() {
        return eventTypes.filter(e => e.isDomain);
    }
    function eventLeaves(domainId) {
        if (!domainId) return [];
        return eventTypes.filter(e => !e.isDomain && e.parentId === String(domainId));
    }
    // Current trigger mode as its stable code, not its label.
    function triggerModeCode() {
        // The stored value is already the code, so no id -> code resolution.
        return String(typedDetailValues.triggerMode ?? "");
    }

    // ---- load existing obligation ------------------------------------
    async function loadObligation(id) {
        const rows = await fetchRows("obligations", { id, status: "" });
        const ob = rows[0] || {};

        nameInput.value      = ob.ObligationName ?? ob.obligationName ?? "";
        execFreqField.value  = String(ob.ExecutionFrequencyId ?? ob.executionFrequencyId ?? "");
        retentionInput.value = ob.RetentionPeriod ?? ob.RetentionRequirement ?? ob.retentionRequirement ?? "";
        keywordsInput.value  = ob.Keywords ?? ob.keywords ?? "";
        descriptionInput.value = ob.ObligationText ?? ob.obligationText ?? "";
        statusSelect.value   = ob.Status ?? ob.status ?? "Active";

        evidenceRows = parseJsonArray(ob.EvidenceRequirementsJson ?? ob.evidenceRequirementsJson)
            .map(e => ({
                key: `existing-${evidenceSeq++}`,
                evidenceTypeId: String(e.EvidenceTypeId ?? e.evidenceTypeId ?? ""),
                frequencyId: String(e.FrequencyId ?? e.frequencyId ?? ""),
                retentionRequirement: e.RetentionRequirement ?? e.retentionRequirement ?? "",
                remarks: e.Remarks ?? e.remarks ?? ""
            }));

        const typeCode = String(ob.TypeCode ?? ob.typeCode ?? "");
        if (typeCode) {
            reinstateRetiredType(typeCode);
            typeSelect.value = typeCode;
            currentTypeCode = typeCode;
            loadedTypeCode  = typeCode;
            await loadTypedDetail(id, typeCode);
        }
        renderTypedDetail();
    }

    async function loadTypedDetail(obligationId, typeCode) {
        const entity = typeEntity(typeCode);
        if (!entity) { typedDetailValues = {}; typedDetailId = 0; return; }
        try {
            // NOTE: the parent obligation is passed as `id`, not `obligationId`.
            // RepositoryQuery has no ObligationId property, so an `obligationId`
            // query param is silently dropped before it ever reaches the
            // dispatcher.  cm_get_obligation_taxonomy falls back to @p_id for
            // exactly this reason (see 029's header).  Passing `obligationId`
            // here would make typed detail always load empty on edit.
            const rows = await fetchRows(entity, { id: obligationId });
            const row = rows[0] || {};
            typedDetailId = Number(row.Id ?? row.id ?? 0) || 0;
            typedDetailValues = {};
            (TYPE_SCHEMA[typeCode]?.fields || []).forEach(f => {
                const pascal = f.name.charAt(0).toUpperCase() + f.name.slice(1);
                const v = row[pascal] ?? row[f.name];
                typedDetailValues[f.name] = v === null || v === undefined ? "" : String(v);
            });
            // eventDomainId is a UI-only cascade step and is therefore not a
            // stored column.  The get proc returns the parent domain of the
            // saved event as EventDomainId so the first cascade level can be
            // pre-selected on edit; without this the Event dropdown would
            // render empty even though an event is saved.
            if (typeCode === "Assurance") {
                const domain = row.EventDomainId ?? row.eventDomainId;
                typedDetailValues.eventDomainId =
                    domain === null || domain === undefined ? "" : String(domain);
            }
        } catch {
            typedDetailValues = {};
            typedDetailId = 0;
        }
    }

    function typeEntity(typeCode) {
        return ({
            State: "obligation-state",
            Execution: "obligation-execution",
            Assurance: "obligation-assurance",
            EventResponse: "obligation-event-response",
            Constraint: "obligation-constraint",
            Retention: "obligation-retention"
        })[typeCode] || null;
    }

    // ---- type change (with discard confirmation) ---------------------
    let confirmResolver = null;

    function onTypeChanged() {
        const next = String(typeSelect.value || "");
        const previous = currentTypeCode;

        // Nothing authored yet, or no real change -> switch silently.
        const hasAuthoredDetail = previous
            && TYPE_SCHEMA[previous]
            && Object.values(typedDetailValues).some(v => String(v ?? "").trim() !== "");

        if (!previous || next === previous || !hasAuthoredDetail) {
            currentTypeCode = next;
            typedDetailValues = {};
            typedDetailId = 0;
            renderTypedDetail();
            return;
        }

        // Authored detail exists and the type is genuinely changing --
        // confirm, because the old typed-detail row is discarded.
        askConfirm(previous, next).then(accepted => {
            if (!accepted) {
                typeSelect.value = previous;   // revert the dropdown
                return;
            }
            currentTypeCode = next;
            typedDetailValues = {};
            typedDetailId = 0;               // 0 => the SP inserts a fresh row
            renderTypedDetail();
        });
    }

    function askConfirm(previousCode, nextCode) {
        const prevLabel = TYPE_SCHEMA[previousCode]?.heading || previousCode;
        const nextLabel = typeOptions.find(t => t.code === nextCode)?.name || nextCode || "none";
        confirmBody.textContent =
            `The ${prevLabel} detail you have entered will be discarded when this obligation `
            + `becomes "${nextLabel}". This cannot be undone once you save.`;
        confirmHost.hidden = false;
        confirmHost.classList.add("is-open");
        return new Promise(resolve => {
            confirmResolver = resolve;
            confirmAccept.onclick = () => dismissConfirm(true);
        });
    }

    function dismissConfirm(accepted) {
        confirmHost.classList.remove("is-open");
        confirmHost.hidden = true;
        const resolve = confirmResolver;
        confirmResolver = null;
        if (resolve) resolve(accepted);
    }

    // ---- typed detail rendering --------------------------------------
    function renderTypedDetail() {
        const schema = TYPE_SCHEMA[currentTypeCode];
        const selected = typeOptions.find(t => t.code === currentTypeCode);
        // Inline hint under the Type select -- empty when nothing is chosen so
        // the row keeps its natural height on a fresh form.
        if (typeDescription) typeDescription.textContent = selected?.description || "";

        // 'Evidence' (and no selection) have no typed-detail form.
        evidenceNote.hidden = currentTypeCode !== "Evidence";

        if (!schema) {
            typedWrap.hidden = true;
            typedFields.innerHTML = "";
            return;
        }

        typedWrap.hidden = false;
        typedHeading.textContent = schema.heading;
        typedSubheading.textContent = schema.subheading;
        // Name the type driving this panel so the dependency on the Type
        // dropdown is stated, not inferred.
        if (typeChip) {
            const label = selected?.name || currentTypeCode;
            typeChip.innerHTML = `<i class="fa-solid fa-tag" aria-hidden="true"></i> ${escapeHtml(label)}`;
            typeChip.hidden = false;
        }
        // Two independent reasons a field is not drawn:
        //   hidden   -- retired from the UI for good, but still carried in the
        //               payload so its stored value survives an edit.
        //   showWhen -- the Assurance cascade: only the live half of
        //               Scheduled-vs-EventDriven is rendered at any time.
        // Only showWhen affects what the payload sends (see
        // buildTypedDetailPayload); hidden fields are sent as they were loaded.
        const visible = schema.fields.filter(f =>
            !f.hidden && (typeof f.showWhen !== "function" || f.showWhen()));
        typedFields.innerHTML = visible.map(f => renderField(f)).join("");

        if (readonly) return;

        typedFields.querySelectorAll("[data-typed-field]").forEach(el => {
            const name = el.dataset.typedField;
            const field = schema.fields.find(f => f.name === name);
            const commit = () => { typedDetailValues[name] = el.value; };

            if (field?.controls) {
                // A controlling field changes which other fields exist, so it
                // re-renders the panel.  Clear whatever it invalidates first,
                // otherwise a stale event could survive a switch back to
                // Scheduled and trip the CHECK constraint on save.
                el.addEventListener("change", () => {
                    commit();
                    if (name === "triggerMode") {
                        const code = triggerModeCode();
                        if (code !== "EventDriven") {
                            typedDetailValues.eventDomainId = "";
                            typedDetailValues.eventTypeId = "";
                        }
                        if (code !== "Scheduled") typedDetailValues.assuranceFrequencyId = "";
                    }
                    if (name === "eventDomainId") typedDetailValues.eventTypeId = "";
                    renderTypedDetail();
                });
                return;
            }

            el.addEventListener("input", commit);
            el.addEventListener("change", commit);
        });
    }

    function renderField(field) {
        const value = typedDetailValues[field.name] ?? "";
        const dis = readonly ? " disabled" : "";
        const req = field.required ? ` <span class="required">*</span>` : "";
        const hint = field.hint ? `<span class="form-field-hint">${escapeHtml(field.hint)}</span>` : "";
        // 12-column grid: long-form inputs take the full row, everything else
        // sits three-to-a-row so a six-field type (Retention) fits in two rows
        // instead of six.
        const span = field.full || field.type === "textarea" ? 12 : 4;
        const cls = `form-field omf-span-${span}`;

        let control;
        if (field.type === "textarea") {
            control = `<textarea data-typed-field="${escapeHtml(field.name)}" rows="2"${dis}>${escapeHtml(value)}</textarea>`;
        } else if (field.type === "number") {
            control = `<input type="number" data-typed-field="${escapeHtml(field.name)}" value="${escapeHtml(value)}"${dis} />`;
        } else if (field.type === "select") {
            control = `<select data-typed-field="${escapeHtml(field.name)}"${dis}>`
                + (field.options || []).map(o =>
                    `<option value="${escapeHtml(o)}"${String(o) === String(value) ? " selected" : ""}>${escapeHtml(o || "-- Select --")}</option>`).join("")
                + `</select>`;
        } else if (field.type === "reference") {
            control = `<select data-typed-field="${escapeHtml(field.name)}"${dis}>`
                + `<option value="">-- Select --</option>`
                + frequencyOptions.map(o =>
                    `<option value="${escapeHtml(o.value)}"${o.value === String(value) ? " selected" : ""}>${escapeHtml(o.label)}</option>`).join("")
                + `</select>`;
        } else if (field.type === "trigger-mode") {
            control = optionSelect(field, value, triggerModeOptions, "-- Select Mode --", dis);
        } else if (field.type === "event-domain") {
            control = optionSelect(field, value,
                eventDomains().map(d => ({ value: d.id, label: d.name })),
                "-- Select Domain --", dis);
        } else if (field.type === "event-leaf") {
            // Depends on the domain chosen one step earlier in the cascade.
            const domainId = String(typedDetailValues.eventDomainId ?? "");
            const leaves = eventLeaves(domainId).map(l => ({ value: l.id, label: l.name }));
            control = optionSelect(field, value, leaves,
                domainId ? "-- Select Event --" : "-- Select a domain first --",
                domainId ? dis : " disabled");
        } else {
            control = `<input type="text" data-typed-field="${escapeHtml(field.name)}" value="${escapeHtml(value)}"${dis} />`;
        }

        return `<div class="${cls}">
            <span class="form-field-label">${escapeHtml(field.label)}${req}</span>
            ${control}${hint}
        </div>`;
    }

    // Shared <select> builder for the cascade field types.
    function optionSelect(field, value, options, placeholder, disabledAttr) {
        return `<select data-typed-field="${escapeHtml(field.name)}"${disabledAttr}>`
            + `<option value="">${escapeHtml(placeholder)}</option>`
            + options.map(o =>
                `<option value="${escapeHtml(o.value)}"${String(o.value) === String(value) ? " selected" : ""}>${escapeHtml(o.label)}</option>`).join("")
            + `</select>`;
    }

    // ---- evidence grid -----------------------------------------------
    // Columns: Evidence Type | Retention Period | Remarks | (actions).
    // Assurance Frequency used to sit between type and retention.  It was
    // removed because assurance cadence belongs to the obligation TYPE -- an
    // Assurance obligation states it on its typed-detail panel -- and asking
    // again per evidence row gave one fact two owners.  row.frequencyId stays
    // in the model and in the save payload so a value stored before this
    // change round-trips untouched instead of being silently cleared.
    function renderEvidence() {
        if (evidenceRows.length === 0) {
            evidenceBody.innerHTML = `<tr><td colspan="4" class="empty">No evidence rows yet.</td></tr>`;
            return;
        }
        const dis = readonly ? " disabled" : "";
        evidenceBody.innerHTML = evidenceRows.map((row, index) => `
            <tr data-evidence-row="${index}">
                <td>
                    <select data-ev-field="evidenceTypeId" data-ev-row="${index}"${dis}>
                        <option value="">-- Select --</option>
                        ${evidenceTypeOptions.map(o =>
                            `<option value="${escapeHtml(o.value)}"${o.value === String(row.evidenceTypeId) ? " selected" : ""}>${escapeHtml(o.label)}</option>`).join("")}
                    </select>
                </td>
                <td><input type="text" data-ev-field="retentionRequirement" data-ev-row="${index}" value="${escapeHtml(row.retentionRequirement || "")}"${dis} /></td>
                <td><input type="text" data-ev-field="remarks" data-ev-row="${index}" value="${escapeHtml(row.remarks || "")}"${dis} /></td>
                <td class="omf-ev-actions">
                    ${readonly ? "" : `<button type="button" class="omf-ev-remove" data-ev-remove="${index}" aria-label="Remove evidence row">&times;</button>`}
                </td>
            </tr>`).join("");

        if (readonly) return;
        evidenceBody.querySelectorAll("[data-ev-field]").forEach(el => {
            const handler = () => {
                const idx = Number(el.dataset.evRow);
                if (evidenceRows[idx]) evidenceRows[idx][el.dataset.evField] = el.value;
            };
            el.addEventListener("input", handler);
            el.addEventListener("change", handler);
        });
        evidenceBody.querySelectorAll("[data-ev-remove]").forEach(btn => {
            btn.addEventListener("click", () => {
                evidenceRows.splice(Number(btn.dataset.evRemove), 1);
                renderEvidence();
            });
        });
    }

    // ---- Source Statement Mapping (056) ------------------------------
    //
    // A deliberate port of the Practice form's Framework Statement Mapping
    // tree (repository.js: initRequirementControlMapping and friends) rather
    // than a new control.  The two screens map the same statements for the
    // same reason, so they use the same markup, the same .req-tree-* classes
    // out of repository-actions.css, and the same Release -> Source Structure
    // -> Statement shape.  Copied rather than shared because repository.js is
    // an IIFE over the generic list/dialog screens with no export surface;
    // extracting a module for it is worth doing, but not inside this change.

    async function loadStatementMap() {
        if (!statementTreeHost) return;
        statementTreeHost.innerHTML = `<div class="similar-empty">Loading framework statements...</div>`;
        try {
            const [nodes, rows] = await Promise.all([
                fetchRows("source-structure", { status: "" }),
                fetchRows("obligation-statement-mappings", { id: ctx.obligationId || 0, status: "" })
            ]);
            // Retired / inactive folders are dropped, matching the Practice
            // tree: a statement under a retired node is not something a maker
            // should be picking up for new work.
            statementNodes = nodes.filter(node =>
                !["inactive", "retired"].includes(String(node.Status || "").toLowerCase()));
            statementRows = rows;
            statementSelected = new Set(rows.filter(isMappedRow).map(statementId));
        } catch (error) {
            statementNodes = [];
            statementRows = [];
            statementTreeHost.innerHTML =
                `<div class="similar-empty">${escapeHtml(error.message || "Could not load framework statements.")}</div>`;
            return;
        }
        renderStatementTree();

        // Search and collapse are wired in view mode too: a reviewer reading a
        // hundred-statement tree needs to narrow and fold it just as much as an
        // editor does, and neither changes anything they could save.  Only the
        // checkbox listener below is gated on readonly.
        statementSearchBox?.addEventListener("input", renderStatementTree);
        statementTreeHost.addEventListener("click", event => {
            const toggle = event.target.closest("[data-omf-node-toggle]");
            if (!toggle) return;
            event.preventDefault();
            const key = toggle.dataset.omfNodeToggle;
            if (statementCollapsed.has(key)) statementCollapsed.delete(key);
            else statementCollapsed.add(key);
            renderStatementTree();
        });

        if (readonly) return;
        // Delegated so the handler survives every re-render; the checkbox
        // writes straight into statementSelected, which is what Save reads.
        statementTreeHost.addEventListener("change", event => {
            const box = event.target.closest("[data-omf-statement]");
            if (!box) return;
            if (box.checked) statementSelected.add(String(box.value));
            else statementSelected.delete(String(box.value));
            updateStatementCount();
        });
    }

    function isMappedRow(row) {
        const value = row?.IsMapped ?? row?.isMapped;
        return value === true || value === 1 || value === "1" || String(value).toLowerCase() === "true";
    }
    function statementId(row) {
        return String(row?.FrameworkStatementId ?? row?.Id ?? "");
    }
    function statementLabel(row) {
        return row?.StatementTitle || row?.StatementText || "Framework Statement";
    }

    function updateStatementCount() {
        if (statementCountLabel) statementCountLabel.textContent = `${statementSelected.size} selected`;
    }

    // Authority and Release are not rows in source_structure_node -- they are
    // the artifact/release the node hangs off.  Synthesising them as folders
    // here gives the maker the same three-level context the Practice tree
    // shows, without the read having to return a second hierarchy.
    function statementHierarchy(nodes) {
        const records = [];
        const seenAuthority = new Set();
        const seenRelease = new Set();
        for (const node of nodes) {
            const authorityKey = `authority:${node.AuthorityId ?? "unknown"}`;
            if (!seenAuthority.has(authorityKey)) {
                seenAuthority.add(authorityKey);
                records.push({
                    Id: authorityKey, Reference: "", Title: node.Authority || "Authority",
                    ParentNodeId: null, IsAuthorityGroup: true
                });
            }
            const releaseKey = `release:${node.ReleaseId ?? "unknown"}`;
            if (!seenRelease.has(releaseKey)) {
                seenRelease.add(releaseKey);
                records.push({
                    Id: releaseKey,
                    Reference: node.ArtifactCode || "",
                    Title: [node.Artifact || "", node.Version || node.Release || ""].filter(Boolean).join(" / "),
                    ParentNodeId: authorityKey, IsReleaseGroup: true
                });
            }
            records.push({ ...node, ParentNodeId: node.ParentNodeId || releaseKey });
        }
        return records;
    }

    function buildStatementTree(records) {
        const map = new Map(records.map(row => [String(row.Id), { row, children: [] }]));
        const roots = [];
        map.forEach(node => {
            const parentId = String(node.row.ParentNodeId || "");
            // The self-parent guard is not paranoia: a bad import can point a
            // node at itself, and without it buildTree loops forever.
            if (parentId && map.has(parentId) && parentId !== String(node.row.Id))
                map.get(parentId).children.push(node);
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

    function flattenStatementTree(records) {
        const output = [];
        const walk = (items, depth) => items.forEach(item => {
            output.push({ row: item.row, depth, hasChildren: item.children.length > 0 });
            if (!statementCollapsed.has(String(item.row.Id))) walk(item.children, depth + 1);
        });
        walk(buildStatementTree(records), 0);
        return output;
    }

    // A search that matched only leaves would strand them under folders that
    // are no longer in the result set, so every ancestor of a match is kept.
    function includeStatementAncestors(records, ids) {
        const byId = new Map(records.map(row => [String(row.Id), row]));
        const keep = new Set(ids);
        ids.forEach(id => {
            let current = byId.get(String(id));
            while (current?.ParentNodeId) {
                keep.add(String(current.ParentNodeId));
                current = byId.get(String(current.ParentNodeId));
            }
        });
        return records.filter(row => keep.has(String(row.Id)));
    }

    function renderStatementTree() {
        if (!statementTreeHost) return;
        const search = String(statementSearchBox?.value || "").trim().toLowerCase();

        const rowsByNode = statementRows.reduce((map, row) => {
            const key = String(row.StructureNodeId || "");
            (map[key] ||= []).push(row);
            return map;
        }, {});

        const records = statementHierarchy(statementNodes);
        let visible = records;
        if (search) {
            const matched = new Set();
            for (const row of records) {
                const text = `${row.Authority || ""} ${row.Reference || ""} ${row.Title || ""} ${row.ArtifactCode || ""} ${row.Artifact || ""} ${row.Version || row.Release || ""}`.toLowerCase();
                if (text.includes(search)) matched.add(String(row.Id));
            }
            for (const row of statementRows) {
                const text = `${row.StatementReference || ""} ${row.StatementTitle || ""} ${row.StatementText || ""} ${row.ArtifactCode || ""} ${row.Release || ""}`.toLowerCase();
                if (text.includes(search)) matched.add(String(row.StructureNodeId || ""));
            }
            visible = includeStatementAncestors(records, matched);
        }

        const html = flattenStatementTree(visible).map(({ row, depth, hasChildren }) => {
            const nodeId = String(row.Id);
            const collapsed = statementCollapsed.has(nodeId);
            const toggle = hasChildren
                ? `<button type="button" class="req-tree-toggle" data-omf-node-toggle="${escapeHtml(nodeId)}"><i class="fa-solid fa-chevron-${collapsed ? "right" : "down"}"></i></button>`
                : `<span class="tree-toggle-spacer"></span>`;
            const folderIcon = row.IsAuthorityGroup ? "fa-building-columns"
                : row.IsReleaseGroup ? "fa-tags" : "fa-folder";
            const folderClass = row.IsAuthorityGroup ? " authority" : row.IsReleaseGroup ? " release" : "";
            const nodeRow = `<div class="req-tree-source${folderClass}" style="--tree-depth:${depth}">${toggle}<i class="fa-solid ${folderIcon}"></i><span><strong>${escapeHtml(row.Reference || "")}</strong>${row.Reference ? " - " : ""}${escapeHtml(row.Title || "")}</span></div>`;
            if (collapsed) return nodeRow;

            const leaves = (rowsByNode[nodeId] || [])
                .filter(statement => !search
                    || `${statement.StatementReference || ""} ${statement.StatementTitle || ""} ${statement.StatementText || ""} ${statement.ArtifactCode || ""} ${statement.Release || ""}`
                        .toLowerCase().includes(search))
                .map(statement => renderStatementRow(statement, depth + 1))
                .join("");
            return `${nodeRow}${leaves}`;
        }).join("");

        statementTreeHost.innerHTML = html || `<div class="similar-empty">No framework statements found.</div>`;
        updateStatementCount();
    }

    function renderStatementRow(statement, depth) {
        const id = statementId(statement);
        if (!id) return "";
        const checked = statementSelected.has(id);
        const reference = statement.StatementReference || "";
        return `<label class="req-tree-control req-tree-statement" style="--tree-depth:${depth}">`
            + `<input type="checkbox" value="${escapeHtml(id)}" data-omf-statement${checked ? " checked" : ""}${readonly ? " disabled" : ""}>`
            + `<i class="fa-solid fa-file-lines"></i>`
            + `<span><strong>${escapeHtml(reference)}</strong>${reference ? " - " : ""}${escapeHtml(statementLabel(statement))}</span>`
            + `${badge(checked ? "Mapped" : "Available")}</label>`;
    }

    // ---- save ---------------------------------------------------------
    async function save() {
        message.hidden = true;

        const name = String(nameInput.value || "").trim();
        if (!name) return showError("Obligation Name is required.");
        if (!currentTypeCode) return showError("Obligation Type is required.");

        const schema = TYPE_SCHEMA[currentTypeCode];
        if (schema) {
            // Only fields currently on screen can be required -- an Assurance
            // spec set to Scheduled must not be blocked on the Event dropdown
            // that the cascade has hidden, and nothing may block Save on a
            // `hidden` field the maker has no way to fill in.
            const missing = schema.fields
                .filter(f => !f.hidden && (typeof f.showWhen !== "function" || f.showWhen()))
                .filter(f => f.required && !String(typedDetailValues[f.name] ?? "").trim())
                .map(f => f.label);
            if (missing.length) return showError(`Complete the required fields: ${missing.join(", ")}.`);
        }

        // Evidence rows must at least name a type.
        const evidence = evidenceRows
            .filter(r => String(r.evidenceTypeId || "").trim())
            .map(r => ({
                evidenceTypeId: Number(r.evidenceTypeId),
                frequencyId: r.frequencyId ? Number(r.frequencyId) : null,
                retentionRequirement: r.retentionRequirement || null,
                remarks: r.remarks || null
            }));

        // Local duplicate guard -- the SP enforces this too, but failing
        // here gives the maker a faster, clearer message.
        //
        // The key used to be evidenceTypeId + frequencyId, because the same
        // Evidence Type was allowed to repeat at a different Assurance
        // Frequency.  Frequency is no longer captured here, so that escape
        // hatch is gone: an Evidence Type may appear once.  Keying on the pair
        // would now compare null against null on every row and reject the
        // second one with a message naming a field the form no longer shows.
        const seen = new Set();
        for (const e of evidence) {
            if (seen.has(e.evidenceTypeId))
                return showError("The same Evidence Type is listed more than once. Remove the duplicate row.");
            seen.add(e.evidenceTypeId);
        }

        // Execution Frequency is owned by the Execution typed panel now.  For an
        // Execution obligation the master column mirrors the typed value; every
        // other type keeps whatever was already stored (blank on a new record).
        const typedExecFreq = currentTypeCode === "Execution"
            ? String(typedDetailValues.executionFrequencyId ?? "")
            : String(execFreqField.value || "");

        const payload = {
            obligationName: name,
            executionFrequencyId: typedExecFreq ? Number(typedExecFreq) : null,
            retentionRequirement: retentionInput.value || null,
            obligationText: descriptionInput.value || null,
            keywords: String(keywordsInput.value || "")
                .split(",").map(s => s.trim()).filter(Boolean),
            status: statusSelect.value || "Active",
            evidenceRequirements: evidence,
            // Source Statement Mapping (056).  Always sent, including as an
            // empty array: the SP treats an absent key as "leave the map
            // alone" for older callers, so a maker who unticks every statement
            // must send [] to actually clear it.  Sorted numerically so an
            // unchanged selection produces an identical string and the
            // checker's field diff stays quiet.
            sourceStatements: [...statementSelected]
                .map(Number).filter(Number.isFinite).sort((a, b) => a - b),
            obligationTypeCode: currentTypeCode,
            typedDetailId: typedDetailId || 0,
            typedDetail: schema ? buildTypedDetailPayload(schema) : null
            // evidenceLinks is intentionally not sent.  The M:M evidence-reuse
            // section was removed before release (see the note in
            // ObligationMasterForm.cshtml).  cm_manage_obligation_composite
            // treats the key as optional, so omitting it is a no-op.
        };

        try {
            saveBtn.disabled = true;
            const result = await fetchJson(`${buildBaseUrl()}/obligation-composite`, {
                method: "POST",
                headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
                body: JSON.stringify({ id: ctx.obligationId || null, data: payload })
            });

            // The composite dispatcher reports whether the save applied
            // directly or was routed into an approval bundle.
            const row = apiRows(result)[0] || {};
            const status = String(row.Status ?? row.status ?? "");
            showSuccess(status === "Pending Approval"
                ? "Obligation submitted for approval. The master, type, detail and evidence will be approved together."
                : "Obligation saved.");
            setTimeout(goBack, 1200);
        } catch (error) {
            showError(error.message);
        } finally {
            saveBtn.disabled = false;
        }
    }

    // Numeric field types whose value is an id or a count, so the payload
    // carries a number rather than a string.
    const NUMERIC_FIELD_TYPES = new Set([
        "number", "reference", "event-domain", "event-leaf"
    ]);

    function buildTypedDetailPayload(schema) {
        const out = {};
        schema.fields.forEach(f => {
            // `transient` fields exist only to drive the cascade in the UI and
            // have no stored column -- eventDomainId is implied by the leaf
            // event, so sending it would be meaningless to the SP.
            if (f.transient) return;

            // A field the CASCADE has hidden must be sent as NULL, not with a
            // stale value.  Switching an Assurance spec from event-driven back
            // to scheduled has to clear the event, otherwise the row violates
            // ck_cm_assurance_spec_trigger.
            //
            // `f.hidden` is deliberately NOT consulted here.  A cascade-hidden
            // field means "this no longer applies, clear it"; a `hidden` field
            // means "the form no longer asks, keep what is stored".  Testing
            // showWhen only is what makes the second case work -- the value
            // loaded by loadTypedDetail is written straight back.
            const visible = typeof f.showWhen !== "function" || f.showWhen();
            const raw = visible ? typedDetailValues[f.name] : "";

            if (raw === undefined || raw === null || String(raw).trim() === "") {
                out[f.name] = null;
                return;
            }
            out[f.name] = NUMERIC_FIELD_TYPES.has(f.type) ? Number(raw) : raw;
        });
        return out;
    }

    // ---- Similar Obligations -----------------------------------------
    function tagList(value) {
        return Array.isArray(value)
            ? value.map(String).filter(Boolean)
            : String(value || "").split(",").map(s => s.trim()).filter(Boolean);
    }

    function similarValue(row, key) {
        return row?.[key] ?? row?.[key?.[0]?.toUpperCase() + key?.slice(1)] ?? "";
    }

    // Wrap keyword matches in <mark> AFTER escaping, so user input can never
    // inject markup.  Regex specials in keywords are escaped so "." or "*"
    // match literally.
    function highlightKeywords(text) {
        const escaped = escapeHtml(text ?? "");
        const keywords = similarKeywords.map(k => String(k || "").trim()).filter(Boolean);
        if (!escaped || !keywords.length) return escaped;
        const pattern = keywords.map(k => k.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");
        try {
            return escaped.replace(new RegExp(`(${pattern})`, "gi"),
                match => `<mark class="similar-highlight">${match}</mark>`);
        } catch { return escaped; }
    }

    function similarFiltered() {
        const quick = String(similarQuickFilter || "").trim().toLowerCase();
        const keys = SIMILAR.columns.map(([key]) => key);
        const rows = [...similarRecords].filter(row => !quick || keys.some(key =>
            String(similarValue(row, key) || "").toLowerCase().includes(quick)));
        rows.sort((a, b) => {
            const left = similarValue(a, similarSort.key);
            const right = similarValue(b, similarSort.key);
            const result = Number.isFinite(Number(left)) && Number.isFinite(Number(right))
                ? Number(left) - Number(right)
                : String(left || "").localeCompare(String(right || ""), undefined, { sensitivity: "base" });
            return similarSort.direction === "desc" ? -result : result;
        });
        return rows;
    }

    function renderSimilarRows() {
        const host = document.querySelector(`#${SIMILAR.hostId}`);
        if (!host) return;
        const rows = similarFiltered();
        const total = similarRecords.length;
        const count = host.querySelector("[data-similar-count]");
        if (count) count.textContent = `${rows.length} of ${total} record${total === 1 ? "" : "s"}`;
        const body = host.querySelector("[data-similar-body]");
        if (!body) return;
        body.innerHTML = rows.length
            ? rows.map(row => `<tr>${SIMILAR.columns.map(([key], columnIndex) => {
                const raw = similarValue(row, key);
                const display = raw === null || raw === undefined || raw === "" ? "-" : String(raw);
                if (key === "Status") return `<td>${badge(display)}</td>`;
                const cell = display === "-" ? "-" : highlightKeywords(display);
                return `<td title="${escapeHtml(display)}">${columnIndex === 0 ? `<strong>${cell}</strong>` : cell}</td>`;
              }).join("")}</tr>`).join("")
            : `<tr><td colspan="${SIMILAR.columns.length}" class="similar-empty-cell">No records match the current filters.</td></tr>`;

        host.querySelectorAll("[data-similar-sort]").forEach(button => {
            const icon = button.querySelector("i");
            if (!icon) return;
            icon.className = similarSort.key === button.dataset.similarSort
                ? `fa-solid fa-sort-${similarSort.direction === "desc" ? "down" : "up"}`
                : "fa-solid fa-sort";
        });
    }

    function renderSimilarGrid() {
        const host = document.querySelector(`#${SIMILAR.hostId}`);
        if (!host) return;
        if (!similarRecords.length) {
            host.innerHTML = `<div class="similar-empty">${escapeHtml(SIMILAR.emptyResult)}</div>`;
            return;
        }
        const sortIcon = key => similarSort.key === key
            ? `<i class="fa-solid fa-sort-${similarSort.direction === "desc" ? "down" : "up"}"></i>`
            : `<i class="fa-solid fa-sort"></i>`;
        host.innerHTML = `<div class="similar-grid-header">
                <div>
                    <div class="similar-title">${escapeHtml(SIMILAR.title)}</div>
                    <div class="similar-count" data-similar-count></div>
                    <div class="similar-warn">${escapeHtml(SIMILAR.warnMessage)}</div>
                </div>
                <div class="similar-toolbar">
                    <input type="search" class="similar-quick-filter" data-similar-quick-filter
                           placeholder="Search similar..." value="${escapeHtml(similarQuickFilter)}">
                </div>
            </div>
            <div class="similar-grid-wrap">
                <table class="similar-grid">
                    <thead>
                        <tr>${SIMILAR.columns.map(([key, label]) =>
                            `<th><button type="button" data-similar-sort="${escapeHtml(key)}">${escapeHtml(label)} ${sortIcon(key)}</button></th>`).join("")}</tr>
                    </thead>
                    <tbody data-similar-body></tbody>
                </table>
            </div>`;

        host.querySelector("[data-similar-quick-filter]")?.addEventListener("input", event => {
            similarQuickFilter = event.target.value;
            renderSimilarRows();
        });
        host.querySelectorAll("[data-similar-sort]").forEach(button => {
            button.addEventListener("click", () => {
                const key = button.dataset.similarSort;
                similarSort = similarSort.key === key
                    ? { key, direction: similarSort.direction === "desc" ? "asc" : "desc" }
                    : { key, direction: "desc" };
                renderSimilarRows();
            });
        });
        renderSimilarRows();
    }

    async function refreshSimilar() {
        const host = document.querySelector(`#${SIMILAR.hostId}`);
        if (!host) return;
        const keywords = tagList(keywordsInput.value);
        // No keywords -> collapse entirely so the form looks untouched.
        if (!keywords.length) {
            similarRecords = [];
            similarKeywords = [];
            host.hidden = true;
            host.innerHTML = "";
            return;
        }
        similarKeywords = keywords;
        host.hidden = false;
        // `id` excludes the record being edited from its own duplicate list.
        similarRecords = await fetchRows(SIMILAR.entity, {
            search: keywords.join(","),
            id: ctx.obligationId || 0
        });
        renderSimilarGrid();
    }

    function scheduleSimilarRefresh() {
        clearTimeout(similarTimer);
        similarTimer = setTimeout(() => refreshSimilar().catch(error => {
            const host = document.querySelector(`#${SIMILAR.hostId}`);
            if (host) {
                host.hidden = false;
                host.innerHTML = `<div class="similar-empty">${escapeHtml(error.message)}</div>`;
            }
        }), 300);
    }

    // ---- misc ---------------------------------------------------------
    // Status pill.  Identical to repository.js's helper (a plain .badge span)
    // so the similar-records grid renders exactly as it did on the old dialog.
    const badge = value => `<span class="badge">${escapeHtml(value)}</span>`;

    function goBack() {
        // ctx.returnUrl is Referer-derived.  It is honoured only when it points
        // inside THIS application -- an origin check alone would accept a page
        // from a sibling GRAC app on the same host and drop the user outside the
        // base URL.  The fallback is resolved against the application root.
        window.location.assign(window.gracUrl.safeReturn(ctx.returnUrl, "/Repository/Index?areaKey=obligations"));
    }
    function parseJsonArray(raw) {
        if (Array.isArray(raw)) return raw;
        if (!raw) return [];
        try { const x = JSON.parse(raw); return Array.isArray(x) ? x : []; } catch { return []; }
    }
    function showError(text) {
        message.textContent = text || "Something went wrong.";
        message.classList.remove("success"); message.classList.add("error");
        message.hidden = false;
        window.scrollTo({ top: 0, behavior: "smooth" });
    }
    function showSuccess(text) {
        message.textContent = text;
        message.classList.add("success"); message.classList.remove("error");
        message.hidden = false;
        window.scrollTo({ top: 0, behavior: "smooth" });
    }
    function escapeHtml(value) {
        return String(value ?? "").replace(/[&<>"']/g, ch =>
            ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
    }
})();
