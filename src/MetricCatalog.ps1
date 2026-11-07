# 지표 사전: 키 이름 -> 단위/설명/임시 기준
# 모든 기준(warn/hot)은 '일반적인 임시 값'이다. 기기별 정상 범위와 다를 수 있으며, 원인 판단이 아니라 읽는 순서를 돕는 표시일 뿐이다.
#   direction: 'high' = 값이 클수록 주의, 'low' = 값이 작을수록 주의, 'none' = 기준 없음
#   scale:     'absolute' = 절대 기준으로 색을 입힘, 'relative' = 그 PC의 최소~최대로 색을 입힘

$script:MetricRules = @(
  @{ re = '^cpu\.util$';                  unit = '%';     desc = 'CPU 전체 사용률(Processor Utility 기준, 100 초과 가능)'; direction = 'high'; warn = 80; hot = 95; scale = 'absolute' }
  @{ re = '^cpu\.perf_pct$';              unit = '%';     desc = 'CPU 성능 비율. 100=기본 클럭, 100 초과=부스트, 낮으면 절전/제한'; direction = 'none'; scale = 'relative' }
  @{ re = '^cpu\.dpc$';                   unit = '%';     desc = '드라이버 지연 처리(DPC)에 쓰인 CPU 시간. 지속적으로 높으면 드라이버 문제 후보'; direction = 'high'; warn = 5; hot = 15; scale = 'absolute' }
  @{ re = '^cpu\.interrupt$';             unit = '%';     desc = '하드웨어 인터럽트 처리 시간'; direction = 'high'; warn = 5; hot = 15; scale = 'absolute' }
  @{ re = '^cpu\.core\.';                 unit = '%';     desc = 'CPU 논리 코어별 사용률(코어 번호 = 프로세서그룹_번호)'; direction = 'high'; warn = 90; hot = 100; scale = 'absolute' }
  @{ re = '^cpu\.core_';                  unit = '';      desc = '코어 요약(파생)'; direction = 'none'; scale = 'absolute' }
  @{ re = '^mem\.avail_mb$';              unit = 'MB';    desc = '사용 가능한 메모리'; direction = 'low'; warn = 2048; hot = 1024; scale = 'absolute' }
  @{ re = '^mem\.commit_pct$';            unit = '%';     desc = '커밋된 메모리 / 커밋 한도(물리 메모리 + 페이지 파일). 높으면 메모리 압박 후보'; direction = 'high'; warn = 80; hot = 95; scale = 'absolute' }
  @{ re = '^mem\.pages_per_sec$';         unit = '개/초'; desc = '초당 페이지 입출력(디스크로 오가는 메모리 페이지)'; direction = 'high'; warn = 500; hot = 2000; scale = 'absolute' }
  @{ re = '^disk\..*\.busy$';             unit = '%';     desc = '디스크 사용 시간 비율'; direction = 'high'; warn = 70; hot = 95; scale = 'absolute' }
  @{ re = '^disk\..*\.queue$';            unit = '개';    desc = '디스크 대기열 길이'; direction = 'high'; warn = 2; hot = 8; scale = 'absolute' }
  @{ re = '^disk\..*\.latency_ms$';       unit = 'ms';    desc = '디스크 요청당 평균 응답 시간(SSD 기준. HDD는 더 큼)'; direction = 'high'; warn = 20; hot = 100; scale = 'absolute' }
  @{ re = '^net\..*\.kbps$';              unit = 'KB/s';  desc = '네트워크 어댑터 송수신 합계 처리량'; direction = 'none'; scale = 'relative' }
  @{ re = '^gpu\.engine\.';               unit = '%';     desc = 'GPU 엔진 종류별 사용률(모든 프로세스 합, 최대 100). 3D=그래픽, VideoDecode=영상 재생 디코딩'; direction = 'high'; warn = 85; hot = 98; scale = 'absolute' }
  @{ re = '^gpu\.vram_used_mb$';          unit = 'MB';    desc = 'GPU 전용 메모리 사용량'; direction = 'none'; scale = 'relative' }
  @{ re = '^gpu\.shared_used_mb$';        unit = 'MB';    desc = 'GPU가 시스템 메모리에서 빌려 쓰는 양'; direction = 'none'; scale = 'relative' }
  @{ re = '^nv\.gpu\d+\.temp_c$';         unit = '°C';    desc = 'NVIDIA GPU 온도'; direction = 'high'; warn = 75; hot = 85; scale = 'absolute' }
  @{ re = '^nv\.gpu\d+\.util$';           unit = '%';     desc = 'NVIDIA GPU 사용률'; direction = 'high'; warn = 85; hot = 98; scale = 'absolute' }
  @{ re = '^nv\.gpu\d+\.mem_util$';       unit = '%';     desc = 'GPU 메모리 컨트롤러 사용률'; direction = 'high'; warn = 85; hot = 98; scale = 'absolute' }
  @{ re = '^nv\.gpu\d+\.fan_pct$';        unit = '%';     desc = 'NVIDIA GPU 팬 속도(최대 대비 %). 0은 정지 모드일 수 있음'; direction = 'none'; scale = 'absolute' }
  @{ re = '^nv\.gpu\d+\.sm_mhz$';         unit = 'MHz';   desc = 'GPU 코어 클럭'; direction = 'none'; scale = 'relative' }
  @{ re = '^nv\.gpu\d+\.mem_mhz$';        unit = 'MHz';   desc = 'GPU 메모리 클럭'; direction = 'none'; scale = 'relative' }
  @{ re = '^nv\.gpu\d+\.max_sm_mhz$';     unit = 'MHz';   desc = 'GPU 코어 최대 클럭(허용 상한)'; direction = 'none'; scale = 'relative' }
  @{ re = '^nv\.gpu\d+\.pstate$';         unit = '';      desc = 'GPU 성능 상태(P0=최고 ~ P8 이상=절전). 문자열'; direction = 'none'; scale = 'absolute' }
  @{ re = '^nv\.gpu\d+\.throttle$';       unit = '';      desc = 'GPU 클럭 제한 사유. none=없음, idle=쉬는 중, sw_power_cap/sw_thermal/hw_thermal/power_brake 등=성능 제한. 문자열'; direction = 'none'; scale = 'absolute' }
  @{ re = '^nv\.gpu\d+\.(enc|dec)_util$'; unit = '%';     desc = '영상 인코더/디코더 사용률'; direction = 'high'; warn = 85; hot = 98; scale = 'absolute' }
  @{ re = '^nv\.gpu\d+\.power_w$';        unit = 'W';     desc = 'GPU 소비 전력'; direction = 'none'; scale = 'relative' }
  @{ re = '^nv\.gpu\d+\.vram_(used|total)_mb$'; unit = 'MB'; desc = 'GPU 메모리 사용량/전체'; direction = 'none'; scale = 'relative' }
  @{ re = '^hw\.temp_c\.';                unit = '°C';    desc = '센서 프로그램이 읽은 온도'; direction = 'high'; warn = 80; hot = 90; scale = 'absolute' }
  @{ re = '^hw\.fan_rpm\.';               unit = 'RPM';   desc = '센서 프로그램이 읽은 팬 회전수'; direction = 'none'; scale = 'relative' }
  @{ re = '^hw\.fan_duty_pct\.';          unit = '%';     desc = '팬 제어 출력(듀티) %'; direction = 'none'; scale = 'absolute' }
  @{ re = '^fan_pct\.';                   unit = '%';     desc = '팬 하나의 회전수를 그 팬의 관측 최대 RPM 대비 %로 환산(파생)'; direction = 'none'; scale = 'absolute' }
  @{ re = '^fan_group\.';                 unit = '%';     desc = '같은 종류 팬들의 통합값(파생): mean_pct=평균, max_pct=가장 빠른 팬'; direction = 'none'; scale = 'absolute' }
  @{ re = '^collector\.cpu_core_pct$';    unit = '%(코어1개 기준)'; desc = '이 수집기(powershell) 자신의 CPU 사용률. 측정이 시스템에 주는 부하. WmiPrvSE 사용률의 상당 부분도 수집용 조회에서 생김'; direction = 'none'; scale = 'relative' }
  @{ re = '^collector\.wmi_host_cpu_core_pct$'; unit = '%(코어1개 기준)'; desc = 'WMI 제공자(WmiPrvSE) 프로세스들의 CPU 합. 수집 조회가 대부분이지만 다른 프로그램의 WMI 조회도 포함'; direction = 'none'; scale = 'relative' }
  @{ re = '^collector\.ram_mb$';          unit = 'MB';    desc = '이 수집기 자신의 메모리 사용량'; direction = 'none'; scale = 'relative' }
  @{ re = '^proc\.count$';                unit = '개';    desc = '실행 중인 프로세스 수'; direction = 'none'; scale = 'relative' }
  @{ re = '^proc\.top_cpu_core_pct$';     unit = '%(코어1개 기준)'; desc = 'CPU를 가장 많이 쓴 프로세스의 사용률. 100=코어 1개 전부'; direction = 'none'; scale = 'relative' }
  @{ re = '^proc\.top_gpu_pct$';          unit = '%';     desc = 'GPU를 가장 많이 쓴 프로세스의 사용률'; direction = 'none'; scale = 'relative' }
  @{ re = '^proc\.top_(cpu|gpu)$';        unit = '';      desc = '해당 분(分)에 가장 자주 1위였던 프로세스 이름. 문자열'; direction = 'none'; scale = 'absolute' }
)

function Get-MetricInfo([string]$Key) {
  foreach ($r in $script:MetricRules) {
    if ($Key -match $r.re) {
      return [ordered]@{
        unit = $r.unit; description = $r.desc; direction = $r.direction
        warn = $r.warn; hot = $r.hot; scale = $r.scale; provisional = $true
      }
    }
  }
  [ordered]@{ unit = ''; description = '(사전에 없는 지표)'; direction = 'none'; warn = $null; hot = $null; scale = 'relative'; provisional = $true }
}

# 값 하나를 임시 기준으로 읽는 한 줄 해석. 원인 판단이 아님.
function Get-Reading($Info, $Value) {
  if ($null -eq $Value) { return '측정값 없음' }
  if ($Info.direction -eq 'none' -or $null -eq $Info.warn) { return '기준 없음(수치만 제공)' }
  if ($Info.direction -eq 'high') {
    if ($Value -ge $Info.hot) { return '높음 (임시 기준)' }
    if ($Value -ge $Info.warn) { return '주의 (임시 기준)' }
    return '정상 범위 (임시 기준)'
  }
  if ($Value -le $Info.hot) { return '낮음 (임시 기준)' }
  if ($Value -le $Info.warn) { return '주의 (임시 기준)' }
  '정상 범위 (임시 기준)'
}
