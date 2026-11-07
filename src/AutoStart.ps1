# 자동 실행 설치/제거에 쓰는 공용 함수. 이 파일은 불러오기만 하고 아무것도 바꾸지 않는다.
. (Join-Path $PSScriptRoot 'Common.ps1')
$script:AutoTaskName = 'PCCheckerWithAI-Logon'
$script:AppFolderName = 'PCCheckerWithAI'

# Root 는 설치 위치(기본 %LOCALAPPDATA%\PCCheckerWithAI). 이름이 PCCheckerWithAI 가 아니면 거부한다 (엉뚱한 폴더 삭제 방지)
function Get-AutoPaths([string]$Root) {
  if (-not $Root) { $Root = Get-AppRoot }
  $Root = [IO.Path]::GetFullPath($Root)
  if ((Split-Path $Root -Leaf) -ne $script:AppFolderName) { throw "설치 위치의 폴더 이름은 '$($script:AppFolderName)' 이어야 합니다: $Root" }
  [ordered]@{
    Root = $Root; App = (Join-Path $Root 'app'); Src = (Join-Path $Root 'app\src'); Data = (Join-Path $Root 'data')
    Launch = (Join-Path $Root 'app\src\Launch.ps1'); Panel = (Join-Path $Root 'app\src\Show-Panel.ps1'); Info = (Join-Path $Root 'install.json'); Settings = (Join-Path $Root 'settings.json')
    StartupLink = (Join-Path ([Environment]::GetFolderPath('Startup')) 'PC-checker-with-AI.lnk')
    DesktopLink = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'PC 상태 기록 - 표시하기.lnk')
  }
}

# 작업 스케줄러 정의만 만든다 (등록하지 않는다). 현재 사용자 권한(관리자 아님), 로그온 시, 숨김, 시간 제한 없음.
function New-AutoStartTask([string]$LaunchScript, [int]$DelaySeconds = 30) {
  $user = "$env:USERDOMAIN\$env:USERNAME"
  $arg = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $LaunchScript
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
  $trigger.Delay = ('PT{0}S' -f $DelaySeconds)   # 로그온 직후 바탕화면이 자리 잡을 때까지 잠깐 기다림
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Hidden
  $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'PC-checker-with-AI: 로그온 시 PC 상태 기록 시작 (로컬 전용, 관리자 권한 없음). 제거: Uninstall-AutoStart.ps1'
}

function New-Shortcut([string]$LinkPath, [string]$Target, [string]$Arguments, [int]$WindowStyle = 7, [string]$Description = '') {
  $sh = New-Object -ComObject WScript.Shell; $l = $sh.CreateShortcut($LinkPath)
  $l.TargetPath = $Target; $l.Arguments = $Arguments; $l.WindowStyle = $WindowStyle; $l.Description = $Description; $l.Save()
  [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh)
}

function Copy-AppFiles([string]$From, [string]$AppDir) {
  $dest = Join-Path $AppDir 'src'
  if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
  New-Item -ItemType Directory -Path $dest -Force | Out-Null
  Copy-Item -Path (Join-Path $From '*') -Destination $dest -Recurse -Force
  (Get-ChildItem $dest -Recurse -File | Measure-Object).Count
}

# 설치된 앱 경로로 실행 중인 우리 프로세스 (수집기/트레이)
function Get-OurProcesses([string]$SrcDir) {
  $pat = [regex]::Escape($SrcDir)
  @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match $pat -and $_.ProcessId -ne $PID })
}
