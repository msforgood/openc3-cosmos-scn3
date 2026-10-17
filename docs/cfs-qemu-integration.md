# QEMU cFS 연동 준비 절차

별도 QEMU cFS 배포본과 OpenC3를 연결해 TC/TM을 주고받기 위한 순서입니다.
현재 체크아웃에는 cFS 통신 플러그인 소스와 검증된 gem이 포함되어 있으며,
`openc3-cosmos-init`이 이를 설치합니다.

## 연결 구조

```
OpenC3 operator (172.21.0.2) ── cfs-telemetry-link (internal, 172.21.0.0/16) ── qemu-cfs 컨테이너
   TC: CFS-1_QEMU 인터페이스 → qemu-cfs:1234/udp → 게스트 CI_LAB
   TM: 게스트 TO_LAB → 172.21.0.2:1236/udp → CFS-1_QEMU 인터페이스
```

| 항목 | 값 | 설정 위치 |
|---|---|---|
| 전용 네트워크 / operator IP | `cfs-telemetry-link` / `172.21.0.2` | `compose.yaml` |
| TC 목적지 | `qemu-cfs:1234/udp` | `cfs-plugin-variables.json` (`cfs_qemu_cmd_ip`) |
| TM 수신 | `1236/udp` | cFS 플러그인 / QEMU용 `to_lab.so` |
| 포함된 플러그인 / Scenario Runner | `openc3-cosmos-cfs-7.0.5.pre.all.3` / `1.0.29` | `openc3-cosmos-init/cfs-artifacts/`, `docs/all-three-scenarios.md` |

## 0. 사전 확인

- 디스크 여유 공간: QEMU 이미지 로드와 게스트 디스크 볼륨에 수 GB가 필요합니다.
  여유가 부족하면 redis가 쓰기를 거부해 OpenC3 전체가 멈추므로 **최소 5GB 이상** 남겨 두세요.
  (`df -h /`, `docker system df`)
- OpenC3가 먼저 실행 중이어야 합니다 (`cfs-telemetry-link` 네트워크를 OpenC3가 만듭니다).

## 1. QEMU cFS 실행

배포본의 `README.md`에 따라 이미지 무결성을 확인하고 이미지를 로드한 뒤, 해당 배포 디렉터리에서 실행합니다.

```bash
docker compose up -d --no-build
docker compose logs -f --tail 100 qemu-cfs    # "CFE_ES_Main entering OPERATIONAL state", "CFS_ALIVE" 확인
```

종료는 `docker compose stop`, 재시작은 `docker compose up -d --no-build`.
**`docker compose down -v`는 게스트 디스크 볼륨을 지우므로 사용하지 않습니다.**

## 2. (선택) 원시 TC/TM 확인

UDP 1236을 다른 인터페이스가 사용하지 않을 때만, 플러그인을 거치지 않고
TC/TM 경로와 메시지 ID를 확인할 수 있습니다. 현재 통합 배포는 플러그인을
자동 설치하므로 보통은 4절의 방법으로 확인합니다. 원시 검사가 필요하다면
`CFS-1_QEMU_INTF`를 중지한 뒤 operator 컨테이너에서 실행합니다.

```bash
docker cp tools/cfs_qemu_probe.py openc3-cosmos-scn3-openc3-operator-1:/tmp/
docker exec -it openc3-cosmos-scn3-openc3-operator-1 python3 /tmp/cfs_qemu_probe.py
```

보내는 TC (cFS 기본 MID, 다르면 `--to-lab-cmd-mid` 등 옵션으로 변경):

| TC | MID / FC | 기대 결과 |
|---|---|---|
| `TO_LAB_CMD_ENABLE_OUTPUT` (DEST_IP 172.21.0.2) | 0x1880 / 6 | UDP 1236으로 TM 수신 시작 |
| `CFE_ES_CMD_NOOP` | 0x1806 / 0 | `CFE_ES_HK` (0x0800) COMMAND_COUNTER +1 |
| `CFE_ES_SEND_HK_CMD` | 0x1808 / 0 | 새 `CFE_ES_HK` 수신 |
| `CFE_EVS_CMD_NOOP` | 0x1801 / 0 | EVS 이벤트 (0x0808) "No-op command" |

받은 TM은 MID별로 출력됩니다. 아무것도 오지 않으면 QEMU 부팅 상태와 MID를 확인합니다.
검사를 마치면 `CFS-1_QEMU_INTF`를 다시 시작합니다.

## 3. cFS 통신 플러그인 확인

현재 체크아웃의 `openc3-cosmos-init` 이미지를 빌드하고 실행하면 포함된
`openc3-cosmos-cfs-7.0.5.pre.all.3.gem`이 설치됩니다. 새 설치와 기존 설치의
업그레이드 절차는 [`all-three-scenarios.md`](all-three-scenarios.md)를 따릅니다.

설치 후 Admin > Plugins에서 포함된 cFS 플러그인을, CmdTlmServer > Interfaces에서
`CFS-1_QEMU_INTF`, `CFS-1_BBB_INTF`와 두 대상의 `*_XBAND_INTF`를 확인합니다.

## 4. TM 활성화와 확인

cFS가 (재)시작될 때마다 OpenC3에서 전송합니다.

```text
Target: CFS-1_QEMU   Command: TO_LAB_CMD_ENABLE_OUTPUT   DEST_IP: 172.21.0.2
```

`CONNECTED` 표시만 보지 말고 Packet Viewer에서 `TO_LAB_HK` / `CI_LAB_HK` / `CFE_ES_HK`가 새로 수신되는지 확인합니다.
Scenario Runner에는 QEMU용 housekeeping 예제가 없습니다. 현재 카탈로그의
`01. CS 1바이트 CRC 키 복원`, `02. TC 로그 사진 경로 변경`, `03. MM 포인터 변경`은
`CFS-1_QEMU`와 `CFS-1_BBB`에서 공통으로 표시됩니다. 기본 TC/TM 연결 확인은
위의 Packet Viewer와 `CFE_ES_CMD_NOOP` 같은 기본 TC를 이용하세요.
