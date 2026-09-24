/* ================================================================
   Migration 058 -- Time Zone Master table, procs and seed
   ----------------------------------------------------------------
   Creates GRAC_New.time_zone_master -- standardized IANA time zones
   shared across every GRAC module -- and its dedicated dispatcher
   procs cm_get_time_zone_master / cm_manage_time_zone_master.
   Routed by Api.Services.RegulatoryRepositoryService so the existing
   cm_get_repository / cm_manage_repository stay untouched, exactly
   the same split already used for SLA Master (043/044).

   WHY iana_time_zone, NOT utc_offset, IS THE IDENTIFIER
   ----------------------------------------------------------------
   utc_offset is stored only as a display label (e.g. 'UTC+05:30').
   It is NOT unique and NOT what other tables should reference --
   daylight-saving rules mean a zone's offset changes through the
   year while its IANA id never does. Any table that needs to record
   "which time zone" (Location's time_zone_id, coming in a follow-up
   PracticeManagement migration) points at time_zone_id, which in
   turn is anchored to iana_time_zone.

   Seed: ~49 commonly-used IANA zones, one row per zone actually
   likely to be selected by a GRAC customer or their locations,
   covering India, the Gulf, wider Asia-Pacific, Europe, Africa, and
   the Americas, plus UTC itself. Admins can add more from the new
   screen (059_time_zone_master_menu.sql) -- this seed is a starting
   point, not an attempt at the full ~400-zone IANA database.

   Rollback: database/058_time_zone_master_table_and_procs_rollback.sql
   ================================================================ */

/* ------------------------------------------------------------------
   1. Table
   ------------------------------------------------------------------ */
IF OBJECT_ID('GRAC_New.time_zone_master','U') IS NULL
BEGIN
    CREATE TABLE GRAC_New.time_zone_master(
        time_zone_id       BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        time_zone_name      NVARCHAR(120) NOT NULL,
        iana_time_zone      NVARCHAR(80)  NOT NULL,
        utc_offset          NVARCHAR(20)  NOT NULL,
        remarks             NVARCHAR(500) NULL,
        status              NVARCHAR(20)  NOT NULL CONSTRAINT df_time_zone_master_status     DEFAULT (N'Active'),
        entered_by          NVARCHAR(100) NOT NULL CONSTRAINT df_time_zone_master_entered_by DEFAULT (N'system'),
        entered_dt          DATETIME2(3)  NOT NULL CONSTRAINT df_time_zone_master_entered_dt DEFAULT (SYSUTCDATETIME()),
        updated_by          NVARCHAR(100) NULL,
        updated_dt          DATETIME2(3)  NULL,

        CONSTRAINT uq_time_zone_master_iana   UNIQUE (iana_time_zone),
        CONSTRAINT ck_time_zone_master_status CHECK (status IN (N'Active', N'Inactive'))
    );
END
GO

/* ------------------------------------------------------------------
   2. cm_get_time_zone_master
   ------------------------------------------------------------------
   Same two-shape contract as cm_get_sla_master: @p_id = 0 lists,
   @p_id > 0 returns the single record for the edit / view form.
   ------------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.cm_get_time_zone_master
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30)  = N'',
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = N'',
    @p_status      NVARCHAR(30)  = N'',
    @p_payload     NVARCHAR(MAX) = N'{}',
    @p_usr_id      NVARCHAR(100) = N''
AS
BEGIN
    SET NOCOUNT ON;

    IF @p_entity_type <> N'time-zone-master'
    BEGIN
        ;THROW 50001, N'Unsupported repository area', 1;
    END

    SELECT time_zone_id     AS Id,
           time_zone_name   AS TimeZoneName,
           iana_time_zone   AS IanaTimeZone,
           utc_offset       AS UtcOffset,
           remarks          AS Remarks,
           status           AS Status,
           entered_by       AS EnteredBy,
           entered_dt       AS EnteredDt,
           updated_by       AS UpdatedBy,
           updated_dt       AS UpdatedDt
    FROM GRAC_New.time_zone_master
    WHERE (@p_id = 0 OR time_zone_id = @p_id)
      AND (NULLIF(@p_status, N'') IS NULL OR status = @p_status)
      AND (NULLIF(@p_search, N'') IS NULL
           OR time_zone_name LIKE N'%' + @p_search + N'%'
           OR iana_time_zone LIKE N'%' + @p_search + N'%'
           OR utc_offset     LIKE N'%' + @p_search + N'%')
    ORDER BY time_zone_name, time_zone_id;
END
GO

/* ------------------------------------------------------------------
   3. cm_manage_time_zone_master
   ------------------------------------------------------------------
   Actions: ADD / EDIT / INACTIVE (soft-delete) / ACTIVATE. No
   maker-checker lifecycle -- Active <-> Inactive only, same as SLA
   Master (043's comment: "Simple config master").
   ------------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.cm_manage_time_zone_master
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30),
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = N'',
    @p_status      NVARCHAR(30)  = N'',
    @p_payload     NVARCHAR(MAX) = N'{}',
    @p_usr_id      NVARCHAR(100) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @p_entity_type <> N'time-zone-master'
    BEGIN
        ;THROW 50001, N'Unsupported repository area', 1;
    END

    IF NULLIF(@p_usr_id, N'') IS NULL SET @p_usr_id = N'system';

    DECLARE
        @time_zone_name NVARCHAR(120) = JSON_VALUE(@p_payload, N'$.timeZoneName'),
        @iana_time_zone NVARCHAR(80)  = JSON_VALUE(@p_payload, N'$.ianaTimeZone'),
        @utc_offset     NVARCHAR(20)  = JSON_VALUE(@p_payload, N'$.utcOffset'),
        @remarks        NVARCHAR(500) = JSON_VALUE(@p_payload, N'$.remarks'),
        @status_in      NVARCHAR(20)  = COALESCE(JSON_VALUE(@p_payload, N'$.status'), N'Active');

    DECLARE @action NVARCHAR(30) = UPPER(ISNULL(@p_action, N''));

    /* Gateway Save posts Action='SAVE' for both create and update. */
    IF @action = N'SAVE'
        SET @action = CASE WHEN ISNULL(@p_id, 0) = 0 THEN N'ADD' ELSE N'EDIT' END;

    IF @action = N'ADD'
    BEGIN
        IF NULLIF(@time_zone_name, N'') IS NULL
        BEGIN
            ;THROW 50601, N'Time Zone Name is required.', 1;
        END
        IF NULLIF(@iana_time_zone, N'') IS NULL
        BEGIN
            ;THROW 50602, N'IANA Time Zone is required.', 1;
        END
        IF NULLIF(@utc_offset, N'') IS NULL
        BEGIN
            ;THROW 50603, N'UTC Offset is required.', 1;
        END
        IF EXISTS (SELECT 1 FROM GRAC_New.time_zone_master WHERE iana_time_zone = @iana_time_zone)
        BEGIN
            ;THROW 50604, N'This IANA Time Zone is already registered.', 1;
        END

        INSERT GRAC_New.time_zone_master(time_zone_name, iana_time_zone, utc_offset, remarks, status, entered_by)
        VALUES(@time_zone_name, @iana_time_zone, @utc_offset, @remarks, @status_in, @p_usr_id);

        SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
        RETURN;
    END

    IF @action = N'EDIT'
    BEGIN
        IF @p_id IS NULL OR @p_id = 0
        BEGIN
            ;THROW 50605, N'Time zone id is required for edit.', 1;
        END
        IF NULLIF(@iana_time_zone, N'') IS NOT NULL
           AND EXISTS (SELECT 1 FROM GRAC_New.time_zone_master WHERE iana_time_zone = @iana_time_zone AND time_zone_id <> @p_id)
        BEGIN
            ;THROW 50604, N'This IANA Time Zone is already registered.', 1;
        END

        UPDATE GRAC_New.time_zone_master
        SET time_zone_name = COALESCE(NULLIF(@time_zone_name, N''), time_zone_name),
            iana_time_zone = COALESCE(NULLIF(@iana_time_zone, N''), iana_time_zone),
            utc_offset     = COALESCE(NULLIF(@utc_offset, N''), utc_offset),
            remarks        = COALESCE(@remarks, remarks),
            status         = COALESCE(NULLIF(@status_in, N''), status),
            updated_by     = @p_usr_id,
            updated_dt     = SYSUTCDATETIME()
        WHERE time_zone_id = @p_id;

        SELECT @p_id AS Id;
        RETURN;
    END

    IF @action IN (N'INACTIVE', N'INACTIVATE', N'DELETE', N'RETIRE')
    BEGIN
        IF @p_id IS NULL OR @p_id = 0
        BEGIN
            ;THROW 50606, N'Time zone id is required for deactivate.', 1;
        END

        UPDATE GRAC_New.time_zone_master
        SET status     = N'Inactive',
            remarks    = COALESCE(NULLIF(@remarks, N''), remarks),
            updated_by = @p_usr_id,
            updated_dt = SYSUTCDATETIME()
        WHERE time_zone_id = @p_id;

        SELECT @p_id AS Id;
        RETURN;
    END

    IF @action IN (N'ACTIVATE', N'REACTIVATE')
    BEGIN
        IF @p_id IS NULL OR @p_id = 0
        BEGIN
            ;THROW 50607, N'Time zone id is required for activate.', 1;
        END

        UPDATE GRAC_New.time_zone_master
        SET status     = N'Active',
            updated_by = @p_usr_id,
            updated_dt = SYSUTCDATETIME()
        WHERE time_zone_id = @p_id;

        SELECT @p_id AS Id;
        RETURN;
    END

    ;THROW 50608, N'Unsupported action for time-zone-master.', 1;
END
GO

/* ------------------------------------------------------------------
   4. Seed -- curated common IANA zones. Idempotent MERGE on
      iana_time_zone so re-running does not duplicate rows or blow
      away edits made from the new screen.
   ------------------------------------------------------------------ */
MERGE GRAC_New.time_zone_master AS target
USING (VALUES
    (N'Coordinated Universal Time',        N'UTC',                  N'UTC+00:00'),
    (N'India Standard Time',               N'Asia/Kolkata',         N'UTC+05:30'),
    (N'Pakistan Standard Time',            N'Asia/Karachi',         N'UTC+05:00'),
    (N'Bangladesh Standard Time',          N'Asia/Dhaka',           N'UTC+06:00'),
    (N'Nepal Time',                        N'Asia/Kathmandu',       N'UTC+05:45'),
    (N'Sri Lanka Standard Time',           N'Asia/Colombo',         N'UTC+05:30'),
    (N'Gulf Standard Time (UAE)',          N'Asia/Dubai',           N'UTC+04:00'),
    (N'Gulf Standard Time (Oman)',         N'Asia/Muscat',          N'UTC+04:00'),
    (N'Arabia Standard Time (Saudi)',      N'Asia/Riyadh',          N'UTC+03:00'),
    (N'Arabia Standard Time (Qatar)',      N'Asia/Qatar',           N'UTC+03:00'),
    (N'Arabia Standard Time (Kuwait)',     N'Asia/Kuwait',          N'UTC+03:00'),
    (N'Arabia Standard Time (Bahrain)',    N'Asia/Bahrain',         N'UTC+03:00'),
    (N'Israel Standard Time',              N'Asia/Jerusalem',       N'UTC+02:00'),
    (N'Turkey Time',                       N'Europe/Istanbul',      N'UTC+03:00'),
    (N'Singapore Standard Time',           N'Asia/Singapore',       N'UTC+08:00'),
    (N'Malaysia Time',                     N'Asia/Kuala_Lumpur',    N'UTC+08:00'),
    (N'Western Indonesia Time',            N'Asia/Jakarta',         N'UTC+07:00'),
    (N'Indochina Time (Thailand)',         N'Asia/Bangkok',         N'UTC+07:00'),
    (N'Indochina Time (Vietnam)',          N'Asia/Ho_Chi_Minh',     N'UTC+07:00'),
    (N'Philippine Standard Time',          N'Asia/Manila',          N'UTC+08:00'),
    (N'Hong Kong Time',                    N'Asia/Hong_Kong',       N'UTC+08:00'),
    (N'China Standard Time',               N'Asia/Shanghai',        N'UTC+08:00'),
    (N'Taipei Standard Time',              N'Asia/Taipei',          N'UTC+08:00'),
    (N'Japan Standard Time',               N'Asia/Tokyo',           N'UTC+09:00'),
    (N'Korea Standard Time',               N'Asia/Seoul',           N'UTC+09:00'),
    (N'Greenwich Mean Time (UK)',          N'Europe/London',        N'UTC+00:00'),
    (N'Irish Standard Time',               N'Europe/Dublin',        N'UTC+00:00'),
    (N'Central European Time (France)',    N'Europe/Paris',         N'UTC+01:00'),
    (N'Central European Time (Germany)',   N'Europe/Berlin',        N'UTC+01:00'),
    (N'Central European Time (Spain)',     N'Europe/Madrid',        N'UTC+01:00'),
    (N'Central European Time (Italy)',     N'Europe/Rome',          N'UTC+01:00'),
    (N'Central European Time (Netherlands)',N'Europe/Amsterdam',    N'UTC+01:00'),
    (N'Central European Time (Switzerland)',N'Europe/Zurich',       N'UTC+01:00'),
    (N'Eastern European Time (Greece)',    N'Europe/Athens',        N'UTC+02:00'),
    (N'Moscow Standard Time',              N'Europe/Moscow',        N'UTC+03:00'),
    (N'Eastern European Time (Egypt)',     N'Africa/Cairo',         N'UTC+02:00'),
    (N'South Africa Standard Time',        N'Africa/Johannesburg',  N'UTC+02:00'),
    (N'West Africa Time',                  N'Africa/Lagos',         N'UTC+01:00'),
    (N'East Africa Time',                  N'Africa/Nairobi',       N'UTC+03:00'),
    (N'Eastern Time (US)',                 N'America/New_York',     N'UTC-05:00'),
    (N'Central Time (US)',                 N'America/Chicago',      N'UTC-06:00'),
    (N'Mountain Time (US)',                N'America/Denver',       N'UTC-07:00'),
    (N'Pacific Time (US)',                 N'America/Los_Angeles',  N'UTC-08:00'),
    (N'Alaska Time (US)',                  N'America/Anchorage',    N'UTC-09:00'),
    (N'Hawaii-Aleutian Standard Time',     N'Pacific/Honolulu',     N'UTC-10:00'),
    (N'Eastern Time (Canada)',             N'America/Toronto',      N'UTC-05:00'),
    (N'Pacific Time (Canada)',             N'America/Vancouver',    N'UTC-08:00'),
    (N'Central Time (Mexico)',             N'America/Mexico_City',  N'UTC-06:00'),
    (N'Brasilia Time',                     N'America/Sao_Paulo',    N'UTC-03:00'),
    (N'Australian Eastern Standard Time',  N'Australia/Sydney',     N'UTC+10:00'),
    (N'Australian Western Standard Time',  N'Australia/Perth',      N'UTC+08:00'),
    (N'New Zealand Standard Time',         N'Pacific/Auckland',     N'UTC+12:00')
) AS source(time_zone_name, iana_time_zone, utc_offset)
ON target.iana_time_zone = source.iana_time_zone
WHEN NOT MATCHED THEN INSERT(time_zone_name, iana_time_zone, utc_offset, status, entered_by)
    VALUES(source.time_zone_name, source.iana_time_zone, source.utc_offset, N'Active', N'migration-058');
GO

PRINT 'Migration 058_time_zone_master_table_and_procs applied.';
GO
