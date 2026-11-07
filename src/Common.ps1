# 공통 함수 (수집 엔진/마커/이후 단계에서 공유)
# 원칙: 사람이나 그 사람의 활동 내용을 알 수 있는 값은 수집하지 않는다. (README '데이터와 개인정보' 참고)

$script:Inv = [Globalization.CultureInfo]::InvariantCulture

function Get-DefaultDataDir {
  Join-Path $env:LOCALAPPDATA 'PCCheckerWithAI\data'
}

# 텍스트에서 사용자 이름/컴퓨터 이름을 지운다. 이벤트 메시지 등 자유 텍스트를 저장하기 전에 반드시 통과시킨다.
# -PatternsOnly: 프로세스 이름/제조사/설명처럼 계정명이 들어갈 일이 없는 필드용. 이름 치환은 건너뛰고 경로/이메일/IP/MAC 형태만 지운다.
# 이름 치환은 '단어 경계'에서만 한다 (예: 사용자 이름이 User 일 때 RtkAudUService64 같은 이름은 건드리지 않음).
# -NoIp: IPv4 형태 치환을 끈다 (드라이버 버전 4.6.5.0 같은 값이 <IP>로 가려지는 것을 막을 때. IP를 직접 출력하지 않는 곳에서만 쓴다)
function Protect-Text([string]$Text, [switch]$PatternsOnly, [switch]$NoIp) {
  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  $t = $Text
  if (-not $PatternsOnly) {
    foreach ($pair in @(@($env:USERNAME, '<USER>'), @($env:COMPUTERNAME, '<PC>'))) {
      if ($pair[0] -and $pair[0].Length -ge 2) { $t = [regex]::Replace($t, '(?<![A-Za-z0-9])' + [regex]::Escape($pair[0]) + '(?![A-Za-z0-9])', $pair[1], 'IgnoreCase') }
    }
  }
  if (-not $PatternsOnly) {   # 자유 텍스트(이벤트 본문·라벨)에서는 드라이브/장치 경로를 통째로 지운다 (README: 파일·폴더 경로는 수집하지 않음)
    $t = [regex]::Replace($t, '(?i)([''"])[a-z]:\\.*?\1', '$1<경로>$1')   # 따옴표로 감싼 경로는 공백이 있어도 통째로
    $t = [regex]::Replace($t, '(?i)\\\\\?\\[^\s"'']+', '<경로>')
    $t = [regex]::Replace($t, '(?i)\\Device\\[^\s"'']+', '<경로>')
    $t = [regex]::Replace($t, '(?i)\b[a-z]:\\\S*', '<경로>')               # 따옴표 없는 경로는 공백 전까지
  }
  # 사용자 폴더 경로, 이메일, IPv4, MAC 형태는 값 자체를 지운다
  $t = [regex]::Replace($t, '(?i)[a-z]:\\users\\[^\\\s"'']+', 'C:\Users\<USER>')
  $t = [regex]::Replace($t, '[\w\.\-+]+@[\w\-]+\.[\w\.\-]+', '<EMAIL>')
  if (-not $NoIp) { $t = [regex]::Replace($t, '\b\d{1,3}(\.\d{1,3}){3}\b', '<IP>') }
  $t = [regex]::Replace($t, '\b([0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}\b', '<MAC>')
  $t
}

function Add-JsonLine([string]$Path, $Object) {
  $json = $Object | ConvertTo-Json -Depth 6 -Compress
  [IO.File]::AppendAllText($Path, $json + "`n", (New-Object Text.UTF8Encoding $false))
}

function Write-JsonFile([string]$Path, $Object) {
  $json = $Object | ConvertTo-Json -Depth 6
  [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}

function ConvertTo-Number($v) {
  $d = 0.0
  if ($null -ne $v -and [double]::TryParse(("$v").Trim(), [Globalization.NumberStyles]::Float, $script:Inv, [ref]$d)) { return $d }
  $null
}

function Get-Percentile([double[]]$Sorted, [double]$P) {
  if ($Sorted.Count -eq 0) { return $null }
  $i = [int][math]::Min($Sorted.Count - 1, [math]::Floor($Sorted.Count * $P))
  $Sorted[$i]
}

# nvidia-smi clocks_throttle_reasons.active 비트마스크 해석
function ConvertFrom-ThrottleMask([string]$Hex) {
  try { $v = [Convert]::ToUInt64(($Hex.Trim() -replace '^0x', ''), 16) } catch { return $null }
  if ($v -eq 0) { return 'none' }
  $map = [ordered]@{ 1 = 'idle'; 2 = 'app_clocks'; 4 = 'sw_power_cap'; 8 = 'hw_slowdown'; 16 = 'sync_boost'; 32 = 'sw_thermal'; 64 = 'hw_thermal'; 128 = 'power_brake'; 256 = 'display_clock' }
  $names = New-Object Collections.Generic.List[string]; $rest = $v
  foreach ($k in $map.Keys) { if ($v -band [uint64]$k) { $names.Add($map[$k]); $rest = $rest -band (-bnot [uint64]$k) } }
  if ($rest -ne 0) { $names.Add(('0x{0:X}' -f $rest)) }
  $names -join '+'
}

# ---------------- 앱 위치 / 설정 / 마커 / 수집기 상태 (트레이·패널·설치 스크립트가 공유) ----------------
function Get-AppRoot { Join-Path $env:LOCALAPPDATA 'PCCheckerWithAI' }

# 구간/메모 마커를 수집기에 전달한다 (Mark.ps1 과 표시하기 패널이 같은 함수를 쓴다). 라벨은 저장 전에 마스킹한다.
function Send-Marker([string]$Action, [string]$Label, [string]$DataDir) {
  if (-not $DataDir) { $DataDir = Get-DefaultDataDir }
  $cmd = Join-Path $DataDir 'cmd'; New-Item -ItemType Directory -Path $cmd -Force | Out-Null
  $obj = [ordered]@{ action = $Action; label = (Protect-Text ([string]$Label).Trim()); at = (Get-Date).ToString('s') }
  $name = '{0}_{1}.json' -f (Get-Date).ToString('yyyyMMdd_HHmmss_fff'), $Action
  Write-JsonFile (Join-Path $cmd $name) $obj
  $obj
}

# 수집기 상태를 사람이 읽는 글로 (색이 아니라 기호+글자로 구분): running / stale / stopped / none
function Get-CollectorState([string]$DataDir) {
  if (-not $DataDir) { $DataDir = Get-DefaultDataDir }
  $p = Join-Path $DataDir 'state.json'
  if (-not (Test-Path $p)) { return @{ status = 'none'; text = '■ 아직 기록을 시작하지 않았어요'; open_segment = $null } }
  try { $s = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return @{ status = 'none'; text = '■ 상태 파일을 읽지 못했어요'; open_segment = $null } }
  $age = (Get-Date) - [datetime]$s.updated
  $seg = $(if ($s.open_segment) { [string]$s.open_segment } else { $null })
  if ($s.phase -eq 'stopped') { return @{ status = 'stopped'; text = '■ 기록이 멈춰 있어요'; open_segment = $seg } }
  if ($age.TotalSeconds -gt 45) { return @{ status = 'stale'; text = ('▲ 기록이 {0}분째 갱신되지 않아요' -f [math]::Max(1, [math]::Round($age.TotalMinutes))); open_segment = $seg } }
  $ph = switch -Wildcard ([string]$s.phase) { 'boot_settle' { '부팅 직후' } 'baseline' { '기준선' } 'normal' { '일반' } 'segment:*' { '구간 기록' } default { [string]$s.phase } }
  @{ status = 'running'; text = ('● 기록 중 · {0}{1}' -f $ph, $(if ($seg) { " · 열린 구간: $seg" } else { '' })); open_segment = $seg }
}

function Get-Settings([string]$Root) {
  if (-not $Root) { $Root = Get-AppRoot }
  $s = @{ welcome_balloon = $true; last_welcome_boot = ''; panel_topmost = $true }
  $p = Join-Path $Root 'settings.json'
  if (Test-Path $p) { try { $o = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json; foreach ($k in @($s.Keys)) { if ($null -ne $o.$k) { $s[$k] = $o.$k } } } catch { } }
  $s
}
function Save-Settings($Settings, [string]$Root) {
  if (-not $Root) { $Root = Get-AppRoot }
  New-Item -ItemType Directory -Path $Root -Force | Out-Null
  Write-JsonFile (Join-Path $Root 'settings.json') $Settings
}
