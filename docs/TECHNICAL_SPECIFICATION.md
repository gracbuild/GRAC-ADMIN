# GRAC Control Management — Technical Specification

**Module:** Regulatory Intelligence Repository & Change Management Engine
**Solution:** `ControlManagement.sln`
**Platform:** .NET 8 (ASP.NET Core) + Microsoft SQL Server
**Document status:** Current as of the repository state on 15 August 2026
**Intended readers:** Client technical reviewers, internal and external auditors, security assessors

---

## 1. Purpose and Scope

The Control Management module maintains a normalized, version-aware repository of external regulatory material and the internal control structures derived from it, together with the workflow, approval and audit machinery required to evidence that every change to that repository was authorised and recorded.

The module covers:

| Domain | Contents |
| --- | --- |
| Regulatory source | Authorities, artifacts, releases, native source structure, source (framework) statements, statement classifications |
| Normalized control layer | Controls, control domains and sub-domains, atomic practices (requirements) |
| Obligation layer | Obligation master, a 7-type atomic obligation taxonomy, evidence specifications and links |
| Mapping layer | Source-structure↔control, statement↔requirement, control↔requirement, practice↔obligation mappings |
| Assurance | Assurance metadata masters, event-driven assurance runtime, checklists, SLA master |
| Governance | Maker–checker change management, approval workflow configuration, impact analysis, notifications |
| Administration | Users, roles, menus, role-permission matrix, entity master |
| Traceability | Append-only audit trace, transaction audit, assurance version history |

The module is deliberately deployable and reviewable independently of `GRACPlusAPI` and `GRACPlusNew`. Integration with the main platform is expected to replace the standalone authentication adapter only; the repository model itself is unaffected.

---

## 2. Solution Architecture

### 2.1 Physical structure

```
ControlManagement.sln
├── src/ControlManagement.Api        ASP.NET Core Web API  (net8.0)
├── src/ControlManagement.Web        ASP.NET Core MVC UI   (net8.0)
├── src/ControlManagement.Security   Shared security library (net8.0)
└── database/                        Versioned SQL migration scripts (001 – 043)
```

Third-party dependencies are deliberately minimal:

| Package | Version | Used by | Purpose |
| --- | --- | --- | --- |
| `Microsoft.Data.SqlClient` | 5.2.2 | Api | Database access |
| `ClosedXML` | 0.104.1 | Api | XLSX template generation, bulk/single-form upload parsing |

No ORM is used. All data access is through stored procedures.

### 2.2 Tier responsibilities and trust boundaries

```
Browser
  │  same-origin HTTPS, session cookie, CSRF token
  ▼
ControlManagement.Web  (MVC + same-origin gateway)
  │  Bearer token + AES-encrypted, HMAC-signed JSON envelope
  ▼
ControlManagement.Api  (REST)
  │  stored procedure calls only, parameterised
  ▼
SQL Server  (schema GRAC_New)
```

Three properties define the trust model:

1. **The browser never holds an API token.** The signed access token is stored server-side in the Web tier's session. Browser JavaScript talks only to the same-origin gateway.
2. **The Web tier never holds a database connection string** and never performs password hashing. Authentication, hashing and all data access live in the API tier.
3. **The API tier does not trust the Web tier.** It independently validates the signed token, permissions, envelope signature, request freshness, nonce uniqueness and input contracts on every call.

### 2.3 Component inventory

**ControlManagement.Security** (shared, referenced by both host projects)

| Type | Responsibility |
| --- | --- |
| `EnvelopeCrypto` | AES-CBC encryption and HMAC-SHA256 signing/verification of request and response envelopes |
| `SignedAccessTokenService` | Issues and validates `cm01.<payload>.<signature>` access tokens |
| `PermissionPolicy` | Evaluates `area:action` permission strings, including wildcards |
| `SecurityOptions` | Bound from the `Security` configuration section |
| `SecurityModels` | `EncryptedRequest`, `EncryptedResponse`, `SecureRepositoryRequest`, `AccessPrincipal` |

**ControlManagement.Api**

| Type | Responsibility |
| --- | --- |
| `RepositoryController` | Encrypted `secure/query` and `secure/manage` entry points; entity allow-list; RBAC; replay defence |
| `AuthController` | Login, change password, admin password reset |
| `BulkUploadController` | Multi-sheet workbook template, validation, commit, error report |
| `SingleFormUploadController` | Per-entity template, validation, commit, replace preview |
| `RegulatoryRepositoryService` | Stored-procedure dispatcher; SQL error-code translation; connection handling |
| `AuthService` | Credential verification, role/permission loading, token issue, password change |
| `RepositoryCommandValidator` | Server-side payload contract validation |
| `PasswordHasher` | PBKDF2-SHA256 hashing and verification |
| `BulkUploadService` / `SingleFormUploadService` | Workbook parsing, cross-row validation, atomic commit |

**ControlManagement.Web**

| Type | Responsibility |
| --- | --- |
| `ControlManagementGatewayController` | Same-origin gateway: session→token, CSRF, RBAC, envelope forwarding |
| `RepositoryController` | Renders management screens and forms |
| `LoginController` / `AccountController` | Sign-in, sign-out, forced password change |
| `BulkUploadController` / `SingleFormUploadController` | Browser-side upload proxies |
| `SecureRepositoryClient` | Builds encrypted envelopes, adds nonce/timestamp, calls the API |
| `AuthApiClient` | Calls the API authentication endpoints |
| `NavigationContextProtector` | Signs and validates cross-screen navigation context codes |
| `ControlMenuService` | Builds the database-driven navigation tree filtered by permission |

---

## 3. Security Design

This section is written to support security and compliance review. Every control described here is implemented in code; file references are given.

### 3.1 Authentication

| Property | Value |
| --- | --- |
| Credential store | `GRAC_New.cm_user` (`login_id`, `email`, `password_hash`, `status`, `is_password_change_required`) |
| Hash algorithm | PBKDF2-SHA256 |
| Iterations | 210,000 (minimum accepted on verify: 100,000) |
| Salt | 16 bytes, cryptographically random, per credential |
| Derived key | 32 bytes |
| Stored format | `{iterations}.{saltBase64}.{hashBase64}` |
| Comparison | `CryptographicOperations.FixedTimeEquals` (constant time) |

*Implementation:* `src/ControlManagement.Api/Security/PasswordHasher.cs`, `src/ControlManagement.Api/Services/AuthService.cs`.

Login behaviour:

- Identifier match is case-insensitive on either `login_id` or `email`.
- Non-`Active` accounts are rejected with a distinct message; invalid credentials return a single generic message that does not disclose whether the account exists.
- On success the API loads the user's roles and explicit permissions, merges them, and issues a signed access token.
- `is_password_change_required` is returned to the Web tier, which then locks the session to the change-password path.

Password change rules: current password must verify; new password minimum length 8; new password must differ from current. The update executes `dbo.cm_change_password`.

Administrative reset (`POST /auth/admin-reset-password`) requires a valid token whose principal holds `user-management:EDIT`, resets to `Security:DefaultUserPassword`, and sets `is_password_change_required = 1`.

### 3.2 Access token

Format: `cm01.<base64url(payload)>.<base64url(HMAC-SHA256(payload))>`

- Payload: `{ Subject, Roles[], ExpiresUtc }` (Unix seconds).
- Signing key: `Security:TokenSigningKey`; the service refuses to operate if the key is shorter than 32 characters.
- Signature comparison is constant time; expiry is enforced on every validation.
- Default lifetime: `Security:TokenLifetimeMinutes` = 30.
- The same key must be configured on both the Web and API processes.

*Implementation:* `src/ControlManagement.Security/SignedAccessTokenService.cs`.

### 3.3 Encrypted request/response envelope

All repository reads and writes travel between the Web gateway and the API inside an encrypted, signed envelope, following the GRAC AES convention:

| Element | Value |
| --- | --- |
| Cipher | AES-256, CBC, PKCS7 |
| Key | 32 characters of the access token, offset 4 |
| IV | 16 characters of the lower-cased access token, offset 4 |
| Signature | HMAC-SHA256 over the Base64 ciphertext, keyed with `SHA256(token)` |
| Verification | Constant-time comparison; failure raises `CryptographicException` and yields a generic error |
| Precondition | Token length ≥ 36 characters, otherwise rejected |

Request shape: `{ RequestStr, Signature }`. Response shape: `{ Status, ResponseStr, Signature }`.

*Implementation:* `src/ControlManagement.Security/EnvelopeCrypto.cs`.

### 3.4 Replay and tampering defence

Enforced by `RepositoryController` on every `secure/*` call:

| Control | Detail |
| --- | --- |
| Timestamp freshness | `|now − TimestampUtc| ≤ Security:RequestValidityMinutes` (default 5) |
| Nonce | 24 cryptographically random bytes, hex-encoded, generated per request by `SecureRepositoryClient` |
| Nonce uniqueness | Registered in `IMemoryCache` under `cm-replay:{nonce}` for the validity window; a repeat is rejected |
| Nonce bounds | Non-empty, maximum 128 characters |
| Entity allow-list | `EntityType` must appear in the controller's `Supported` set; unknown areas are rejected before any database call |
| Parameter bounds | Non-negative identifiers; `Search` ≤ 250, `Module` ≤ 200, `ActionType` ≤ 50, `Status` ≤ 40 characters; `Page` ≤ 100,000; `PageSize` ∈ {0, 10, 25, 50, 100} |
| Payload contract | `RepositoryCommandValidator` validates the decrypted command before dispatch |

### 3.5 Authorization model

Permissions are expressed as `area:action` strings. Actions are `VIEW`, `ADD`, `EDIT`, `DELETE`, `APPROVE`, `REJECT`. Either side of the pair may be `*`.

Roles are mapped to permission sets in the `Security:RolePermissions` configuration section and, at the database level, through `security_role` / `security_permission` / `security_role_permission` and the `cm_role` / `cm_role_permission` menu matrix.

Seeded roles:

| Role | Permissions |
| --- | --- |
| `CM_ADMIN` | `*:*` |
| `CM_REVIEWER` | `*:VIEW` |
| `CM_APPROVER` | `*:VIEW`, `change-management:APPROVE`, `change-management:REJECT`, `changes:APPROVE`, `impact-analysis:APPROVE` |

**Authorization is applied twice** — once in the Web gateway (fast rejection, correct UI behaviour) and again in the API (authoritative). The API decides the required action as follows:

| Requested action | Permission checked |
| --- | --- |
| `SAVE` with `Id > 0` | `EDIT` |
| `SAVE` with no `Id` | `ADD` |
| `RETIRE` | `DELETE` |
| `APPROVE` | `APPROVE` |
| `REJECT`, `SEND_BACK` | `REJECT` |
| `SUBMIT` | `EDIT` |
| `PUBLISH`, `RETIRE_PUBLISHED` | `APPROVE` |

**Permission aliasing.** Some entity types intentionally share a parent area so that administrators do not have to grant per-type rights:

- All obligation-taxonomy types (`obligation-state`, `obligation-execution`, `obligation-assurance`, `obligation-event-response`, `obligation-constraint`, `obligation-retention`, `obligation-types`, `obligation-type-assignment`, `obligation-evidence-links`, `obligation-composite`, `event-types`) → `obligations`
- `assurance-checklist`, `event-subjects` → `assurance-occurrences`
- `framework-statement-requirement-mappings`, `requirements-similar` → `requirements`
- `obligations-similar` → `obligations`

The aliases are implemented identically on both tiers (`RepositoryController.ObligationTaxonomyPermissionAliases` and `ControlManagementGatewayController.GatewayPermissionArea`).

### 3.6 Browser-tier controls

| Control | Configuration |
| --- | --- |
| Session cookie | `.ControlManagement.Session`; `HttpOnly`; `SameSite=Strict`; `Secure` always outside Development; 30-minute idle timeout |
| CSRF | ASP.NET antiforgery, header `X-CSRF-TOKEN`; `[ValidateAntiForgeryToken]` on every gateway mutation |
| Rate limiting | Fixed window per client IP — login 5 requests/minute, gateway 120 requests/minute |
| HSTS + HTTPS redirect | Enabled outside Development |
| `Content-Security-Policy` | `default-src 'self'`; `frame-ancestors 'none'`; `base-uri 'self'`; `form-action 'self'`; scoped font/style CDNs |
| `X-Frame-Options` | `DENY` |
| `X-Content-Type-Options` | `nosniff` |
| `Referrer-Policy` | `strict-origin-when-cross-origin` |
| `Permissions-Policy` | `camera=(), microphone=(), geolocation=()` |
| Forced password change | Middleware restricts the session to `/Account/ChangePassword` and `/Login/Logout` until the flag clears |
| Forwarded headers | `X-Forwarded-For` / `X-Forwarded-Proto` honoured for reverse-proxy deployment |

The API additionally sets `nosniff`, `X-Frame-Options: DENY` and `Cache-Control: no-store` on every response, and restricts cross-origin callers through the named CORS policy `ControlManagementWeb` driven by `Cors:AllowedOrigins`.

### 3.7 Navigation context protection

Cross-screen drill-down (Authority → Artifacts → Releases → Source Structure / Classifications) passes a *signed context code* rather than raw identifiers, so a user cannot rewrite a query string to reach data outside the path they navigated. `NavigationContextProtector` binds the code to the session token; the gateway re-validates that the code's target area matches the requested area, that the caller holds `VIEW` on both source and target areas, and that the source/target pair is on an explicit allow-list. An invalid or expired code produces a generic rejection.

### 3.8 Secrets and credentials

- `Security:TokenSigningKey` is intentionally blank in source control and must be supplied per environment (environment variable `Security__TokenSigningKey` or the deployment secret manager) to both processes.
- The API supports either a direct `ConnectionStrings:ControlManagement` value or the GRAC convention of `ConnectionStrings:DbConnection` plus an AES-encrypted `ConnectionStrings:Password` in `key~ciphertext` form, decrypted at runtime.
- The production Web configuration contains no default review credential. The development-only review login is PBKDF2-hashed in `appsettings.Development.json`.
- `Database:Encrypt` defaults to `true`; `Database:TrustServerCertificate` should be `false` in production.

> **Reviewer note.** Environment-specific `appsettings.json` files checked into the repository should be confirmed to carry no live server addresses or encrypted credential blobs before external distribution; the intended pattern is that all such values come from the deployment secret manager.

### 3.9 Error handling and disclosure

- Cryptographic failures return a single generic message plus a correlation identifier; the specific cause is logged server-side only.
- Unhandled exceptions return a correlation identifier; detailed exception text is appended only when the host environment is Development.
- Database rule violations are translated from SQL error numbers (50008–50110, plus 2601/2627 uniqueness) into business-readable messages in `RegulatoryRepositoryService`, so the client never sees raw SQL text. Approximately 90 distinct codes are mapped.

---

## 4. API Surface

### 4.1 Browser-facing gateway (`ControlManagement.Web`)

Base path `/control-management-gateway`. All mutations require a valid session and a CSRF token.

| Method | Path | Permission | Purpose |
| --- | --- | --- | --- |
| GET | `/{entityType}` | `VIEW` | Query an area (filters: `id`, `search`, `status`, `authorityId`, `artifactId`, `releaseId`, `controlId`, `requirementId`, `frameworkStatementId`, `domainId`, `module`, `actionType`, `code`, `page`, `pageSize`) |
| POST | `/{entityType}` | `ADD` / `EDIT` | Create or update (`SAVE`) |
| POST | `/{entityType}/{id}/retire` | `DELETE` | Soft retirement |
| POST | `/{entityType}/{id}/approve` | `APPROVE` | Approve a change request |
| POST | `/{entityType}/{id}/reject` | `REJECT` | Reject a change request |
| POST | `/{entityType}/{id}/send-back` | `REJECT` | Return to maker |
| POST | `/{entityType}/{id}/submit` | `EDIT` | Assurance lifecycle: Draft → Review |
| POST | `/{entityType}/{id}/publish` | `APPROVE` | Assurance lifecycle: publish |
| POST | `/{entityType}/{id}/retire-published` | `APPROVE` | Assurance lifecycle: retire published version |
| POST | `/user-management/{id}/reset-password` | `user-management:EDIT` | Admin password reset |
| POST | `/navigation-code` | `VIEW` on both areas | Issue a signed navigation context |
| GET | `/navigation-context` | `VIEW` on target | Resolve a signed navigation context |
| GET | `/diagnostics/security` | session | Configuration diagnostic (key length, fingerprint, token validity) — no secret values returned |

### 4.2 API endpoints (`ControlManagement.Api`)

**Repository — `/api/control-management`**

| Method | Path | Auth | Notes |
| --- | --- | --- | --- |
| POST | `/secure/query` | Bearer + envelope | Requires `VIEW` on the resolved permission area |
| POST | `/secure/manage` | Bearer + envelope | Action-derived permission; validator; maker-checker |
| GET | `/diagnostics/security` | optional Bearer | Environment and key-configuration diagnostic |
| GET | `/` | none | Readiness probe |

**Authentication — `/api/control-management/auth`**

| Method | Path | Auth |
| --- | --- | --- |
| POST | `/login` | none |
| POST | `/change-password` | Bearer (subject taken from token, never from body) |
| POST | `/admin-reset-password` | Bearer + `user-management:EDIT` |

**Bulk upload — `/api/control-management/bulk-upload`**

| Method | Path | Auth |
| --- | --- | --- |
| GET | `/template` | Bearer + `ADD` on all gated areas |
| POST | `/validate` | Bearer + `ADD` on all gated areas (50 MB limit) |
| POST | `/commit` | Bearer + `ADD` on all gated areas (50 MB limit) |
| POST | `/error-report` | Bearer + `ADD` on all gated areas |

Gated areas: `authorities`, `artifacts`, `releases`, `source-structure`, `framework-statements`, `requirements`, `obligations`, `source-control-mappings`, `obligation-mappings`. Because `ADD` is required on *every* gated area, in practice only `CM_ADMIN` can use the multi-sheet uploader.

**Single-form upload — `/api/control-management/single-form-upload`**

| Method | Path | Auth |
| --- | --- | --- |
| GET | `/forms` | Bearer; the list is filtered to forms the caller can `ADD` |
| GET | `/releases` | Bearer |
| GET | `/template` | Bearer + `ADD` on that form's area |
| POST | `/validate` | Bearer + `ADD` on that form's area |
| POST | `/commit` | Bearer + `ADD`; `Replace` mode additionally requires `DELETE` |
| GET | `/preview-replace` | Bearer + `ADD` |

Per-entity permission gating means a user who may add framework statements does not thereby gain the right to add authorities.

---

## 5. Data Layer

### 5.1 Conventions

- Single schema: `GRAC_New`.
- All access through stored procedures; no dynamic SQL is constructed in application code; all parameters are `DbParameter` objects.
- Every business table carries `status`, `entered_by`, `entered_dt`, `updated_by`, `updated_dt`.
- Retirement is a status change, not a physical delete, so history is reconstructable.
- Payloads are passed as JSON in `@p_payload` and read with `JSON_VALUE` / `OPENJSON` inside the procedures.

### 5.2 Dispatcher procedures

Reads and writes are routed by `EntityType` to one of the following pairs:

| Domain | Read | Write |
| --- | --- | --- |
| Core repository | `dbo.cm_get_repository` | `dbo.cm_manage_repository` |
| Assurance metadata masters | `dbo.cm_get_assurance_repository` | `dbo.cm_manage_assurance_repository` |
| Obligation taxonomy (typed detail) | `dbo.cm_get_obligation_taxonomy` | `dbo.cm_manage_obligation_taxonomy` |
| Obligation composite save | — | `dbo.cm_manage_obligation_composite` |
| Assurance runtime | `dbo.cm_get_assurance_runtime` | `dbo.cm_manage_assurance_runtime` |
| SLA master | `dbo.cm_get_sla_master` | `dbo.cm_manage_sla_master` |

Shared signature: `@p_entity_type`, `@p_action`, `@p_id`, `@p_search`, `@p_status`, `@p_payload`, `@p_usr_id`; `cm_get_repository` and `cm_get_obligation_taxonomy` additionally take `@p_page` and `@p_page_size`.

Supporting procedures include `cm_change_password`, `cm_admin_reset_user_password`, `cm_bootstrap_table`, the `sp_cm_obligation_*` typed accessors, `sp_cm_change_bundle_*` (bundle approval), `sp_cm_assurance_occurrence_*` and `sp_cm_assurance_checklist_*` (runtime), `sp_cm_event_type_list`, and the functions `fn_cm_assurance_specs_for_event` and `fn_cm_obligation_type_entity`.

### 5.3 Principal tables

**Regulatory source chain**

```
authority
  └── artifact ── artifact_industry_map, artifact_jurisdiction_map
        └── release
              ├── statement_classification
              ├── source_structure_node   (parent_node_id, node_level, node_type)
              └── framework_statement
```

**Control and practice layer:** `control`, `control_domain`, `control_sub_domain`, `control_keyword`, `requirement`.

**Mapping layer:** `source_control_map`, `framework_statement_control_map`, `control_requirement_map`, `framework_statement_requirement_map`, `obligation_requirement_release_map`.

**Obligation layer:** `obligation`, `obligation_type_master`, `requirement_obligation`, `requirement_obligation_evidence`, `obligation_evidence_type`, `evidence_type_master`, plus one detail table per non-Evidence type (`obligation_state_rule`, `obligation_execution_spec`, `obligation_assurance_spec`, `obligation_event_response`, `obligation_constraint_rule`, `obligation_retention_spec`) and a matching `obligation_<type>_evidence_link` table for many-to-many evidence attachment.

**Applicability:** `applicability_attribute`, `applicability_rule`, `organization`, `reference_option`.

**Change and impact:** `change_event`, `change_management`, `change_management_field`, `impact_analysis`, `notification`, `approval_action`, `approval_workflow_config`.

**Assurance:** `assurance_category`, `assurance_scoring_model`, `assurance_observation_severity`, `assurance_gap_category`, `assurance_workflow_template`, `assurance_workflow_stage`, `assurance_question_type`, `assurance_sampling_model`, `assurance_frequency_type`, `assurance_report_template`, `assurance_starter_template`, `assurance_starter_template_question`, `assurance_metadata_version`, `assurance_event_occurrence`, `assurance_checklist_item`, `assurance_checklist_evidence`, `event_type_master`, `sla_master`.

**Administration and security:** `cm_entity_master`, `cm_user`, `cm_role`, `cm_user_role`, `cm_menu`, `cm_role_permission`, `security_role`, `security_permission`, `security_role_permission`, `security_user_role`.

**Traceability:** `audit_trace`, `audit_trace_event`, `audit_trace_detail`, `transaction_audit`.

### 5.4 Entity master

`cm_entity_master` is the single registry that maps an `entity_code` slug (the same slug used in URLs, JavaScript payloads and stored procedures) to its human label, physical table, route and — critically — its `is_maker_checker` flag. Introducing this table removed a hard-coded module list from `cm_manage_repository`, so whether an area is under maker–checker control is now configuration, not code.

---

## 6. Governance Workflows

### 6.1 Maker–checker

For any entity registered with `is_maker_checker = 1`, a save or retire does **not** write directly to the business table. It writes a change request:

`GRAC_New.change_management`

| Column | Meaning |
| --- | --- |
| `change_request_no` | Computed, persisted — `CR-000001` format |
| `module_name`, `entity_type`, `action_type` | What is being changed (`Add`, `Edit`, `Inactive`) |
| `record_id`, `record_reference` | Target record |
| `old_data_json`, `proposed_data_json` | Before/after state, retained in full |
| `maker_user`, `submitted_dt` | Who proposed and when |
| `checker_user`, `checked_dt`, `checker_comments` | Who decided, when, and why |
| `status` | `Pending Approval`, `Approved`, `Rejected`, `Sent Back`, `Auto Approved` |
| `applied_record_id`, `draft_reference_id` | Linkage to the applied record and its draft |
| `parent_change_request_id` | Parent/child sequencing for dependent records |
| `bundle_id`, `bundle_seq` | Atomic multi-row approval (see 6.2) |

Field-level detail is held in `change_management_field`. Checker comments are mandatory (enforced in the database, error 50026). Self-approval is refused unless the workflow row for that module permits it (error 50027). A child change request cannot be approved before its parent (errors 50035/50036).

**Auto-approval.** Because the API tier owns the role→permission map, it tells the procedure whether the maker also holds `APPROVE` on the affected area by injecting `__autoApproveAllowed = 1` into the payload. The stored procedure retains the final decision and auto-approves only when both that flag and `self_approval_allowed = 1` on the workflow configuration are present. The resulting row is recorded as `Auto Approved`, not silently applied.

`approval_workflow_config` holds per-module rules: approval required, self-approval allowed, minimum approvers.

### 6.2 Composite (bundled) approval

A merged Obligation save produces several logically inseparable sub-entity changes. `cm_manage_obligation_composite` emits one `change_management` row per sub-entity, all sharing a `bundle_id` with an explicit `bundle_seq` apply order. `sp_cm_change_bundle_approve` / `_reject` / `_send_back` / `_apply_row` / `_list` act on the bundle as a unit, so a partial approval cannot leave the obligation in an inconsistent state.

### 6.3 Assurance metadata lifecycle

Assurance masters carry a versioned lifecycle: `Draft → Review → Approved → Published → Retired`, driven by the `SUBMIT`, `APPROVE`, `REJECT`, `PUBLISH` and `RETIRE_PUBLISHED` actions. Rules enforced in the database include: only `Draft` may be submitted (50071); only `Review` may be approved or rejected (50072/50073); only `Approved` or `Published` may be published (50074); only `Published` may be retired (50075); and `Approved`, `Published` or `Retired` records cannot be edited in place — a new version must be created (50078). `assurance_metadata_version` records every transition and is protected by an immutability trigger.

### 6.4 Event-driven assurance runtime

Event occurrences and the checklists they generate are registered with `is_maker_checker = 0` by design. Rationale, recorded here because it is an auditable design decision: routing checklist completion through change management would raise one approval per assurance per subject and swamp the checker queue. The *rules* remain governed by maker–checker; *recording that a governed rule was carried out* does not. Completion, reopen and cancel actions are still written through dedicated procedures (`sp_cm_assurance_checklist_complete`, `_reopen`, `sp_cm_assurance_occurrence_cancel`) and captured in the audit trace.

---

## 7. Auditability and Traceability

| Store | Contents | Protection |
| --- | --- | --- |
| `audit_trace` | Flat who/what/when/old-value/new-value rows | `tr_audit_trace_immutable` blocks UPDATE and DELETE |
| `audit_trace_event` | One row per business event, with `before_json` / `after_json` | `tr_audit_trace_event_immutable` |
| `audit_trace_detail` | Field-level deltas linked to an event | `tr_audit_trace_detail_immutable` |
| `transaction_audit` | Correlation id, user key, area, action, result, client address, detail JSON | `tr_transaction_audit_immutable` |
| `assurance_metadata_version` | Assurance lifecycle transitions | `tr_assurance_metadata_version_immutable` |
| `change_management` | Full proposed/old state per change request | Retained indefinitely; status transitions only |

Together these give an auditor four independent, append-only views of a change: the request (`change_management`), the decision (`checker_user` / `checked_dt` / `checker_comments` and `approval_action`), the applied delta (`audit_trace_event` + `audit_trace_detail`), and the transport record (`transaction_audit`). Every application-side operation also carries a correlation identifier that appears in both the client-facing error message and the server log, so a reported failure can be traced to a specific request.

---

## 8. Application Screens

The Web tier renders a dedicated management screen per area, each with list, add, edit and view forms. Dropdowns are API-fed; users never enter JSON. The navigation tree is database-driven — `ControlMenuService` reads the `menu-management` area (backed by `cm_menu` and the `cm_role_permission` matrix) and drops every node for which the signed-in user does not hold `VIEW` on the node's own key or its mapped area key.

| Group | Screens |
| --- | --- |
| Regulatory source | Authority, Artifacts, Releases, Source Classification, Source Structure, Source Statements |
| Control and practice | Practices |
| Obligation | Obligation Master, Practices–Obligation Mapping |
| Mapping | Practices–Statement Mapping |
| Assurance metadata | Assurance Categories, Scoring Models, Observation Severity, Gap Categories, Workflow Templates, Question Types, Sampling Models, Frequency Types, Report Templates, Starter Templates, Version History |
| Assurance runtime | Event Checklists, SLA Master |
| Governance | Change Management, Approval Workflow Configuration, Audit Traceability |
| Administration | User Management, Role Management, Menu Management, Role Permission Management |

Screen metadata (key, title, description, icon, list columns) is declared centrally in `src/ControlManagement.Web/Models/RepositoryScreen.cs`.

---

## 9. Data Ingestion

### 9.1 Multi-sheet bulk upload

A single workbook covering Authority, Artifact, Release, Source Structure, Source Statement, Practice, Obligation Master, Obligation Evidence Types, Practice–Source Statement Mapping and Practice–Obligation Mapping. Flow: download template → validate (report only) → commit (atomic). Failures are returned as a downloadable error workbook with row and column references. Maximum upload size 50 MB.

### 9.2 Single-form upload

Seven per-entity forms, each with its own template and permission area:

| Entity key | Display name | Permission area | Release-scoped | Replace strategy |
| --- | --- | --- | --- | --- |
| `source-structure` | Source Structure | `source-structure` | Yes | Hard delete |
| `framework-statements` | Source Statement | `framework-statements` | Yes | Hard delete |
| `requirements` | Practices | `requirements` | No | Not allowed |
| `obligations` | Obligation Master | `obligations` | No | — |
| `obligation-evidence` | Obligation Evidence Types | `obligations` | No | — |
| `source-control-mappings` | Practice–Source Statement Mapping | `source-control-mappings` | Yes | Hard delete |
| `obligation-mappings` | Practice Obligation Mapping | `obligation-mappings` | Yes | Hard delete |

**Anti-tampering.** Release-scoped templates carry a hidden `__context__` sheet holding the entity key, release id, a UTC timestamp and an HMAC signature. At commit the server re-verifies the signature, so an edited `ReleaseId`, a swapped entity or a replaced signature is rejected — a file downloaded for one release cannot be silently retargeted at another. Replace mode additionally requires `DELETE` permission and a typed release-code confirmation.

---

## 10. Deployment and Configuration

### 10.1 Database installation order

| Step | Script | Required |
| --- | --- | --- |
| 1 | `001_control_management_schema.sql` | Yes |
| 2 | `002_control_management_procedures.sql` | Yes |
| 3 | `005_control_management_security.sql` | Yes |
| 4 | `006` – `044` in numeric order | Yes (incremental migrations) |
| — | `003_iso_27001_sample_data.sql` | Optional demonstration data |
| — | `004_multi_authority_sample_data.sql` | Optional demonstration data (RBI, SEBI, PCI SSC, NIST) |

Migrations are written to be re-runnable — each block is guarded with `IF NOT EXISTS`, `MERGE` or column-existence checks, and paired `_rollback.sql` scripts are supplied for the later migrations (026 onward). Deployment steps for migrations 031–039 are documented separately in `docs/deployment-runbook-031-039.md`.

The `database/` folder also contains non-sequenced utility scripts (`diagnostics_login.sql`, `fix_login_reset_user_password.sql`, `cleanup_source_structure_uat.sql`) and smoke tests (`039`, `041`). These are operational aids and are not part of the standard installation sequence.

### 10.2 Required configuration

**API**

| Key | Notes |
| --- | --- |
| `ConnectionStrings:ControlManagement` | Or `DbConnection` + encrypted `Password` |
| `Database:Provider` | Default `Microsoft.Data.SqlClient` |
| `Database:Encrypt` / `Database:TrustServerCertificate` | `true` / `false` in production |
| `Security:TokenSigningKey` | ≥ 32 characters; from secret manager; must match the Web tier |
| `Security:TokenLifetimeMinutes` | Default 30 |
| `Security:RequestValidityMinutes` | Default 5 |
| `Security:DefaultUserPassword` | Used for new users and admin resets |
| `Security:RolePermissions` | Role → permission map |
| `Cors:AllowedOrigins` | Exact Web origins |

**Web**

| Key | Notes |
| --- | --- |
| `ApiBaseUrl` | Must end at `/api/control-management` |
| `Security:TokenSigningKey` | Identical to the API value |
| `Security:RolePermissions` | Mirrors the API map |
| `Hosting:PathBase` | Set when hosted under a virtual directory |

### 10.3 Running

```powershell
dotnet run --project src\ControlManagement.Api
dotnet run --project src\ControlManagement.Web
```

The two processes are started and hosted independently. Behind IIS or another reverse proxy, confirm that the `Authorization` header is forwarded — the client surfaces a specific diagnostic message when the API rejects a token, and `/control-management-gateway/diagnostics/security` reports whether both tiers agree on the signing key (by length and fingerprint only; the key itself is never returned).

---

## 11. Design Decisions of Audit Interest

| Decision | Rationale |
| --- | --- |
| No ORM; stored procedures only | Business rules, uniqueness constraints and workflow gates are enforced in one place that the application cannot bypass |
| Web tier has no connection string and no hashing primitive | Compromise of the presentation tier does not yield database access or credential material |
| Double authorization (gateway and API) | The API remains safe against a caller that bypasses the browser entirely |
| Soft retirement instead of deletion | Historical reconstruction remains possible for any point in time |
| Append-only audit tables with immutability triggers | Audit history cannot be edited even by a database user with table rights |
| Auto-approval decided by the stored procedure, not the API | The workflow configuration in the database has the final say; the API can only *offer* the flag |
| Assurance runtime deliberately outside maker–checker | Recording execution of an already-governed rule is distinguished from changing the rule |
| Signed navigation context codes | Prevents horizontal parameter tampering across drill-down screens |
| Signed `__context__` sheet in upload templates | Prevents retargeting an approved upload at a different release |
| Entity-level maker-checker flag in `cm_entity_master` | Governance scope is configuration and is itself auditable |

---

## 12. Known Constraints

- Typed obligation-detail writes bypass the change-management workflow that guards the Obligation Master. Extending maker–checker to typed edits is a follow-on migration.
- Applicability expressions are stored as JSON metadata and are intended for evaluation by an approved rule executor; no executable expression is evaluated by the current code.
- The standalone review login is intended to be replaced by the main-platform authentication adapter at integration; role synchronisation with the enterprise directory is not yet implemented.
- The nonce replay cache is per-process `IMemoryCache`. In a multi-instance deployment behind a load balancer, either enable sticky sessions or promote the cache to a distributed store to preserve replay protection across instances.

---

## 13. Related Documents

| Document | Contents |
| --- | --- |
| `docs/architecture.md` | Repository flow, metadata-driven rules, obligation taxonomy detail |
| `docs/SECURITY.md` | Security summary |
| `docs/event-driven-assurance-design.md` | Event-driven assurance design |
| `docs/assurance-module-split.md` | Assurance module boundaries |
| `docs/obligation-merge-verification-plan.md` | Obligation merge verification |
| `docs/practice-management-handoff.md` | Practice management handoff |
| `docs/deployment-runbook-031-039.md` | Migration 031–039 deployment runbook |
| `docs/brd-coverage.md` | BRD coverage matrix |
| `docs/GRAC_RepositoryManagement_UAT_Checklist.docx` | UAT checklist |
| `docs/GRAC_Control_Management_User_Manual.docx` | End-user manual |
