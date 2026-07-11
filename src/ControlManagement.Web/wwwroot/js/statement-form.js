(() => {
  "use strict";

  const cfg = window.cmStatementForm || {};
  const api = cfg.api || "";
  const mode = String(cfg.mode || "add").toLowerCase();
  const readonly = mode === "view";
  const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || "";
  const pathBase = (window.cmPathBase || "").replace(/\/$/, "");
  const appUrl = path => `${pathBase}${path}`;
  const appAlert = (message, type = "info", title = "") => window.gracAlert ? window.gracAlert({ message, type, title }) : Promise.resolve(window.alert(message));

  const form = document.querySelector("#statementForm");
  const message = document.querySelector("#statementMessage");
  const saveButton = document.querySelector("#statementSave");
  const backButton = document.querySelector("#statementBack");
  const releaseInput = document.querySelector("#field-releaseId");
  const classificationSelect = document.querySelector("#field-classificationId");
  const classificationField = classificationSelect?.closest(".form-field");
  const releaseContextText = document.querySelector("#releaseContextText");
  const sourceInput = document.querySelector("#field-structureNodeId");
  const sourceTree = document.querySelector("#statementSourceTree");
  const title = document.querySelector("#statementPageTitle");

  const state = {
    record: {},
    releases: [],
    nodes: [],
    selectedNodeId: cfg.nodeId ? String(cfg.nodeId) : "",
    collapsed: new Set(),
    lockedRelease: Number(cfg.releaseId || 0) > 0 && Number(cfg.nodeId || 0) > 0,
    lockedNode: Number(cfg.nodeId || 0) > 0,
    autoStatementReference: ""
  };

  const escapeHtml = value => String(value ?? "").replace(/[&<>"']/g, char => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;" })[char]);
  const dataOf = result => result.data?.[0] || result.Data?.[0] || [];
  const valueOf = (row, name) => row?.[name] ?? row?.[name[0].toUpperCase() + name.slice(1)] ?? "";
  const showMessage = text => { message.textContent = text; message.hidden = false; };
  const clearMessage = () => { message.textContent = ""; message.hidden = true; };

  async function fetchJson(url, options) {
    let response;
    try {
      response = await fetch(url, options);
    } catch {
      throw new Error(`Unable to reach the ControlManagement API at ${api}.`);
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
    return dataOf(await fetchJson(`${api}/${entity}?${qs}`));
  }

  function option(label, value, selected = false) {
    return `<option value="${escapeHtml(value)}"${selected ? " selected" : ""}>${escapeHtml(label)}</option>`;
  }

  function releaseLabel(row) {
    return [row.ArtifactCode || row.Artifact, row.Version || row.Release].filter(Boolean).join(" / ") || `Release #${row.Id}`;
  }

  function selectedSourceNode() {
    return state.nodes.find(row => String(row.Id) === String(state.selectedNodeId)) || null;
  }

  function sourceNodeReleaseId(row) {
    return String(row?.ReleaseId || row?.releaseId || "");
  }

  function releaseLabelFromSourceNode(row) {
    return [row?.ArtifactCode || row?.Artifact, row?.Version || row?.Release].filter(Boolean).join(" / ");
  }

  async function ensureReleaseLabel(releaseId = "") {
    const id = String(releaseId || releaseInput.value || "");
    const nodeLabel = releaseLabelFromSourceNode(selectedSourceNode());
    if (nodeLabel) {
      releaseContextText.textContent = `Release: ${nodeLabel}`;
      return;
    }
    if (!id) {
      releaseContextText.textContent = "Select a source node to load classifications.";
      return;
    }
    let release = state.releases.find(row => String(row.Id) === id);
    if (!release) {
      const rows = await fetchRows("releases", { releaseId: id, status: "" });
      state.releases = state.releases.filter(row => String(row.Id) !== id).concat(rows);
      release = rows[0];
    }
    releaseContextText.textContent = release ? `Release: ${releaseLabel(release)}` : `Release #${id}`;
  }

  async function loadClassifications(selectedId = "") {
    const releaseId = releaseInput.value;
    const rows = releaseId ? await fetchRows("statement-classifications", { releaseId, status: "" }) : [];
    classificationField.hidden = false;
    if (!rows.length) {
      classificationSelect.innerHTML = option("No classifications configured", "");
      classificationSelect.disabled = true;
      console.debug("Statement classifications loaded", { releaseId, count: 0 });
      return;
    }
    classificationSelect.disabled = readonly;
    classificationSelect.innerHTML = `${option("None", "")}${rows.map(row => option(row.ClassificationName || row.Name || `Classification #${row.Id}`, row.Id, String(row.Id) === String(selectedId))).join("")}`;
    console.debug("Statement classifications loaded", { releaseId, count: rows.length });
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

  function sourceTreeLabel(row) {
    return [row.Reference, row.Title].filter(Boolean).join(" - ") || row.NodeType || `Node #${row.Id}`;
  }

  function sourceTreePath(id) {
    const byId = new Map(state.nodes.map(row => [String(row.Id), row]));
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

  function sourceReference(id) {
    const row = state.nodes.find(item => String(item.Id) === String(id));
    return String(row?.Reference || row?.Code || "").trim();
  }

  function syncStatementReferenceFromSource(id) {
    const input = document.querySelector("#field-statementReference");
    if (!input || input.readOnly || input.disabled) return;
    const next = sourceReference(id);
    if (!next) return;
    if (!input.value.trim() || input.value.trim() === state.autoStatementReference) {
      input.value = next;
      state.autoStatementReference = next;
    }
  }

  function renderSourceTree() {
    if (!state.nodes.length) {
      sourceTree.innerHTML = `<div class="source-tree-empty">No source structure configured.</div>`;
      sourceInput.value = "";
      return;
    }
    const selectedPath = state.selectedNodeId ? sourceTreePath(state.selectedNodeId) : "";
    if ((readonly || state.lockedNode) && selectedPath) {
      sourceTree.innerHTML = `<div class="source-tree-selected readonly"><strong>Selected:</strong> ${escapeHtml(selectedPath)}</div>`;
      sourceInput.value = state.selectedNodeId;
      return;
    }
    const walk = (items, depth = 0) => items.map(item => {
      const row = item.row;
      const id = String(row.Id);
      const hasChildren = item.children.length > 0;
      const collapsed = state.collapsed.has(id);
      const selected = state.selectedNodeId === id;
      const toggle = hasChildren ? `<button type="button" class="map-tree-toggle" data-source-toggle="${escapeHtml(id)}"><i class="fa-solid fa-chevron-${collapsed ? "right" : "down"}"></i></button>` : `<span class="map-tree-spacer"></span>`;
      return `<div class="map-tree-row source-tree-option${hasChildren ? " parent" : ""}${selected ? " selected" : ""}" role="radio" aria-checked="${selected ? "true" : "false"}" tabindex="${readonly ? "-1" : "0"}" style="--tree-depth:${depth}" data-source-row="${escapeHtml(id)}">
        ${toggle}
        <span class="source-tree-check" aria-hidden="true">${selected ? `<i class="fa-solid fa-check"></i>` : ""}</span>
        <span class="map-node-text" title="${escapeHtml(sourceTreePath(id))}">${escapeHtml(sourceTreeLabel(row))}</span>
      </div>${collapsed ? "" : walk(item.children, depth + 1)}`;
    }).join("");
    sourceTree.innerHTML = `<div class="source-tree-selected">${selectedPath ? `<strong>Selected:</strong> ${escapeHtml(selectedPath)}` : "Select one source structure node."}</div><div class="source-tree-list">${walk(buildTree(state.nodes))}</div>`;
    sourceInput.value = state.selectedNodeId || "";
  }

  async function loadSourceTree(selectedId = "") {
    const releaseId = releaseInput.value;
    state.selectedNodeId = selectedId ? String(selectedId) : "";
    state.nodes = await fetchRows("source-structure", releaseId ? { releaseId, status: "Active" } : { status: "Active" });
    if (state.selectedNodeId && !state.nodes.some(row => String(row.Id) === state.selectedNodeId)) state.selectedNodeId = "";
    const nodeReleaseId = sourceNodeReleaseId(selectedSourceNode());
    if (nodeReleaseId) releaseInput.value = nodeReleaseId;
    renderSourceTree();
    await ensureReleaseLabel();
  }

  async function loadRecord() {
    if (!cfg.id) return {};
    const row = (await fetchRows("framework-statements", { id: cfg.id, status: "" }))[0] || {};
    state.record = row;
    return row;
  }

  function setValue(name, value) {
    const element = document.querySelector(`#field-${name}`);
    if (element) element.value = value ?? "";
  }

  function setReadonlyFields() {
    form.querySelectorAll("input, textarea, select").forEach(element => {
      if (readonly) element.disabled = true;
    });
  }

  function collect() {
    const data = {
      releaseId: releaseInput.value,
      structureNodeId: sourceInput.value,
      classificationId: classificationSelect.disabled ? "" : classificationSelect.value,
      statementReference: document.querySelector("#field-statementReference").value.trim(),
      statementTitle: document.querySelector("#field-statementTitle").value.trim(),
      statementText: document.querySelector("#field-statementText").value.trim(),
      statementType: document.querySelector("#field-statementType").value.trim(),
      displayOrder: Number(document.querySelector("#field-displayOrder")?.value || 0),
      status: document.querySelector("#field-status")?.value || "Active",
      remarks: document.querySelector("#field-remarks").value.trim()
    };
    const missing = [];
    if (!data.releaseId) missing.push("Release");
    if (!data.structureNodeId) missing.push("Source Structure Node");
    if (!data.statementReference) missing.push("Statement Reference");
    if (!data.statementText) missing.push("Statement Text");
    if (!data.status) missing.push("Status");
    if (missing.length) throw new Error(`Complete the required fields: ${missing.join(", ")}.`);
    return data;
  }

  function returnBack() {
    const target = cfg.returnUrl && cfg.returnUrl.startsWith(window.location.origin)
      ? cfg.returnUrl
      : appUrl("/Repository/Index/framework-statements");
    window.location.assign(target);
  }

  async function save() {
    try {
      clearMessage();
      const result = await fetchJson(`${api}/framework-statements`, {
        method: "POST",
        headers: { "Content-Type":"application/json", "X-CSRF-TOKEN":csrfToken },
        body: JSON.stringify({ id: cfg.id || null, data: collect() })
      });
      const row = dataOf(result)[0] || {};
      const pending = String(row.Status || row.status || "").toLowerCase() === "pending approval";
      if (pending) await appAlert("Change submitted for approval. The main record will update after checker approval.", "success", "Submitted");
      returnBack();
    } catch (error) {
      showMessage(error.message);
    }
  }

  async function init() {
    try {
      clearMessage();
      const record = await loadRecord();
      const selectedReleaseId = valueOf(record, "releaseId") || cfg.releaseId || "";
      const selectedNodeId = valueOf(record, "structureNodeId") || cfg.nodeId || "";
      const selectedClassificationId = valueOf(record, "classificationId") || "";

      releaseInput.value = String(selectedReleaseId || "");
      await loadSourceTree(selectedNodeId);
      await loadClassifications(selectedClassificationId);

      setValue("statementReference", valueOf(record, "statementReference") || "");
      setValue("statementTitle", valueOf(record, "statementTitle") || "");
      setValue("statementText", valueOf(record, "statementText") || "");
      setValue("statementType", valueOf(record, "statementType") || "");
      setValue("displayOrder", valueOf(record, "displayOrder") || 0);
      setValue("remarks", valueOf(record, "remarks") || "");

      const statuses = ["Active", "Draft", "Published", "Retired", "Inactive"];
      const selectedStatus = valueOf(record, "status") || "Active";
      const statusField = document.querySelector("#field-status");
      if (statusField) statusField.innerHTML = statuses.map(item => option(item, item, item === selectedStatus)).join("");

      if (!cfg.id && cfg.nodeId && !document.querySelector("#field-statementReference").value.trim()) {
        syncStatementReferenceFromSource(cfg.nodeId);
      }
      if (mode === "edit") title.textContent = "Edit Source Statement";
      if (mode === "view") title.textContent = "View Source Statement";
      setReadonlyFields();
    } catch (error) {
      showMessage(error.message);
    }
  }

  sourceTree.addEventListener("click", event => {
    const toggle = event.target.closest("[data-source-toggle]");
    if (toggle) {
      const id = toggle.dataset.sourceToggle;
      state.collapsed.has(id) ? state.collapsed.delete(id) : state.collapsed.add(id);
      renderSourceTree();
      return;
    }
    const row = event.target.closest("[data-source-row]");
    if (!row || readonly || state.lockedNode) return;
    state.selectedNodeId = row.dataset.sourceRow;
    sourceInput.value = state.selectedNodeId;
    syncStatementReferenceFromSource(state.selectedNodeId);
    const nodeReleaseId = sourceNodeReleaseId(selectedSourceNode());
    const releaseChanged = nodeReleaseId && String(releaseInput.value) !== String(nodeReleaseId);
    if (nodeReleaseId) releaseInput.value = nodeReleaseId;
    renderSourceTree();
    ensureReleaseLabel()
      .then(() => releaseChanged ? loadClassifications("") : null)
      .catch(error => showMessage(error.message));
  });

  document.querySelector("#field-statementReference").addEventListener("input", event => {
    if (event.target.value.trim() !== state.autoStatementReference) state.autoStatementReference = "";
  });
  saveButton?.addEventListener("click", save);
  backButton.addEventListener("click", returnBack);

  init();
})();
