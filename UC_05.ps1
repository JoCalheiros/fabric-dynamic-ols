param(
    [string] $configRelPath = "ParametersExample.json",
    [string] $workspaceId = "your-workspace-id",
    [string] $datasetId = "your-dataset-id",
    [string] $datasetName = "Sales",
    [string] $queryPermissions = "Queries\Permissions.sql",
    [string] $querySchema = "Queries\TableSchema.sql",
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

Import-Module "$currentPath\modules\FabricPS-PBIP" 

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
$azureUsername= $config.ConnectionAzureSQL.Username 
$azurePassword=  $config.ConnectionAzureSQL.Password
$connectionString = "Server=tcp:$serverName,1433;Initial Catalog=$databaseName;Persist Security Info=False;User ID=$azureUsername;Password=$azurePassword;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

# SQL Query
$queryRoles = Get-Content -Path "$currentPath\$queryRoles"
$queryPermissions = Get-Content -Path "$currentPath\$queryPermissions"
$querySchema = Get-Content -Path "$currentPath\$querySchema"


$exportPath = Join-Path (Split-Path $currentPath -Parent) "\$ExportRelPath\$workspaceId\$datasetName.SemanticModel"
Export-FabricItem -path $exportPath -workspaceId $workspaceId -itemId $datasetId -format "TMSL"

#Dataset parameters
write-host "##[group] | Getting Model BIM" 
$bimFilePath = "$exportPath\model.bim"
$model = Get-Content -Path $bimFilePath -Encoding utf8 | ConvertFrom-Json


#-----UPDATE DYNAMIC SCHEMA-----

$dbSchema = Query-AzureDB -DBConnectionString $connectionString -query $querySchema

$tables = $model.model.tables
$tables = $tables | Where-Object {$_.annotations.name -eq "SourceTable"}


$tables | ForEach-Object {

    $table = $_

    #Get from the "SourceTable" annotation the Source Table name
    $sourceTable = $table.annotations | Where-Object {$_.name -eq "SourceTable"} | Select-Object -ExpandProperty Value

    #Filter the Source table in the Schema Query
    $fieldsToAdd = $dbSchema | Where-Object {$_.table -eq $sourceTable}

    #Add new fields to the model
    $fieldsToAdd | ForEach-Object {
        $field = $_
        
        #Check if DB Column is on BIM Model
        $fieldOnBIM = $table.columns | Where-Object { $_.name -eq $field.Column }

        #Add Column if not in BIM Model
        if (!$fieldOnBIM)
        {
            write-host "Adding field '$($field.Column)' to the table '$($table.name)'"

            $newColumn =[PSCustomObject]@{
                "name" = $field.Column
                "dataType" = "string"
                "sourceColumn" = $field.Column
                "summarizeBy" = "none"
            }

            $table.columns += $newColumn
        }

    }

    #Check if bim fields are not in DB
    $bimFieldNames = $table.columns.name
    $dbFieldNames = $fieldsToAdd.Column
    $fieldsNamestoRemove = $bimFieldNames | Where-Object { $dbFieldNames -notcontains $_ }

    #If BIM Fields are not in DB Columns then remove them
    $fieldsNamestoRemove | ForEach-Object {
        $fieldName = $_
        write-host "Removing field '$fieldName' from the table '$($table.name)'"
        $table.columns = $table.columns | Where-Object { $_.name -ne $fieldName }
    }
    
}


#-----ADDING OLS-----

#Creating Roles Object if not exists
if(!$model.model.roles){
    
    $newObject = @()
    $model.model | Add-Member -MemberType NoteProperty -Name "roles" -Value $newObject
}

#Adding DB Roles
$dbRoles = Query-AzureDB -DBConnectionString $connectionString -query $queryRoles
foreach($dbRole in $dbRoles){

    $roleName = $dbRole.name

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

$dbRolePermissions = Query-AzureDB -DBConnectionString $connectionString -query $queryPermissions
foreach($dbRolePermission in $dbRolePermissions){

    $roleName = $dbRolePermission.RoleName
    $table = $dbRolePermission.Table
    $column = $dbRolePermission.Column

    if($dbRolePermission.ColumnPermission -eq 1){
        $columnPermission = "Read" 
    }else{
        $columnPermission = "None" 
    }

    $selectedRole = $model.model.roles | Where-Object {$_.name -eq $roleName}
    $selectedTable = $selectedRole.tablePermissions | Where-Object {$_.name -eq $table}

    if(!$selectedTable ){
        $newTable = [PSCustomObject]@{
            "name" = $table
            "filterExpression" = @()
            "columnPermissions" = @()
        }
        $selectedRole.tablePermissions += $newTable
    }

    $selectedColumnPermission = $selectedTable.columnPermissions | Where-Object {$_.name -eq $column}
    if(!$selectedColumnPermission ){
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