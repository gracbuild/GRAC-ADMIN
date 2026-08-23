/*
  Event Checklist fill page (Phase B).

  Shows every assurance generated for one event occurrence and records a
  result against each: Pass / Fail / Not Applicable, plus remarks.

  Two things worth knowing before changing this file:

  1. The verification method rendered here is a SNAPSHOT taken when the event
     was raised, not a live read of the obligation.  Editing the rule later
     must not change what an already-raised checklist asked.  Do not "fix"
     this by joining to the obligation.

  2. Completion writes DIRECTLY -- there is no maker-checker round trip.  That
     is deliberate: routing completion through change_management would raise
     one approval per assurance per person (see migration 035).  Each save is
     therefore immediate and the item re-renders in place.
*/
(function () {
    const ctx = window.cmEventChecklist || {};
    const api = (ctx.api || "").replace(/\/$/, "");
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || "";
    // Resolved against the application root (see gracUrl in site.js).
    const appUrl = path => window.gracUrl.app(path);
    const canEdit = ctx.canEdit === true;

    const message     = document.querySelector("#eclMessage");
    const summaryHost = document.querySelector("#ecl-summary");
    const itemsHost   = document.querySelector("#ecl-items");
    const backBtn     = document.querySelector("#eclBack");

    const RESPONSES = ["Pass", "Fail", "Not Applicable"];

    let occurrence = null;
    let items = [];
    // Local edit buffer keyed by item id, so typing remarks on one row does
    // not get lost when another row saves and triggers a re-render.
    const draft = new Map();

    init().catch(error => showError(error.message));

    async function init() {
        await load();
        backBtn.addEventListener("click", goBack);
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
        const query = Object.entries(params)
            .filter(([, v]) => v !== undefined && v !== null && v !== "")
            .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
            .join("&");
        return apiRows(await fetchJson(`${buildBaseUrl()}/${entity}${query ? `?${query}` : ""}`));
    }

    // The browser gateway hardcodes Action = SAVE, so the real intent travels
    // in the payload as _action -- same convention the taxonomy dispatcher
    // uses (see migration 030).
    async function post(entity, action, id, data) {
        const payload = Object.assign({}, data || {});
        if (action && action !== "SAVE") payload._action = action;
        return await fetchJson(`${buildBaseUrl()}/${entity}`, {
            method: "POST",
            headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
            body: JSON.stringify({ id: id || null, data: payload })
        });
    }

    // ---- load ---------------------------------------------------------
    async function load() {
        const id = Number(ctx.occurrenceId || 0);
        if (!id) { showError("No checklist selected."); return; }

        const occRows = await fetchRows("assurance-occurrences", { id });
        occurrence = occRows[0] || null;
        if (!occurrence) { showError("This checklist could not be found."); return; }

        // @p_id on the checklist read is the OCCURRENCE, not an item id.
        items = await fetchRows("assurance-checklist", { id });

        renderSummary();
        renderItems();
    }

    // ---- summary ------------------------------------------------------
    function renderSummary() {
        const total     = Number(occurrence.TotalItems ?? 0);
        const completed = Number(occurrence.CompletedItems ?? 0);
        const failed    = Number(occurrence.FailedItems ?? 0);
        const overdue   = Number(occurrence.OverdueItems ?? 0);
        const percent   = Number(occurrence.CompletionPercent ?? 0);
        const status    = String(occurrence.Status ?? "Open");

        document.querySelector("#eclPageTitle").textContent =
            `${occurrence.EventName || "Event"} - ${occurrence.SubjectLabel || ""}`;

        summaryHost.innerHTML = `
            <div class="ecl-summary-main">
                <div class="ecl-summary-titles">
                    <h2>${escapeHtml(occurrence.SubjectLabel || "")}</h2>
                    <p>
                        <strong>${escapeHtml(occurrence.EventName || "")}</strong>
                        ${occurrence.EventDomainName ? ` &middot; ${escapeHtml(occurrence.EventDomainName)}` : ""}
                        &middot; occurred ${escapeHtml(formatDate(occurrence.OccurredOn))}
                        &middot; raised by ${escapeHtml(occurrence.RaisedBy || "-")}
                    </p>
                </div>
                <span class="ecl-status ecl-status-${escapeHtml(status.toLowerCase())}">${escapeHtml(status)}</span>
            </div>
            <div class="ecl-progress">
                <div class="ecl-progress-bar" role="progressbar"
                     aria-valuenow="${percent}" aria-valuemin="0" aria-valuemax="100"
                     aria-label="Checklist completion">
                    <span style="width:${percent}%"></span>
                </div>
                <div class="ecl-progress-legend">
                    <span><strong>${completed}</strong> of <strong>${total}</strong> complete</span>
                    ${overdue > 0 ? `<span class="ecl-legend-overdue"><i class="fa-solid fa-clock" aria-hidden="true"></i> ${overdue} overdue</span>` : ""}
                    ${failed > 0 ? `<span class="ecl-legend-fail"><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i> ${failed} failed</span>` : ""}
                </div>
            </div>`;
    }

    // ---- items --------------------------------------------------------
    function renderItems() {
        if (items.length === 0) {
            // Worth distinguishing from a load error: an occurrence with no
            // items means no assurance is configured for that event yet.
            itemsHost.innerHTML = `<div class="ecl-empty">
                No assurance is currently configured for this event. Classify an Assurance
                obligation as event driven and point it at this event to populate future checklists.
            </div>`;
            return;
        }
        itemsHost.innerHTML = items.map(renderItem).join("");
        if (!canEdit) return;

        itemsHost.querySelectorAll("[data-response]").forEach(btn => {
            btn.addEventListener("click", () => {
                const id = btn.dataset.itemId;
                const d = draft.get(id) || {};
                d.response = btn.dataset.response;
                draft.set(id, d);
                renderItems();
            });
        });
        itemsHost.querySelectorAll("[data-remarks-for]").forEach(input => {
            input.addEventListener("input", () => {
                const id = input.dataset.remarksFor;
                const d = draft.get(id) || {};
                d.remarks = input.value;
                draft.set(id, d);
                // Deliberately no re-render here: it would steal focus mid-typing.
                const saveBtn = itemsHost.querySelector(`[data-save-item="${id}"]`);
                if (saveBtn) saveBtn.disabled = !canSave(id);
            });
        });
        itemsHost.querySelectorAll("[data-save-item]").forEach(btn => {
            btn.addEventListener("click", () => saveItem(btn.dataset.saveItem));
        });
        itemsHost.querySelectorAll("[data-reopen-item]").forEach(btn => {
            btn.addEventListener("click", () => reopenItem(btn.dataset.reopenItem));
        });
    }

    function renderItem(item) {
        const id        = String(item.ChecklistItemId ?? item.Id ?? "");
        const completed = String(item.Status ?? "") === "Completed";
        const d         = draft.get(id) || {};
        const response  = completed ? String(item.ResponseValue ?? "") : (d.response || "");
        const remarks   = completed ? String(item.Remarks ?? "") : (d.remarks ?? String(item.Remarks ?? ""));

        const chips = RESPONSES.map(r => {
            const active = r === response;
            const cls = `ecl-chip ecl-chip-${r.toLowerCase().replace(/\s+/g, "-")}${active ? " is-active" : ""}`;
            return completed || !canEdit
                ? (active ? `<span class="${cls}">${escapeHtml(r)}</span>` : "")
                : `<button type="button" class="${cls}" data-response="${escapeHtml(r)}" data-item-id="${escapeHtml(id)}">${escapeHtml(r)}</button>`;
        }).join("");

        const body = completed
            ? `<div class="ecl-item-result">
                   <div class="ecl-item-chips">${chips || `<span class="ecl-chip">${escapeHtml(response || "-")}</span>`}</div>
                   ${remarks ? `<p class="ecl-item-remarks">${escapeHtml(remarks)}</p>` : ""}
                   <p class="ecl-item-meta">
                       Completed by ${escapeHtml(item.CompletedBy || "-")}
                       on ${escapeHtml(formatDate(item.CompletedOn))}
                   </p>
                   ${canEdit ? `<button type="button" class="button tiny" data-reopen-item="${escapeHtml(id)}">
                       <i class="fa-solid fa-rotate-left"></i> Reopen
                   </button>` : ""}
               </div>`
            : `<div class="ecl-item-form">
                   <div class="ecl-item-chips">${chips}</div>
                   <input type="text" class="ecl-item-remarks-input"
                          data-remarks-for="${escapeHtml(id)}"
                          value="${escapeHtml(remarks)}"
                          placeholder="Remarks${response === "Fail" ? " (required for Fail)" : " (optional)"}"
                          ${canEdit ? "" : "disabled"} />
                   ${canEdit ? `<button type="button" class="button primary tiny" data-save-item="${escapeHtml(id)}"${canSave(id) ? "" : " disabled"}>
                       <i class="fa-solid fa-check"></i> Save
                   </button>` : ""}
               </div>`;

        // IsOverdue is computed server-side against database time -- never
        // recomputed here, so the definition cannot drift between screens and
        // a wrong client clock cannot mark work overdue.
        const overdue = item.IsOverdue === true || item.IsOverdue === 1 || String(item.IsOverdue) === "1";
        const due = renderDue(item, completed, overdue);

        return `<article class="ecl-item${completed ? " is-complete" : ""}${overdue ? " is-overdue" : ""}">
            <header class="ecl-item-head">
                <div>
                    <h3>${escapeHtml(item.ObligationName || "Assurance")}</h3>
                    <p class="ecl-item-method">${escapeHtml(item.VerificationMethod || "")}</p>
                </div>
                <div class="ecl-item-head-right">
                    ${due}
                    <span class="ecl-item-status">${completed ? "Completed" : "Pending"}</span>
                </div>
            </header>
            ${item.AssuranceParty || item.Scope ? `<p class="ecl-item-context">
                ${item.AssuranceParty ? `<span><strong>Party:</strong> ${escapeHtml(item.AssuranceParty)}</span>` : ""}
                ${item.Scope ? `<span><strong>Scope:</strong> ${escapeHtml(item.Scope)}</span>` : ""}
            </p>` : ""}
            ${body}
        </article>`;
    }

    // Due-date badge.  A completed item shows nothing: its deadline stopped
    // mattering the moment it was answered, and leaving a red "overdue" chip
    // on finished work misrepresents the record.
    function renderDue(item, completed, overdue) {
        if (completed || !item.DueOn) return "";
        const days = item.DaysRemaining === null || item.DaysRemaining === undefined
            ? null : Number(item.DaysRemaining);

        if (overdue) {
            const late = days === null ? "" : ` ${Math.abs(days)}d`;
            return `<span class="ecl-due ecl-due-overdue" title="Due ${escapeHtml(formatDate(item.DueOn))}">
                <i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i> Overdue${escapeHtml(late)}
            </span>`;
        }
        // "Due today" reads better than "0 days left" for the last day.
        const label = days === null ? `Due ${formatDate(item.DueOn)}`
            : days === 0 ? "Due today"
            : `${days}d left`;
        // Flag the last three days so imminent work is visible without being
        // shouted about a fortnight early.
        const soon = days !== null && days <= 3 ? " ecl-due-soon" : "";
        return `<span class="ecl-due${soon}" title="Due ${escapeHtml(formatDate(item.DueOn))}">
            <i class="fa-regular fa-clock" aria-hidden="true"></i> ${escapeHtml(label)}
        </span>`;
    }

    // A Fail must be explained -- the SP enforces this too (52914), but
    // disabling Save is a faster, clearer signal than a round trip.
    function canSave(id) {
        const d = draft.get(String(id)) || {};
        if (!d.response) return false;
        if (d.response === "Fail" && !String(d.remarks || "").trim()) return false;
        return true;
    }

    // ---- write --------------------------------------------------------
    async function saveItem(id) {
        const d = draft.get(String(id)) || {};
        if (!canSave(id)) return;
        message.hidden = true;
        try {
            await post("assurance-checklist", "COMPLETE", Number(id), {
                checklistItemId: Number(id),
                responseValue: d.response,
                remarks: d.remarks || null
            });
            draft.delete(String(id));
            await load();
            showSuccess("Result recorded.");
        } catch (error) { showError(error.message); }
    }

    async function reopenItem(id) {
        message.hidden = true;
        try {
            await post("assurance-checklist", "REOPEN", Number(id), { checklistItemId: Number(id) });
            draft.delete(String(id));
            await load();
            showSuccess("Item reopened.");
        } catch (error) { showError(error.message); }
    }

    // ---- misc ---------------------------------------------------------
    function goBack() {
        // Referer-derived: accepted only when it points inside this application,
        // otherwise fall back to the list grid under the application root.
        window.location.assign(window.gracUrl.safeReturn(ctx.returnUrl, "/Repository/Index?areaKey=assurance-occurrences"));
    }
    function formatDate(value) {
        if (!value) return "-";
        const d = new Date(value);
        return isNaN(d.getTime()) ? String(value) : d.toLocaleDateString();
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
