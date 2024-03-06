param(
	[string] $bimFileRelPath = "SalesReport\SalesReport.Dataset\model.bim",
	[string] $tenantId = "09e251dc-5e87-48bf-b4d2-71b01adb984a",
	[string] $workspaceId = "03221cab-dbcc-4273-a897-324782236c2d",
	[string] $ExportRelPath = "ExportPath",
	[string] $datasetId = "a430712b-ee9e-4937-9709-9a96a5f654cb",
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