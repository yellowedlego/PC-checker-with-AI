<#
  자동 실행 · 트레이 · 표시하기 패널을 검증한다. 이 PC의 시스템 설정(작업 스케줄러, 시작 프로그램, 바탕화면)은 건드리지 않는다.
    powershell -ExecutionPolicy Bypass -File .\tests\Test-AutoStart.ps1
  - 작업 정의는 '만들기만' 하고 등록하지 않는다. 설치/제거는 임시 폴더에 -SkipTask 로만 돌린다.
  - 패널/트레이는 화면에 띄우지 않고 컨트롤을 만든 뒤 버튼 클릭을 코드로 흉내 낸다.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent; $src = Join-Path $root 'src'
$utf8 = New-Object Text.UTF8Encoding $false
$script:fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Info = '') { if ($Ok) { Write-Host "PASS  $Name" -ForegroundColor Green } else { Write-Host "FAIL  $Name  $Info" -ForegroundColor Red; $script:fail++ } }
$tmpBase = Join-Path ([IO.Path]::GetTempPath()) ('pcc_auto_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$appRoot = Join-Path $tmpBase 'PCCheckerWithAI'; $data = Join-Path $appRoot 'data'
New-Item -ItemType Directory -Path $tmpBase -Force | Out-Null

$before = @(Get-ScheduledTask -TaskName 'PCCheckerWithAI*' -ErrorAction SilentlyContinue).Count
$startupBefore = Test-Path (Join-Path ([Environment]::GetFolderPath('Startup')) 'PC-checker-with-AI.lnk')

# ---------- 공통 함수 ----------
Write-Host '--- 공통 함수' -ForegroundColor Cyan
. (Join-Path $src 'Common.ps1')
$m = Send-Marker 'start' "OBS 켬 $($env:USERNAME)" $data
$files = @(Get-ChildItem (Join-Path $data 'cmd') -Filter '*.json')
Check '마커 전송: 명령 파일 생성' ($files.Count -eq 1)
$j = [IO.File]::ReadAllText($files[0].FullName, $utf8) | ConvertFrom-Json
Check '마커 전송: action/label 저장' ($j.action -eq 'start' -and $j.label -like 'OBS 켬*')
Check '마커 전송: 라벨 속 사용자 이름이 <USER> 로 바뀜' (($j.label -match '<USER>') -and (($j.label -replace '<USER>', '') -notmatch [regex]::Escape($env:USERNAME))) $j.label
# 수집기 상태 글
New-Item -ItemType Directory -Path $data -Force | Out-Null
function SetState($phase, $ageSec, $seg) { Write-JsonFile (Join-Path $data 'state.json') ([ordered]@{ updated = (Get-Date).AddSeconds(-$ageSec).ToString('s'); phase = $phase; open_segment = $seg }) }
Remove-Item (Join-Path $data 'state.json') -ErrorAction SilentlyContinue
Check '상태: 파일 없음 → none' ((Get-CollectorState $data).status -eq 'none')
SetState 'normal' 5 $null;       $s = Get-CollectorState $data; Check '상태: 최근 갱신 → running (● 기호)' ($s.status -eq 'running' -and $s.text.StartsWith('●')) $s.text
SetState 'segment:게임' 5 '게임'; $s = Get-CollectorState $data; Check '상태: 열린 구간 이름 표시' ($s.text -match '열린 구간: 게임')
SetState 'normal' 300 $null;     $s = Get-CollectorState $data; Check '상태: 오래된 갱신 → stale (▲ 기호)' ($s.status -eq 'stale' -and $s.text.StartsWith('▲')) $s.text
SetState 'stopped' 1 $null;      $s = Get-CollectorState $data; Check '상태: stopped (■ 기호)' ($s.status -eq 'stopped' -and $s.text.StartsWith('■'))
$set = Get-Settings $appRoot; Check '설정: 기본값(시작 알림 켜짐)' ($set.welcome_balloon -eq $true)
$set.welcome_balloon = $false; Save-Settings $set $appRoot; Check '설정: 저장 후 다시 읽기' ((Get-Settings $appRoot).welcome_balloon -eq $false)

# ---------- 작업 정의 (등록하지 않음) ----------
Write-Host '--- 작업 스케줄러 정의' -ForegroundColor Cyan
. (Join-Path $src 'AutoStart.ps1')
$t = New-AutoStartTask 'C:\Some Path\app\src\Launch.ps1' 30
Check '작업: 로그온 트리거' ($t.Triggers[0].CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger')
Check '작업: 로그온 30초 뒤 시작' ($t.Triggers[0].Delay -eq 'PT30S') "$($t.Triggers[0].Delay)"
Check '작업: 관리자 권한 아님 (RunLevel Limited)' ($t.Principal.RunLevel -eq 'Limited') "$($t.Principal.RunLevel)"
Check '작업: 현재 사용자 대화형 (SYSTEM 아님)' ($t.Principal.UserId -match [regex]::Escape($env:USERNAME) -and $t.Principal.UserId -notmatch 'SYSTEM') "$($t.Principal.UserId)"
Check '작업: 숨김 + 시간 제한 없음 + 중복 실행 무시' ($t.Settings.Hidden -and $t.Settings.ExecutionTimeLimit -eq 'PT0S' -and $t.Settings.MultipleInstances -eq 'IgnoreNew') "$($t.Settings.ExecutionTimeLimit)"
Check '작업: powershell 숨김 창 + 경로 따옴표' ($t.Actions[0].Execute -eq 'powershell.exe' -and $t.Actions[0].Arguments -match '-WindowStyle Hidden' -and $t.Actions[0].Arguments -match '"C:\\Some Path\\app\\src\\Launch\.ps1"') $t.Actions[0].Arguments
Check '작업: 배터리에서도 실행' ($t.Settings.DisallowStartIfOnBatteries -eq $false -and $t.Settings.StopIfGoingOnBatteries -eq $false)
Check '설치 위치 이름 검사: 엉뚱한 폴더 거부' ((& { try { Get-AutoPaths 'C:\Windows' | Out-Null; $false } catch { $true } }))

# ---------- 설치/제거 (미리보기 + 임시 폴더) ----------
Write-Host '--- 설치/제거' -ForegroundColor Cyan
$out = & (Join-Path $src 'Install-AutoStart.ps1') -Root $appRoot -WhatIf -DesktopShortcut 6>&1 | Out-String
Check '설치 -WhatIf: 계획을 보여줌' ($out -match '설치 계획' -and $out -match '작업 스케줄러' -and $out -match '아무것도 바꾸지 않았습니다')
Check '설치 -WhatIf: 아무것도 만들지 않음' (-not (Test-Path (Join-Path $appRoot 'app')) -and -not (Test-Path (Join-Path $appRoot 'install.json')))
& (Join-Path $src 'Install-AutoStart.ps1') -Root $appRoot -SkipTask -Yes 6>&1 | Out-Null
Check '설치(-SkipTask): 앱 복사본 생성' (Test-Path (Join-Path $appRoot 'app\src\Launch.ps1'))
Check '설치(-SkipTask): 대시보드 템플릿까지 복사' (Test-Path (Join-Path $appRoot 'app\src\dashboard\template.html'))
Check '설치(-SkipTask): install.json 기록' (Test-Path (Join-Path $appRoot 'install.json'))
$out = & (Join-Path $src 'Uninstall-AutoStart.ps1') -Root $appRoot -SkipTask -WhatIf 6>&1 | Out-String
Check '제거 -WhatIf: 계획을 보여주고 데이터는 남긴다고 안내' ($out -match '제거 계획' -and $out -match '그대로 둡니다')
Check '제거 -WhatIf: 아무것도 지우지 않음' (Test-Path (Join-Path $appRoot 'app'))
& (Join-Path $src 'Uninstall-AutoStart.ps1') -Root $appRoot -SkipTask -Yes 6>&1 | Out-Null
Check '제거: 앱 복사본·설정 삭제' (-not (Test-Path (Join-Path $appRoot 'app')) -and -not (Test-Path (Join-Path $appRoot 'settings.json')))
Check '제거: 기록한 데이터는 기본으로 남김' (Test-Path (Join-Path $data 'state.json'))
& (Join-Path $src 'Uninstall-AutoStart.ps1') -Root $appRoot -SkipTask -Yes -RemoveData 6>&1 | Out-Null
Check '제거 -RemoveData: 데이터까지 삭제' (-not (Test-Path $data))

# ---------- 패널 (화면에 띄우지 않고 버튼 클릭을 흉내) ----------
Write-Host '--- 표시하기 패널' -ForegroundColor Cyan
$panelScript = @"
`$ErrorActionPreference = 'Stop'
. '$src\UI.ps1'
`$d = '$data'; Remove-Item `$d -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Path `$d -Force | Out-Null
`$p = New-MarkerPanel `$d '$src' `$true
`$r = [ordered]@{}
function Click(`$b) { `$m = [Windows.Forms.Control].GetMethod('OnClick', [Reflection.BindingFlags]'NonPublic,Instance'); `$m.Invoke(`$b, @([EventArgs]::Empty)) | Out-Null }
Click `$p.BtnStart; `$r.emptyStartFiles = @(Get-ChildItem (Join-Path `$d 'cmd') -Filter *.json -ErrorAction SilentlyContinue).Count; `$r.emptyHint = `$p.Status.Text
`$p.TextBox.Text = '영상 재생 테스트'; Click `$p.BtnStart; Start-Sleep -Milliseconds 30
Click `$p.BtnNote; Start-Sleep -Milliseconds 30
Click `$p.BtnEnd
`$r.files = @(Get-ChildItem (Join-Path `$d 'cmd') -Filter *.json -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { `$o = Get-Content `$_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json; '{0}:{1}' -f `$o.action, `$o.label })
`$r.flash = `$p.Status.Text
`$r.controls = `$p.Form.Controls.Count; `$r.topmost = `$p.Form.TopMost
`$p.CheckTop.Checked = `$false; `$r.topmostAfterUncheck = `$p.Form.TopMost
`$r.minButtonHeight = (@(`$p.BtnStart, `$p.BtnEnd, `$p.BtnNote, `$p.BtnReport, `$p.BtnPack) | ForEach-Object { `$_.Height } | Measure-Object -Minimum).Minimum
`$p.Form.Dispose()
`$r | ConvertTo-Json -Compress
"@
$ps1 = Join-Path $tmpBase 'panel_test.ps1'; [IO.File]::WriteAllText($ps1, $panelScript, (New-Object Text.UTF8Encoding $true))
$raw = powershell -STA -NoProfile -ExecutionPolicy Bypass -File $ps1 2>&1 | Out-String
$res = $null; try { $res = ($raw.Trim().Split("`n") | Select-Object -Last 1) | ConvertFrom-Json } catch { }
Check '패널: 만들어짐(컨트롤 9개)' ($res -and $res.controls -eq 9) $raw
if ($res) {
  Check '패널: 이름이 비어 있으면 구간 시작을 막고 안내' ($res.emptyStartFiles -eq 0 -and $res.emptyHint -match '이름을 한 줄')
  Check '패널: 시작/메모/끝 버튼이 마커를 보냄' (($res.files -join '|') -match 'start:영상 재생 테스트' -and ($res.files -join '|') -match 'note:영상 재생 테스트' -and ($res.files -join '|') -match 'end:') ($res.files -join '|')
  Check '패널: 버튼 높이 36px 이상' ($res.minButtonHeight -ge 36) "$($res.minButtonHeight)"
  Check '패널: 항상 위 토글' ($res.topmost -eq $true -and $res.topmostAfterUncheck -eq $false)
}

# ---------- 트레이 (SelfTest) ----------
Write-Host '--- 트레이' -ForegroundColor Cyan
$raw = powershell -STA -NoProfile -ExecutionPolicy Bypass -File (Join-Path $src 'Start-Tray.ps1') -SelfTest -DataDir $data -AppRoot $appRoot 2>&1 | Out-String
$tr = $null; try { $tr = ($raw.Trim().Split("`n") | Select-Object -Last 1) | ConvertFrom-Json } catch { }
Check '트레이: 메뉴 구성 생성' ($tr -and $tr.menu_items.Count -ge 9) $raw
if ($tr) {
  $items = $tr.menu_items -join '|'
  Check '트레이: 대시보드 열기 / 가벼운 파일 / 표시하기 창 메뉴' ($items -match '대시보드 열기' -and $items -match '가벼운 파일' -and $items -match '표시하기 창')
  Check '트레이: 기록 켜기·끄기, 닫기 메뉴' ($items -match '기록 (켜기|끄기)' -and $items -match '이 아이콘만 닫기' -and $items -match '기록도 끄고 닫기')
  Check '트레이: 아이콘 생성 + 툴팁 63자 이내' ($tr.icon_ok -eq $true -and $tr.tooltip.Length -le 63) $tr.tooltip
}

# ---------- 스크립트 점검 ----------
Write-Host '--- 스크립트 점검' -ForegroundColor Cyan
foreach ($f in 'Launch.ps1', 'Start-Tray.ps1', 'UI.ps1', 'Make-Report.ps1', 'Show-Panel.ps1', 'AutoStart.ps1', 'Install-AutoStart.ps1', 'Uninstall-AutoStart.ps1') {
  $errs = $null; [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $src $f), [ref]$null, [ref]$errs); Check "문법 오류 없음: $f" ($errs.Count -eq 0)
}
$launch = [IO.File]::ReadAllText((Join-Path $src 'Launch.ps1'), $utf8)
Check 'Launch.ps1: 공백 경로를 따옴표로 감쌈' ($launch -match "function Q" -and $launch -match "Q \(Join-Path")
# PowerShell 은 한글도 변수 이름으로 읽는다. 큰따옴표 문자열에서 변수 바로 뒤에 한글을 붙이면 다른 변수로 해석되어 값이 사라지므로 중괄호로 변수 이름을 감싸야 한다. (이 주석은 검사에 걸리지 않도록 예시를 쓰지 않는다)
$interp = @(Get-ChildItem $root -Recurse -Include '*.ps1' -File | Where-Object { $_.FullName -notmatch '\\legacy\\' } | Select-String -Pattern '\$[A-Za-z_][A-Za-z0-9_]*[가-힣]')
Check '변수 바로 뒤에 한글이 붙은 문자열 보간이 없음' ($interp.Count -eq 0) (($interp | Select-Object -First 3 | ForEach-Object { $_.Filename + ':' + $_.LineNumber }) -join ', ')
$hits = @(Get-ChildItem $src -Filter '*.ps1' | Select-String -Pattern 'Invoke-WebRequest|Invoke-RestMethod|WebClient|Start-BitsTransfer|Net\.Sockets|DownloadString')
Check '네트워크 호출 없음 (src 의 모든 스크립트)' ($hits.Count -eq 0) (($hits | Select-Object -First 3 | ForEach-Object { $_.Filename + ':' + $_.LineNumber }) -join ', ')

# ---------- 시스템 변경 없음 확인 ----------
Write-Host '--- 시스템 변경 없음' -ForegroundColor Cyan
Check '이 PC의 작업 스케줄러에 새 작업이 생기지 않음' (@(Get-ScheduledTask -TaskName 'PCCheckerWithAI*' -ErrorAction SilentlyContinue).Count -eq $before)
Check '이 PC의 시작 폴더에 바로가기가 생기지 않음' ((Test-Path (Join-Path ([Environment]::GetFolderPath('Startup')) 'PC-checker-with-AI.lnk')) -eq $startupBefore)

Remove-Item $tmpBase -Recurse -Force -ErrorAction SilentlyContinue
if ($script:fail -gt 0) { Write-Host "`n$($script:fail)개 실패" -ForegroundColor Red; exit 1 } else { Write-Host "`n모두 통과" -ForegroundColor Green }
