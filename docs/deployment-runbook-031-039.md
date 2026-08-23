# Deployment Runbook — migrations 031–039

Covers two features built together:

- **Obligation Master merge** (031–032) — one form, one atomic approval bundle
- **Event-driven Assurance** (033–038) — trigger classification, checklists,
  auto-raise, SLA

**Database layer verified.** `039` passes 24/24 and `041` passes 11/11,
including both load-bearing checks — M8 (a bundle with one bad row applies
nothing) and M10 (approving a single row from the checker UI actions the whole
bundle, so partial approval is impossible).

**Still unverified:** `dotnet build ControlManagement.sln` has never been run,
and the three new screens (Obligation Master, Event Checklists, Raise Event)
have not been exercised in a browser. Everything proven so far sits at the
stored-procedure level; nothing has yet gone through the encrypted-envelope
gateway end to end.

---

## 1. Apply order

Strict. Each script preflight-guards its dependency, but a wrong order fails
late and confusingly.

| # | Script | Notes |
|---|---|---|
| 1 | `002_control_management_procedures.sql` | **Re-run — modified.** Adds `bundle_id`/`bundle_seq` to the `change_management` CREATE TABLE, the bundle interception in the `change-management` branch, `TypeCode` on the obligations GET, and two lookup groups |
| 2 | `031_change_management_bundle.sql` | bundle columns + atomic approve/reject/send-back |
| 3 | `032_obligation_composite_dispatcher.sql` | `obligation-composite` entity type |
| 4 | `033_event_type_taxonomy.sql` | event tree, trigger modes, spec columns |
| 5 | `034_assurance_trigger_procs.sql` | assurance get/save carry the classification |
| 6 | `035_assurance_runtime_schema.sql` | occurrence / checklist / evidence tables |
| 7 | `036_assurance_runtime_procs.sql` | raise / complete / reopen / cancel |
| 8 | `037_assurance_autoraise_people.sql` | shared TVF + `cm_user` trigger |
| 9 | `038_assurance_sla_due_dates.sql` | `sla_days` and due-date computation |
| 10 | `040_assurance_raise_insert_exec_fix.sql` | fixes the `INSERT ... EXEC` defect found by 039 G1 |
| 11 | `039_assurance_smoke_test.sql` | **verification — changes nothing** |

Then build and deploy the application: `dotnet build ControlManagement.sln`.

### Why 002 must be re-run first

`cm_get_repository` now projects `BundleId`. On a fresh database the column
would not exist yet and the procedure would fail to compile — so `002` declares
`bundle_id` in its own CREATE TABLE, and `031` keeps a guarded `ALTER` for
databases that predate it. Both are guarded; order between those two does not
matter, but `002` must precede everything that reads the new columns.

---

## 1a. Re-running migrations — replay in order, never selectively

Every script is individually idempotent (`CREATE OR ALTER`, guarded `ALTER`), and
that used to be described as "safe to re-run". That claim was true of each file
alone and **false in combination**, which is worse — nothing warns you.

The trap: several migrations re-emit a procedure that a *later* migration then
corrects. Re-running the earlier file on its own silently reinstates the old
body. `sp_cm_assurance_occurrence_raise` was the sharp case — it was emitted by
`036`, `037`, `038` and `040`, and `040` exists purely to fix a defect
(`Msg 3916`, `ROLLBACK` inside `INSERT ... EXEC`) that `039` check G1 catches.
Re-running `038` alone put that bug straight back into production, and also
dropped the `due_dt` computation.

**Fixed by giving the procedure one owner.** `037` and `038` no longer emit it;
they now carry a comment explaining why. Ownership is `036` (creates it) →
`040` (final version). The other sections of `037` and `038` are unchanged.

Rules:

- **Full replay, in table order.** That always converges on the correct final state.
- **Never re-run a single migration in isolation** to "refresh" an object.
- After any replay that includes `036`–`038`, **re-run `040`**, then `039` to confirm.
- `039` and `041` change nothing and can be run at any time to prove the state.

Objects emitted by more than one migration (last one wins on a full replay):
`cm_get_obligation_taxonomy`, `cm_manage_obligation_taxonomy`,
`sp_cm_assurance_checklist_list`, `sp_cm_assurance_occurrence_list`,
`sp_cm_assurance_occurrence_raise`, `sp_cm_obligation_assurance_get`,
`sp_cm_obligation_assurance_save`, `fn_cm_assurance_specs_for_event`,
`tr_cm_user_assurance_autoraise`.

### Failed migrations report as failed

Preflight guards originally used `RAISERROR` + `RETURN`. `RETURN` only aborts
its own batch, so every batch after the next `GO` still ran and the closing
`PRINT` announced success — a failed migration looked like a clean one. All
guards now use `SET NOEXEC ON`, with a matching `SET NOEXEC OFF` at end of file
so the session is left clean. Applied across `031`–`038` and `040`.

---

## 2. Verification

Two scripts, both safe on any environment including production — each rolls
itself back:

```sql
:r 039_assurance_smoke_test.sql   -- event-driven assurance  (033-038, 040)
:r 041_bundle_approval_smoke_test.sql  -- obligation merge   (031-032)
```

They cover different halves of the work and neither substitutes for the other.
`039` verifies the assurance runtime; `041` verifies that one Save produces a
linked bundle which is then approved or rejected **as a unit**.

### 041 — bundle approval

`M0` is a pre-check: if maker-checker has been disabled for obligations in this
environment, the composite applies directly and M1–M10 are not meaningful. Read
M0 first.

**Load-bearing:**

| Check | Asserts |
|---|---|
| **M8** | A bundle containing one bad row applies **nothing** — not even the master, which applies first |
| **M10** | Approving **one** row through the ordinary change-management path actions the **whole** bundle. Without this the UI could approve the master alone — exactly the partial approval the bundle exists to prevent |

`M6` is also worth watching: dependent rows are submitted with
`obligationId = 0` because the master does not exist yet, and are back-filled at
approval time. If it fails, typed detail is being orphaned.

### 039 — event-driven assurance

Twenty-four checks. **Four are load-bearing** — if any reads FAIL,
stop and understand it before deploying:

| Check | Asserts | Why it matters |
|---|---|---|
| **B1** | runtime entities are `is_maker_checker = 0` | If 1, every checklist completion raises an approval request — one per assurance per person. The checker queue becomes unusable in weeks |
| **F1** | editing a rule does not rewrite a raised checklist | This is an audit system. A 2026 checklist must still show what was asked in 2026 |
| **J1** | completion writes no `change_management` row | Same property as B1, observed from the other end |
| **L1** | user creation succeeds when the event is misconfigured | The auto-raise trigger sits in the write path of User Management. It must never be able to block it |

`039` runs in one transaction and rolls back, so it leaves no fixture data.
It can be re-run freely.

---

## 2b. Contract audit — done, clean

The smoke test verifies the database. A separate static audit checked the
front-end/back-end contracts, which is the bug class it structurally cannot
reach. All clean:

| Checked | Result |
|---|---|
| Every entity type the new JS calls is in the API allow-list | 12/12 present |
| Routing reaches the right dispatcher for each | correct, runtime checked first in both chains |
| `obligation-composite` payload keys vs SP reads | exact match |
| All six typed-detail schemas (JS `TYPE_SCHEMA`) vs dispatcher branches | exact match, including `eventDomainId` correctly excluded as transient |
| Runtime write payloads (raise / complete / reopen) vs `cm_manage_assurance_runtime` | exact match |
| Every column the checklist page reads vs the two runtime procs | all projected |
| Every column the obligation form reads vs `obligations` / `obligation-assurance` / `event-types` | all projected |
| Brace balance in all six edited C# files | balanced |
| Views, scripts and stylesheets referenced by new actions | all exist |
| Helpers the new controller actions call | all exist |
| `RepositoryScreen` constructor arity | 29/29 rows consistent |
| JS syntax (`node --check`) on all five touched files | clean |

This does **not** replace `dotnet build` — it cannot catch type errors,
nullability warnings, or analyzer failures. It does mean the most likely
runtime failure mode (a key or column mismatch producing a silently empty
form) has been ruled out.

---

## 3. Manual checks the smoke test cannot cover

Everything in `039` is server-side. These need a browser:

- **Obligation Master** — the merged form saves master + type + typed detail in
  one click; the checker queue shows one grouped card, not N loose rows;
  approving any row of a bundle actions the whole bundle
- **Assurance cascade** — Trigger Mode → Domain → Event; the Asset domain must
  not appear (seeded Inactive); switching back to Scheduled clears the event
- **Event Checklists** — raise an event, complete items, confirm overdue
  styling and that a completed item shows no due badge
- **Similar Obligations** — typing a keyword surfaces existing obligations

Full lists: `docs/obligation-merge-verification-plan.md` and
`docs/event-driven-assurance-design.md` §9–§12.

---

## 4. Rollback

Reverse order, and two pairs have traps.

| # | Script | Trap |
|---|---|---|
| 1 | `038_..._rollback.sql` | — |
| 2 | `037_..._rollback.sql` | Does **not** drop `fn_cm_assurance_specs_for_event` — the manual raise proc depends on it. To remove the function, first re-run `036`, then drop it |
| 3 | `036_..._rollback.sql` | Must run **before** `035`'s, or procedures reference dropped tables |
| 4 | `035_..._rollback.sql` | **Refuses** while any occurrence exists. That data is operational compliance evidence and cannot be regenerated — export first |
| 5 | `034_..._rollback.sql` | Must run **before** `033`'s. Also requires re-running `030` to restore the dispatcher |
| 6 | `033_..._rollback.sql` | **Refuses** while any assurance spec is classified |
| 7 | `032_..._rollback.sql` | Pending bundles remain approvable — `031` applies them, not `032` |
| 8 | `031_..._rollback.sql` | **Refuses** while any bundled `change_management` row exists — dropping `bundle_id` would orphan the grouping and re-enable partial approval |

The three refusals are deliberate. Each prints the query to inspect what is
blocking it and, where safe, the statement to clear it.

### Cheaper alternatives to a full rollback

- **Stop auto-raising** without dropping the trigger:
  ```sql
  UPDATE GRAC_New.reference_option SET status = 'Inactive'
  WHERE option_group = 'assurance-settings' AND option_value = 'people-autoraise';
  ```
- **Hide Event Checklists** without touching the schema: retire the menu row or
  revoke the role permission.

---

## 5. Known-unfinished, by design

| Area | State |
|---|---|
| `ObligationTypeDetailForm` | Retained as an unreachable fallback. Delete only after a verified stable release — see the merge plan §7 |
| Evidence upload | Schema only. This application has **no persistent file storage**; needs a storage decision first |
| Applicability filtering | `cm_user` has no department, location, or organization link. Role-only filtering is possible; anything else needs User Management to change |
| Asset events | Seeded Inactive. No asset register exists |
| Reminders / escalation | Overdue items are visible only to someone who opens the screen. Needs a scheduled job this application does not have |
| Working-day SLA | `due_dt` is calendar days. A 2-day SLA raised Friday falls due Sunday |

---

## 6. Bugs already found and fixed by inspection

Recorded because they indicate the error rate in unverified work, and because
the same mistakes are easy to reintroduce.

| Bug | Consequence had it shipped |
|---|---|
| Subquery inside a CHECK constraint (033) | **Caught at runtime by you** — Msg 1046. Fixed by storing the trigger mode code on the row |
| `INSERT ... EXEC` into a single-column table where the proc returns 2–3 columns (031) | Every bundle approval containing a type assignment would have failed |
| `obligationId` passed as a query param that `RepositoryQuery` does not carry | Typed detail and evidence links would load **silently empty** on every edit |
| `subject_label` not truncated (037) | An ordinary long name would raise a truncation error *inside a trigger* and block user creation |
| Duplicate-raise test placed mid-script (039) | The proc's unnamed `ROLLBACK` would have unwound the smoke transaction, corrupting every later check |
| CHECK test reusing one obligation (039) | Would have tripped the unique index instead and reported PASS for the wrong reason |
| One transaction wrapping the whole smoke test (039) | **Caught at runtime by you** — Msg 3930. See below |
| `ROLLBACK` inside `sp_cm_assurance_occurrence_raise` (038) | **Caught by the smoke test, check G1** — Msg 3916. Any caller capturing the returned `OccurrenceId` via `INSERT ... EXEC` got an opaque error instead of the intended 52905. Fixed in `040` |

### The Msg 3930 lesson — worth knowing beyond this script

The first version of `039` wrapped every check in one transaction. It failed with:

> Msg 3930 — The current transaction cannot be committed and cannot support
> operations that write to the log file.

Cause: several checks deliberately provoke an error, and those errors are raised
inside procedures that `SET XACT_ABORT ON`. That **dooms the enclosing
transaction** — `XACT_STATE()` becomes `-1`. Catching the error does not un-doom
it; every subsequent write fails, including inserts into the results table
variable.

This is not specific to the smoke test. **Any** caller that opens a transaction
and then calls one of these procedures expecting to trap a failure and continue
will hit the same wall. If application code ever needs "try this, and carry on
if it fails", the call must sit in its own transaction, not inside a wider one.

`039` now gives each check its own transaction, and every `CATCH` rolls back
*before* recording its result.
