SELECT
    r.[Name] AS 'RoleName',
    p.[Table] AS 'Table',
    p.[column] AS 'Column',
    p.[columnpermission] AS 'ColumnPermission'
FROM [dbo].[Permissions] p
INNER JOIN [dbo].[Roles] r
    ON p.RoleID = r.ID