/*
  GRAC Repository Management - Part 015
  Add force-password-change support to cm_user and introduce a typed change
  password stored procedure.

  Safe to re-run.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF SCHEMA_ID('GRAC_New') IS NULL
    THROW 51301, 'Schema GRAC_New is missing. Run Repository Management schema scripts first.', 1;

/* -----------------------------------------------------------------------
   1. New columns on cm_user.
      - is_password_change_required defaults to 1 so every newly created
        user is forced through the change-password screen on first login.
      - last_password_changed_dt is updated by cm_change_password.
   ----------------------------------------------------------------------- */
IF NOT EXISTS(SELECT 1 FROM sys.columns
              WHERE object_id = OBJECT_ID('GRAC_New.cm_user')
                AND name = 'is_password_change_required')
BEGIN
    ALTER TABLE GRAC_New.cm_user
        ADD is_password_change_required BIT NOT NULL
            CONSTRAINT df_cm_user_pwd_change DEFAULT 1;
END
GO

IF NOT EXISTS(SELECT 1 FROM sys.columns
              WHERE object_id = OBJECT_ID('GRAC_New.cm_user')
                AND name = 'last_password_changed_dt')
BEGIN
    ALTER TABLE GRAC_New.cm_user
        ADD last_password_changed_dt DATETIME2(3) NULL;
END
GO

/* Existing seeded admin/checker users keep their working passwords - they
   should NOT be forced through the first-login change. Anything else
   created before this migration is also assumed pre-vetted (set 0). New
   users created from the UI after this script runs will be inserted with
   is_password_change_required=1 by cm_manage_repository. */
UPDATE GRAC_New.cm_user
SET is_password_change_required = 0
WHERE is_password_change_required = 1
  AND last_password_changed_dt IS NULL
  AND entered_dt < SYSUTCDATETIME();
GO

/* -----------------------------------------------------------------------
   2. cm_change_password
      Updates the password hash for an authenticated user. The Web layer
      verifies the current password against the stored hash before calling
      this proc; the proc itself never sees plaintext. It clears the
      force-change flag and stamps last_password_changed_dt, writes an
      audit trace event, and returns the user_id on success.
   ----------------------------------------------------------------------- */
GO
CREATE OR ALTER PROCEDURE dbo.cm_change_password
    @p_login_id          NVARCHAR(160),
    @p_new_password_hash NVARCHAR(500),
    @p_usr_id            NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
    IF NULLIF(@p_usr_id,'') IS NULL SET @p_usr_id = COALESCE(@p_login_id, 'system');
    IF NULLIF(@p_login_id,'') IS NULL THROW 50040, 'Login id is required.', 1;
    IF NULLIF(@p_new_password_hash,'') IS NULL THROW 50041, 'New password hash is required.', 1;

    DECLARE @user_id BIGINT, @before NVARCHAR(MAX), @after NVARCHAR(MAX), @audit_event_id BIGINT;
    SELECT @user_id = user_id FROM GRAC_New.cm_user WHERE LOWER(login_id) = LOWER(@p_login_id);
    IF @user_id IS NULL THROW 50042, 'User not found.', 1;

    SELECT @before = (
        SELECT is_password_change_required isPasswordChangeRequired,
               CONVERT(NVARCHAR(40), last_password_changed_dt, 126) lastPasswordChangedDt
        FROM GRAC_New.cm_user WHERE user_id = @user_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    UPDATE GRAC_New.cm_user
    SET password_hash = @p_new_password_hash,
        is_password_change_required = 0,
        last_password_changed_dt = SYSUTCDATETIME(),
        updated_by = @p_usr_id,
        updated_dt = SYSUTCDATETIME()
    WHERE user_id = @user_id;

    SELECT @after = (
        SELECT is_password_change_required isPasswordChangeRequired,
               CONVERT(NVARCHAR(40), last_password_changed_dt, 126) lastPasswordChangedDt
        FROM GRAC_New.cm_user WHERE user_id = @user_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    INSERT GRAC_New.audit_trace_event(entity_type, entity_id, action_type, table_name, record_reference, remarks, before_json, after_json, entered_by)
    VALUES(N'user-management', @user_id, N'Password Change', N'GRAC_New.cm_user',
           (SELECT CONCAT(user_name, N' - ', login_id) FROM GRAC_New.cm_user WHERE user_id = @user_id),
           N'Password changed by user.', @before, @after, @p_usr_id);
    SET @audit_event_id = SCOPE_IDENTITY();

    INSERT GRAC_New.audit_trace_detail(audit_event_id, field_name, old_value, new_value, entered_by)
    VALUES(@audit_event_id, N'Password Hash', N'***', N'***', @p_usr_id),
          (@audit_event_id, N'Password Change Required', N'Yes', N'No', @p_usr_id);

    INSERT GRAC_New.audit_trace(audit_event_id, entity_type, entity_id, action_type, table_name, record_reference, remarks, before_json, after_json, entered_by)
    VALUES(@audit_event_id, N'user-management', @user_id, N'Password Change', N'GRAC_New.cm_user',
           (SELECT CONCAT(user_name, N' - ', login_id) FROM GRAC_New.cm_user WHERE user_id = @user_id),
           N'Password changed by user.', @before, @after, @p_usr_id);

    COMMIT;
    SELECT @user_id Id, 0 IsPasswordChangeRequired;
END
GO

PRINT 'Migration 015 complete. cm_user supports first-login password change and cm_change_password is installed.';
GO
