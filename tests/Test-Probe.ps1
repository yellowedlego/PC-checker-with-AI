<#
  AI 자료 요청 명령 모음(RequestCatalog.ps1, Probe.ps1)과 그 연결(내보내기·가벼운 팩·대시보드)을 검증한다.
    powershell -ExecutionPolicy Bypass -File .\tests\Test-Probe.ps1 [-Quick]
  -Quick: 오래 걸리는 확인 명령(network, startup, drivers)은 실제로 실행하지 않는다.
  확인 명령은 이 PC의 정보를 읽기만 한다(설정 변경 없음). 외부로는 아무것도 보내지 않는다.
#>
param([switch]$Quick)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent; $src = Join-Path $root 'src'
$utf8 = New-Object Text.UTF8Encoding $false
$script:fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Info = '') { if ($Ok) { Write-Host "PASS  $Name" -ForegroundColor Green } else { Write-Host "FAIL  $Name  $Info" -ForegroundColor Red; $script:fail++ } }
. (Join-Path $src 'Common.ps1'); . (Join-Path $src 'RequestCatalog.ps1')
$probeText = [IO.File]::ReadAllText((Join-Path $src 'Probe.ps1'), $utf8)

# ---------------- 카탈로그 일관성 ----------------
Write-Host '--- 카탈로그' -ForegroundColor Cyan
$ids = @($script:AiRequests | ForEach-Object { $_.id })
Check '요청 번호가 중복되지 않음' (($ids | Select-Object -Unique).Count -eq $ids.Count)
Check '확인 명령 R1~R12 + 순서 S1~S4' ((@($ids | Where-Object { $_ -like 'R*' }).Count -eq 12) -and (@($ids | Where-Object { $_ -like 'S*' }).Count -eq 4))
$probes = @($script:AiRequests | Where-Object { $_.kind -eq 'probe' })
$missing = @($probes | Where-Object { $probeText -notmatch ('function Probe-' + [regex]::Escape((Get-Culture).TextInfo.ToTitleCase($_.name)) + '\b') } | ForEach-Object { $_.name })
Check '모든 확인 명령이 Probe.ps1 에 구현되어 있음' ($missing.Count -eq 0) ($missing -join ',')
Check '모든 요청에 언제/얻는 것/걸리는 시간이 적혀 있음' (@($script:AiRequests | Where-Object { -not $_.when -or -not $_.collects -or -not $_.minutes }).Count -eq 0)
Check '재현·표시 순서에 단계가 있음' (@($script:AiRequests | Where-Object { $_.kind -eq 'scenario' -and $_.steps.Count -lt 1 }).Count -eq 0)
Check "모든 확인 명령에 한 줄 설명(AiShort)이 있음" (@($probes | Where-Object { -not $script:AiShort[$_.id] }).Count -eq 0)
$compact = Get-AiRequestText 'compact'
Check "규칙: '목록에 없는 명령을 만들지 말 것'" (($script:AiProtocol -join ' ') -match '목록에 없는 명령' -and ($script:AiProtocol -join ' ') -match '최대 3개')
Check '규칙: 개인정보를 요구하지 말 것' (($script:AiProtocol -join ' ') -match '개인정보는 요구하지')
Check '가벼운 팩용 목록에 모든 R 번호와 S 순서의 명령이 있음' ((@($probes | Where-Object { $compact -notmatch ('\b' + $_.id + '\b') }).Count -eq 0) -and $compact -match 'Mark\.ps1 start' -and $compact -match 'Mark\.ps1 note' -and $compact -match 'Make-Report\.ps1')
Check '가벼운 팩용 목록 크기 2KB 이내' ($utf8.GetByteCount($compact) -le 2200) "bytes=$($utf8.GetByteCount($compact))"
Check '전체 목록(full)에 규칙과 모든 요청이 있음' ((Get-AiRequestText 'full') -match '## 요청 규칙' -and (@($ids | Where-Object { (Get-AiRequestText 'full') -notmatch ('### ' + $_ + '\.') }).Count -eq 0))

# ---------------- 마스킹 단위 테스트 ----------------
Write-Host '--- 마스킹' -ForegroundColor Cyan
$a = Protect-Text "Application 'C:\Program Files\My App\x64\svc.exe' (pid 1) cannot restart"
Check '따옴표로 감싼 경로(공백 포함)를 통째로 지움' ($a -notmatch 'Program' -and $a -match '<경로>') $a
$a = Protect-Text 'for the file \Device\HarddiskVolumeShadowCopy51\Foo and \\?\GLOBALROOT\Device\X1 failed'
Check '장치 경로를 지움' ($a -notmatch 'Harddisk' -and $a -notmatch 'GLOBALROOT') $a
$a = Protect-Text 'saved to D:\games\a.log then mail me@x.com from 192.168.0.5 mac aa:bb:cc:dd:ee:ff'
Check '드라이브 경로·이메일·IP·MAC을 지움' ($a -notmatch 'games' -and $a -match '<EMAIL>' -and $a -match '<IP>' -and $a -match '<MAC>') $a
$a = Protect-Text 'C:\Users\Someone\Documents\a.txt'
Check '사용자 폴더 경로를 지움' ($a -notmatch 'Someone') $a
$a = Protect-Text 'driver 4.6.5.0 ok' -PatternsOnly -NoIp
Check '-NoIp: 드라이버 버전 4.6.5.0 이 IP로 오인되지 않음' ($a -match '4\.6\.5\.0') $a
$a = Protect-Text 'driver 4.6.5.0 ok'
Check '기본 모드: IP 형태는 가림' ($a -match '<IP>') $a

# ---------------- 확인 명령 실행 (읽기 전용) ----------------
Write-Host '--- 확인 명령 실행' -ForegroundColor Cyan
$slow = 'network', 'startup', 'drivers'
$myComputer = $env:COMPUTERNAME; $myProfile = $env:USERPROFILE
foreach ($pr in $probes) {
  if ($Quick -and $pr.name -in $slow) { Write-Host "SKIP  $($pr.id) $($pr.name) (-Quick)" -ForegroundColor DarkGray; continue }
  $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $src 'Probe.ps1') $pr.name 2>&1 | Out-String
  $bytes = $utf8.GetByteCount($raw)
  Check "$($pr.id) $($pr.name): 헤더·꼬리말이 있고 4KB 이내($bytes bytes)" ($raw -match '## 확인 결과' -and $raw -match '읽기 전용 확인 명령 결과' -and $bytes -le 4200)
  Check "$($pr.id) $($pr.name): 컴퓨터 이름·사용자 폴더 경로가 없음" (($raw -notmatch [regex]::Escape($myComputer)) -and ($raw -notmatch [regex]::Escape($myProfile)) -and ($raw -notmatch '(?i)[a-z]:\\users\\(?!<USER>)'))
  # events 는 Windows 이벤트 본문(영어 문구에 'exception' 같은 단어가 정상적으로 나올 수 있음)을 보여주므로 스크립트 오류 문구만 검사한다
  $errPat = $(if ($pr.name -eq 'events') { '(?i)cannot bind|cannot index|\$null|the term .* is not recognized' } else { '(?i)exception|cannot bind|cannot index|\bnull\b|\$null|is not recognized' })
  Check "$($pr.id) $($pr.name): 스크립트 오류 문구나 비어 있는 값(null)이 없음" (-not ($raw -match $errPat))
}
$net = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $src 'Probe.ps1') list 2>&1 | Out-String
Check "list: 모든 R 번호가 보임" (@($probes | Where-Object { $net -notmatch ('\b' + $_.id + '\b') }).Count -eq 0)
$bad = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $src 'Probe.ps1') nonsense 2>&1 | Out-String; $code = $LASTEXITCODE
Check '알 수 없는 이름: 종료 코드 2 + 사용할 수 있는 이름 안내' ($code -eq 2 -and $bad -match 'display' -and $bad -match 'memory') "code=$code"
if (-not ($Quick)) { $netOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $src 'Probe.ps1') network 2>&1 | Out-String; Check 'network: 사설/공인 IP 주소가 출력에 없음' ($netOut -notmatch '\b(10|127|192\.168|172\.(1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}(\.\d{1,3})?\b') }

# ---------------- 읽기 전용 · 외부 전송 없음 (정적 점검) ----------------
Write-Host '--- 읽기 전용 점검' -ForegroundColor Cyan
$write = [regex]::Matches($probeText, '(?i)\b(Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|New-Item|Remove-Item|Set-Content|Add-Content|Out-File|Set-Service|Stop-Service|Start-Service|Restart-Service|Stop-Process|Disable-\w+|Enable-\w+|netsh|schtasks|reg\s+add|Set-NetAdapter|Set-ExecutionPolicy|Invoke-Expression|iex)\b') | ForEach-Object { $_.Value }
Check 'Probe.ps1 에 쓰기·변경·실행 동사가 없음' ($write.Count -eq 0) ($write -join ',')
Check 'Probe.ps1 에 외부 전송 코드가 없음' ($probeText -notmatch '(?i)Invoke-WebRequest|Invoke-RestMethod|WebClient|Start-BitsTransfer|Resolve-DnsName|Net\.Sockets|DownloadString|\bcurl\b|\bwget\b')
$tc = [regex]::Matches($probeText, 'Test-Connection[^\r\n]*') | ForEach-Object { $_.Value }
Check '핑은 공유기($gw)에만 보냄 (공인 주소 없음)' ($tc.Count -ge 1 -and @($tc | Where-Object { $_ -notmatch '\$gw' }).Count -eq 0 -and $probeText -notmatch '\b(8\.8\.8\.8|1\.1\.1\.1)\b') ($tc -join ' | ')
Check '클립보드는 -Copy 를 줄 때만 씀' (([regex]::Matches($probeText, 'Set-Clipboard')).Count -ge 1 -and $probeText -match 'if \(\$Copy\)')

# ---------------- 내보내기 · 가벼운 팩 · 대시보드 연결 ----------------
Write-Host '--- 연결 (내보내기 / 가벼운 팩 / 대시보드)' -ForegroundColor Cyan
. (Join-Path $PSScriptRoot 'SyntheticBoot.ps1')
$syn = New-SyntheticBoot
& (Join-Path $src 'Export-Data.ps1') -DataDir $syn.DataDir -NoSnapshot | Out-Null
$exp = (Get-ChildItem (Join-Path $syn.DataDir 'export') -Directory | Select-Object -First 1).FullName
& (Join-Path $src 'Build-LightPack.ps1') -ExportDir $exp | Out-Null
& (Join-Path $src 'Build-Dashboard.ps1') -ExportDir $exp | Out-Null
$sum = [IO.File]::ReadAllText((Join-Path $exp 'summary.json'), $utf8) | ConvertFrom-Json
Check 'summary.json: data_requests 16개 + ai_protocol' (@($sum.data_requests).Count -eq 16 -and @($sum.ai_protocol).Count -ge 4)
Check 'summary.json: 확인 명령에는 command, 순서에는 steps' ((@($sum.data_requests | Where-Object { $_.kind -eq 'probe' -and $_.command -match 'Probe\.ps1' }).Count -eq 12) -and (@($sum.data_requests | Where-Object { $_.kind -eq 'scenario' -and @($_.steps).Count -ge 1 }).Count -eq 4))
$schema = [IO.File]::ReadAllText((Join-Path $exp 'schema.md'), $utf8)
Check 'schema.md: 요청 방법 설명이 있고 개인정보 제목은 하나뿐' ($schema -match '## AI가 추가 자료를 요청하는 방법' -and ([regex]::Matches($schema, '## 개인정보')).Count -eq 1)
$md = [IO.File]::ReadAllText((Join-Path $exp 'light\summary.md'), $utf8); $mdBytes = $utf8.GetByteCount($md)
Check "가벼운 팩 summary.md: 요청 섹션이 있고 6.4KB 이내($mdBytes bytes)" ($md -match '더 필요한 자료는 이렇게 요청하세요' -and $md -match 'R1 Probe\.ps1 display' -and $mdBytes -le 6400)
Check '가벼운 팩 summary.md: 요청 섹션이 맨 앞 요약을 밀어내지 않음(원인 후보·글자 히트맵 유지)' ($md -match '\[supports\]' -and $md -match '글자 히트맵')
$html = [IO.File]::ReadAllText((Join-Path $exp 'dashboard.html'), $utf8)
Check '대시보드: 명령 모음 섹션과 복사 버튼 코드' ($html -match 'renderReqs' -and $html -match 'data-copy' -and $html -match 'AI에게 더 줄 자료')
Check '대시보드: 명령 문자열이 데이터에 들어 있음' ($html -match 'Probe\.ps1 display' -and $html -match 'Probe\.ps1 events -Hours 24')
Check '대시보드: 외부 주소·외부 스크립트 없음(오프라인 유지)' (-not ($html -match '(?i)(src|href)\s*=\s*["'']?https?://|@import|<script[^>]+\ssrc='))
Remove-Item $syn.DataDir -Recurse -Force -ErrorAction SilentlyContinue

if ($script:fail -gt 0) { Write-Host "`n$($script:fail)개 실패" -ForegroundColor Red; exit 1 } else { Write-Host "`n모두 통과" -ForegroundColor Green }
