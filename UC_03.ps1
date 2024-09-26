param(
    [string] $configRelPath = "ParametersExample.json",
    [string] $workspaceId = "your-workspace-id",
    [string] $datasetId = "your-dataset-id",
    [string] $datasetName = "Sales",
    [string] $queryPermissions = "Queries\Permissions.sql",
    [string] $queryRoles = "Queries\Roles.sql",
    [string] $exportRelPath = "ExportPath"
)

function GenerateHash {
    param(
        [string]$InputString
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $inputBytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
    $hashBytes = $sha256.ComputeHash($inputBytes)

    $hashString = [System.BitConverter]::ToString($hashBytes) -replace '-', ''

    $hashString = $hashString.Substring(0, 32)

    return $hashString
}

function Query-AzureDB{
    param (
        [string] $DBConnectionString,
        [string] $query
    )
    try {
        $connection = New-Object System.Data.SqlClient.SqlConnection
        $connection.ConnectionString = $DBConnectionString
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $query
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $result = $dataset.Tables[0]
    } catch {
        Write-Host "Error when connecting to database: $_"
    } finally {
        if ($connection.State -eq 'Open') {
            $connection.Close()
        }
    }
    return $result
}

$currentPath = (Split-Path $MyInvocation.MyCommand.Definition -Parent)

Import-Module "$currentPath\modules\FabricPS-PBIP" -Force

#Get Config
$configPath = "$currentPath\$configRelPath"
$config = Get-Content -Raw -Path $configPath | ConvertFrom-Json

#Fabric Authentication
$servicePrincipalId = $config.ServiceAuth.servicePrincipalId
$servicePrincipalSecret = $config.ServiceAuth.servicePrincipalSecret 
$tenantId = $config.ServiceAuth.tenantId
Set-FabricAuthToken -servicePrincipalId $servicePrincipalId -servicePrincipalSecret $servicePrincipalSecret -tenantId $tenantId -reset

#AzureDB Authentication
$serverName = $config.ConnectionAzureSQL.serverName
$databaseName = $config.ConnectionAzureSQL.DatabaseName 
$azureUsername = $config.ConnectionAzureSQL.Username 
$azurePassword = $config.ConnectionAzureSQL.Password
$connectionString = "Server=tcp:$serverName,1433;Initial Catalog=$databaseName;Persist Security Info=False;User ID=$azureUsername;Password=$azurePassword;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

# SQL Queries
$queryRoles = Get-Content -Path "$currentPath\$queryRoles"
$queryPermissions = Get-Content -Path "$currentPath\$queryPermissions"

#Export BIM file
$exportPath = Join-Path (Split-Path $currentPath -Parent) "\$ExportRelPath\$workspaceId\$datasetName.SemanticModel"
Export-FabricItem -path $exportPath -workspaceId $workspaceId -itemId $datasetId -format "TMSL"

#Dataset parameters
write-host "##[group] | Getting Model BIM" 
$bimFilePath = "$exportPath\model.bim"
$model = Get-Content -Path $bimFilePath -Encoding utf8 | ConvertFrom-Json

#Creating roles object
if(!$model.model.roles){
    
    $newObject = @()
    $model.model | Add-Member -MemberType NoteProperty -Name "roles" -Value $newObject

}

#Adding DB Roles
$dbRoles = Query-AzureDB -DBConnectionString $connectionString -query $queryRoles
foreach($dbRole in $dbRoles){

    $roleName = $dbRole.name

    #Check if role exists in BIM file
    $currentRole = $model.model.roles | Where-Object {$_.name -eq $roleName}
    if(!$currentRole){
        $newRole = [PSCustomObject]@{
            "name" = $roleName
            "annotations" = @(
                [PSCustomObject]@{
                    "name" = "PBI_Id"
                    "value" = GenerateHash $roleName
                }
            )
            "modelPermission" = "read"
            "tablePermissions" = @()
        }
        $model.model.roles += $newRole

    }    
}

#Adding Permissions to the Roles
$dbRolePermissions = Query-AzureDB -DBConnectionString $connectionString -query $queryPermissions
foreach($dbRolePermission in $dbRolePermissions){

    $roleName = $dbRolePermission.RoleName
    $table = $dbRolePermission.Table
    $column = $dbRolePermission.Column

    #Check column permission
    if($dbRolePermission.ColumnPermission -eq 1){
        $columnPermission = "Read" 
    }else{
        $columnPermission = "None" 
    }

    $selectedRole = $model.model.roles | Where-Object {$_.name -eq $roleName}
    $selectedTable = $selectedRole.tablePermissions | Where-Object {$_.name -eq $table}

    #Add table to table permissions
    if(!$selectedTable){
        $newTable = [PSCustomObject]@{
            "name" = $table
            "filterExpression" = @()
            "columnPermissions" = @()
        }
        $selectedRole.tablePermissions += $newTable
    }

    #Check column in BIM model
    $selectedColumnPermission = $selectedTable.columnPermissions | Where-Object {$_.name -eq $column}

    #Add column permissions
    if(!$selectedColumnPermission){
        $newColumnPermission = [PSCustomObject]@{
            "name" = $column
            "metadataPermission" = $columnPermission
        }
        $tablePermission = $selectedRole.tablePermissions | Where-Object {$_.name -eq $table}
        $tablePermission.columnPermissions  += $newColumnPermission
        
    }else{
        $selectedColumnPermission.metadataPermission = $columnPermission
    }

}

#Output to BIM
write-host "Writing output bim file"
$model | ConvertTo-Json -Depth 20 | Out-File -LiteralPath $bimFilePath -Encoding utf8

Import-FabricItems -workspaceId $workspaceId -path $exportPath