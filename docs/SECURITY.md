# ControlManagement Security Model

## Runtime Boundary

The browser calls `/control-management-gateway` on the MVC web application. The web application keeps the signed access token in its HTTP-only, SameSite session cookie state and sends encrypted, signed envelopes to `ControlManagement.Api`. Browser JavaScript never receives the API token or encryption material.

Production deployments must terminate TLS for both web and API applications and provide the same `Security__TokenSigningKey` through the deployment secret manager. Do not commit a production key.

## Controls

- AES-CBC request and response encryption follows the existing GRAC token-derived key and IV convention.
- HMAC signatures protect encrypted envelopes from tampering.
- Signed short-lived tokens, timestamp validation, and nonce replay detection protect API operations.
- RBAC is checked in both the MVC gateway and API for `VIEW`, `ADD`, `EDIT`, `DELETE`, and `APPROVE`.
- MVC mutations require antiforgery tokens. Session cookies are HTTP-only, SameSite strict, and secure in production.
- CSP, frame denial, content-type sniffing prevention, and login throttling are enabled.
- Repository SQL uses stored procedures and parameters. Deletion is status-based.
- Database audit trace, approval action, and transaction audit tables are append-only.
- UI messages are sanitized. Detailed exceptions remain server-side with correlation references.

## Integration Checklist

1. Replace the standalone review login adapter with the main GRAC authentication source.
2. Load role assignments from the enterprise directory and `cm.security_user_role`.
3. Supply secrets from the deployment secret manager.
4. Configure trusted TLS certificates and set `Database:TrustServerCertificate` to `false`.
5. Run VAPT against the deployed topology, including reverse-proxy headers and database permissions.
