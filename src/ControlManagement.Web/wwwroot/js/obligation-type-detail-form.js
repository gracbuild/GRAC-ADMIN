/*
  Obligation Type Detail (Phase 2C) -- companion page to Obligation Master.

  Flow:
    1. Page loads with the Obligation dropdown (all active masters) and Type
       dropdown (7 types).  If ctx.obligationId is set, that master is
       preselected and its currently-assigned type is loaded.
    2. Assign / Change Type -- writes obligation_type_id on the master via
       entityType='obligation-type-assignment'.
    3. Once a type is assigned, the typed-detail form section renders the
       fields specific to that type.  Save posts to the matching
       entityType='obligation-<type>'.
    4. Evidence Attachments section shows current links (unioned across all
       six per-type link tables) with Attach / Detach controls.  Uses
       entityType='obligation-evidence-links'.

  All server calls go through the same-origin gateway
  /control-management-gateway/{entity} so the browser never sees an API
  token; the gateway re-signs and encrypts requests before forwarding.
*/
(function () {
    const ctx = window.cmObligationTypeDetailForm || {};
    const api = (ctx.api || "").replace(/\/$/, "");
    // Resolved against the application root (see gracUrl in site.js).
    const appUrl = path => window.gracUrl.app(path);
    // Antiforgery header value -- pulled from the layout's <meta name="csrf-token">.
    // The gateway's Save endpoints carry [ValidateAntiForgeryToken] and reject
    // requests without this header with a 400.
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || "";
    const message = document.querySelector("#otdMessage");
    const obligationSelect = document.querySelector("#otd-obligation");
    const typeSelect = document.querySelector("#otd-type");
    const currentTypeLabel = document.querySelector("#otd-current-type-label");
    const assignTypeBtn = document.querySelector("#otdAssignType");
    const detailCard = document.querySelector("#otd-detail-card");
    const detailHeading = document.querySelector("#otd-detail-heading");
    const detailSubheading = document.querySelector("#otd-detail-subheading");
    const detailFields = document.querySelector("#otd-detail-fields");
    const saveDetailBtn = document.querySelector("#otdSaveDetail");
    const evidenceCard = document.querySelector("#otd-evidence-card");
    const evidenceSpecSelect = document.querySelector("#otd-evidence-spec");
    const evidenceRemarksInput = document.querySelector("#otd-evidence-remarks");
    const attachEvidenceBtn = document.querySelector("#otdAttachEvidence");
    const evidenceBody = document.querySelector("#otd-evidence-body");
    const cancelBtn = document.querySelector("#otdCancel");
    const readonly = ctx.mode === "view";

    // Per-type field schemas.  Field defs mirror the SP contract in
    // dbo.cm_manage_obligation_taxonomy -- keep in sync when adding fields.
    const TYPE_SCHEMA = {
        State: {
            heading: "State Rule",
            subheading: "Positive parametric assertion (e.g. password.length >= 12).",
            fields: [
                { name: "attribute",  label: "Attribute",  type: "text", required: true, hint: "e.g. password.length" },
                { name: "operator",   label: "Operator",   type: "text", required: true, hint: "e.g. >=, =, in, contains" },
                { name: "value",      label: "Value",      type: "text", required: true, hint: "e.g. 12, true, AES-256" },
                { name: "unit",       label: "Unit",       type: "text", hint: "e.g. characters, days" },
                { name: "tolerance",  label: "Tolerance",  type: "text" }
            ]
        },
        Execution: {
            heading: "Execution Spec",
            subheading: "What must be done and when.",
            fields: [
                { name: "action",             label: "Action",             type: "textarea", required: true },
                { name: "executionFrequencyId", label: "Execution Frequency", type: "reference", refGroup: "frequency-types" },
                { name: "triggerCondition",   label: "Trigger Condition",  type: "text" },
                { name: "responsibleParty",   label: "Responsible Party",  type: "text" },
                { name: "dueWithin",          label: "Due Within",         type: "text", hint: "e.g. 30 days, quarter-end" }
            ]
        },
        Assurance: {
            heading: "Assurance Spec",
            subheading: "What must be verified and how.",
            fields: [
                { name: "verificationMethod", label: "Verification Method", type: "textarea", required: true },
                { name: "scope",              label: "Scope",               type: "text" },
                { name: "assuranceFrequencyId", label: "Assurance Frequency", type: "reference", refGroup: "frequency-types" },
                { name: "assuranceParty",     label: "Assurance Party",     type: "text" }
            ]
        },
        EventResponse: {
            heading: "Event Response",
            subheading: "If X occurs, do Y within SLA.",
            fields: [
                { name: "triggerEvent",   label: "Trigger Event",   type: "textarea", required: true },
                { name: "responseAction", label: "Response Action", type: "textarea", required: true },
                { name: "slaValue",       label: "SLA Value",       type: "number" },
                { name: "slaUnit",        label: "SLA Unit",        type: "select", options: ["", "Hours", "Days", "Weeks", "Months", "Years"] },
                { name: "escalationPath", label: "Escalation Path", type: "text" }
            ]
        },
        Constraint: {
            heading: "Constraint Rule",
            subheading: "A prohibition -- what must never be true.",
            fields: [
                { name: "prohibitedCondition", label: "Prohibited Condition", type: "textarea", required: true },
                { name: "scope",               label: "Scope",                type: "text" },
                { name: "exceptionPolicy",     label: "Exception Policy",     type: "text" }
            ]
        },
        Retention: {
            heading: "Retention Spec",
            subheading: "What must be preserved and for how long.",
            fields: [
                { name: "retainedObject",     label: "Retained Object",     type: "text", required: true, hint: "e.g. audit_log, contract_pdf" },
                { name: "minRetentionValue",  label: "Min Retention Value", type: "number" },
                { name: "minRetentionUnit",   label: "Min Retention Unit",  type: "select", options: ["", "Days", "Weeks", "Months", "Years"] },
                { name: "maxRetentionValue",  label: "Max Retention Value", type: "number" },
                { name: "maxRetentionUnit",   label: "Max Retention Unit",  type: "select", options: ["", "Days", "Weeks", "Months", "Years"] },
                { name: "disposalPolicy",     label: "Disposal Policy",     type: "text" }
            ]
        }
        // Evidence type has no typed-detail form -- standalone Evidence
        // obligations use the classic requirement_obligation_evidence flow
        // via the existing Obligation Master page.
    };

    let obligationOptions = [];
    let typeOptions = [];
    let evidenceSpecOptions = [];
    let currentObligationId = 0;
    let currentTypeCode = "";
    let currentDetailId = 0;
    let currentDetailData = {};

    init().catch(err => showError(err.message));

    async function init() {
        await Promise.all([
            loadObligations(),
            loadTypes(),
            loadEvidenceSpecOptions()
        ]);

        if (ctx.obligationId) {
            obligationSelect.value = String(ctx.obligationId);
            await onObligationChanged();
        }

        if (!readonly) {
            obligationSelect.addEventListener("change", onObligationChanged);
            assignTypeBtn.addEventListener("click", onAssignType);
            saveDetailBtn.addEventListener("click", onSaveDetail);
            attachEvidenceBtn.addEventListener("click", onAttachEvidence);
        }
        cancelBtn.addEventListener("click", goBack);
    }

    function buildBaseUrl() {
        return api || "/control-management-gateway";
    }

    async function fetchJson(url, init = {}) {
        const response = await fetch(url, { credentials: "same-origin", ...init });
        const text = await response.text();
        const data = text ? safeParse(text) : {};
        if (!response.ok || data?.success === false) {
            const detail = data?.message || data?.error || text || `HTTP ${response.status}`;
            throw new Error(detail);
        }
        return data;
    }

    function safeParse(text) {
        try { return JSON.parse(text); } catch { return null; }
    }

    function apiRows(result) { return result?.data?.[0] || result?.Data?.[0] || []; }

    async function fetchRows(entity, params = {}) {
        const query = Object.entries(params)
            .filter(([, value]) => value !== undefined && value !== null && value !== "")
            .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`)
            .join("&");
        const result = await fetchJson(`${buildBaseUrl()}/${entity}${query ? `?${query}` : ""}`);
        return apiRows(result);
    }

    // Gateway's POST /{entityType} endpoint binds [FromBody] BrowserCommand
    // which is only { Id, Data }.  Action is hardcoded to SAVE by the
    // gateway, so we tunnel the real intent (ASSIGN_TYPE / ATTACH / DETACH)
    // inside data._action -- cm_manage_obligation_taxonomy reads this field
    // as an override to @p_action.
    async function postJson(entity, action, id, data) {
        const payload = Object.assign({}, data || {});
        if (action && action !== "SAVE") payload._action = action;
        const body = { id: id || null, data: payload };
        return await fetchJson(`${buildBaseUrl()}/${entity}`, {
            method: "POST",
            headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
            body: JSON.stringify(body)
        });
    }

    async function loadObligations() {
        const rows = await fetchRows("obligations", { status: "" });
        obligationOptions = rows.map(row => ({
            value: String(row.Id ?? row.ObligationId ?? row.id ?? ""),
            label: row.ObligationName ?? row.obligationName ?? row.ObligationText ?? `Obligation #${row.Id}`,
            typeId: row.ObligationTypeId ?? null,
            typeCode: row.TypeCode ?? ""
        })).filter(option => option.value);
        const placeholder = `<option value="">-- Select Obligation --</option>`;
        obligationSelect.innerHTML = placeholder + obligationOptions
            .map(o => `<option value="${escapeHtml(o.value)}">${escapeHtml(o.label)}</option>`)
            .join("");
    }

    async function loadTypes() {
        const rows = await fetchRows("obligation-types");
        typeOptions = rows.map(row => ({
            code: row.TypeCode,
            name: row.TypeName,
            description: row.Description
        }));
        const placeholder = `<option value="">-- Select Type --</option>`;
        typeSelect.innerHTML = placeholder + typeOptions
            .map(t => `<option value="${escapeHtml(t.code)}">${escapeHtml(t.name)}</option>`)
            .join("");
    }

    async function loadEvidenceSpecOptions() {
        // Reuse the Obligation Master's evidence subgrid -- every
        // requirement_obligation_evidence row is a candidate spec.
        try {
            const rows = await fetchRows("obligation-evidence", { status: "" });
            evidenceSpecOptions = rows.map(row => ({
                value: String(row.Id ?? row.ObligationEvidenceId ?? ""),
                label: `${row.EvidenceType || row.EvidenceTypeName || "Evidence"} (${row.Frequency || "-"})`
            })).filter(o => o.value);
        } catch {
            evidenceSpecOptions = [];
        }
        const placeholder = `<option value="">-- Select Evidence Spec --</option>`;
        evidenceSpecSelect.innerHTML = placeholder + evidenceSpecOptions
            .map(o => `<option value="${escapeHtml(o.value)}">${escapeHtml(o.label)}</option>`)
            .join("");
    }

    async function onObligationChanged() {
        currentObligationId = Number(obligationSelect.value || 0);
        if (!currentObligationId) {
            hideDetail();
            hideEvidence();
            return;
        }
        // Look up current type from the master row we already loaded.
        const master = obligationOptions.find(o => o.value === String(currentObligationId));
        currentTypeCode = master?.typeCode || "";
        typeSelect.value = currentTypeCode;
        currentTypeLabel.textContent = currentTypeCode ? `Current type: ${currentTypeCode}` : "No type assigned yet.";
        await refreshDetailAndEvidence();
    }

    async function refreshDetailAndEvidence() {
        currentDetailId = 0;
        currentDetailData = {};
        if (!currentObligationId || !currentTypeCode) {
            hideDetail();
            hideEvidence();
            return;
        }
        if (currentTypeCode === "Evidence") {
            // Standalone Evidence obligations do not use typed detail or link tables.
            hideDetail();
            hideEvidence();
            currentTypeLabel.textContent += " -- authored via the standard Obligation Master evidence subgrid.";
            return;
        }
        renderDetailForm();
        await Promise.all([loadCurrentDetail(), loadEvidenceLinks()]);
    }

    function renderDetailForm() {
        const schema = TYPE_SCHEMA[currentTypeCode];
        if (!schema) { hideDetail(); return; }
        detailCard.hidden = false;
        detailHeading.textContent = schema.heading;
        detailSubheading.textContent = schema.subheading;
        detailFields.innerHTML = schema.fields.map(f => renderField(f)).join("") +
            `<div class="form-field"><span class="form-field-label">Status</span>
                <select id="otd-f-status" ${readonly ? "disabled" : ""}>
                    <option value="Active">Active</option>
                    <option value="Inactive">Inactive</option>
                </select></div>
             <div class="form-field full"><span class="form-field-label">Remarks</span>
                <textarea id="otd-f-remarks" rows="2" ${readonly ? "disabled" : ""}></textarea></div>`;
        evidenceCard.hidden = false;
    }

    function renderField(field) {
        const disabled = readonly ? "disabled" : "";
        const required = field.required ? '<span class="required">*</span>' : "";
        const hint = field.hint ? `<small class="text-muted">${escapeHtml(field.hint)}</small>` : "";
        const id = `otd-f-${field.name}`;
        let input;
        if (field.type === "textarea") {
            input = `<textarea id="${id}" rows="2" ${disabled} ${field.required ? "required" : ""}></textarea>`;
        } else if (field.type === "number") {
            input = `<input type="number" id="${id}" ${disabled} ${field.required ? "required" : ""} />`;
        } else if (field.type === "select") {
            input = `<select id="${id}" ${disabled} ${field.required ? "required" : ""}>` +
                (field.options || []).map(o => `<option value="${escapeHtml(o)}">${escapeHtml(o || "-- none --")}</option>`).join("") +
                `</select>`;
        } else if (field.type === "reference") {
            // Bind to a reference-option dropdown; loaded lazily.
            input = `<select id="${id}" ${disabled}></select>`;
            loadReferenceOptions(field.refGroup, id);
        } else {
            input = `<input type="text" id="${id}" ${disabled} ${field.required ? "required" : ""} />`;
        }
        return `<div class="form-field">
                    <span class="form-field-label">${escapeHtml(field.label)} ${required}</span>
                    ${input}
                    ${hint}
                </div>`;
    }

    async function loadReferenceOptions(group, elementId) {
        try {
            const rows = await fetchRows("lookups", { module: group });
            const target = document.querySelector(`#${elementId}`);
            if (!target) return;
            target.innerHTML = `<option value="">-- none --</option>` + rows.map(r =>
                `<option value="${escapeHtml(String(r.Id ?? r.ReferenceOptionId ?? ""))}">${escapeHtml(r.Label ?? r.OptionLabel ?? "")}</option>`
            ).join("");
        } catch { /* leave empty */ }
    }

    async function loadCurrentDetail() {
        const entity = `obligation-${typeToSlug(currentTypeCode)}`;
        try {
            const rows = await fetchRows(entity, { id: currentObligationId });
            const row = rows[0];
            if (!row) return;
            currentDetailId = Number(row.Id || 0);
            currentDetailData = row;
            const schema = TYPE_SCHEMA[currentTypeCode];
            schema?.fields.forEach(f => {
                const el = document.querySelector(`#otd-f-${f.name}`);
                if (el) el.value = row[capitalize(f.name)] ?? row[f.name] ?? "";
            });
            const statusEl = document.querySelector("#otd-f-status");
            if (statusEl) statusEl.value = row.Status || "Active";
            const remarksEl = document.querySelector("#otd-f-remarks");
            if (remarksEl) remarksEl.value = row.Remarks || "";
        } catch (err) {
            showError(`Could not load current ${currentTypeCode} detail: ${err.message}`);
        }
    }

    async function onAssignType() {
        if (!currentObligationId) { showError("Pick an Obligation first."); return; }
        const nextType = typeSelect.value;
        if (!nextType) { showError("Pick a Type to assign."); return; }
        try {
            await postJson("obligation-type-assignment", "ASSIGN_TYPE", 0, {
                obligationId: currentObligationId,
                typeCode: nextType
            });
            currentTypeCode = nextType;
            currentTypeLabel.textContent = `Current type: ${currentTypeCode}`;
            // Refresh master row cache so subsequent obligation-changes reflect new type.
            const master = obligationOptions.find(o => o.value === String(currentObligationId));
            if (master) master.typeCode = currentTypeCode;
            await refreshDetailAndEvidence();
            showSuccess(`Type set to ${currentTypeCode}.`);
        } catch (err) {
            showError(err.message);
        }
    }

    async function onSaveDetail() {
        if (!currentObligationId || !currentTypeCode) { showError("Pick an Obligation and Type first."); return; }
        const schema = TYPE_SCHEMA[currentTypeCode];
        if (!schema) { showError("Type has no typed-detail form."); return; }
        const payload = { obligationId: currentObligationId };
        for (const f of schema.fields) {
            const el = document.querySelector(`#otd-f-${f.name}`);
            const raw = el ? el.value : "";
            if (raw === "" && !f.required) continue;
            payload[f.name] = f.type === "number" ? Number(raw) : raw;
        }
        payload.status = document.querySelector("#otd-f-status")?.value || "Active";
        payload.remarks = document.querySelector("#otd-f-remarks")?.value || null;
        const entity = `obligation-${typeToSlug(currentTypeCode)}`;
        try {
            await postJson(entity, "SAVE", currentDetailId, payload);
            showSuccess(`${currentTypeCode} detail saved.`);
            await loadCurrentDetail();
        } catch (err) {
            showError(err.message);
        }
    }

    async function loadEvidenceLinks() {
        try {
            const rows = await fetchRows("obligation-evidence-links", { id: currentObligationId });
            if (!rows.length) {
                evidenceBody.innerHTML = `<tr><td colspan="6" class="empty">No evidence attached yet.</td></tr>`;
                return;
            }
            evidenceBody.innerHTML = rows.map(r => `
                <tr data-eid="${escapeHtml(String(r.ObligationEvidenceId || ""))}">
                    <td>${escapeHtml(r.TypeCode || "")}</td>
                    <td>${escapeHtml(r.EvidenceType || "")}</td>
                    <td>${escapeHtml(r.Frequency || "")}</td>
                    <td>${escapeHtml(r.RetentionRequirement || "")}</td>
                    <td>${escapeHtml(r.LinkRemarks || r.EvidenceRemarks || "")}</td>
                    <td>${readonly ? "" : `<button type="button" class="button danger otd-detach" data-eid="${escapeHtml(String(r.ObligationEvidenceId || ""))}"><i class="fa-solid fa-unlink"></i> Detach</button>`}</td>
                </tr>`).join("");
            if (!readonly) {
                evidenceBody.querySelectorAll(".otd-detach").forEach(btn => {
                    btn.addEventListener("click", () => onDetachEvidence(Number(btn.dataset.eid)));
                });
            }
        } catch (err) {
            evidenceBody.innerHTML = `<tr><td colspan="6" class="empty">Could not load evidence links: ${escapeHtml(err.message)}</td></tr>`;
        }
    }

    async function onAttachEvidence() {
        if (!currentObligationId || !currentTypeCode || currentTypeCode === "Evidence") return;
        const eid = Number(evidenceSpecSelect.value || 0);
        if (!eid) { showError("Pick an Evidence Spec first."); return; }
        try {
            await postJson("obligation-evidence-links", "ATTACH", 0, {
                obligationId: currentObligationId,
                obligationEvidenceId: eid,
                remarks: evidenceRemarksInput.value || null
            });
            evidenceRemarksInput.value = "";
            await loadEvidenceLinks();
            showSuccess("Evidence attached.");
        } catch (err) {
            showError(err.message);
        }
    }

    async function onDetachEvidence(evidenceId) {
        if (!currentObligationId || !evidenceId) return;
        try {
            await postJson("obligation-evidence-links", "DETACH", 0, {
                obligationId: currentObligationId,
                obligationEvidenceId: evidenceId
            });
            await loadEvidenceLinks();
            showSuccess("Evidence detached.");
        } catch (err) {
            showError(err.message);
        }
    }

    function hideDetail() { detailCard.hidden = true; detailFields.innerHTML = ""; }
    function hideEvidence() {
        evidenceCard.hidden = true;
        evidenceBody.innerHTML = `<tr><td colspan="6" class="empty">No evidence attached yet.</td></tr>`;
    }

    function goBack() {
        // Referer-derived: accepted only when it points inside this application.
        if (window.gracUrl.isInternal(ctx.returnUrl)) {
            window.location.assign(ctx.returnUrl);
            return;
        }
        window.history.length > 1 ? window.history.back() : window.location.assign(appUrl("/Repository"));
    }

    function showError(text) {
        message.hidden = false;
        message.className = "form-message error";
        message.textContent = text;
    }
    function showSuccess(text) {
        message.hidden = false;
        message.className = "form-message success";
        message.textContent = text;
        setTimeout(() => { message.hidden = true; }, 3000);
    }
    function escapeHtml(text) {
        return String(text ?? "").replace(/[&<>"']/g, m => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" }[m]));
    }
    function typeToSlug(code) {
        return code === "EventResponse" ? "event-response"
             : code === "Constraint"    ? "constraint"
             : String(code).toLowerCase();
    }
    function capitalize(name) { return name ? name.charAt(0).toUpperCase() + name.slice(1) : name; }
})();
