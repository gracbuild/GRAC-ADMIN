-- =====================================================================
-- 048 ROLLBACK -- stop cascading deactivation
--
-- 048 ships three new objects and one replaced procedure.  Rolling back means
-- restoring the procedure; the new objects can stay or go.
--
-- ORDER MATTERS
-- -------------
--   1. Put any half-cascaded data back (below) -- BEFORE dropping anything.
--   2. Restore the procedure.
--   3. Optionally drop the cascade objects.
--
-- =====================================================================
-- STEP 1 -- inspect what the cascade has taken down but not yet restored
-- =====================================================================
SELECT root_entity_type, root_record_id, child_entity_type,
       COUNT(*) AS Rows_, MIN(entered_dt) AS FirstCascade, MAX(entered_dt) AS LastCascade
FROM   GRAC_New.cm_cascade_deactivation
WHERE  restored_dt IS NULL
GROUP  BY root_entity_type, root_record_id, child_entity_type
ORDER  BY root_entity_type, root_record_id, child_entity_type;
GO

-- If you want those children back Active before the cascade goes away, either
-- activate each root through the UI (which restores its batch properly), or
-- replay the restore in bulk with the block below.  Review the SELECT above
-- first -- this puts EVERY unrestored batch back.
--
--   BEGIN TRAN;
--
--   UPDATE t SET t.status = c.previous_status, t.updated_by = N'rollback-048', t.updated_dt = SYSUTCDATETIME()
--   FROM GRAC_New.artifact t
--   JOIN GRAC_New.cm_cascade_deactivation c ON c.child_entity_type = N'artifacts'
--    AND c.child_record_id = t.artifact_id AND c.restored_dt IS NULL;
--
--   UPDATE t SET t.status = c.previous_status, t.updated_by = N'rollback-048', t.updated_dt = SYSUTCDATETIME()
--   FROM GRAC_New.release t
--   JOIN GRAC_New.cm_cascade_deactivation c ON c.child_entity_type = N'releases'
--    AND c.child_record_id = t.release_id AND c.restored_dt IS NULL;
--
--   UPDATE t SET t.status = c.previous_status, t.updated_by = N'rollback-048', t.updated_dt = SYSUTCDATETIME()
--   FROM GRAC_New.source_structure_node t
--   JOIN GRAC_New.cm_cascade_deactivation c ON c.child_entity_type = N'source-structure'
--    AND c.child_record_id = t.structure_node_id AND c.restored_dt IS NULL;
--
--   UPDATE t SET t.status = c.previous_status, t.updated_by = N'rollback-048', t.updated_dt = SYSUTCDATETIME()
--   FROM GRAC_New.statement_classification t
--   JOIN GRAC_New.cm_cascade_deactivation c ON c.child_entity_type = N'statement-classifications'
--    AND c.child_record_id = t.statement_classification_id AND c.restored_dt IS NULL;
--
--   UPDATE t SET t.status = c.previous_status, t.updated_by = N'rollback-048', t.updated_dt = SYSUTCDATETIME()
--   FROM GRAC_New.framework_statement t
--   JOIN GRAC_New.cm_cascade_deactivation c ON c.child_entity_type = N'framework-statements'
--    AND c.child_record_id = t.framework_statement_id AND c.restored_dt IS NULL;
--
--   UPDATE t SET t.status = c.previous_status, t.updated_by = N'rollback-048', t.updated_dt = SYSUTCDATETIME()
--   FROM GRAC_New.source_control_map t
--   JOIN GRAC_New.cm_cascade_deactivation c ON c.child_entity_type = N'source-control-map'
--    AND c.child_record_id = t.source_control_map_id AND c.restored_dt IS NULL;
--
--   UPDATE t SET t.status = c.previous_status, t.updated_by = N'rollback-048', t.updated_dt = SYSUTCDATETIME()
--   FROM GRAC_New.framework_statement_control_map t
--   JOIN GRAC_New.cm_cascade_deactivation c ON c.child_entity_type = N'statement-control-map'
--    AND c.child_record_id = t.statement_control_map_id AND c.restored_dt IS NULL;
--
--   UPDATE t SET t.status = c.previous_status, t.updated_by = N'rollback-048', t.updated_dt = SYSUTCDATETIME()
--   FROM GRAC_New.framework_statement_requirement_map t
--   JOIN GRAC_New.cm_cascade_deactivation c ON c.child_entity_type = N'statement-requirement-map'
--    AND c.child_record_id = t.statement_requirement_map_id AND c.restored_dt IS NULL;
--
--   UPDATE GRAC_New.cm_cascade_deactivation
--   SET restored_dt = SYSUTCDATETIME(), restored_by = N'rollback-048'
--   WHERE restored_dt IS NULL;
--
--   COMMIT;

-- =====================================================================
-- STEP 2 -- restore the procedure
-- =====================================================================
-- Run 047_repository_activate_action.sql: it carries the pre-cascade
-- definition of dbo.cm_manage_repository (Activate without cascade) together
-- with the ck_cm_chg_action widening, so the Activate feature keeps working.
--
-- To go all the way back to no Activate at all, follow
-- 047_repository_activate_action_rollback.sql instead.

-- =====================================================================
-- STEP 3 -- optional: drop the cascade objects
-- =====================================================================
-- Only after step 2, and only once nothing references them.  Keeping the table
-- costs nothing and preserves the history of what was cascaded.
--
--   DROP FUNCTION IF EXISTS dbo.fn_cm_repository_descendant_status;
--   DROP FUNCTION IF EXISTS dbo.fn_cm_repository_descendants;
--   DROP TABLE    IF EXISTS GRAC_New.cm_cascade_deactivation;

-- =====================================================================
-- APPLICATION SIDE
-- =====================================================================
-- Revert the impact-preview endpoint and the cascade warning, or the UI will
-- keep calling an action the procedure no longer understands:
--   src/ControlManagement.Web/Controllers/ControlManagementGatewayController.cs  (DeactivationImpact)
--   src/ControlManagement.Api/Controllers/RepositoryController.cs               (RETIRE_IMPACT permission)
--   src/ControlManagement.Api/Validation/RepositoryCommandValidator.cs          (RETIRE_IMPACT)
--   src/ControlManagement.Web/wwwroot/js/repository.js                          (cascadeImpact, retire)
--
-- The preview fails soft -- cascadeImpact() swallows errors and shows the plain
-- confirmation -- so a missed UI revert degrades rather than breaks.

PRINT 'Review the output above, then follow steps 2 and 3 in this file.';
GO
