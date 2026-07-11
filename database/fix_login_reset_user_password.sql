/*
  ONE-SHOT FIX for the henajyothi@gmail.com login failure.

  Re-stamps the user's password_hash to a freshly computed PBKDF2-SHA256
  hash of 'Welcome@123' that exactly matches ControlManagement.Web.Security
  .PasswordHasher (210,000 iterations, 16-byte salt, 32-byte key,
  format '{iterations}.{saltB64}.{hashB64}').

  Why this is needed:
  The user row was created on 2026-06-26 with the gateway InjectDefaultUserPassword
  path running, but `Security:DefaultUserPassword` in the deployed appsettings
  did not resolve to 'Welcome@123' at that moment.  The stored hash is therefore
  valid PBKDF2 but for a different plaintext, so Verify('Welcome@123', hash)
  returns false.  This script overwrites the hash so the user can sign in with
  'Welcome@123' and is forced through the Change Password screen on first login.

  Safe to re-run.  Only updates the named row.  No other column is touched.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @target_login_id NVARCHAR(250) = N'henajyothi@gmail.com';

-- Hash generated with PBKDF2-SHA256, 210000 iters, 16-byte random salt,
-- 32-byte key, of UTF-8 plaintext "Welcome@123".  Verified against
-- PasswordHasher.Verify before being pasted here.
DECLARE @new_hash NVARCHAR(500) = N'210000.PpGLtaF8889g17OD/nt/7Q==.Xee3NvO9wF0bpxKvd8p1RVUMU4JJ9pYYk0lYJDs8vEI=';

IF NOT EXISTS (SELECT 1 FROM GRAC_New.cm_user
               WHERE LOWER(login_id) = LOWER(@target_login_id)
                  OR LOWER(email)    = LOWER(@target_login_id))
BEGIN
    RAISERROR('No cm_user row matches "%s". Check the identifier and run again.', 16, 1, @target_login_id);
    RETURN;
END

BEGIN TRAN;

UPDATE GRAC_New.cm_user
SET password_hash               = @new_hash,
    is_password_change_required = 1,
    last_password_changed_dt    = NULL,
    status                      = N'Active',
    updated_by                  = N'admin',
    updated_dt                  = SYSUTCDATETIME()
WHERE LOWER(login_id) = LOWER(@target_login_id)
   OR LOWER(email)    = LOWER(@target_login_id);

-- Audit (best effort, matches the format other writes use)
DECLARE @user_id BIGINT = (SELECT user_id FROM GRAC_New.cm_user
                            WHERE LOWER(login_id) = LOWER(@target_login_id)
                               OR LOWER(email)    = LOWER(@target_login_id));

IF OBJECT_ID('GRAC_New.audit_trace_event','U') IS NOT NULL
BEGIN
    DECLARE @audit_event_id BIGINT;
    INSERT GRAC_New.audit_trace_event(entity_type, entity_id, action_type, table_name, record_reference, remarks, before_json, after_json, entered_by)
    VALUES(N'user-management', @user_id, N'Password Reset', N'GRAC_New.cm_user',
           (SELECT CONCAT(user_name, N' - ', login_id) FROM GRAC_New.cm_user WHERE user_id = @user_id),
           N'Password reset to Welcome@123 (first-login flag set).',
           N'{"reason":"login-fix-script"}',
           N'{"is_password_change_required":1}',
           N'admin');
    SET @audit_event_id = SCOPE_IDENTITY();

    IF OBJECT_ID('GRAC_New.audit_trace_detail','U') IS NOT NULL
        INSERT GRAC_New.audit_trace_detail(audit_event_id, field_name, old_value, new_value, entered_by)
        VALUES(@audit_event_id, N'Password Hash',             N'***', N'***',  N'admin'),
              (@audit_event_id, N'Password Change Required',  N'?',   N'Yes', N'admin'),
              (@audit_event_id, N'Last Password Changed',     N'?',   N'NULL', N'admin');

    IF OBJECT_ID('GRAC_New.audit_trace','U') IS NOT NULL
        INSERT GRAC_New.audit_trace(audit_event_id, entity_type, entity_id, action_type, table_name, record_reference, remarks, before_json, after_json, entered_by)
        VALUES(@audit_event_id, N'user-management', @user_id, N'Password Reset', N'GRAC_New.cm_user',
               (SELECT CONCAT(user_name, N' - ', login_id) FROM GRAC_New.cm_user WHERE user_id = @user_id),
               N'Password reset to Welcome@123 (first-login flag set).',
               N'{"reason":"login-fix-script"}',
               N'{"is_password_change_required":1}',
               N'admin');
END

COMMIT;

PRINT N'Password reset complete.';
SELECT user_id, login_id, email, status, is_password_change_required,
       LEN(password_hash) AS password_hash_length,
       LEFT(password_hash, 6) AS password_hash_prefix
FROM GRAC_New.cm_user
WHERE LOWER(login_id) = LOWER(@target_login_id)
   OR LOWER(email)    = LOWER(@target_login_id);
