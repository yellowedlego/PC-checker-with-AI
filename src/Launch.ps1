<#
  로그온 시 실행되는 진입점. 수집기와 트레이 아이콘을 각각 숨김 창으로 띄운다. 이미 떠 있으면 각 스크립트의 중복 실행 방지가 알아서 종료시킨다.
  관리자 권한이 필요 없다.
    powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File Launch.ps1 [-DataDir <폴더>]
#>
param([string]$DataDir, [switch]$NoTray)
$src = $PSScriptRoot
$common = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass')
# Start-Process 는 공백이 든 경로를 자동으로 따옴표로 감싸 주지 않으므로 직접 감싼다
function Q([string]$s) { '"' + $s + '"' }
$collectorArgs = $common + @('-File', (Q (Join-Path $src 'Start-Collector.ps1')))
$trayArgs = $common + @('-STA', '-File', (Q (Join-Path $src 'Start-Tray.ps1')))
if ($DataDir) { $collectorArgs += @('-DataDir', (Q $DataDir)); $trayArgs += @('-DataDir', (Q $DataDir)) }
Start-Process -FilePath 'powershell.exe' -ArgumentList $collectorArgs -WindowStyle Hidden
if (-not $NoTray) { Start-Process -FilePath 'powershell.exe' -ArgumentList $trayArgs -WindowStyle Hidden }
