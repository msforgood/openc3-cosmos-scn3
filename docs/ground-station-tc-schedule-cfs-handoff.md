# 시나리오 4 cFS 연동 요구사항: DOWNLINK_MSG

## 핵심

cFS가 `DOWNLINK_MSG` TC를 받으면 탑재체에 저장된 flag를 TM으로 내려보낸다. 이를 위해 아래 세 가지가 필요하다.

1. **cFS:** `DOWNLINK_MSG` TC를 받아 flag TM을 송신하는 기능
2. **OpenC3 → cFS:** OpenC3에서 `cmd("... DOWNLINK_MSG")`를 보내면 cFS가 받을 수 있는 패킷으로 구성
3. **cFS → OpenC3:** OpenC3가 flag TM을 받아 디코딩

## 현재 구현과 검증 범위

현재 패치의 Scenario Runner 04는 **INST 시뮬레이터**를 대상으로 정상 TC 시퀀스 파일을 만들고 `GROUND_OPS` Calendar에 약 5분 뒤 실행하도록 예약한다. 표시되는 **4/4 성공**은 링크 확인, 파일 생성, 예약 등록, 예약 재조회가 끝났다는 뜻이다. 예약 시각에 스크립트가 실행되었거나 `DOWNLINK_MSG` TC·flag TM이 오갔다는 뜻은 아니다.

INST에는 `DOWNLINK_MSG` 명령, `MESSAGE` TM, `INST/procedures/downlink_msg.py` 데모 절차가 있다. `TIMELINE_GUIDE.md` 6장의 Redis ZSET 수정 예시는 이 INST 예약의 `data.script`를 바꾸어 실제 실행과 TM을 **별도로 확인**하는 절차다. INST에서 받은 flag TM은 시뮬레이터의 결과로 기록한다.

**이 패치에는 QEMU/BBB cFS의 `DOWNLINK_MSG` 앱·TC/TM 정의·비행 번들이 없다.** 아래 1~4장은 이를 추가하기 위한 요구사항이다. 두 대상에서의 실제 TC 처리와 flag TM 수신은 구현·배포 후 각각 검증해야 한다.

## 1. cFS 동작

- 파라미터가 없는 `DOWNLINK_MSG` TC를 받는다.
- 받으면 flag 문자열을 담은 TM 패킷을 송신한다.
  - flag: `flag{ground_station_telecommand_highjaking}`
  - TM 항목: 순번(SEQ), flag 문자열(최대 64바이트)
  - 현재 OpenC3 데모(INST)는 1초 간격으로 5회 보낸다. 횟수와 간격은 조정 가능하다.
- TC는 기존 경로(`CI_LAB`)로 들어오고, TM은 `TO_LAB` 출력 구독 목록에 넣어 OpenC3로 내려와야 한다.
- QEMU와 BBB 양쪽에서 동작해야 하고, 시나리오 1~3에서 쓰는 MID와 함수 코드와 겹치면 안 된다.

## 2. OpenC3 → cFS: TC 패킷

OpenC3의 cFS 플러그인(`cfs-cosmos-plugin`)은 cFS 명령을 다음 형식으로 만든다(`targets/CFS/lib/cfs_packet_headers.rb`의 `cfs_cmd_hdr`).

| 필드 | 크기 | 바이트 순서 |
| --- | --- | --- |
| CCSDS_STREAMID (MID) | 16 bit | BIG_ENDIAN |
| CCSDS_SEQUENCE | 16 bit | BIG_ENDIAN |
| CCSDS_LENGTH | 16 bit | BIG_ENDIAN |
| CCSDS_FC (함수 코드) | 8 bit | - |
| CCSDS_CHECKSUM | 8 bit | - |

`DOWNLINK_MSG`는 파라미터가 없으므로 이 헤더만으로 구성된다. 지상에서 정의를 추가하려면 cFS 쪽에서 다음 값을 정해 주어야 한다.

- 명령 MID
- `DOWNLINK_MSG` 함수 코드

## 3. cFS → OpenC3: flag TM 디코딩

OpenC3는 cFS TM을 다음 헤더 뒤에 페이로드가 오는 형식으로 해석한다(`cfs_tlm_hdr`). 헤더는 BIG_ENDIAN이고, 페이로드는 LITTLE_ENDIAN이 기본값이다(`cfs_globals.rb`).

| 필드 | 크기 |
| --- | --- |
| CCSDS_STREAMID (MID) | 16 bit |
| CCSDS_SEQUENCE | 16 bit |
| CCSDS_LENGTH | 16 bit |
| SECONDS | 32 bit |
| SUBSECS | 16 bit |
| SPARE_FOR_64_ALIGN | 32 bit |

지상에서 디코딩하려면 cFS 쪽에서 다음을 알려 주어야 한다.

- flag TM의 MID
- 페이로드 필드 순서, 타입, 비트 크기 (예: SEQ 8 bit UINT, TEXT 512 bit STRING)
- 패딩과 정렬 규칙

## 4. cFS 담당자에게 받을 것

1. QEMU와 BBB용 비행 번들과 설치 방법
2. 인터페이스 값: 명령 MID, 함수 코드, TM MID, TM 페이로드 구조
3. 단독 확인 결과: `DOWNLINK_MSG`를 보내면 flag TM이 내려오는 것을 확인한 기록

## 5. 완료 기준

- [x] Scenario Runner 04의 INST 파일 생성·예약·재조회(4/4)를 확인했다. 이것은 예약 검증이다.
- [x] 격리 OpenC3 인스턴스에서 예약 시각 뒤 교체된 INST 스크립트가 `queued → started → running → completed`로 끝났다. 스크립트의 `DOWNLINK_MSG` 명령과 5회 TM 대기 검사가 성공했다.
- [x] 실행 전 비어 있던 `INST MESSAGE` TM이 5회 수신되었고, 마지막 `SEQ=5`와 flag `TEXT`를 확인했다.
- [ ] OpenC3에서 `DOWNLINK_MSG`를 보내면 cFS가 받아 처리한다.
- [ ] OpenC3에서 flag TM이 수신되고, SEQ와 flag 문자열이 올바르게 디코딩된다.
- [ ] 시나리오 1~3이 기존과 같이 동작한다.

HK 데이터 수신은 cFS 기본 TC로 가능할 것으로 보여 이 문서에서 제외한다. 추후 별도로 확인한다.
