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
