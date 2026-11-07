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
. (Join-Path $PSScriptRoot 'SyntheticBoot.ps1')
$syn = New-SyntheticBoot
$tmp = $syn.DataDir

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

& (Join-Path $root 'src\Build-Dashboard.ps1') -ExportDir $out | Out-Null
$htmlPath = Join-Path $out 'dashboard.html'
Check '대시보드: dashboard.html 생성' (Test-Path $htmlPath)
if (Test-Path $htmlPath) {
  $html = [IO.File]::ReadAllText($htmlPath, [Text.Encoding]::UTF8)
  Check '대시보드: 데이터 삽입됨(자리표시자 없음)' (-not ($html -match '__PAYLOAD__') -and $html.Length -gt 50000) "len=$($html.Length)"
  Check '대시보드: 외부 주소/CDN/웹폰트 없음(오프라인)' (-not ($html -match '(?i)(src|href)\s*=\s*["'']?https?://|@import|url\(\s*["'']?https?:|<link[^>]+stylesheet'))
  Check '대시보드: 팬 통합 줄 데이터 포함' ($html -match 'fan_group\.case\.mean_pct')
}

Remove-Item $tmp -Recurse -Force
if ($script:fail -gt 0) { Write-Host "`n$($script:fail)개 실패" -ForegroundColor Red; exit 1 } else { Write-Host "`n모두 통과" -ForegroundColor Green }
