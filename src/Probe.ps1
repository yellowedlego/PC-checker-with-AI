<#
  AI가 분석 중에 추가 자료를 요청할 때 쓰는 '확인 명령'. 읽기 전용이고, 결과는 개인정보를 가린 짧은 글(약 4KB 이내)이다.
  결과를 그대로 복사해 AI에게 붙여 넣으면 된다. 아무것도 자동으로 보내지 않고, PC 설정도 바꾸지 않는다.

    powershell -ExecutionPolicy Bypass -File .\src\Probe.ps1 list            # 요청 목록 보기
    powershell -ExecutionPolicy Bypass -File .\src\Probe.ps1 display         # R1  화면·해상도
    powershell -ExecutionPolicy Bypass -File .\src\Probe.ps1 events -Hours 6 # R5  최근 6시간 이벤트
    powershell -ExecutionPolicy Bypass -File .\src\Probe.ps1 memory -Copy    # 결과를 클립보드에도 복사

  이름: display gpu drivers startup events power disks memory processes network sensors boot
  마스킹: 계정·컴퓨터 이름, 사용자 폴더 경로, 이메일, IP, MAC 은 <USER>/<PC>/<IP>/<MAC> 등으로 바뀐다. 시리얼 번호·Wi-Fi 이름·파일 경로·명령줄·창 제목은 아예 읽지 않는다.
  네트워크: 외부 인터넷으로는 아무 것도 보내지 않는다 (network 은 공유기까지의 응답 시간만 잰다).
#>
param(
  [Parameter(Position = 0)][string]$Name = 'list',
  [int]$Hours = 24, [int]$Top = 10, [switch]$Copy
)
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'RequestCatalog.ps1')
$MaxBytes = 3800
$utf8 = New-Object Text.UTF8Encoding $false
function M([string]$t) { Protect-Text $t -PatternsOnly -NoIp }    # 이름·값 목록용(경로/이메일/MAC 형태만 가림. 드라이버 버전이 IP로 오인되지 않게 IP 규칙은 끔)
function Mx([string]$t) { Protect-Text $t }                        # 자유 텍스트용(계정·컴퓨터 이름까지 가림)
function Clip([string]$s, [int]$n) { if ($s.Length -gt $n) { $s.Substring(0, $n) + '…' } else { $s } }
function Fm($v, [string]$f = '0.#') { if ($null -eq $v -or "$v" -eq '') { '-' } else { ([double]$v).ToString($f, [Globalization.CultureInfo]::InvariantCulture) } }

# ---------------- 확인 명령들 ----------------
function Probe-Display {
  $mon = @(Get-CimInstance -Namespace root/wmi WmiMonitorID | ForEach-Object { [Text.Encoding]::ASCII.GetString(($_.UserFriendlyName | Where-Object { $_ -ne 0 })) })
  "- 모니터: $(if ($mon.Count) { $mon -join ', ' } else { '읽지 못함' })"
  foreach ($v in @(Get-CimInstance Win32_VideoController)) {
    $mode = $(if ($v.CurrentHorizontalResolution) { "$($v.CurrentHorizontalResolution)x$($v.CurrentVerticalResolution) @ $($v.CurrentRefreshRate)Hz" } else { '화면 출력 없음' })
    "- 그래픽 어댑터: $($v.Name) · $mode · 드라이버 $($v.DriverVersion) ($(if ($v.DriverDate) { $v.DriverDate.ToString('yyyy-MM-dd') } else { '?' }))"
  }
  $virt = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'Virtual|Remote|Indirect|Hub|Mirror|Dummy' } | ForEach-Object { $_.Name })
  "- 가상/원격 어댑터: $(if ($virt.Count) { $virt -join ', ' } else { '없음' })"
  "- 배율 DPI: $((Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics').AppliedDPI) (96=100%, 120=125%, 144=150%)"
  $hw = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers').HwSchMode
  "- 하드웨어 가속 GPU 스케줄링: $(switch ($hw) { 2 { '켜짐' } 1 { '꺼짐' } default { '기본/알 수 없음' } })"
  "- 게임 모드: $(if ((Get-ItemProperty 'HKCU:\Software\Microsoft\GameBar').AutoGameModeEnabled -eq 0) { '꺼짐' } else { '켜짐/기본' }) · 게임 녹화(DVR): $(if ((Get-ItemProperty 'HKCU:\System\GameConfigStore').GameDVR_Enabled -eq 1) { '켜짐' } else { '꺼짐/기본' })"
}
function Probe-Gpu {
  $smi = (Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source
  if ($smi) {
    $q = @(& $smi --query-gpu=name,driver_version,temperature.gpu,fan.speed,power.draw,clocks.sm,clocks.max.sm,clocks.mem,clocks.max.mem,pstate,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,utilization.gpu,memory.used,memory.total,clocks_throttle_reasons.active --format=csv,noheader,nounits)
    foreach ($line in $q) {
      $f = @($line -split ',\s*'); if ($f.Count -lt 18) { continue }
      "- $($f[0]) · 드라이버 $($f[1])"
      $na = { param($v, $u) if ("$v" -match 'N/A|Not Supported') { '알 수 없음' } else { "$v$u" } }
      "- 온도 $(& $na $f[2] '°C') · 팬 $(& $na $f[3] '%') · 전력 $(& $na $f[4] 'W') · 사용률 $(& $na $f[14] '%') · 메모리 $($f[15])/$($f[16])MB"
      "- 코어 클럭 $($f[5])/$($f[6])MHz · 메모리 클럭 $($f[7])/$($f[8])MHz · 성능 상태 $($f[9])"
      "- PCIe $($f[10])/$($f[11])세대 × $($f[12])/$($f[13])레인 (현재/최대. 유휴 때는 낮아질 수 있음)"
      "- 성능 제한 사유: $(ConvertFrom-ThrottleMask $f[17])"
    }
  } else { '- NVIDIA 도구(nvidia-smi)가 없어 온도·팬은 읽지 못했어요. Windows가 아는 정보만 보여드려요.' }
  foreach ($v in @(Get-CimInstance Win32_VideoController)) { "- (Windows) $($v.Name) · 드라이버 $($v.DriverVersion) · 상태 $($v.Status)" }
}
function Probe-Drivers {
  $codes = @{ 10 = '시작할 수 없음'; 22 = '사용 안 함'; 28 = '드라이버 없음'; 31 = '정상 작동 안 함'; 37 = '드라이버 초기화 실패'; 39 = '드라이버 손상/없음'; 43 = '장치가 문제를 보고함'; 45 = '연결 안 됨' }
  $bad = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
  "- 문제가 보고된 장치: $($bad.Count)개"
  foreach ($b in ($bad | Select-Object -First 8)) { "  - $(M $b.Name) · 코드 $($b.ConfigManagerErrorCode) ($(if ($codes[[int]$b.ConfigManagerErrorCode]) { $codes[[int]$b.ConfigManagerErrorCode] } else { '의미는 Microsoft 문서 참고' }))" }
  "- 주요 드라이버 (이름 · 버전 · 날짜):"
  foreach ($d in (Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceClass -in 'DISPLAY', 'NET', 'MEDIA', 'SYSTEM' -and $_.DeviceName -and $_.DriverVersion } | Sort-Object DeviceClass, DeviceName -Unique | Select-Object -First 14)) {
    "  - [$($d.DeviceClass)] $(M $d.DeviceName) · $($d.DriverVersion) · $(if ($d.DriverDate) { ([datetime]$d.DriverDate).ToString('yyyy-MM-dd') } else { '?' })"
  }
}
function Probe-Startup {
  $s = @(Get-CimInstance Win32_StartupCommand | ForEach-Object { M $_.Name } | Sort-Object -Unique)
  "- 시작 프로그램 $($s.Count)개 (이름만):"
  if ($s.Count) { "  " + ((Clip ($s -join ', ') 1200)) }
  $svc = @(Get-CimInstance Win32_Service | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' })
  "- 자동 시작인데 멈춰 있는 서비스 $($svc.Count)개 (정상일 수도 있음: 필요할 때만 켜지는 서비스):"
  foreach ($x in ($svc | Select-Object -First 12)) { "  - $(M $x.DisplayName)" }
}
function Probe-Events {
  $since = (Get-Date).AddHours(-$Hours)
  $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System', 'Application'; Level = 1, 2, 3; StartTime = $since } -MaxEvents 3000)
  "- 최근 ${Hours}시간 경고·오류: $($ev.Count)건 (상위 15개 종류)"
  foreach ($g in ($ev | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 15)) {
    $f = $g.Group[0]; $msg = ($f.Message -split "`r?`n")[0]; $last = ($g.Group | ForEach-Object { $_.TimeCreated } | Sort-Object | Select-Object -Last 1).ToString('MM-dd HH:mm')
    "  - $($f.ProviderName) #$($f.Id) ×$($g.Count) (마지막 $last) $(Clip (Mx $msg) 110)"
  }
}
function Probe-Power {
  $plan = (powercfg /getactivescheme) -join ' '
  $planName = '읽지 못함'; if ($plan -match '\(([^)]+)\)') { $planName = $Matches[1] }
  "- 활성 전원 계획: $planName"
  $pw = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
  "- 빠른 시작(Fast Startup): $(if ($pw.HiberbootEnabled -eq 1) { '켜짐 (종료 후 켜기는 완전한 초기화가 아님. 재시작은 영향 없음)' } else { '꺼짐' }) · 최대 절전: $(if ($pw.HibernateEnabled -eq 1) { '켜짐' } else { '꺼짐/알 수 없음' })"
  $b = Get-CimInstance Win32_Battery | Select-Object -First 1
  "- 배터리: $(if ($b) { "있음, 충전 $($b.EstimatedChargeRemaining)%" } else { '없음 (데스크톱일 가능성)' })"
}
function Probe-Disks {
  foreach ($d in @(Get-PhysicalDisk)) { "- 디스크: $($d.FriendlyName) · $($d.MediaType) · $($d.BusType) · $([math]::Round($d.Size / 1GB))GB · 상태 $($d.HealthStatus)/$($d.OperationalStatus)" }
  foreach ($v in @(Get-Volume | Where-Object { $_.DriveLetter })) { "- 드라이브 $($v.DriveLetter): $($v.FileSystem) · 전체 $([math]::Round($v.Size / 1GB))GB · 여유 $([math]::Round($v.SizeRemaining / 1GB))GB ($(if ($v.Size) { [math]::Round(100 * $v.SizeRemaining / $v.Size) } else { '?' })%)" }
  '- (SMART 마모·오류 카운터는 관리자 권한이 필요해 읽지 않았어요)'
}
function Probe-Memory {
  $os = Get-CimInstance Win32_OperatingSystem; $pm = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
  "- 전체 $([math]::Round($os.TotalVisibleMemorySize / 1MB, 1))GB · 남음 $([math]::Round($os.FreePhysicalMemory / 1MB, 1))GB · 커밋 비율 $(Fm $pm.PercentCommittedBytesInUse)%"
  foreach ($pf in @(Get-CimInstance Win32_PageFileUsage)) { "- 페이지 파일: 할당 $($pf.AllocatedBaseSize)MB · 최대 사용 $($pf.PeakUsage)MB" }
  "- 메모리를 많이 쓰는 프로그램 (같은 이름은 합산, 상위 ${Top}개):"
  foreach ($g in (Get-Process | Group-Object ProcessName | ForEach-Object { [pscustomobject]@{ Name = $_.Name; MB = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB); N = $_.Count } } | Sort-Object MB -Descending | Select-Object -First $Top)) { "  - $(M $g.Name) · $($g.MB)MB ($($g.N)개)" }
}
function Probe-Processes {
  $rows = @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | Where-Object { $_.Name -notin '_Total', 'Idle' })
  # 같은 이름의 프로세스(chrome 여러 개 등)는 이름별로 합산한다
  $byName = @($rows | Group-Object { $_.Name -replace '#\d+$', '' } | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Cpu = [int](($_.Group | Measure-Object PercentProcessorTime -Sum).Sum); MB = [math]::Round((($_.Group | Measure-Object WorkingSetPrivate -Sum).Sum) / 1MB); Count = $_.Count } })
  "- CPU 상위 ${Top}개 (이름별 합산, 100 = 코어 1개 가득):"
  foreach ($r in ($byName | Sort-Object Cpu -Descending | Select-Object -First $Top)) { "  - $(M $r.Name) · $($r.Cpu)% ($($r.Count)개)" }
  "- 메모리 상위 ${Top}개 (이름별 합산):"
  foreach ($r in ($byName | Sort-Object MB -Descending | Select-Object -First $Top)) { "  - $(M $r.Name) · $($r.MB)MB ($($r.Count)개)" }
  "- 프로세스 총 $($rows.Count)개"
}
function Probe-Network {
  foreach ($a in @(Get-NetAdapter | Where-Object Status -eq 'Up')) { "- 연결됨: $(M $a.InterfaceDescription) · $($a.LinkSpeed) · $(if ($a.PhysicalMediaType -match '802.11|Native') { '무선' } else { '유선/기타' })" }
  $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop
  if ($gw) {
    $p = @(Test-Connection -ComputerName $gw -Count 10 -ErrorAction SilentlyContinue)
    $lat = ($p | Measure-Object ResponseTime -Average -Maximum)
    "- 공유기(게이트웨이)까지 10번 확인: 응답 $($p.Count)/10 · 평균 $(Fm $lat.Average)ms · 최대 $(Fm $lat.Maximum)ms (IP는 가림, 외부 인터넷으로는 보내지 않음)"
  } else { '- 기본 게이트웨이를 찾지 못했어요 (연결 없음일 수 있음)' }
}
function Probe-Sensors {
  $s = $null; foreach ($ns in 'root/LibreHardwareMonitor', 'root/OpenHardwareMonitor') { $s = @(Get-CimInstance -Namespace $ns -ClassName Sensor); if ($s.Count) { "- 센서 프로그램 감지: $ns"; break } }
  if ($s.Count) {
    foreach ($x in ($s | Where-Object { $_.SensorType -in 'Temperature', 'Fan', 'Control' -and $null -ne $_.Value } | Sort-Object SensorType, Name | Select-Object -First 30)) { "  - $($x.SensorType) · $(M $x.Name) · $(Fm $x.Value)" }
  } else {
    '- 센서 프로그램(LibreHardwareMonitor/OpenHardwareMonitor)이 켜져 있지 않아요. CPU 온도와 케이스 팬 값은 Windows 기본 기능으로는 읽을 수 없습니다.'
    '- 켜는 방법: 무료 프로그램을 실행해 두고(이 도구에는 포함되어 있지 않아요) 같은 명령을 다시 실행해 값이 나오는지 확인하세요.'
  }
}
function Probe-Boot {
  $os = Get-CimInstance Win32_OperatingSystem
  "- 마지막 부팅: $($os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm')) · 켜져 있던 시간 $([math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1))일"
  $meaning = @{ 41 = '비정상 종료 뒤 재시작 (전원 끊김·블루스크린·강제 종료 가능)'; 6008 = '이전 종료가 예기치 않았음'; 1074 = '정상적인 종료/재시작 요청' }
  $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 6008, 1074; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 40)
  "- 최근 30일 부팅·종료 관련 이벤트 $($ev.Count)건:"
  foreach ($e in ($ev | Select-Object -First 15)) { "  - $($e.TimeCreated.ToString('MM-dd HH:mm')) · #$($e.Id) $($meaning[[int]$e.Id])" }
}
function Probe-List {
  '- 아래 이름을 `powershell -ExecutionPolicy Bypass -File .\src\Probe.ps1 <이름>` 으로 실행해요.'
  foreach ($r in ($script:AiRequests | Where-Object { $_.kind -eq 'probe' })) { "- $($r.id) $($r.name) — $($r.title): $($r.when)" }
  '- S1~S4 는 증상을 재현하거나 표시하는 순서예요 (Mark.ps1 / Make-Report.ps1). 자세한 순서는 대시보드의 "AI에게 더 줄 자료" 또는 summary.json 의 data_requests 에 있어요.'
}

# ---------------- 실행 ----------------
$map = @{ display = 'Probe-Display'; gpu = 'Probe-Gpu'; drivers = 'Probe-Drivers'; startup = 'Probe-Startup'; events = 'Probe-Events'; power = 'Probe-Power'; disks = 'Probe-Disks'; memory = 'Probe-Memory'; processes = 'Probe-Processes'; network = 'Probe-Network'; sensors = 'Probe-Sensors'; boot = 'Probe-Boot'; list = 'Probe-List' }
$key = $Name.ToLower().Trim()
if ($key -notin $map.Keys) { Write-Host "알 수 없는 이름입니다: '$Name'. 사용할 수 있는 이름: $(($map.Keys | Where-Object { $_ -ne 'list' } | Sort-Object) -join ', ') (목록: list)"; exit 2 }
$id = ($script:AiRequests | Where-Object { $_.name -eq $key } | Select-Object -First 1).id
$body = @(& $map[$key] | ForEach-Object { M ([string]$_) } | Where-Object { $null -ne $_ })
$head = "## 확인 결과 $(if ($id) { $id + ' ' })$key — $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"
$foot = '(읽기 전용 확인 명령 결과이며 개인정보는 가렸어요. 이 글을 그대로 AI에게 붙여 넣으세요.)'
$truncated = $false
while ($utf8.GetByteCount(($head, ($body -join "`n"), $foot -join "`n")) -gt $MaxBytes -and $body.Count -gt 3) { $body = $body[0..($body.Count - 2)]; $truncated = $true }
if ($truncated) { $body += '…(길어서 일부만 보여줘요. -Top / -Hours 로 범위를 줄여 다시 실행할 수 있어요)' }
$text = ($head, ($body -join "`n"), $foot) -join "`n"
Write-Output $text
if ($Copy) { try { Set-Clipboard -Value $text; Write-Host '(클립보드에 복사했어요)' -ForegroundColor Green } catch { Write-Host '(클립보드 복사는 실패했어요. 위 글을 직접 선택해 복사하세요)' -ForegroundColor Yellow } }
