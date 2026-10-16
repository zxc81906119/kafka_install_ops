# Export the generated .docx to PDF with Word (updates the table of contents first) for a visual check.
# usage: powershell -File render.ps1 [-Out <pdf>]
param([string]$Out = "$env:TEMP\cp-manual.pdf")
$docx = Join-Path $PSScriptRoot '..\Confluent-手動安裝手冊.docx' | Resolve-Path
$w = New-Object -ComObject Word.Application
$w.Visible = $false
try {
  $d = $w.Documents.Open($docx.Path, $false, $true)
  $d.TablesOfContents | ForEach-Object { $_.Update() }
  $d.ExportAsFixedFormat($Out, 17)   # 17 = wdExportFormatPDF
  "pages=$($d.ComputeStatistics(2)) pdf=$Out"
  $d.Close($false)
} finally { $w.Quit() }
