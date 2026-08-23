-- =====================================================================
-- 026 Obligation Taxonomy schema -- ROLLBACK
--
-- Reverses the schema additions from 026_obligation_taxonomy_schema.sql
-- in dependency-safe order:
--   1. Drop the six per-type evidence link tables (they reference
--      requirement_obligation + requirement_obligation_evidence).
--   2. Drop the six per-type detail tables (they reference
--      requirement_obligation).
--   3. Drop the FK + column obligation_type_id on requirement_obligation.
--   4. Restore requirement_obligation_evidence.obligation_id to NOT NULL
--      IF and only if no NULL rows exist (otherwise skip to preserve
--      any detached specs created after 026 was applied -- caller must
--      resolve them manually before re-running this rollback).
--   5. Drop obligation_type_master.
--
-- If 027 data migration was applied, run its rollback FIRST, otherwise
-- this script's step (3) will fail because rows carry obligation_type_id
-- values that reference obligation_type_master.
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- ---------------------------------------------------------------------
-- 1. Drop link tables.
-- ---------------------------------------------------------------------
IF OBJECT_ID('GRAC_New.obligation_state_evidence_link','U') IS NOT NULL
    DROP TABLE GRAC_New.obligation_state_evidence_link;
GO
IF OBJECT_ID('GRAC_New.obligation_execution_evidence_link','U') IS NOT NULL
    DROP TABLE GRAC_New.obligation_execution_evidence_link;
GO
IF OBJECT_ID('GRAC_New.obligation_assurance_evidence_link','U') IS NOT NULL
    DROP TABLE GRAC_New.obligation_assurance_evidence_link;
GO
IF OBJECT_ID('GRAC_New.obligation_event_response_evidence_link','U') IS NOT NULL
    DROP TABLE GRAC_New.obligation_event_response_evidence_link;
GO
IF OBJECT_ID('GRAC_New.obligation_constraint_evidence_link','U') IS NOT NULL
    DROP TABLE GRAC_New.obligation_constraint_evidence_link;
GO
IF OBJECT_ID('GRAC_New.obligation_retention_evidence_link','U') IS NOT NULL
    DROP TABLE GRAC_New.obligation_retention_evidence_link;
GO

-- ---------------------------------------------------------------------
-- 2. Drop detail tables.
-- ---------------------------------------------------------------------
IF OBJECT_ID('GRAC_New.obligation_state_rule','U') IS NOT NULL
    DROP TABLE GRAC_New.obligation_state_rule;
GO
IF OBJECT_ID('GRAC_New.obligation_execution_spec','U') IS NOT NULL
    DROP TABLE GRAC_New.obligation_execution_spec;
GO
IF OBJECT_ID('GRAC_New.obligation_assurance_spec','U') IS NOT NULL
    DROP TABLE GRAC_New.obligation_assurance_spec;
GO
IF OBJECT_ID('GRAC_New.obligation_event_response','U') IS NOT NULL
    DROP TABLE GRAC_New.obligation_event_response;
GO
IF OBJECT_ID('GRAC_New.obligation_constraint_rule','U') IS NOT NULL
    DROP TABLE GRAC_New.obligation_constraint_rule;
GO
IF OBJECT_ID('GRAC_New.obligation_retention_spec','U') IS NOT NULL
    DROP TABLE GRAC_New.obligation_retention_spec;
GO

-- ---------------------------------------------------------------------
-- 3. Drop FK + column obligation_type_id from requirement_obligation.
--    Guarded so re-running the rollback after column is already gone
--    is a no-op.
-- ---------------------------------------------------------------------
IF EXISTS(SELECT 1 FROM sys.foreign_keys
          WHERE name='fk_cm_requirement_obligation_type')
    ALTER TABLE GRAC_New.requirement_obligation
        DROP CONSTRAINT fk_cm_requirement_obligation_type;
GO

IF EXISTS(SELECT 1 FROM sys.indexes
          WHERE name='ix_cm_requirement_obligation_type_status'
            AND object_id=OBJECT_ID('GRAC_New.requirement_obligation'))
    DROP INDEX ix_cm_requirement_obligation_type_status
        ON GRAC_New.requirement_obligation;
GO

IF COL_LENGTH('GRAC_New.requirement_obligation','obligation_type_id') IS NOT NULL
    ALTER TABLE GRAC_New.requirement_obligation
        DROP COLUMN obligation_type_id;
GO

-- ---------------------------------------------------------------------
-- 4. Restore requirement_obligation_evidence.obligation_id to NOT NULL
--    ONLY if no NULL rows exist.  If any detached specs were created
--    after 026, leave the column nullable and PRINT a warning -- caller
--    must reconcile before final tear-down.
-- ---------------------------------------------------------------------
IF OBJECT_ID('GRAC_New.requirement_obligation_evidence','U') IS NOT NULL
   AND EXISTS(SELECT 1 FROM sys.columns
              WHERE object_id=OBJECT_ID('GRAC_New.requirement_obligation_evidence')
                AND name='obligation_id'
                AND is_nullable=1)
BEGIN
    IF NOT EXISTS(SELECT 1 FROM GRAC_New.requirement_obligation_evidence
                  WHERE obligation_id IS NULL)
    BEGIN
        ALTER TABLE GRAC_New.requirement_obligation_evidence
            ALTER COLUMN obligation_id BIGINT NOT NULL;
    END
    ELSE
    BEGIN
        PRINT '026 rollback WARNING: requirement_obligation_evidence contains rows with obligation_id IS NULL.  Column left NULLable to preserve data.  Reconcile manually before re-running.';
    END
END
GO

-- ---------------------------------------------------------------------
-- 5. Drop obligation_type_master.
-- ---------------------------------------------------------------------
IF OBJECT_ID('GRAC_New.obligation_type_master','U') IS NOT NULL
    DROP TABLE GRAC_New.obligation_type_master;
GO

PRINT '026 obligation taxonomy schema rollback complete.';
GO
