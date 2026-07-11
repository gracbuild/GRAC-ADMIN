/*
  Practices - Obligation Mapping (full-page form).

  Flow:
    1. Page loads with empty matrix.
    2. User picks a Requirement (or the page boots with a Requirement pre-set
       from query string / from the row the user clicked Edit on).
    3. We call obligation-mapping-matrix to get every Statement / Release row
       reachable from that Requirement plus any already-mapped obligation.
    4. Each row gets an Obligation dropdown (pre-selected when an active
       mapping exists).
    5. Save posts to obligation-mapping-bulk; the SP de-activates removed
       rows and inserts new ones.  Cancel returns to the list grid.
*/
(function () {
    const ctx = window.cmObligationMappingForm || {};
    const api = (ctx.api || "").replace(/\/$/, "");
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || "";
    const message = document.querySelector("#omMessage");
    const requirementSelect = document.querySelector("#om-requirement");
    const matrixBody = document.querySelector("#om-matrix-body");
    const saveBtn = document.querySelector("#omSave");
    const cancelBtn = document.querySelector("#omCancel");
    const readonly = ctx.mode === "view";

    let requirementOptions = [];
    let obligationOptions = [];
    let matrixRows = [];
    // Obligation details cache (keyed by obligationId) - keeps the inline
    // preview snappy so re-rendering after a re-selection doesn't re-fetch.
    const obligationCache = new Map();
    // Preview expansion state - keyed by rowIndex so re-renders keep the card
    // in whichever state the user left it.
    const previewExpanded = new Set();

    init().catch(error => showError(error.message));

    async function init() {
        await Promise.all([loadRequirements(), loadObligationLookup()]);

        let initialRequirementId = String(ctx.requirementId || "");
        if (ctx.id && !initialRequirementId) {
            // Edit / View: derive Requirement from the picked mapping row.
            try {
                const rows = await fetchRows("obligation-mappings", { id: ctx.id, status: "" });
                if (rows.length > 0)
                    initialRequirementId = String(rows[0].RequirementId || rows[0].requirementId || "");
            } catch { /* ignore */ }
        }
        if (initialRequirementId) {
            requirementSelect.value = initialRequirementId;
            await loadMatrix(initialRequirementId);
        }

        if (!readonly) {
            requirementSelect.addEventListener("change", async () => {
                await loadMatrix(requirementSelect.value);
            });
            saveBtn?.addEventListener("click", saveMappings);
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
    function apiData(result) { return result?.data?.[0] || result?.Data?.[0] || []; }
    async function fetchRows(entity, params = {}) {
        const query = Object.entries(params)
            .filter(([, value]) => value !== undefined && value !== null && value !== "")
            .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`)
            .join("&");
        const result = await fetchJson(`${buildBaseUrl()}/${entity}${query ? `?${query}` : ""}`);
        return apiData(result);
    }

    async function loadRequirements() {
        const rows = await fetchRows("requirements", { status: "" });
        requirementOptions = rows.map(row => ({
            value: String(row.Id || row.id || ""),
            label: [row.Code || row.code, row.Name || row.name].filter(Boolean).join(" - ")
        })).filter(option => option.value);
        const placeholder = `<option value="">${escapeHtml("-- Select Practice --")}</option>`;
        requirementSelect.innerHTML = placeholder + requirementOptions
            .map(option => `<option value="${escapeHtml(option.value)}">${escapeHtml(option.label)}</option>`)
            .join("");
    }

    async function loadObligationLookup() {
        const result = await fetchJson(`${buildBaseUrl()}/lookups`);
        const rows = apiData(result);
        obligationOptions = rows
            .filter(row => String(row.LookupKey || row.lookupKey || "").toLowerCase() === "obligations")
            .map(row => ({
                value: String(row.Value || row.value || ""),
                label: String(row.Label || row.label || "")
            }))
            .filter(option => option.value);
    }

    async function loadMatrix(requirementId) {
        message.hidden = true;
        const id = Number(requirementId);
        if (!id) {
            matrixRows = [];
            renderMatrixEmpty("Pick a Practice to load mapped statement releases.");
            return;
        }
        renderMatrixEmpty("Loading…");
        try {
            matrixRows = await fetchRows("obligation-mapping-matrix", { requirementId: id, status: "" });
        } catch (error) {
            matrixRows = [];
            showError(error.message);
            renderMatrixEmpty("Could not load the matrix. See the message above for details.");
            return;
        }
        renderMatrix();
    }

    function renderMatrixEmpty(text) {
        matrixBody.innerHTML = `<tr><td colspan="6" class="empty">${escapeHtml(text)}</td></tr>`;
    }

    function renderMatrix() {
        if (matrixRows.length === 0) {
            renderMatrixEmpty("No mapped Framework Statements found for this Requirement.");
            return;
        }
        matrixBody.innerHTML = matrixRows.map((row, index) => renderRow(row, index)).join("");
        // Wire the dropdowns: on change show the preview; pre-populate previews
        // for rows that already have a selection.
        matrixBody.querySelectorAll("select[data-matrix-row]").forEach(sel => {
            const rowIndex = Number(sel.dataset.matrixRow);
            sel.addEventListener("change", () => {
                // Fresh selection - collapse the details by default.
                previewExpanded.delete(rowIndex);
                updateRowPreview(rowIndex);
            });
            if (sel.value) updateRowPreview(rowIndex);
        });
        // Expand / collapse toggle for the inline preview card (delegation on
        // the tbody so we only bind once for all rows).
        if (!matrixBody.dataset.previewToggleBound) {
            matrixBody.addEventListener("click", event => {
                const toggle = event.target.closest("[data-preview-toggle]");
                if (!toggle) return;
                event.preventDefault();
                const rowIndex = Number(toggle.dataset.previewToggle);
                if (previewExpanded.has(rowIndex)) previewExpanded.delete(rowIndex);
                else previewExpanded.add(rowIndex);
                updateRowPreview(rowIndex);
            });
            matrixBody.dataset.previewToggleBound = "1";
        }
    }

    function renderRow(row, index) {
        const obligationId = String(row.MappedObligationId || row.mappedObligationId || "");
        const artifact = [row.ArtifactCode, row.Artifact].filter(Boolean).join(" - ");
        const dropdown = `<select data-matrix-row="${index}"${readonly ? " disabled" : ""}>
            <option value="">-- Select Obligation --</option>
            ${obligationOptions.map(option =>
              `<option value="${escapeHtml(option.value)}"${option.value === obligationId ? " selected" : ""}>${escapeHtml(option.label)}</option>`).join("")}
        </select>
        <div class="om-row-preview" data-row-preview="${index}" hidden></div>`;
        return `<tr>
            <td title="${escapeHtml(row.Authority || "")}">${escapeHtml(row.Authority || "")}</td>
            <td title="${escapeHtml(artifact)}">${escapeHtml(artifact)}</td>
            <td>${escapeHtml(row.Release || row.ReleaseLabel || "")}</td>
            <td>${escapeHtml(row.StatementReference || "")}</td>
            <td title="${escapeHtml(row.StatementTitle || "")}">${escapeHtml(row.StatementTitle || "")}</td>
            <td class="col-obligation-cell">${dropdown}</td>
        </tr>`;
    }

    async function updateRowPreview(rowIndex) {
        const select  = matrixBody.querySelector(`select[data-matrix-row="${rowIndex}"]`);
        const preview = matrixBody.querySelector(`[data-row-preview="${rowIndex}"]`);
        if (!select || !preview) return;
        const obligationId = Number(select.value || 0);
        if (!obligationId) {
            preview.hidden = true;
            preview.innerHTML = "";
            previewExpanded.delete(rowIndex);
            return;
        }
        preview.hidden = false;
        preview.innerHTML = `<span class="om-preview-loading">Loading obligation details...</span>`;
        try {
            const ob = await loadObligation(obligationId);
            preview.innerHTML = renderInlinePreview(ob, rowIndex);
        } catch (error) {
            preview.innerHTML = `<span class="om-preview-error">${escapeHtml(error.message || "Could not load obligation details.")}</span>`;
        }
    }

    // Expandable inline preview card.  Collapsed view: name + summary chips +
    // evidence-type name summary.  Expanded view: additionally shows the full
    // evidence-details table right inside the same card - no separate popup.
    function renderInlinePreview(ob, rowIndex) {
        const name          = ob.ObligationName || ob.obligationName || "(unnamed)";
        const exec          = ob.ExecutionFrequency || ob.executionFrequency || "-";
        const assurance     = ob.AssuranceFrequency || ob.assuranceFrequency || "-";
        const retention     = String(ob.RetentionPeriod || ob.RetentionRequirement || ob.retentionPeriod || "").trim() || "-";
        const evidenceTypes = (ob.EvidenceTypes || ob.evidenceTypes || "").trim();
        const evidenceCount = Number(ob.EvidenceCount ?? ob.evidenceCount ?? 0);
        const isExpanded    = previewExpanded.has(rowIndex);

        const summaryChips = [
            ["Execution Frequency", exec],
            ["Assurance Frequency", assurance],
            ["Retention Period",    retention],
            ["Evidence",            String(evidenceCount)],
        ].map(([label, value]) =>
            `<span class="om-preview-chip"><strong>${escapeHtml(label)}:</strong> ${escapeHtml(value)}</span>`).join("");

        // Evidence Type names summary line - truncated when very long so the
        // collapsed card stays compact; full names are visible in the details
        // table when the user expands.
        let evidenceTypesSummary = "";
        if (evidenceTypes) {
            const shown = evidenceTypes.length > 90 ? evidenceTypes.slice(0, 88).replace(/,\s*[^,]*$/, "") + " ..." : evidenceTypes;
            evidenceTypesSummary = `<div class="om-preview-evidence"><strong>Evidence Types:</strong> ${escapeHtml(shown)}</div>`;
        }

        const evidence = parseJsonArray(ob.EvidenceRequirementsJson || ob.evidenceRequirementsJson);
        const detailsBody = evidence.length === 0
            ? `<p class="om-preview-empty">No evidence rows configured for this Obligation.</p>`
            : `<table class="om-preview-evidence-table">
                <thead><tr><th>Evidence Type</th><th>Assurance Frequency</th><th>Retention Period</th><th>Remarks</th></tr></thead>
                <tbody>${evidence.map(e => `<tr>
                    <td>${escapeHtml(e.EvidenceType || "")}</td>
                    <td>${escapeHtml(e.Frequency || "")}</td>
                    <td>${escapeHtml(e.RetentionRequirement || "")}</td>
                    <td>${escapeHtml(e.Remarks || "")}</td>
                </tr>`).join("")}</tbody>
              </table>`;

        return `<div class="om-preview-card om-preview-card-expandable${isExpanded ? " is-expanded" : ""}" data-preview-card="${rowIndex}">
            <div class="om-preview-head">
                <span class="om-preview-name" title="${escapeHtml(name)}">${escapeHtml(name)}</span>
                <button type="button" class="om-preview-toggle" data-preview-toggle="${rowIndex}" aria-expanded="${isExpanded ? "true" : "false"}" aria-controls="om-preview-details-${rowIndex}">
                    <span class="om-preview-toggle-label">${isExpanded ? "Hide Details" : "Show Details"}</span>
                    <i class="fa-solid fa-chevron-${isExpanded ? "up" : "down"}" aria-hidden="true"></i>
                </button>
            </div>
            <div class="om-preview-row">${summaryChips}</div>
            ${evidenceTypesSummary}
            <div class="om-preview-details" id="om-preview-details-${rowIndex}"${isExpanded ? "" : " hidden"}>
                <div class="om-preview-details-heading">Evidence Details</div>
                ${detailsBody}
            </div>
        </div>`;
    }

    async function loadObligation(id) {
        if (obligationCache.has(id)) return obligationCache.get(id);
        const rows = await fetchRows("obligations", { id, status: "" });
        const ob = rows[0] || {};
        obligationCache.set(id, ob);
        return ob;
    }

    function parseJsonArray(raw) {
        if (Array.isArray(raw)) return raw;
        if (!raw) return [];
        try { const x = JSON.parse(raw); return Array.isArray(x) ? x : []; } catch { return []; }
    }

    async function saveMappings() {
        message.hidden = true;
        const requirementId = Number(requirementSelect.value || 0);
        if (!requirementId) {
            showError("Pick a Practice before saving.");
            return;
        }
        const selects = Array.from(matrixBody.querySelectorAll("select[data-matrix-row]"));
        const mappings = selects.map(sel => {
            const idx = Number(sel.dataset.matrixRow);
            const row = matrixRows[idx] || {};
            const obligationId = Number(sel.value || 0);
            if (!obligationId) return null;
            return {
                releaseId: Number(row.ReleaseId || row.releaseId || 0),
                frameworkStatementId: Number(row.FrameworkStatementId || row.frameworkStatementId || 0) || null,
                obligationId
            };
        }).filter(Boolean);

        try {
            saveBtn.disabled = true;
            await fetchJson(`${buildBaseUrl()}/obligation-mapping-bulk`, {
                method: "POST",
                headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
                body: JSON.stringify({ id: null, data: { requirementId, mappings } })
            });
            showSuccess(mappings.length
                ? "Obligation mappings saved."
                : "All obligation mappings for this Requirement were cleared.");
            setTimeout(goBack, 800);
        } catch (error) {
            showError(error.message);
        } finally {
            saveBtn.disabled = false;
        }
    }

    function goBack() {
        if (ctx.returnUrl && /^\/(?!\/)/.test(ctx.returnUrl))
            window.location.assign(ctx.returnUrl);
        else
            window.location.assign("/Repository/Index?areaKey=obligation-mappings");
    }

    function showError(text) {
        message.textContent = text || "Something went wrong.";
        message.classList.remove("success");
        message.classList.add("error");
        message.hidden = false;
        window.scrollTo({ top: 0, behavior: "smooth" });
    }
    function showSuccess(text) {
        message.textContent = text;
        message.classList.add("success");
        message.classList.remove("error");
        message.hidden = false;
    }
    function escapeHtml(value) {
        return String(value ?? "").replace(/[&<>"']/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
    }
})();
