<#
  구간/메모 마커. AI가 "OO 프로그램을 켜 보세요"라고 하면 시작-끝으로 감싸고, 증상이 나타난 순간엔 note 를 남긴다.
    .\Mark.ps1 start "OBS 켬"     # 구간 시작 (끝낼 때까지 촘촘히 기록, 최대 60분)
    .\Mark.ps1 end                # 구간 끝
    .\Mark.ps1 note "화면 잘림"   # 순간 메모 (이후 5분간 촘촘히 기록)
  수집기(Start-Collector.ps1)가 켜져 있어야 반영된다. 라벨에 개인정보를 쓰지 마세요.
  (트레이 아이콘의 '표시하기 창'에서도 같은 일을 버튼으로 할 수 있다.)
#>
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('start', 'end', 'note')][string]$Action,
  [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$Label,
  [string]$DataDir
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$obj = Send-Marker $Action ($Label -join ' ') $DataDir
Write-Host ("마커 전달: {0} {1}" -f $Action, $obj.label)
