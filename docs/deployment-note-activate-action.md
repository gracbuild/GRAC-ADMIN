# Deployment Note — Activate action (record re-enable)

Adds the mirror of the existing **Inactive** action so a deactivated record can
be brought back to **Active** from the same 3-dots menu.

## 1. Apply order

| Script | Notes |
|---|---|
| `database/048_cascade_deactivation.sql` | **Run this.** Supersedes 047 — carries the same Activate support plus cascade deactivation and restore |

047 is now historical. If it was already applied, 048 replaces its copy of the
procedure; running 047 *after* 048 would regress the cascade.

Re-running `database/002_control_management_procedures.sql` in full is also
valid — it is the source of truth for both — but it touches every object in the
module.

What 048 changes:

- `ck_cm_chg_action` on `GRAC_New.change_management` — widened to allow the
  `Activate` action type. Dropped and re-added without `WITH NOCHECK`; existing
  rows only ever hold `Add` / `Edit` / `Inactive`, so it validates cleanly.
- New table `GRAC_New.cm_cascade_deactivation` — one row per cascaded child,
  grouped by a batch id, holding the status to restore.
- New functions `dbo.fn_cm_repository_descendants` and
  `dbo.fn_cm_repository_descendant_status`.
- `dbo.cm_manage_repository` — the `ACTIVATE` branch, the cascade on `RETIRE`,
  the restore on `ACTIVATE`, and the read-only `RETIRE_IMPACT` preview.

No column change to an existing table, no seed data.

Rollback: `database/048_cascade_deactivation_rollback.sql`.

Then build and deploy: `dotnet build ControlManagement.sln`.

### Confirming which version is live

```sql
SELECT
  CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.cm_manage_repository'))
       LIKE '%@p_action=''ACTIVATE''%' THEN 1 ELSE 0 END AS HasActivateBranch,
  CASE WHEN EXISTS(SELECT 1 FROM sys.check_constraints
                   WHERE name = 'ck_cm_chg_action'
                     AND parent_object_id = OBJECT_ID('GRAC_New.change_management')
                     AND definition LIKE '%Activate%')
       THEN 1 ELSE 0 END AS ActionCheckAllowsActivate;
```

Both must read `1`. The two failure modes each map to one of them:

| Error on Activate | Cause |
|---|---|
| `Authority Code is required.` (THROW 50008) | `HasActivateBranch = 0` — the old procedure does not recognise `ACTIVATE`, so the request falls through into the entity `SAVE` branch and fails on the empty payload |
| `The INSERT statement conflicted with the CHECK constraint "ck_cm_chg_action"` | `ActionCheckAllowsActivate = 0` — the procedure raises an `Activate` change request but the constraint still only allows Add / Edit / Inactive |

Applying 048 clears both.

## 2. What changed in `cm_manage_repository`

| Location | Change |
|---|---|
| `@audit_action` | `ACTIVATE` now audits as `Activate` (was falling through to `Edit`) |
| maker-checker gate | `@p_action IN ('SAVE','RETIRE','ACTIVATE')` — activation raises a change request on the maker-checker areas instead of flipping the status directly |
| `@change_action` / `@change_payload` | `ACTIVATE` emits action type `Activate` with payload `{"status":"Active"}` |
| checker apply | `action_type 'Activate'` maps back to the `ACTIVATE` action when a checker approves |
| auto-approve apply | same mapping on the self-approval path |
| new `ACTIVATE` branch | sets `status='Active'` for every area the `RETIRE` branch covers |
| `RETIRE` cascade | after retiring the root, takes its whole subtree down and records each row against a cascade batch |
| `ACTIVATE` restore | puts back exactly the rows of that record's most recent unrestored batch, each to the status it held before |
| new `RETIRE_IMPACT` action | read-only; returns per-entity counts of what a deactivation would cascade to |

Error codes used by the new branch: **50110–50121** (previously unused; the file
already occupies 50001–50099 and the 529xx range).

## 3. Hierarchy guards

A record cannot be re-activated while an ancestor is still inactive — otherwise
the grids show an active child hanging off a retired parent. Each guard names
what to activate first:

| Entity | Guard | Error |
|---|---|---|
| `artifacts` | parent authority is Active | 50110 |
| `releases` | parent artifact is Active | 50111 |
| `source-structure` | parent release is Active | 50112 |
| `source-structure` | parent node (if any) is Active | 50113 |
| `framework-statements` | parent structure node is Active | 50114 |
| `control-sub-domains` | parent domain is Active | 50115 |
| `control-requirement-mappings` | both mapped ends are Active | 50116 |
| `source-control-mappings` | both mapped ends are Active | 50117–50119 |

`50120` — the area has no activation rule. `50121` — the record is already Active.

## 4. Application layer

| File | Change |
|---|---|
| `ControlManagementGatewayController.cs` | new `POST {entityType}/{id}/activate` and `POST {entityType}/{id}/deactivation-impact`, both gated on **DELETE** (same as retire) |
| `RepositoryController.cs` | `ACTIVATE` and `RETIRE_IMPACT` map to the `DELETE` permission; auto-approve flag injected for `ACTIVATE` |
| `RepositoryCommandValidator.cs` | `ACTIVATE` and `RETIRE_IMPACT` accepted, record id required |
| `repository.js` | 3-dots menu renders `Activate` or `Inactive` from the row status; the Inactive confirmation lists what the cascade will take down; both actions now report the maker-checker outcome; status badges are colour-coded |

### Why Inactive used to look like it did nothing

`retire()` discarded the server response. On a maker-checker area — which is all
of Authority, Artifact Release, Source Structure, Source Classification, Source
Statement and Practices — Retire does not change the record: it raises a
`Pending Approval` change request, and the row correctly stays Active until a
checker approves. With no message, the grid just reloaded unchanged and the
action appeared to fail. Both Retire and Activate now surface that outcome via
`reportWorkflowOutcome()`, the same way Save already did.

Related fix on the Source Statement screen: its source-structure tree was
fetched with `status: "Active"`, so a deactivated node took every statement
under it out of the grid entirely — leaving no way to reach them and activate
them again. It now fetches all statuses and marks inactive nodes.

Permission model is unchanged — no new permission code, no `cm_menu` or
`cm_role_permission` seed required.

## 5. Cascade scope

| Root | Takes down |
|---|---|
| `authorities` | artifacts -> releases -> nodes / classifications -> statements -> mappings |
| `artifacts` | releases -> nodes / classifications -> statements -> mappings |
| `releases` | nodes / classifications -> statements -> mappings |
| `source-structure` | child nodes (recursively) -> statements -> mappings |
| `framework-statements` | its two mapping tables |

Standalone records (Practices, Controls, Obligations, admin areas) have no
descendants here and cascade nothing.

Rows already inactive when the cascade runs are neither touched nor recorded, so
re-activating a parent never revives something switched off deliberately
beforehand. `Draft` counts as live and does come down — and is restored as
`Draft`, not `Active`, because `previous_status` is recorded per row.

## 6. Verification

1. Deactivate an Authority. The confirmation first lists what else goes down
   ("3 Regulatory Artifacts, 7 Artifact Releases, 42 Source Structure nodes...").
   Confirm — the row's menu now shows **Activate** and its badge turns grey.
2. Click **Activate**, confirm. On a maker-checker area the toast reads
   "Activation submitted for approval"; the row stays Inactive until a checker approves.
3. Check the child grids — the artifacts, releases, nodes, classifications and
   statements underneath are all inactive too.
4. Approve the request from **Change Management** — action type reads `Activate`.
   The Authority returns to Active, and so does every row the cascade took down
   (but nothing that was already inactive before it ran).
5. Deactivate an Authority, then try to activate one of its Artifacts directly —
   expect "Activate the parent Regulatory Authority first."
6. Check **Audit Trace** — the event is recorded with change type `Activate`.
7. `SELECT * FROM GRAC_New.cm_cascade_deactivation ORDER BY cascade_row_id DESC`
   — one batch per deactivation, `restored_dt` filled in once activated.

## 7. Not yet verified

`dotnet build ControlManagement.sln` has not been run against these changes, and
the flow has not been exercised in a browser or against a live database.
