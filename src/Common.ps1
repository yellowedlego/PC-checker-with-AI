# 공통 함수 (수집 엔진/마커/이후 단계에서 공유)
# 원칙: 사람이나 그 사람의 활동 내용을 알 수 있는 값은 수집하지 않는다. (README '수집하지 않는 것' 참고)

$script:Inv = [Globalization.CultureInfo]::InvariantCulture

function Get-DefaultDataDir {
  Join-Path $env:LOCALAPPDATA 'PCCheckerWithAI\data'
}

# 텍스트에서 사용자 이름/컴퓨터 이름을 지운다. 이벤트 메시지 등 자유 텍스트를 저장하기 전에 반드시 통과시킨다.
function Protect-Text([string]$Text) {
  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  $t = $Text
  foreach ($pair in @(@($env:USERNAME, '<USER>'), @($env:COMPUTERNAME, '<PC>'))) {
    if ($pair[0] -and $pair[0].Length -ge 2) { $t = [regex]::Replace($t, [regex]::Escape($pair[0]), $pair[1], 'IgnoreCase') }
  }
  # 사용자 폴더 경로, 이메일, IPv4, MAC 형태는 값 자체를 지운다
  $t = [regex]::Replace($t, '(?i)[a-z]:\\users\\[^\\\s"'']+', 'C:\Users\<USER>')
  $t = [regex]::Replace($t, '[\w\.\-+]+@[\w\-]+\.[\w\.\-]+', '<EMAIL>')
  $t = [regex]::Replace($t, '\b\d{1,3}(\.\d{1,3}){3}\b', '<IP>')
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
