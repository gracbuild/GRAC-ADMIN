/* =====================================================================
   059_iso27001_v13_masters.sql

   Master-data prerequisites for the v1.3 Practice and Obligation load
   (060 - 065).  Two small vocabularies the workbook uses that the
   database did not yet carry.

   Source : Import Practice & Obligation Mapping v1.3 (4).xlsx

   1.  EVIDENCE TYPES
   ------------------
   The registers use a controlled list of ten Evidence Type values:

       Agreement   Checklist   Configuration/Screenshot   Document
       Log         Policy      Process   Record   Register   Report

   evidence_type_master already holds ten values of its own, seeded by 001
   and 012 -- Policy Document, Procedure Document, System Screenshot,
   System Report, Audit Log, Approval Record, Review Register, Meeting
   Minutes, Configuration Export, Incident Report.  They are NOT the same
   list and they are NOT retired here: rows loaded before this migration
   still point at them.  The ten new values are added alongside, so the
   master ends up with twenty and the workbook loads verbatim rather than
   through a lossy translation ('Document', 'Agreement' and 'Checklist'
   have no sensible equivalent in the original ten).

   Codes are prefixed EVT- so the two generations stay distinguishable in
   the Evidence Type master screen.  evidence_type_code is UNIQUE and so
   is evidence_type_name in practice, so both are guarded.

   2.  FREQUENCY
   -------------
   The Execution and Assurance registers use six frequency words:

       Continuous 2,881    One-time 1,189    Yearly 1,646
       Quarterly    665    Monthly     10    Daily       1

   reference_option group 'frequency-types' (seeded by 001, re-seeded by
   011) holds: Daily, Weekly, Monthly, Quarterly, Half-Yearly, Annual,
   Event Driven, Continuous, Custom.

     Continuous, Quarterly, Monthly, Daily  -- already present.
     Yearly    -- the workbook's word for the master's 'Annual'.  NOT
                  seeded.  060-065 translate Yearly -> Annual on the way
                  in, so the dropdown does not end up offering two options
                  that mean the same thing.
     One-time  -- no equivalent in the master.  Seeded here, display_order
                  10, after Custom.

   Rerunnable : yes.  Every insert is guarded; running twice adds nothing.
   Rollback   : 059_iso27001_v13_masters_rollback.sql
   Order      : 058 -> 059 (this file) -> 060 -> 061 -> 062 -> 063 -> 064 -> 065

   FILE ENCODING
   -------------
   UTF-8 with BOM.  Run with: sqlcmd -f 65001 -i 059_iso27001_v13_masters.sql
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

BEGIN TRY
BEGIN TRANSACTION;

DECLARE @by      NVARCHAR(100) = N'anoop.ps@soffit.in';
DECLARE @ins_evt INT = 0, @ins_freq INT = 0;

-- ---------------------------------------------------------------
-- Preflight
-- ---------------------------------------------------------------
IF SCHEMA_ID(N'GRAC_New') IS NULL
    THROW 50510, 'Schema GRAC_New is missing. Run 001 first.', 1;
IF OBJECT_ID(N'GRAC_New.evidence_type_master','U') IS NULL
    THROW 50511, 'GRAC_New.evidence_type_master is missing. Run 001 first.', 1;
IF OBJECT_ID(N'GRAC_New.reference_option','U') IS NULL
    THROW 50512, 'GRAC_New.reference_option is missing. Run 001 first.', 1;

-- ---------------------------------------------------------------
-- 1.  Evidence types
-- ---------------------------------------------------------------
;WITH seed(evidence_type_code, evidence_type_name, display_order) AS (
    SELECT N'EVT-AGREEMENT',            N'Agreement',                101 UNION ALL
    SELECT N'EVT-CHECKLIST',            N'Checklist',                102 UNION ALL
    SELECT N'EVT-CONFIG-SCREENSHOT',    N'Configuration/Screenshot', 103 UNION ALL
    SELECT N'EVT-DOCUMENT',             N'Document',                 104 UNION ALL
    SELECT N'EVT-LOG',                  N'Log',                      105 UNION ALL
    SELECT N'EVT-POLICY',               N'Policy',                   106 UNION ALL
    SELECT N'EVT-PROCESS',              N'Process',                  107 UNION ALL
    SELECT N'EVT-RECORD',               N'Record',                   108 UNION ALL
    SELECT N'EVT-REGISTER',             N'Register',                 109 UNION ALL
    SELECT N'EVT-REPORT',               N'Report',                   110
)
INSERT GRAC_New.evidence_type_master(evidence_type_code, evidence_type_name, display_order, is_active, entered_by)
SELECT s.evidence_type_code, s.evidence_type_name, s.display_order, 1, @by
FROM seed s
WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.evidence_type_master e
                 WHERE e.evidence_type_code = s.evidence_type_code
                    OR e.evidence_type_name = s.evidence_type_name);
SET @ins_evt = @@ROWCOUNT;

-- Re-activate any of the ten that a previous rollback deactivated instead
-- of deleting, so a rollback-then-reload round trip is clean.
UPDATE GRAC_New.evidence_type_master
   SET is_active = 1, updated_by = @by, updated_dt = SYSUTCDATETIME()
WHERE evidence_type_code IN (N'EVT-AGREEMENT', N'EVT-CHECKLIST', N'EVT-CONFIG-SCREENSHOT',
                             N'EVT-DOCUMENT', N'EVT-LOG', N'EVT-POLICY', N'EVT-PROCESS',
                             N'EVT-RECORD', N'EVT-REGISTER', N'EVT-REPORT')
  AND is_active = 0;

-- ---------------------------------------------------------------
-- 2.  Frequency: 'One-time'
-- ---------------------------------------------------------------
INSERT GRAC_New.reference_option(option_group, option_value, option_label, display_order, status, entered_by)
SELECT N'frequency-types', N'One-time', N'One-time', 10, N'Active', @by
WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.reference_option
                 WHERE option_group = N'frequency-types' AND option_value = N'One-time');
SET @ins_freq = @@ROWCOUNT;

UPDATE GRAC_New.reference_option
   SET status = N'Active', updated_by = @by, updated_dt = SYSUTCDATETIME()
WHERE option_group = N'frequency-types' AND option_value = N'One-time' AND status <> N'Active';

-- ---------------------------------------------------------------
-- 3.  Assert everything 060-065 will look up now resolves.
--
-- Fail here, before a single Practice is written, rather than midway
-- through 12,071 Obligation inserts.
-- ---------------------------------------------------------------
DECLARE @missing NVARCHAR(4000), @error NVARCHAR(4000);

IF EXISTS(SELECT 1 FROM (VALUES
        (N'Agreement'),(N'Checklist'),(N'Configuration/Screenshot'),(N'Document'),(N'Log'),
        (N'Policy'),(N'Process'),(N'Record'),(N'Register'),(N'Report')) v(nm)
     WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.evidence_type_master e
                      WHERE e.evidence_type_name = v.nm AND e.is_active = 1))
BEGIN
    SET @missing = STUFF((SELECT N', ' + v.nm FROM (VALUES
            (N'Agreement'),(N'Checklist'),(N'Configuration/Screenshot'),(N'Document'),(N'Log'),
            (N'Policy'),(N'Process'),(N'Record'),(N'Register'),(N'Report')) v(nm)
        WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.evidence_type_master e
                         WHERE e.evidence_type_name = v.nm AND e.is_active = 1)
        FOR XML PATH('')), 1, 2, N'');
    SET @error = CONCAT(N'Evidence type(s) still unresolved after seeding: ', @missing,
                        N'. An inactive row with the same name probably blocked the insert.');
    THROW 50513, @error, 1;
END

IF EXISTS(SELECT 1 FROM (VALUES
        (N'Continuous'),(N'One-time'),(N'Annual'),(N'Quarterly'),(N'Monthly'),(N'Daily')) v(nm)
     WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.reference_option o
                      WHERE o.option_group = N'frequency-types'
                        AND o.option_value = v.nm AND o.status = N'Active'))
BEGIN
    SET @missing = STUFF((SELECT N', ' + v.nm FROM (VALUES
            (N'Continuous'),(N'One-time'),(N'Annual'),(N'Quarterly'),(N'Monthly'),(N'Daily')) v(nm)
        WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.reference_option o
                         WHERE o.option_group = N'frequency-types'
                           AND o.option_value = v.nm AND o.status = N'Active')
        FOR XML PATH('')), 1, 2, N'');
    SET @error = CONCAT(N'Frequency option(s) missing from frequency-types: ', @missing,
                        N'. Run 011_seed_frequency_standard_values.sql, then re-run 059.');
    THROW 50514, @error, 1;
END

-- 063 loads 239 EventDriven Assurance rows whose events must resolve to a
-- leaf under the Asset or People domain.  033 seeds the ASSET domain
-- Inactive; 042 activates it.  Without 042 those rows cannot resolve and
-- 063 would abort partway.  Catch it here instead.
IF OBJECT_ID(N'GRAC_New.event_type_master','U') IS NOT NULL
BEGIN
    IF EXISTS(SELECT 1 FROM (VALUES
            (N'People', N'Onboarding'), (N'People', N'Offboarding'),
            (N'Asset',  N'Commissioning'), (N'Asset', N'Decommissioning')) v(dom, evt)
         WHERE NOT EXISTS(
               SELECT 1
               FROM GRAC_New.event_type_master leaf
               JOIN GRAC_New.event_type_master root ON root.event_type_id = leaf.parent_event_type_id
               WHERE leaf.event_name = v.evt AND root.event_name = v.dom
                 AND leaf.status = N'Active' AND root.status = N'Active'))
    BEGIN
        SET @missing = STUFF((SELECT N', ' + v.dom + N' / ' + v.evt FROM (VALUES
                (N'People', N'Onboarding'), (N'People', N'Offboarding'),
                (N'Asset',  N'Commissioning'), (N'Asset', N'Decommissioning')) v(dom, evt)
            WHERE NOT EXISTS(
                  SELECT 1
                  FROM GRAC_New.event_type_master leaf
                  JOIN GRAC_New.event_type_master root ON root.event_type_id = leaf.parent_event_type_id
                  WHERE leaf.event_name = v.evt AND root.event_name = v.dom
                    AND leaf.status = N'Active' AND root.status = N'Active')
            FOR XML PATH('')), 1, 2, N'');
        SET @error = CONCAT(N'Event type(s) not active: ', @missing,
                            N'. 063 needs all four for its 239 EventDriven Assurance rows. Run 033 and 042 first.');
        THROW 50515, @error, 1;
    END
END

COMMIT TRANSACTION;

PRINT CONCAT(N'059 complete. Evidence types inserted ', @ins_evt,
             N' | Frequency options inserted ', @ins_freq,
             N'. All lookups 060-065 depend on resolve.');
PRINT N'Next: run 060_iso27001_v13_practices.sql.';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
GO

-- ---------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------
SELECT evidence_type_id, evidence_type_code, evidence_type_name, display_order, is_active
FROM GRAC_New.evidence_type_master
ORDER BY display_order, evidence_type_name;
GO

SELECT reference_option_id, option_value, option_label, display_order, status
FROM GRAC_New.reference_option
WHERE option_group = N'frequency-types'
ORDER BY display_order;
GO
