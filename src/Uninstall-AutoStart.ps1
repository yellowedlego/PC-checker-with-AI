<#
  자동 실행 제거. Install-AutoStart.ps1 이 만든 것을 모두 되돌린다.
    powershell -ExecutionPolicy Bypass -File .\src\Uninstall-AutoStart.ps1 -WhatIf     # 무엇을 지울지 미리보기
    powershell -ExecutionPolicy Bypass -File .\src\Uninstall-AutoStart.ps1             # 확인 후 제거 (기록한 데이터는 남김)
  옵션: -RemoveData(기록한 데이터까지 삭제, 되돌릴 수 없음)  -Yes  -SkipTask(파일만, 테스트용)  -Root <설치 위치>
  지우는 것: 실행 중인 수집기·트레이 종료, 작업 스케줄러 작업, 시작 폴더/바탕화면 바로가기, 앱 복사본, 설정 파일
  기본으로 남기는 것: 기록한 데이터(<설치 위치>\data)
#>
param([string]$Root, [switch]$RemoveData, [switch]$Yes, [switch]$SkipTask, [switch]$WhatIf)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AutoStart.ps1')
$P = Get-AutoPaths $Root
$task = $(if (-not $SkipTask) { Get-ScheduledTask -TaskName $script:AutoTaskName -ErrorAction SilentlyContinue } else { $null })
$procs = Get-OurProcesses $P.Src
function SizeText([string]$path) { if (Test-Path $path) { $b = (Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum; '{0:N1}MB' -f ($b / 1MB) } else { '' } }

$plan = New-Object Collections.Generic.List[string]
if ($procs.Count) { $plan.Add("실행 중인 수집기·트레이 $($procs.Count)개를 종료합니다.") }
if ($task) { $plan.Add("작업 스케줄러 작업을 삭제합니다: $($script:AutoTaskName)") }
if (-not $SkipTask -and (Test-Path $P.StartupLink)) { $plan.Add("시작 폴더 바로가기를 삭제합니다: $($P.StartupLink)") }
if (-not $SkipTask -and (Test-Path $P.DesktopLink)) { $plan.Add("바탕화면 바로가기를 삭제합니다: $($P.DesktopLink)") }
if (Test-Path $P.App) { $plan.Add("앱 복사본을 삭제합니다: $($P.App) ($(SizeText $P.App))") }
foreach ($f in $P.Settings, $P.Info) { if (Test-Path $f) { $plan.Add("파일을 삭제합니다: $f") } }
if ($RemoveData -and (Test-Path $P.Data)) { $plan.Add("★ 기록한 데이터를 삭제합니다 (되돌릴 수 없음): $($P.Data) ($(SizeText $P.Data))") }
elseif (Test-Path $P.Data) { $plan.Add("기록한 데이터는 그대로 둡니다: $($P.Data) ($(SizeText $P.Data)) — 지우려면 -RemoveData") }
if (-not ($plan | Where-Object { $_ -notmatch '^기록한 데이터는 그대로' })) { Write-Host '제거할 것이 없습니다 (설치되어 있지 않습니다).'; if ($plan.Count) { $plan | ForEach-Object { Write-Host "  $_" } }; return }

Write-Host "`n[제거 계획]" -ForegroundColor Cyan; $plan | ForEach-Object { Write-Host "  $_" }
if ($WhatIf) { Write-Host "`n(미리보기입니다. 아무것도 바꾸지 않았습니다.)" -ForegroundColor Yellow; return }
if (-not $Yes) { $a = Read-Host "`n위 내용대로 제거할까요? (y/N)"; if ($a -notmatch '^(y|yes|예|ㅛ)$') { Write-Host '취소했습니다. 아무것도 바꾸지 않았습니다.'; return } }

# 1) 먼저 부드럽게 종료 요청 (수집기: stop.flag, 트레이: tray-stop.flag), 남으면 강제 종료
if ($procs.Count) {
  New-Item -ItemType Directory -Path $P.Data -Force | Out-Null
  New-Item -ItemType File -Path (Join-Path $P.Data 'stop.flag') -Force | Out-Null; New-Item -ItemType File -Path (Join-Path $P.Root 'tray-stop.flag') -Force | Out-Null
  for ($i = 0; $i -lt 20 -and (Get-OurProcesses $P.Src).Count; $i++) { Start-Sleep -Milliseconds 700 }
  foreach ($pr in (Get-OurProcesses $P.Src)) { Stop-Process -Id $pr.ProcessId -Force -ErrorAction SilentlyContinue }
  Remove-Item (Join-Path $P.Data 'stop.flag'), (Join-Path $P.Root 'tray-stop.flag') -Force -ErrorAction SilentlyContinue
  Write-Host '✓ 실행 중이던 수집기·트레이를 종료했습니다.'
}
# 2) 자동 실행 해제
if ($task) { Unregister-ScheduledTask -TaskName $script:AutoTaskName -Confirm:$false; Write-Host "✓ 작업 스케줄러 작업을 삭제했습니다." }
if (-not $SkipTask) { foreach ($l in $P.StartupLink, $P.DesktopLink) { if (Test-Path $l) { Remove-Item $l -Force; Write-Host "✓ 바로가기를 삭제했습니다: $l" } } }
# 3) 파일
if (Test-Path $P.App) { Remove-Item $P.App -Recurse -Force; Write-Host "✓ 앱 복사본을 삭제했습니다." }
foreach ($f in $P.Settings, $P.Info) { if (Test-Path $f) { Remove-Item $f -Force } }
if ($RemoveData -and (Test-Path $P.Data)) { Remove-Item $P.Data -Recurse -Force; Write-Host '✓ 기록한 데이터를 삭제했습니다.' }
if ((Test-Path $P.Root) -and -not (Get-ChildItem $P.Root -Force | Select-Object -First 1)) { Remove-Item $P.Root -Force }
Write-Host "`n제거 완료." -ForegroundColor Green
