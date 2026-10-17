# PSP/MM 포인터 수정과 cFS SIGSEGV 시나리오

현재 절차는 OpenC3 6.10.1, Scenario Runner 1.0.29, ARMv7 armhf의 QEMU/BBB를 대상으로 한다. 양쪽에서 포인터는 4바이트다. 시나리오 ID는 공통 `psp-mm-indirect-write`를 사용하고, 실행 대상은 별도로 선택한다.

## 비행 앱과 MM 제한

- `PAYLOAD_DATA_APP` 한 개가 모의 페이로드 샘플을 0.5초마다 256바이트 링 버퍼에 쓴다. 버퍼는 별도의 `mmap` 읽기/쓰기 페이지에 있다. 별도 보호 페이지는 만들지 않는다.
- 쓰기 대상 포인터 `PAYLOAD_DATA_WritePtr`는 `pay_data_app.so`의 `.data`에 있다. 앱은 매 샘플마다 포인터를 다시 읽는다. 정상 상태에서는 링 버퍼를 가리킨다.
- MM `DEBUG_MAP`(FC13)은 실행 중인 `PAYLOAD_DATA_APP`과 실제 로드된 `.so`를 대조하고, ELF 프로그램 헤더와 `/proc/self/maps`로 쓰기 가능한 모듈 영역 및 포인터 슬롯을 확인한다. 또한 같은 `.so`의 기존 코드 영역에서 256바이트가 모두 실행 가능하고 쓰기 금지인 주소를 찾아 `MM_DEBUG.ADDRESS`에 넣는다. `DEBUG_READ`(FC14), `DEBUG_WRITE`(FC15)는 쓰기 가능한 모듈 영역에 대한 접근만 허용한다. 주소는 고정값으로 가정하지 않는다.
- 버퍼와 코드 영역은 MM의 직접 쓰기 허용 영역 밖이다. MM이 버퍼에 직접 쓰면 `DENIED`가 된다. 그러나 허용 영역 안의 포인터 슬롯 4바이트를 코드 영역 주소로 바꾸면, 앱 자신의 다음 쓰기가 기존 읽기 전용 코드에 닿는다. cFE 앱들이 같은 `core-cpu1` 프로세스 안에서 실행되므로 결과는 앱 하나의 `APP_ERROR`가 아니라 프로세스의 `SIGSEGV`다.

## Scenario Runner의 9단계

`Run step`으로 순서대로 실행하거나 `Start script`로 전 과정을 실행한다. 주소와 `REQUEST_ID`는 실행 중 받은 TM과 생성값으로 채우며, 각 단계에는 실제로 승인된 TC 파라미터와 실행 결과가 표시된다.

| 단계 | 전송 TC와 값 | 확인 결과 |
| --- | --- | --- |
| 1. `baseline` | `PAYLOAD_DATA_STATUS_CMD` (추가 파라미터 없음) | `PAYLOAD_DATA_STATE`의 정상 버퍼 주소, 포인터 슬롯, 증가한 샘플 수, `RESERVED_WORD=0`을 확인하고 관찰 서비스의 cFS 프로세스 식별자를 저장한다. |
| 2. `map` | `MM_CMD_DEBUG_MAP` (`REQUEST_ID` 생성) | MM이 허용 `.so` 영역, 같은 포인터 슬롯, 쓰기 금지 코드 주소 `MM_DEBUG.ADDRESS`를 반환한다. 버퍼와 코드 주소가 허용 영역 밖임을 확인한다. |
| 3. `deny-direct-write` | `MM_CMD_DEBUG_WRITE` (`ADDRESS=BUFFER_ADDRESS`, `WIDTH_BYTES=1`, `VALUE=0`, `REQUEST_ID` 생성, `RESERVED=0`) | `MM_DEBUG.STATUS=DENIED(3)`. 버퍼는 변경되지 않는다. |
| 4. `pause` | `PAYLOAD_DATA_PAUSE_CMD` | 상태 `PAUSED`, 쓰기 대상과 샘플 수를 확인한다. |
| 5. `read-pointer` | `MM_CMD_DEBUG_READ` (`ADDRESS=POINTER_SLOT`, `WIDTH_BYTES=4`, `REQUEST_ID` 생성) | 현재 포인터 값이 정상 `BUFFER_ADDRESS`와 일치한다. |
| 6. `write-pointer` | `MM_CMD_DEBUG_WRITE` (`ADDRESS=POINTER_SLOT`, `WIDTH_BYTES=4`, `VALUE=MM_DEBUG_MAP.ADDRESS`, `REQUEST_ID` 생성, `RESERVED=0`) | MM이 허용된 `.data` 슬롯 4바이트에 쓰기 금지 코드 주소를 쓴다. |
| 7. `verify-pointer` | `MM_CMD_DEBUG_READ` (`ADDRESS=POINTER_SLOT`, `WIDTH_BYTES=4`, `REQUEST_ID` 생성) | 수정된 포인터 값이 `MM_DEBUG_MAP.ADDRESS`와 일치한다. |
| 8. `resume` | `PAYLOAD_DATA_RESUME_CMD` | TC 승인을 확인한다. 이후 cFS가 종료될 수 있으므로 새 TM 수신을 성공 조건으로 삼지 않는다. |
| 9. `confirm-sigsegv` | TC 없음 | 관찰 서비스에서 최초 프로세스 식별자의 종료 신호가 정확히 `SIGSEGV(11)`인지 확인한다. |

마지막 단계는 TM 소실만으로 성공하지 않는다. 관찰 서비스가 QEMU/BBB의 `systemd` 상태에서 최초 cFS 프로세스의 `ExecMainCode=2` 또는 `3`, `ExecMainStatus=11`을 확인해야 한다. 일반 종료 코드 `139`도 대체 증거로 인정하지 않는다. 이 결과를 기록한 뒤 다른 시나리오를 실행하려면 대상의 `cfs.service`를 다시 시작해야 한다.

## 배포와 실행 조건

1. QEMU/BBB에 새 `MM`과 `PAYLOAD_DATA_APP`이 포함된 ARM 비행 번들을 설치한다. `PAYLOAD_CTRL_APP`은 이 버전에서 사용하지 않는다.
2. cFS 통신 플러그인에서 `PAYLOAD_DATA_*` TC/TM 정의를 설치하고, OpenC3의 init/API 이미지를 1.0.29로 함께 배포한다. 통합 절차는 [세 시나리오 안내](all-three-scenarios.md)를 따른다.
3. QEMU의 `cfs-run`은 `exec ./core-cpu1`로 실행하고, BBB는 `core-cpu1`을 직접 `ExecStart`하는 `cfs.service`를 사용한다. 두 서비스는 시연 동안 `Restart=no`로 둔다. [관찰 서비스 설정](../scenario-observer/README.md)에 따라 SSH 인증 자료와 검증한 호스트키 지문을 설정한다.
4. cFS 서비스를 시작하거나 재시작한 뒤 해당 대상에 `TO_LAB_CMD_ENABLE_OUTPUT`을 보내 TM 출력을 켠다. OpenC3의 QEMU/BBB TC/TM 수신이 정상이고 관찰 서비스가 해당 cFS 프로세스를 보고하는지 확인한 뒤 [Scenario Runner](http://localhost:2900/tools/scenariorunner)에서 대상별 `MM payload data pointer SIGSEGV` 절차를 실행한다.

## 2026-10-12 실기 검증 (1.0.26 QEMU·BBB 전체 실행)

Scenario Runner 1.0.26의 `Start script`가 QEMU와 BBB에서 각각 9/9단계를 모두 성공했다. MM이 실행 중 `.so`의 쓰기 금지 코드 주소를 찾아 포인터 슬롯에 4바이트로 쓰고 다시 읽어 같은 값을 확인했다. 재개 후 관찰 서비스는 각각 **원래 cFS PID**가 `SIGSEGV(11)`로 종료됐음을 확인했다.

| 대상 | 소요 시간 | 원래 cFS PID | 포인터 슬롯 | 정상 버퍼 → 코드 주소 | 신호 11 확인 시각 (UTC) |
| --- | --- | --- | --- | --- | --- |
| QEMU | 20초 | `25225` | `0xb64c2080` | `0xb6f26000` → `0xb64b0000` | `2026-10-12T11:24:03.552263Z` |
| BBB | 50초 | `11493` | `0xb6972080` | `0xb6eef000` → `0xb6960000` | `2026-10-12T11:18:43Z` |

BBB에서는 2단계 `MM_CMD_DEBUG_MAP`과 3단계의 직접 쓰기 거부를 확인하는 `MM_CMD_DEBUG_WRITE`가 각각 `MM_DEBUG` TM 유실 후 한 번 재시도됐다. 재시도 TC에는 최초와 다른 `REQUEST_ID`가 기록됐고, 해당 단계는 재시도 응답을 받아 계속 진행했다. 따라서 실제 BBB TM 유실 상황에서도 전체 Runner 절차가 완료됐다. 실행 뒤 두 `cfs.service`를 재시작해 `active`와 새 PID를 확인했다(QEMU `25509`, BBB `11717`). 두 대상 모두 `TO_LAB_CMD_ENABLE_OUTPUT`을 다시 보내 TM 출력을 활성화했다(QEMU `DEST_IP=172.21.0.2`, BBB `DEST_IP=192.168.7.1`).

## 2026-10-12 실기 검증 (기존 코드 영역 방식)

Scenario Runner 1.0.25와 새 ARM `mm.so`, `pay_data_app.so`를 QEMU와 BBB에 배포했다. OpenC3 init은 정상 종료했고, API health 응답도 확인했다. QEMU에서 `Start script`를 실행한 결과 9/9단계가 약 19초에 성공했다.

| 대상 | 포인터 슬롯 | 정상 버퍼 → MM이 찾은 코드 주소 | 원래 cFS PID | 종료 확인 |
| --- | --- | --- | --- | --- |
| QEMU | `0xb6522080` | `0xb6f8a000` → `0xb6510000` | `25047` | 같은 프로세스의 `SIGSEGV(11)` |

`MM_CMD_DEBUG_MAP`이 반환한 `0xb6510000`은 실행 중인 `pay_data_app.so`의 쓰기 금지 코드 영역이다. 버퍼 직접 쓰기는 `MM_DEBUG.STATUS=DENIED(3)`였고, 허용된 `.data` 포인터 슬롯에 대한 4바이트 쓰기와 다시 읽기는 성공했다. `PAYLOAD_DATA_RESUME_CMD` 뒤 앱의 정기 쓰기가 수정된 포인터를 따라 코드 영역에 닿자 관찰 서비스가 원래 PID의 신호 11 종료를 확인했다. 별도 `mprotect(PROT_NONE)` 페이지는 사용하지 않았다.

BBB에서는 1.0.25 Runner의 두 차례 실행이 각각 5단계와 7단계의 `MM_DEBUG` TM 대기 시간 초과로 끝났다. 해당 `MM` 명령은 비행체에서 처리된 것을 확인했지만, 이 두 실행을 9/9 성공으로 기록하지 않는다. 이후 수동 절차에서 포인터를 실제 코드 주소 `0xb64b0000`으로 바꾸고 `PAYLOAD_DATA_RESUME_CMD`를 보내자 원래 cFS PID `11048`이 `ExecMainCode=2`, `ExecMainStatus=11`로 종료됐다. 서비스를 새 PID `11493`으로 재시작하고 `TO_LAB_CMD_ENABLE_OUTPUT`을 다시 보냈다. 이 1.0.25 실행에는 BBB Runner 전체 성공 기록이 없다.

자동 검증에서는 ARM QEMU/BBB 빌드, Python Runner 테스트 63건, Scenario API 테스트 90건/단언 783개, init 설치 테스트 6건/단언 49개, cFS 플러그인 패킷 계약 테스트 5건/단언 42개가 통과했다. 새 OpenC3 init/API 이미지도 빌드됐고 통합 플러그인 `7.0.5.pre.all.3`을 설치했다. 이 실행으로 QEMU의 cFS가 의도대로 종료됐으므로 다음 시나리오 전에 서비스를 재시작하고 `TO_LAB_CMD_ENABLE_OUTPUT`을 다시 보내야 한다.

## 2026-10-10 실기 검증 (이전 보호 페이지 방식)

Scenario Runner 1.0.20의 수동 `Run step` 경로에서 보호 페이지를 사용했을 때 QEMU와 BBB에서 각각 9/9단계가 성공했다. 각 실행에서 8개 TC의 실제 파라미터가 기록됐고, 마지막 단계는 TC 없이 외부 관찰 결과를 사용했다. 이 기록은 현재 코드 영역 방식의 실기 검증 결과가 아니다.

| 대상 | MM이 찾은 포인터 슬롯 | 정상 버퍼 → 보호 페이지 | 종료 확인 |
| --- | --- | --- | --- |
| QEMU | `0xb6a22084` | `0xb6f8b000` → `0xb6f8c000` | 원래 `core-cpu1` 인스턴스가 `SIGSEGV(11)`로 종료 |
| BBB | `0xb64c2084` | `0xb6c03000` → `0xb6c04000` | 원래 `core-cpu1` 인스턴스가 `SIGSEGV(11)`로 종료 |

두 대상 모두 버퍼 직접 쓰기는 `MM_DEBUG.STATUS=DENIED(3)`였고, 포인터 슬롯의 4바이트 쓰기와 다시 읽기는 성공했다. `RESUME` 이후 관찰 서비스가 같은 프로세스 인스턴스의 신호 11을 반환했다. 검증 뒤 두 `cfs.service`를 재시작하고 `TO_LAB_CMD_ENABLE_OUTPUT`을 다시 보내 `PAYLOAD_DATA_STATE`의 새 TM 수신을 확인했다. QEMU 최초 시도는 재기동 후 TO_LAB 출력이 비활성화되어 baseline TM 대기에서 실패했으며, 출력을 활성화한 뒤 재실행해 성공했다.

## 이전 구현의 검증 기록

아래 2026-10-08 결과는 교체된 두 앱(`PAYLOAD_PULSE_APP`, `PAYLOAD_CTRL_APP`)과 `APP_ERROR` 흐름을 검증한 당시의 기록이다. 현재 9단계 SIGSEGV 구현의 성공 증거로 해석하지 않는다.

## 2026-10-08 실기 검증

- QEMU run `2c32d900-8603-4243-9b42-37e98ed52635`: 11/11단계 성공. MM은 펄스 앱 영역 `0xb68f1f10–0xb68f20fc`와 포인터 슬롯 `0xb68f2078`을 찾았다. 컨트롤러 모드 직접 쓰기는 `DENIED`(3)였고, 포인터 하위 바이트 `0x40→0xff` 수정으로 대상이 `0xb6a22240→0xb6a222ff`가 되었다. 컨트롤러 모드는 1→90, 오류 횟수 1, HALT ACK 수신을 확인했다. cFE ES의 종료 정리 이벤트 14와 펄스 앱 생존 상태까지 확인했다.
- BBB 첫 run `88e82ff8-35e3-4f66-85ea-72b1e0acbf68`은 baseline `psp_telemetry_timeout`으로 끝났다. BBB의 `usb0`에는 Windows 방향 UDP 송신이 잡혔지만 호스트 임시 UDP 리스너는 패킷을 받지 못했다. Windows Public 방화벽은 `BlockInbound`였다. 최초 규칙 제안은 자동 승인 심사에서 거절되어 적용하지 않았고, 이후 사용자가 수신 허용을 승인했다. 승인된 범위의 `CFS-BBB-TM-UDP1235-20261008` 규칙을 적용하자 Windows의 별도 리스너가 BBB TM을 받았다.
- 두 번째 run `96548eb2-60bc-4b7e-acd9-a04330b3263c`도 baseline에서 실패했다. Docker에는 `192.168.7.1:1235/udp` 포트 매핑이 표시됐지만 Windows의 Docker UDP 소켓이 없고 OpenC3 인터페이스 `rxcnt=0`이었다. `openc3-operator` 컨테이너만 재생성한 뒤 Docker 소켓이 바인딩되고 `rxcnt`가 증가했다. 비행체 TO_LAB 출력은 이 과정에서 유지됐다.
- BBB 최종 run `f2011329-3c58-4141-af5f-576a2182e479`: 11/11단계 성공, 종료 상태 `succeeded`, `termination_confirmed=true`. MM은 영역 `0xb6901f10–0xb69020fc`와 포인터 슬롯 `0xb6902078`을 찾았다. 컨트롤러 모드 직접 쓰기는 `DENIED`(3), 포인터는 하위 바이트 `0x40→0xff`만 바꿔 `0xb6922240→0xb69222ff`가 되었다. 재개 후 컨트롤러 모드가 1→90으로 훼손됐고 오류 횟수 1, HALT ACK, cFE ES `Exit Application PAYLOAD_CTRL_APP Completed.` 이벤트 14, 펄스 앱 생존·오류 정지를 확인했다.
- Runner UI 테스트 117/117, Scenario API 테스트 78건/390개 단언, 비행 ARM 빌드와 QEMU 실기 절차를 통과했다.
