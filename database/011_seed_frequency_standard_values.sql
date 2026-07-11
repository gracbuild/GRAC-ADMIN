/*
  GRAC Part 1 - Control Management
  Standard frequency master values for obligations and future evidence schedules.
*/
SET NOCOUNT ON;

IF SCHEMA_ID('GRAC_New') IS NULL
    THROW 51101, 'Schema GRAC_New is missing. Run Control Management schema scripts first.', 1;

IF OBJECT_ID('GRAC_New.reference_option','U') IS NULL
    THROW 51102, 'Table GRAC_New.reference_option is missing.', 1;

;WITH seed(option_group,option_value,option_label,display_order) AS (
    SELECT N'frequency-types',N'Daily',N'Daily',1 UNION ALL
    SELECT N'frequency-types',N'Weekly',N'Weekly',2 UNION ALL
    SELECT N'frequency-types',N'Monthly',N'Monthly',3 UNION ALL
    SELECT N'frequency-types',N'Quarterly',N'Quarterly',4 UNION ALL
    SELECT N'frequency-types',N'Half-Yearly',N'Half-Yearly',5 UNION ALL
    SELECT N'frequency-types',N'Annual',N'Annual',6 UNION ALL
    SELECT N'frequency-types',N'Event Driven',N'Event Driven',7 UNION ALL
    SELECT N'frequency-types',N'Continuous',N'Continuous',8 UNION ALL
    SELECT N'frequency-types',N'Custom',N'Custom',9
)
INSERT GRAC_New.reference_option(option_group,option_value,option_label,display_order,status,entered_by)
SELECT s.option_group,s.option_value,s.option_label,s.display_order,N'Active',N'system'
FROM seed s
WHERE NOT EXISTS(
    SELECT 1
    FROM GRAC_New.reference_option existing
    WHERE existing.option_group=s.option_group
      AND existing.option_value=s.option_value
);

SELECT option_value Frequency, option_label Label, display_order DisplayOrder, status Status
FROM GRAC_New.reference_option
WHERE option_group=N'frequency-types'
ORDER BY display_order, option_label;
