# Deployment Note — Status vocabulary per screen (049)

## 1. Apply order

| # | Script | Notes |
|---|---|---|
| 1 | `database/049_status_vocabulary.sql` | Lookup groups, data migration, `cm_manage_repository`, `cm_get_repository` |

Preflight: `002`, then `048`. Rollback: `database/049_status_vocabulary_rollback.sql`.

> **049 was updated after first publication.** It now also carries the
> `statement_type` guard described in section 6. If you already applied 049,
> re-run it — the script is idempotent.

Then build and deploy: `dotnet build ControlManagement.sln`.

## 2. What was wrong

Two independent faults compounded.

**The filter merged every group whose key contained "status".**

```js
Object.entries(state.lookups).filter(([key]) => key.includes("status"))
```

So every grid offered the union of `status-active` (Active, Inactive, Retired),
`release-status` (Draft, Active, Retired, Archived), `change-status` and
`notification-status` — values most tables can never hold. Each screen already
declared the right group on its own Status field; the filter ignored it.

**`RETIRE` was inconsistent about what it wrote.**

| Wrote `Retired` | Wrote `Inactive` |
|---|---|
| Artifact, Release, Control, Practice, Source Structure, Source Statement, Obligation, Applicability Rule | Authority, Source Classification, Control Domain / Sub Domain, Control-Practice map, Source-Control maps |

So filtering the Authority grid by `Retired` returned nothing, and its
deactivated rows could not be filtered at all. Trimming the dropdown to two
values without fixing the data would have made those rows permanently
unreachable.

## 3. The vocabulary now

| Screens | Group | Values |
|---|---|---|
| Authority, Artifact, Source Structure, Source Classification, Source Statement, Control, Control Domain / Sub Domain, Practice, Obligation, all mappings, Applicability Rule, SLA Master, all Assurance masters | `status-repository` | Active / Retired |
| User, Role, Menu, Role Permissions, Approval Workflow | `status-admin` | Active / Inactive |
| Artifact Release | `release-status` | Draft / Active / Retired |
| Change Management | `status-change-request` | Pending Approval / Approved / Auto Approved / Rejected / Sent Back |
| Change Event, Impact Analysis | `change-status` | unchanged |
| Notifications | `notification-status` | unchanged |
| Audit Trace, Assurance Version History | — | filter hidden; these are immutable logs |

Two deliberate exceptions to "only two values":

- **Access Administration keeps `Inactive`.** A user is deactivated, not
  retired. The wording follows the domain rather than forcing uniformity.
- **Artifact Release keeps `Draft`.** It is a real pre-effective state that the
  form lets you choose. `Archived` is never written to `release.status` and has
  been retired as an option.

## 4. Data migration

`Inactive` → `Retired` on `authority`, `statement_classification`,
`control_domain`, `control_sub_domain`, `control_requirement_map`,
`source_control_map`, `framework_statement_control_map`,
`framework_statement_requirement_map`, `obligation_evidence_type`.

Migrated rows are stamped `updated_by = '049'`, which is what the rollback's
narrow revert keys on.

Deliberately **not** migrated: `cm_user`, `cm_role`, `cm_menu`,
`cm_role_permission`, `approval_workflow_config` (they keep `Inactive`);
`artifact_industry_map`, `artifact_jurisdiction_map`, `control_keyword`
(internal child rows with no grid); `reference_option` itself.

049 prints a status census before and after, so the effect is visible in the
script output.

## 5. Verification

1. Authority grid — Status filter offers exactly **Active** and **Retired**.
2. Deactivate an Authority, filter by **Retired** — the row appears. Filter by
   **Active** — it does not.
3. Artifact Release grid — **Draft / Active / Retired**, no `Archived`.
4. User Management — **Active / Inactive**, no `Retired`.
5. Change Management — the five workflow statuses, nothing else.
6. Audit Trace — no Status filter at all.
7. Every grid: the badge values in the Status column are all present in that
   screen's own dropdown. Nothing in a grid should be unfilterable.

## 6. Statement Type removed from the Source Statement form

`framework_statement.statement_type` was a free-text field that nothing read
back: no filter, no dropdown, no mapping, no report, no join, no validation, no
seed data, and no mention in the docs. Its only consumers were the form itself
and the grid's search `LIKE`. It also duplicated **Statement Classification**,
which is the governed version of the same idea — an FK to
`statement_classification`, with its own master screen and a controlled
vocabulary per release.

Removed from the UI only:

| File | Change |
|---|---|
| `Views/Repository/StatementForm.cshtml` | field removed |
| `wwwroot/js/statement-form.js` | dropped from the save payload and the load |
| `wwwroot/js/repository.js` | dropped from the `framework-statements` schema |

**The column and its data stay.** Bulk upload and single-form upload still
accept a `statementType` column, and the grid search still matches on it, so
anything already loaded remains searchable.

### The guard that matters

The `UPDATE` in `cm_manage_repository` read:

```sql
statement_type = JSON_VALUE(@p_payload,'$.statementType'),
```

With the field gone from the form, the payload no longer carries that key, so
`JSON_VALUE` returns `NULL` and **every edit would silently wipe the stored
value** — including bulk-uploaded ones. It is now:

```sql
statement_type = COALESCE(JSON_VALUE(@p_payload,'$.statementType'), statement_type),
```

Absent key preserves what is stored; bulk upload can still set it. This is why
049 must be applied (or re-applied) alongside the UI change — shipping the UI
without it loses data.

To check whether anything was ever stored:

```sql
SELECT COUNT(*) AS TypedStatements
FROM   GRAC_New.framework_statement
WHERE  NULLIF(LTRIM(RTRIM(statement_type)), '') IS NOT NULL;
```

`0` means the field was never used and the column can be dropped later if
wanted. Anything above `0` is data now reachable only through search and the
upload path — decide whether to fold it into Statement Classification before
retiring the column.

## 7. Not yet verified

`dotnet build ControlManagement.sln` has not been run against these changes, and
the filters have not been exercised in a browser or against a live database.
