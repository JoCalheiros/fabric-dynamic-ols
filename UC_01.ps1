param(
	[string] $bimFileRelPath = "SalesReport\SalesReport.Dataset\model.bim"
)

$currentPath = (Split-Path $MyInvocation.MyCommand.Definition -Parent)

#Dataset parameters
$bimFilePath = Join-Path (Split-Path $currentPath -Parent) "\$bimFileRelPath"

write-host "##[group] | Getting Model BIM" 
$model = Get-Content -Path $bimFilePath -Encoding utf8 | ConvertFrom-Json

#Modifying column objcet
$salesTable = $model.model.tables | Where-Object {$_.name -eq "Sales"}
$salesTableColumn = $salesTable.columns | Where-Object {$_.name -eq "Total Price"}
$salesTableColumn.name = "Total"

#Output to BIM
write-host "Writing output bim file"
$model | ConvertTo-Json -Depth 20 | Out-File -LiteralPath $bimFilePath -Encoding utf8

