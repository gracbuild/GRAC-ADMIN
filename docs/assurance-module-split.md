# Revised architecture — assurance definition (CM) vs runtime (PM)

Supersedes the runtime half of `event-driven-assurance-design.md`. That document
assumed occurrences and checklists lived in Control Management. Two decisions
changed that:

1. The checklist runtime moves into **Practice Management** — the organization's
   own users fill and submit, so the screens and the data belong where those
   users are.
2. Employee roles are defined **per organization**, not from a global list.

## The seam

```
CONTROL MANAGEMENT                      PRACTICE MANAGEMENT
------------------                      -------------------
obligation                              employee register
assurance spec                          asset register
event_type_master (taxonomy)            organization <-> release subscription
applicability matrix                    role master (per organization)
                                        occurrence + checklist tables
"what must be verified"                 "it was verified"
maker-checker governed                  direct write
                    \                  /
                     \                /
              fn_cm_assurance_specs_for_event(...)
                  the entire contract
```

Control Management answers a question. Practice Management records an answer.
Neither writes to the other's tables.

## The contract

One inline table-valued function, called by PM at raise time:

```sql
GRAC_New.fn_cm_assurance_specs_for_event(
    @p_event_type_id   BIGINT,          -- PEOPLE_ONBOARDING, etc.
    @p_organization_id BIGINT,          -- whose employee / asset
    @p_dimension_code  NVARCHAR(40),    -- 'ROLE' | 'ASSET_CATEGORY'
    @p_dimension_value BIGINT           -- the role id / category id
)
```

Returns the assurances that apply: `obligation_id`, `assurance_spec_id`,
`obligation_name`, `verification_method`, `assurance_party`, `scope`,
`sla_days`.

PM **snapshots** those values into its own checklist rows. It does not hold
foreign keys back into the spec. That is deliberate: editing an assurance rule
must never rewrite a checklist somebody already completed. This is the same
reasoning behind the existing snapshot columns, and it is what makes the
cross-module split safe — PM keeps working even if a spec is later retired.

## Applicability — one mechanism, not two

Role (for people) and asset category (for assets) are the same idea: a
classification of the subject that narrows which assurances apply. Modelled
once:

```sql
assurance_spec_applicability(
    applicability_id   BIGINT IDENTITY,
    assurance_spec_id  BIGINT NOT NULL,   -- FK, Control Management
    organization_id    BIGINT NOT NULL,   -- per-organization by decision
    dimension_code     NVARCHAR(40) NOT NULL,  -- 'ROLE' | 'ASSET_CATEGORY'
    dimension_value_id BIGINT NOT NULL,   -- role id / category id, no FK
    status             NVARCHAR(30) NOT NULL DEFAULT 'Active'
)
```

Two bespoke tables (`..._role_map`, `..._asset_category_map`) would work today
and cost a release each time a new dimension appears — department, location,
vendor tier. This is the same trade-off already settled when `event_type_master`
was made a self-referencing tree rather than three columns.

`dimension_value_id` intentionally carries no foreign key, because it points at
different tables per dimension. Register the dimensions so it stays honest:

```sql
applicability_dimension(dimension_code, source_table, subject_entity, status)
```

### Two semantics to fix deliberately

**No rows means "applies to everyone."** If absence meant "applies to nobody,"
every assurance that exists today would silently stop applying the moment this
ships. Narrowing must be an explicit act.

**Mandatory vs optional.** Per-organization configuration means an organization
can deselect assurances. Without a guard, an organization can opt out of
compliance by unticking boxes — which defeats the purpose of a GRC tool.

Recommendation: Control Management marks each assurance `is_mandatory`. The
per-organization map may only narrow **optional** assurances; mandatory ones
always apply and are not shown as deselectable. Compliance keeps its floor,
organizations keep their flexibility above it.

*This one needs an explicit decision before the applicability table is built.*

## What happens to the runtime already built in Control Management

Built, verified by `039` at 24/24, and now on the wrong side of the seam:

| Object | Fate |
|---|---|
| `assurance_event_occurrence`, `assurance_checklist_item`, `assurance_checklist_evidence` (035) | Move to PM |
| raise / complete / reopen / cancel / subject-picker (036) | Move to PM |
| `tr_cm_user_assurance_autoraise` (037) | Retire — replaced by a trigger on PM's employee register |
| `sp_cm_assurance_occurrence_raise` INSERT-EXEC fix (040) | Move with the proc — **keep the fix**, it was a real bug |
| Event Checklists + Raise Event screens | Move to PM |
| `fn_cm_assurance_specs_for_event` (037/038) | **Stays** — becomes the contract, extended with the new parameters |
| `sla_days` on `obligation_assurance_spec` (038) | Stays — it is part of the definition |
| Obligation Master merge, bundle approval (031/032) | Unaffected |

**Do not delete anything until PM's replacement is live.** The current runtime
works; retiring it early leaves a gap with no fallback.

## Sequencing

1. **Decide** mandatory-vs-optional (above).
2. **Discovery** — PM reports its schema, including the per-organization role
   master. See `practice-management-handoff.md`, items 7 and 8.
3. **Control Management** — build `assurance_spec_applicability`,
   `applicability_dimension`, `is_mandatory`, extend the TVF, and add the admin
   UI for configuring which assurances apply to which role or category. All of
   it maker-checker governed.
4. **Practice Management** — build the runtime against the contract.
5. **Control Management** — retire the relocated runtime once PM is live.

Step 3 cannot be finished before step 2: the applicability UI needs to know
where roles come from and whether an employee can hold more than one.

## Consequence worth stating

Once roles are per-organization, "which assurances apply" has no single global
answer. Two organizations subscribed to the same release can produce different
checklists for the same job title. That is what was asked for, and it means
reporting must always be scoped by organization — there is no meaningful
cross-tenant "the onboarding checklist" any more.
