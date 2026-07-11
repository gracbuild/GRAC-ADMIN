/*
  Removes the obsolete direct Release-Control mapping table from existing ControlManagement databases.
  The active model derives release-control coverage from:
    GRAC_New.source_control_map -> GRAC_New.source_structure_node -> GRAC_New.release

  Run this after applying 001/002 and reviewing any existing release_control_map rows.
*/
IF OBJECT_ID('GRAC_New.release_control_map','U') IS NOT NULL
BEGIN
    IF OBJECT_ID('GRAC_New.release_control_map_archive','U') IS NULL
    BEGIN
        SELECT *, SYSUTCDATETIME() AS archived_dt
        INTO GRAC_New.release_control_map_archive
        FROM GRAC_New.release_control_map;
    END
    ELSE
    BEGIN
        INSERT GRAC_New.release_control_map_archive
        SELECT m.*, SYSUTCDATETIME()
        FROM GRAC_New.release_control_map m
        WHERE NOT EXISTS (
            SELECT 1
            FROM GRAC_New.release_control_map_archive a
            WHERE a.release_control_map_id = m.release_control_map_id
        );
    END

    DROP TABLE GRAC_New.release_control_map;
END
GO
