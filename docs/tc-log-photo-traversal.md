# TC 로그 사진 파일명 시나리오: OpenC3

이 브랜치 `scenario/tc-log-photo-traversal`은 OpenC3 6.10.1의 Scenario Runner 1.0.9에 QEMU/BBB 절차를 추가한다. 비행 소프트웨어는 같은 이름의 cFS 브랜치, TC/TM 정의는 같은 이름의 `cfs-cosmos-plugin-bbb` 브랜치에서 빌드한다. 각 브랜치는 독립된 체크아웃이다.

## 설치 순서

1. 두 장비에 시나리오 2 ARM 번들을 올리고 CI_LAB·TO_LAB·TC_CAMERA가 기동했는지 확인한다. QEMU의 TO_LAB 송신 포트는 1236, BBB는 1235다.
2. 플러그인 브랜치에서 `VERSION=7.0.1.pre.tclog.1 gem build openc3-cosmos-cfs.gemspec`으로 패킷 정의를 빌드한다. 이 체크아웃의 `cfs-plugin-variables.json`은 실습 환경의 BBB USB 및 QEMU Docker 주소를 지정한다. `scripts/prepare-cfs-plugin.rb`로 기존 cFS 플러그인 설정과 gem을 백업하고, 생성된 `install.json`을 사용해 새 gem을 OpenC3에 로드한다.
3. 이 체크아웃에서 `docker compose -p openc3-cosmos-scn3 -f compose.yaml build openc3-cosmos-init scenario-api`를 실행한다. 기존 `scenario-api`를 중지하고 SQLite DB를 백업한다. 기존 Runner 1.0.8에서 전환할 때만 `SCENARIO_UPGRADE_FROM=1.0.8`을 지정해 `/openc3/scenario/autoinstall.rb`를 실행한다. 두 Scenario gem이 설치됐다는 출력을 확인한 뒤 `scenario-api`를 1.0.9 이미지로 재시작한다.
4. OpenC3에서 두 대상의 `TO_LAB_CMD_ENABLE_OUTPUT`을 보내 TM 수신을 활성화한다. [Scenario Runner](http://localhost:2900/tools/scenariorunner)에서 대상을 고르고 `TC log photo path traversal`을 선택해 시작한다.

절차는 이전 로그 봉인, 정상 사진 TC 기록, 대상 로그 봉인, 공격 전 READ, `../log/tcNNNN.log` 사진 TC, 공격 후 READ, 다음 파일의 로그 지속 확인까지 7단계다. 화면의 **Onboard TC log**에는 같은 `/cf/log/tcNNNN.log`에 대한 공격 전 TCLOG 텍스트와 공격 후 PNG HEX가 나란히 표시된다. 지상 OpenC3 명령 이력은 별도로 유지된다.

## 실장비 검증

2026-10-07에 BBB 실행 `574f6c62-71b4-4c22-b767-146e3a99581b`, QEMU 실행 `628b55fd-50f2-4d8d-848c-53edccd82a68`이 각각 7/7 성공했다. 두 대상 모두 `tc0004.log`가 383바이트 TCLOG에서 737바이트 PNG로 바뀌었고, 다음 `tc0005.log`에 새 TC가 기록됐다. 공격 후 로그의 SHA-256은 원본 사진과 같은 `9a80db474f14e44ced3e91bcaf1d5537464c5ababf954e6a8d7e9b258255d654`다.

이 브랜치의 Scenario Runner 카탈로그는 시나리오 2와 QEMU housekeeping 절차만 표시한다. 이전 X-band 시나리오를 다시 실행하려면 보존된 1.0.8 Scenario gem과 이전 cFS 플러그인·비행 소프트웨어 배포본으로 전환한다. 플러그인 백업은 배포 시 지정한 `backups/tclog-20261007-preinstall/`, QEMU 이전 비행 번들은 `/opt/cfs/cpu1.backup-20261007-tclog-predeploy`, BBB 이전 비행 번들은 `/home/debian/cfs-bbb.backup-20261007-tclog-predeploy`에 남겨 두었다.
