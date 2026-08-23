# Practice Management handoff — event-driven assurance for subscribed organizations

## Why there is a handoff at all

Event-driven assurance is built in Control Management: the obligation, its
assurance spec, the event taxonomy (`event_type_master`), the runtime tables
(`assurance_event_occurrence`, `assurance_checklist_item`) and the raise
procedure all live in the `GRAC_New` schema, governed by this module's
maker-checker.

What Control Management does **not** have is the subject. Today the auto-raise
trigger watches `GRAC_New.cm_user` — the login accounts for the GRC tool
itself. The people whose onboarding actually needs a checklist are the
employees of a subscribing organization, and they live in Practice Management.

## The applicability chain

```
obligation -> practice -> release -> organization subscribes -> that org's employees
              EXISTS      EXISTS      MISSING                    MISSING
```

- "Practice" is `GRAC_New.requirement` (`requirement_code` surfaces as
  PracticeCode, `requirement_name` as PracticeName).
- `GRAC_New.obligation_requirement_release_map` already links obligation ->
  requirement -> release.
- Nothing in Control Management references `GRAC_New.organization`. It has
  **zero foreign keys** pointing at it.
- `fn_cm_assurance_specs_for_event` currently matches on `event_type_id`
  **alone** — no practice, release or subscription filtering. Left as-is, every
  organization would receive every event-driven assurance globally.

## Division of work

**Control Management (this repo) owns:**

- `organization_id` on `assurance_event_occurrence`
- extending `fn_cm_assurance_specs_for_event` to take an organization and join
  through `obligation_requirement_release_map` into the subscription table
- a single entry-point procedure for other modules, roughly:

```sql
sp_cm_assurance_raise_for_person
    @p_organization_id BIGINT,
    @p_person_entity   NVARCHAR(100),   -- the PM employee table
    @p_person_id       BIGINT,
    @p_person_label    NVARCHAR(300),
    @p_event_code      NVARCHAR(60),    -- 'PEOPLE_ONBOARDING' | 'PEOPLE_OFFBOARDING'
    @p_usr_id          NVARCHAR(100)
```

**Practice Management owns:**

- a trigger on its employee table that calls that one procedure

That procedure signature is the entire contract. Practice Management should
never write to the assurance tables directly, and Control Management should
never reach into Practice Management's tables from a trigger. Either shortcut
turns two modules into one.

## Sequencing

1. **Discovery** — Practice Management reports its schema (prompt below). Read
   only, no code changes.
2. **Control Management** — build `organization_id`, the applicability join and
   the entry-point procedure, with a smoke test.
3. **Practice Management** — add the trigger calling the procedure.

Step 3 cannot be done before step 2: the procedure will not exist.

---

## Prompt to paste into the Practice Management module

> This is a **read-only investigation. Do not change any code, schema, or
> files.** I need to document your schema so another module can integrate with
> it. Answer in plain text.
>
> Context: the Control Management module raises compliance checklists
> automatically when a person joins or leaves an organization. Its trigger
> currently watches its own `GRAC_New.cm_user` table, which is wrong — the real
> subjects are the employees managed here. I need to know exactly what your
> tables look like before designing the integration.
>
> Please report:
>
> **1. The employee / person table**
> - Full name including schema, and whether it is in the same database as `GRAC_New`
> - The `CREATE TABLE` DDL, or at minimum: primary key column and type; the
>   column(s) making up a display name; the status column and the exact value
>   meaning "active"
> - Whether rows are ever hard-deleted, or only deactivated
>
> **2. How an employee is linked to an organization**
> - A direct `organization_id` column, or a join table? If a join table, give
>   its DDL
> - Can one employee belong to more than one organization at a time?
> - Does it point at `GRAC_New.organization`, or a different organization table?
>   If different, give that table's name and how the two relate
>
> **3. Organization ↔ release subscription**
> - Which table records that an organization subscribes to a release, or to an
>   artifact/framework version? Give its DDL
> - How is an inactive or expired subscription represented?
> - If no such table exists, say so plainly — that is important
>
> **4. How employee records get written**
> - Do inserts and updates go through maker-checker (a change-request table),
>   or are they written directly on save?
> - If maker-checker: which procedure performs the real insert on approval?
> - This decides whether a checklist appears at Save or at Approve
>
> **5. Existing triggers**
> - List any triggers already on the employee table, and what they do
> - Note whether the table has an `INSTEAD OF` trigger — that changes how a new
>   `AFTER` trigger must be written
>
> **6. Onboarding / offboarding semantics**
> - Which column change represents a person joining, and which represents
>   leaving? A status transition, a `date_of_leaving`, a soft-delete flag?
> - Is there a joining date column distinct from the row's creation timestamp?
>
> **7. Employee roles / designations**
> - Which table holds the role, grade or designation of an employee (junior,
>   senior, manager)? Give its DDL
> - Is that list **global**, or does each organization define its own roles?
>   This is the single most important answer here
> - Can one employee hold more than one role at a time?
> - Is it the same table as the application-permission role, or a separate
>   HR-style designation? If the same, say so explicitly
>
> **8. Asset register and asset categories**
> - Does an asset register exist yet? If not, say so — that is expected
> - If it does: give the DDL of the asset table and of whatever holds asset
>   category, plus how an asset links to an organization
> - Is asset category a single value per asset, or a hierarchy?
>
> Do not write any SQL objects or propose an implementation yet. I only need
> these facts. If something does not exist, say it does not exist rather than
> suggesting what it could be called.

---

## Why the prompt insists on read-only

The integration cannot be designed from guesses about column names, and a
module that starts writing a trigger before the procedure it calls exists will
produce something that has to be discarded. The discovery step is cheap; the
wrong implementation is not.

## One design decision to make deliberately

With applicability enforced, a person joining an organization subscribed to
three releases gets **one** occurrence with a merged checklist, not three.
`ux_cm_assurance_occurrence_open` already enforces one open occurrence per
event-and-subject, so the schema is pointed that way. Confirm that is the
intended behaviour before the applicability join is written — reversing it
later means changing an index that production data already depends on.
