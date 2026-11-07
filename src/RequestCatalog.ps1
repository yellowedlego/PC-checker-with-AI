# AI 자료 요청 카탈로그: AI가 분석 중에 새 데이터가 필요할 때 사용자에게 요청할 수 있는 '미리 정해 둔 명령' 목록.
# 원칙
#  - AI는 이 목록에 있는 번호/명령만 요청한다. 목록에 없는 명령·스크립트를 만들어 내지 않는다.
#  - 모든 확인 명령은 읽기 전용이고, 결과는 개인정보(계정·컴퓨터 이름·경로·IP·MAC·시리얼)를 가린 짧은 글이다.
#  - 사용자는 결과를 그대로 복사해 AI에게 붙여 넣는다. 도구는 아무것도 자동으로 보내지 않는다.
# 이 파일은 불러오기만 하고 아무것도 실행하지 않는다.

$script:AiRequests = @(
  @{ id = 'R1';  kind = 'probe'; name = 'display';   title = '화면·해상도 설정'; when = '화면이 잘리거나 흐릿할 때, 해상도·배율·주사율·가상 디스플레이가 의심될 때'; minutes = '1분 미만'; collects = '모니터 모델, 해상도·주사율, 그래픽 어댑터와 드라이버 버전·날짜, 가상/원격 어댑터, 배율, 하드웨어 가속 설정' }
  @{ id = 'R2';  kind = 'probe'; name = 'gpu';       title = '그래픽카드 상태'; when = '영상·게임이 끊기거나 GPU 온도·팬·성능 제한이 의심될 때'; minutes = '1분 미만'; collects = 'NVIDIA면 온도·팬·클럭·전력·성능 제한 사유·PCIe 속도(없으면 Windows가 아는 정보만)' }
  @{ id = 'R3';  kind = 'probe'; name = 'drivers';   title = '드라이버·문제 장치'; when = '드라이버 오류나 문제가 보고된 장치가 의심될 때'; minutes = '1분 미만'; collects = '문제가 보고된 장치, 그래픽·네트워크·오디오 드라이버 이름·버전·날짜' }
  @{ id = 'R4';  kind = 'probe'; name = 'startup';   title = '시작 프로그램·서비스'; when = '부팅 직후 느리거나 백그라운드 프로그램이 의심될 때'; minutes = '1분 미만'; collects = '시작 프로그램 이름(실행 경로·인자 제외), 자동 시작인데 멈춰 있는 서비스 이름' }
  @{ id = 'R5';  kind = 'probe'; name = 'events';    title = '최근 시스템 이벤트'; when = '특정 시각 전후의 오류·경고 원인을 더 보고 싶을 때 (-Hours 로 범위 조절)'; minutes = '1분 미만'; collects = '최근 N시간(기본 24)의 경고·오류 이벤트를 종류별로 묶은 상위 15개(본문은 첫 줄만, 마스킹)'; args = '-Hours 24' }
  @{ id = 'R6';  kind = 'probe'; name = 'power';     title = '전원 설정'; when = '절전·성능 제한, 노트북 배터리, 빠른 시작이 의심될 때'; minutes = '1분 미만'; collects = '활성 전원 계획 이름, 빠른 시작·최대 절전 설정, 배터리 유무와 충전 %' }
  @{ id = 'R7';  kind = 'probe'; name = 'disks';     title = '저장장치 상태'; when = '디스크 응답이 느리거나 용량 부족이 의심될 때'; minutes = '1분 미만'; collects = '디스크 모델·종류·크기·상태, 드라이브별 여유 공간 (SMART 상세는 관리자 권한이 필요해 제외)' }
  @{ id = 'R8';  kind = 'probe'; name = 'memory';    title = '메모리 사용 현황'; when = '메모리 부족·커밋 비율이 높을 때, 어떤 프로그램이 메모리를 쓰는지 볼 때'; minutes = '1분 미만'; collects = '전체·남은 메모리, 커밋 비율, 페이지 파일, 메모리를 많이 쓰는 프로그램 이름 상위 N개 (-Top 으로 조절)'; args = '-Top 10' }
  @{ id = 'R9';  kind = 'probe'; name = 'processes'; title = '지금 바쁜 프로그램'; when = '지금 이 순간 CPU·메모리를 누가 쓰는지 확인할 때'; minutes = '1분 미만'; collects = 'CPU·메모리 상위 프로그램 이름과 사용량 (경로·창 제목 제외)'; args = '-Top 10' }
  @{ id = 'R10'; kind = 'probe'; name = 'network';   title = '네트워크 연결 상태'; when = '인터넷이 끊기거나 느린 것이 의심될 때'; minutes = '약 10초'; collects = '연결된 어댑터와 링크 속도, 공유기(게이트웨이)까지의 응답 시간·손실. 외부 인터넷으로는 아무것도 보내지 않고 IP·Wi-Fi 이름은 가림' }
  @{ id = 'R11'; kind = 'probe'; name = 'sensors';   title = '온도·팬 센서 확인'; when = 'CPU 온도·케이스 팬 값이 비어 있어 센서 프로그램이 켜져 있는지 확인할 때'; minutes = '1분 미만'; collects = 'LibreHardwareMonitor/OpenHardwareMonitor가 켜져 있으면 온도·팬 센서 이름과 현재 값, 없으면 켜는 방법' }
  @{ id = 'R12'; kind = 'probe'; name = 'boot';      title = '부팅·종료 기록'; when = '갑자기 꺼지거나 재부팅 직후 문제가 반복될 때'; minutes = '1분 미만'; collects = '마지막 부팅 시각, 켜져 있던 시간, 최근 30일의 비정상 종료·재부팅 이벤트 시각' }
  @{ id = 'S1';  kind = 'scenario'; title = '증상 재현 구간 기록'; when = '증상이 특정 프로그램·상황에서만 나타나는지 가릴 때'; minutes = '증상이 나타나는 동안(최대 60분)'; collects = '구간 동안 평소(구간 밖)와 얼마나 달랐는지 비교';
     steps = @('(1) 수집기가 켜져 있는지 확인하세요 (트레이 아이콘 또는 Start-Collector.ps1)', '(2) 구간 시작:  powershell -ExecutionPolicy Bypass -File .\src\Mark.ps1 start "<상황 이름, 개인정보 제외>"', '(3) 증상이 나타나는 일을 하세요 (예: 문제가 있는 영상 재생)', '(4) 구간 끝:  powershell -ExecutionPolicy Bypass -File .\src\Mark.ps1 end', '(5) 새 리포트:  powershell -ExecutionPolicy Bypass -File .\src\Make-Report.ps1 -Pack light  → light 폴더를 AI에게 첨부') }
  @{ id = 'S2';  kind = 'scenario'; title = '증상 순간 메모'; when = '증상이 갑자기 나타났다 사라질 때, 그 시각을 표시하고 싶을 때'; minutes = '즉시 (이후 5분간 촘촘히 기록)'; collects = '메모 시각 전후 5분 비교';
     steps = @('(1) 증상이 보이는 순간:  powershell -ExecutionPolicy Bypass -File .\src\Mark.ps1 note "<무엇이 보였나, 개인정보 제외>"', '(2) 5분쯤 뒤 새 리포트:  powershell -ExecutionPolicy Bypass -File .\src\Make-Report.ps1 -Pack light') }
  @{ id = 'S3';  kind = 'scenario'; title = 'CPU 온도·케이스 팬까지 포함해 다시 기록'; when = '온도·팬 데이터가 비어 있어 팬 소음 문제를 가릴 수 없을 때'; minutes = '30분 이상(부하와 식는 구간이 모두 있게)'; collects = 'CPU 온도, 케이스 팬 회전수, 팬 통합값';
     steps = @('(1) 무료 프로그램 LibreHardwareMonitor(또는 OpenHardwareMonitor)를 실행해 두세요. 이 도구에는 포함되어 있지 않습니다.', '(2) 확인:  powershell -ExecutionPolicy Bypass -File .\src\Probe.ps1 sensors  (값이 나오면 성공)', '(3) 평소처럼 쓰거나 팬 소음이 날 만한 일(게임·영상 편집 등)을 한 뒤, 식을 때까지 30분 이상 두세요.', '(4) 새 리포트:  powershell -ExecutionPolicy Bypass -File .\src\Make-Report.ps1 -Pack light') }
  @{ id = 'S4';  kind = 'scenario'; title = '지금 상태로 새 리포트 만들기'; when = '시간이 지나 데이터가 더 쌓였거나 설정을 바꾼 뒤 다시 볼 때'; minutes = '약 10~40초'; collects = '가장 최근 기록으로 만든 요약·그림';
     steps = @('(1) powershell -ExecutionPolicy Bypass -File .\src\Make-Report.ps1 -Pack light  → light 폴더를 AI에게 첨부') }
)

# AI가 따라야 할 요청 규칙 (summary.md / summary.json / 복사 텍스트 / 대시보드에 같은 문구를 쓴다)
$script:AiProtocol = @(
  '더 필요한 자료가 있으면 아래 "요청 목록"의 번호(R1~R12, S1~S4)와 그 명령만 요청하세요. 목록에 없는 명령·스크립트를 만들어 내지 마세요.',
  '목록에 없는 정보가 필요하면 명령을 만들지 말고, 어떤 정보가 왜 필요한지 말로 설명하세요.',
  '한 번에 최대 3개까지만 요청하고, 요청마다 "무엇을 확인하려는지" 한 줄을 적으세요. 형식 예: [요청] R1 — 해상도가 모니터 기본값과 다른지 확인하려고요.',
  '비밀번호·계정·파일 경로·IP 같은 개인정보는 요구하지 마세요. 결과는 사용자가 그대로 복사해 붙여 넣습니다.',
  'R로 시작하는 요청은 읽기 전용 확인 명령이고, S로 시작하는 요청은 사용자가 증상을 재현하거나 표시하는 순서입니다.'
)

# 가벼운 팩(summary.md)용 한 줄 설명
$script:AiShort = @{ R1 = '화면 잘림·해상도·배율'; R2 = 'GPU 온도·팬·성능 제한'; R3 = '드라이버·문제 장치'; R4 = '시작 프로그램·서비스'; R5 = '시각별 오류 이벤트'; R6 = '절전·전원 설정'; R7 = '디스크 상태·용량'; R8 = '메모리 쓰는 프로그램'; R9 = '지금 바쁜 프로그램'; R10 = '네트워크 끊김·지연'; R11 = 'CPU 온도·팬 센서 유무'; R12 = '비정상 종료·재부팅' }

function Get-AiRequestCommand($Request, [switch]$Short) {
  if ($Request.kind -ne 'probe') { return $null }
  $a = $(if ($Request.args) { ' ' + $Request.args } else { '' })
  if ($Short) { return "Probe.ps1 $($Request.name)$a" }
  "powershell -ExecutionPolicy Bypass -File .\src\Probe.ps1 $($Request.name)$a"
}

# 사람이 읽는 목록. Style: compact(한 줄씩, 가벼운 팩용) / full(설명 포함)
function Get-AiRequestText([ValidateSet('compact', 'full')][string]$Style = 'full') {
  $L = New-Object Collections.Generic.List[string]
  if ($Style -eq 'full') {
    $L.Add('## 요청 규칙 (AI용)'); foreach ($p in $script:AiProtocol) { $L.Add("- $p") }
    $L.Add(''); $L.Add('## 요청 목록'); $L.Add('도구 폴더(src 폴더가 있는 곳)에서 PowerShell을 열어 실행합니다. 모든 R 명령은 읽기 전용이고 결과는 개인정보를 가린 짧은 글입니다.'); $L.Add('')
    foreach ($r in $script:AiRequests) {
      $L.Add("### $($r.id). $($r.title)"); $L.Add("- 언제: $($r.when)"); $L.Add("- 걸리는 시간: $($r.minutes)"); $L.Add("- 얻는 것: $($r.collects)")
      if ($r.kind -eq 'probe') { $L.Add("- 명령: ``$(Get-AiRequestCommand $r)``") } else { $L.Add('- 순서:'); foreach ($s in $r.steps) { $L.Add("  - $s") } }
      $L.Add('')
    }
  } else {
    foreach ($p in $script:AiProtocol[0..3]) { $L.Add("- $p") }
    $L.Add('요청 목록 (도구 폴더에서 `powershell -ExecutionPolicy Bypass -File .\src\` + 아래 명령. 읽기 전용, 결과는 마스킹됨):')
    foreach ($r in ($script:AiRequests | Where-Object { $_.kind -eq 'probe' })) { $L.Add("- $($r.id) $(Get-AiRequestCommand $r -Short) — $($script:AiShort[$r.id])") }
    $L.Add('- S1 증상 재현: `Mark.ps1 start "<이름>"` → 증상 재현 → `Mark.ps1 end` → `Make-Report.ps1 -Pack light`')
    $L.Add('- S2 순간 메모: `Mark.ps1 note "<무엇이 보였나>"` → 5분 뒤 `Make-Report.ps1 -Pack light`')
    $L.Add('- S3 센서 프로그램(LibreHardwareMonitor) 켜고 R11로 확인 → 30분 이상 재기록 → `Make-Report.ps1 -Pack light`')
    $L.Add('- S4 새 리포트: `Make-Report.ps1 -Pack light`')
  }
  $L -join "`n"
}
