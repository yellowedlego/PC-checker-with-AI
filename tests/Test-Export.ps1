<#
  합성 데이터로 Export-Data.ps1 의 센서 경로(팬 개별/통합 열, 식는 속도, 팬 지연, 원인 후보)를 검증한다.
  실제 센서가 없는 PC에서도 돌릴 수 있다.   실행:  powershell -ExecutionPolicy Bypass -File .\tests\Test-Export.ps1

  시나리오(부팅 후 90분, 1분 간격):
    0~19분   대기       CPU 40°C, 모든 팬 800 RPM
    20~39분  부하       CPU 40→85°C (선형), 팬은 온도를 4분 늦게 따라가 1800 RPM까지
    40~89분  식는 중    CPU 85→45°C (55분까지), 그런데 팬은 70분까지 1800 RPM 유지 후 하락  => '온도 낮은데 팬 높음' 구간
    Case_Fan_3 은 다른 팬보다 낮게(1200 RPM) 돈다.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('pcc_synth_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$boot = [datetime]'2026-11-01T09:00:00'
$bootDir = Join-Path $tmp ('boot_' + $boot.ToString('yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $bootDir -Force | Out-Null

function Clamp($x, $lo, $hi) { [math]::Max($lo, [math]::Min($hi, $x)) }
function TempAt($i) { if ($i -lt 20) { 40 } elseif ($i -lt 40) { 40 + 45 * ($i - 20) / 19 } elseif ($i -lt 55) { 85 - 40 * ($i - 39) / 16 } else { 45 } }
function FanBase($i) { # 팬 목표(0..1): 온도를 4분 늦게 따라가고, 70분까지 높게 유지
  $j = $i - 4; if ($j -lt 20) { return 0.0 }
  if ($j -lt 40) { return (Clamp (($j - 19) / 20.0) 0 1) }
  if ($i -lt 70) { return 1.0 }
  Clamp (1.0 - ($i - 69) / 10.0) 0 1
}
$lines = New-Object Collections.Generic.List[string]
for ($i = 0; $i -lt 90; $i++) {
  $t = $boot.AddMinutes($i)
  $temp = TempAt $i; $fb = FanBase $i
  $m = [ordered]@{}
  $m['cpu.util'] = @((10 + 70 * [double]($i -ge 20 -and $i -lt 40)), 95, 95)
  $m['mem.commit_pct'] = @(55, 56, 56)
  $m['hw.temp_c.CPU_Package'] = @([math]::Round($temp, 1), [math]::Round($temp + 1, 1), [math]::Round($temp + 1, 1))
  $m['hw.fan_rpm.CPU_Fan'] = @([math]::Round(800 + 1000 * $fb), 1850, 1850)
  foreach ($n in 1, 2, 4) { $m["hw.fan_rpm.Case_Fan_$n"] = @([math]::Round(800 + 1000 * $fb), 1850, 1850) }
  $m['hw.fan_rpm.Case_Fan_3'] = @([math]::Round(800 + 400 * $fb), 1250, 1250)
  $m['nv.gpu0.temp_c'] = @(45, 46, 46); $m['nv.gpu0.fan_pct'] = @(0, 0, 0)
  $phase = if ($i -lt 5) { 'boot_settle' } elseif ($i -ge 20 -and $i -lt 40) { 'segment:game' } elseif ($i -lt 30) { 'baseline' } else { 'normal' }
  $lines.Add(([ordered]@{ t = $t.ToString('s'); n = 12; phase = $phase; m = $m; s = [ordered]@{ 'proc.top_cpu' = 'game' } } | ConvertTo-Json -Depth 5 -Compress))
}
[IO.File]::WriteAllLines((Join-Path $bootDir 'minute.jsonl'), $lines, (New-Object Text.UTF8Encoding $false))
$meta = [ordered]@{ collector_version = 'synthetic'; boot_time = $boot.ToString('s'); os = @{ caption = 'Synthetic' }; cpu = @{ name = 'Synthetic CPU'; logical = 8 }; ram_gb = 16; gpus = @(); plan = @{ note = 'synthetic' } }
[IO.File]::WriteAllText((Join-Path $bootDir 'meta.json'), ($meta | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
$mk = @(
  ([ordered]@{ t = $boot.AddMinutes(20).ToString('s'); type = 'segment_start'; label = 'game' } | ConvertTo-Json -Compress),
  ([ordered]@{ t = $boot.AddMinutes(40).ToString('s'); type = 'segment_end'; label = 'game'; duration_sec = 1200 } | ConvertTo-Json -Compress))
[IO.File]::WriteAllLines((Join-Path $bootDir 'markers.jsonl'), $mk, (New-Object Text.UTF8Encoding $false))

$out = Join-Path $tmp 'out'
& (Join-Path $root 'src\Export-Data.ps1') -DataDir $tmp -OutDir $out -NoSnapshot | Out-Null
$sum = Get-Content (Join-Path $out 'summary.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$csv = Import-Csv (Join-Path $out 'metrics_1min.csv')
$cols = $csv[0].PSObject.Properties.Name

$script:fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Info = '') { if ($Ok) { Write-Host "PASS  $Name" -ForegroundColor Green } else { Write-Host "FAIL  $Name  $Info" -ForegroundColor Red; $script:fail++ } }

Check 'CSV: 행 수 = 90' ($csv.Count -eq 90) "got $($csv.Count)"
Check 'CSV: 팬 개별 % 열' (($cols -contains 'fan_pct.Case_Fan_1') -and ($cols -contains 'fan_pct.Case_Fan_3'))
Check 'CSV: 케이스 팬 통합 열(옆 열)' (($cols -contains 'fan_group.case.mean_pct') -and ($cols -contains 'fan_group.case.max_pct'))
Check 'CSV: CPU 팬 통합 열' ($cols -contains 'fan_group.cpu.mean_pct')
$peak = $csv | Where-Object { [int]$_.min_since_boot -eq 60 } | Select-Object -First 1
Check 'CSV: 60분 케이스 팬 통합 평균 > 60%' ([double]$peak.'fan_group.case.mean_pct' -gt 60) "got $($peak.'fan_group.case.mean_pct')"
Check 'CSV: Case_Fan_3 은 다른 팬보다 낮음(60분)' ([double]$peak.'fan_pct.Case_Fan_3' -lt [double]$peak.'fan_pct.Case_Fan_1') "fan3=$($peak.'fan_pct.Case_Fan_3') fan1=$($peak.'fan_pct.Case_Fan_1')"
Check 'CSV: 마커 열에 구간 시작' (@($csv | Where-Object { $_.marker -like 'segment_start:game*' }).Count -eq 1)
Check 'CSV: __max 열' ($cols -contains 'hw.temp_c.CPU_Package__max')

$th = @($sum.thermal_fan_analysis | Where-Object { $_.temperature -eq 'hw.temp_c.CPU_Package' })[0]
Check '열분석: CPU 온도-팬 쌍 존재' ($null -ne $th)
if ($th) {
  Check '열분석: 정점 85°C 근처' ($th.temp_max -ge 84 -and $th.temp_max -le 86) "got $($th.temp_max)"
  Check '열분석: 식는 데 걸린 시간 관측(10도)' ($null -ne $th.cooldown_10c_minutes)
  Check '열분석: 온도 낮은데 팬 높은 분 >= 5' ($th.fan_high_while_temp_low_minutes -ge 5) "got $($th.fan_high_while_temp_low_minutes)"
  Check '열분석: 팬이 온도를 3~16분 늦게 따라감' ($th.fan_follows_temp_with_lag_minutes -ge 3) "got $($th.fan_follows_temp_with_lag_minutes)"
}
$h = @{}; foreach ($x in $sum.hypotheses) { $h[$x.id] = $x.evidence }
Check '후보 T1(CPU 과열) = supports' ($h['T1'] -eq 'supports') "got $($h['T1'])"
Check '후보 T2(온도 내려가도 팬 높음) = supports' ($h['T2'] -eq 'supports') "got $($h['T2'])"
Check '후보 T3(팬 제어 지연) = supports' ($h['T3'] -eq 'supports') "got $($h['T3'])"
Check '후보 T4(팬 비정상) = no_data(판단 보류)' ($h['T4'] -eq 'no_data') "got $($h['T4'])"
Check '구간 1개 인식' (@($sum.segments).Count -eq 1)
Check 'schema.md 생성' (Test-Path (Join-Path $out 'schema.md'))
Check 'summary: 임시 기준 안내문 존재' ($sum.read_me_first -match '임시')

Remove-Item $tmp -Recurse -Force
if ($script:fail -gt 0) { Write-Host "`n$($script:fail)개 실패" -ForegroundColor Red; exit 1 } else { Write-Host "`n모두 통과" -ForegroundColor Green }
