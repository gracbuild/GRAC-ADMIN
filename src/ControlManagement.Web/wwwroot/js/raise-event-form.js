/*
  Raise Event (Phase B).

  Records that a tracked event occurred and generates its assurance checklist.
  Its own page rather than the shared dialog because the subject picker
  depends on the chosen event type -- the generic schema-driven dialog has no
  way to express a dependent lookup.

  Cascade:  Domain -> Event -> Subject
  Domain and Event come from event_type_master; Subject is resolved through
  whichever register that event type declares in subject_entity (today only
  cm_user exists, so a non-people event returns an empty list rather than
  failing -- the picker degrades quietly).

  Writes directly.  See migration 035: occurrences and checklists are
  operational records, not policy, and do not route through maker-checker.
*/
(function () {
    const ctx = window.cmRaiseEvent || {};
    const api = (ctx.api || "").replace(/\/$/, "");
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || "";
    // Resolved against the application root (see gracUrl in site.js).
    const appUrl = path => window.gracUrl.app(path);

    const message      = document.querySelector("#revMessage");
    const domainSelect = document.querySelector("#rev-domain");
    const eventSelect  = document.querySelector("#rev-event");
    const subjectSelect= document.querySelector("#rev-subject");
    const subjectHint  = document.querySelector("#rev-subject-hint");
    const occurredInput= document.querySelector("#rev-occurred");
    const remarksInput = document.querySelector("#rev-remarks");
    const previewCard  = document.querySelector("#rev-preview-card");
    const previewHost  = document.querySelector("#rev-preview");
    const previewSub   = document.querySelector("#rev-preview-sub");
    const saveBtn      = document.querySelector("#revSave");
    const cancelBtn    = document.querySelector("#revCancel");

    let eventTypes = [];
    let subjects = [];

    init().catch(e => showError(e.message));

    async function init() {
        await loadEventTypes();
        renderDomains();

        // Default to today, in the input's expected yyyy-mm-dd form.
        occurredInput.value = new Date().toISOString().slice(0, 10);

        domainSelect.addEventListener("change", onDomainChanged);
        eventSelect.addEventListener("change", onEventChanged);
        subjectSelect.addEventListener("change", updateSaveState);
        saveBtn?.addEventListener("click", raise);
        cancelBtn.addEventListener("click", goBack);
    }

    // ---- plumbing ----------------------------------------------------
    function buildBaseUrl() { return api || "/control-management-gateway"; }
    async function fetchJson(url, init = {}) {
        const response = await fetch(url, { credentials: "same-origin", ...init });
        const text = await response.text();
        const data = text ? safeParse(text) : {};
        if (!response.ok || data?.success === false)
            throw new Error(data?.message || data?.error || text || `HTTP ${response.status}`);
        return data;
    }
    function safeParse(t) { try { return JSON.parse(t); } catch { return null; } }
    function apiRows(r) { return r?.data?.[0] || r?.Data?.[0] || []; }
    async function fetchRows(entity, params = {}) {
        const q = Object.entries(params)
            .filter(([, v]) => v !== undefined && v !== null && v !== "")
            .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
        return apiRows(await fetchJson(`${buildBaseUrl()}/${entity}${q ? `?${q}` : ""}`));
    }

    // ---- cascade ------------------------------------------------------
    async function loadEventTypes() {
        const rows = await fetchRows("event-types");
        eventTypes = rows.map(r => ({
            id: String(r.EventTypeId ?? r.Id ?? ""),
            parentId: r.ParentEventTypeId === null || r.ParentEventTypeId === undefined
                ? "" : String(r.ParentEventTypeId),
            name: String(r.EventName ?? ""),
            subjectEntity: String(r.SubjectEntity ?? ""),
            isDomain: r.IsDomain === true || r.IsDomain === 1 || String(r.IsDomain) === "1"
        })).filter(e => e.id);
    }

    function renderDomains() {
        const domains = eventTypes.filter(e => e.isDomain);
        domainSelect.innerHTML = `<option value="">-- Select Domain --</option>`
            + domains.map(d => `<option value="${escapeHtml(d.id)}">${escapeHtml(d.name)}</option>`).join("");
        if (domains.length === 0)
            showError("No event domains are active. Seed the event taxonomy before raising events.");
    }

    function onDomainChanged() {
        const leaves = eventTypes.filter(e => !e.isDomain && e.parentId === domainSelect.value);
        eventSelect.innerHTML = `<option value="">${domainSelect.value ? "-- Select Event --" : "-- Select a domain first --"}</option>`
            + leaves.map(l => `<option value="${escapeHtml(l.id)}">${escapeHtml(l.name)}</option>`).join("");
        eventSelect.disabled = !domainSelect.value;
        resetSubject("-- Select an event first --");
        hidePreview();
        updateSaveState();
    }

    async function onEventChanged() {
        resetSubject("Loading...");
        hidePreview();
        updateSaveState();
        if (!eventSelect.value) { resetSubject("-- Select an event first --"); return; }

        const evt = eventTypes.find(e => e.id === eventSelect.value);
        subjectHint.textContent = evt?.subjectEntity
            ? `Resolved from the ${evt.subjectEntity} register.`
            : "This event has no register configured, so no subject can be selected.";

        try {
            // The subject read takes the event type as `id` -- RepositoryQuery
            // has no EventTypeId property, and the SP falls back to @p_id for
            // exactly this reason.
            subjects = await fetchRows("event-subjects", { id: eventSelect.value });
        } catch { subjects = []; }

        if (subjects.length === 0) {
            resetSubject("No selectable subjects");
            subjectSelect.disabled = true;
        } else {
            subjectSelect.innerHTML = `<option value="">-- Select Subject --</option>`
                + subjects.map(s => {
                    const id = String(s.SubjectRecordId ?? s.Id ?? "");
                    return `<option value="${escapeHtml(id)}">${escapeHtml(String(s.SubjectLabel ?? ""))}</option>`;
                }).join("");
            subjectSelect.disabled = false;
        }

        await loadPreview();
        updateSaveState();
    }

    function resetSubject(placeholder) {
        subjects = [];
        subjectSelect.innerHTML = `<option value="">${escapeHtml(placeholder)}</option>`;
        subjectSelect.disabled = true;
    }

    // ---- preview ------------------------------------------------------
    // Shows what raising will generate.  An event with nothing configured is
    // the most likely confusion on this screen -- better to say so before the
    // operator commits than to hand back an empty checklist afterwards.
    //
    // KNOWN DEFECT -- this count OVERSTATES.  The filter below matches every
    // Assurance obligation.  What actually gets raised comes from
    // fn_cm_assurance_specs_for_event(@event_type_id), which also requires
    // trigger_mode = 'EventDriven' AND a matching event_type_id.  A Scheduled
    // assurance, or one pointed at a different event, is counted here but
    // never generated.
    //
    // Not fixable client-side: trigger_mode and event_type_id live in
    // obligation_assurance_spec, which the 'obligations' list does not
    // project.  The fix is to expose the existing TVF as a read branch so the
    // preview and the raise path share ONE rule instead of duplicating it.
    // Deferred deliberately until after the first build / browser pass.
    async function loadPreview() {
        try {
            const rows = await fetchRows("obligations", { status: "Active" });
            const matches = rows.filter(r =>
                String(r.TypeCode ?? "") === "Assurance");

            previewCard.hidden = false;
            if (matches.length === 0) {
                previewSub.textContent = "Assurances that will be raised for this event.";
                previewHost.innerHTML = `<div class="ecl-empty">
                    No Assurance obligations exist yet. The checklist will be empty until at least
                    one is classified as event driven and pointed at this event.
                </div>`;
                return;
            }
            // The obligations list does not carry the trigger classification,
            // so this is an upper bound rather than an exact count.  The
            // authoritative set is computed by sp_cm_assurance_occurrence_raise.
            previewSub.textContent = "Exact items are resolved when the event is raised.";
            previewHost.innerHTML = `<div class="ecl-empty">
                ${matches.length} Assurance obligation${matches.length === 1 ? "" : "s"} exist.
                Those configured as event driven for this event will be added to the checklist.
            </div>`;
        } catch {
            hidePreview();
        }
    }
    function hidePreview() { previewCard.hidden = true; previewHost.innerHTML = ""; }

    function updateSaveState() {
        if (!saveBtn) return;
        saveBtn.disabled = !(eventSelect.value && subjectSelect.value);
    }

    // ---- write --------------------------------------------------------
    async function raise() {
        message.hidden = true;
        const evt = eventTypes.find(e => e.id === eventSelect.value);
        const subject = subjects.find(s => String(s.SubjectRecordId ?? s.Id ?? "") === subjectSelect.value);
        if (!evt || !subject) return showError("Select an event and a subject.");

        try {
            saveBtn.disabled = true;
            const result = await fetchJson(`${buildBaseUrl()}/assurance-occurrences`, {
                method: "POST",
                headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
                body: JSON.stringify({
                    id: null,
                    data: {
                        _action: "RAISE",
                        eventTypeId: Number(evt.id),
                        subjectEntity: String(subject.SubjectEntity ?? evt.subjectEntity ?? ""),
                        subjectRecordId: Number(subjectSelect.value),
                        subjectLabel: String(subject.SubjectLabel ?? ""),
                        occurredOn: occurredInput.value || null,
                        remarks: remarksInput.value || null
                    }
                })
            });

            const row = apiRows(result)[0] || {};
            const occurrenceId = Number(row.OccurrenceId ?? row.Id ?? 0);
            const count = Number(row.ChecklistItemCount ?? 0);

            showSuccess(count > 0
                ? `Checklist raised with ${count} item${count === 1 ? "" : "s"}. Opening...`
                : "Event raised, but no assurance is configured for it yet.");

            // Straight into the checklist when there is something to do.
            if (occurrenceId > 0 && count > 0)
                setTimeout(() => window.location.assign(appUrl(`/Repository/EventChecklist?id=${occurrenceId}`)), 900);
            else
                setTimeout(goBack, 1400);
        } catch (error) {
            showError(error.message);
            saveBtn.disabled = false;
        }
    }

    // ---- misc ---------------------------------------------------------
    function goBack() {
        // Referer-derived: accepted only when it points inside this application,
        // otherwise fall back to the list grid under the application root.
        window.location.assign(window.gracUrl.safeReturn(ctx.returnUrl, "/Repository/Index?areaKey=assurance-occurrences"));
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
    }
    function escapeHtml(v) {
        return String(v ?? "").replace(/[&<>"']/g, ch =>
            ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
    }
})();
