# 시나리오 4 단계별 터미널 데모

Scenario Runner 04를 실행해 `GROUND_OPS` Calendar 예약이 만들어진 다음 사용한다. 이 도구는 **INST 시뮬레이터**의 예약만 다룬다. 정상 스크립트 뒤에 이미 설치된 `INST/procedures/downlink_msg.py`를 붙여, 예약 시각에 `INST DOWNLINK_MSG` TC와 `INST MESSAGE` TM 5개를 Script Runner 로그에서 확인할 수 있게 한다.

WSL에서 `cfs-app-idea-lab` 작업 디렉터리로 이동한 뒤 아래 명령을 순서대로 실행한다. 기본 컨테이너 이름은 `openc3-openc3-operator-1`이다. 다른 Compose 프로젝트명으로 실행 중이면 `OPENC3_OPERATOR_CONTAINER` 환경변수에 실제 operator 컨테이너 이름을 지정한다.

```bash
demo() { bash scenario-all-worktrees/openc3/tools/scenario4_demo.sh "$@"; }

demo connect
demo reset
demo list     # 키 없음, 예약 0건

# 여기서 Scenario Runner 04를 실행해 Calendar 예약 생성
demo list
ID='여기에_방금_생성된_예약_UUID'
demo show "$ID"
demo prepare "$ID"
demo switch "$ID"
demo notify "$ID"
demo result "$ID"
```

| 명령 | 수행하는 일 | 터미널에서 보이는 결과 |
| --- | --- | --- |
| `connect` | operator 컨테이너의 환경변수로 메인·ephemeral Redis에 각각 연결해 `PING` | 두 연결의 `PONG`, `GROUND_OPS` 예약 키, 예약 개수 |
| `reset` | `GROUND_OPS` 예약 키를 삭제하고 Timeline에 refresh 알림 게시 | 삭제한 예약 수, 키 `ABSENT` 확인 |
| `list` | `GROUND_OPS` 키 상태와 최근 스크립트 예약 조회 | 키 `ABSENT` 또는 `PRESENT`, UUID·실행 시각·경로·완료 여부 |
| `show UUID` | 선택한 예약과 현재 스크립트 읽기 | 원본 경로, 실행까지 남은 시간, 스크립트 전문 |
| `prepare UUID` | 원본 뒤에 `downlink_msg.py`를 붙인 새 파일 생성 | 원본 경로, 새 경로, 추가된 명령 설명 |
| `switch UUID` | 같은 UUID·시각의 예약에서 `data.script` 경로를 원자적으로 교체 | 변경 전후 경로 |
| `notify UUID` | ephemeral Redis에 `activity/updated` 알림 게시 | 스트림 ID와 Calendar에 표시될 경로 |
| `result UUID` | Calendar 실행 이벤트, Script Runner 로그, 최신 `INST MESSAGE` 조회 | `started` 경로, 완료 상태, `[1/5]`~`[5/5]` 출력과 TM 값 |

Runner 04 예약은 약 5분 뒤 실행된다. `prepare`와 `switch`는 실행까지 2분 이상 남았을 때만 진행된다. 시간이 부족하면 새 예약을 만든다. `notify` 뒤 Calendar를 새로고침해 변경 경로를 보여주고, 예약 시각 뒤 `result`를 다시 실행한다. `result`의 최신 TM 값만으로 이번 실행의 TM임을 단정하지 않는다. 도구가 Script Runner 로그를 읽지 못할 때는 **Completed Scripts → Log**에서 다섯 개의 `[1/5]`~`[5/5]` 출력까지 확인한다.

이 도구는 `docker exec`으로 이미 operator 컨테이너에 접근할 수 있는 데모를 전제한다. 컨테이너 접근 권한을 획득하는 취약점이나 QEMU·BBB cFS의 `DOWNLINK_MSG` 처리 기능은 구현하지 않는다.

`connect`는 이전 PoC의 `r = Redis.new(...)`, `e = Redis.new(...)`, `key = ...`에 해당한다. 두 Redis를 실제로 `PING`해 접속을 확인하고 호스트·포트·키를 출력하지만 비밀번호는 출력하지 않는다. 도구의 각 명령은 별도 프로세스로 실행되므로 이후 단계에서도 같은 컨테이너 환경변수로 Redis 연결을 다시 연다.

`reset`은 정확히 `DEFAULT__openc3_timelines__GROUND_OPS` 예약 키의 항목을 모두 지우고, Timeline microservice에 `refresh`를 보내 메모리의 예약도 다시 읽게 한다. Timeline 자체의 등록 정보와 저장된 스크립트 파일은 유지한다. 실행 중이거나 이미 큐에 들어간 예약이 있으면 삭제를 거부한다. `list`를 리셋 전·후, Runner 04 예약 생성 후에 각각 실행하면 키가 없을 때와 있을 때의 차이가 드러난다.

2026-10-14 실기 확인: Runner 04가 만든 INST 예약에서 `show → prepare → switch → notify → result`를 순서대로 실행했다. 교체된 경로로 `started → completed`가 기록됐고, `result`가 정상 HK 뒤 `[1/5]`부터 `[5/5]`까지의 `INST MESSAGE`와 최종 `SEQ=5`를 출력했다. 이 확인에 사용한 예약은 이미 완료됐으므로 다음 데모에는 Runner 04로 새 예약을 만든다.
