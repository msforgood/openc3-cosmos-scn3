# PSP/MM 간접 쓰기 시나리오: OpenC3

이 브랜치 `scenario/psp-mm-indirect-write`는 OpenC3 6.10.1의 Scenario Runner 1.0.11에 QEMU/BBB 절차를 추가한다. 같은 이름의 cFS 브랜치에서 비행 앱을, cFS 플러그인 브랜치에서 TC/TM 정의를 빌드한다. 두 실험 환경 모두 ARMv7 armhf이며 포인터 크기는 4바이트다.

## 비행 앱과 관찰 근거

- `PAYLOAD_PULSE_APP`은 `PAYLOAD_CTRL_APP`이 제공하는 모의 페이로드 레지스터의 `kick` 바이트에 주기적으로 0x5A/0xA5를 쓴다. `PAYLOAD_PULSE_FeedPtr`가 쓰기 대상 포인터이며 이 앱의 `.data`에 있다.
- `PAYLOAD_CTRL_APP`은 같은 256바이트 정렬 영역의 `mode` 바이트를 검사한다. `kick`은 영역 시작+0x40, `mode`는 +0xFF다. 모드 초기값은 1이다.
- MM의 새 `DEBUG_MAP`(FC13)은 실행 중인 펄스 앱 `.so`의 쓰기 가능한 영역과 포인터 슬롯을 찾는다. `DEBUG_READ`(FC14), `DEBUG_WRITE`(FC15)는 해당 앱 영역만 허용하고 실제 메모리 접근에는 PSP 함수를 사용한다.
- cFE ES가 피해 앱의 `APP_ERROR` 종료 정리를 완료하면 EVS 이벤트 14(`CFE_ES_ERREXIT_APP_INF_EID`)를 보낸다. Scenario Runner는 이벤트의 앱 이름, ID, 메시지에 `PAYLOAD_CTRL_APP`이 포함되는지를 확인한다.

## 고정 절차

QEMU/BBB 모두 같은 11단계다.

1. 두 앱 상태 TM에서 정상 킥, 모드, 포인터 값을 확인한다.
2. MM `DEBUG_MAP`으로 펄스 앱의 실제 주소와 포인터 슬롯을 찾는다.
3. MM에서 보호된 `mode` 주소에 정상값 1을 직접 쓰려 시도하고 `DENIED` 상태를 확인한다. 이 음성 대조군은 실제 모드를 변경하지 않는다.
4. `PAYLOAD_PULSE_PAUSE_CMD`로 주기 쓰기를 멈춘다.
5. MM `DEBUG_READ`로 펄스 앱 포인터 4바이트를 읽고 기존 `kick` 주소와 비교한다.
6. MM `DEBUG_WRITE`로 포인터의 하위 바이트 한 개를 0x40에서 0xFF로 변경한다.
7. MM `DEBUG_READ`로 포인터 전체가 `mode` 주소가 되었음을 재확인한다.
8. 펄스 앱을 재개한다. 정상 주기 쓰기가 이제 `mode`를 훼손한다.
9. 컨트롤러 상태 TM의 오류와 내부 HALT ACK를 확인한다.
10. EVS의 cFE ES 이벤트 14로 컨트롤러 오류 종료 정리를 확인한다.
11. 펄스 앱 상태 TC/TM으로 펄스 앱이 살아 있고 오류 정지 상태임을 확인한다.

웹 Scenario Runner의 **Indirect payload memory write** 패널은 MM 허용 영역, 거부된 직접 쓰기, 포인터 변경 전후, 모드 오류, cFE ES 종료 이벤트, 펄스 앱 생존 상태를 순서대로 보여준다. 이벤트 수신이 누락되면 성공으로 표시하지 않는다.

## 배포

1. QEMU/BBB에 시나리오 3 ARM 비행 번들을 배포하고 MM·두 페이로드 앱·TO_LAB 구독이 올라오는지 확인한다. QEMU TM 포트는 1236, BBB는 1235다.
2. cFS 플러그인 브랜치의 `openc3-cosmos-cfs.gemspec`을 `VERSION=7.0.2.pre.pspmm.2`로 빌드한다. `scripts/prepare-cfs-plugin.rb`로 기존 gem과 설정을 백업하고 생성된 `install.json`을 사용해 OpenC3의 writable `/gems`를 가진 init 서비스에서 새 gem을 로드한다.
3. 이 체크아웃에서 `docker compose -p openc3-cosmos-scn3 -f compose.yaml build openc3-cosmos-init scenario-api`를 실행한다. 기존 `scenario-api`를 중지하고 SQLite DB와 설치된 Scenario Runner gems를 백업한다.
4. 이전 Runner가 1.0.9 또는 1.0.10이면 그 버전을 `SCENARIO_UPGRADE_FROM`에 지정해 새 `openc3-cosmos-init` 서비스의 `/openc3/scenario/autoinstall.rb`를 한 번 실행한다. 예를 들어 1.0.10에서 올릴 때는 `docker compose -p openc3-cosmos-scn3 -f compose.yaml run --rm --no-deps -e SCENARIO_UPGRADE_FROM=1.0.10 --entrypoint ruby openc3-cosmos-init /openc3/scenario/autoinstall.rb`를 사용한다. 두 1.0.11 gems 설치 완료를 확인한 뒤 `docker compose -p openc3-cosmos-scn3 -f compose.yaml up -d --no-deps scenario-api`로 재시작한다.
5. OpenC3에서 `TO_LAB_CMD_ENABLE_OUTPUT`으로 TM 송신을 켠다. [Scenario Runner](http://localhost:2900/tools/scenariorunner)에서 `QEMU MM indirect payload write` 또는 `BBB MM indirect payload write`를 실행한다.

이 작업 디렉터리의 `backups/pspmm-20261008-preinstall/`에는 이전 cFS 플러그인 gem/설정, Scenario Runner 1.0.9 gems를 보관한다. `backups/pspmm-20261008-runner-1.0.10/`에는 1.0.11 설치 직전의 Scenario DB와 Runner 1.0.10 gems 두 개를 보관한다. 배포 전 QEMU/BBB 비행 번들도 각 대상의 이전 경로로 별도 백업해야 한다.

## 2026-10-08 실기 검증

- QEMU run `2c32d900-8603-4243-9b42-37e98ed52635`: 11/11단계 성공. MM은 펄스 앱 영역 `0xb68f1f10–0xb68f20fc`와 포인터 슬롯 `0xb68f2078`을 찾았다. 컨트롤러 모드 직접 쓰기는 `DENIED`(3)였고, 포인터 하위 바이트 `0x40→0xff` 수정으로 대상이 `0xb6a22240→0xb6a222ff`가 되었다. 컨트롤러 모드는 1→90, 오류 횟수 1, HALT ACK 수신을 확인했다. cFE ES의 종료 정리 이벤트 14와 펄스 앱 생존 상태까지 확인했다.
- BBB run `88e82ff8-35e3-4f66-85ea-72b1e0acbf68`: baseline에서 `psp_telemetry_timeout`. BBB는 STATUS TC를 수신했고 TO_LAB는 `192.168.7.1`로 활성화되었지만, OpenC3는 BBB TM을 아직 수신하지 못했다. USB 링크의 UDP 수신 경로를 조사 중이다.
- Runner UI 테스트 117/117, Scenario API 테스트 78건/390개 단언, 비행 ARM 빌드와 QEMU 실기 절차를 통과했다.
