-- =====================================================================
-- 042 -- Activate the ASSET event domain and align its codes
--
-- Context
-- -------
-- 033 seeded the ASSET branch of the event taxonomy Inactive, with this
-- note: "this codebase has no asset register yet (only cm_user exists).
-- Asset event types are seeded as Inactive so they appear in admin but
-- cannot be selected until a register exists. Flip to Active in the same
-- release that introduces the register."
--
-- That release has arrived -- on the subscriber side. PracticeManagement
-- migration 123 gave grac_practice.organization_dependency_asset a
-- lifecycle (lifecycle_status, commissioned_dt, decommissioned_dt), 126
-- seeded the matching practice event definitions, and 138 shipped the
-- Asset Category Assurance screen where an organization decides what has
-- to happen when an asset of a given category is commissioned or retired.
-- The register the asset events attach to lives there.
--
-- TWO CHANGES, BOTH REQUIRED FOR THE SUBSCRIBER SIDE TO SEE ANYTHING
-- ------------------------------------------------------------------
-- 1. STATUS. grac_practice.vw_pm_event_driven_obligation filters
--    et.status = N'Active', and dbo.sp_cm_event_type_list hides both a
--    domain root and its leaves unless Active. While the ASSET rows stay
--    Inactive no admin can map an obligation to an asset event, and no
--    organization can see one.
--
-- 2. CODE. The leaves were seeded ASSET_COMMISSIONED / ASSET_DECOMMISSIONED
--    while every practice-side artefact -- event_definition (126), the
--    raise procedures (124, 128) and the checklist editor UI -- uses
--    ASSET_COMMISSIONING / ASSET_DECOMMISSIONING. The view joins on
--    event_code, so the mismatch alone would leave the asset screen
--    permanently empty.
--
--    The rename happens HERE rather than on the practice side because
--    these codes are referenced nowhere else in this repository (only
--    033 and docs/event-driven-assurance-design.md mention them) and,
--    being Inactive, no obligation can yet have been mapped to them.
--    The practice side, by contrast, has seeds, two stored procedures,
--    raised instances and UI on the gerund form. Changing the side with
--    no dependents is the smaller and safer edit -- and the gerund also
--    matches PEOPLE_ONBOARDING / PEOPLE_OFFBOARDING, so the taxonomy
--    ends up internally consistent instead of half past-tense.
--
-- WHAT IS NOT CHANGED
-- -------------------
-- subject_entity stays NULL on the ASSET branch. It records which
-- register in THIS database an occurrence attaches to, and GRAC_New
-- still has no asset table -- cm_user is the only register here. The
-- subscriber does not depend on it: grac_practice.sp_event_obligation_raise
-- takes its own @subject_entity ('EMPLOYEE' / 'ASSET') parameter and uses
-- the admin value for display only. Writing a practice table name into an
-- admin column would be a lie about this database's contents.
--
-- event_type_id is untouched by the rename, so any obligation_assurance_spec
-- row already pointing at these types keeps pointing at them.
--
-- Preflight: 033 (event_type_master).
-- Rollback: database/042_asset_event_types_activate_rollback.sql
-- Safe to re-run. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('GRAC_New.event_type_master','U') IS NULL
BEGIN
    RAISERROR('042 preflight failed: GRAC_New.event_type_master is missing. Run 033 first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF NOT EXISTS (SELECT 1 FROM GRAC_New.event_type_master WHERE event_code = N'ASSET')
BEGIN
    RAISERROR('042 preflight failed: the ASSET domain root is missing. Run 033 first.', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. Rename the two leaves to the gerund form.
--
--    Guarded both ways so the migration is a no-op on a database where
--    it has already run, and cannot trip uq_cm_event_type_code if an
--    operator has separately created a row under the target name.
-- =====================================================================
IF EXISTS (SELECT 1 FROM GRAC_New.event_type_master WHERE event_code = N'ASSET_COMMISSIONED')
   AND NOT EXISTS (SELECT 1 FROM GRAC_New.event_type_master WHERE event_code = N'ASSET_COMMISSIONING')
    UPDATE GRAC_New.event_type_master
       SET event_code  = N'ASSET_COMMISSIONING',
           event_name  = N'Commissioning',
           description = N'An asset is brought into service.',
           updated_by  = 'migration-042',
           updated_dt  = SYSUTCDATETIME()
     WHERE event_code  = N'ASSET_COMMISSIONED';
GO

IF EXISTS (SELECT 1 FROM GRAC_New.event_type_master WHERE event_code = N'ASSET_DECOMMISSIONED')
   AND NOT EXISTS (SELECT 1 FROM GRAC_New.event_type_master WHERE event_code = N'ASSET_DECOMMISSIONING')
    UPDATE GRAC_New.event_type_master
       SET event_code  = N'ASSET_DECOMMISSIONING',
           event_name  = N'Decommissioning',
           description = N'An asset is retired from service.',
           updated_by  = 'migration-042',
           updated_dt  = SYSUTCDATETIME()
     WHERE event_code  = N'ASSET_DECOMMISSIONED';
GO

-- =====================================================================
-- 2. Activate the domain root and its leaves.
--
--    The root matters as much as the leaves: sp_cm_event_type_list
--    suppresses a child whose parent is Inactive, so activating only the
--    leaves would still leave the cascade empty.
-- =====================================================================
UPDATE GRAC_New.event_type_master
   SET status     = N'Active',
       updated_by = 'migration-042',
       updated_dt = SYSUTCDATETIME()
 WHERE event_code IN (N'ASSET', N'ASSET_COMMISSIONING', N'ASSET_DECOMMISSIONING')
   AND status <> N'Active';
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'commissioning code renamed' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                          WHERE event_code = N'ASSET_COMMISSIONING')
             AND NOT EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                              WHERE event_code = N'ASSET_COMMISSIONED')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'decommissioning code renamed',
       CASE WHEN EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                          WHERE event_code = N'ASSET_DECOMMISSIONING')
             AND NOT EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                              WHERE event_code = N'ASSET_DECOMMISSIONED')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'ASSET domain active',
       CASE WHEN NOT EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                              WHERE event_code IN (N'ASSET', N'ASSET_COMMISSIONING',
                                                   N'ASSET_DECOMMISSIONING')
                                AND status <> N'Active')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'leaves still parented to ASSET',
       CASE WHEN (SELECT COUNT(*)
                  FROM   GRAC_New.event_type_master c
                  JOIN   GRAC_New.event_type_master p ON p.event_type_id = c.parent_event_type_id
                  WHERE  p.event_code = N'ASSET'
                    AND  c.event_code IN (N'ASSET_COMMISSIONING', N'ASSET_DECOMMISSIONING')) = 2
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'existing obligation mappings preserved',
       CASE WHEN OBJECT_ID('GRAC_New.obligation_assurance_spec','U') IS NULL
             OR  NOT EXISTS (SELECT 1
                             FROM   GRAC_New.obligation_assurance_spec s
                             WHERE  s.event_type_id IS NOT NULL
                               AND  NOT EXISTS (SELECT 1 FROM GRAC_New.event_type_master e
                                                 WHERE e.event_type_id = s.event_type_id))
            THEN 'PASS' ELSE 'FAIL -- an obligation points at a missing event type' END;

-- The taxonomy as an admin now sees it.
SELECT c.event_code   AS EventCode,
       c.event_name   AS EventName,
       p.event_code   AS ParentCode,
       c.subject_entity AS SubjectEntity,
       c.status       AS Status
FROM   GRAC_New.event_type_master c
LEFT   JOIN GRAC_New.event_type_master p ON p.event_type_id = c.parent_event_type_id
ORDER  BY COALESCE(p.display_order, c.display_order), c.parent_event_type_id, c.display_order;

PRINT '042 ASSET event domain activated and aligned to the gerund code form.';
PRINT 'Asset obligations can now be authored in admin and will surface in the';
PRINT 'subscriber Asset Category Assurance screen. No obligation mapping changed.';
GO
