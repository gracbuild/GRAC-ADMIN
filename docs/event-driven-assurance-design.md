# Event-Driven Assurance — Architecture Note

**Problem.** An Assurance obligation may be *scheduled* (quarterly, annually) or
*event-driven* (every time a person is onboarded, every time an asset is
decommissioned). For event-driven assurance, each occurrence of the event must
produce a checklist of every applicable assurance, which someone completes and
saves.

**Status.** Phases A, B, C and the SLA half of D implemented (migrations 033–038 +
screens), unverified — see §9–§12. Three Phase D items remain, two of them
blocked — see §12.

---

## 1. The decision that matters most

The requirement spans **two layers that must not be conflated**:

| | Definition layer | Runtime layer |
|---|---|---|
| Example | "Assurance X is triggered by People / Onboarding" | "Rahul was onboarded on 28-Jul; here are his 7 checks" |
| Volume | Tens of rows, rarely changed | Thousands of rows, created constantly |
| Who writes | Compliance author (maker) | HR / ops staff doing the actual work |
| Governance | **Maker-checker** — this is policy | **Direct write** — this is operational data |
| Lives in | `requirement_obligation` + specs | New occurrence / checklist tables |

**If runtime checklist completion is routed through `change_management`, every new
employee generates seven approval requests.** That would make the approval queue
unusable within a week and would be the single worst mistake available here.

Concretely: register the new runtime entities in `cm_entity_master` with
`is_maker_checker = 0`. Only the *definition* side joins the existing
obligation approval bundle.

---

## 2. Model the cascade as a tree, not as columns

The naive reading of the requirement is three new columns:

```
trigger_mode      Scheduled | EventDriven
event_domain      People | Asset
event_name        Onboarding | Offboarding | Commissioned | Decommissioned
```

Do not do this. The first time someone asks for *Vendor → Contract Signed* or
*Application → Go-Live*, it needs a schema change, a dispatcher change, and a
front-end change. The cascade is a **taxonomy tree**; model it as one.

### `event_type_master` (self-referencing)

| Column | Notes |
|---|---|
| `event_type_id` | PK |
| `parent_event_type_id` | NULL = domain root; otherwise the domain |
| `event_code` | `PEOPLE`, `PEOPLE_ONBOARDING`, `ASSET_DECOMMISSIONED` |
| `event_name` | `People`, `Onboarding` |
| `subject_entity` | `cm_user`, `asset`, … — what record the event attaches to |
| `display_order`, `status`, audit cols | standard |

Seed:

```
People            (root, subject_entity = 'cm_user')
  ├─ Onboarding
  └─ Offboarding
Asset             (root, subject_entity = 'asset')
  ├─ Commissioned
  └─ Decommissioned
```

This satisfies "ella optionum table-nnu edukkanam" completely — every dropdown
level reads from this one table, and adding a whole new domain is an INSERT.
No schema change, no code change, no release.

`subject_entity` is what later lets a checklist point at a real record. It is
the seam that makes the runtime layer possible; without it the occurrence has
nothing to attach to.

---

## 3. Definition layer — extend the existing spec

`obligation_assurance_spec` already exists (migration 026) and is 1:1 with an
Assurance obligation. Extend it rather than adding a parallel table:

| New column | Notes |
|---|---|
| `trigger_mode_id` | → `reference_option`, group `assurance-trigger-modes` (`Scheduled` / `EventDriven`) |
| `event_type_id` | → `event_type_master`, **leaf only**. NULL when Scheduled |

`assurance_frequency_id` (already present) stays and is used when Scheduled.

Enforce mutual exclusivity with a CHECK constraint — a spec is either scheduled
*or* event-driven, never both, never neither:

```sql
CHECK (
  (trigger_mode = 'Scheduled'   AND event_type_id IS NULL)
  OR
  (trigger_mode = 'EventDriven' AND event_type_id IS NOT NULL)
)
```

Because `obligation_assurance_spec` is already carried by the composite save and
the approval bundle, **the definition side needs no new governance work** — the
two new columns ride along in the existing `obligation-assurance` sub-entity.

---

## 4. Runtime layer — three new tables

### `assurance_event_occurrence`
One row each time an event actually happens.

| Column | Notes |
|---|---|
| `occurrence_id` | PK |
| `event_type_id` | → leaf event type |
| `subject_entity` / `subject_record_id` | polymorphic pointer, e.g. `cm_user` / 4021 |
| `subject_label` | denormalized display, e.g. `Rahul K — EMP1042` |
| `occurred_dt` | when the event happened |
| `raised_by`, `raise_source` | `Manual` \| `System` |
| `status` | `Open` \| `Completed` \| `Cancelled` |

`subject_label` is denormalized deliberately — the checklist must still read
correctly after the underlying user record is renamed or deactivated.

### `assurance_checklist_item`
One row per (occurrence × applicable assurance obligation), generated when the
occurrence is raised.

| Column | Notes |
|---|---|
| `checklist_item_id` | PK |
| `occurrence_id` | → occurrence |
| `obligation_id`, `assurance_spec_id` | which rule produced this item |
| `verification_method_snapshot` | **snapshot**, see below |
| `assurance_party_snapshot` | ditto |
| `due_dt` | derived from occurrence + SLA |
| `status` | `Pending` \| `Completed` \| `Not Applicable` |
| `response_value` | `Pass` \| `Fail` \| `NA` |
| `remarks`, `completed_by`, `completed_dt` | |

### `assurance_checklist_evidence`
Uploaded proof per checklist item (many per item).

### Why snapshot the method text

This is an audit system. If the obligation is edited in 2027, a checklist
completed in 2026 must still show **what was actually asked at the time**. If
the checklist joins live to the obligation, editing a rule silently rewrites
history. Snapshot the human-readable fields; keep the FK for traceability.

---

## 5. Generation

```
raise occurrence (event_type = PEOPLE_ONBOARDING, subject = cm_user/4021)
        │
        ▼
sp_cm_assurance_occurrence_raise
        │  selects every Active Assurance obligation whose spec has
        │  trigger_mode = EventDriven AND event_type_id = PEOPLE_ONBOARDING
        ▼
insert one assurance_checklist_item per match (with snapshots)
```

Idempotency matters: raising the same event twice for the same subject must not
double the checklist. Enforce with a filtered unique index on
`(event_type_id, subject_entity, subject_record_id, occurred_dt)` — or make the
raise SP a no-op when an Open occurrence already exists for that tuple.

**Applicability.** Not every onboarding check applies to every hire — role,
department, and location will eventually filter the set. Phase 1 can generate
for all, but leave the seam: an `applicability_rule` FK on the spec, reusing the
table that already exists rather than inventing a second rules engine.

---

## 6. What is missing in this codebase today

- **There is no asset register.** Only `cm_user` exists — no `asset`, `vendor`,
  or `employee` table anywhere in `database/`. Asset events can be *defined* in
  the taxonomy immediately, but nothing can raise them until a register exists.
  People events are fully implementable today.
- **Question-level responses.** `assurance_starter_template_question` exists,
  which suggests assurance may eventually be question-by-question rather than
  one Pass/Fail per obligation. That materially changes
  `assurance_checklist_item` — it would need a child response table. This needs
  deciding before Phase B is built, not after.

---

## 7. Suggested phasing

| Phase | Scope | Ships value? |
|---|---|---|
| **A** | `event_type_master` + seed, `reference_option` trigger modes, two columns on `obligation_assurance_spec`, cascading selects on the Obligation form | Yes — authors can classify assurance correctly |
| **B** | Occurrence + checklist tables, generation SP, manual "Raise Event" screen, checklist fill screen | Yes — the loop works end-to-end, manually triggered |
| **C** | Auto-raise hook from User Management (onboarding/offboarding) | Yes — no manual step |
| **D** | Applicability filtering, due dates / SLA, reminders, asset register + asset events | Incremental |

Phase A is genuinely self-contained and low-risk: it only adds a lookup tree and
two nullable columns that flow through the approval bundle already built.

---

## 8. Open decisions

1. **Checklist granularity** — one Pass/Fail per obligation, or per-question
   responses using the existing assurance question templates?
2. **Who completes it** — the operational user performing the onboarding (HR),
   or a compliance reviewer? Drives assignment, notification, and permissions.
3. **Does completion need its own review step?** A checklist is operational, but
   an organisation may still want a second pair of eyes on a *Fail*. If so, that
   is a lightweight status transition on the item — still not `change_management`.
4. **Asset register** — is one planned? Asset events are inert without it.

---

## 9. Phase A — what shipped, and how to verify it

**Nothing below has been executed.** No SQL Server or .NET toolchain was
available where it was written. JavaScript passes `node --check` (syntax only).

### Files

| File | Change |
|---|---|
| `033_event_type_taxonomy.sql` (+ rollback) | `event_type_master` tree + seed, `assurance-trigger-modes` options, two new columns on `obligation_assurance_spec` with a mutual-exclusivity CHECK, `sp_cm_event_type_list`, `event-types` read branch |
| `034_assurance_trigger_procs.sql` (+ rollback) | assurance get/save carry the new columns; dispatcher forwards `triggerModeId` / `eventTypeId` |
| `002_control_management_procedures.sql` | two lookup groups added to the `lookups` union |
| `RegulatoryRepositoryService.cs`, `RepositoryController.cs`, `ControlManagementGatewayController.cs` | `event-types` registered for routing, allow-list and RBAC alias |
| `obligation-master-form.js` | Trigger Mode → Domain → Event cascade on the Assurance typed panel |

### Deployment order

```
002_control_management_procedures.sql   (re-run — modified)
033_event_type_taxonomy.sql
034_assurance_trigger_procs.sql
```

Rollback is the reverse, and **034's rollback must run before 033's** — otherwise
the procs would briefly reference columns that no longer exist. 034's rollback
also requires re-running `030_...override.sql` to restore the dispatcher.

### Tests

- [ ] Apply 002 → 033 → 034 cleanly; re-running each is a no-op.
- [ ] `SELECT * FROM GRAC_New.event_type_master` shows People (Active, `cm_user`)
      with Onboarding / Offboarding, and Asset (**Inactive**) with
      Commissioned / Decommissioned.
- [ ] `dotnet build ControlManagement.sln` succeeds.
- [ ] Obligation form, type = **Assurance**: Trigger Mode appears with two options.
- [ ] Choose **Scheduled** → Assurance Frequency shows; Domain and Event do not.
- [ ] Choose **Event Driven** → Domain and Event show; Frequency does not.
- [ ] Domain lists **People only** — Asset is seeded Inactive and must not appear.
- [ ] Event dropdown is disabled until a domain is picked, then lists
      Onboarding / Offboarding.
- [ ] Save with Event Driven + Onboarding; reopen and confirm all three levels
      pre-select (this exercises `EventDomainId` from the get proc).
- [ ] Switch a saved event-driven spec back to **Scheduled**, save, and confirm
      `event_type_id` is NULL — not left stale. A stale value violates
      `ck_cm_assurance_spec_trigger`.
- [ ] Try to save Event Driven with no event → blocked client-side; if forced
      past the UI, `THROW 52834`.
- [ ] Confirm a **pre-033 assurance spec** still loads and saves with both
      columns NULL (the CHECK permits the un-classified state).
- [ ] Confirm the composite save still routes through the approval bundle and
      that the two new keys survive an approve.

### Known gaps

1. **Asset events are seeded Inactive on purpose.** There is no asset register
   in this database, so an asset event could be selected but never raised.
   Flip to Active in the same release that introduces the register.
2. **Trigger modes are carried by two parallel lookup groups**
   (`assurance-trigger-modes` for the label, `assurance-trigger-mode-codes` for
   the stable `option_value`). The `lookups` projection is a flat
   `(key, value, label)` union with no room for a code column, and the cascade
   must branch on the code — branching on the display label would break the
   moment someone renames "Event Driven" in admin. Slightly redundant, but
   data-driven and single-round-trip.
3. **No admin screen for the event taxonomy yet.** Adding a domain or event is
   currently an INSERT. That is by design for Phase A — but a CRUD screen
   should land before non-technical users are expected to extend it.

---

## 10. Phase B — what shipped, and how to verify it

**Nothing below has been executed.** No SQL Server or .NET toolchain was
available where it was written. JavaScript passes `node --check` only.

### Files

| File | Change |
|---|---|
| `035_assurance_runtime_schema.sql` (+ rollback) | `assurance_event_occurrence`, `assurance_checklist_item`, `assurance_checklist_evidence`; entity + menu registration |
| `036_assurance_runtime_procs.sql` (+ rollback) | raise / list / complete / reopen / cancel / subject picker + `cm_get_assurance_runtime` and `cm_manage_assurance_runtime` |
| `RegulatoryRepositoryService.cs` | `AssuranceRuntimeEntities` routing set, checked first in both dispatch chains |
| `RepositoryController.cs` (API) | entity types allow-listed; `AssuranceRuntimePermissionAliases` maps sub-reads to the `assurance-occurrences` area |
| `RepositoryCommandValidator.cs` | multi-shape branch: RAISE contract applies only when the action is RAISE |
| `ControlManagementGatewayController.cs` | permission alias for the sub-reads |
| `RepositoryScreen.cs` | Event Checklists grid registered |
| `RepositoryController.cs` (Web) | `EventChecklist` and `RaiseEvent` actions |
| `EventChecklistForm.cshtml` + `event-checklist-form.js` + `event-checklist-form.css` | checklist fill page |
| `RaiseEventForm.cshtml` + `raise-event-form.js` | Domain → Event → Subject cascade |
| `repository.js` | grid routes Add to Raise Event, row click to the checklist |

### Deployment order

```
035_assurance_runtime_schema.sql
036_assurance_runtime_procs.sql
```

Rollback is the reverse — **036's rollback must run before 035's**, otherwise
procedures are left referencing dropped tables.

### Tests

- [ ] Apply 035 → 036 cleanly; re-running each is a no-op.
- [ ] `dotnet build ControlManagement.sln` succeeds.
- [ ] Confirm both runtime entities are registered with **`is_maker_checker = 0`**:
      `SELECT entity_code, is_maker_checker FROM GRAC_New.cm_entity_master
       WHERE entity_code LIKE 'assurance-%';`
- [ ] Event Checklists appears in the sidebar for CM_ADMIN.

**Raise**

- [ ] Configure an Assurance obligation as Event Driven → People / Onboarding.
- [ ] Raise Event: Domain lists People only (Asset is seeded Inactive).
- [ ] Event dropdown stays disabled until a domain is chosen; Subject stays
      disabled until an event is chosen.
- [ ] Subject list resolves real `cm_user` rows.
- [ ] Raise → confirm one occurrence row plus one checklist item per matching
      assurance, each carrying a **snapshot** of the verification method.
- [ ] Raise the same event for the same subject again → blocked with `52905`,
      not a raw unique-index violation.

**Complete**

- [ ] Checklist page shows the snapshot text, not a live obligation read.
- [ ] Pass / Not Applicable save without remarks.
- [ ] **Fail without remarks is blocked** — Save disabled client-side, `52914`
      server-side.
- [ ] Completing the last pending item flips the occurrence to Completed.
- [ ] Reopen returns the item to Pending **and** the occurrence to Open.
- [ ] Cancel requires a reason (`52915`) and leaves the row in place.

**Governance — the property this design exists to protect**

- [ ] Complete a checklist item and confirm **no `change_management` row is
      created**. If one appears, the runtime layer has been wired to
      maker-checker and the approval queue will drown.

**Snapshot integrity**

- [ ] Raise a checklist, then edit the obligation's verification method, then
      reopen the checklist. The item must still show the **original** wording.

### Known gaps

1. **Raising is manual.** No hook into user creation yet — that is Phase C.
2. **No applicability filtering.** Every matching assurance is generated for
   every subject; role / department / location filtering is Phase D. The
   deliberate direction to be wrong in: an extra item can be marked Not
   Applicable, a missing item goes unnoticed.
3. **`due_dt` is never populated.** The column exists and the grid reads it,
   but nothing computes an SLA yet.
4. **Evidence upload is schema-only.** `assurance_checklist_evidence` exists
   and is projected by the read proc, but no upload UI is wired.
5. **The Raise Event preview is approximate.** The obligations list does not
   carry the trigger classification, so the preview states an upper bound
   rather than the exact set. The authoritative count comes back from
   `sp_cm_assurance_occurrence_raise`.

---

## 11. Phase C — auto-raise for People events

**Nothing below has been executed.**

Migration `037_assurance_autoraise_people.sql` (+ rollback) makes People events
raise themselves: creating or reactivating a user raises `PEOPLE_ONBOARDING`,
deactivating one raises `PEOPLE_OFFBOARDING`, each generating its checklist
exactly as the manual path does.

### Why a trigger, not a branch in `cm_manage_repository`

User Management can run under maker-checker. When it does, a SAVE does **not**
write `cm_user` — it writes a `change_management` row and returns; the real
INSERT happens later when the checker approves and the payload is replayed with
`__approvalBypass = 1`.

A hook inside the SAVE branch would fire on the **request**, raising a checklist
for a user who does not exist yet and may never be approved. A trigger fires
when the row actually appears, which is correct under both modes and needs no
knowledge of the approval machinery.

### The trigger cannot be allowed to fail

It sits in the write path of user creation. A compliance-configuration problem
must never stop an administrator from creating a user.

**`TRY/CATCH` is not sufficient protection.** The caller sets `XACT_ABORT ON`,
so an error inside a trigger dooms the outer transaction whether or not it is
caught. The only real defence is a body that cannot raise an error:

- event types resolved by JOIN — a missing or inactive event yields no rows;
- existing Open occurrences excluded by `NOT EXISTS` — the unique index is
  never violated;
- `subject_label` is `LEFT()`-truncated — `user_name(200)` + `login_id(160)`
  can exceed the 300-char column, which would otherwise raise a
  string-truncation error on an ordinary long name;
- no `THROW`, no casts, no arithmetic.

### One matching rule, not two

`fn_cm_assurance_specs_for_event` holds "which assurances does this event
raise?". Both the manual proc (re-emitted in 037 to use it) and the trigger
call it.

Written twice, the two would drift — someone adds applicability filtering in
Phase D, updates one path, and manual and automatic checklists quietly stop
matching. An inline TVF still inlines into the caller's plan, so both paths
stay set-based.

### Off switch

```sql
UPDATE GRAC_New.reference_option SET status = 'Inactive'
WHERE option_group = 'assurance-settings' AND option_value = 'people-autoraise';
```

Reversible in one statement, leaves the trigger in place. Prefer this over
dropping the trigger — worth having for something in the path of every user
write.

### Tests

- [ ] Apply 037; re-running is a no-op.
- [ ] Create a user with an Onboarding assurance configured → one occurrence
      (`raise_source = 'System'`) plus its checklist appears automatically.
- [ ] Edit that user's name or email → **no** new occurrence (status unchanged).
- [ ] Deactivate the user → an Offboarding occurrence appears.
- [ ] Reactivate → an Onboarding occurrence appears (the reactivation path).
- [ ] Create a user while an Open Onboarding occurrence already exists for them
      → no duplicate, no error.
- [ ] Create a user with **no** event-driven assurance configured → user is
      created normally, no occurrence, no error.
- [ ] **Set the event type Inactive, then create a user** → user is created
      normally and nothing is raised. This is the "trigger cannot break user
      creation" property; if user creation fails here, the guard has a hole.
- [ ] Create a user whose name + login exceeds 300 characters → succeeds, label
      truncated. This is the most likely real-world truncation failure.
- [ ] Bulk-insert several users in one statement → one occurrence each, not
      just for the first row.
- [ ] Set the off switch Inactive, create a user → nothing raised.
- [ ] Under maker-checker on User Management: SAVE raises **nothing**; the
      occurrence appears only when the checker approves.
- [ ] Manual Raise Event still works and produces an identical checklist to the
      automatic path (both now share the TVF).

### Known gaps

1. **People only.** Asset events remain seeded Inactive with no register to
   hang off, so nothing auto-raises for them.
2. **`raise_source` is the only provenance.** The trigger does not record which
   administrator's action caused the raise — `entered_by` is `'system'`.
   Correlating to the actor means joining `audit_trace` by timestamp.
3. **Reactivation is treated as onboarding.** A user going Inactive → Active
   raises a fresh Onboarding checklist. That is usually right for a rehire, and
   defensible for a reactivated account, but it is a policy assumption worth
   confirming with compliance.

---

## 12. Phase D — SLA and due dates (and what remains)

**Nothing below has been executed.**

Phase D was scoped as four items. Investigation before building showed they are
not equally buildable, so only the SLA work was done.

| Item | State |
|---|---|
| **SLA / due dates** | **Built** — migration 038 |
| Role-based applicability | Partially blocked |
| Evidence upload | Blocked |
| Asset register | Oversized — own project |

### What shipped

`038_assurance_sla_due_dates.sql` (+ rollback) closes a loop left open since
035: `assurance_checklist_item.due_dt` existed and the UI already read it, but
nothing ever populated it.

- `obligation_assurance_spec.sla_days` (NULL = no deadline)
- the shared TVF carries it; both the manual proc and the auto-raise trigger
  resolve it into a concrete `due_dt`
- `sp_cm_assurance_checklist_list` projects `IsOverdue` / `DaysRemaining` and
  sorts overdue first
- `sp_cm_assurance_occurrence_list` adds `OverdueItems` / `NextDueOn` and
  sorts occurrences with overdue work above merely-open work
- "Due Within (days)" on the Obligation form, visible only for event-driven
  assurance
- due badges on the checklist page; overdue count in the summary

### Three decisions worth knowing

**An interval, not a date.** The rule applies to every future occurrence, so it
cannot carry an absolute date. It carries "within N days", which the runtime
layer resolves against `occurred_dt` — and then **freezes** on the item, in the
same spirit as the wording snapshots. Editing the SLA next year must not
silently re-date a checklist raised last year.

**On the spec, not the event.** Two assurances raised by the same onboarding
event can legitimately differ — issue a laptop in 2 days, complete security
training in 30. An SLA on the event type would force them to share one.

**`IsOverdue` is computed server-side**, against database time, in one place.
Recomputing it in the browser would let the definition drift between screens
and would let a wrong client clock mark work overdue.

`sla_days` is deliberately **not** defaulted to a number — inventing a deadline
for every historical spec would manufacture fake overdue items on the day this
ships.

### Tests

- [ ] Apply 038; re-running is a no-op.
- [ ] `dotnet build ControlManagement.sln` succeeds.
- [ ] Existing assurance specs load and save with `sla_days` NULL.
- [ ] "Due Within (days)" appears only when Trigger Mode is Event Driven.
- [ ] Set it to 7, raise the event → every item's `due_dt` is `occurred_dt + 7`.
- [ ] Leave it blank → `due_dt` is NULL and no badge renders.
- [ ] Back-date an occurrence past its SLA → items show Overdue, sort to the
      top, and the summary shows the overdue count.
- [ ] Complete an overdue item → the badge disappears entirely. A completed
      item is never overdue.
- [ ] **Change the SLA on the spec after raising a checklist** → the existing
      checklist's dates must NOT move. This is the freeze property.
- [ ] Switch a spec from Event Driven to Scheduled → `sla_days` clears.
- [ ] Reject `sla_days` of -1 and 99999 (`52836`, and the CHECK as backstop).
- [ ] Auto-raise (Phase C) produces the same due dates as a manual raise.

### Why the other three were not built

**Role-based applicability — partially blocked.** `cm_user` has only
`user_id, user_name, login_id, email, password_hash, status, remarks` plus audit
columns. There is **no department, location, or organization link** — an
`organization` table exists but nothing joins users to it. So applicability
could filter by *role* (via `cm_user_role`) and nothing else. If department or
location filtering is wanted, `cm_user` must gain those attributes first, which
is a change to User Management rather than to this feature.

**Evidence upload — blocked on a storage decision.** This application has **no
persistent file storage at all**: Bulk Upload parses spreadsheets in memory and
discards them. `assurance_checklist_evidence.file_reference` implies external
storage, but nothing exists to reference. Needs a call on filesystem path vs
Azure Blob vs database `varbinary` before any code is worth writing.

**Asset register — own project.** A whole new register plus CRUD screens, then
wiring asset events to it and flipping the Asset branch Active. Would unblock
`Commissioned` / `Decommissioned`, which remain seeded Inactive and inert.

### Remaining gaps in the SLA work itself

1. **No reminders or escalation.** Overdue items are visible only to someone
   who opens the screen. Notifications would need a scheduled job, which this
   application does not currently have.
2. **`due_dt` is calendar days, not working days.** A 2-day SLA raised on a
   Friday is due Sunday. Working-day arithmetic needs a holiday calendar.
3. **No occurrence-level SLA.** Each item carries its own deadline; there is no
   "the whole onboarding must be done within 30 days" rollup beyond `NextDueOn`.
