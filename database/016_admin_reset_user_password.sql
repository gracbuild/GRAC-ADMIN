/*
  GRAC Repository Management - Part 016
  Admin-initiated password reset.  Re-stamps the password_hash to a value
  supplied by the API (which hashes Security:DefaultUserPassword with the
  same PasswordHasher login uses) and forces a first-login change.

  Safe to re-run (CREATE OR ALTER).
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF SCHEMA_ID('GRAC_New') IS NULL
    THROW 51401, 'Schema GRAC_New is missing. Run Repository Management schema scripts first.', 1;
GO

CREATE OR ALTER PROCEDURE dbo.cm_admin_reset_user_password
    @p_user_id           BIGINT,
    @p_new_password_hash NVARCHAR(500),
    @p_usr_id            NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
    IF NULLIF(@p_usr_id,'') IS NULL SET @p_usr_id = 'admin';
    IF @p_user_id IS NULL OR @p_user_id <= 0
        THROW 50050, 'A valid user identifier is required.', 1;
    IF NULLIF(@p_new_password_hash,'') IS NULL
        THROW 50051, 'New password hash is required.', 1;
    IF NOT EXISTS(SELECT 1 FROM GRAC_New.cm_user WHERE user_id = @p_user_id)
        THROW 50052, 'User not found.', 1;

    DECLARE @before NVARCHAR(MAX), @after NVARCHAR(MAX), @audit_event_id BIGINT;
    SELECT @before = (
        SELECT is_password_change_required isPasswordChangeRequired,
               CONVERT(NVARCHAR(40), last_password_changed_dt, 126) lastPasswordChangedDt
        FROM GRAC_New.cm_user WHERE user_id = @p_user_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    UPDATE GRAC_New.cm_user
    SET password_hash               = @p_new_password_hash,
        is_password_change_required = 1,
        last_password_changed_dt    = NULL,
        status                      = 'Active',
        updated_by                  = @p_usr_id,
        updated_dt                  = SYSUTCDATETIME()
    WHERE user_id = @p_user_id;

    SELECT @after = (
        SELECT is_password_change_required isPasswordChangeRequired,
               CONVERT(NVARCHAR(40), last_password_changed_dt, 126) lastPasswordChangedDt
        FROM GRAC_New.cm_user WHERE user_id = @p_user_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    INSERT GRAC_New.audit_trace_event(entity_type, entity_id, action_type, table_name, record_reference, remarks, before_json, after_json, entered_by)
    VALUES(N'user-management', @p_user_id, N'Admin Password Reset', N'GRAC_New.cm_user',
           (SELECT CONCAT(user_name, N' - ', login_id) FROM GRAC_New.cm_user WHERE user_id = @p_user_id),
           N'Admin reset password to default. First-login change required.',
           @before, @after, @p_usr_id);
    SET @audit_event_id = SCOPE_IDENTITY();

    INSERT GRAC_New.audit_trace_detail(audit_event_id, field_name, old_value, new_value, entered_by)
    VALUES(@audit_event_id, N'Password Hash',             N'***', N'***',   @p_usr_id),
          (@audit_event_id, N'Password Change Required',  N'?',   N'Yes',  @p_usr_id),
          (@audit_event_id, N'Last Password Changed',     N'?',   N'NULL', @p_usr_id);

    INSERT GRAC_New.audit_trace(audit_event_id, entity_type, entity_id, action_type, table_name, record_reference, remarks, before_json, after_json, entered_by)
    VALUES(@audit_event_id, N'user-management', @p_user_id, N'Admin Password Reset', N'GRAC_New.cm_user',
           (SELECT CONCAT(user_name, N' - ', login_id) FROM GRAC_New.cm_user WHERE user_id = @p_user_id),
           N'Admin reset password to default. First-login change required.',
           @before, @after, @p_usr_id);

    COMMIT;
    SELECT @p_user_id Id, 1 IsPasswordChangeRequired;
END
GO

PRINT 'Migration 016 complete. dbo.cm_admin_reset_user_password installed.';
GO
