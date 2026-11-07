<#
  PC-checker-with-AI 수집 엔진 (1단계)
  - 부팅 시점부터 부품별 지표를 기록한다. 읽기 전용, 설정 변경 없음, 네트워크 전송 없음.
  - 실행:  powershell -ExecutionPolicy Bypass -File .\src\Start-Collector.ps1
  - 중지:  Ctrl+C  또는  데이터 폴더에 stop.flag 파일 생성
  - 구간/메모 마커:  .\src\Mark.ps1 start|end|note "라벨"

  측정 계획(부팅 후 경과 시간 기준)
    0~5분   boot_settle : 촘촘히(기본 2초 목표)
    5~30분  baseline    : 기준선(5초)  - 이 시간엔 PC를 평소처럼 두기
    30분~   normal      : 5초
    구간 마커 열림 / 메모 후 5분 : 촘촘히
  * CIM 성능 클래스를 한 번 읽는 데 약 1.5초가 걸려서 '촘촘히'의 실제 간격은 2~3초다.

  저장 구조 (-DataDir 아래)
    boot_<부팅시각>\meta.json            하드웨어 모델/수집 설정 (컴퓨터 이름·시리얼 없음)
    boot_<부팅시각>\raw_<날짜>_<시>.jsonl  틱 원본 (기본 24시간 보관)
    boot_<부팅시각>\minute.jsonl          1분 평균/최대/상위5% (기본 30일 보관)
    boot_<부팅시각>\processes.jsonl       프로세스 이름/시작·종료/최대 사용량 (경로·인자·창 제목 없음)
    boot_<부팅시각>\markers.jsonl         구간/메모 마커
    state.json                            수집기 상태(heartbeat)
#>
param(
  [string]$DataDir,
  [int]$DenseSec = 2,
  [int]$NormalSec = 5,
  [int]$MaxMinutes = 0,        # 테스트용. 0 = 중지할 때까지
  [int]$RawKeepHours = 24,
  [int]$MinuteKeepDays = 30
)
$ErrorActionPreference = 'SilentlyContinue'
$Version = '0.1.0'
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $DataDir) { $DataDir = Get-DefaultDataDir }
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null

# ---- 중복 실행 방지 ----
$mutexName = 'Local\PCCheckerWithAI.' + ([regex]::Replace($DataDir.ToLower(), '[^a-z0-9]', ''))
$mutex = New-Object Threading.Mutex($false, $mutexName.Substring(0, [math]::Min(200, $mutexName.Length)))
if (-not $mutex.WaitOne(0)) { Write-Host '이미 수집기가 실행 중입니다.'; exit 0 }

# ---- 부팅/환경 ----
$os = Get-CimInstance Win32_OperatingSystem
$boot = $os.LastBootUpTime
$bootDir = Join-Path $DataDir ('boot_' + $boot.ToString('yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $bootDir -Force | Out-Null
$cpuInfo = Get-CimInstance Win32_Processor | Select-Object -First 1
$logicalCpu = [int](($cpuInfo | Measure-Object NumberOfLogicalProcessors -Sum).Sum)
if ($logicalCpu -lt 1) { $logicalCpu = 1 }
$smi = (Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---- 보관 기간 정리 (boot_* 폴더만, 안전하게) ----
Get-ChildItem $DataDir -Directory -Filter 'boot_*' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$MinuteKeepDays) } | Remove-Item -Recurse -Force
function Remove-OldRaw {
  Get-ChildItem $DataDir -Recurse -File -Filter 'raw_*.jsonl' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-$RawKeepHours) } | Remove-Item -Force
}
Remove-OldRaw

function Rn($v, [int]$d = 2) { [math]::Round([double]$v, $d) }
function Get-SafeKey([string]$s) { ([regex]::Replace($s.Trim(), '[^\w\-:]+', '_')).Trim('_') }

# ---- meta.json (하드웨어 모델명만. 컴퓨터 이름/시리얼/IP 없음) ----
$meta = [ordered]@{
  collector_version = $Version
  boot_time = $boot.ToString('s')
  collector_started = (Get-Date).ToString('s')
  os = [ordered]@{ caption = $os.Caption; build = $os.BuildNumber; arch = $os.OSArchitecture }
  cpu = [ordered]@{ name = $cpuInfo.Name.Trim(); logical = $logicalCpu; physical = [int](($cpuInfo | Measure-Object NumberOfCores -Sum).Sum) }
  ram_gb = Rn ((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB) 1
  gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object { [ordered]@{ name = $_.Name; driver = $_.DriverVersion } })
  plan = [ordered]@{ boot_settle_min = 5; baseline_min = 30; dense_sec = $DenseSec; normal_sec = $NormalSec; segment_max_min = 60; note_dense_min = 5 }
  retention = [ordered]@{ raw_hours = $RawKeepHours; minute_days = $MinuteKeepDays }
  nvidia_smi = [bool]$smi
  is_admin = $isAdmin
}
Write-JsonFile (Join-Path $bootDir 'meta.json') $meta

# ---- 상태 ----
$script:seg = $null            # 열린 구간 마커
$script:denseUntil = [datetime]::MinValue
$script:buf = New-Object Collections.Generic.List[object]
$script:bufKey = ''
$script:tracked = @{}
$script:vendor = @{}
$script:hwNs = $null; $script:hwSkip = 0
$script:src = [ordered]@{}
$script:ticks = 0
$script:lastBeat = [datetime]::MinValue
$script:lastClean = Get-Date

function Get-VendorInfo([int]$ProcId, [string]$Name) {
  if ($script:vendor.ContainsKey($Name)) { return $script:vendor[$Name] }
  $info = @{ company = $null; description = $null }
  if ($script:vendor.Count -lt 600) {
    try {
      $fvi = [Diagnostics.Process]::GetProcessById($ProcId).MainModule.FileVersionInfo
      $info.company = Protect-Text $fvi.CompanyName
      $info.description = Protect-Text $fvi.FileDescription
    } catch { }
  }
  $script:vendor[$Name] = $info
  $info
}

function Add-Marker($type, $label, $extra) {
  $o = [ordered]@{ t = (Get-Date).ToString('s'); type = $type; label = $label }
  if ($extra) { foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] } }
  Add-JsonLine (Join-Path $bootDir 'markers.jsonl') $o
}

function Read-Commands([datetime]$Now) {
  $cdir = Join-Path $DataDir 'cmd'
  if (-not (Test-Path $cdir)) { return }
  foreach ($f in (Get-ChildItem $cdir -Filter '*.json' | Sort-Object Name)) {
    $c = $null; try { $c = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    Remove-Item $f.FullName -Force
    if (-not $c) { continue }
    $label = Protect-Text ([string]$c.label)
    switch ($c.action) {
      'start' {
        if ($script:seg) { Add-Marker 'segment_end' $script:seg.label @{ duration_sec = [int]($Now - $script:seg.start).TotalSeconds; auto = $true; reason = 'new_segment' } }
        $script:seg = @{ label = $label; start = $Now }
        Add-Marker 'segment_start' $label $null
      }
      'end' {
        if ($script:seg) { Add-Marker 'segment_end' $script:seg.label @{ duration_sec = [int]($Now - $script:seg.start).TotalSeconds }; $script:seg = $null }
      }
      'note' {
        Add-Marker 'note' $label $null
        $script:denseUntil = $Now.AddMinutes(5)
      }
    }
  }
  if ($script:seg -and ($Now - $script:seg.start).TotalMinutes -ge 60) {
    Add-Marker 'segment_end' $script:seg.label @{ duration_sec = 3600; auto = $true; reason = 'max_60min' }
    $script:seg = $null
  }
}

function Get-Phase([datetime]$Now) {
  if ($script:seg) { return 'segment:' + $script:seg.label }
  $min = ($Now - $boot).TotalMinutes
  if ($min -lt 5) { return 'boot_settle' }
  if ($min -lt 30) { return 'baseline' }
  'normal'
}

function Get-IntervalSec([datetime]$Now) {
  if ($script:seg -or $Now -lt $script:denseUntil -or ($Now - $boot).TotalMinutes -lt 5) { return $DenseSec }
  $NormalSec
}

function Get-HwSensors {
  if ($script:hwSkip -gt 0) { $script:hwSkip--; return $null }
  $order = @('root/LibreHardwareMonitor', 'root/OpenHardwareMonitor')
  if ($script:hwNs) { $order = @($script:hwNs) }
  foreach ($ns in $order) {
    $s = Get-CimInstance -Namespace $ns -ClassName Sensor
    if ($s) { $script:hwNs = $ns; return $s }
  }
  $script:hwNs = $null; $script:hwSkip = 30
  $null
}

function Get-Tick([bool]$First) {
  $m = [ordered]@{}; $s = [ordered]@{}

  # CPU
  $cpu = @(Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation)
  $script:src.cpu = ($cpu.Count -gt 0)
  foreach ($c in $cpu) {
    if ($c.Name -eq '_Total') {
      $m['cpu.util'] = Rn $c.PercentProcessorUtility 1; $m['cpu.perf_pct'] = Rn $c.PercentProcessorPerformance 0
      $m['cpu.dpc'] = Rn $c.PercentDPCTime 2; $m['cpu.interrupt'] = Rn $c.PercentInterruptTime 2
    } elseif ($c.Name -match '^\d+,\d+$') {
      $m['cpu.core.' + ($c.Name -replace ',', '_')] = Rn $c.PercentProcessorUtility 0
    }
  }
  # 메모리
  $mem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
  $script:src.memory = [bool]$mem
  if ($mem) { $m['mem.avail_mb'] = Rn $mem.AvailableMBytes 0; $m['mem.commit_pct'] = Rn $mem.PercentCommittedBytesInUse 1; $m['mem.pages_per_sec'] = Rn $mem.PagesPersec 1 }
  # 디스크 (장치별)
  $disks = @(Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk | Where-Object { $_.Name -ne '_Total' })
  $script:src.disk = ($disks.Count -gt 0)
  foreach ($d in $disks) {
    $k = 'disk.' + (Get-SafeKey $d.Name)
    $m[$k + '.busy'] = Rn $d.PercentDiskTime 1; $m[$k + '.queue'] = Rn $d.AvgDiskQueueLength 2; $m[$k + '.latency_ms'] = Rn ([double]$d.AvgDisksecPerTransfer * 1000) 2
  }
  # 네트워크 (어댑터별 처리량만)
  $nics = @(Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface | Where-Object { $_.Name -notmatch 'isatap|Loopback|Teredo|Pseudo|6to4' })
  $script:src.network = ($nics.Count -gt 0)
  foreach ($n in $nics) { $m['net.' + (Get-SafeKey $n.Name) + '.kbps'] = Rn ([double]$n.BytesTotalPersec / 1024) 1 }
  # GPU (제조사 공통 카운터)
  $eng = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine)
  $script:src.gpu_counters = ($eng.Count -gt 0)
  $byType = @{}; $byPid = @{}
  foreach ($e in $eng) {
    if ($e.Name -match 'pid_(\d+)_.*engtype_(\w+)') {
      $p = [int]$Matches[1]; $t = $Matches[2]; $u = [double]$e.UtilizationPercentage
      if (-not $byType.ContainsKey($t)) { $byType[$t] = 0.0 }; $byType[$t] += $u
      if (-not $byPid.ContainsKey($p)) { $byPid[$p] = 0.0 }; $byPid[$p] += $u
    }
  }
  foreach ($t in ($byType.Keys | Sort-Object)) { $m['gpu.engine.' + (Get-SafeKey $t)] = Rn ([math]::Min(100, $byType[$t])) 1 }
  $gm = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory)
  if ($gm.Count -gt 0) {
    $m['gpu.vram_used_mb'] = Rn (($gm | Measure-Object DedicatedUsage -Sum).Sum / 1MB) 0
    $m['gpu.shared_used_mb'] = Rn (($gm | Measure-Object SharedUsage -Sum).Sum / 1MB) 0
  }
  # NVIDIA 보강 (온도/팬/클럭/스로틀)
  if ($smi) {
    $q = @(& $smi --query-gpu=temperature.gpu,utilization.gpu,utilization.memory,fan.speed,clocks.sm,clocks.mem,clocks.max.sm,pstate,clocks_throttle_reasons.active,utilization.encoder,utilization.decoder,power.draw,memory.used,memory.total --format=csv,noheader,nounits)
    $script:src.nvidia_smi = ($q.Count -gt 0)
    $i = 0
    foreach ($line in $q) {
      $f = @($line -split ',\s*')
      if ($f.Count -ge 14) {
        $names = 'temp_c', 'util', 'mem_util', 'fan_pct', 'sm_mhz', 'mem_mhz', 'max_sm_mhz'
        for ($j = 0; $j -lt 7; $j++) { $v = ConvertTo-Number $f[$j]; if ($null -ne $v) { $m["nv.gpu$i." + $names[$j]] = $v } }
        $s["nv.gpu$i.pstate"] = $f[7]; $s["nv.gpu$i.throttle"] = ConvertFrom-ThrottleMask $f[8]
        $names2 = 'enc_util', 'dec_util', 'power_w', 'vram_used_mb', 'vram_total_mb'
        for ($j = 0; $j -lt 5; $j++) { $v = ConvertTo-Number $f[9 + $j]; if ($null -ne $v) { $m["nv.gpu$i." + $names2[$j]] = $v } }
      }
      $i++
    }
  }
  # 센서 프로그램(LibreHardwareMonitor/OpenHardwareMonitor)이 켜져 있으면 온도/팬 RPM/팬 듀티
  $hw = Get-HwSensors
  $script:src.hw_sensors = [bool]$hw
  if ($hw) {
    $typeMap = @{ Temperature = 'temp_c'; Fan = 'fan_rpm'; Control = 'fan_duty_pct' }
    foreach ($sn in $hw) {
      if (-not $typeMap.ContainsKey([string]$sn.SensorType) -or $null -eq $sn.Value) { continue }
      $key = 'hw.' + $typeMap[[string]$sn.SensorType] + '.' + (Get-SafeKey $sn.Name); $n = 2; $base = $key
      while ($m.Contains($key)) { $key = "$base.$n"; $n++ }
      $m[$key] = Rn $sn.Value 1
    }
  }
  # 프로세스 (이름만) + 추적
  $pr = @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process)
  $script:src.processes = ($pr.Count -gt 0)
  $now = Get-Date
  Update-Procs $pr $now $First
  $real = @($pr | Where-Object { $_.Name -notin '_Total', 'Idle' })
  $m['proc.count'] = $real.Count
  $top = $real | Sort-Object PercentProcessorTime -Descending | Select-Object -First 1
  if ($top) { $s['proc.top_cpu'] = ($top.Name -replace '#\d+$', ''); $m['proc.top_cpu_core_pct'] = Rn $top.PercentProcessorTime 0 }
  if ($byPid.Count -gt 0) {
    $gp = $byPid.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    $gname = ($real | Where-Object { [int]$_.IDProcess -eq $gp.Key } | Select-Object -First 1).Name
    if ($gname -and $gp.Value -ge 1) { $s['proc.top_gpu'] = ($gname -replace '#\d+$', ''); $m['proc.top_gpu_pct'] = Rn ([math]::Min(100, $gp.Value)) 0 }
  }
  @{ m = $m; s = $s }
}

function Update-Procs($rows, [datetime]$Now, [bool]$First) {
  $seen = @{}
  foreach ($r in $rows) {
    if ($r.Name -in '_Total', 'Idle') { continue }
    $name = $r.Name -replace '#\d+$', ''
    $key = "$([int]$r.IDProcess)|$name"; $seen[$key] = $true
    $cpuP = [double]$r.PercentProcessorTime; $mb = [double]$r.WorkingSetPrivate / 1MB
    $t = $script:tracked[$key]
    if (-not $t) {
      $vi = Get-VendorInfo ([int]$r.IDProcess) $name
      $script:tracked[$key] = @{ name = $name; first = $Now; pre = $First; last = $Now; peak_cpu = $cpuP; peak_mb = $mb; company = $vi.company; description = $vi.description }
    } else {
      $t.last = $Now
      if ($cpuP -gt $t.peak_cpu) { $t.peak_cpu = $cpuP }
      if ($mb -gt $t.peak_mb) { $t.peak_mb = $mb }
    }
  }
  foreach ($key in @($script:tracked.Keys)) { if (-not $seen.ContainsKey($key)) { Write-ProcRecord $script:tracked[$key] $false; $script:tracked.Remove($key) } }
}

function Write-ProcRecord($t, [bool]$StillRunning) {
  $o = [ordered]@{
    name = $t.name; company = $t.company; description = $t.description
    first_seen = $(if ($t.pre) { $null } else { $t.first.ToString('s') })
    started_before_collector = [bool]$t.pre
    last_seen = $t.last.ToString('s'); still_running = $StillRunning
    peak_cpu_core_pct = Rn $t.peak_cpu 0; peak_ram_mb = Rn $t.peak_mb 0
  }
  Add-JsonLine (Join-Path $bootDir 'processes.jsonl') $o
}

function Write-MinuteRecord {
  if ($script:buf.Count -eq 0) { return }
  $vals = @{}; $strs = @{}
  foreach ($t in $script:buf) {
    foreach ($k in $t.m.Keys) { if (-not $vals.ContainsKey($k)) { $vals[$k] = New-Object Collections.Generic.List[double] }; $vals[$k].Add([double]$t.m[$k]) }
    foreach ($k in $t.s.Keys) { if (-not $strs.ContainsKey($k)) { $strs[$k] = New-Object Collections.Generic.List[string] }; $strs[$k].Add([string]$t.s[$k]) }
  }
  $mm = [ordered]@{}
  foreach ($k in ($vals.Keys | Sort-Object)) {
    $a = $vals[$k].ToArray(); [Array]::Sort($a)
    $sum = 0.0; foreach ($x in $a) { $sum += $x }
    $mm[$k] = @((Rn ($sum / $a.Count) 2), $a[-1], (Get-Percentile $a 0.95))
  }
  $ss = [ordered]@{}
  foreach ($k in ($strs.Keys | Sort-Object)) { $ss[$k] = ($strs[$k] | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name }
  Add-JsonLine (Join-Path $bootDir 'minute.jsonl') ([ordered]@{ t = $script:bufKey; n = $script:buf.Count; phase = $script:buf[$script:buf.Count - 1].ph; m = $mm; s = $ss })
  $script:buf.Clear()
}

function Write-Heartbeat([datetime]$Now, [string]$Phase, [int]$Interval, [int]$TickMs) {
  Write-JsonFile (Join-Path $DataDir 'state.json') ([ordered]@{
      updated = $Now.ToString('s'); collector_version = $Version; boot_time = $boot.ToString('s'); phase = $Phase
      target_interval_sec = $Interval; last_tick_ms = $TickMs; ticks = $script:ticks
      open_segment = $(if ($script:seg) { $script:seg.label } else { $null }); sources = $script:src })
}

# ---- 메인 루프 ----
Write-Host ("[PC-checker] 수집 시작  부팅 {0}  저장 위치: {1}" -f $boot.ToString('s'), $bootDir) -ForegroundColor Cyan
Write-Host '  중지: Ctrl+C 또는 stop.flag 파일 생성.  구간 마커: src\Mark.ps1 start|end|note "라벨"'
$stopAt = $(if ($MaxMinutes -gt 0) { (Get-Date).AddMinutes($MaxMinutes) } else { [datetime]::MaxValue })
$first = $true
try {
  while ((Get-Date) -lt $stopAt) {
    $t0 = Get-Date
    if (Test-Path (Join-Path $DataDir 'stop.flag')) { Remove-Item (Join-Path $DataDir 'stop.flag') -Force; break }
    Read-Commands $t0
    $phase = Get-Phase $t0
    $interval = Get-IntervalSec $t0
    $tick = Get-Tick $first
    $first = $false
    $script:ticks++
    $rec = [ordered]@{ t = $t0.ToString('s'); ph = $phase; m = $tick.m; s = $tick.s }
    Add-JsonLine (Join-Path $bootDir ('raw_' + $t0.ToString('yyyyMMdd_HH') + '.jsonl')) $rec
    $key = $t0.ToString('yyyy-MM-ddTHH:mm')
    if ($script:bufKey -ne $key) { Write-MinuteRecord; $script:bufKey = $key }
    $script:buf.Add(@{ m = $tick.m; s = $tick.s; ph = $phase })
    $tickMs = [int]((Get-Date) - $t0).TotalMilliseconds
    if (((Get-Date) - $script:lastBeat).TotalSeconds -ge 15) { Write-Heartbeat (Get-Date) $phase $interval $tickMs; $script:lastBeat = Get-Date }
    if (((Get-Date) - $script:lastClean).TotalHours -ge 1) { Remove-OldRaw; $script:lastClean = Get-Date }
    $wait = $interval * 1000 - $tickMs
    if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
  }
} finally {
  Write-MinuteRecord
  foreach ($key in @($script:tracked.Keys)) { Write-ProcRecord $script:tracked[$key] $true }
  if ($script:seg) { Add-Marker 'segment_end' $script:seg.label @{ auto = $true; reason = 'collector_stopped' } }
  Write-Heartbeat (Get-Date) 'stopped' 0 0
  $mutex.ReleaseMutex() | Out-Null
  Write-Host '[PC-checker] 수집 종료'
}
