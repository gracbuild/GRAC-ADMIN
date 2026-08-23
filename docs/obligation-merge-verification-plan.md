# Obligation Master Merge — Verification Plan

**Scope:** Merging "Obligation Master" and "Manage Obligation Type Details" into a
single form, saved as one atomically-approved change bundle.

**Status:** Code complete for Phases 1–3b. **Nothing in this change set has been
executed** — no SQL Server or .NET toolchain was available in the environment
where it was written. Every item below is unverified. JavaScript has passed
`node --check` only (syntax, not behaviour).

---

## 1. Architecture decisions (locked)

| # | Decision | Choice |
|---|---|---|
| 1 | Change request granularity | **One row per sub-entity** (not one composite row) — preserves granular audit history |
| 2 | Bundle linkage | **New `bundle_id` column**, not `parent_change_request_id` (that already encodes Authority→Artifact→Release hierarchy) |
| 3 | Atomicity enforcement | **Database-enforced**, not UI-enforced |
| 4 | Approval mode | **Bundle inherits the master's** approval mode |
| 5 | Legacy contract | `'obligations'` entity type and payload **left untouched**; composite is a new additive `'obligation-composite'` type |
| 6 | Form location | **Dedicated full-page form**, not an extension of the shared `repository.js` dialog |
| 7 | Type change on edit | **Confirm, then discard** the old typed detail |

---

## 2. Deployment order

Migrations must be applied in this order. `002` must be re-run because it now
declares the bundle columns and contains the bundle interception logic.

```
002_control_management_procedures.sql      (re-run — modified)
031_change_management_bundle.sql
032_obligation_composite_dispatcher.sql
```

Rollback order is the reverse:

```
032_obligation_composite_dispatcher_rollback.sql
031_change_management_bundle_rollback.sql
```

> `031`'s rollback **deliberately refuses** to drop `bundle_id` while any bundled
> row exists — dropping it would orphan the grouping and silently re-enable
> partial approval. It drops the procedures and index, then halts with
> remediation SQL.

---

## 3. Pre-flight checks

- [ ] `002` applies cleanly on a **fresh** database (validates that
      `cm_get_repository` compiles against the newly-declared `bundle_id`).
- [ ] `002` applies cleanly on an **existing** database (validates the guarded
      `ALTER TABLE` upgrade path).
- [ ] `031` and `032` apply cleanly; re-running each is a no-op.
- [ ] `dotnet build ControlManagement.sln` succeeds.
- [ ] Error codes `50070`–`50073` and `50080`–`50085` do not collide.
      *(Checked statically against `002`, which tops out at `50065`.)*

---

## 4. Core functional tests

### 4.1 Composite save — maker-checker ON

- [ ] Create a new obligation with type `State`, typed detail, 2 evidence rows,
      1 evidence link. Save.
- [ ] Confirm N rows in `change_management` share one `bundle_id`, with
      `bundle_seq` = 1 (master), 2 (type assignment), 3 (typed detail), 4+ (links).
- [ ] `EXEC dbo.sp_cm_change_bundle_list @p_status = N'Pending Approval'` returns
      **one** row for the bundle with the correct `SubEntityCount`.
- [ ] Checker queue shows **one** parent row with an "N linked" badge, expandable
      to show each sub-entity.
- [ ] Approve. Confirm master, type assignment, typed detail, and links all
      applied, and every bundle row is `Approved`.

### 4.2 Late binding (the subtle one)

- [ ] For the **new** obligation above, confirm the dependent rows were submitted
      with `obligationId = 0` and that `sp_cm_change_bundle_approve` back-filled
      the real id before applying them.
- [ ] Confirm the typed detail and evidence links are attached to the correct
      parent obligation — not to id 0 or to another obligation.

### 4.3 Atomicity — the property this whole change exists for

- [ ] Force a mid-bundle failure (e.g. tamper a bundle row's payload to reference
      an invalid `evidenceTypeId`), then approve.
- [ ] **Confirm nothing applied** — no master row, no type assignment, no typed
      detail. All bundle rows remain `Pending Approval`.
- [ ] Attempt to approve a **single** bundle row directly via the API
      (`POST /change-management/{id}/approve`). Confirm the whole bundle is
      actioned, not just that row. *This is the partial-approval hole; it must be
      closed at the database, not just hidden in the UI.*
- [ ] Reject a bundle. Confirm all rows move to `Rejected` together and nothing
      was applied.
- [ ] Send back a bundle. Confirm all rows move to `Sent Back`.

### 4.4 Composite save — maker-checker OFF / auto-approve

- [ ] With approval disabled for `obligations`, save a composite. Confirm it
      applies directly with no `change_management` rows.
- [ ] With self-approval enabled and the maker holding APPROVE, confirm the whole
      bundle auto-approves (Decision 4 — bundle inherits master's mode).

### 4.5 Edit flows

- [ ] Edit an existing obligation. Confirm the form pre-selects the saved type and
      loads its typed detail. **This exercises the `id` vs `obligationId` query
      parameter fix — if typed detail loads empty, that regression is back.**
- [ ] Confirm existing evidence rows populate.
- [ ] Change the type on an obligation that has authored detail. Confirm the
      discard-confirmation appears; Cancel reverts the dropdown; Confirm clears
      the fields and saves a fresh typed-detail row.
- [ ] Change the type on an obligation with **no** authored detail. Confirm it
      switches silently with no prompt.

### 4.6 Similar Obligations (duplicate detection)

> Regression caught during review: the merged form initially dropped this
> entirely. The shared dialog wired it through `similarConfigs["obligations"]`,
> which the full-page form does not use.

- [ ] Type a keyword that an existing obligation already carries. Confirm the
      "Similar Obligations Found" grid appears **below the Keywords field**.
- [ ] Confirm matching substrings are highlighted in the result rows.
- [ ] Confirm the grid shows Obligation Name, Execution Frequency, Assurance
      Frequency, Retention Period, Evidence Count, Existing Keywords, Status.
- [ ] Confirm column sorting and the quick-filter search box work.
- [ ] Clear the Keywords box. Confirm the grid collapses and hides completely.
- [ ] Type a keyword no obligation uses. Confirm "No similar records found."
- [ ] **Edit** an existing obligation with saved keywords. Confirm the grid
      populates on open, and that the record being edited does **not** appear in
      its own similar list (`@p_id` self-exclusion).
- [ ] Confirm the grid is warn-only — it must never block Save.

---

## 5. Regression — must not break

- [ ] **Obligation Mapping** (the earlier multi-obligation change): a Statement /
      Release cell still accepts multiple obligations; chips load, save, and
      removal works.
- [ ] **Legacy `'obligations'` entity type** still works for any direct API
      caller using the original payload contract.
- [ ] Single-row (non-bundled) change requests approve, reject, and send back
      exactly as before — `bundle_id IS NULL` must take the original path.
- [ ] Authority → Artifact → Release chained approval still cascades correctly
      (`parent_change_request_id` behaviour must be untouched).
- [ ] Every other repository screen still opens its form — `repository.js`
      `openForm` was modified.
- [ ] Assurance Management screens unaffected.
- [ ] Audit trace still renders.

---

## 6. Known gaps / accepted risk

1. **`COMMIT` before delegating.** The bundle interception in
   `cm_manage_repository` commits its own transaction before calling the bundle
   procedures, assuming `@@TRANCOUNT = 1`. True on the normal API path. If
   something ever wraps `cm_manage_repository` in an outer transaction, the
   isolation boundary shifts. Watch for unexpected locking during testing.

2. **`applied_record_id` not captured for some sub-entities.**
   `sp_cm_obligation_type_assign` returns 2 columns and
   `sp_cm_obligation_evidence_link_attach` returns 3, so `INSERT ... EXEC` cannot
   capture an id for them. Those rows apply correctly but leave
   `applied_record_id` NULL. They are identified by their parent obligation, so
   this is cosmetic in the audit trail.

3. **Evidence reuse (M:M) is not exposed.** A "Linked Evidence Specs" section
   was prototyped and **removed before release**. The data layer is intact and
   untouched — the six per-type link tables from 026,
   `sp_cm_obligation_evidence_link_attach` / `_detach`, and the
   `obligation-evidence-links` entity type all remain. What was missing was the
   workflow:

   - no screen authors a standalone reusable spec, even though
     `requirement_obligation_evidence.obligation_id` was made nullable in 026
     precisely to allow them — so every "linkable" spec is really owned by
     another obligation;
   - standalone `Evidence`-type obligations cannot use link tables at all
     (`sp_..._link_attach` throws `52874`);
   - the prototype was attach-only, with no detach reconciliation, so removing
     a chip and saving left the link in place;
   - two evidence sections on one form read as near-duplicates.

   Evidence Details covers the normal case. Reuse should return as its own
   piece of work: an Evidence Spec library screen plus a picker that offers
   only genuinely shared specs.

4. **`ObligationTypeDetailForm` retained.** The page, its JS, and its controller
   action still exist as a fallback route with no menu entry or button. Delete
   only after a verified stable release — see Phase 4 below.

---

## 7. Phase 4 — deferred deletion

Do **not** run this until the above passes on a real environment and one stable
release has shipped.

Files to remove once verified:

- `src/ControlManagement.Web/Views/Repository/ObligationTypeDetailForm.cshtml`
- `src/ControlManagement.Web/wwwroot/js/obligation-type-detail-form.js`
- `RepositoryController.ObligationTypeDetail` action

Retaining them costs nothing and preserves a working fallback if the merged form
has to be backed out. Deleting them early removes the only escape hatch.
