<#
  가벼운 AI용 팩(Build-LightPack.ps1)을 합성 데이터로 검증한다.   실행:  powershell -ExecutionPolicy Bypass -File .\tests\Test-LightPack.ps1
  - 90분 기록(센서·구간·메모 포함)과 7분짜리 짧은 기록 두 가지를 검사한다.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'SyntheticBoot.ps1')
Add-Type -AssemblyName System.Drawing
$utf8 = New-Object Text.UTF8Encoding $false
$script:fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Info = '') { if ($Ok) { Write-Host "PASS  $Name" -ForegroundColor Green } else { Write-Host "FAIL  $Name  $Info" -ForegroundColor Red; $script:fail++ } }
function Build-Pack([int]$Minutes) {
  $syn = New-SyntheticBoot -Minutes $Minutes
  & (Join-Path $root 'src\Export-Data.ps1') -DataDir $syn.DataDir -NoSnapshot | Out-Null
  $out = (Get-ChildItem (Join-Path $syn.DataDir 'export') -Directory | Select-Object -First 1).FullName
  & (Join-Path $root 'src\Build-LightPack.ps1') -ExportDir $out | Out-Null
  @{ Dir = Join-Path $out 'light'; Root = $syn.DataDir }
}
$sqRe = '\uD83D[\uDFE5-\uDFE9]|[⬛⬜]'

# ---------------- 90분 ----------------
Write-Host '--- 90분 기록' -ForegroundColor Cyan
$p = Build-Pack 90; $L = $p.Dir
foreach ($f in 'summary.md', 'charts_guide.md', 'chart_1_heatmap.png', 'chart_2_vs_thresholds.png', 'chart_3_thermal_fan.png', 'chart_4_cpu_gpu.png', 'chart_5_memory_disk.png') { Check "파일 존재: $f" (Test-Path (Join-Path $L $f)) }
foreach ($png in Get-ChildItem $L -Filter 'chart_*.png') {
  $img = [Drawing.Image]::FromFile($png.FullName); $w = $img.Width; $h = $img.Height; $img.Dispose()
  Check "PNG 폭 <= 1000px, 크기 <= 300KB: $($png.Name)" ($w -le 1000 -and $png.Length -le 300KB) "w=$w kb=$([math]::Round($png.Length/1KB))"
}
$md = [IO.File]::ReadAllText((Join-Path $L 'summary.md'), $utf8); $bytes = $utf8.GetByteCount($md)
Check 'summary.md <= 4600 bytes' ($bytes -le 4600) "bytes=$bytes"
Check 'summary.md: 임시 기준 안내' ($md -match '임시 값' -and $md -match '단정하지 않습니다')
Check 'summary.md: 글자 히트맵(이모지 칸)' ([regex]::Matches($md, $sqRe).Count -gt 50)
Check 'summary.md: 원인 후보 supports 표시' ($md -match '\[supports\]')
Check 'summary.md: 보간 오류 없음(빈 값/잘린 제목)' (-not ($md -match '기록  \(') -and -not ($md -match '시간, \)') -and -not ($md -match 'against  /'))
$guide = [IO.File]::ReadAllText((Join-Path $L 'charts_guide.md'), $utf8)
Check 'charts_guide.md: 모든 그림 설명' (($guide -match 'chart_1_heatmap') -and ($guide -match 'chart_3_thermal_fan') -and ($guide -match 'chart_5_memory_disk'))
Check 'charts_guide.md: 색만으로 구분하지 않는다는 안내' ($guide -match '색만으로 구분하지')
# 낮을수록 나쁜 지표('남은 메모리')가 정상일 때 빨간 칸이 없어야 한다 (과거 버그: 없는 칸을 0으로 읽음)
$row = ($md -split "`n" | Where-Object { $_ -match '^남은 메모리 ' } | Select-Object -First 1)
Check "'남은 메모리' 줄: 정상 구간에 🟥 없음" ($row -and -not ($row -match [char]::ConvertFromUtf32(0x1F7E5))) $row
Remove-Item $p.Root -Recurse -Force

# ---------------- 7분 (칸 수보다 짧은 기록) ----------------
Write-Host '--- 7분 기록' -ForegroundColor Cyan
$p = Build-Pack 7; $L = $p.Dir
$md = [IO.File]::ReadAllText((Join-Path $L 'summary.md'), $utf8)
Check '7분: summary.md 생성' ($md.Length -gt 200)
$rows = @($md -split "`n" | Where-Object { $_ -match "$sqRe" -and $_ -notmatch '^범례' })
$maxCells = ($rows | ForEach-Object { [regex]::Matches($_, $sqRe).Count } | Measure-Object -Maximum).Maximum
Check '7분: 글자 히트맵 칸 수가 기록 분 수(7) 이내' ($maxCells -le 7 -and $maxCells -ge 1) "max=$maxCells"
Check '7분: 그림 1 생성' (Test-Path (Join-Path $L 'chart_1_heatmap.png'))
$row = ($md -split "`n" | Where-Object { $_ -match '^남은 메모리 ' } | Select-Object -First 1)
Check "7분: '남은 메모리' 줄에 🟥 없음" ($row -and -not ($row -match [char]::ConvertFromUtf32(0x1F7E5))) $row
Remove-Item $p.Root -Recurse -Force

if ($script:fail -gt 0) { Write-Host "`n$($script:fail)개 실패" -ForegroundColor Red; exit 1 } else { Write-Host "`n모두 통과" -ForegroundColor Green }
