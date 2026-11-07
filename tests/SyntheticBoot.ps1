<#
  합성 부팅 데이터 생성기 (테스트/화면 확인용). 센서가 없는 PC에서도 팬·온도 경로를 검증할 수 있다.
  사용:  . .\tests\SyntheticBoot.ps1 ; $s = New-SyntheticBoot ; $s.DataDir

  시나리오(부팅 후 90분, 1분 간격):
    0~19분   대기       CPU 40°C, 모든 팬 800 RPM
    20~39분  부하       CPU 40→85°C (선형), 팬은 온도를 4분 늦게 따라가 1800 RPM까지   (구간 마커 "game")
    40~89분  식는 중    CPU 85→45°C (55분까지), 그런데 팬은 70분까지 1800 RPM 유지 후 하락  => '온도 낮은데 팬 높음' 구간
    Case_Fan_3 은 다른 팬보다 낮게(1200 RPM) 돈다.
#>
function New-SyntheticBoot([string]$Root, [int]$Minutes = 90) {
  if (-not $Root) { $Root = Join-Path ([IO.Path]::GetTempPath()) ('pcc_synth_' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
  $boot = [datetime]'2026-11-01T09:00:00'
  $bootDir = Join-Path $Root ('boot_' + $boot.ToString('yyyyMMdd_HHmmss'))
  New-Item -ItemType Directory -Path $bootDir -Force | Out-Null
  $clamp = { param($x, $lo, $hi) [math]::Max($lo, [math]::Min($hi, $x)) }
  $tempAt = { param($i) if ($i -lt 20) { 40 } elseif ($i -lt 40) { 40 + 45 * ($i - 20) / 19 } elseif ($i -lt 55) { 85 - 40 * ($i - 39) / 16 } else { 45 } }
  $fanBase = { param($i) $j = $i - 4; if ($j -lt 20) { return 0.0 }; if ($j -lt 40) { return (& $clamp (($j - 19) / 20.0) 0 1) }; if ($i -lt 70) { return 1.0 }; & $clamp (1.0 - ($i - 69) / 10.0) 0 1 }
  $rnd = New-Object Random 7
  $lines = New-Object Collections.Generic.List[string]
  for ($i = 0; $i -lt $Minutes; $i++) {
    $t = $boot.AddMinutes($i)
    $temp = & $tempAt $i; $fb = & $fanBase $i; $load = [double]($i -ge 20 -and $i -lt 40)
    $m = [ordered]@{}
    $m['cpu.util'] = @([math]::Round(8 + 70 * $load + $rnd.Next(0, 6), 1), 96, 96)
    $m['cpu.perf_pct'] = @([math]::Round(120 + 80 * $load), 260, 260)
    $m['mem.avail_mb'] = @([math]::Round(9000 - 3500 * $load), 2500, 2500)
    $m['mem.commit_pct'] = @([math]::Round(55 + 20 * $load, 1), 78, 78)
    $m['disk.0_C:.busy'] = @([math]::Round(2 + 30 * $load + $rnd.Next(0, 5), 1), 90, 90)
    $m['disk.0_C:.latency_ms'] = @([math]::Round(0.4 + 6 * $load, 2), 40, 40)
    $m['gpu.engine.3D'] = @([math]::Round(5 + 80 * $load, 1), 98, 98)
    $m['hw.temp_c.CPU_Package'] = @([math]::Round($temp, 1), [math]::Round($temp + 1, 1), [math]::Round($temp + 1, 1))
    $m['hw.fan_rpm.CPU_Fan'] = @([math]::Round(800 + 1000 * $fb), 1850, 1850)
    foreach ($n in 1, 2, 4) { $m["hw.fan_rpm.Case_Fan_$n"] = @([math]::Round(800 + 1000 * $fb), 1850, 1850) }
    $m['hw.fan_rpm.Case_Fan_3'] = @([math]::Round(800 + 400 * $fb), 1250, 1250)
    $m['nv.gpu0.temp_c'] = @([math]::Round(42 + 30 * $load, 1), 75, 75); $m['nv.gpu0.fan_pct'] = @([math]::Round(35 * $load), 40, 40)
    $m['nv.gpu0.util'] = @([math]::Round(4 + 85 * $load, 1), 99, 99); $m['nv.gpu0.sm_mhz'] = @([math]::Round(300 + 2200 * $load), 2640, 2640)
    $phase = if ($i -lt 5) { 'boot_settle' } elseif ($i -ge 20 -and $i -lt 40) { 'segment:game' } elseif ($i -lt 30) { 'baseline' } else { 'normal' }
    $s = [ordered]@{ 'proc.top_cpu' = $(if ($load) { 'game' } else { 'explorer' }); 'nv.gpu0.throttle' = $(if ($i -ge 30 -and $i -lt 40) { 'sw_thermal' } else { 'none' }) }
    $lines.Add(([ordered]@{ t = $t.ToString('s'); n = 12; phase = $phase; m = $m; s = $s } | ConvertTo-Json -Depth 5 -Compress))
  }
  [IO.File]::WriteAllLines((Join-Path $bootDir 'minute.jsonl'), $lines, (New-Object Text.UTF8Encoding $false))
  $meta = [ordered]@{ collector_version = 'synthetic'; boot_time = $boot.ToString('s'); os = @{ caption = 'Synthetic' }; cpu = @{ name = 'Synthetic CPU'; logical = 8 }; ram_gb = 16; gpus = @(); plan = @{ note = 'synthetic' } }
  [IO.File]::WriteAllText((Join-Path $bootDir 'meta.json'), ($meta | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
  $mk = @(
    ([ordered]@{ t = $boot.AddMinutes(20).ToString('s'); type = 'segment_start'; label = 'game' } | ConvertTo-Json -Compress),
    ([ordered]@{ t = $boot.AddMinutes(40).ToString('s'); type = 'segment_end'; label = 'game'; duration_sec = 1200 } | ConvertTo-Json -Compress),
    ([ordered]@{ t = $boot.AddMinutes(60).ToString('s'); type = 'note'; label = '팬 소리가 계속 큼' } | ConvertTo-Json -Compress))
  [IO.File]::WriteAllLines((Join-Path $bootDir 'markers.jsonl'), $mk, (New-Object Text.UTF8Encoding $false))
  @{ DataDir = $Root; BootDir = $bootDir }
}
