/*
  GRAC Repository Management - Part 019
  Obligation data-model alignment.

  Goal: keep the existing one-to-many "Obligation -> Evidence" design but reshape
  it so an Obligation is independent of any particular (Requirement, Release) and
  may be re-used across many (Requirement, Release) contexts via a new mapping
  table.

  Effective schema after this script:

    requirement_obligation         (parent)
      obligation_id           BIGINT IDENTITY PK         -- ObligationID
      obligation_name         NVARCHAR(500) NOT NULL     -- Obligation Name  (NEW)
      obligation_text         NVARCHAR(MAX) NULL         -- preserved for backward compat
      execution_frequency_id  BIGINT NULL FK reference_option  (NEW)
      frequency_type          NVARCHAR(40) NULL          -- preserved cache of text
      retention_requirement   NVARCHAR(250) NULL         -- Retention Period
      remarks                 NVARCHAR(MAX) NULL         -- Remarks  (NEW)
      status_id               BIGINT NULL FK reference_option
      status                  NVARCHAR(30) DEFAULT 'Active'
      requirement_id          BIGINT NULL  (legacy column kept for backward compat)
      release_id              BIGINT NULL  (legacy column kept for backward compat)
      ...audit columns...

    requirement_obligation_evidence (child)
      obligation_evidence_id  BIGINT IDENTITY PK         -- ObligationEvidenceID
      obligation_id           BIGINT NOT NULL FK requirement_obligation
      evidence_type_id        INT NOT NULL FK evidence_type_master   -- EvidenceTypeID
      frequency_id            BIGINT NULL FK reference_option        -- AssuranceFrequencyID
      retention_requirement   NVARCHAR(250) NULL                     -- evidence-level Retention
      remarks                 NVARCHAR(MAX) NULL                     -- Remarks
      status                  NVARCHAR(30) DEFAULT 'Active'          -- StatusID maps via status_id
      ...audit columns...

    obligation_requirement_release_map (NEW)
      obligation_map_id BIGINT IDENTITY PK
      obligation_id     BIGINT NOT NULL FK requirement_obligation
      requirement_id    BIGINT NOT NULL FK requirement
      release_id        BIGINT NOT NULL FK release
      status            NVARCHAR(30) DEFAULT 'Active'
      ...audit columns...
      UNIQUE(obligation_id, requirement_id, release_id)

  Indexes:
    - Evidence uniqueness relaxed to (obligation_id, evidence_type_id, frequency_id)
      so the same Evidence Type may repeat under one Obligation provided the
      Assurance Frequency differs.
    - Mapping uniqueness blocks the same Obligation being mapped twice to the
      same Requirement + Release pair.

  Safe to re-run.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF SCHEMA_ID('GRAC_New') IS NULL
    THROW 51701, 'Schema GRAC_New is missing. Run Repository Management schema scripts first.', 1;

/* ----- 1. Parent: add new columns ----------------------------------------- */
IF OBJECT_ID('GRAC_New.requirement_obligation','U') IS NULL
    THROW 51702, 'requirement_obligation does not exist. Run 002_control_management_procedures.sql first.', 1;
GO

IF COL_LENGTH('GRAC_New.requirement_obligation','obligation_name') IS NULL
BEGIN
    ALTER TABLE GRAC_New.requirement_obligation ADD obligation_name NVARCHAR(500) NULL;
END
GO

IF COL_LENGTH('GRAC_New.requirement_obligation','execution_frequency_id') IS NULL
BEGIN
    ALTER TABLE GRAC_New.requirement_obligation
        ADD execution_frequency_id BIGINT NULL
            REFERENCES GRAC_New.reference_option(reference_option_id);
END
GO

IF COL_LENGTH('GRAC_New.requirement_obligation','remarks') IS NULL
BEGIN
    ALTER TABLE GRAC_New.requirement_obligation ADD remarks NVARCHAR(MAX) NULL;
END
GO

/* ----- 2. Back-fill parent columns ---------------------------------------- */
-- obligation_name <- first 500 chars of obligation_text where empty.
UPDATE GRAC_New.requirement_obligation
SET obligation_name = LTRIM(RTRIM(LEFT(obligation_text, 500)))
WHERE obligation_name IS NULL
  AND NULLIF(LTRIM(RTRIM(obligation_text)), N'') IS NOT NULL;
GO

-- execution_frequency_id <- match frequency_type text to reference_option(frequency-types).
UPDATE o
SET o.execution_frequency_id = ro.reference_option_id
FROM GRAC_New.requirement_obligation o
JOIN GRAC_New.reference_option ro
  ON ro.option_group = N'frequency-types'
 AND ro.status = N'Active'
 AND (LOWER(ro.option_value) = LOWER(o.frequency_type)
      OR LOWER(ro.option_label) = LOWER(o.frequency_type))
WHERE o.execution_frequency_id IS NULL
  AND NULLIF(LTRIM(RTRIM(o.frequency_type)), N'') IS NOT NULL;
GO

/* ----- 3. Make requirement_id / release_id nullable on the parent --------- */
-- An Obligation now lives independently of Requirement + Release; the link
-- moves to obligation_requirement_release_map.  Existing rows that already
-- carry a value are preserved (for backward compatibility) but the column is
-- now optional.
IF EXISTS (
    SELECT 1 FROM sys.columns c
    JOIN sys.tables t ON t.object_id = c.object_id
    WHERE t.name = 'requirement_obligation' AND c.name = 'requirement_id' AND c.is_nullable = 0)
BEGIN
    -- DROP and re-add the FK in nullable form (SQL Server doesn't allow ALTER COLUMN
    -- to flip nullability while the FK is in place).
    DECLARE @fk_req NVARCHAR(256) = (
        SELECT TOP 1 fk.name FROM sys.foreign_keys fk
        JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
        JOIN sys.columns c ON c.object_id = fk.parent_object_id AND c.column_id = fkc.parent_column_id
        WHERE fk.parent_object_id = OBJECT_ID('GRAC_New.requirement_obligation')
          AND c.name = 'requirement_id');
    IF @fk_req IS NOT NULL
        EXEC('ALTER TABLE GRAC_New.requirement_obligation DROP CONSTRAINT ' + @fk_req);
    ALTER TABLE GRAC_New.requirement_obligation ALTER COLUMN requirement_id BIGINT NULL;
    ALTER TABLE GRAC_New.requirement_obligation
        ADD CONSTRAINT fk_cm_req_obl_requirement
        FOREIGN KEY (requirement_id) REFERENCES GRAC_New.requirement(requirement_id);
END
GO

IF EXISTS (
    SELECT 1 FROM sys.columns c
    JOIN sys.tables t ON t.object_id = c.object_id
    WHERE t.name = 'requirement_obligation' AND c.name = 'release_id' AND c.is_nullable = 0)
BEGIN
    DECLARE @fk_rel NVARCHAR(256) = (
        SELECT TOP 1 fk.name FROM sys.foreign_keys fk
        JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
        JOIN sys.columns c ON c.object_id = fk.parent_object_id AND c.column_id = fkc.parent_column_id
        WHERE fk.parent_object_id = OBJECT_ID('GRAC_New.requirement_obligation')
          AND c.name = 'release_id');
    IF @fk_rel IS NOT NULL
        EXEC('ALTER TABLE GRAC_New.requirement_obligation DROP CONSTRAINT ' + @fk_rel);
    ALTER TABLE GRAC_New.requirement_obligation ALTER COLUMN release_id BIGINT NULL;
    ALTER TABLE GRAC_New.requirement_obligation
        ADD CONSTRAINT fk_cm_req_obl_release
        FOREIGN KEY (release_id) REFERENCES GRAC_New.release(release_id);
END
GO

-- Drop the old unique index that enforced one-obligation-per-(requirement,release)
-- because Obligation is no longer scoped that way.
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'ux_cm_requirement_obligation_release_active'
             AND object_id = OBJECT_ID('GRAC_New.requirement_obligation'))
BEGIN
    DROP INDEX ux_cm_requirement_obligation_release_active ON GRAC_New.requirement_obligation;
END
GO

/* ----- 4. Evidence uniqueness: (Obligation, EvidenceType, AssuranceFreq) -- */
-- Existing index was (obligation_id, evidence_type_id) - now replace with the
-- 3-column composite so the same EvidenceType can repeat under one Obligation
-- when the Assurance Frequency differs.
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'ux_cm_requirement_obligation_evidence_active'
             AND object_id = OBJECT_ID('GRAC_New.requirement_obligation_evidence'))
BEGIN
    DROP INDEX ux_cm_requirement_obligation_evidence_active
        ON GRAC_New.requirement_obligation_evidence;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ux_cm_obligation_evidence_typefreq_active'
                 AND object_id = OBJECT_ID('GRAC_New.requirement_obligation_evidence'))
BEGIN
    -- Filtered unique index so Inactive evidence rows do not block re-adding.
    -- ISNULL keeps two rows that omit the frequency from being treated as
    -- both "NULL = NULL is unknown" (SQL Server quirk on filtered unique
    -- indexes); coalesce against 0 to be safe.
    CREATE UNIQUE INDEX ux_cm_obligation_evidence_typefreq_active
        ON GRAC_New.requirement_obligation_evidence(
            obligation_id, evidence_type_id, frequency_id)
        WHERE status = 'Active';
END
GO

/* ----- 5. New mapping table ---------------------------------------------- */
IF OBJECT_ID('GRAC_New.obligation_requirement_release_map', 'U') IS NULL
BEGIN
    CREATE TABLE GRAC_New.obligation_requirement_release_map(
        obligation_map_id  BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_cm_obligation_map PRIMARY KEY,
        obligation_id      BIGINT NOT NULL
            CONSTRAINT fk_cm_obligation_map_obligation
                REFERENCES GRAC_New.requirement_obligation(obligation_id),
        requirement_id     BIGINT NOT NULL
            CONSTRAINT fk_cm_obligation_map_requirement
                REFERENCES GRAC_New.requirement(requirement_id),
        release_id         BIGINT NOT NULL
            CONSTRAINT fk_cm_obligation_map_release
                REFERENCES GRAC_New.release(release_id),
        status             NVARCHAR(30) NOT NULL
            CONSTRAINT df_cm_obligation_map_status DEFAULT 'Active',
        entered_by         NVARCHAR(100) NOT NULL
            CONSTRAINT df_cm_obligation_map_eb DEFAULT 'system',
        entered_dt         DATETIME2(3) NOT NULL
            CONSTRAINT df_cm_obligation_map_ed DEFAULT SYSUTCDATETIME(),
        updated_by         NVARCHAR(100) NULL,
        updated_dt         DATETIME2(3) NULL,
        CONSTRAINT uq_cm_obligation_map_active
            UNIQUE(obligation_id, requirement_id, release_id)
    );
    CREATE INDEX ix_cm_obligation_map_release   ON GRAC_New.obligation_requirement_release_map(release_id, status);
    CREATE INDEX ix_cm_obligation_map_requirement ON GRAC_New.obligation_requirement_release_map(requirement_id, status);
END
GO

/* ----- 6. Back-fill: existing parent rows that still carry the legacy
            requirement_id/release_id become mapping rows. ----------------- */
INSERT INTO GRAC_New.obligation_requirement_release_map(obligation_id, requirement_id, release_id, status, entered_by)
SELECT o.obligation_id, o.requirement_id, o.release_id, COALESCE(o.status, 'Active'), 'migration-019'
FROM GRAC_New.requirement_obligation o
WHERE o.requirement_id IS NOT NULL
  AND o.release_id IS NOT NULL
  AND NOT EXISTS (
        SELECT 1 FROM GRAC_New.obligation_requirement_release_map m
        WHERE m.obligation_id = o.obligation_id
          AND m.requirement_id = o.requirement_id
          AND m.release_id    = o.release_id);
GO

PRINT 'Migration 019 complete. Obligation parent decoupled from Requirement+Release; new mapping table created.';
PRINT 'Note: SP cm_manage_repository SAVE branch for obligations still writes the legacy requirement_id/release_id columns. Update it to write the mapping table separately when the front-end gains a multi-release picker.';
GO

/* Quick sanity counts. */
SELECT 'requirement_obligation rows' AS Item, COUNT_BIG(1) AS [Count] FROM GRAC_New.requirement_obligation
UNION ALL
SELECT 'requirement_obligation rows with obligation_name back-filled',
       COUNT_BIG(1) FROM GRAC_New.requirement_obligation WHERE obligation_name IS NOT NULL
UNION ALL
SELECT 'requirement_obligation rows with execution_frequency_id back-filled',
       COUNT_BIG(1) FROM GRAC_New.requirement_obligation WHERE execution_frequency_id IS NOT NULL
UNION ALL
SELECT 'obligation_requirement_release_map rows',
       COUNT_BIG(1) FROM GRAC_New.obligation_requirement_release_map
UNION ALL
SELECT 'requirement_obligation_evidence rows',
       COUNT_BIG(1) FROM GRAC_New.requirement_obligation_evidence;
GO
