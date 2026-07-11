/*
  Removes Domain from the Control master for existing ControlManagement databases.
  Controls remain reusable objectives; domain/category context is derived from mapped
  source structure nodes and reporting.

  This script archives existing control-domain assignments before dropping the
  obsolete column/table. It detects the schema that contains the Control table,
  so it can run against databases using cm or another schema name such as GRAC_New.
*/
DECLARE @schema_name SYSNAME;

SELECT TOP 1 @schema_name = s.name
FROM sys.schemas s
JOIN sys.tables t ON t.schema_id = s.schema_id
JOIN sys.columns c ON c.object_id = t.object_id
WHERE t.name = N'control'
  AND c.name = N'domain_id'
ORDER BY CASE WHEN s.name = N'GRAC_New' THEN 0 ELSE 1 END, s.name;

IF @schema_name IS NOT NULL
BEGIN
    DECLARE @control_table NVARCHAR(300) = QUOTENAME(@schema_name) + N'.' + QUOTENAME(N'control');
    DECLARE @domain_table NVARCHAR(300) = QUOTENAME(@schema_name) + N'.' + QUOTENAME(N'control_domain');
    DECLARE @archive_table NVARCHAR(300) = QUOTENAME(@schema_name) + N'.' + QUOTENAME(N'control_domain_assignment_archive');
    DECLARE @domain_object NVARCHAR(300) = @schema_name + N'.control_domain';
    DECLARE @archive_object NVARCHAR(300) = @schema_name + N'.control_domain_assignment_archive';
    DECLARE @sql NVARCHAR(MAX);

    IF OBJECT_ID(@domain_object, N'U') IS NOT NULL
    BEGIN
        SET @sql = N'
IF OBJECT_ID(N''' + REPLACE(@archive_object,'''','''''') + N''', N''U'') IS NULL
BEGIN
    SELECT c.control_id,c.control_code,c.control_name,c.domain_id,d.domain_code,d.domain_name,SYSUTCDATETIME() AS archived_dt
    INTO ' + @archive_table + N'
    FROM ' + @control_table + N' c
    LEFT JOIN ' + @domain_table + N' d ON d.domain_id = c.domain_id;
END
ELSE
BEGIN
    INSERT ' + @archive_table + N'(control_id,control_code,control_name,domain_id,domain_code,domain_name,archived_dt)
    SELECT c.control_id,c.control_code,c.control_name,c.domain_id,d.domain_code,d.domain_name,SYSUTCDATETIME()
    FROM ' + @control_table + N' c
    LEFT JOIN ' + @domain_table + N' d ON d.domain_id = c.domain_id
    WHERE NOT EXISTS (
        SELECT 1
        FROM ' + @archive_table + N' a
        WHERE a.control_id = c.control_id
    );
END';
        EXEC sp_executesql @sql;
    END

    SET @sql = N'';
    SELECT @sql = @sql + N'ALTER TABLE '
        + QUOTENAME(parent_schema.name) + N'.' + QUOTENAME(parent_table.name)
        + N' DROP CONSTRAINT ' + QUOTENAME(fk.name) + N';' + CHAR(13) + CHAR(10)
    FROM sys.foreign_keys fk
    JOIN sys.tables parent_table ON parent_table.object_id = fk.parent_object_id
    JOIN sys.schemas parent_schema ON parent_schema.schema_id = parent_table.schema_id
    JOIN sys.tables referenced_table ON referenced_table.object_id = fk.referenced_object_id
    JOIN sys.schemas referenced_schema ON referenced_schema.schema_id = referenced_table.schema_id
    WHERE referenced_schema.name = @schema_name
      AND referenced_table.name = N'control_domain';

    IF @sql <> N'' EXEC sp_executesql @sql;

    SET @sql = N'ALTER TABLE ' + @control_table + N' DROP COLUMN domain_id;';
    EXEC sp_executesql @sql;

    IF OBJECT_ID(@domain_object, N'U') IS NOT NULL
    BEGIN
        SET @sql = N'DROP TABLE ' + @domain_table + N';';
        EXEC sp_executesql @sql;
    END
END
GO
