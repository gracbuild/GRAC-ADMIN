-- =====================================================================
-- 042 -- ROLLBACK: return the ASSET event domain to its 033 state
--
-- Restores the past-tense codes and sets the ASSET root and both leaves
-- back to Inactive.
--
-- READ BEFORE RUNNING
-- -------------------
-- If an obligation has been mapped to an asset event since 042 ran, this
-- rollback does NOT unmap it -- obligation_assurance_spec.event_type_id
-- survives untouched (the id never changed, only the code and status).
-- What happens instead is that the obligation goes quiet: the subscriber
-- view grac_practice.vw_pm_event_driven_obligation filters
-- et.status = N'Active', so those obligations stop appearing in the Asset
-- Category Assurance screen and stop being raised. Nothing is lost, but
-- nothing fires either. Check first:
--
--     SELECT o.obligation_id, e.event_code
--     FROM   GRAC_New.obligation_assurance_spec o
--     JOIN   GRAC_New.event_type_master e ON e.event_type_id = o.event_type_id
--     WHERE  e.event_code LIKE N'ASSET[_]%';
--
-- The subscriber side is not reverted by this file. PracticeManagement
-- keeps using ASSET_COMMISSIONING / ASSET_DECOMMISSIONING, which after
-- this rollback match nothing in admin -- the same empty-screen state
-- that existed before 042.
--
-- Safe to re-run. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('GRAC_New.event_type_master','U') IS NULL
BEGIN
    RAISERROR('042 rollback: GRAC_New.event_type_master is missing.', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

IF EXISTS (SELECT 1 FROM GRAC_New.event_type_master WHERE event_code = N'ASSET_COMMISSIONING')
   AND NOT EXISTS (SELECT 1 FROM GRAC_New.event_type_master WHERE event_code = N'ASSET_COMMISSIONED')
    UPDATE GRAC_New.event_type_master
       SET event_code  = N'ASSET_COMMISSIONED',
           event_name  = N'Commissioned',
           description = N'An asset is brought into service.',
           updated_by  = 'rollback-042',
           updated_dt  = SYSUTCDATETIME()
     WHERE event_code  = N'ASSET_COMMISSIONING';
GO

IF EXISTS (SELECT 1 FROM GRAC_New.event_type_master WHERE event_code = N'ASSET_DECOMMISSIONING')
   AND NOT EXISTS (SELECT 1 FROM GRAC_New.event_type_master WHERE event_code = N'ASSET_DECOMMISSIONED')
    UPDATE GRAC_New.event_type_master
       SET event_code  = N'ASSET_DECOMMISSIONED',
           event_name  = N'Decommissioned',
           description = N'An asset is retired from service.',
           updated_by  = 'rollback-042',
           updated_dt  = SYSUTCDATETIME()
     WHERE event_code  = N'ASSET_DECOMMISSIONING';
GO

UPDATE GRAC_New.event_type_master
   SET status     = N'Inactive',
       updated_by = 'rollback-042',
       updated_dt = SYSUTCDATETIME()
 WHERE event_code IN (N'ASSET', N'ASSET_COMMISSIONED', N'ASSET_DECOMMISSIONED')
   AND status <> N'Inactive';
GO

COMMIT TRAN;
GO

SELECT 'codes reverted to past tense' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM GRAC_New.event_type_master WHERE event_code = N'ASSET_COMMISSIONED')
             AND EXISTS (SELECT 1 FROM GRAC_New.event_type_master WHERE event_code = N'ASSET_DECOMMISSIONED')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'ASSET domain inactive',
       CASE WHEN NOT EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                              WHERE event_code IN (N'ASSET', N'ASSET_COMMISSIONED',
                                                   N'ASSET_DECOMMISSIONED')
                                AND status <> N'Inactive')
            THEN 'PASS' ELSE 'FAIL' END;

-- Obligations that just went quiet, if any.
SELECT s.obligation_id AS ObligationId,
       e.event_code    AS EventCode,
       e.status        AS EventStatus
FROM   GRAC_New.obligation_assurance_spec s
JOIN   GRAC_New.event_type_master e ON e.event_type_id = s.event_type_id
WHERE  e.event_code IN (N'ASSET_COMMISSIONED', N'ASSET_DECOMMISSIONED');

PRINT '042 rolled back: ASSET event domain is Inactive and past-tense again.';
PRINT 'Any obligation listed above is still mapped but will no longer be raised.';
GO
