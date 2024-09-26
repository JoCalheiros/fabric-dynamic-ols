param(
	[string] $configRelPath = "ParametersExample.json",
	[string] $workspaceId = "your-workspace-id",
	[string] $datasetId = "your-dataset-id",
	[string] $datasetName = "Sales",
	[string] $ExportRelPath = "ExportPath"
)

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

$exportPath = Join-Path (Split-Path $currentPath -Parent) "\$ExportRelPath\$workspaceId\$datasetName.SemanticModel"
Export-FabricItem -path $exportPath -workspaceId $workspaceId -itemId $datasetId -format "TMSL"

#Dataset parameters
$bimFilePath = "$exportPath\model.bim"

write-host "##[group] | Getting Model BIM" 
$model = Get-Content -Path $bimFilePath -Encoding utf8 | ConvertFrom-Json

#Modifying column objcet
$salesTable = $model.model.tables | Where-Object {$_.name -eq "Sales"}
$salesTableColumn = $salesTable.columns | Where-Object {$_.name -eq "Total Price"}
$salesTableColumn.name = "Total"

#Output to BIM
write-host "Writing output bim file"
$model | ConvertTo-Json -Depth 20 | Out-File -LiteralPath $bimFilePath -Encoding utf8

Import-FabricItems -workspaceId $workspaceId -path $exportPath