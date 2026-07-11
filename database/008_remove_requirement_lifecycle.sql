/*
  Removes lifecycle_state from Requirement master for existing databases.
  Requirement lifecycle is tracked through Change Management and Audit Traceability.

  Existing values are archived before the column is dropped.
*/
DECLARE @schema_name SYSNAME;

SELECT TOP 1 @schema_name = s.name
FROM sys.schemas s
JOIN sys.tables t ON t.schema_id = s.schema_id
JOIN sys.columns c ON c.object_id = t.object_id
WHERE t.name = N'requirement'
  AND c.name = N'lifecycle_state'
ORDER BY CASE WHEN s.name = N'GRAC_New' THEN 0 ELSE 1 END, s.name;

IF @schema_name IS NOT NULL
BEGIN
    DECLARE @requirement_table NVARCHAR(300) = QUOTENAME(@schema_name) + N'.' + QUOTENAME(N'requirement');
    DECLARE @archive_table NVARCHAR(300) = QUOTENAME(@schema_name) + N'.' + QUOTENAME(N'requirement_lifecycle_archive');
    DECLARE @archive_object NVARCHAR(300) = @schema_name + N'.requirement_lifecycle_archive';
    DECLARE @sql NVARCHAR(MAX);

    SET @sql = N'
IF OBJECT_ID(N''' + REPLACE(@archive_object,'''','''''') + N''', N''U'') IS NULL
BEGIN
    CREATE TABLE ' + @archive_table + N'(
        archive_id BIGINT IDENTITY PRIMARY KEY,
        requirement_id BIGINT NOT NULL,
        requirement_code NVARCHAR(100) NOT NULL,
        requirement_name NVARCHAR(300) NOT NULL,
        lifecycle_state NVARCHAR(30) NULL,
        archived_dt DATETIME2 NOT NULL
    );
    INSERT ' + @archive_table + N'(requirement_id,requirement_code,requirement_name,lifecycle_state,archived_dt)
    SELECT requirement_id,requirement_code,requirement_name,lifecycle_state,SYSUTCDATETIME()
    FROM ' + @requirement_table + N';
END
ELSE
BEGIN
    IF COLUMNPROPERTY(OBJECT_ID(N''' + REPLACE(@archive_object,'''','''''') + N'''), N''requirement_id'', N''IsIdentity'') = 1
        SET IDENTITY_INSERT ' + @archive_table + N' ON;

    INSERT ' + @archive_table + N'(requirement_id,requirement_code,requirement_name,lifecycle_state,archived_dt)
    SELECT requirement_id,requirement_code,requirement_name,lifecycle_state,SYSUTCDATETIME()
    FROM ' + @requirement_table + N' r
    WHERE NOT EXISTS (
        SELECT 1
        FROM ' + @archive_table + N' a
        WHERE a.requirement_id = r.requirement_id
    );

    IF COLUMNPROPERTY(OBJECT_ID(N''' + REPLACE(@archive_object,'''','''''') + N'''), N''requirement_id'', N''IsIdentity'') = 1
        SET IDENTITY_INSERT ' + @archive_table + N' OFF;
END';
    EXEC sp_executesql @sql;

    SET @sql = N'';
    SELECT @sql = @sql + N'ALTER TABLE '
        + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name)
        + N' DROP CONSTRAINT ' + QUOTENAME(dc.name) + N';' + CHAR(13) + CHAR(10)
    FROM sys.default_constraints dc
    JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
    JOIN sys.tables t ON t.object_id = dc.parent_object_id
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE s.name = @schema_name
      AND t.name = N'requirement'
      AND c.name = N'lifecycle_state';

    SELECT @sql = @sql + N'ALTER TABLE '
        + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name)
        + N' DROP CONSTRAINT ' + QUOTENAME(cc.name) + N';' + CHAR(13) + CHAR(10)
    FROM sys.check_constraints cc
    JOIN sys.tables t ON t.object_id = cc.parent_object_id
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE s.name = @schema_name
      AND t.name = N'requirement'
      AND cc.definition LIKE N'%lifecycle_state%';

    IF @sql <> N'' EXEC sp_executesql @sql;

    SET @sql = N'ALTER TABLE ' + @requirement_table + N' DROP COLUMN lifecycle_state;';
    EXEC sp_executesql @sql;
END
GO

DECLARE @reference_schema SYSNAME;
DECLARE @sql NVARCHAR(MAX);

SELECT TOP 1 @reference_schema = s.name
FROM sys.schemas s
JOIN sys.tables t ON t.schema_id = s.schema_id
WHERE t.name = N'reference_option'
ORDER BY CASE WHEN s.name = N'GRAC_New' THEN 0 ELSE 1 END, s.name;

IF @reference_schema IS NOT NULL
BEGIN
    SET @sql = N'DELETE FROM ' + QUOTENAME(@reference_schema) + N'.' + QUOTENAME(N'reference_option') + N' WHERE option_group = N''requirement-lifecycle'';';
    EXEC sp_executesql @sql;
END
GO
