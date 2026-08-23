-- =====================================================================
-- 049 ROLLBACK -- back to the shared status-active vocabulary
--
-- Reverses the three things 049 did: the data migration, the lookup groups,
-- and the procedure change.
--
-- CAUTION ON STEP 1
-- -----------------
-- 049 folded two populations together.  Rows that held 'Inactive' before it ran
-- and rows that RETIRE set to 'Retired' afterwards are both 'Retired' now, and
-- nothing distinguishes them -- `updated_by = '049'` marks the ones the
-- migration touched, but any row edited since has lost that marker.
--
-- If a faithful reversal matters, recover the pre-049 statuses from
-- GRAC_New.audit_trace_event (before_json / after_json) rather than flipping
-- everything back.  The bulk revert below is a blunt instrument: it sends EVERY
-- 'Retired' row in these tables to 'Inactive', including ones that were always
-- 'Retired'.  Read it before running it.
-- =====================================================================

-- STEP 0 -- what the migration touched, as far as it can still be told
SELECT 'authority' AS TableName, status, updated_by, COUNT(*) AS Rows_
FROM   GRAC_New.authority GROUP BY status, updated_by
UNION ALL SELECT 'statement_classification', status, updated_by, COUNT(*) FROM GRAC_New.statement_classification GROUP BY status, updated_by
UNION ALL SELECT 'control_domain', status, updated_by, COUNT(*) FROM GRAC_New.control_domain GROUP BY status, updated_by
UNION ALL SELECT 'control_sub_domain', status, updated_by, COUNT(*) FROM GRAC_New.control_sub_domain GROUP BY status, updated_by
UNION ALL SELECT 'control_requirement_map', status, updated_by, COUNT(*) FROM GRAC_New.control_requirement_map GROUP BY status, updated_by
UNION ALL SELECT 'source_control_map', status, updated_by, COUNT(*) FROM GRAC_New.source_control_map GROUP BY status, updated_by
UNION ALL SELECT 'framework_statement_control_map', status, updated_by, COUNT(*) FROM GRAC_New.framework_statement_control_map GROUP BY status, updated_by
UNION ALL SELECT 'framework_statement_requirement_map', status, updated_by, COUNT(*) FROM GRAC_New.framework_statement_requirement_map GROUP BY status, updated_by
UNION ALL SELECT 'obligation_evidence_type', status, updated_by, COUNT(*) FROM GRAC_New.obligation_evidence_type GROUP BY status, updated_by
ORDER BY TableName, status, updated_by;
GO

-- STEP 1 -- narrow revert: only the rows still carrying the migration marker.
-- Safer than the bulk revert, and correct for a rollback performed promptly.
--
--   BEGIN TRAN;
--   UPDATE GRAC_New.authority                           SET status = N'Inactive' WHERE status = N'Retired' AND updated_by = N'049';
--   UPDATE GRAC_New.statement_classification            SET status = N'Inactive' WHERE status = N'Retired' AND updated_by = N'049';
--   UPDATE GRAC_New.control_domain                      SET status = N'Inactive' WHERE status = N'Retired' AND updated_by = N'049';
--   UPDATE GRAC_New.control_sub_domain                  SET status = N'Inactive' WHERE status = N'Retired' AND updated_by = N'049';
--   UPDATE GRAC_New.control_requirement_map             SET status = N'Inactive' WHERE status = N'Retired' AND updated_by = N'049';
--   UPDATE GRAC_New.source_control_map                  SET status = N'Inactive' WHERE status = N'Retired' AND updated_by = N'049';
--   UPDATE GRAC_New.framework_statement_control_map     SET status = N'Inactive' WHERE status = N'Retired' AND updated_by = N'049';
--   UPDATE GRAC_New.framework_statement_requirement_map SET status = N'Inactive' WHERE status = N'Retired' AND updated_by = N'049';
--   UPDATE GRAC_New.obligation_evidence_type            SET status = N'Inactive' WHERE status = N'Retired' AND updated_by = N'049';
--   UPDATE GRAC_New.cm_cascade_deactivation SET previous_status = N'Inactive' WHERE previous_status = N'Retired' AND restored_dt IS NULL;
--   COMMIT;

-- STEP 2 -- lookup groups
-- Restore the 'Archived' release option, and retire the two new groups.  They
-- are left in place rather than deleted so any row still referencing a
-- reference_option_id keeps its foreign key.
--
--   UPDATE GRAC_New.reference_option SET status = N'Active'
--   WHERE option_group = N'release-status' AND option_value = N'Archived';
--
--   UPDATE GRAC_New.reference_option SET status = N'Inactive'
--   WHERE option_group IN (N'status-repository', N'status-admin');

-- STEP 3 -- restore the procedures
-- Run 048_cascade_deactivation.sql: it carries the pre-049 definitions of both
-- dbo.cm_manage_repository (RETIRE writing 'Inactive' for Authority and
-- friends) and the cascade wiring.  cm_get_repository's only 049 change is the
-- unmapped-statement default, which is cosmetic and can be left alone.

-- =====================================================================
-- APPLICATION SIDE
-- =====================================================================
-- Revert src/ControlManagement.Web/wwwroot/js/repository.js:
--   - 26 schemas point back at 'status-active' instead of
--     'status-repository' / 'status-admin'
--   - populateStatusFilter() / statusLookupKey() go back to merging every
--     lookup group whose key contains "status"
--
-- If the JS is reverted but the database is not, the filters fall back to
-- 'status-active' (Active / Inactive / Retired) and still work -- the extra
-- 'Inactive' option simply matches nothing on the repository screens.

PRINT 'Review the census above, then work through steps 1-3 in this file.';
GO
