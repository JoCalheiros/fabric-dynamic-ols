param(
    [string] $configRelPath = "ParametersExample.json",
    [string] $workspaceId = "your-workspace-id",
    [string] $datasetId = "your-dataset-id",
    [string] $datasetName = "Sales",
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

# Get Config
$configPath = "$currentPath\$configRelPath"
$config = Get-Content -Raw -Path $configPath | ConvertFrom-Json

# Fabric Authentication
$servicePrincipalId =  $config.ServiceAuth.servicePrincipalId
$servicePrincipalSecret = $config.ServiceAuth.servicePrincipalSecret 
$tenantId = $config.ServiceAuth.tenantId 
Set-FabricAuthToken -servicePrincipalId $servicePrincipalId -servicePrincipalSecret $servicePrincipalSecret -tenantId $tenantId -reset

# AzureDB Authentication
$serverName = $config.ConnectionAzureSQL.serverName
$databaseName = $config.ConnectionAzureSQL.DatabaseName 
$azureUsername= $config.ConnectionAzureSQL.Username 
$azurePassword= $config.ConnectionAzureSQL.Password
$connectionString = "Server=tcp:$serverName,1433;Initial Catalog=$databaseName;Persist Security Info=False;User ID=$azureUsername;Password=$azurePassword;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

# Exporting Dataset from Fabric
write-host "##[group] | Getting Model BIM" 
$exportPath = Join-Path (Split-Path $currentPath -Parent) "\$ExportRelPath\$workspaceId\$datasetName.SemanticModel"
Export-FabricItem -path $exportPath -workspaceId $workspaceId -itemId $datasetId -format "TMSL"

# Get Model BIM
$bimFilePath = "$exportPath\model.bim"
$model = Get-Content -Path $bimFilePath -Encoding utf8 | ConvertFrom-Json

#Query DB Schema
$querySchema = Get-Content -Path "$currentPath\$querySchema"
$dbSchema = Query-AzureDB -DBConnectionString $connectionString -query $querySchema

#Filter Tables that have "Source Table" annotation
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


#Output to BIM
write-host "Writing output bim file"
$model | ConvertTo-Json -Depth 20 | Out-File -LiteralPath $bimFilePath -Encoding utf8

Import-FabricItems -workspaceId $workspaceId -path $exportPath