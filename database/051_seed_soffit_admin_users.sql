/*
  GRAC Repository Management - Part 051
  Seed three Soffit administrator users with full Admin privileges.

    Anoop P S   anoop.ps@soffit.in
    Saji P      saji.p@soffit.in
    Aparna      Aparna.mp@soffit.in

  Behaviour
  ---------
  * Default password for all three is Grac@123, stored as a PBKDF2-SHA256
    hash in the exact format ControlManagement.Api.Security.PasswordHasher
    produces and verifies: "{iterations}.{saltB64}.{hashB64}" with
    iterations = 210000, 16-byte salt, 32-byte derivation.
  * is_password_change_required = 1, so LoginController flags the session and
    the first-login guard middleware in ControlManagement.Web/Program.cs
    confines the user to /Account/ChangePassword until dbo.cm_change_password
    clears the flag. No other route is reachable in the meantime.
  * Roles are cloned from the existing reference administrator
    (@ReferenceAdminLogin, default admin@grac.local) so the three accounts
    carry exactly the same role -> cm_role_permission grants as the admin
    already in the system. CM_ADMIN is unioned in as a safety net in case the
    reference account is missing.

  Re-runnable
  -----------
  Safe to execute more than once. On re-run existing accounts are reactivated
  and their role assignments are re-synchronised, but the password hash is
  NOT re-stamped - a user who has already set their own password keeps it.
  Set @ForcePasswordReset = 1 below to deliberately push all three back to
  Grac@123 with the first-login change re-armed.

  Ordering note
  -------------
  Run AFTER 015_user_password_change_flow.sql. Script 015 contains a one-time
  backfill that clears is_password_change_required for pre-existing rows; if
  015 is re-executed after this script, re-run this script (or use
  @ForcePasswordReset = 1) to re-arm the first-login prompt.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF SCHEMA_ID('GRAC_New') IS NULL
    THROW 51501, 'Schema GRAC_New is missing. Run the Repository Management schema scripts first.', 1;

IF OBJECT_ID('GRAC_New.cm_user','U') IS NULL
    THROW 51502, 'GRAC_New.cm_user is missing. Run 005_control_management_security.sql first.', 1;

IF NOT EXISTS(SELECT 1 FROM sys.columns
              WHERE object_id = OBJECT_ID('GRAC_New.cm_user')
                AND name = 'is_password_change_required')
    THROW 51503, 'GRAC_New.cm_user.is_password_change_required is missing. Run 015_user_password_change_flow.sql first.', 1;
GO

BEGIN TRY
BEGIN TRAN;

DECLARE @ForcePasswordReset  BIT            = 0;                  /* set to 1 to re-stamp Grac@123 on existing rows */
DECLARE @ReferenceAdminLogin NVARCHAR(160)  = N'admin@grac.local'; /* admin whose privileges are copied */
DECLARE @ActedBy             NVARCHAR(100)  = N'system';

/* -----------------------------------------------------------------------
   1. The three accounts.
      Each password_hash is an independent PBKDF2-SHA256 derivation of
      Grac@123 (210,000 iterations, unique 16-byte salt, 32-byte output).
   ----------------------------------------------------------------------- */
DECLARE @seed TABLE(
    user_name     NVARCHAR(200)  NOT NULL,
    login_id      NVARCHAR(160)  NOT NULL,
    email         NVARCHAR(250)  NOT NULL,
    password_hash NVARCHAR(500)  NOT NULL,
    remarks       NVARCHAR(MAX)  NULL);

INSERT @seed(user_name, login_id, email, password_hash, remarks) VALUES
 (N'Anoop P S', N'anoop.ps@soffit.in',  N'anoop.ps@soffit.in',
  N'210000.MtcWKLgFIfrxpwvZF6Igrg==.PBC5/S85gfJZNXkfeMX5KQcGrNcT26CRQmh4rW4QDr8=',
  N'Seeded administrator - Soffit. Default password Grac@123, first-login change required.'),
 (N'Saji P',    N'saji.p@soffit.in',    N'saji.p@soffit.in',
  N'210000.cyv0oXDO1FmGGtOjPgkDIQ==.XTo8eHG5PjkFHy5celq+ygfJ5xae+emwgphrAuxDYdw=',
  N'Seeded administrator - Soffit. Default password Grac@123, first-login change required.'),
 (N'Aparna',    N'Aparna.mp@soffit.in', N'Aparna.mp@soffit.in',
  N'210000.hOKk5WpaIeAPGjvm0RW3AA==.2iKfMgAmbZCxI+k7xSpj/FcRvZd6MKX+5SUvv+pQqfw=',
  N'Seeded administrator - Soffit. Default password Grac@123, first-login change required.');

/* Reject a collision where one of these addresses is already held by a
   different login, which would otherwise trip the cm_user UNIQUE indexes. */
IF EXISTS(SELECT 1
          FROM GRAC_New.cm_user u
          JOIN @seed s ON LOWER(u.email) = LOWER(s.email)
          WHERE LOWER(u.login_id) <> LOWER(s.login_id))
    THROW 51504, 'One of the seeded email addresses is already assigned to a different login id. Resolve manually before re-running.', 1;

/* -----------------------------------------------------------------------
   2. Insert missing accounts.
   ----------------------------------------------------------------------- */
DECLARE @inserted TABLE(user_id BIGINT NOT NULL, login_id NVARCHAR(160) NOT NULL);

INSERT GRAC_New.cm_user(user_name, login_id, email, password_hash, status, remarks,
                        is_password_change_required, last_password_changed_dt, entered_by)
OUTPUT inserted.user_id, inserted.login_id INTO @inserted(user_id, login_id)
SELECT s.user_name, s.login_id, s.email, s.password_hash, N'Active', s.remarks,
       1, NULL, @ActedBy
FROM @seed s
WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.cm_user u
                 WHERE LOWER(u.login_id) = LOWER(s.login_id)
                    OR LOWER(u.email)    = LOWER(s.email));

/* -----------------------------------------------------------------------
   3. Existing accounts: reactivate and refresh the display name. The
      password hash is only re-stamped when @ForcePasswordReset = 1.
   ----------------------------------------------------------------------- */
UPDATE u
SET u.user_name                   = s.user_name,
    u.email                       = s.email,
    u.status                      = N'Active',
    u.password_hash               = CASE WHEN @ForcePasswordReset = 1 THEN s.password_hash ELSE u.password_hash END,
    u.is_password_change_required = CASE WHEN @ForcePasswordReset = 1 THEN 1 ELSE u.is_password_change_required END,
    u.last_password_changed_dt    = CASE WHEN @ForcePasswordReset = 1 THEN NULL ELSE u.last_password_changed_dt END,
    u.updated_by                  = @ActedBy,
    u.updated_dt                  = SYSUTCDATETIME()
FROM GRAC_New.cm_user u
JOIN @seed s ON LOWER(u.login_id) = LOWER(s.login_id)
WHERE NOT EXISTS(SELECT 1 FROM @inserted i WHERE i.user_id = u.user_id);

/* -----------------------------------------------------------------------
   4. Grant Admin privileges.
      Target role set = every Active role held by the reference admin,
      plus CM_ADMIN. Permissions themselves live in cm_role_permission and
      are therefore identical by construction - nothing is duplicated.
   ----------------------------------------------------------------------- */
DECLARE @targetRoles TABLE(role_id BIGINT PRIMARY KEY);

INSERT @targetRoles(role_id)
SELECT DISTINCT r.role_id
FROM GRAC_New.cm_role r
WHERE r.status = N'Active'
  AND (r.role_name = N'CM_ADMIN'
       OR EXISTS(SELECT 1
                 FROM GRAC_New.cm_user_role ur
                 JOIN GRAC_New.cm_user au ON au.user_id = ur.user_id
                 WHERE LOWER(au.login_id) = LOWER(@ReferenceAdminLogin)
                   AND ur.status = N'Active'
                   AND ur.role_id = r.role_id));

IF NOT EXISTS(SELECT 1 FROM @targetRoles)
    THROW 51505, 'No Active administrator role found (CM_ADMIN missing and reference admin has no roles). Run 005_control_management_security.sql first.', 1;

DECLARE @targetUsers TABLE(user_id BIGINT PRIMARY KEY);
INSERT @targetUsers(user_id)
SELECT u.user_id
FROM GRAC_New.cm_user u
JOIN @seed s ON LOWER(u.login_id) = LOWER(s.login_id);

/* Reactivate any previously de-assigned mapping. */
UPDATE ur
SET ur.status     = N'Active',
    ur.updated_by = @ActedBy,
    ur.updated_dt = SYSUTCDATETIME()
FROM GRAC_New.cm_user_role ur
JOIN @targetUsers tu ON tu.user_id = ur.user_id
JOIN @targetRoles tr ON tr.role_id = ur.role_id
WHERE ur.status <> N'Active';

/* Create the missing mappings. */
INSERT GRAC_New.cm_user_role(user_id, role_id, status, entered_by)
SELECT tu.user_id, tr.role_id, N'Active', @ActedBy
FROM @targetUsers tu
CROSS JOIN @targetRoles tr
WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.cm_user_role x
                 WHERE x.user_id = tu.user_id AND x.role_id = tr.role_id);

/* -----------------------------------------------------------------------
   5. Audit trail, matching the shape written by cm_manage_repository.
   ----------------------------------------------------------------------- */
DECLARE @user_id BIGINT, @reference NVARCHAR(400), @after NVARCHAR(MAX), @audit_event_id BIGINT;
DECLARE @remark NVARCHAR(400) = N'Administrator account seeded by migration 051. Default password issued; first-login change required.';

DECLARE seed_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT tu.user_id FROM @targetUsers tu;
OPEN seed_cursor;
FETCH NEXT FROM seed_cursor INTO @user_id;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @reference = CONCAT(user_name, N' - ', login_id) FROM GRAC_New.cm_user WHERE user_id = @user_id;
    SELECT @after = (
        SELECT user_name userName, login_id loginId, email, status,
               is_password_change_required isPasswordChangeRequired
        FROM GRAC_New.cm_user WHERE user_id = @user_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    INSERT GRAC_New.audit_trace_event(entity_type, entity_id, action_type, table_name, record_reference, remarks, before_json, after_json, entered_by)
    VALUES(N'user-management', @user_id, N'Save', N'GRAC_New.cm_user', @reference, @remark, NULL, @after, @ActedBy);
    SET @audit_event_id = SCOPE_IDENTITY();

    INSERT GRAC_New.audit_trace_detail(audit_event_id, field_name, old_value, new_value, entered_by)
    VALUES(@audit_event_id, N'Password Hash',            N'***',  N'***',      @ActedBy),
          (@audit_event_id, N'Password Change Required', N'-',    N'Yes',      @ActedBy),
          (@audit_event_id, N'Roles',                    N'-',    N'CM_ADMIN', @ActedBy);

    INSERT GRAC_New.audit_trace(audit_event_id, entity_type, entity_id, action_type, table_name, record_reference, remarks, before_json, after_json, entered_by)
    VALUES(@audit_event_id, N'user-management', @user_id, N'Save', N'GRAC_New.cm_user', @reference, @remark, NULL, @after, @ActedBy);

    FETCH NEXT FROM seed_cursor INTO @user_id;
END
CLOSE seed_cursor;
DEALLOCATE seed_cursor;

COMMIT;
PRINT 'Migration 051 complete. Three Soffit administrator accounts seeded with Admin privileges.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
END CATCH
GO

/* -----------------------------------------------------------------------
   6. Verification. Expect three rows, status Active,
      PasswordChangeRequired = 1 and a role list identical to the existing
      administrator.
   ----------------------------------------------------------------------- */
SELECT u.user_id                     AS UserId,
       u.user_name                   AS UserName,
       u.login_id                    AS LoginId,
       u.email                       AS Email,
       u.status                      AS Status,
       u.is_password_change_required AS PasswordChangeRequired,
       u.last_password_changed_dt    AS LastPasswordChangedDt,
       STUFF((SELECT N', ' + r.role_name
              FROM GRAC_New.cm_user_role ur
              JOIN GRAC_New.cm_role r ON r.role_id = ur.role_id
              WHERE ur.user_id = u.user_id AND ur.status = N'Active' AND r.status = N'Active'
              ORDER BY r.role_name
              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS Roles
FROM GRAC_New.cm_user u
WHERE LOWER(u.login_id) IN (N'anoop.ps@soffit.in', N'saji.p@soffit.in', N'aparna.mp@soffit.in')
ORDER BY u.user_name;
GO

/* Effective menu permissions granted to the three accounts. */
SELECT u.login_id AS LoginId, m.menu_code AS MenuCode,
       MAX(CAST(rp.can_view     AS INT)) AS CanView,
       MAX(CAST(rp.can_add      AS INT)) AS CanAdd,
       MAX(CAST(rp.can_edit     AS INT)) AS CanEdit,
       MAX(CAST(rp.can_inactive AS INT)) AS CanDelete,
       MAX(CAST(rp.can_approve  AS INT)) AS CanApprove
FROM GRAC_New.cm_user u
JOIN GRAC_New.cm_user_role ur       ON ur.user_id = u.user_id AND ur.status = N'Active'
JOIN GRAC_New.cm_role r             ON r.role_id  = ur.role_id AND r.status = N'Active'
JOIN GRAC_New.cm_role_permission rp ON rp.role_id = r.role_id  AND rp.status = N'Active'
JOIN GRAC_New.cm_menu m             ON m.menu_id  = rp.menu_id AND m.status = N'Active'
WHERE LOWER(u.login_id) IN (N'anoop.ps@soffit.in', N'saji.p@soffit.in', N'aparna.mp@soffit.in')
GROUP BY u.login_id, m.menu_code
ORDER BY u.login_id, m.menu_code;
GO
