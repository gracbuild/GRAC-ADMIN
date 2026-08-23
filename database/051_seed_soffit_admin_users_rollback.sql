/*
  GRAC Repository Management - Part 051 rollback
  Deactivates the three Soffit administrator accounts seeded by
  051_seed_soffit_admin_users.sql.

  cm_user rows are NOT deleted: audit_trace / audit_trace_event reference
  user_id and the platform treats de-provisioning as status = 'Inactive'
  (see the retire branch of cm_manage_repository, which sets 'Inactive' for
  user-management). This mirrors that behaviour.

  Safe to re-run.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF SCHEMA_ID('GRAC_New') IS NULL
    THROW 51511, 'Schema GRAC_New is missing.', 1;
GO

BEGIN TRY
BEGIN TRAN;

DECLARE @ActedBy NVARCHAR(100) = N'system';
DECLARE @logins TABLE(login_id NVARCHAR(160) PRIMARY KEY);
INSERT @logins(login_id) VALUES (N'anoop.ps@soffit.in'), (N'saji.p@soffit.in'), (N'aparna.mp@soffit.in');

DECLARE @targetUsers TABLE(user_id BIGINT PRIMARY KEY);
INSERT @targetUsers(user_id)
SELECT u.user_id FROM GRAC_New.cm_user u
JOIN @logins l ON LOWER(u.login_id) = l.login_id;

UPDATE ur
SET ur.status     = N'Inactive',
    ur.updated_by = @ActedBy,
    ur.updated_dt = SYSUTCDATETIME()
FROM GRAC_New.cm_user_role ur
JOIN @targetUsers tu ON tu.user_id = ur.user_id
WHERE ur.status = N'Active';

UPDATE u
SET u.status     = N'Inactive',
    u.updated_by = @ActedBy,
    u.updated_dt = SYSUTCDATETIME()
FROM GRAC_New.cm_user u
JOIN @targetUsers tu ON tu.user_id = u.user_id
WHERE u.status <> N'Inactive';

COMMIT;
PRINT 'Migration 051 rollback complete. Soffit administrator accounts and role assignments set to Inactive.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
END CATCH
GO

SELECT user_id AS UserId, user_name AS UserName, login_id AS LoginId, status AS Status
FROM GRAC_New.cm_user
WHERE LOWER(login_id) IN (N'anoop.ps@soffit.in', N'saji.p@soffit.in', N'aparna.mp@soffit.in')
ORDER BY user_name;
GO
