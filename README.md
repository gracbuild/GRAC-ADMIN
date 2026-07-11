# GRAC Repository Management

Standalone first-review module for the Regulatory Intelligence Repository and Change Management Engine.

## Projects

- `src/ControlManagement.Api`: ASP.NET Core API with a stored-procedure service layer modeled on `GracPlusApi`.
- `src/ControlManagement.Web`: independent ASP.NET Core MVC frontend modeled on the `GracPlusNew` visual language.
- `src/ControlManagement.Security`: shared encryption, signed-token, and RBAC enforcement used by the web gateway and API.
- `database`: normalized SQL Server schema and stored procedures.
- `docs`: design and deployment notes.

## Run

1. Execute `database/001_control_management_schema.sql`.
2. Execute `database/002_control_management_procedures.sql`.
3. Execute `database/005_control_management_security.sql`.
4. Optional: execute `database/003_iso_27001_sample_data.sql` to load rerunnable ISO/IEC 27001:2022 demonstration records with paraphrased content.
5. Optional: execute `database/004_multi_authority_sample_data.sql` to load rerunnable RBI, SEBI, PCI SSC, and NIST demonstration records with shared controls.
6. Configure `ConnectionStrings:ControlManagement` in `src/ControlManagement.Api/appsettings.json`.
7. For a non-default database provider, replace `Database:Provider` with its registered invariant name.
8. Set `ApiBaseUrl` in `src/ControlManagement.Web/appsettings.json`.
9. Set matching `Security__TokenSigningKey` environment variables for the API and web processes. Store the production value in the deployment secret manager.
10. Configure enterprise authentication values or replace the review login adapter during integration.
11. Start the API and web projects separately.

```powershell
dotnet run --project src\ControlManagement.Api
dotnet run --project src\ControlManagement.Web
```

## Review Login

The standalone development build uses a configurable session login styled after `GracPlusNew`. The development credential is PBKDF2-hashed in `src/ControlManagement.Web/appsettings.Development.json`:

```text
admin@grac.local
Grac@123
```

Production configuration contains no default review credential. Use the deployment secret manager and the main-platform authentication adapter before sharing an environment.

## Review Scope

The schema covers authorities, artifacts, releases, native source structure, normalized controls, atomic requirements, obligations, all required mappings, metadata-driven applicability rules, change events, impact analysis, notifications, and immutable audit traceability.

The frontend provides a separate management screen for each requested area. Each area has a normal Add/Edit/View form with validated controls and API-fed dropdowns; users never enter JSON manually. Mapping forms provide multi-select controls for bulk relationship creation.

Browser requests use a same-origin web gateway. The gateway protects session tokens from browser JavaScript, encrypts and signs API envelopes using the GRAC-compatible AES convention, applies CSRF validation, and enforces View/Add/Edit/Delete/Approve permissions. The API independently validates signed tokens, permissions, timestamps, nonces, input contracts, and soft-delete operations. Database audit rows and approval actions are append-only.
