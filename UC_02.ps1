param(
	[string] $bimFileRelPath = "SalesReport\SalesReport.Dataset\model.bim",
	[string] $tenantId = "your-tenant-id",
	[string] $workspaceId = "your-workspace-id",
	[string] $ExportRelPath = "ExportPath",
	[string] $datasetId = "your-dataset-id",
	[string] $datasetName = "SalesReport"
)

$currentPath = (Split-Path $MyInvocation.MyCommand.Definition -Parent)


Import-Module "$currentPath\modules\FabricPS-PBIP" -Force
Set-FabricAuthToken -tenantId $tenantId -reset

$exportPath = Join-Path (Split-Path $currentPath -Parent) "\$ExportRelPath"
Export-FabricItems -path $exportPath -workspaceId $workspaceId -filter { $_.id -eq $datasetId}

#Dataset parameters
$bimFilePath = "$exportPath\$workspaceId\$datasetName.SemanticModel\model.bim"

write-host "##[group] | Getting Model BIM" 
$model = Get-Content -Path $bimFilePath -Encoding utf8 | ConvertFrom-Json

#Modifying column objcet
$salesTable = $model.model.tables | Where-Object {$_.name -eq "Sales"}
$salesTableColumn = $salesTable.columns | Where-Object {$_.name -eq "Total Price"}
$salesTableColumn.name = "Total"

#Output to BIM
write-host "Writing output bim file"
$model | ConvertTo-Json -Depth 20 | Out-File -LiteralPath $bimFilePath -Encoding utf8

Import-FabricItems -workspaceId $workspaceId -path "$exportPath\$workspaceId\$datasetName.SemanticModel"