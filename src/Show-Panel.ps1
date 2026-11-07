<#
  '표시하기' 창만 따로 띄운다 (바탕화면 바로가기용). 구간 시작/끝, 증상 메모, 대시보드 열기.
    powershell -STA -File Show-Panel.ps1 [-DataDir <폴더>]
#>
param([string]$DataDir)
. (Join-Path $PSScriptRoot 'UI.ps1')
if (-not $DataDir) { $DataDir = Get-DefaultDataDir }
[Windows.Forms.Application]::EnableVisualStyles()
$p = New-MarkerPanel $DataDir $PSScriptRoot ([bool](Get-Settings).panel_topmost)
[Windows.Forms.Application]::Run($p.Form)
