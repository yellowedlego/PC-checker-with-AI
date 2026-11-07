<#
  한 번에 리포트 만들기: 내보내기 -> 대시보드 -> (선택) 가벼운 AI용 팩. 트레이 메뉴와 '표시하기' 창이 이 스크립트를 부른다.
    powershell -ExecutionPolicy Bypass -File .\src\Make-Report.ps1 [-Pack full|light] [-Open dashboard|folder|none]
  진행 상태는 <데이터 폴더>\report-status.json 에 남는다. 읽기 전용(설정 변경 없음), 네트워크 전송 없음.
#>
param(
  [string]$DataDir,
  [ValidateSet('full', 'light')][string]$Pack = 'full',
  [ValidateSet('dashboard', 'folder', 'none')][string]$Open = 'dashboard'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $DataDir) { $DataDir = Get-DefaultDataDir }
$statusFile = Join-Path $DataDir 'report-status.json'
function Set-Status([string]$State, [string]$Message, [string]$Path = '') { try { Write-JsonFile $statusFile ([ordered]@{ state = $State; message = $Message; path = $Path; at = (Get-Date).ToString('s') }) } catch { } }
try {
  Set-Status 'working' '기록을 파일로 내보내는 중…'
  & (Join-Path $PSScriptRoot 'Export-Data.ps1') -DataDir $DataDir | Out-Null
  $exp = Get-ChildItem (Join-Path $DataDir 'export') -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  Set-Status 'working' '대시보드를 만드는 중…'
  $dash = & (Join-Path $PSScriptRoot 'Build-Dashboard.ps1') -DataDir $DataDir -ExportDir $exp.FullName | Select-Object -Last 1
  $target = $exp.FullName
  if ($Pack -eq 'light') {
    Set-Status 'working' 'AI용 가벼운 팩을 만드는 중…'
    $target = & (Join-Path $PSScriptRoot 'Build-LightPack.ps1') -DataDir $DataDir -ExportDir $exp.FullName | Select-Object -Last 1
  }
  Set-Status 'done' '완료' $target
  if ($Open -eq 'dashboard' -and $dash -and (Test-Path $dash)) { Start-Process $dash }
  elseif ($Open -eq 'folder') { Start-Process explorer.exe -ArgumentList ('"' + $target + '"') }
  Write-Host "[report] 완료: $target"
} catch {
  Set-Status 'error' $_.Exception.Message
  Write-Error $_
  exit 1
}
