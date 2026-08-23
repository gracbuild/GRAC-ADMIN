/*
  Practices - Obligation Mapping (full-page form).

  Flow:
    1. Page loads with empty matrix.
    2. User picks a Requirement (or the page boots with a Requirement pre-set
       from query string / from the row the user clicked Edit on).
    3. We call obligation-mapping-matrix to get every Statement / Release row
       reachable from that Requirement plus every currently-active obligation
       mapped for that (req, rel, stmt) cell (aggregated as a CSV of IDs).
    4. Each row gets a chip-based multi-picker so ONE or MANY obligations may
       be attached to the same Statement / Release cell.  Chips can be removed
       with the "x" button; new obligations are added from the "+ Add
       Obligation" dropdown that filters out already-picked options.
    5. Save posts to obligation-mapping-bulk; the SP de-activates removed
       rows and inserts new ones (compare on the (req, rel, stmt, obligation)
       tuple, so multiple obligations per cell are supported).  Cancel returns
       to the list grid.
*/
(function () {
    const ctx = window.cmObligationMappingForm || {};
    const api = (ctx.api || "").replace(/\/$/, "");
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || "";
    // Resolved against the application root (see gracUrl in site.js).
    const appUrl = path => window.gracUrl.app(path);
    const message = document.querySelector("#omMessage");
    const requirementSelect = document.querySelector("#om-requirement");
    const matrixBody = document.querySelector("#om-matrix-body");
    const saveBtn = document.querySelector("#omSave");
    const cancelBtn = document.querySelector("#omCancel");
    const readonly = ctx.mode === "view";

    let requirementOptions = [];
    let obligationOptions = [];
    let obligationLabelById = new Map();
    // Source Statement eligibility (056).  obligationId -> Set<releaseId> of the
    // releases the obligation declared source statements against, from
    // 'obligation-statement-releases'.  An obligation that mapped no statements
    // is simply absent from this map, and absent means UNRESTRICTED -- it keeps
    // appearing on every row, which is what stops this feature from hiding
    // every obligation created before it existed.
    let releasesByObligation = new Map();
    let matrixRows = [];
    // Live selection state per matrix row: rowIndex -> Array<string obligationId>.
    // Populated on load from MappedObligationIdsCsv and mutated in place as the
    // user adds / removes chips.  Serialized on Save.
    let rowSelections = [];
    // Obligation details cache (keyed by obligationId) - keeps the inline
    // preview snappy so re-rendering after a re-selection doesn't re-fetch.
    const obligationCache = new Map();
    // Preview expansion state - keyed by "rowIndex:obligationId" so re-renders
    // keep each obligation card in whichever state the user left it.
    const previewExpanded = new Set();
    // Add-Obligation combo state.  A plain <select> made the user scroll a list
    // that grows with every obligation in the library, so the picker is a
    // trigger + search box + filtered option list instead.  Only one combo is
    // open at a time; the query is per-combo and cleared when it closes.
    let openComboRow = null;
    let comboQuery = "";
    // How many matches the list shows before it asks the user to keep typing.
    // Deep enough to browse, shallow enough that the row never becomes a page.
    const COMBO_MAX_OPTIONS = 50;

    init().catch(error => showError(error.message));

    async function init() {
        await Promise.all([loadRequirements(), loadObligationLookup(), loadStatementEligibility()]);

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
        // De-duplicated on Value: /lookups unions several branches with a
        // catch-all, so the same obligation can come back more than once and
        // would otherwise appear twice in every picker on the matrix.
        const seen = new Set();
        obligationOptions = rows
            .filter(row => String(row.LookupKey || row.lookupKey || "").toLowerCase() === "obligations")
            .map(row => ({
                value: String(row.Value || row.value || ""),
                label: String(row.Label || row.label || "")
            }))
            .filter(option => option.value && !seen.has(option.value) && seen.add(option.value));
        obligationLabelById = new Map(obligationOptions.map(o => [o.value, o.label]));
    }

    // One flat read of every active obligation -> release pair, folded into a
    // lookup once.  Cheaper than asking per row: a practice mapped to fifty
    // statements would otherwise mean fifty round-trips for a filter.
    //
    // A failure here degrades to the pre-056 behaviour -- an empty map means
    // every obligation is unrestricted, so the picker shows everything rather
    // than nothing.  Silently showing too much is recoverable; silently
    // showing nothing looks like the obligation library has been wiped.
    async function loadStatementEligibility() {
        try {
            const rows = await fetchRows("obligation-statement-releases", { status: "" });
            releasesByObligation = new Map();
            for (const row of rows) {
                const obligationId = String(row.ObligationId ?? row.obligationId ?? "");
                const releaseId = String(row.ReleaseId ?? row.releaseId ?? "");
                if (!obligationId || !releaseId) continue;
                if (!releasesByObligation.has(obligationId)) releasesByObligation.set(obligationId, new Set());
                releasesByObligation.get(obligationId).add(releaseId);
            }
        } catch {
            releasesByObligation = new Map();
        }
    }

    // The filter rule, in one place.
    //
    // Release level, not statement level: an obligation is authored once for a
    // release and reused across that release's statements, so requiring an
    // exact statement match would force the same fact to be maintained twice.
    //
    // Unmapped obligations pass everything.  That is the whole backward
    // compatibility story: mapping statements NARROWS the picker, mapping none
    // leaves it exactly as it was.
    function isObligationEligible(obligationId, releaseId) {
        const releases = releasesByObligation.get(String(obligationId));
        if (!releases || releases.size === 0) return true;
        return releases.has(String(releaseId));
    }

    function rowReleaseId(row) {
        return String(row?.ReleaseId ?? row?.releaseId ?? "");
    }

    async function loadMatrix(requirementId) {
        message.hidden = true;
        const id = Number(requirementId);
        if (!id) {
            matrixRows = [];
            rowSelections = [];
            renderMatrixEmpty("Pick a Practice to load mapped statement releases.");
            return;
        }
        renderMatrixEmpty("Loading…");
        try {
            matrixRows = await fetchRows("obligation-mapping-matrix", { requirementId: id, status: "" });
        } catch (error) {
            matrixRows = [];
            rowSelections = [];
            showError(error.message);
            renderMatrixEmpty("Could not load the matrix. See the message above for details.");
            return;
        }
        // Seed per-row selections from the CSV the SP now returns.  Fall back
        // to the legacy single-id column for backward compat if the SP hasn't
        // been redeployed yet.
        rowSelections = matrixRows.map(row => {
            const csv = String(row.MappedObligationIdsCsv || row.mappedObligationIdsCsv || "").trim();
            if (csv) return csv.split(",").map(s => s.trim()).filter(Boolean);
            const legacy = String(row.MappedObligationId || row.mappedObligationId || "").trim();
            return legacy ? [legacy] : [];
        });
        previewExpanded.clear();
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

        // Delegated handlers for the Add Obligation combo, chip remove and
        // preview expand toggles.  Bind once per matrixBody so re-renders
        // don't accumulate listeners -- and so a row rebuilt by rerenderRow
        // needs no rewiring.
        if (!matrixBody.dataset.matrixBound) {
            matrixBody.addEventListener("click", event => {
                const comboToggle = event.target.closest("[data-combo-toggle]");
                if (comboToggle) {
                    event.preventDefault();
                    const rowIndex = Number(comboToggle.dataset.comboToggle);
                    if (openComboRow === rowIndex) closeCombo();
                    else openCombo(rowIndex);
                    return;
                }
                const pick = event.target.closest("[data-combo-pick]");
                if (pick) {
                    event.preventDefault();
                    const [rowIndexStr, obligationId] = pick.dataset.comboPick.split("|");
                    openComboRow = null;
                    comboQuery = "";
                    addObligationToRow(Number(rowIndexStr), obligationId);
                    return;
                }
                const removeBtn = event.target.closest("[data-chip-remove]");
                if (removeBtn) {
                    event.preventDefault();
                    const [rowIndexStr, obligationId] = removeBtn.dataset.chipRemove.split("|");
                    removeObligationFromRow(Number(rowIndexStr), obligationId);
                    return;
                }
                const toggle = event.target.closest("[data-preview-toggle]");
                if (toggle) {
                    event.preventDefault();
                    const key = toggle.dataset.previewToggle;
                    if (previewExpanded.has(key)) previewExpanded.delete(key);
                    else previewExpanded.add(key);
                    const [rowIndexStr, obligationId] = key.split("|");
                    updateSinglePreview(Number(rowIndexStr), obligationId);
                }
            });

            matrixBody.addEventListener("input", event => {
                const search = event.target.closest("[data-combo-search]");
                if (!search) return;
                comboQuery = search.value;
                refreshComboOptions(Number(search.dataset.comboSearch));
            });

            // Esc closes the open combo without touching the row's selection.
            matrixBody.addEventListener("keydown", event => {
                if (event.key !== "Escape" || openComboRow === null) return;
                if (!event.target.closest("[data-combo]")) return;
                event.preventDefault();
                const rowIndex = openComboRow;
                closeCombo();
                matrixBody.querySelector(`[data-combo-toggle="${rowIndex}"]`)?.focus();
            });

            // A click anywhere else on the page closes the combo, the way a
            // native <select> drops its list when focus moves away.
            document.addEventListener("mousedown", event => {
                if (openComboRow === null) return;
                if (event.target.closest("[data-combo]")) return;
                closeCombo();
            });

            matrixBody.dataset.matrixBound = "1";
        }

        // Populate preview cards for rows that boot with existing selections.
        rowSelections.forEach((ids, rowIndex) => {
            (ids || []).forEach(id => updateSinglePreview(rowIndex, id));
        });
    }

    function renderRow(row, index) {
        const selectedIds = rowSelections[index] || [];
        const artifact = [row.ArtifactCode, row.Artifact].filter(Boolean).join(" - ");

        const chips = selectedIds.map(id => {
            const label = obligationLabelById.get(id) || `#${id}`;
            const removeBtn = readonly ? "" :
                `<button type="button" class="om-chip-remove" data-chip-remove="${index}|${escapeHtml(id)}" aria-label="Remove ${escapeHtml(label)}">&times;</button>`;
            return `<span class="om-chip" data-chip-obligation="${escapeHtml(id)}" title="${escapeHtml(label)}">
                <span class="om-chip-label">${escapeHtml(label)}</span>
                ${removeBtn}
            </span>`;
        }).join("");

        const addPicker = readonly ? "" : renderAddCombo(index, selectedIds);

        const emptyHint = (readonly && selectedIds.length === 0)
            ? `<span class="om-chip-empty">No obligations mapped.</span>` : "";

        const picker = `<div class="om-chip-picker" data-matrix-row="${index}">
            <div class="om-chip-list" data-chip-list="${index}">${chips}${emptyHint}</div>
            ${addPicker}
        </div>
        <div class="om-row-preview" data-row-preview="${index}" hidden></div>`;

        return `<tr>
            <td title="${escapeHtml(row.Authority || "")}">${escapeHtml(row.Authority || "")}</td>
            <td title="${escapeHtml(artifact)}">${escapeHtml(artifact)}</td>
            <td>${escapeHtml(row.Release || row.ReleaseLabel || "")}</td>
            <td>${escapeHtml(row.StatementReference || "")}</td>
            <td title="${escapeHtml(row.StatementTitle || "")}">${escapeHtml(row.StatementTitle || "")}</td>
            <td class="col-obligation-cell">${picker}</td>
        </tr>`;
    }

    /* ---------- searchable Add Obligation combo ----------
       Rendered inline (not as an absolutely-positioned overlay) because
       .om-table-wrap clips its children -- a floating menu would be cut off on
       the lower rows.  Expanding in flow matches how the preview cards below
       already behave. */
    function renderAddCombo(index, selectedIds) {
        const isOpen = openComboRow === index;
        const label = selectedIds.length === 0 ? "-- Select Obligation --" : "+ Add Obligation";
        return `<div class="om-obligation-combo${isOpen ? " is-open" : ""}" data-combo="${index}">
            <button type="button" class="om-combo-trigger" data-combo-toggle="${index}"
                    aria-expanded="${isOpen}" aria-haspopup="listbox">
                <span class="om-combo-trigger-label">${escapeHtml(label)}</span>
                <i class="fa-solid fa-chevron-down" aria-hidden="true"></i>
            </button>
            <div class="om-combo-panel" data-combo-panel="${index}"${isOpen ? "" : " hidden"}>
                <input type="search" class="om-combo-search" data-combo-search="${index}"
                       placeholder="Type to search obligations..." autocomplete="off"
                       aria-label="Search obligations" value="${escapeHtml(comboQuery)}" />
                <div class="om-combo-options" data-combo-options="${index}" role="listbox">
                    ${renderComboOptions(index, selectedIds)}
                </div>
            </div>
        </div>`;
    }

    // Options for one combo: the obligations eligible for THIS row's release
    // (056), minus whatever is already chipped on the row, then narrowed by
    // the query.  Matching is a plain case-insensitive substring on the label,
    // which is "CODE - Name" -- so a code or any word of the name both find
    // the record.
    function renderComboOptions(index, selectedIds) {
        const ids = selectedIds || rowSelections[index] || [];
        const query = comboQuery.trim().toLowerCase();
        const releaseId = rowReleaseId(matrixRows[index]);
        const eligible = obligationOptions.filter(o => isObligationEligible(o.value, releaseId));
        const available = eligible.filter(o => !ids.includes(o.value));
        const matches = query
            ? available.filter(o => o.label.toLowerCase().includes(query))
            : available;

        // Three distinct empty states, because they call for three different
        // actions.  Collapsing them into one "nothing to show" message sends a
        // maker hunting through the obligation library for a record that is
        // there but filtered out.
        if (eligible.length === 0)
            return `<p class="om-combo-empty">No obligation is mapped to a source statement of this release. Map this release's statements on the Obligation Master screen to list it here.</p>`;
        if (available.length === 0)
            return `<p class="om-combo-empty">Every obligation available for this release is already mapped on this row.</p>`;
        if (matches.length === 0)
            return `<p class="om-combo-empty">No obligation for this release matches "${escapeHtml(comboQuery.trim())}".</p>`;

        const shown = matches.slice(0, COMBO_MAX_OPTIONS);
        const more = matches.length - shown.length;
        return shown.map(o =>
            `<button type="button" class="om-combo-option" role="option"
                     data-combo-pick="${index}|${escapeHtml(o.value)}"
                     title="${escapeHtml(o.label)}">${escapeHtml(o.label)}</button>`).join("")
            + (more > 0
                ? `<p class="om-combo-more">${more} more match${more === 1 ? "" : "es"} -- keep typing to narrow the list.</p>`
                : "");
    }

    function openCombo(rowIndex) {
        const previous = openComboRow;
        openComboRow = rowIndex;
        comboQuery = "";
        if (previous !== null && previous !== rowIndex) rerenderRow(previous);
        rerenderRow(rowIndex);
        matrixBody.querySelector(`[data-combo-search="${rowIndex}"]`)?.focus();
    }

    function closeCombo() {
        if (openComboRow === null) return;
        const rowIndex = openComboRow;
        openComboRow = null;
        comboQuery = "";
        rerenderRow(rowIndex);
    }

    // Re-paints just the option list while the user types, so the search box
    // keeps focus and the caret does not jump.
    function refreshComboOptions(rowIndex) {
        const host = matrixBody.querySelector(`[data-combo-options="${rowIndex}"]`);
        if (host) host.innerHTML = renderComboOptions(rowIndex, rowSelections[rowIndex] || []);
    }

    function rerenderRow(rowIndex) {
        const row = matrixRows[rowIndex];
        if (!row) return;
        // Replace only the obligation cell so the rest of the row stays put.
        const tr = matrixBody.querySelectorAll("tr")[rowIndex];
        if (!tr) return;
        // Build a temporary tr just to lift the fresh cell markup out of it.
        const tmp = document.createElement("tbody");
        tmp.innerHTML = renderRow(row, rowIndex);
        const freshCell = tmp.querySelector("td.col-obligation-cell");
        const oldCell   = tr.querySelector("td.col-obligation-cell");
        if (freshCell && oldCell) oldCell.replaceWith(freshCell);
        // No rewiring needed: every control in the cell is driven by the
        // delegated handlers bound once on matrixBody in renderMatrix().
        // Repopulate previews for whatever obligations are still selected.
        (rowSelections[rowIndex] || []).forEach(id => updateSinglePreview(rowIndex, id));
    }

    function addObligationToRow(rowIndex, obligationId) {
        const ids = rowSelections[rowIndex] || (rowSelections[rowIndex] = []);
        if (ids.includes(obligationId)) return;
        ids.push(obligationId);
        // New selection - expand its preview by default so the user can
        // immediately verify the obligation they picked.
        previewExpanded.add(`${rowIndex}|${obligationId}`);
        rerenderRow(rowIndex);
    }

    function removeObligationFromRow(rowIndex, obligationId) {
        const ids = rowSelections[rowIndex] || [];
        const idx = ids.indexOf(obligationId);
        if (idx < 0) return;
        ids.splice(idx, 1);
        previewExpanded.delete(`${rowIndex}|${obligationId}`);
        rerenderRow(rowIndex);
    }

    async function updateSinglePreview(rowIndex, obligationId) {
        const preview = matrixBody.querySelector(`[data-row-preview="${rowIndex}"]`);
        if (!preview) return;

        const selectedIds = rowSelections[rowIndex] || [];
        if (selectedIds.length === 0) {
            preview.hidden = true;
            preview.innerHTML = "";
            return;
        }
        preview.hidden = false;

        // Ensure a card slot exists for each selected obligation; render or
        // update the specific slot for `obligationId`.
        selectedIds.forEach(id => {
            let slot = preview.querySelector(`[data-preview-slot="${rowIndex}|${escapeSelector(id)}"]`);
            if (!slot) {
                slot = document.createElement("div");
                slot.className = "om-preview-slot";
                slot.dataset.previewSlot = `${rowIndex}|${id}`;
                slot.innerHTML = `<span class="om-preview-loading">Loading obligation details...</span>`;
                preview.appendChild(slot);
            }
        });
        // Drop slots for obligations that were removed from the selection.
        preview.querySelectorAll("[data-preview-slot]").forEach(slot => {
            const [, id] = slot.dataset.previewSlot.split("|");
            if (!selectedIds.includes(id)) slot.remove();
        });

        try {
            const ob = await loadObligation(Number(obligationId));
            const slot = preview.querySelector(`[data-preview-slot="${rowIndex}|${escapeSelector(obligationId)}"]`);
            if (slot) slot.innerHTML = renderInlinePreview(ob, rowIndex, obligationId);
        } catch (error) {
            const slot = preview.querySelector(`[data-preview-slot="${rowIndex}|${escapeSelector(obligationId)}"]`);
            if (slot)
                slot.innerHTML = `<span class="om-preview-error">${escapeHtml(error.message || "Could not load obligation details.")}</span>`;
        }
    }

    // CSS attribute-selector-safe version of an id (digits are fine but we
    // stay defensive in case obligation ids ever become alphanumeric).
    function escapeSelector(value) {
        return String(value ?? "").replace(/["\\]/g, "\\$&");
    }

    // Expandable inline preview card.  Collapsed view: name + summary chips +
    // evidence-type name summary.  Expanded view: additionally shows the full
    // evidence-details table right inside the same card - no separate popup.
    function renderInlinePreview(ob, rowIndex, obligationId) {
        const name          = ob.ObligationName || ob.obligationName || "(unnamed)";
        const exec          = ob.ExecutionFrequency || ob.executionFrequency || "-";
        const assurance     = ob.AssuranceFrequency || ob.assuranceFrequency || "-";
        const retention     = String(ob.RetentionPeriod || ob.RetentionRequirement || ob.retentionPeriod || "").trim() || "-";
        const evidenceTypes = (ob.EvidenceTypes || ob.evidenceTypes || "").trim();
        const evidenceCount = Number(ob.EvidenceCount ?? ob.evidenceCount ?? 0);
        const previewKey    = `${rowIndex}|${obligationId}`;
        const isExpanded    = previewExpanded.has(previewKey);
        const detailsDomId  = `om-preview-details-${rowIndex}-${obligationId}`;

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

        return `<div class="om-preview-card om-preview-card-expandable${isExpanded ? " is-expanded" : ""}" data-preview-card="${previewKey}">
            <div class="om-preview-head">
                <span class="om-preview-name" title="${escapeHtml(name)}">${escapeHtml(name)}</span>
                <button type="button" class="om-preview-toggle" data-preview-toggle="${previewKey}" aria-expanded="${isExpanded ? "true" : "false"}" aria-controls="${detailsDomId}">
                    <span class="om-preview-toggle-label">${isExpanded ? "Hide Details" : "Show Details"}</span>
                    <i class="fa-solid fa-chevron-${isExpanded ? "up" : "down"}" aria-hidden="true"></i>
                </button>
            </div>
            <div class="om-preview-row">${summaryChips}</div>
            ${evidenceTypesSummary}
            <div class="om-preview-details" id="${detailsDomId}"${isExpanded ? "" : " hidden"}>
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
        // Flatten rowSelections into one payload entry per (row, obligation).
        // The SP compares on the (req, rel, stmt, obligation) tuple so multi-
        // obligation cells save cleanly without any additional payload shape.
        const mappings = [];
        matrixRows.forEach((row, idx) => {
            const ids = rowSelections[idx] || [];
            ids.forEach(id => {
                const obligationId = Number(id);
                if (!obligationId) return;
                mappings.push({
                    releaseId: Number(row.ReleaseId || row.releaseId || 0),
                    frameworkStatementId: Number(row.FrameworkStatementId || row.frameworkStatementId || 0) || null,
                    obligationId
                });
            });
        });

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
        // Referer-derived: accepted only when it points inside this application,
        // otherwise fall back to the list grid under the application root.
        window.location.assign(window.gracUrl.safeReturn(ctx.returnUrl, "/Repository/Index?areaKey=obligation-mappings"));
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
