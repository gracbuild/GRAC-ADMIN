# Repository Management Architecture

## Design Boundary

This module is intentionally separate from `GRACPlusAPI` and `GRACPLUSNEW`. It can be reviewed, deployed, and evolved independently before integration decisions are made.

## Repository Flow

```text
Authority
  -> Regulatory Artifact
    -> Release
      -> Native Source Structure Node
        -> Source Structure-Control Mapping
          -> Normalized Control
            -> Control-Requirement Mapping
              -> Atomic Requirement
                -> Release-Specific Obligation
```

## Metadata-Driven Rules

- Artifact categories and native node types are values stored in data.
- Native hierarchy is represented by `parent_node_id`, `node_level`, and `node_type`.
- Applicability expressions are JSON metadata evaluated by a future approved rule executor.
- No authority or framework name is embedded in application logic.
- Controls and requirements are reusable across artifacts and releases.
- Controls are created as independent reusable objectives. Domain/category context is derived from mapped source structure nodes and reporting views rather than forced into the Control master.
- Control-to-release association is derived from `source_control_map -> source_structure_node -> release`; there is no separate editable release-control mapping because that would duplicate the same relationship.
- Obligations remain release-specific because execution details can vary by publisher and version.

## Historical Reconstruction

- Major tables use a status column for retirement and do not require physical deletion.
- `cm.audit_trace` is append-only and protected by an immutable trigger.
- `cm.change_event`, `cm.impact_analysis`, and `cm.notification` retain the operational trace from repository change to organizational action.

## API Surface

The browser uses the same-origin MVC gateway:

```text
GET  /control-management-gateway/{area}
POST /control-management-gateway/{area}
POST /control-management-gateway/{area}/{id}/retire
POST /control-management-gateway/{area}/{id}/approve
```

The gateway keeps API tokens out of browser JavaScript, validates CSRF tokens on mutations, checks RBAC, and sends encrypted signed envelopes to the API:

```text
POST /api/control-management/secure/query
POST /api/control-management/secure/manage
```

The repository facade supports reads, form lookups, create/update operations, approvals, status-based retirement, and bulk mapping inserts for the requested areas. Main-platform integration can replace the standalone authentication adapter and synchronize enterprise directory roles without changing the repository model.

## Obligation Taxonomy (7-type atomic model)

Obligations carry a discriminator `obligation_type_id` on `GRAC_New.requirement_obligation` (FK to `GRAC_New.obligation_type_master`) that classifies each obligation as one of seven atomic types:

| type_code       | meaning                                                       |
| --------------- | ------------------------------------------------------------- |
| `State`         | what must be / continue to be true (e.g. password length ≥ 12) |
| `Execution`     | what must be done and when                                    |
| `Assurance`     | what must be verified and how                                 |
| `EventResponse` | if X occurs, what must happen within SLA                      |
| `Constraint`    | what boundary or prohibition must never be violated           |
| `Evidence`      | what proves fulfilment (standalone evidence obligation)       |
| `Retention`     | what must be preserved and for how long                       |

Each non-Evidence type has a dedicated detail table (`obligation_state_rule`, `obligation_execution_spec`, `obligation_assurance_spec`, `obligation_event_response`, `obligation_constraint_rule`, `obligation_retention_spec`) with a 1:1 active row per obligation. Evidence spec storage stays in the existing `requirement_obligation_evidence` table; six per-type M:M link tables (`obligation_<type>_evidence_link`) allow any obligation to attach one or more reusable evidence specs.

### API entry points for typed detail

Typed detail flows through the same `secure/query` and `secure/manage` envelopes as everything else, routed by `EntityType`:

| EntityType                    | Query dispatcher                       | Manage dispatcher                        | Actions                    |
| ----------------------------- | -------------------------------------- | ---------------------------------------- | -------------------------- |
| `obligation-types`            | `dbo.cm_get_obligation_taxonomy`       | (no manage; use `obligation-type-assignment`) | -                     |
| `obligation-type-assignment`  | -                                      | `dbo.cm_manage_obligation_taxonomy`      | `ASSIGN_TYPE`              |
| `obligation-state`            | `dbo.cm_get_obligation_taxonomy`       | `dbo.cm_manage_obligation_taxonomy`      | `SAVE`                     |
| `obligation-execution`        | `dbo.cm_get_obligation_taxonomy`       | `dbo.cm_manage_obligation_taxonomy`      | `SAVE`                     |
| `obligation-assurance`        | `dbo.cm_get_obligation_taxonomy`       | `dbo.cm_manage_obligation_taxonomy`      | `SAVE`                     |
| `obligation-event-response`   | `dbo.cm_get_obligation_taxonomy`       | `dbo.cm_manage_obligation_taxonomy`      | `SAVE`                     |
| `obligation-constraint`       | `dbo.cm_get_obligation_taxonomy`       | `dbo.cm_manage_obligation_taxonomy`      | `SAVE`                     |
| `obligation-retention`        | `dbo.cm_get_obligation_taxonomy`       | `dbo.cm_manage_obligation_taxonomy`      | `SAVE`                     |
| `obligation-evidence-links`   | `dbo.cm_get_obligation_taxonomy`       | `dbo.cm_manage_obligation_taxonomy`      | `SAVE`/`ATTACH`, `DETACH`/`RETIRE`/`DELETE` |

The legacy Obligation Master entities (`obligations`, `obligation-mappings`, `obligation-mapping-matrix`, `obligation-mapping-bulk`, `obligation-evidence`, `obligations-similar`) continue to route through `cm_get_repository` / `cm_manage_repository` unchanged.

**RBAC:** All typed entity types alias to the `obligations` permission area (View/Add/Edit/Approve on Obligations grants access to typed detail). Admins do not have to grant per-type permissions.

**Payload contract:** SAVE and ASSIGN_TYPE both send `{ obligationId, ...typedFields }` in the encrypted envelope `Data` field. For GET the front-end passes the parent obligation id via the top-level `Id` field (falls back to `$.obligationId` in payload). See `database/029_obligation_taxonomy_dispatcher.sql` for per-type field lists.

**Maker-checker:** Typed detail writes bypass the change-management workflow that guards the Obligation Master. If sir wants approval on typed edits, that is a follow-on migration.
