<#
  PC-checker-with-AI 대시보드 만들기 (3단계)
  Export-Data.ps1 이 만든 파일을 읽어, 인터넷 없이 열리는 HTML 하나(dashboard.html)로 묶는다.
  외부 폰트/스크립트/이미지를 쓰지 않고, 데이터는 HTML 안에 들어 있다. 읽기 전용, 네트워크 전송 없음.

    powershell -ExecutionPolicy Bypass -File .\src\Build-Dashboard.ps1 [-ExportDir <폴더>] [-Open]
#>
param(
  [string]$ExportDir,
  [string]$DataDir,
  [switch]$Open
)
$ErrorActionPreference = 'Stop'
$ToolVersion = '0.3.0'
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'MetricCatalog.ps1')
. (Join-Path $PSScriptRoot 'RequestCatalog.ps1')
if (-not $DataDir) { $DataDir = Get-DefaultDataDir }
if (-not $ExportDir) {
  $latest = Get-ChildItem (Join-Path $DataDir 'export') -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $latest) { throw "내보낸 파일이 없습니다. 먼저 Export-Data.ps1 을 실행하세요. ($DataDir\export)" }
  $ExportDir = $latest.FullName
}
$summaryPath = Join-Path $ExportDir 'summary.json'; $csvPath = Join-Path $ExportDir 'metrics_1min.csv'
foreach ($p in $summaryPath, $csvPath) { if (-not (Test-Path $p)) { throw "파일이 없습니다: $p" } }
$template = Join-Path $PSScriptRoot 'dashboard\template.html'
$utf8 = New-Object Text.UTF8Encoding $false

$sum = [IO.File]::ReadAllText($summaryPath, $utf8) | ConvertFrom-Json
$csvText = [IO.File]::ReadAllText($csvPath, $utf8)
$header = ($csvText -split "`n", 2)[0].Trim().Split(',')
$strCols = @()
if ($sum.string_metrics) { $strCols = @($sum.string_metrics.PSObject.Properties.Name) }
$numCols = @($header | Where-Object { $_ -notin 'time', 'min_since_boot', 'phase', 'marker' -and $_ -notlike '*__max' -and $_ -notin $strCols })

# 지표 사전(단위/설명/임시 기준) - 화면의 색 기준이 도구의 기준과 같도록 여기서 내려준다
$catalog = [ordered]@{}
foreach ($k in $numCols) { $i = Get-MetricInfo $k; $catalog[$k] = [ordered]@{ unit = $i.unit; description = $i.description; direction = $i.direction; warn = $i.warn; hot = $i.hot; scale = $i.scale } }
$stats = [ordered]@{}
if ($sum.metrics) {
  foreach ($p in $sum.metrics.PSObject.Properties) {
    $m = $p.Value
    $stats[$p.Name] = [ordered]@{ mean = $m.mean; p95 = $m.p95; max_peak = $m.max_peak_in_any_minute; reading = $m.reading_by_p95; minutes_over_warn = $m.minutes_over_warn }
  }
}
# 시스템 정보는 화면에 필요한 부분만
$system = $null
if ($sum.system) {
  $system = [ordered]@{
    display = $sum.system.display; devices_with_problems = $sum.system.devices_with_problems; power = $sum.system.power; notes = $sum.system.notes
    events_since_boot = [ordered]@{ system = $sum.system.events_since_boot.system }
  }
}
# AI 자료 요청 목록(확인 명령 R, 재현·표시 순서 S)과 규칙
$reqs = New-Object Collections.Generic.List[object]
foreach ($r in $script:AiRequests) { $o = [ordered]@{ id = $r.id; kind = $r.kind; title = $r.title; when = $r.when; minutes = $r.minutes; collects = $r.collects }; if ($r.kind -eq 'probe') { $o['command'] = Get-AiRequestCommand $r } else { $o['steps'] = $r.steps }; $reqs.Add($o) }
$payload = [ordered]@{
  tool_version = $ToolVersion; generated_at = (Get-Date).ToString('s')
  boot = $sum.boot; hardware = $sum.hardware; data_quality = $sum.data_quality
  highlights = $sum.highlights_over_provisional_thresholds; hypotheses = $sum.hypotheses; thermal = $sum.thermal_fan_analysis
  segments = $sum.segments; notes = $sum.notes; system = $system
  stats = $stats; catalog = $catalog; strCols = $strCols; csv = $csvText
  requests = $reqs.ToArray(); protocol = $script:AiProtocol; request_text_compact = (Get-AiRequestText 'compact')
}
$json = $payload | ConvertTo-Json -Depth 12 -Compress
# <script> 안에서 안전하도록 '</' 와 줄 구분 문자를 이스케이프
$json = $json.Replace('</', '<\/').Replace([string][char]0x2028, ' ').Replace([string][char]0x2029, ' ')

$html = [IO.File]::ReadAllText($template, $utf8).Replace('__PAYLOAD__', $json)
$out = Join-Path $ExportDir 'dashboard.html'
[IO.File]::WriteAllText($out, $html, $utf8)
Write-Host "[dashboard] 완료: $out  ($([math]::Round((Get-Item $out).Length / 1KB, 0)) KB)" -ForegroundColor Green
if ($Open) { Start-Process $out }
$out
