/* =====================================================================
   _discover_grac_practice_schema.sql

   READ-ONLY.  Dumps the shape of the grac_practice schema so a seed
   script can be written for it.

   WHY THIS EXISTS
   ---------------
   grac_practice is deployed from the Practice Management repository, not
   from ControlManagement, so its table list, columns, keys and check
   constraints are not knowable from this codebase.  058 cleared the
   schema; rebuilding its master rows needs the real shape, not a guess.

   Nothing here writes.  It is safe to run on any database, at any time.

   HOW TO USE
   ----------
   1. Run the whole file in SSMS with results as TEXT (Ctrl+T), not grid --
      each section returns one wide column that is meant to be copied
      verbatim.
   2. Copy the output of all six sections and send it back.
   3. Section 6 is the important one for a seed: it is the row content of
      every table small enough to be a lookup/master.  Redact anything
      confidential before sharing.

   FILE ENCODING : UTF-8 with BOM.
   ===================================================================== */

SET NOCOUNT ON;
GO

IF SCHEMA_ID(N'grac_practice') IS NULL
BEGIN
    PRINT N'grac_practice schema does not exist on this instance. Nothing to report.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1.  Tables and current row counts
--
-- After 058 these should all be 0.  A non-zero count means that table
-- survived the reset and does not need re-seeding.
-- =====================================================================
PRINT N'';
PRINT N'===== 1. TABLES AND ROW COUNTS =====';
GO
SELECT CONCAT(t.name, N'  |  rows = ', SUM(p.rows)) AS [grac_practice tables]
FROM sys.tables t
JOIN sys.schemas s    ON s.schema_id = t.schema_id
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE s.name = N'grac_practice'
GROUP BY t.name
ORDER BY t.name;
GO

-- =====================================================================
-- 2.  Columns
--
-- Type, nullability, identity and default for every column.  A seed
-- script has to satisfy every NOT NULL column that has no default.
-- =====================================================================
PRINT N'';
PRINT N'===== 2. COLUMNS =====';
GO
SELECT CONCAT(
        t.name, N'.', c.name,
        N'  ', UPPER(ty.name),
        CASE WHEN ty.name IN (N'varchar',N'nvarchar',N'char',N'nchar',N'varbinary',N'binary')
             THEN CONCAT(N'(', CASE WHEN c.max_length = -1 THEN N'MAX'
                                    WHEN ty.name IN (N'nvarchar',N'nchar')
                                    THEN CAST(c.max_length/2 AS NVARCHAR(10))
                                    ELSE CAST(c.max_length AS NVARCHAR(10)) END, N')')
             WHEN ty.name IN (N'decimal',N'numeric')
             THEN CONCAT(N'(', c.precision, N',', c.scale, N')')
             ELSE N'' END,
        CASE WHEN c.is_nullable = 1 THEN N' NULL' ELSE N' NOT NULL' END,
        CASE WHEN c.is_identity = 1 THEN N' IDENTITY' ELSE N'' END,
        CASE WHEN c.is_computed = 1 THEN N' COMPUTED' ELSE N'' END,
        ISNULL(CONCAT(N' DEFAULT ', dc.definition), N'')) AS [columns]
FROM sys.tables t
JOIN sys.schemas s        ON s.schema_id = t.schema_id
JOIN sys.columns c        ON c.object_id = t.object_id
JOIN sys.types ty         ON ty.user_type_id = c.user_type_id
LEFT JOIN sys.default_constraints dc ON dc.object_id = c.default_object_id
WHERE s.name = N'grac_practice'
ORDER BY t.name, c.column_id;
GO

-- =====================================================================
-- 3.  Primary keys and unique constraints
--
-- These are the natural keys a rerunnable seed has to guard against.
-- =====================================================================
PRINT N'';
PRINT N'===== 3. PRIMARY KEYS AND UNIQUE INDEXES =====';
GO
SELECT CONCAT(
        t.name, N'  ',
        CASE WHEN i.is_primary_key = 1 THEN N'PK' ELSE N'UNIQUE' END,
        N' ', i.name,
        CASE WHEN i.has_filter = 1 THEN CONCAT(N' WHERE ', i.filter_definition) ELSE N'' END,
        N'  (',
        STUFF((SELECT N', ' + c2.name
               FROM sys.index_columns ic2
               JOIN sys.columns c2 ON c2.object_id = ic2.object_id AND c2.column_id = ic2.column_id
               WHERE ic2.object_id = i.object_id AND ic2.index_id = i.index_id AND ic2.is_included_column = 0
               ORDER BY ic2.key_ordinal
               FOR XML PATH('')), 1, 2, N''),
        N')') AS [keys]
FROM sys.indexes i
JOIN sys.tables t  ON t.object_id = i.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = N'grac_practice'
  AND (i.is_primary_key = 1 OR i.is_unique_constraint = 1 OR i.is_unique = 1)
ORDER BY t.name, i.name;
GO

-- =====================================================================
-- 4.  Foreign keys
--
-- Gives the insert order a seed has to follow, and shows which tables
-- reach back into GRAC_New.
-- =====================================================================
PRINT N'';
PRINT N'===== 4. FOREIGN KEYS =====';
GO
SELECT CONCAT(
        OBJECT_SCHEMA_NAME(fk.parent_object_id), N'.', OBJECT_NAME(fk.parent_object_id),
        N'.', pc.name,
        N'  ->  ',
        OBJECT_SCHEMA_NAME(fk.referenced_object_id), N'.', OBJECT_NAME(fk.referenced_object_id),
        N'.', rc.name,
        N'   [', fk.name, N']',
        CASE WHEN fk.delete_referential_action_desc <> N'NO_ACTION'
             THEN CONCAT(N' ON DELETE ', fk.delete_referential_action_desc) ELSE N'' END) AS [foreign keys]
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id     AND pc.column_id = fkc.parent_column_id
JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
WHERE fk.parent_object_id     IN (SELECT object_id FROM sys.tables WHERE schema_id = SCHEMA_ID(N'grac_practice'))
   OR fk.referenced_object_id IN (SELECT object_id FROM sys.tables WHERE schema_id = SCHEMA_ID(N'grac_practice'))
ORDER BY 1;
GO

-- =====================================================================
-- 5.  Check constraints and triggers
--
-- Check constraints carry the allowed values for status / type / mode
-- columns -- a seed that writes anything else is rejected.  Triggers
-- matter because an append-only one blocks DELETE (this is what 058 hit).
-- =====================================================================
PRINT N'';
PRINT N'===== 5. CHECK CONSTRAINTS =====';
GO
SELECT CONCAT(t.name, N'  ', cc.name, N'  ', cc.definition) AS [check constraints]
FROM sys.check_constraints cc
JOIN sys.tables t  ON t.object_id = cc.parent_object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = N'grac_practice'
ORDER BY t.name, cc.name;
GO

PRINT N'';
PRINT N'===== 5b. TRIGGERS =====';
GO
SELECT CONCAT(t.name, N'  ', tr.name,
              CASE WHEN tr.is_disabled = 1 THEN N'  (disabled)' ELSE N'  (enabled)' END,
              CASE WHEN OBJECTPROPERTY(tr.object_id, 'ExecIsDeleteTrigger')    = 1 THEN N' DELETE'    ELSE N'' END,
              CASE WHEN OBJECTPROPERTY(tr.object_id, 'ExecIsInsertTrigger')    = 1 THEN N' INSERT'    ELSE N'' END,
              CASE WHEN OBJECTPROPERTY(tr.object_id, 'ExecIsUpdateTrigger')    = 1 THEN N' UPDATE'    ELSE N'' END,
              CASE WHEN OBJECTPROPERTY(tr.object_id, 'ExecIsInsteadOfTrigger') = 1 THEN N' INSTEADOF' ELSE N'' END) AS [triggers]
FROM sys.triggers tr
JOIN sys.tables t  ON t.object_id = tr.parent_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = N'grac_practice'
ORDER BY t.name, tr.name;
GO

-- =====================================================================
-- 6.  Procedures, functions and views
--
-- If the app creates an organization through a stored procedure, calling
-- that is safer than inserting into its tables directly -- the procedure
-- knows the invariants.  Only names and parameters are listed here, not
-- the bodies.
-- =====================================================================
PRINT N'';
PRINT N'===== 6. PROCEDURES / FUNCTIONS / VIEWS =====';
GO
SELECT CONCAT(o.type_desc, N'  ', s.name, N'.', o.name,
              ISNULL(N'  (' + STUFF((SELECT N', ' + p.name + N' ' + UPPER(TYPE_NAME(p.user_type_id))
                                     FROM sys.parameters p
                                     WHERE p.object_id = o.object_id AND p.parameter_id > 0
                                     ORDER BY p.parameter_id
                                     FOR XML PATH('')), 1, 2, N'') + N')', N'')) AS [routines]
FROM sys.objects o
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE s.name = N'grac_practice'
  AND o.type IN ('P','FN','IF','TF','V')
ORDER BY o.type_desc, o.name;
GO

-- Any routine anywhere that writes into grac_practice -- the app's own
-- organization-creation path is very likely in this list.
PRINT N'';
PRINT N'===== 6b. ROUTINES (ANY SCHEMA) THAT REFERENCE grac_practice =====';
GO
SELECT CONCAT(SCHEMA_NAME(o.schema_id), N'.', o.name, N'   [', o.type_desc, N']') AS [writers]
FROM sys.sql_modules m
JOIN sys.objects o ON o.object_id = m.object_id
WHERE m.definition LIKE N'%grac_practice%'
ORDER BY 1;
GO

SET NOEXEC OFF;
GO
