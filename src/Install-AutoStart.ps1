<#
  로그온 시 자동 실행 설치. 이 PC에 남는 설정을 만들므로, 무엇을 만드는지 먼저 보여주고 확인을 받는다.
    powershell -ExecutionPolicy Bypass -File .\src\Install-AutoStart.ps1 -WhatIf          # 미리보기 (아무것도 바꾸지 않음)
    powershell -ExecutionPolicy Bypass -File .\src\Install-AutoStart.ps1                  # 확인 질문 후 설치
  옵션: -Method Task|Startup  -DesktopShortcut  -StartNow  -Yes(질문 없이)  -SkipTask(파일 복사만, 테스트용)  -Root <설치 위치>

  만드는 것 (관리자 권한 불필요, 네트워크 전송 없음)
    1) %LOCALAPPDATA%\PCCheckerWithAI\app\src   스크립트 복사본 (이 저장소 폴더를 옮겨도 계속 동작)
    2) 로그온 시 실행: 작업 스케줄러 작업 'PCCheckerWithAI-Logon' (현재 사용자, 숨김).
       작업 스케줄러 등록이 거부되면 시작 폴더 바로가기로 대신한다.
    3) (선택) 바탕화면 바로가기 '표시하기'
  제거:  .\src\Uninstall-AutoStart.ps1   (기록한 데이터는 -RemoveData 를 줘야만 지운다)
#>
param(
  [string]$Root,
  [ValidateSet('Task', 'Startup')][string]$Method = 'Task',
  [switch]$DesktopShortcut, [switch]$StartNow, [switch]$SkipTask, [switch]$Yes, [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AutoStart.ps1')
$P = Get-AutoPaths $Root
$existing = $(if (-not $SkipTask) { Get-ScheduledTask -TaskName $script:AutoTaskName -ErrorAction SilentlyContinue } else { $null })

$plan = New-Object Collections.Generic.List[string]
$plan.Add("1) 스크립트 복사본을 만듭니다: $($P.Src)")
if ($SkipTask) { $plan.Add('2) (-SkipTask) 자동 실행 등록은 건너뜁니다.') }
elseif ($Method -eq 'Task') { $plan.Add("2) 로그온 때 실행되는 작업 스케줄러 작업을 등록합니다: '$($script:AutoTaskName)' (현재 사용자 권한, 숨김, 로그온 30초 뒤)$(if ($existing) { ' ← 이미 있어서 덮어씁니다' })"); $plan.Add("   (등록이 거부되면 시작 폴더 바로가기로 대신합니다: $($P.StartupLink))") }
else { $plan.Add("2) 시작 폴더에 바로가기를 만듭니다: $($P.StartupLink)") }
if ($DesktopShortcut) { $plan.Add("3) 바탕화면에 '표시하기' 바로가기를 만듭니다: $($P.DesktopLink)") }
$plan.Add("기록 데이터는 $($P.Data) 에 저장됩니다. 관리자 권한은 쓰지 않고, 아무것도 외부로 보내지 않습니다.")
$plan.Add('언제든 Uninstall-AutoStart.ps1 로 되돌릴 수 있습니다.')

Write-Host "`n[설치 계획]" -ForegroundColor Cyan; $plan | ForEach-Object { Write-Host "  $_" }
if ($WhatIf) { Write-Host "`n(미리보기입니다. 아무것도 바꾸지 않았습니다.)" -ForegroundColor Yellow; return }
if (-not $Yes) { $a = Read-Host "`n위 내용대로 설치할까요? (y/N)"; if ($a -notmatch '^(y|yes|예|ㅛ)$') { Write-Host '취소했습니다. 아무것도 바꾸지 않았습니다.'; return } }

# 1) 복사
$n = Copy-AppFiles $PSScriptRoot $P.App
Write-Host "✓ 스크립트 $n개를 복사했습니다: $($P.Src)"
$used = 'none'
# 2) 자동 실행
if (-not $SkipTask) {
  if ($Method -eq 'Task') {
    try {
      $task = New-AutoStartTask $P.Launch
      Register-ScheduledTask -TaskName $script:AutoTaskName -InputObject $task -Force | Out-Null
      $used = 'task'; Write-Host "✓ 작업 스케줄러에 등록했습니다: $($script:AutoTaskName)"
    } catch {
      Write-Warning "작업 스케줄러 등록이 거부됐습니다 ($($_.Exception.Message.Trim())). 시작 폴더 바로가기로 대신합니다."
      $Method = 'Startup'
    }
  }
  if ($Method -eq 'Startup') {
    New-Shortcut $P.StartupLink 'powershell.exe' ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $P.Launch) 7 'PC-checker-with-AI: 로그온 시 PC 상태 기록 시작'
    $used = 'startup'; Write-Host "✓ 시작 폴더에 바로가기를 만들었습니다: $($P.StartupLink)"
  }
}
# 3) 바탕화면 바로가기
$desktop = $false
if ($DesktopShortcut) { New-Shortcut $P.DesktopLink 'powershell.exe' ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File "{0}"' -f $P.Panel) 1 'PC 상태 기록: 구간·메모 표시하기'; $desktop = $true; Write-Host "✓ 바탕화면 바로가기를 만들었습니다." }
Write-JsonFile $P.Info ([ordered]@{ installed_at = (Get-Date).ToString('s'); method = $used; task_name = $script:AutoTaskName; desktop_shortcut = $desktop; app_dir = $P.App })
if ($StartNow -and -not $SkipTask) { Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $P.Launch + '"')) -WindowStyle Hidden; Write-Host '✓ 지금 바로 기록을 시작했습니다 (트레이 아이콘을 확인하세요).' }
Write-Host "`n설치 완료. 다음 로그온부터 자동으로 시작됩니다. 되돌리기: Uninstall-AutoStart.ps1" -ForegroundColor Green
