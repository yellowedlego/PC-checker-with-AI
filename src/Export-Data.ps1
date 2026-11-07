<#
  PC-checker-with-AI 데이터 내보내기 (2단계)
  수집된 1분 요약(minute.jsonl)을 AI/사람이 읽기 쉬운 파일로 만든다. 읽기 전용, 네트워크 전송 없음.

    powershell -ExecutionPolicy Bypass -File .\src\Export-Data.ps1
    옵션:  -DataDir <폴더>  -BootDir <boot_...>(기본: 가장 최근)  -OutDir <폴더>  -Hours 72(분석할 최근 시간, 0=전부)  -NoSnapshot

  출력(OutDir):
    metrics_1min.csv   분 단위 와이드 표 (평균 + 일부 __max). 팬은 개별 열 옆에 통합 열(fan_group.*)
    processes.csv      프로세스 이름별 요약 (경로/인자/창 제목 없음)
    summary.json       서술 지표(기울기·치우침·튀는 순간·식는 속도), 구간 비교, 시스템 스냅샷, 원인 후보 체크리스트
    schema.md          열 이름·단위·설명·임시 기준 설명

  원칙: 이 도구는 원인을 단정하지 않는다. 기준값은 모두 '임시(provisional)'이고, 판단은 AI/사용자가 한다.
#>
param(
  [string]$DataDir,
  [string]$BootDir,
  [string]$OutDir,
  [int]$Hours = 72,
  [switch]$NoSnapshot
)
$ErrorActionPreference = 'Stop'
$ToolVersion = '0.2.0'
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'MetricCatalog.ps1')
. (Join-Path $PSScriptRoot 'Get-Snapshot.ps1')
$inv = [Globalization.CultureInfo]::InvariantCulture
if (-not $DataDir) { $DataDir = Get-DefaultDataDir }

# ---------------- 입력 찾기 ----------------
if (-not $BootDir) {
  $latest = Get-ChildItem $DataDir -Directory -Filter 'boot_*' | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $latest) { throw "수집 데이터가 없습니다: $DataDir  (먼저 Start-Collector.ps1 을 실행하세요)" }
  $BootDir = $latest.FullName
}
$minuteFile = Join-Path $BootDir 'minute.jsonl'
if (-not (Test-Path $minuteFile)) { throw "minute.jsonl 이 없습니다: $BootDir  (수집기를 1분 이상 켜 두세요)" }
if (-not $OutDir) { $OutDir = Join-Path (Join-Path $DataDir 'export') (Split-Path $BootDir -Leaf) }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

function Rn($v, [int]$d = 2) { if ($null -eq $v -or [double]::IsNaN([double]$v)) { $null } else { [math]::Round([double]$v, $d) } }
function Fmt($v) { if ($null -eq $v) { '' } elseif ($v -is [double] -or $v -is [single] -or $v -is [decimal]) { if ([double]::IsNaN([double]$v)) { '' } else { ([double]$v).ToString('0.##', $inv) } } else { [string]$v } }
function Csv([string]$s) { if ($s -match '[",\r\n]') { '"' + $s.Replace('"', '""') + '"' } else { $s } }

$meta = Get-Content (Join-Path $BootDir 'meta.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$boot = [datetime]$meta.boot_time

# ---------------- 분 데이터 읽기 ----------------
$rows = New-Object Collections.Generic.List[object]
foreach ($line in [IO.File]::ReadLines($minuteFile, [Text.Encoding]::UTF8)) {
  if (-not $line.Trim()) { continue }
  $o = $line | ConvertFrom-Json
  $m = @{}; foreach ($p in $o.m.PSObject.Properties) { $m[$p.Name] = @($p.Value) }
  $s = @{}; foreach ($p in $o.s.PSObject.Properties) { $s[$p.Name] = [string]$p.Value }
  $t = [datetime]$o.t
  $rows.Add(@{ t = $t; min = ($t - $boot).TotalMinutes; phase = [string]$o.phase; n = [int]$o.n; m = $m; s = $s })
}
if ($rows.Count -eq 0) { throw 'minute.jsonl 에 데이터가 없습니다.' }
$rows = [Collections.Generic.List[object]]@($rows | Sort-Object { $_.t })
if ($Hours -gt 0) {
  $cut = $rows[$rows.Count - 1].t.AddHours(-$Hours)
  $rows = [Collections.Generic.List[object]]@($rows | Where-Object { $_.t -ge $cut })
}
$N = $rows.Count
$windowStart = $rows[0].t; $windowEnd = $rows[$N - 1].t
$mins = [double[]]@($rows | ForEach-Object { $_.min })

# ---------------- 시리즈 구성 ----------------
$numKeys = New-Object Collections.Generic.HashSet[string]
$strKeys = New-Object Collections.Generic.HashSet[string]
foreach ($r in $rows) { foreach ($k in $r.m.Keys) { [void]$numKeys.Add($k) }; foreach ($k in $r.s.Keys) { [void]$strKeys.Add($k) } }

$avg = @{}; $mx = @{}
foreach ($k in $numKeys) {
  $a = New-Object 'double[]' $N; $b = New-Object 'double[]' $N
  for ($i = 0; $i -lt $N; $i++) {
    $v = $rows[$i].m[$k]
    if ($v) { $a[$i] = [double]$v[0]; $b[$i] = [double]$v[1] } else { $a[$i] = [double]::NaN; $b[$i] = [double]::NaN }
  }
  $avg[$k] = $a; $mx[$k] = $b
}

# 파생: 코어 요약
$coreKeys = @($numKeys | Where-Object { $_ -like 'cpu.core.*' })
if ($coreKeys.Count -gt 0) {
  $cm = New-Object 'double[]' $N; $co = New-Object 'double[]' $N
  for ($i = 0; $i -lt $N; $i++) {
    $best = [double]::NaN; $cnt = 0
    foreach ($k in $coreKeys) { $x = $avg[$k][$i]; if (-not [double]::IsNaN($x)) { if ([double]::IsNaN($best) -or $x -gt $best) { $best = $x }; if ($x -ge 90) { $cnt++ } } }
    $cm[$i] = $best; $co[$i] = $cnt
  }
  $avg['cpu.core_max'] = $cm; $mx['cpu.core_max'] = $cm
  $avg['cpu.core_over90_count'] = $co; $mx['cpu.core_over90_count'] = $co
}

# 파생: 팬 개별 % 와 종류별 통합값 (센서 프로그램이 있을 때만 생김)
$fanKeys = @($numKeys | Where-Object { $_ -like 'hw.fan_rpm.*' } | Sort-Object)
$fanGroups = @{ cpu = New-Object Collections.Generic.List[string]; gpu = New-Object Collections.Generic.List[string]; case = New-Object Collections.Generic.List[string] }
foreach ($k in $fanKeys) {
  $name = $k.Substring('hw.fan_rpm.'.Length)
  $obsMax = 0.0; foreach ($x in $mx[$k]) { if (-not [double]::IsNaN($x) -and $x -gt $obsMax) { $obsMax = $x } }
  $pk = 'fan_pct.' + $name
  $p = New-Object 'double[]' $N
  for ($i = 0; $i -lt $N; $i++) { $x = $avg[$k][$i]; $p[$i] = $(if ($obsMax -gt 0 -and -not [double]::IsNaN($x)) { [math]::Round(100 * $x / $obsMax, 1) } else { [double]::NaN }) }
  $avg[$pk] = $p; $mx[$pk] = $p
  $grp = if ($name -match '(?i)cpu|pump|aio|water') { 'cpu' } elseif ($name -match '(?i)gpu|graphics') { 'gpu' } else { 'case' }
  $fanGroups[$grp].Add($pk)
}
foreach ($k in ($numKeys | Where-Object { $_ -match '^nv\.gpu\d+\.fan_pct$' })) { $fanGroups['gpu'].Add($k) }
foreach ($g in 'cpu', 'gpu', 'case') {
  if ($fanGroups[$g].Count -eq 0) { continue }
  $me = New-Object 'double[]' $N; $ma = New-Object 'double[]' $N
  for ($i = 0; $i -lt $N; $i++) {
    $sum = 0.0; $c = 0; $best = [double]::NaN
    foreach ($k in $fanGroups[$g]) { $x = $avg[$k][$i]; if (-not [double]::IsNaN($x)) { $sum += $x; $c++; if ([double]::IsNaN($best) -or $x -gt $best) { $best = $x } } }
    $me[$i] = $(if ($c -gt 0) { [math]::Round($sum / $c, 1) } else { [double]::NaN }); $ma[$i] = $best
  }
  $avg["fan_group.$g.mean_pct"] = $me; $mx["fan_group.$g.mean_pct"] = $me
  $avg["fan_group.$g.max_pct"] = $ma; $mx["fan_group.$g.max_pct"] = $ma
}

# 문자열 시리즈
$strSeries = @{}
foreach ($k in $strKeys) { $arr = New-Object 'string[]' $N; for ($i = 0; $i -lt $N; $i++) { $arr[$i] = [string]$rows[$i].s[$k] }; $strSeries[$k] = $arr }

# ---------------- 마커 / 구간 ----------------
$markers = @()
$mf = Join-Path $BootDir 'markers.jsonl'
if (Test-Path $mf) { $markers = @([IO.File]::ReadLines($mf, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) }
$segments = New-Object Collections.Generic.List[object]
$openSeg = $null
foreach ($mk in $markers) {
  if ($mk.type -eq 'segment_start') { $openSeg = @{ label = [string]$mk.label; start = [datetime]$mk.t } }
  elseif ($mk.type -eq 'segment_end' -and $openSeg) {
    $segments.Add(@{ label = $openSeg.label; start = $openSeg.start; end = [datetime]$mk.t; auto_closed = [bool]$mk.auto }); $openSeg = $null
  }
}
if ($openSeg) { $segments.Add(@{ label = $openSeg.label; start = $openSeg.start; end = $windowEnd.AddMinutes(1); auto_closed = $true }) }
$noteMarks = @($markers | Where-Object { $_.type -eq 'note' })

# 마커 열: 분 단위로 붙이기
$markerByMinute = @{}
foreach ($mk in $markers) {
  $key = ([datetime]$mk.t).ToString('yyyy-MM-ddTHH:mm')
  $txt = "$($mk.type):$($mk.label)"
  if ($markerByMinute.ContainsKey($key)) { $markerByMinute[$key] += ' | ' + $txt } else { $markerByMinute[$key] = $txt }
}

# ---------------- 통계 도구 ----------------
function Get-Finite([double[]]$a) { , @($a | Where-Object { -not [double]::IsNaN($_) }) }
function Get-Median([double[]]$a) { if ($a.Count -eq 0) { return $null }; $s = [double[]]$a.Clone(); [Array]::Sort($s); $n = $s.Count; if ($n % 2) { $s[($n - 1) / 2] } else { ($s[$n / 2 - 1] + $s[$n / 2]) / 2 } }
function Get-Mean([double[]]$a) { if ($a.Count -eq 0) { return $null }; $t = 0.0; foreach ($x in $a) { $t += $x }; $t / $a.Count }
function Get-Slope([double[]]$x, [double[]]$y) {
  $px = New-Object Collections.Generic.List[double]; $py = New-Object Collections.Generic.List[double]
  for ($i = 0; $i -lt $x.Count; $i++) { if (-not [double]::IsNaN($y[$i])) { $px.Add($x[$i]); $py.Add($y[$i]) } }
  if ($px.Count -lt 5) { return $null }
  $mx_ = Get-Mean $px.ToArray(); $my_ = Get-Mean $py.ToArray(); $num = 0.0; $den = 0.0
  for ($i = 0; $i -lt $px.Count; $i++) { $num += ($px[$i] - $mx_) * ($py[$i] - $my_); $den += ($px[$i] - $mx_) * ($px[$i] - $mx_) }
  if ($den -eq 0) { return $null }; $num / $den
}
function Get-Pearson([double[]]$x, [double[]]$y) {
  $px = New-Object Collections.Generic.List[double]; $py = New-Object Collections.Generic.List[double]
  for ($i = 0; $i -lt $x.Count; $i++) { if (-not [double]::IsNaN($x[$i]) -and -not [double]::IsNaN($y[$i])) { $px.Add($x[$i]); $py.Add($y[$i]) } }
  if ($px.Count -lt 10) { return $null }
  $a = Get-Mean $px.ToArray(); $b = Get-Mean $py.ToArray(); $sxy = 0.0; $sxx = 0.0; $syy = 0.0
  for ($i = 0; $i -lt $px.Count; $i++) { $dx = $px[$i] - $a; $dy = $py[$i] - $b; $sxy += $dx * $py[$i] - $dx * $b; $sxx += $dx * $dx; $syy += $dy * $dy }
  if ($sxx -eq 0 -or $syy -eq 0) { return $null }; $sxy / [math]::Sqrt($sxx * $syy)
}

function Get-SeriesSummary([string]$Key) {
  $a = $avg[$Key]; $b = $mx[$Key]
  $f = Get-Finite $a
  if ($f.Count -eq 0) { return $null }
  $info = Get-MetricInfo $Key
  $sorted = [double[]]$f.Clone(); [Array]::Sort($sorted)
  $med = Get-Median $f; $mean = Get-Mean $f
  $p95 = Get-Percentile $sorted 0.95
  $maxAvg = $sorted[-1]; $maxAt = $null
  for ($i = 0; $i -lt $N; $i++) { if ($a[$i] -eq $maxAvg) { $maxAt = $rows[$i].t.ToString('s'); break } }
  $peak = Get-Finite $b; $peakMax = $(if ($peak.Count -gt 0) { ($peak | Measure-Object -Maximum).Maximum } else { $null })
  # 임시 기준 초과 시간(분)
  $overWarn = $null; $overHot = $null
  if ($info.direction -eq 'high' -and $null -ne $info.warn) {
    $overWarn = @($f | Where-Object { $_ -ge $info.warn }).Count; $overHot = @($f | Where-Object { $_ -ge $info.hot }).Count
  } elseif ($info.direction -eq 'low' -and $null -ne $info.warn) {
    $overWarn = @($f | Where-Object { $_ -le $info.warn }).Count; $overHot = @($f | Where-Object { $_ -le $info.hot }).Count
  }
  # 기울기(전체 추세), 가장 가파른 상승/하강(3분 창)
  $slope = Get-Slope $mins $a
  $rise = $null; $fall = $null
  for ($i = 3; $i -lt $N; $i++) {
    if ([double]::IsNaN($a[$i]) -or [double]::IsNaN($a[$i - 3])) { continue }
    $dt = $mins[$i] - $mins[$i - 3]; if ($dt -lt 2 -or $dt -gt 4.5) { continue }
    $r = ($a[$i] - $a[$i - 3]) / $dt
    if ($null -eq $rise -or $r -gt $rise) { $rise = $r }; if ($null -eq $fall -or $r -lt $fall) { $fall = $r }
  }
  # 튀는 순간 (중앙값 + 3 * 1.4826 * MAD)
  $spikes = @()
  if ($f.Count -ge 10) {
    $dev = [double[]]@($f | ForEach-Object { [math]::Abs($_ - $med) }); $mad = Get-Median $dev
    if ($mad -gt 0) {
      $thr = $med + 3 * 1.4826 * $mad
      $hits = New-Object Collections.Generic.List[object]
      for ($i = 0; $i -lt $N; $i++) { if (-not [double]::IsNaN($a[$i]) -and $a[$i] -gt $thr) { $hits.Add([pscustomobject]@{ t = $rows[$i].t; v = $a[$i] }) } }
      $spikes = @($hits | Sort-Object v -Descending | Select-Object -First 5 | ForEach-Object { [ordered]@{ time = $_.t.ToString('s'); value = Rn $_.v 2 } })
    }
  }
  $spikeCount = 0
  if ($f.Count -ge 10 -and $mad -gt 0) { $spikeCount = @($f | Where-Object { $_ -gt $thr }).Count }
  [ordered]@{
    unit = $info.unit; description = $info.description
    minutes_with_data = $f.Count
    min = Rn $sorted[0]; mean = Rn $mean; median = Rn $med; p95 = Rn $p95; max_of_minute_avg = Rn $maxAvg; max_peak_in_any_minute = Rn $peakMax; max_at = $maxAt
    reading_by_p95 = Get-Reading $info $p95
    provisional_thresholds = $(if ($null -ne $info.warn) { [ordered]@{ direction = $info.direction; warn = $info.warn; hot = $info.hot } } else { $null })
    minutes_over_warn = $overWarn; minutes_over_hot = $overHot
    trend_slope_per_min = Rn $slope 4
    steepest_rise_per_min = Rn $rise 3; steepest_fall_per_min = Rn $fall 3
    skew = [ordered]@{ mean_minus_median = Rn ($mean - $med) 3; p95_over_median = $(if ($med -gt 0) { Rn ($p95 / $med) 2 } else { $null }) }
    spike_count = $spikeCount; spikes_top5 = $spikes
  }
}

$metrics = [ordered]@{}
$skipSummary = '^cpu\.core\.\d'
$keyOrder = @('cpu', 'mem', 'disk', 'net', 'gpu', 'nv', 'hw', 'fan_pct', 'fan_group', 'proc', 'collector')
function Get-KeyRank([string]$k) { $p = $k.Split('.')[0]; $i = [array]::IndexOf($keyOrder, $p); if ($i -lt 0) { 99 } else { $i } }
function Get-NaturalKey([string]$k) { [regex]::Replace($k, '\d+', { param($m) $m.Value.PadLeft(4, '0') }) }
$allNumKeys = @($avg.Keys | Sort-Object { Get-KeyRank $_ }, { Get-NaturalKey $_ })
foreach ($k in $allNumKeys) {
  if ($k -match $skipSummary) { continue }
  $s = Get-SeriesSummary $k
  if ($s) { $metrics[$k] = $s }
}

# 문자열 지표 분포
$stringMetrics = [ordered]@{}
foreach ($k in ($strSeries.Keys | Sort-Object)) {
  $vals = @($strSeries[$k] | Where-Object { $_ })
  $info = Get-MetricInfo $k
  $stringMetrics[$k] = [ordered]@{
    description = $info.description; minutes_with_data = $vals.Count
    minutes_by_value = @($vals | Group-Object | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object { [ordered]@{ value = $_.Name; minutes = $_.Count; share_pct = Rn (100 * $_.Count / [math]::Max(1, $vals.Count)) 1 } })
  }
}

# ---------------- 온도-팬 관계 (식는 속도, 팬 지연) ----------------
function Get-ThermalPair([string]$TempKey, [string]$FanKey, [string]$FanLabel) {
  if (-not $avg.ContainsKey($TempKey) -or -not $avg.ContainsKey($FanKey)) { return $null }
  $t = $avg[$TempKey]; $fn = $avg[$FanKey]
  $tf = Get-Finite $t; $ff = Get-Finite $fn
  if ($tf.Count -lt 5 -or $ff.Count -lt 5) { return $null }
  $tmin = ($tf | Measure-Object -Minimum).Minimum; $tmax = ($tf | Measure-Object -Maximum).Maximum
  $fmax = ($ff | Measure-Object -Maximum).Maximum; $fmin = ($ff | Measure-Object -Minimum).Minimum
  $res = [ordered]@{ temperature = $TempKey; fan = $FanKey; fan_label = $FanLabel
    temp_min = Rn $tmin 1; temp_max = Rn $tmax 1; fan_min = Rn $fmin 1; fan_max = Rn $fmax 1 }
  if (($tmax - $tmin) -lt 8) { $res.note = '온도 변화폭이 8도 미만이라 식는 속도/팬 지연을 분석할 수 없음'; return $res }
  # 정점 이후 10도 내려가는 데 걸린 시간
  $pi = 0; for ($i = 0; $i -lt $N; $i++) { if ($t[$i] -eq $tmax) { $pi = $i; break } }
  $cool = $null
  for ($i = $pi + 1; $i -lt $N; $i++) { if (-not [double]::IsNaN($t[$i]) -and $t[$i] -le $tmax - 10) { $cool = $mins[$i] - $mins[$pi]; break } }
  $res.peak_time = $rows[$pi].t.ToString('s'); $res.cooldown_10c_minutes = Rn $cool 1
  $res.cooldown_note = $(if ($null -eq $cool) { '정점 이후 10도 이상 내려간 구간이 관측되지 않음' } else { '' })
  # 온도는 낮은데 팬은 높은 분 수 (그 PC의 관측 범위 기준: 온도 하위 35%, 팬 상위 40%)
  $lowT = $tmin + 0.35 * ($tmax - $tmin); $highF = $fmin + 0.6 * ($fmax - $fmin)
  $cnt = 0; $streak = 0; $best = 0
  for ($i = 0; $i -lt $N; $i++) {
    if (-not [double]::IsNaN($t[$i]) -and -not [double]::IsNaN($fn[$i]) -and $t[$i] -le $lowT -and $fn[$i] -ge $highF -and $fmax -gt $fmin) { $cnt++; $streak++; if ($streak -gt $best) { $best = $streak } } else { $streak = 0 }
  }
  $res.fan_high_while_temp_low_minutes = $cnt; $res.fan_high_while_temp_low_longest_streak = $best
  $res.definition = "온도 하위 35%($([math]::Round($lowT,1))) 이하이면서 팬 상위 40%($([math]::Round($highF,1))) 이상인 분"
  # 팬이 온도를 몇 분 늦게 따라가는가 (상관이 가장 큰 지연)
  $bestLag = $null; $bestR = $null
  if ($N -ge 20 -and $fmax -gt $fmin) {
    for ($lag = 0; $lag -le 15; $lag++) {
      if ($N - $lag -lt 10) { break }
      $x = [double[]]$t[0..($N - 1 - $lag)]; $y = [double[]]$fn[$lag..($N - 1)]
      $r = Get-Pearson $x $y
      if ($null -ne $r -and ($null -eq $bestR -or $r -gt $bestR)) { $bestR = $r; $bestLag = $lag }
    }
  }
  $res.fan_follows_temp_with_lag_minutes = $bestLag; $res.correlation_at_that_lag = Rn $bestR 2
  $res
}
$thermal = New-Object Collections.Generic.List[object]
foreach ($k in ($avg.Keys | Where-Object { $_ -match '^nv\.gpu\d+\.temp_c$' } | Sort-Object)) {
  $fk = $k -replace 'temp_c$', 'fan_pct'; $r = Get-ThermalPair $k $fk 'GPU 팬(%)'; if ($r) { $thermal.Add($r) }
}
foreach ($k in ($avg.Keys | Where-Object { $_ -like 'hw.temp_c.*' } | Sort-Object)) {
  $isCpu = $k -match '(?i)cpu|core|package|tctl|tdie'
  $fk = $(if ($isCpu) { 'fan_group.cpu.mean_pct' } else { 'fan_group.case.mean_pct' })
  $r = Get-ThermalPair $k $fk $(if ($isCpu) { 'CPU 팬 통합(%)' } else { '케이스 팬 통합(%)' }); if ($r) { $thermal.Add($r) }
}

# ---------------- 구간/메모 비교 (원본 틱 사용) ----------------
$curated = @('cpu.util', 'mem.commit_pct', 'gpu.engine.3D', 'gpu.engine.VideoDecode', 'nv.gpu0.temp_c', 'nv.gpu0.util', 'nv.gpu0.fan_pct', 'nv.gpu0.sm_mhz', 'nv.gpu0.dec_util', 'proc.top_cpu_core_pct', 'disk.0_C:.latency_ms') | Where-Object { $avg.ContainsKey($_) }
# 기준선: baseline 단계(없으면 normal), 구간 안의 분은 제외
function Test-InSegment([datetime]$t) { foreach ($sg in $segments) { if ($t -ge $sg.start.AddMinutes(-1) -and $t -le $sg.end) { return $true } }; $false }
$baseIdx = @(for ($i = 0; $i -lt $N; $i++) { if ($rows[$i].phase -eq 'baseline' -and -not (Test-InSegment $rows[$i].t)) { $i } })
$baseLabel = 'baseline 단계'
if ($baseIdx.Count -lt 3) { $baseIdx = @(for ($i = 0; $i -lt $N; $i++) { if (-not $rows[$i].phase.StartsWith('segment') -and -not (Test-InSegment $rows[$i].t)) { $i } }); $baseLabel = '구간 밖 전체' }
$base = @{}; foreach ($k in $curated) { $v = @($baseIdx | ForEach-Object { $avg[$k][$_] } | Where-Object { -not [double]::IsNaN($_) }); $base[$k] = $(if ($v.Count -gt 0) { Get-Mean ([double[]]$v) } else { $null }) }

$procFile = Join-Path $BootDir 'processes.jsonl'
$procRecs = @()
if (Test-Path $procFile) { $procRecs = @([IO.File]::ReadLines($procFile, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) }

$rawFiles = @(Get-ChildItem $BootDir -Filter 'raw_*.jsonl' | Sort-Object Name)
function Read-RawTicks([datetime]$From, [datetime]$To) {
  $out = New-Object Collections.Generic.List[object]
  foreach ($f in $rawFiles) {
    foreach ($line in [IO.File]::ReadLines($f.FullName, [Text.Encoding]::UTF8)) {
      if ($line.Length -lt 30) { continue }
      $ts = $null; if ($line -match '^\{"t":"([^"]+)"') { $ts = [datetime]$Matches[1] } else { continue }
      if ($ts -ge $From -and $ts -le $To) { $out.Add(($line | ConvertFrom-Json)) }
    }
  }
  $out
}
function Get-WindowStats([datetime]$From, [datetime]$To) {
  $ticks = Read-RawTicks $From $To
  if ($ticks.Count -eq 0) { return $null }
  $st = [ordered]@{}
  foreach ($k in $curated) {
    $v = @($ticks | ForEach-Object { $_.m.$k } | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($v.Count -gt 0) {
      $mean = Get-Mean ([double[]]$v); $mxv = ($v | Measure-Object -Maximum).Maximum
      $d = $null; if ($null -ne $base[$k]) { $d = $mean - $base[$k] }
      $st[$k] = [ordered]@{ mean = Rn $mean 2; max = Rn $mxv 2; baseline_mean = Rn $base[$k] 2; delta_vs_baseline = Rn $d 2 }
    }
  }
  $topProc = @($ticks | ForEach-Object { $_.s.'proc.top_cpu' } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { [ordered]@{ process = $_.Name; ticks = $_.Count } })
  $topGpu = @($ticks | ForEach-Object { $_.s.'proc.top_gpu' } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { [ordered]@{ process = $_.Name; ticks = $_.Count } })
  [ordered]@{ ticks = $ticks.Count; metrics = $st; top_cpu_processes = $topProc; top_gpu_processes = $topGpu }
}

$segOut = @()
foreach ($sg in $segments) {
  $started = @($procRecs | Where-Object { -not $_.started_before_collector -and $_.first_seen -and ([datetime]$_.first_seen) -ge $sg.start.AddSeconds(-30) -and ([datetime]$_.first_seen) -le $sg.end } | Group-Object name | ForEach-Object { [ordered]@{ process = $_.Name; instances = $_.Count; company = ($_.Group | Select-Object -First 1).company } })
  $ws = Get-WindowStats $sg.start $sg.end
  $segOut += [ordered]@{
    label = $sg.label; start = $sg.start.ToString('s'); end = $sg.end.ToString('s'); duration_min = Rn (($sg.end - $sg.start).TotalMinutes) 1; auto_closed = $sg.auto_closed
    comparison_baseline = $baseLabel
    stats = $(if ($ws) { $ws } else { '원본 틱이 보관 기간(24시간)을 지나 비교할 수 없음' })
    processes_started_during = $started
  }
}
$noteOut = @()
foreach ($nm in $noteMarks) {
  $t0 = [datetime]$nm.t
  $before = Get-WindowStats $t0.AddMinutes(-5) $t0
  $after = Get-WindowStats $t0 $t0.AddMinutes(5)
  $noteOut += [ordered]@{ time = $t0.ToString('s'); label = [string]$nm.label; minutes_since_boot = Rn (($t0 - $boot).TotalMinutes) 1; five_min_before = $before; five_min_after = $after }
}

# ---------------- 프로세스 요약 ----------------
$procSummary = @($procRecs | Group-Object name | ForEach-Object {
    $g = $_.Group
    $firsts = @($g | Where-Object { $_.first_seen } | ForEach-Object { [datetime]$_.first_seen } | Sort-Object)
    [pscustomobject]@{
      name = $_.Name; company = [string]($g | Where-Object { $_.company } | Select-Object -First 1).company; description = [string]($g | Where-Object { $_.description } | Select-Object -First 1).description
      instances = $g.Count; started_after_collector = @($g | Where-Object { -not $_.started_before_collector }).Count
      first_seen = $(if ($firsts.Count) { $firsts[0].ToString('s') } else { '' }); last_seen = ($g | ForEach-Object { [datetime]$_.last_seen } | Sort-Object | Select-Object -Last 1).ToString('s')
      still_running = [bool](@($g | Where-Object { $_.still_running }).Count)
      peak_cpu_core_pct = ($g | Measure-Object peak_cpu_core_pct -Maximum).Maximum; peak_ram_mb = ($g | Measure-Object peak_ram_mb -Maximum).Maximum
    } } | Sort-Object peak_cpu_core_pct -Descending)

# ---------------- 스냅샷 ----------------
$snapshot = $null
if (-not $NoSnapshot) { Write-Host '[export] 시스템 스냅샷 수집 중...'; $snapshot = Get-Snapshot $boot }

# ---------------- 원인 후보 체크리스트 (결론 없음) ----------------
$H = New-Object Collections.Generic.List[object]
function Add-H([string]$Id, [string]$Cat, [string]$Text, [string]$Evidence, [string]$Detail) {
  $H.Add([ordered]@{ id = $Id; category = $Cat; hypothesis = $Text; evidence = $Evidence; detail = $Detail; provisional = $true })
}
function MetricsLike([string]$Pattern) { @($metrics.Keys | Where-Object { $_ -match $Pattern } | ForEach-Object { @{ key = $_; m = $metrics[$_] } }) }
function Judge([string]$Pattern, [double]$Threshold, [string]$Which = 'p95', [string]$Dir = 'high') {
  $ms = MetricsLike $Pattern
  if ($ms.Count -eq 0) { return @{ status = 'no_data'; detail = '해당 지표가 수집되지 않음' } }
  $hit = @(); $ok = @()
  foreach ($x in $ms) {
    $v = $(if ($Which -eq 'p95') { $x.m.p95 } elseif ($Which -eq 'min') { $x.m.min } else { $x.m.max_of_minute_avg })
    if ($null -eq $v) { continue }
    $line = "$($x.key)=$v$($x.m.unit)"
    if (($Dir -eq 'high' -and $v -ge $Threshold) -or ($Dir -eq 'low' -and $v -le $Threshold)) { $hit += $line } else { $ok += $line }
  }
  if ($hit.Count -gt 0) { return @{ status = 'supports'; detail = ("임시 기준($Which " + $(if ($Dir -eq 'high') { '≥' } else { '≤' }) + " $Threshold) 해당: " + ($hit -join ', ')) } }
  if ($ok.Count -gt 0) { return @{ status = 'against'; detail = ('임시 기준 미만: ' + (($ok | Select-Object -First 4) -join ', ')) } }
  @{ status = 'no_data'; detail = '값 없음' }
}
function AddJ($id, $cat, $text, $j) { Add-H $id $cat $text $j.status $j.detail }

# 디스플레이
if ($snapshot) {
  $vl = @($snapshot.display.virtual_or_remote_adapters)
  Add-H 'D1' '디스플레이' '가상/원격 디스플레이 어댑터가 화면 출력에 개입한다' $(if ($vl.Count -gt 0) { 'supports' } else { 'against' }) $(if ($vl.Count -gt 0) { "발견: $($vl -join ', ') (존재 자체가 문제의 증거는 아님)" } else { '가상/원격 어댑터 없음' })
  $de = @($snapshot.display_driver_events); $dc = 0; foreach ($e in $de) { $dc += [int]$e['occurrences'] }
  Add-H 'D2' '디스플레이' '디스플레이 드라이버 오류/복구 이벤트가 이번 부팅 중 발생했다' $(if ($dc -gt 0) { 'supports' } else { 'against' }) $(if ($dc -gt 0) { "총 $dc 건: " + (($de | Select-Object -First 3 | ForEach-Object { "$($_['provider'])#$($_['event_id'])×$($_['occurrences'])(처음 $($_['first']), 마지막 $($_['last']))" }) -join ', ') } else { '해당 이벤트 없음' })
  $mode = @($snapshot.display.adapters | Where-Object { $_.width } | ForEach-Object { "$($_.width)x$($_.height)@$($_.refresh_hz)Hz" }) -join ', '
  Add-H 'D3' '디스플레이' '현재 해상도/주사율/배율이 모니터 기본값과 다르다' 'no_data' "현재: $mode, 모니터: $(@($snapshot.display.monitors | ForEach-Object { $_.model }) -join ', '), 배율 DPI: $($snapshot.display.dpi_applied). 모니터 기본값은 이 도구가 알 수 없음"
} else {
  Add-H 'D1' '디스플레이' '가상/원격 디스플레이 어댑터가 화면 출력에 개입한다' 'no_data' '시스템 스냅샷을 만들지 않음(-NoSnapshot)'
}
$dec = MetricsLike '^(gpu\.engine\.VideoDecode|nv\.gpu\d+\.dec_util)$'
Add-H 'D4' '디스플레이' '영상 재생이 GPU 디코더를 쓰지 않고 CPU로 처리된다' $(if ($dec.Count -eq 0) { 'no_data' } elseif (($dec | Where-Object { $_.m.max_peak_in_any_minute -ge 5 }).Count -gt 0) { 'against' } else { 'no_data' }) $(if ($dec.Count -eq 0) { '디코더 지표 없음' } elseif (($dec | Where-Object { $_.m.max_peak_in_any_minute -ge 5 }).Count -gt 0) { '디코더 사용이 관측됨: ' + (($dec | ForEach-Object { "$($_.key) 최대 $($_.m.max_peak_in_any_minute)%" }) -join ', ') } else { '기록 중 영상 재생이 없었을 수 있음. 영상 재생 구간 마커(start/end)로 다시 측정 필요' })

# GPU
$thr = $stringMetrics.Keys | Where-Object { $_ -match '^nv\.gpu\d+\.throttle$' } | Select-Object -First 1
if ($thr) {
  $bad = @($stringMetrics[$thr].minutes_by_value | Where-Object { $_.value -match 'thermal|slowdown|power_brake|power_cap' })
  Add-H 'G1' 'GPU' 'GPU가 열/전력 때문에 성능을 제한(스로틀링)당했다' $(if ($bad.Count -gt 0) { 'supports' } else { 'against' }) $(if ($bad.Count -gt 0) { '제한 사유별 분: ' + (($bad | ForEach-Object { "$($_.value) $($_.minutes)분" }) -join ', ') } else { '분포: ' + (($stringMetrics[$thr].minutes_by_value | ForEach-Object { "$($_.value) $($_.minutes)분" }) -join ', ') })
} else { Add-H 'G1' 'GPU' 'GPU가 열/전력 때문에 성능을 제한(스로틀링)당했다' 'no_data' 'NVIDIA가 아니거나 nvidia-smi 사용 불가: 스로틀 사유를 읽지 못함' }
AddJ 'G2' 'GPU' 'GPU가 고온이다' (Judge '^nv\.gpu\d+\.temp_c$' 75)
$vr = @($metrics.Keys | Where-Object { $_ -match '^nv\.gpu\d+\.vram_used_mb$' })
if ($vr.Count -gt 0) {
  $tot = $metrics[($vr[0] -replace 'used', 'total')]; $ratio = $(if ($tot -and $tot.median) { $metrics[$vr[0]].max_of_minute_avg / $tot.median } else { $null })
  Add-H 'G3' 'GPU' 'GPU 메모리(VRAM)가 부족하다' $(if ($null -eq $ratio) { 'no_data' } elseif ($ratio -ge 0.9) { 'supports' } else { 'against' }) $(if ($null -eq $ratio) { '전체 용량 정보 없음' } else { "최대 사용 비율 $([math]::Round(100*$ratio,0))% (임시 기준 90%)" })
} else { Add-H 'G3' 'GPU' 'GPU 메모리(VRAM)가 부족하다' 'no_data' '지표 없음' }

# 열/팬
$cpuT = MetricsLike '^hw\.temp_c\.(?i:.*(cpu|core|package|tctl|tdie).*)$'
if ($cpuT.Count -eq 0) { Add-H 'T1' '열/팬' 'CPU가 과열된다' 'no_data' 'CPU 온도 센서 없음: LibreHardwareMonitor/OpenHardwareMonitor 를 켜면 수집됨' }
else { AddJ 'T1' '열/팬' 'CPU가 과열된다' (Judge '^hw\.temp_c\.(?i:.*(cpu|core|package|tctl|tdie).*)$' 80) }
$lagCand = @($thermal | Where-Object { $null -ne $_.fan_high_while_temp_low_minutes })
if ($lagCand.Count -eq 0) { Add-H 'T2' '열/팬' '온도가 내려간 뒤에도 팬이 높게 유지된다' 'no_data' '온도 변화폭이 작거나(8도 미만) 온도-팬 쌍을 얻지 못함. 부하를 준 뒤 식는 구간이 필요' }
else {
  $worst = $lagCand | Sort-Object fan_high_while_temp_low_minutes -Descending | Select-Object -First 1
  Add-H 'T2' '열/팬' '온도가 내려간 뒤에도 팬이 높게 유지된다' $(if ($worst.fan_high_while_temp_low_minutes -ge 5) { 'supports' } else { 'against' }) "$($worst.temperature) vs $($worst.fan_label): 온도 낮음+팬 높음 $($worst.fan_high_while_temp_low_minutes)분(가장 긴 연속 $($worst.fan_high_while_temp_low_longest_streak)분). 정의: $($worst.definition)"
}
$lagL = @($thermal | Where-Object { $null -ne $_.fan_follows_temp_with_lag_minutes })
if ($lagL.Count -eq 0) { Add-H 'T3' '열/팬' '팬 제어가 온도 변화보다 늦게 반응한다' 'no_data' '분석할 만큼의 온도 변화/시간이 없음' }
else { $l = $lagL | Sort-Object fan_follows_temp_with_lag_minutes -Descending | Select-Object -First 1
  Add-H 'T3' '열/팬' '팬 제어가 온도 변화보다 늦게 반응한다' $(if ($l.fan_follows_temp_with_lag_minutes -ge 3) { 'supports' } else { 'against' }) "$($l.temperature): 팬이 온도를 $($l.fan_follows_temp_with_lag_minutes)분 늦게 따라갈 때 상관이 가장 큼(r=$($l.correlation_at_that_lag))" }
if ($fanKeys.Count -eq 0) { Add-H 'T4' '열/팬' '케이스 팬/CPU 팬 중 일부가 비정상 회전한다' 'no_data' '팬 RPM 센서 없음(센서 프로그램 필요). GPU 팬 %만 NVIDIA에서 읽힘' }
else { Add-H 'T4' '열/팬' '케이스 팬/CPU 팬 중 일부가 비정상 회전한다' 'no_data' "팬 $($fanKeys.Count)개 수집됨. fan_pct.* 열로 서로 비교해 볼 것(한 팬만 다르게 움직이는지)" }

# 메모리
AddJ 'M1' '메모리' '메모리 압박(커밋 비율이 높다)' (Judge '^mem\.commit_pct$' 80)
AddJ 'M2' '메모리' '사용 가능한 메모리가 부족하다' (Judge '^mem\.avail_mb$' 2048 'min' 'low')
AddJ 'M3' '메모리' '디스크로 오가는 메모리 페이지(페이징)가 많다' (Judge '^mem\.pages_per_sec$' 500)
# 디스크
AddJ 'K1' '디스크' '디스크 응답이 느리다' (Judge '^disk\..*\.latency_ms$' 20)
AddJ 'K2' '디스크' '디스크가 포화 상태다' (Judge '^disk\..*\.busy$' 70)
if ($snapshot) { $bd = @($snapshot.physical_disks | Where-Object { $_.health -ne 'Healthy' }); Add-H 'K3' '디스크' '디스크 상태 이상이 보고됐다' $(if ($bd.Count -gt 0) { 'supports' } else { 'against' }) $(if ($bd.Count -gt 0) { "비정상: $(($bd | ForEach-Object { "$($_.model)=$($_.health)" }) -join ', ')" } else { 'Windows가 보고한 상태 모두 Healthy (SMART 상세는 관리자 권한 필요)' }) }
# CPU
AddJ 'C1' 'CPU' 'CPU가 지속적으로 과부하다' (Judge '^cpu\.util$' 80)
$dp = Judge '^cpu\.(dpc|interrupt)$' 5; AddJ 'C2' 'CPU' 'DPC/인터럽트 처리 시간이 길다(드라이버 후보)' $dp
if ($metrics.Contains('cpu.core_max') -and $metrics.Contains('cpu.util')) {
  $cmA = Get-Finite $avg['cpu.core_max']; $hotMin = @($cmA | Where-Object { $_ -ge 90 }).Count
  $share = $(if ($cmA.Count -gt 0) { $hotMin / $cmA.Count } else { 0 })
  $one = ($share -ge 0.5 -and $metrics['cpu.util'].mean -lt 40)
  Add-H 'C3' 'CPU' '한두 코어에만 부하가 몰린다(코어 수가 많은데 전체 사용률은 낮은 경우)' $(if ($one) { 'supports' } else { 'against' }) "가장 바쁜 코어가 90% 이상이었던 분: $hotMin/$($cmA.Count) ($([math]::Round(100*$share,0))%), 전체 평균 사용률=$($metrics['cpu.util'].mean)% (임시 기준: 분의 50% 이상 + 전체 평균 40% 미만)"
}
if ($metrics.Contains('cpu.perf_pct')) { Add-H 'C4' 'CPU' 'CPU 클럭이 기본값보다 낮게 제한된다' $(if ($metrics['cpu.perf_pct'].median -lt 60) { 'supports' } else { 'against' }) "성능 비율 중앙값=$($metrics['cpu.perf_pct'].median)% (100=기본 클럭, 100 초과=부스트)" }
# 전원
if ($snapshot) {
  $pl = [string]$snapshot.power.active_plan
  Add-H 'P1' '전원' '전원 계획이 절전 위주다' $(if ($pl -match '(?i)saver|절전|저전력') { 'supports' } else { 'against' }) "현재 계획: $pl"
  $rr = @($snapshot.reboot_related | Where-Object { $_.event_id -in 41, 6008 })
  Add-H 'P2' '전원' '직전 종료가 비정상이었다(전원 끊김/블루스크린/강제 종료)' $(if ($rr.Count -gt 0) { 'supports' } else { 'against' }) $(if ($rr.Count -gt 0) { "이벤트: $(($rr | ForEach-Object { "$($_.provider)#$($_.event_id)@$($_.time)" }) -join ', ')" } else { '부팅 직후 비정상 종료 기록 없음' })
  Add-H 'P3' '전원' '빠른 시작(Fast Startup)이 켜져 있어 "종료 후 켜기"가 완전한 초기화가 아니다' $(if ($snapshot.power.fast_startup -eq 1) { 'supports' } else { 'against' }) "fast_startup=$($snapshot.power.fast_startup) (재시작은 영향 없음, 종료 후 전원 켜기에만 해당)"
}
# 백그라운드
$tc = $stringMetrics['proc.top_cpu']
if ($tc -and $tc.minutes_by_value.Count -gt 0) {
  $top = $tc.minutes_by_value[0]
  $selfNote = ''
  if ($top.value -match '^(WmiPrvSE|powershell|pwsh|conhost)$') { $selfNote = " ※ 이 프로세스에는 이 도구 자신의 측정 부하가 섞여 있음" + $(if ($metrics.Contains('collector.cpu_core_pct')) { " (수집기 자신 평균 $($metrics['collector.cpu_core_pct'].mean)%, 코어1개 기준)" } else { '' }) }
  Add-H 'B1' '프로세스' '특정 프로세스가 지속적으로 자원을 점유한다' $(if ($top.share_pct -ge 50 -and $metrics.Contains('proc.top_cpu_core_pct') -and $metrics['proc.top_cpu_core_pct'].mean -ge 50 -and -not $selfNote) { 'supports' } else { 'against' }) "CPU 1위 프로세스: $($top.value) ($($top.share_pct)% 분), 1위 평균 사용률 $($metrics['proc.top_cpu_core_pct'].mean)%(코어1개 기준).$selfNote"
}
if ($segments.Count -gt 0 -or $noteMarks.Count -gt 0) {
  $sp = @($segOut | ForEach-Object { $_.processes_started_during } | ForEach-Object { $_.process } | Sort-Object -Unique)
  Add-H 'B2' '프로세스' '증상 구간 중 새로 시작된 프로그램이 원인이다' $(if ($sp.Count -gt 0) { 'supports' } else { 'no_data' }) $(if ($sp.Count -gt 0) { "구간 중 시작: $($sp -join ', ') (시작과 증상이 겹쳤다는 뜻일 뿐 인과는 아님)" } else { '구간 중 새로 시작된 프로세스 기록 없음' })
} else { Add-H 'B2' '프로세스' '증상 구간 중 새로 시작된 프로그램이 원인이다' 'no_data' '구간/메모 마커가 없음. Mark.ps1 start/end/note 로 증상 구간을 표시하면 분석됨' }
# 기타
if ($snapshot) {
  Add-H 'O1' '장치/시스템' '문제가 보고된 장치 드라이버가 있다' $(if (@($snapshot.devices_with_problems).Count -gt 0) { 'supports' } else { 'against' }) $(if (@($snapshot.devices_with_problems).Count -gt 0) { (@($snapshot.devices_with_problems) | ForEach-Object { "$($_['device']) (코드 $($_['error_code']): $($_['meaning']))" }) -join ', ' } else { '문제 장치 없음' })
  $tot = $snapshot.events_since_boot.system.total
  Add-H 'O2' '장치/시스템' '시스템 로그에 경고/오류가 많다' $(if ($tot -ge 50) { 'supports' } else { 'against' }) "이번 부팅 System 로그 경고/오류 $tot 건 (임시 기준 50건). 상위: $((@($snapshot.events_since_boot.system.groups) | Select-Object -First 3 | ForEach-Object { "$($_['provider'])#$($_['event_id'])×$($_['occurrences'])" }) -join ', ')"
}
Add-H 'N1' '네트워크' '네트워크 지연/끊김이 원인이다' 'no_data' '이 도구는 어댑터별 처리량만 기록하고 지연/패킷 손실은 측정하지 않음'
Add-H 'S1' '보안' '악성 프로그램/백그라운드 채굴이 자원을 쓴다' 'no_data' '보안 검사는 하지 않음. B1(프로세스 점유)과 processes.csv 참고'

# ---------------- highlights (임시 기준을 넘은 지표) ----------------
$rank = @{ '높음 (임시 기준)' = 2; '낮음 (임시 기준)' = 2; '주의 (임시 기준)' = 1 }
$highlights = @($metrics.GetEnumerator() | Where-Object { $rank.ContainsKey($_.Value.reading_by_p95) } | Sort-Object { -$rank[$_.Value.reading_by_p95] } | Select-Object -First 15 | ForEach-Object {
    [ordered]@{ metric = $_.Key; reading = $_.Value.reading_by_p95; p95 = $_.Value.p95; unit = $_.Value.unit; minutes_over_warn = $_.Value.minutes_over_warn } })

# ---------------- 데이터 품질 ----------------
$gaps = 0; $gapMin = 0.0
for ($i = 1; $i -lt $N; $i++) { $d = $mins[$i] - $mins[$i - 1]; if ($d -gt 2) { $gaps++; $gapMin += $d - 1 } }
$sources = $null; $sf = Join-Path $DataDir 'state.json'
if (Test-Path $sf) { $sources = (Get-Content $sf -Raw -Encoding UTF8 | ConvertFrom-Json).sources }

# ---------------- CSV 쓰기 ----------------
$peakRe = '(temp_c(\.|$)|^cpu\.util$|latency_ms$|\.busy$|^gpu\.engine\.(3D|VideoDecode)$|^nv\.gpu\d+\.util$|^mem\.pages_per_sec$|^cpu\.dpc$)'
$peakKeys = @($allNumKeys | Where-Object { $_ -match $peakRe -and $_ -notmatch '^fan_' })
$strCols = @($strSeries.Keys | Sort-Object)
$header = @('time', 'min_since_boot', 'phase', 'marker') + $allNumKeys + @($peakKeys | ForEach-Object { $_ + '__max' }) + $strCols
$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine((($header | ForEach-Object { Csv $_ }) -join ','))
for ($i = 0; $i -lt $N; $i++) {
  $r = $rows[$i]; $mk = $markerByMinute[$r.t.ToString('yyyy-MM-ddTHH:mm')]
  $cells = New-Object Collections.Generic.List[string]
  $cells.Add($r.t.ToString('s')); $cells.Add((Fmt (Rn $r.min 1))); $cells.Add((Csv $r.phase)); $cells.Add((Csv ([string]$mk)))
  foreach ($k in $allNumKeys) { $cells.Add((Fmt $avg[$k][$i])) }
  foreach ($k in $peakKeys) { $cells.Add((Fmt $mx[$k][$i])) }
  foreach ($k in $strCols) { $cells.Add((Csv $strSeries[$k][$i])) }
  [void]$sb.AppendLine(($cells -join ','))
}
[IO.File]::WriteAllText((Join-Path $OutDir 'metrics_1min.csv'), $sb.ToString(), (New-Object Text.UTF8Encoding $false))

$psb = New-Object Text.StringBuilder
[void]$psb.AppendLine('name,company,description,instances,started_after_collector,first_seen,last_seen,still_running,peak_cpu_core_pct,peak_ram_mb')
foreach ($p in $procSummary) { [void]$psb.AppendLine(((@($p.name, $p.company, $p.description, $p.instances, $p.started_after_collector, $p.first_seen, $p.last_seen, $p.still_running, $p.peak_cpu_core_pct, $p.peak_ram_mb) | ForEach-Object { Csv (Protect-Text ([string]$_) -PatternsOnly) }) -join ',')) }
[IO.File]::WriteAllText((Join-Path $OutDir 'processes.csv'), $psb.ToString(), (New-Object Text.UTF8Encoding $false))

# ---------------- summary.json ----------------
$dq = [ordered]@{}
$dq['minute_rows'] = $N
$dq['gaps_over_2min'] = $gaps
$dq['missing_minutes_estimate'] = [math]::Round([double]$gapMin, 0)
$dq['sources_available'] = $sources
$dq['limitations'] = @('CPU 온도/팬 RPM은 센서 프로그램이 켜져 있어야 수집됨', 'GPU 온도·팬·스로틀 사유는 NVIDIA에서만 수집됨', '1분 평균 기반이라 1분 미만의 짧은 순간 현상은 평균에 묻힐 수 있음(max_peak_in_any_minute 참고)', '구간/메모 비교는 원본 틱(24시간 보관)을 쓰며 보관 기간이 지나면 불가')
$summary = [ordered]@{
  schema_version = 1; tool_version = $ToolVersion; generated_at = (Get-Date).ToString('s')
  read_me_first = '이 파일의 모든 임시 기준(provisional)은 일반적인 값이며 이 PC의 정상 범위가 아닐 수 있습니다. 도구는 원인을 단정하지 않습니다. hypotheses 의 evidence 는 supports/against/no_data 만 표시합니다. 판단은 AI/사용자가 합니다.'
}
$fromMin = [math]::Round([double]$mins[0], 1); $toMin = [math]::Round([double]$mins[$N - 1], 1)
$summary['boot'] = [ordered]@{ boot_time = $boot.ToString('s'); window_start = $windowStart.ToString('s'); window_end = $windowEnd.ToString('s'); window_minutes_since_boot = [ordered]@{ from = $fromMin; to = $toMin }; analyzed_hours_limit = $Hours }
$summary['hardware'] = [ordered]@{ os = $meta.os; cpu = $meta.cpu; ram_gb = $meta.ram_gb; gpus = $meta.gpus }
$summary['measurement_plan'] = $meta.plan
$summary['data_quality'] = $dq
$summary['highlights_over_provisional_thresholds'] = $highlights
$summary['metrics'] = $metrics
$summary['string_metrics'] = $stringMetrics
$summary['thermal_fan_analysis'] = $thermal.ToArray()
$summary['segments'] = $segOut
$summary['notes'] = $noteOut
$summary['processes_top'] = @($procSummary | Select-Object -First 10 | ForEach-Object { [ordered]@{ name = $_.name; company = $_.company; peak_cpu_core_pct = $_.peak_cpu_core_pct; peak_ram_mb = $_.peak_ram_mb; started_after_collector = $_.started_after_collector } })
$summary['system'] = $snapshot
$summary['hypotheses'] = $H.ToArray()
Write-JsonFile (Join-Path $OutDir 'summary.json') $summary

# ---------------- schema.md ----------------
$md = New-Object Text.StringBuilder
function L([string]$s = '') { [void]$md.AppendLine($s) }
L '# 데이터 읽는 법 (schema)'
L
L "생성: $((Get-Date).ToString('s')) / 도구 v$ToolVersion / 부팅 $($boot.ToString('s'))"
L
L '## 파일'
L
L '| 파일 | 내용 |'
L '| --- | --- |'
L '| `metrics_1min.csv` | 분 단위 표. 행 = 1분, 열 = 지표. 빈 칸 = 그 분에 값 없음 |'
L '| `processes.csv` | 프로세스 이름별 요약 (경로·인자·창 제목은 수집하지 않음) |'
L '| `summary.json` | 지표별 요약, 서술 지표, 구간 비교, 시스템 스냅샷, 원인 후보 체크리스트 |'
L '| `schema.md` | 이 문서 |'
L
L '## 읽기 전에'
L
L '- 시간은 PC의 로컬 시간(ISO 8601, 시간대 표기 없음)이고, `min_since_boot`는 부팅 후 경과 분입니다. **분석의 기준축은 `min_since_boot`입니다.**'
L '- CSV는 UTF-8(BOM 없음), 쉼표 구분입니다. 숫자 열은 그 분의 **평균**입니다. 이름 끝에 `__max`가 붙은 열은 그 분 안에서 **가장 높았던 순간 값**입니다. 평균에 묻히는 짧은 급등을 볼 때 쓰세요.'
L '- `phase` 열: `boot_settle`(부팅 후 5분) → `baseline`(5~30분, 평소처럼 둔 구간) → `normal`(그 이후), `segment:<이름>`(사용자가 표시한 구간). `marker` 열: 그 분에 남긴 구간 시작/끝/메모.'
L '- **임시 기준(provisional)**: 아래 표의 주의/높음 기준은 일반적인 값입니다. 이 PC의 정상 범위가 아닐 수 있고, 도구는 이 값으로 원인을 단정하지 않습니다. `reading_by_p95` 같은 한 줄 해석은 읽는 순서를 돕는 표시일 뿐입니다.'
L '- `fan_pct.*`: 센서 프로그램이 있을 때만 생깁니다. 팬 하나의 회전수를 **그 팬이 이번 기록에서 보인 최대 RPM 대비 %**로 환산한 값입니다. `fan_group.<cpu|gpu|case>.mean_pct / max_pct`는 같은 종류 팬들의 평균/최고값으로, 케이스 팬이 여러 개일 때 전체 풍량의 대표값으로 씁니다.'
L '- **측정 자체의 부하**: 이 도구는 Windows 성능 카운터를 주기적으로 조회하므로 `WmiPrvSE`, `powershell` 프로세스의 CPU 사용이 실제보다 높게 보일 수 있습니다. `collector.cpu_core_pct`는 수집기 자신의 사용률입니다. `proc.top_cpu` 1위가 이 프로세스들이면 그 값은 가려서 보세요.'
L '- 센서가 없으면 해당 열이 아예 없습니다. 값이 0인 것과 측정되지 않은 것은 다릅니다 (NVIDIA GPU 팬은 저온에서 0%로 멈추는 것이 정상일 수 있음).'
L
L '## 열 목록'
L
L '| 열 | 단위 | 설명 | 주의 / 높음 (임시) | 색 기준 |'
L '| --- | --- | --- | --- | --- |'
$docKeys = New-Object Collections.Generic.List[string]
foreach ($k in $allNumKeys) {
  if ($k -match '^cpu\.core\.\d') { continue }
  $docKeys.Add($k)
}
foreach ($k in $docKeys) {
  $i = Get-MetricInfo $k
  $th = $(if ($null -ne $i.warn) { "$(if ($i.direction -eq 'low') { '≤' } else { '≥' }) $($i.warn) / $($i.hot)" } else { '-' })
  L "| ``$k`` | $($i.unit) | $($i.description) | $th | $(if ($i.scale -eq 'absolute') { '절대' } else { '상대(최소~최대)' }) |"
}
if ($coreKeys.Count -gt 0) {
  $i = Get-MetricInfo 'cpu.core.0_0'
  L "| ``cpu.core.<그룹>_<번호>`` ($($coreKeys.Count)개) | % | $($i.description) | ≥ $($i.warn) / $($i.hot) | 절대 |"
}
foreach ($k in $strCols) { $i = Get-MetricInfo $k; L "| ``$k`` | | $($i.description) | - | - |" }
L
L '## summary.json 구조'
L
L '- `metrics.<열 이름>`: `min / mean / median / p95 / max_of_minute_avg / max_peak_in_any_minute / max_at`, `reading_by_p95`(임시 기준 한 줄 해석), `minutes_over_warn / hot`, `trend_slope_per_min`(전체 추세, 단위/분), `steepest_rise_per_min / steepest_fall_per_min`(3분 창 기준 가장 가파른 변화), `skew`(평균-중앙값, p95/중앙값), `spike_count / spikes_top5`(중앙값+3·MAD 초과 순간).'
L '- `thermal_fan_analysis`: 온도 정점, 10도 식는 데 걸린 시간, **온도는 낮은데 팬은 높은 분 수**, 팬이 온도를 몇 분 늦게 따라가는지(상관이 가장 큰 지연).'
L '- `segments / notes`: 사용자가 표시한 구간·메모 전후의 원본 틱 기준 평균/최대와 기준선 대비 변화, 구간 중 시작된 프로세스.'
L '- `hypotheses`: 가능한 원인 후보 체크리스트. `evidence` 는 `supports`(임시 기준 이상으로 관측됨) / `against`(측정했고 기준 미만) / `no_data`(수집하지 않았거나 부족) 중 하나이며 **결론이 아닙니다.**'
L '- `system`: 부팅 이후 이벤트 요약, 디스플레이 설정, 문제 장치, 전원 계획 등 스냅샷. 계정/경로/IP/MAC/시리얼은 포함하지 않으며 이름은 `<USER>`, `<PC>`로 가려집니다.'
L
L '## 개인정보'
L
L '수집하지 않는 것의 기준과 목록은 저장소의 README를 보세요. 이 폴더의 파일에는 파일 경로, 명령줄 인자, 창 제목, 계정, IP/MAC, 시리얼 번호가 없습니다.'
[IO.File]::WriteAllText((Join-Path $OutDir 'schema.md'), $md.ToString(), (New-Object Text.UTF8Encoding $false))

Write-Host "[export] 완료: $OutDir" -ForegroundColor Green
Get-ChildItem $OutDir | ForEach-Object { Write-Host ("  {0,-18} {1,10:N0} bytes" -f $_.Name, $_.Length) }
