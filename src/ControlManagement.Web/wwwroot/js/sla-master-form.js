/* SLA Master form controller (Views/Repository/SlaMasterForm.cshtml).
   Populates the Process / Classification / Time Basis / Status dropdowns,
   loads the existing record on edit / view / inactive, and wires Save,
   Deactivate and Cancel through the /control-management-gateway/sla-master
   endpoints. */
(() => {
  "use strict";

  const cfg = window.cmSlaMasterForm || {};
  const api = cfg.api || "";
  const mode = String(cfg.mode || "add").toLowerCase();
  const slaId = Number(cfg.slaId || 0);
  const isView = mode === "view";
  const isInactive = mode === "inactive";
  const isEdit = mode === "edit";
  const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || "";
  // Resolved against the application root (see gracUrl in site.js).
  const appUrl = path => window.gracUrl.app(path);
  const appAlert = (message, type = "info", title = "") =>
    window.gracAlert ? window.gracAlert({ message, type, title }) : Promise.resolve(window.alert(message));
  const appConfirm = (message, options = {}) =>
    window.gracConfirm
      ? window.gracConfirm({ message, type: options.type || "warning",
                             title: options.title || "Please confirm",
                             confirmText: options.confirmText || "Continue",
                             cancelText: options.cancelText || "Cancel" })
      : Promise.resolve(window.confirm(message));

  /* Process list -- hardcoded from the Obligation Definition workbook.
     A lookup endpoint would be nicer, but with 13 fixed values this
     keeps the form self-contained and the seed data in one place. */
  const PROCESSES = [
    "Gap Analysis",
    "Gap Remediation",
    "Risk Assessment",
    "Risk Treatment",
    "Exception Approval",
    "Exception Action",
    "Exception Review",
    "Task Execution",
    "Continuous Assurance",
    "Event Assurance",
    "Obligation Fulfilment",
    "Custom Task",
    "Periodic Review"
  ];

  const $ = sel => document.querySelector(sel);
  const message   = $("#slaMessage");
  const idInput   = $("#sla-id");
  const process   = $("#sla-process");
  const classify  = $("#sla-classification");
  const durValue  = $("#sla-duration-value");
  const durUnit   = $("#sla-duration-unit");
  const timeBasis = $("#sla-time-basis");
  const warningIn = $("#sla-warning-pct");
  const escalIn   = $("#sla-escalation-pct");
  const status    = $("#sla-status");
  const effective = $("#sla-effective-from");
  const remarks   = $("#sla-remarks");
  const saveBtn   = $("#slaSave");
  const inactiveBtn = $("#slaDeactivate");
  const cancelBtn = $("#slaCancel");

  const showMessage = (text, isError = true) => {
    if (!message) return;
    message.textContent = text;
    message.classList.toggle("error", isError);
    message.hidden = false;
  };
  const clearMessage = () => { if (message) { message.textContent = ""; message.hidden = true; } };

  async function fetchJson(url, options) {
    let response;
    try { response = await fetch(url, options); }
    catch { throw new Error(`Unable to reach the ControlManagement API at ${api}.`); }
    let result;
    try { result = await response.json(); }
    catch { throw new Error("The repository service returned an invalid response."); }
    if (response.status === 401) throw new Error("Your session has expired. Please sign in again.");
    if (response.status === 403) throw new Error("You do not have permission to perform this action.");
    if (!(result.success ?? result.Success))
      throw new Error(result.message || result.Message || "Request failed.");
    return result;
  }

  const dataOf = result => result.data?.[0] || result.Data?.[0] || [];
  const valueOf = (row, name) =>
    row?.[name] ?? row?.[name[0].toUpperCase() + name.slice(1)] ?? "";

  function option(label, value, selected = false) {
    const val = String(value ?? "");
    return `<option value="${val}"${selected ? " selected" : ""}>${label}</option>`;
  }

  function populateProcesses(selected = "") {
    process.innerHTML =
      option("-- Select Process --", "") +
      PROCESSES.map(p => option(p, p, p === selected)).join("");
  }

  function populateStatus(selected = "Active") {
    if (!status) return;
    status.innerHTML = ["Active", "Inactive"]
      .map(s => option(s, s, s === selected))
      .join("");
  }

  async function loadRecord() {
    if (!slaId) return {};
    const rows = dataOf(await fetchJson(`${api}/sla-master?id=${slaId}`));
    return rows[0] || {};
  }

  function collect() {
    const process_ = process.value.trim();
    const cls      = classify.value.trim();
    const dv       = durValue.value.trim();
    const du       = durUnit.value.trim();
    const tb       = timeBasis.value.trim();
    const wp       = warningIn.value.trim();
    const ep       = escalIn.value.trim();
    const statusV  = status?.value?.trim() || "Active";
    const missing = [];
    if (!process_) missing.push("Process");
    if (!cls)      missing.push("Classification");
    if (!dv)       missing.push("Duration Value");
    if (!du)       missing.push("Duration Unit");
    if (!tb)       missing.push("Time Basis");
    if (!wp)       missing.push("Warning %");
    if (!ep)       missing.push("Escalation %");
    if (missing.length) throw new Error(`Complete the required fields: ${missing.join(", ")}.`);

    const warning    = Number(wp);
    const escalation = Number(ep);
    if (!(warning > 0 && warning < 100))    throw new Error("Warning % must be between 1 and 99.");
    if (!(escalation > 0 && escalation <= 100)) throw new Error("Escalation % must be between 2 and 100.");
    if (!(warning < escalation))            throw new Error("Warning % must be strictly less than Escalation %.");

    const duration = Number(dv);
    if (!Number.isInteger(duration) || duration < 1 || duration > 3650)
      throw new Error("Duration Value must be an integer between 1 and 3650.");

    return {
      processCode:    process_,
      classification: cls,
      durationValue:  duration,
      durationUnit:   du,
      timeBasis:      tb,
      warningPct:     warning,
      escalationPct:  escalation,
      effectiveFrom:  effective?.value || null,
      remarks:        remarks?.value || null,
      status:         statusV
    };
  }

  function returnBack() {
    // Referer-derived: honoured only when it points inside this application.
    window.location.assign(window.gracUrl.safeReturn(cfg.returnUrl, "/Repository/Index/sla-master"));
  }

  async function save() {
    try {
      clearMessage();
      const data = collect();
      await fetchJson(`${api}/sla-master`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ id: slaId || null, data })
      });
      await appAlert(slaId ? "SLA updated successfully." : "SLA saved successfully.", "success", "Saved");
      returnBack();
    } catch (error) {
      showMessage(error.message);
    }
  }

  async function deactivate() {
    try {
      clearMessage();
      const reason = (remarks?.value || "").trim();
      if (!reason) throw new Error("Deactivation reason is required.");
      const confirmed = await appConfirm(
        "Mark this SLA inactive? The pair will remain in history and can be re-created.",
        { confirmText: "Mark Inactive", type: "warning" }
      );
      if (!confirmed) return;
      /* Reuse the standard Save endpoint so change-management tracking
         picks the event up like any other edit; the payload's status +
         remarks drive the SP's INACTIVE branch. */
      await fetchJson(`${api}/sla-master`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({
          id: slaId,
          data: { status: "Inactive", remarks: reason }
        })
      });
      await appAlert("SLA deactivated.", "success", "Inactive");
      returnBack();
    } catch (error) {
      showMessage(error.message);
    }
  }

  function applyRecord(record) {
    const rec = record || {};
    idInput.value    = valueOf(rec, "slaCode") || (slaId ? `SLA-${String(slaId).padStart(3, "0")}` : "");
    populateProcesses(valueOf(rec, "process") || valueOf(rec, "processCode") || "");
    classify.value   = valueOf(rec, "classification") || "";
    durValue.value   = valueOf(rec, "durationValue") || "";
    durUnit.value    = valueOf(rec, "durationUnit") || "";
    timeBasis.value  = valueOf(rec, "timeBasis") || "";
    warningIn.value  = valueOf(rec, "warningPct") || 75;
    escalIn.value    = valueOf(rec, "escalationPct") || 90;
    const eff = valueOf(rec, "effectiveFrom");
    if (effective && eff) effective.value = String(eff).slice(0, 10);
    /* On inactive-mode load we deliberately DO NOT prefill remarks --
       the field is now a mandatory deactivation reason and reusing the
       existing text would let the user save an empty reason. */
    if (remarks && !isInactive) remarks.value = valueOf(rec, "remarks") || "";
    populateStatus(valueOf(rec, "status") || "Active");
    if (isInactive && status) status.value = "Inactive";
  }

  async function init() {
    try {
      clearMessage();
      const record = await loadRecord();
      applyRecord(record);
    } catch (error) {
      /* Add mode has no record to load, so a 404-ish message is expected;
         only surface errors when we actually asked for a record. */
      if (slaId) showMessage(error.message);
      else applyRecord({});
    }
  }

  saveBtn?.addEventListener("click", save);
  inactiveBtn?.addEventListener("click", deactivate);
  cancelBtn?.addEventListener("click", returnBack);

  init();
})();
