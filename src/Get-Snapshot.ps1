# 시스템 스냅샷: 부팅 이후 이벤트, 디스플레이 설정, 장치 문제 등 '지금 상태' (읽기 전용)
# 모든 자유 텍스트(이벤트 메시지 등)는 Protect-Text 를 거친다. 계정/경로/IP/MAC/시리얼은 수집하지 않는다.
. (Join-Path $PSScriptRoot 'Common.ps1')

function Get-Snapshot([datetime]$Boot) {
  $ErrorActionPreference = 'SilentlyContinue'
  $snap = [ordered]@{}
  $notes = New-Object Collections.Generic.List[string]

  # ---- 디스플레이 ----
  $mon = @(Get-CimInstance -Namespace root/wmi WmiMonitorID | ForEach-Object {
      $n = [Text.Encoding]::ASCII.GetString(($_.UserFriendlyName | Where-Object { $_ -ne 0 })); [ordered]@{ model = $n } })
  $ctrl = @(Get-CimInstance Win32_VideoController | ForEach-Object {
      [ordered]@{ adapter = $_.Name; driver_version = $_.DriverVersion; driver_date = $(if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { $null })
        width = $_.CurrentHorizontalResolution; height = $_.CurrentVerticalResolution; refresh_hz = $_.CurrentRefreshRate; status = $_.Status } })
  $virt = @($ctrl | Where-Object { $_.adapter -match 'Virtual|Remote|Indirect|Hub|Mirror|Dummy' } | ForEach-Object { $_.adapter })
  $gfx = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
  $snap.display = [ordered]@{
    monitors = $mon; adapters = $ctrl; virtual_or_remote_adapters = $virt
    dpi_applied = (Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics').AppliedDPI
    hardware_gpu_scheduling = $gfx.HwSchMode
    game_mode = (Get-ItemProperty 'HKCU:\Software\Microsoft\GameBar').AutoGameModeEnabled
    game_dvr_capture = (Get-ItemProperty 'HKCU:\System\GameConfigStore').GameDVR_Enabled
  }

  # ---- 전원/메모리 설정 ----
  $plan = (powercfg /getactivescheme) -join ' '
  $snap.power = [ordered]@{
    active_plan = $(if ($plan -match '\(([^)]+)\)') { $Matches[1] } else { $null })
    fast_startup = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power').HiberbootEnabled
  }
  $snap.pagefile = @(Get-CimInstance Win32_PageFileUsage | ForEach-Object { [ordered]@{ allocated_mb = $_.AllocatedBaseSize; peak_mb = $_.PeakUsage } })

  # ---- 저장장치 상태 (SMART 상세는 관리자 권한 필요) ----
  $snap.physical_disks = @(Get-PhysicalDisk | ForEach-Object {
      [ordered]@{ model = $_.FriendlyName; media = "$($_.MediaType)"; bus = "$($_.BusType)"; size_gb = [math]::Round($_.Size / 1GB, 0); health = "$($_.HealthStatus)"; operational = "$($_.OperationalStatus)" } })
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) { $notes.Add('디스크 마모/오류 카운터(SMART)는 관리자 권한이 필요해서 수집하지 않았습니다.') }

  # ---- 문제가 있는 장치 ----
  $codeMeaning = @{ 10 = '장치를 시작할 수 없음'; 22 = '사용 안 함(비활성화됨)'; 28 = '드라이버가 설치되지 않음'; 31 = '장치가 제대로 작동하지 않음'; 37 = '드라이버 초기화 실패'; 39 = '드라이버가 손상되었거나 없음'; 43 = '장치가 문제를 보고해 중지됨'; 45 = '장치가 현재 연결되어 있지 않음' }
  $snap.devices_with_problems = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 } | ForEach-Object {
      $mean = $codeMeaning[[int]$_.ConfigManagerErrorCode]
      [ordered]@{ device = (Protect-Text $_.Name); error_code = $_.ConfigManagerErrorCode; meaning = $(if ($mean) { $mean } else { '코드 의미는 Microsoft 문서 참고' }); class = $_.PNPClass } })

  # ---- 부팅 이후 이벤트 (경고/오류/치명) ----
  function Group-Events($log) {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = $log; Level = 1, 2, 3; StartTime = $Boot } -MaxEvents 5000)
    [ordered]@{
      total = $ev.Count
      groups = @($ev | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
          $f = $_.Group[0]; $msg = ($f.Message -split "`r?`n")[0]; if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) }
          $times = @($_.Group | ForEach-Object { $_.TimeCreated } | Sort-Object)
          [ordered]@{ provider = $f.ProviderName; event_id = $f.Id; level = $f.LevelDisplayName; occurrences = $_.Count
            first = $times[0].ToString('s'); last = $times[-1].ToString('s'); sample = (Protect-Text $msg) } })
    }
  }
  $sys = Group-Events 'System'
  $app = Group-Events 'Application'
  $snap.events_since_boot = [ordered]@{ boot_time = $Boot.ToString('s'); system = $sys; application = $app }
  $dispPattern = 'nvlddmkm|^Display$|dxgkrnl|igfx|amdkmdag|amdwddmg|LiveKernelEvent'
  $snap.display_driver_events = @($sys.groups | Where-Object { $_.provider -match $dispPattern })
  $snap.reboot_related = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 1001, 6008; StartTime = $Boot.AddMinutes(-1) } -MaxEvents 20 | ForEach-Object {
      [ordered]@{ time = $_.TimeCreated.ToString('s'); provider = $_.ProviderName; event_id = $_.Id; level = $_.LevelDisplayName } })
  $notes.Add('Kernel-Power 41 등은 "이전 종료가 비정상이었다"는 기록이 이번 부팅 직후에 남는 것입니다. 이번 부팅 중의 문제가 아닐 수 있습니다.')

  $snap.minidumps = @(Get-ChildItem 'C:\Windows\Minidump' -Filter *.dmp | Sort-Object LastWriteTime -Descending | Select-Object -First 5 | ForEach-Object { [ordered]@{ time = $_.LastWriteTime.ToString('s') } })
  $snap.notes = $notes.ToArray()
  $snap
}
