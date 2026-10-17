# Timeline / Calendar 운영 가이드

OpenC3 COSMOS(이 저장소, 6.10.1 기반)에 추가한 Timeline microservice와 Calendar 툴의 사용법,
그리고 operator 컨테이너에서 Redis·버킷을 직접 다루는 방법을 정리한 문서입니다.

---

## 1. 구성 개요

| 구성 요소 | 위치 | 역할 |
|---|---|---|
| Timeline microservice | `openc3/lib/openc3/microservices/timeline_microservice.rb` | timeline마다 1개씩 operator 안에서 실행되며, 예약된 activity를 시간에 맞춰 실행 |
| Calendar 툴 | `openc3-cosmos-init/plugins/packages/openc3-cosmos-tool-calendar/` | 웹 UI. Calendar / Gantt / List 뷰, timeline·activity 생성 |
| REST API | `openc3-cosmos-cmd-tlm-api` (`/openc3-api/timeline/...`) | timeline·activity 조회, 생성, 수정, 삭제 |

### 동작 방식
- timeline을 만들면 `DEFAULT__TIMELINE__<이름>` microservice가 operator에서 자동으로 실행됩니다.
- microservice는 **앞으로 약 1시간 안에 실행될 activity만 메모리에** 올려 두고, 매초 실행할 것이 있는지 확인합니다.
- 메모리 내용은 다음 경우에만 Redis에서 다시 읽습니다.
  - 약 59분마다 자동으로
  - 변경 알림(`activity/updated`, `timeline/refresh` 등)을 받았을 때
  - 프로세스가 재시작될 때
- 스크립트 activity는 Script Runner로 실행되고, 이후 스크립트 상태가 바뀔 때마다 activity에 이벤트로 기록됩니다.

### activity 이벤트(상태)
| 색 | 이벤트 |
|---|---|
| 🟢 정상 | `created`, `updated`, `queued`, `started`, `running`, `completed` |
| 🟡 경고 | `paused`, `breakpoint`, `waiting`, `stopped`, `killed`, `completed_errors`, `disabled` |
| 🔴 에러 | `error`, `failed`, `crashed` |

- `started` 메시지는 `<스크립트 경로> => <running script ID>` 형식입니다.
- `failed`는 스크립트를 시작조차 하지 못한 경우입니다(경로 오류, 인증 실패 등).
- `disabled`는 timeline의 실행이 꺼져 있을 때 기록됩니다.

---

## 2. Calendar에서 스크립트 예약하기

### 2-1. Timeline 만들기 (최초 1회)
1. 상단 메뉴 **Create → Timeline**을 누릅니다.
2. 이름과 색을 정하고 생성합니다.
   - 이름에는 영문, 숫자, `_ - .`만 쓸 수 있고 `__`는 쓸 수 없습니다.

### 2-2. Activity(스크립트) 예약
**Create → Activity**를 누르거나, 캘린더/Gantt에서 원하는 시간대를 **우클릭**합니다.

**1단계: 시간 정보**
- **Timeline**: 예약할 timeline을 고릅니다.
- **Start/End Date·Time**:
  - 시작 시간은 반드시 미래여야 합니다.
  - 시작과 끝이 같으면 안 됩니다.
  - 최대 24시간까지 잡을 수 있습니다.
- **Custom Title, Notes**: 선택 사항입니다.
- **Recurring**: 반복이 필요하면 켜고 주기(분/시간/일)와 종료 시점을 정합니다.

**2단계: 실행 내용**
- **Activity Type**을 **SCRIPT**로 고릅니다.
- 실행할 스크립트를 고르고, 필요하면 환경변수도 넣습니다.

### 2-3. 실행 허용 여부
- 왼쪽 timeline 목록의 메뉴에서 **Enable/Disable Execution**으로 켜고 끕니다.
- 꺼져 있으면 시간이 되어도 실행되지 않고 `disabled`로만 기록됩니다.

### 2-4. 다른 예약 방법
- **Script Runner**: activity 예약 다이얼로그가 있어서 같은 방식으로 예약할 수 있습니다.
- **스크립트 API**:
  ```ruby
  create_timeline('OPS')
  now = Time.now.to_i
  create_timeline_activity('OPS', kind: 'script', start: now + 300, stop: now + 600,
    data: { 'script' => 'INST/procedures/collect.rb', 'environment' => [] })
  ```

---

## 3. 스크립트 실행 결과 확인

### 3-1. Calendar
activity를 클릭하면 이벤트 이력(시간, 이벤트, 메시지)이 나옵니다.
- `started` 메시지 끝의 숫자가 running script ID입니다. 아래 방법들에서 이 ID로 찾으면 됩니다.
- 최종 상태는 `completed`, `completed_errors`, `stopped`, `crashed` 중 하나입니다.

### 3-2. Script Runner (출력 로그)
1. **Script → Execution Status**를 엽니다.
2. 실행 상태에 따라 탭을 고릅니다.
   - **Running Scripts**: 실행 중인 스크립트입니다. 연결하면 실시간으로 볼 수 있습니다.
   - **Completed Scripts**: 끝난 스크립트입니다. ID로 찾아 **Log**를 보거나 다운로드합니다.
   - Suite로 실행한 경우에는 **Report**도 받을 수 있습니다.

### 3-3. Bucket Explorer
- 로그 파일 위치: `logs` 버킷의 `DEFAULT/tool_logs/sr/<YYYYMMDD>/`

### 3-4. Redis
상태 정보만 있고 출력 내용은 없습니다. 접속 준비는 4장을 참고하세요.
```ruby
# 완료된 스크립트 (ID 15번 예시)
puts JSON.pretty_generate(JSON.parse(r.hget("running-script-completed__DEFAULT", "15")))

# 최근 완료 목록
r.zrevrange("running-script-completed__DEFAULT__LIST", 0, 9).each { |id| s = JSON.parse(r.hget("running-script-completed__DEFAULT", id)); puts "#{id} #{s['filename']} #{s['state']} #{s['end_time']} errors=#{s['errors']}" }

# 실행 중인 스크립트
r.hkeys("running-script__DEFAULT")
```

---

## 4. operator 컨테이너에서 Redis·버킷 접속 준비

> 이 장부터 7장까지의 예시는 Ruby(irb) 기준입니다. 같은 작업을 **Python**으로 하는 방법은 **10장**에 있습니다.

```bash
docker exec -it openc3-cosmos-scn3-openc3-operator-1 sh
cd /tmp
irb -r openc3 -r openc3/utilities/target_file -r redis -r json
```

irb 안에서 아래를 한 번 입력해 둡니다.
```ruby
r = Redis.new(host: ENV["OPENC3_REDIS_HOSTNAME"], port: ENV["OPENC3_REDIS_PORT"], username: ENV["OPENC3_REDIS_USERNAME"], password: ENV["OPENC3_REDIS_PASSWORD"])                      # 데이터
e = Redis.new(host: ENV["OPENC3_REDIS_EPHEMERAL_HOSTNAME"], port: ENV["OPENC3_REDIS_EPHEMERAL_PORT"], username: ENV["OPENC3_REDIS_USERNAME"], password: ENV["OPENC3_REDIS_PASSWORD"])  # 알림 스트림
key = "DEFAULT__openc3_timelines__test"   # <scope>__openc3_timelines__<timeline이름>
```

- operator 이미지에는 `redis-cli`가 없어서 Ruby redis 클라이언트를 씁니다.
- 접속 정보는 컨테이너 환경변수에 이미 들어 있으므로 비밀번호를 입력할 필요가 없습니다.

### Redis 키 구조

| 키 | Redis | 종류 | 내용 |
|---|---|---|---|
| `openc3_timelines` | 메인 (`openc3-redis:6379`) | hash | timeline 목록. 필드는 `DEFAULT__TIMELINE__<이름>` |
| `DEFAULT__openc3_timelines__<이름>` | 메인 | sorted set | activity 목록. score = 시작 시간(epoch 초), 값 = activity JSON |
| `openc3_microservices` | 메인 | hash | microservice 등록 정보 (`DEFAULT__TIMELINE__<이름>`) |
| `running-script__DEFAULT`, `running-script-completed__DEFAULT` | 메인 | hash | 실행 중 / 완료된 스크립트 상태 |
| `DEFAULT__openc3_timelines` | **ephemeral** (`openc3-redis-ephemeral:6380`) | stream | 변경 알림. microservice와 Calendar가 이 스트림을 구독함 |

> ⚠️ **변경 알림 스트림은 ephemeral redis에 있습니다.** 메인 redis에 `XADD`하면 microservice가 알림을 받지 못합니다.

### 조회 예시
```ruby
# timeline 목록
r.hgetall("openc3_timelines").each { |k, v| puts k, JSON.pretty_generate(JSON.parse(v)) }

# 예약 목록 (시간순)
r.zrange(key, 0, -1).each { |v| a = JSON.parse(v); puts "#{Time.at(a['start'])} ~ #{Time.at(a['stop'])}  #{a['kind']}  #{a['data']['script'] || a['data']['command']}  fulfilled=#{a['fulfillment']}  last=#{a['events'].last['event']}" }

# 앞으로 실행될 예약만
r.zrangebyscore(key, Time.now.to_i, "+inf").each { |v| puts JSON.pretty_generate(JSON.parse(v)) }

# 한 activity의 이벤트 이력 (목록에서 확인한 UUID를 지정)
event_uuid = "여기에_확인할_UUID"
event_raw = r.zrange(key, 0, -1).find { |v| JSON.parse(v)["uuid"] == event_uuid }
raise "activity not found" unless event_raw
JSON.parse(event_raw)["events"].each { |ev| puts "#{Time.at(ev['time'])} #{ev['event']} #{ev['message']}" }

# 최근 변경 알림 (ephemeral)
e.xrevrange("DEFAULT__openc3_timelines", "+", "-", count: 10).each { |id, h| puts "#{id} #{h['type']}/#{h['kind']} #{h['timeline']}" }
```

### redis-cli로 조회하고 싶다면
redis 컨테이너에는 `redis-cli`가 있습니다. 비밀번호는 호스트에서 `grep OPENC3_REDIS_PASSWORD .env`로 확인합니다.
```bash
# 메인 redis (데이터)
docker exec -it openc3-cosmos-scn3-openc3-redis-1 redis-cli --user openc3 --pass '<비밀번호>' --no-auth-warning
#   HKEYS openc3_timelines
#   ZRANGE DEFAULT__openc3_timelines__test 0 -1 WITHSCORES

# ephemeral redis (알림 스트림)
docker exec -it openc3-cosmos-scn3-openc3-redis-ephemeral-1 redis-cli -p 6380 --user openc3 --pass '<비밀번호>' --no-auth-warning
#   XREVRANGE DEFAULT__openc3_timelines + - COUNT 10
```

---

## 5. 데이터 구조(JSON 필드) 상세

Redis에 저장되는 값은 모두 JSON 문자열입니다. 이 장에서는 각 필드의 의미와, 직접 수정할 때 **바꿔도 되는 값과 바꾸면 안 되는 값**을 정리합니다.

### 5-1. 저장 방식 (먼저 알아둘 것)
- **activity 저장 위치:** `DEFAULT__openc3_timelines__<timeline>` sorted set에 다음 형태로 저장됩니다.
  ```
  score = start(시작 시간, epoch 초)
  member = activity JSON 문자열 전체
  ```
- **수정 방법:** sorted set은 **member(JSON 문자열) 자체가 항목을 구분하는 값**이라서 그 자리에서 고칠 수 없습니다. 그래서 수정은 항상 다음처럼 합니다(OpenC3 내부의 `update`, `commit`도 같은 방식).
  ```
  기존 JSON 읽기 → 필드 수정 → MULTI { ZREM 기존 문자열 ; ZADD 같은 score 새 문자열 }
  ```
- **activity를 찾는 기준:** microservice, Calendar, API는 모두 **`start` + `uuid`** 조합으로 activity를 찾습니다. 이 두 값이 바뀌면 다른 activity로 취급됩니다.

### 5-2. Activity JSON 예시
```json
{
  "name": "test",
  "updated_at": 1791447349001573376,
  "start": 1791447942,
  "stop": 1791447952,
  "kind": "script",
  "data": {
    "script": "EXAMPLE/test2.py",
    "environment": [{ "key": "MODE", "value": "TEST" }],
    "customTitle": "test",
    "notes": "memo",
    "username": "anonymous"
  },
  "scope": "DEFAULT",
  "fulfillment": false,
  "uuid": "b104fdba-cb18-4065-adb3-31c28d83b0b2",
  "events": [
    { "time": 1791447922, "event": "created" },
    { "time": 1791447942, "event": "queued" },
    { "time": 1791447942, "event": "started", "commit": true, "message": "EXAMPLE/test2.py => 6" },
    { "time": 1791447943, "event": "completed", "commit": true, "message": "EXAMPLE/test2.py (6) completed" }
  ],
  "recurring": {}
}
```

### 5-3. Activity 필드 설명

표의 "변경" 열은 다음 뜻입니다.
- ✅ **자유롭게 변경 가능**
- ⚠️ **조건을 지키면 변경 가능**
- ⛔ **변경 금지**

| 필드 | 타입 | 의미 | 누가 설정 | 변경 |
|---|---|---|---|---|
| `name` | 문자열 | 소속 timeline 이름 | 생성 시 | ⛔ |
| `scope` | 문자열 | scope (보통 `DEFAULT`) | 생성 시 | ⛔ |
| `uuid` | 문자열 | activity 고유 ID (생성 시 무작위 UUID v4, 사용자와 무관) | 생성 시 | ⛔ |
| `start` | 숫자 (epoch 초, 소수 가능) | 시작(실행) 시간. **sorted set의 score와 같아야 함** | 생성·수정 시 | ⚠️ (가급적 금지) |
| `stop` | 숫자 (epoch 초) | 끝 시간. 화면 표시와 겹침 검사에 사용 | 생성·수정 시 | ⚠️ |
| `kind` | 문자열 | `script`, `command`, `reserve` (`expire`는 내부용) | 생성·수정 시 | ⚠️ |
| `data` | 객체 | 실행 내용 (아래 5-4 참고) | 생성·수정 시 | ✅ / ⚠️ (하위 필드마다 다름) |
| `fulfillment` | 불리언 | 실행 완료 여부. `true`면 다시 실행되지 않음 | microservice | ⛔ |
| `events` | 배열 | 상태 이력 (아래 5-5 참고) | API, microservice | ⚠️ (추가만) |
| `recurring` | 객체 | 반복 예약 정보 (아래 5-6 참고) | 생성 시 | ⛔ |
| `updated_at` | 숫자 (epoch 나노초) | 마지막 수정 시각 (정보용) | 생성·수정 시 | ✅ |

### 5-4. `data` 하위 필드

| 필드 | 사용하는 kind | 의미 | 변경 |
|---|---|---|---|
| `script` | script | 실행할 스크립트 경로 (Script Runner에 보이는 경로. 예: `EXAMPLE/test2.py`, `__TEMP__/..._temp.py`) | ✅ (경로가 실제로 있어야 함. 없으면 실행 시 `failed`) |
| `command` | command | 보낼 명령 문자열 (예: `INST ABORT`, `INST COLLECT with TYPE NORMAL`) | ✅ (문법이 틀리면 실행 시 `failed`) |
| `environment` | script | 스크립트 환경변수 배열 `[{ "key": "...", "value": "..." }]` | ✅ (배열 형태 유지. 없으면 `[]`) |
| `customTitle` | 공통 | Calendar에 표시할 제목 | ✅ |
| `notes` | 공통 | 메모 | ✅ |
| `username` | 공통 | 생성·수정한 사용자. Enterprise에서는 실행 권한(토큰)에 사용. Core에서는 기록용 | ✅ (Core) / ⛔ (Enterprise) |

- `data`는 반드시 **객체(`{}`)**여야 합니다. `null`이나 문자열로 바꾸면 안 됩니다.
- `data` 안에 다른 키를 추가하는 것은 괜찮습니다(무시됨).

### 5-5. `events` 배열 항목

| 필드 | 의미 |
|---|---|
| `time` | 이벤트 시각 (epoch 초) |
| `event` | 이벤트 이름 (1장의 이벤트 표 참고) |
| `commit` | `true`면 **"실행되었음"을 뜻하는 기록** (`started`, `completed`, `failed`, `disabled` 등 실행 결과) |
| `message` | 부가 설명 (스크립트 경로와 ID, 에러 메시지 등) |

`events`를 다룰 때 규칙은 다음과 같습니다.
- **기존 항목은 지우거나 고치지 마세요.**
  - 실행 이력이 사라지고, Calendar 상태 아이콘(마지막 이벤트 기준)이 틀어집니다.
- **`"commit": true`인 항목은 절대 추가하지 마세요.**
  - microservice는 `fulfillment`가 `true`이거나 `commit` 이벤트가 하나라도 있으면 **이미 실행된 것으로 보고 실행하지 않습니다.**
- **추가는 정보성 이벤트만 하세요.**
  - 예: `{ "time": <지금>, "event": "updated" }`처럼 `commit` 없는 항목만 추가합니다.
- **`queued`는 microservice가 메모리에서 붙이는 값입니다.**
  - 실행 결과를 저장할 때 함께 들어가므로 직접 넣을 필요가 없습니다.

### 5-6. `recurring` (반복 예약)
- **반복이 아닌 예약:** `{}`입니다.
- **반복 예약:**
  ```json
  { "start": 1791447942, "end": 1791534342, "frequency": "90", "span": "minutes", "uuid": "a1b2..." }
  ```

| 필드 | 의미 |
|---|---|
| `start` | 반복 묶음의 첫 시작 시간 |
| `end` | 반복 종료 시점 |
| `frequency` / `span` | 반복 주기 (예: 90 minutes, 2 hours, 1 days) |
| `uuid` | 반복 묶음 전체를 가리키는 ID. 각 activity의 `uuid`와는 다른 값 |

- 반복 예약은 만들 때 **각 회차가 별도의 activity로 펼쳐져 저장됩니다.** 그래서 `frequency`나 `end`를 고쳐도 회차가 새로 생기거나 사라지지 않습니다.
- `recurring.uuid`는 "반복 묶음 전체 삭제"의 기준이므로 바꾸면 묶음 삭제가 안 됩니다.
- 한 회차의 script만 바꾸고 싶다면 그 회차 activity의 `data.script`만 바꾸면 됩니다.

### 5-7. 변경하면 안 되는 값과 이유

| 필드 | 바꾸면 생기는 일 |
|---|---|
| `uuid` | 다른 activity로 취급됩니다. microservice가 메모리의 예전 activity를 실행하고, 결과를 저장할 항목을 찾지 못해 상태가 기록되지 않습니다. Calendar에서 수정·삭제가 안 되고(not found), 화면을 열어둔 상태에서는 두 개로 보입니다. uuid를 **빼먹으면** 읽을 때마다 새 uuid가 생겨 상태 기록과 중복 실행 방지가 깨집니다. |
| `name` / `scope` | 키(`<scope>__openc3_timelines__<name>`)와 맞지 않게 되어 화면 표시와 알림 처리가 어긋납니다. activity를 다른 timeline으로 옮기려면 **새로 만들고 기존 것을 삭제**하세요. |
| `fulfillment` | `true`로 바꾸면 실행되지 않습니다. 이미 실행된 activity를 `false`로 바꿔도 `commit` 이벤트가 남아 있으므로 다시 실행되지 않습니다. |
| `recurring` | 반복 묶음 삭제(`recurring.uuid` 기준)가 깨집니다. |
| `events`의 기존 항목, `commit` 항목 추가 | 이력이 손상되고, `commit` 항목을 추가하면 실행이 막힙니다. |
| 알 수 없는 최상위 키 추가 (예: `"foo": 1`) | 읽을 때 `ArgumentError(unknown keyword)`가 나서 **microservice가 스케줄을 읽지 못하고 종료**되고, API 조회도 실패합니다. 최상위에는 위 표에 있는 키만 두세요. |

### 5-8. 조건을 지키면 변경 가능한 값

**`start` (가급적 바꾸지 말고, Calendar에서 시간을 수정하는 것을 권장)**
1. sorted set의 **score도 같은 값으로** 넣어야 합니다: `zadd(key, 새start, new)`
2. **미래 시간**이어야 합니다. 과거 시간으로 바꾸면 실행되지 않거나 즉시 실행될 수 있습니다.
3. `stop`보다 작아야 하고, `stop - start`는 **86400초(24시간) 이하**여야 합니다.
4. 같은 timeline의 다른 activity와 겹치는지 검사되지 않습니다. 직접 확인해야 합니다.
5. Calendar를 열어둔 상태라면 알림에 `old_start`, `old_uuid`를 함께 넣어야 화면에서 예전 위치의 항목이 지워집니다.
   ```ruby
   old_start = JSON.parse(old)['start']      # 수정 전 시작 시간
   e.xadd("DEFAULT__openc3_timelines", { 'timeline' => 'test', 'kind' => 'updated', 'type' => 'activity', 'data' => new, 'old_start' => old_start.to_s, 'old_uuid' => a['uuid'] })
   ```

**`stop`**
- `start`보다 커야 하고, 기간은 24시간 이하여야 합니다.
- score는 바꿀 필요가 없습니다.

**`kind`**
- `data`의 내용도 함께 맞춰야 합니다.
  - `script` → `data.script`
  - `command` → `data.command`
  - `reserve` → 실행 내용 없음
- 그 외 값을 넣으면 실행 시 `Unknown kind` 에러만 기록되고 아무것도 실행되지 않습니다.

### 5-9. 공통 형식 규칙
- 값은 **올바른 JSON 문자열**이어야 합니다. 직접 타이핑하지 말고 `JSON.parse` → 수정 → `JSON.generate`를 쓰세요.
- 숫자 필드(`start`, `stop`, `time`, `updated_at`)를 문자열(`"1791447942"`)로 바꾸지 마세요.
- `zrem`에는 **기존 문자열을 한 글자도 바꾸지 않고 그대로** 넘겨야 합니다. 다르면 기존 항목이 남아 **같은 activity가 두 개**가 되고, 둘 다 실행될 수 있습니다.
- 수정 후에는 같은 `start`에서 같은 `uuid`가 하나만 있는지 확인하세요.
  ```ruby
  r.zrangebyscore(key, a['start'], a['start']).map { |v| JSON.parse(v)['uuid'] }
  ```

### 5-10. Timeline JSON (`openc3_timelines` hash)
- 필드 이름: `DEFAULT__TIMELINE__<이름>`

```json
{ "name": "test", "color": "#3f51b5", "execute": true, "shard": 0, "scope": "DEFAULT", "updated_at": null }
```

| 필드 | 의미 | 변경 |
|---|---|---|
| `name` | timeline 이름 | ⛔ (microservice 이름, activity 키와 연결됨) |
| `scope` | scope | ⛔ |
| `shard` | operator shard 번호 | ⛔ |
| `color` | Calendar 표시 색 (`#RRGGBB`) | ✅ |
| `execute` | 실행 허용 여부. `false`면 실행하지 않고 `disabled`로 기록 | ✅ (activity를 실행할 때마다 읽으므로 알림 없이도 반영됨. 단 화면 표시는 새로고침해야 바뀜) |
| `updated_at` | 수정 시각 | ✅ |

`color`, `execute`는 Calendar의 timeline 메뉴나 API(`POST /openc3-api/timeline/<이름>/color`, `/execute`)로 바꾸는 것을 권장합니다.

### 5-11. 변경 알림 메시지 (ephemeral `DEFAULT__openc3_timelines` stream)

| 필드 | 의미 |
|---|---|
| `timeline` | 대상 timeline 이름. microservice는 자기 이름과 같은 메시지만 처리 |
| `type` | `activity` 또는 `timeline` |
| `kind` | activity: `created`, `updated`, `deleted`, `event` / timeline: `created`, `updated`, `deleted`, `refresh` |
| `data` | JSON 문자열. activity 메시지는 activity JSON 전체, `deleted`는 `{"start":..,"uuid":..}` |
| `old_start`, `old_uuid` | (선택) `updated`에서 예전 위치·ID. Calendar 화면에서 예전 항목을 지울 때 사용 |

microservice는 메시지를 받으면 다음처럼 반응합니다.

| 메시지 | microservice 반응 |
|---|---|
| `activity/created` | 1시간 이내면 스케줄에 추가 (반복 예약은 전체를 다시 읽음) |
| `activity/updated`, `activity/deleted`, `timeline/refresh` | Redis에서 스케줄 전체를 다시 읽음 |
| 그 외 | 무시 |

---

## 6. 시나리오 4: `GROUND_OPS` 예약의 스크립트 경로 바꾸기

> 4장의 `r`(메인 Redis), `e`(ephemeral Redis), `OpenC3::TargetFile`을 준비한 operator `irb`에서 실행합니다.
> Scenario Runner 04의 `4/4`는 INST 링크 확인, 정상 TC 시퀀스 파일 생성, Calendar 예약 및 예약 내용 재조회까지 성공했다는 뜻입니다. 약 5분 뒤 스크립트 실행이나 flag TM 수신을 뜻하지 않습니다.

이 절차는 현재 **INST 데모 예약**만 대상으로 합니다. 먼저 Scenario Runner 04가 만든 `GROUND_OPS` 예약을 확인하고, 실행까지 2분 이상 남아 있을 때 진행하세요. 시간이 부족하면 새 예약을 만드세요. QEMU/BBB cFS용 `DOWNLINK_MSG` 기능은 아직 별도 구현 대상입니다.

### 6-1. 예약을 UUID로 고르고 실행 전 상태 확인

```ruby
key = "DEFAULT__openc3_timelines__GROUND_OPS"
timeline_name = "GROUND_OPS"
timeline = JSON.parse(r.hget("openc3_timelines", "DEFAULT__TIMELINE__GROUND_OPS") || "null")
raise "GROUND_OPS execution is disabled" unless timeline && timeline["execute"] == true

rows = r.zrange(key, 0, -1).map { |raw| [raw, JSON.parse(raw)] }
rows.each do |_raw, item|
  puts "#{item['uuid']}  #{Time.at(item['start']).getlocal('+09:00')}  #{item['data']['script']}  fulfilled=#{item['fulfillment']}  committed=#{item['events'].any? { |ev| ev['commit'] == true }}"
end

uuid = "여기에_목록에서_고른_UUID"  # 번호가 아니라 출력된 UUID를 정확히 복사
matches = rows.select { |_raw, item| item["uuid"] == uuid }
raise "UUID must identify exactly one activity" unless matches.length == 1
old, a = matches.first
original_path = a.fetch("data").fetch("script")
raise "not the Scenario Runner INST reservation" unless a["name"] == timeline_name && a["scope"] == "DEFAULT" &&
  a["kind"] == "script" && original_path.match?(/\AINST\/procedures\/INST_\d{8}_\d{6}\.py\z/)
raise "reservation is already executed" if a["fulfillment"] == true || a["events"].any? { |ev| ev["commit"] == true }
raise "start must be at least two minutes away" unless a["start"].is_a?(Numeric) && a["start"] > Time.now.to_i + 120
raise "invalid stop time" unless a["stop"].is_a?(Numeric) && a["stop"] > a["start"] && a["stop"] - a["start"] <= 86_400
```

`list[0]`은 가장 오래된 항목이라 과거 예약이나 `fulfilled=true`인 항목일 수 있습니다. 위 조건 중 하나라도 실패하면 Redis를 수정하지 마세요.

### 6-2. 원본을 보존하고 새 스크립트 파일 준비

원래 `INST_...py` 파일은 덮어쓰지 않습니다. UUID를 붙인 별도 백업과 새 실행 파일을 만들고, 버킷과 로컬 사본을 함께 갱신하는 `TargetFile.create`의 결과를 확인합니다.

```ruby
suffix = uuid.delete("-")
backup_path = "INST/procedures/ground_ops_original_#{suffix}.py"
new_path = "INST/procedures/ground_ops_downlink_#{suffix}.py"
original_body = OpenC3::TargetFile.body("DEFAULT", original_path)
downlink_body = OpenC3::TargetFile.body("DEFAULT", "INST/procedures/downlink_msg.py")
raise "source script missing" if original_body.nil? || downlink_body.nil?
raise "choose a new UUID/path; existing file would be overwritten" unless (
  OpenC3::TargetFile.body("DEFAULT", backup_path).nil? &&
  OpenC3::TargetFile.body("DEFAULT", new_path).nil?
)
raise "backup failed" unless OpenC3::TargetFile.create("DEFAULT", backup_path, original_body)
raise "new script failed" unless OpenC3::TargetFile.create("DEFAULT", new_path, downlink_body)
raise "file readback mismatch" unless (
  OpenC3::TargetFile.body("DEFAULT", backup_path) == original_body &&
  OpenC3::TargetFile.body("DEFAULT", new_path) == downlink_body
)
puts "original=#{original_path} backup=#{backup_path} replacement=#{new_path}"
```

`downlink_msg.py`는 `INST DOWNLINK_MSG`를 보내고 `INST MESSAGE` 5개를 기다리며 각 `SEQ`와 `TEXT`를 로그에 남기는 INST 데모 절차입니다. 파일 생성·백업 성공만으로 TC가 실행되지는 않습니다.

### 6-3. 같은 UUID의 Redis member를 원자적으로 교체

ZSET의 member는 JSON 문자열 전체입니다. `ZREM`에는 읽어 둔 `old` 원문을 넣고, `ZADD`에는 변경된 JSON을 같은 `start` score로 넣습니다. `WATCH` 뒤에 원문과 UUID를 다시 확인해 동시 수정이 있으면 교체하지 않습니다.

```ruby
a["data"]["script"] = new_path
a["updated_at"] = (Time.now.to_f * 1_000_000_000).to_i
a["events"] << { "time" => Time.now.to_i, "event" => "updated" } # commit은 추가하지 않음
new = JSON.generate(a)
raise "UUID changed" unless JSON.parse(new)["uuid"] == uuid
raise "too close to execution; create a new reservation" unless a["start"] > Time.now.to_i + 120

r.watch(key)
begin
  live = r.zrangebyscore(key, a["start"], a["start"]).select { |raw| JSON.parse(raw)["uuid"] == uuid }
  raise "activity changed; reselect UUID" unless live == [old]
  raise "replacement member already exists" unless r.zscore(key, new).nil?
  result = r.multi { |tx| tx.zrem(key, old); tx.zadd(key, a["start"], new) }
ensure
  r.unwatch
end
raise "swap failed or concurrently modified: #{result.inspect}" unless [[1, 1], [true, true]].include?(result)

same_uuid = r.zrange(key, 0, -1).map { |raw| JSON.parse(raw) }.select { |item| item["uuid"] == uuid }
raise "duplicate or missing UUID" unless same_uuid.length == 1 &&
  same_uuid[0]["start"] == a["start"] && same_uuid[0]["data"]["script"] == new_path
```

`[1, 1]` 또는 `[true, true]`는 기존 member 삭제·새 member 추가가 모두 성공했다는 뜻입니다. 반환 형식은 Redis Ruby 클라이언트 버전에 따라 다릅니다. `nil` 또는 다른 결과면 알림을 보내지 말고 현재 ZSET을 다시 읽어 원인을 확인하세요. 같은 UUID가 둘이면 실행·상태 기록이 어긋날 수 있습니다. 이때 만들어 둔 백업·새 파일은 남아 있으므로, 재시도할 때 같은 경로를 무심코 덮어쓰지 마세요.

### 6-4. ephemeral Redis에 refresh 알림 보내기

```ruby
refresh_id = e.xadd("DEFAULT__openc3_timelines", {
  "timeline" => timeline_name, "type" => "timeline", "kind" => "refresh",
  "data" => JSON.generate({ "time" => Time.now.to_f })
})
raise "refresh was not published" if refresh_id.to_s.empty?
puts "refresh stream ID=#{refresh_id}"
```

반드시 `e`에 보내세요. `r`에 보내면 Timeline microservice가 알림을 받지 못합니다. stream ID는 **알림 등록**의 증거일 뿐, worker가 다시 읽었거나 스크립트를 실행했다는 증거는 아닙니다. Calendar 화면은 새로고침해 `data.script`가 `new_path`로 보이는지 확인합니다.

### 6-5. 실행과 TM을 별도로 확인

예약 시간이 지난 뒤 같은 UUID의 `events`에서 `started` 메시지가 **`new_path`**를 가리키고 최종 상태가 `completed`인지 확인합니다. Script Runner의 Completed Scripts 로그에서 `INST DOWNLINK_MSG` 실행과 `[1/5]`~`[5/5]` 출력, Telemetry Viewer에서 새로 수신한 `INST MESSAGE`의 `SEQ`/`TEXT`를 확인해야 INST flag TM까지 검증한 것입니다. `failed`, `disabled`, `completed_errors`는 성공으로 세지 않습니다.

```ruby
after = r.zrange(key, 0, -1).map { |raw| JSON.parse(raw) }.select { |item| item["uuid"] == uuid }
raise "activity missing or duplicated" unless after.length == 1
after[0]["events"].each { |ev| puts "#{Time.at(ev['time'])} #{ev['event']} #{ev['message']}" }
```

| 확인 결과 | 입증되는 범위 |
|---|---|
| Scenario Runner `4/4` | 정상 INST TC 시퀀스의 파일 생성·예약·재조회 |
| `ZREM/ZADD = [1, 1]` 또는 `[true, true]`와 UUID 1개 | 저장된 예약의 `data.script` 교체 |
| ephemeral `XADD` ID | refresh 알림 게시 |
| `started` 경로·`completed` 로그 | 교체된 INST 스크립트의 실제 실행 |
| 새 `INST MESSAGE` 5개와 flag `TEXT` | INST 시뮬레이터의 TM 수신 |
| cFS QEMU/BBB flag TM | 별도 cFS 구현·패킷 정의·실기동 검증 필요 |

실행 전에 되돌릴 때는 Calendar의 **Edit**에서 `data.script`를 기록한 `original_path`로 복원하세요. 이미 실행했다면 파일·Redis 이력을 보존하고 실행 결과를 먼저 조사하세요. 백업 파일은 원본 파일의 보관용이며, 새 경로의 스크립트를 삭제해도 이미 송신된 TC/TM은 되돌릴 수 없습니다.

---

## 7. operator 컨테이너에서 버킷의 스크립트 읽고 쓰기

> Python 버전: **10-4**

### 로컬 모드 주의
이 환경은 `OPENC3_LOCAL_MODE=1`입니다. 그래서 스크립트가 두 곳에 저장됩니다.
- 버킷: `config/DEFAULT/targets_modified/...`
- 호스트 폴더: `./plugins/DEFAULT/targets_modified/...`

Script Runner는 실행할 때 **로컬 폴더를 먼저** 읽습니다. 버킷 클라이언트로 버킷만 수정하면, 로컬 사본이 남아 있는 한 예전 내용이 계속 실행됩니다.
👉 `OpenC3::TargetFile`을 사용하세요. 두 곳을 한 번에 처리합니다.

### 경로 규칙
| Script Runner 경로 | 버킷(config) 키 | 비고 |
|---|---|---|
| `EXAMPLE/test2.py` | `DEFAULT/targets_modified/EXAMPLE/test2.py` | |
| | `DEFAULT/targets/<TARGET>/...` | 플러그인 원본(읽기 전용). 수정하면 targets_modified에 저장됨 |

### irb에서
```ruby
# 목록
OpenC3::Bucket.getClient.list_objects(bucket: ENV["OPENC3_CONFIG_BUCKET"], prefix: "DEFAULT/targets_modified/").map(&:key)

# 읽기 (targets_modified 쪽이 없으면 targets 원본을 읽음)
puts OpenC3::TargetFile.body("DEFAULT", "EXAMPLE/test2.py")

# 쓰기 (새로 만들거나 덮어쓰기, 버킷과 로컬에 동시에 저장)
OpenC3::TargetFile.create("DEFAULT", "EXAMPLE/test2.py", "print('hello')\n")

# 컨테이너 안의 파일 내용으로 쓰기
OpenC3::TargetFile.create("DEFAULT", "EXAMPLE/test2.py", File.read("/tmp/test2.py"))

# 삭제 (targets_modified에서만 지워지고, 원본이 있으면 원본으로 돌아감)
OpenC3::TargetFile.destroy("DEFAULT", "EXAMPLE/test2.py")
```

### 셸에서 한 줄로 (operator 컨테이너 안)
```sh
# 읽기
cd /tmp && ruby -ropenc3 -ropenc3/utilities/target_file -e 'puts OpenC3::TargetFile.body("DEFAULT", ARGV[0])' EXAMPLE/test2.py

# 파일로 쓰기 (/tmp/test2.py 내용 → EXAMPLE/test2.py)
cd /tmp && ruby -ropenc3 -ropenc3/utilities/target_file -e 'OpenC3::TargetFile.create("DEFAULT", ARGV[0], File.read(ARGV[1])); puts :ok' EXAMPLE/test2.py /tmp/test2.py

# 목록
cd /tmp && ruby -ropenc3 -ropenc3/utilities/bucket -e 'puts OpenC3::Bucket.getClient.list_objects(bucket: ENV["OPENC3_CONFIG_BUCKET"], prefix: "DEFAULT/targets_modified/").map(&:key)'
```

### 호스트 파일을 올리기
```bash
docker cp ./test2.py openc3-cosmos-scn3-openc3-operator-1:/tmp/test2.py
# 이후 위의 "파일로 쓰기" 실행
```

> 스크립트 **내용**만 바꿀 거라면 6장(Redis 수정)은 필요 없습니다.
> 예약에는 경로만 저장되고 내용은 실행할 때 읽어가므로, 같은 경로의 파일만 덮어쓰면 다음 실행부터 새 내용으로 실행됩니다.

---

## 8. 문제 해결

| 증상 | 원인 / 조치 |
|---|---|
| 직접 수정했는데 `updated`가 사라지고 예전 스크립트가 실행됨 | 알림을 메인 redis에 넣었거나 알림을 넣지 않았음. 알림은 **ephemeral redis**(`e`)에 넣을 것 |
| `started` 이후 `completed`가 기록되지 않음 | 수정 전 코드의 버그(시작 시간이 지난 activity를 다시 읽을 때 검증 에러). 현재 코드에서는 수정됨. operator 로그에 `activity must be in the future`가 보이면 operator 이미지가 최신인지 확인 |
| 시간이 되어도 실행되지 않고 `disabled` | 해당 timeline의 Execution이 꺼져 있음 |
| operator 로그에 timeline microservice가 `activity must be in the future`로 종료되고 재시작됨 | 수정 전 코드의 버그(activity가 시작된 직후 15초 안에 스케줄을 다시 읽으면 발생). 현재 코드에서는 수정됨 |
| timeline microservice가 `unknown keyword`로 종료됨 | activity JSON에 알 수 없는 최상위 키가 들어감. 5-7 참고 |
| `failed` | 스크립트 경로 오류나 인증 실패 등. 메시지와 operator 로그 확인 |
| 스크립트 내용을 버킷에서 바꿨는데 반영 안 됨 | 로컬 모드 때문에 `./plugins/DEFAULT/targets_modified/`의 사본이 우선함. `OpenC3::TargetFile.create`로 저장할 것 |
| 재시작이 반복됨(cmd-tlm-api, script-runner-api) | bootsnap 1.24.2 이상의 인코딩 문제. 두 API의 `Gemfile`에서 `bootsnap < 1.24.2`로 고정되어 있는지 확인 |
| operator 셸에서 `cmd()`가 `AuthError` | 의도된 동작(9장). 명령은 Script Runner나 timeline으로 보낼 것 |
| init 컨테이너가 exit 1 | Scenario 설치 단계의 볼륨 소유권 또는 `user` 설정 확인. init·scenario-api의 데이터 경로는 해당 실행 사용자에게 쓰기 가능해야 함 |

### 로그 확인
```bash
# timeline microservice 로그
docker logs openc3-cosmos-scn3-openc3-operator-1 2>&1 | grep "TIMELINE__GROUND_OPS\|GROUND_OPS run_script\|script monitor"

# 컨테이너 상태
docker ps -a --filter name=openc3-cosmos-scn3 --format '{{.Names}}\t{{.Status}}'
```

### 직접 docker compose를 실행할 때 주의
`openc3.sh`를 거치지 않고 `docker compose`를 직접 실행할 때는, 호스트 uid를 함께 넘겨야 볼륨 권한 문제가 생기지 않습니다.
```bash
OPENC3_USER_ID=$(id -u) OPENC3_GROUP_ID=$(id -g) OPENC3_ROOTFUL=1 docker compose -f compose.yaml up -d
```

---

## 9. operator 셸에서 직접 명령(`cmd()`) 차단

### 목적
operator 셸에서는 Redis·버킷·timeline을 그대로 다룰 수 있게 두고, **스크립트 API(`cmd()` 등)로 바로 명령을 보내는 것만** 막습니다.

### 적용 내용

| 변경 | 위치 | 내용 |
|---|---|---|
| 서비스 비밀번호 제거 | `compose.yaml`의 `openc3-operator` | `OPENC3_SERVICE_PASSWORD=`로 빈 값을 줘서 `.env`의 값을 덮어씀. operator 셸과 그 안의 모든 프로세스에 API 비밀번호가 없음 |
| 임시 세션 토큰 | `timeline_microservice.rb`의 `get_token` / `release_token` | 서비스 비밀번호가 없으면 명령·스크립트를 실행하기 직전에 일회용 세션 토큰(`OPENC3__SESSIONS`)을 발급해 쓰고, 실행이 끝나면 바로 삭제 |
| 빈 비밀번호 보호 | `auth_model.rb`의 `verify` | 서비스 비밀번호가 빈 값이면 절대 인증으로 인정하지 않음 |

cmd-tlm-api와 script-runner-api는 기존대로 서비스 비밀번호를 가지고 있습니다. Script Runner로 실행한 스크립트 안의 `cmd()`는 정상적으로 동작합니다.

### 결과

| 동작 | 결과 |
|---|---|
| operator 셸에서 `cmd("INST CLEAR")` | `OpenC3::AuthError: Token is required` |
| operator 셸에서 `OPENC3_API_PASSWORD=$OPENC3_SERVICE_PASSWORD`로 시도 | `OpenC3::AuthError: Password is invalid` |
| timeline의 script / command activity | 정상 실행 (`started → completed`) |
| operator 셸에서 Redis·버킷·timeline 조회와 수정 | 기존과 동일하게 가능 |
| Calendar, Script Runner 등 웹 UI | 영향 없음 |

### 한계 (알아둘 점)
- **막히는 것은 "스크립트 API로 바로 보내는" 경로뿐입니다.**
- Redis 전체 권한은 그대로이므로, OpenC3 내부 구조를 아는 사람은 다음 방법으로 여전히 명령을 보낼 수 있습니다.
  - Redis에 세션 토큰을 직접 만들기
  - 명령 스트림에 직접 쓰기
  - timeline에 command activity를 예약하기
- Redis·timeline 운용을 막지 않는 이상, 이 부분까지 막을 수는 없습니다.
- operator 셸에 들어올 수 있는 사람 자체를 줄이는 것(호스트의 docker 접근 제한)이 가장 근본적인 대책입니다.

### 되돌리기
`compose.yaml`의 operator 항목을 `- OPENC3_SERVICE_PASSWORD=${OPENC3_SERVICE_PASSWORD}`로 되돌린 뒤 operator를 재시작합니다. 코드 쪽은 비밀번호가 있으면 기존처럼 비밀번호를 사용하므로 그대로 두어도 됩니다.

---

## 10. Python 버전

4장, 6장, 7장(그리고 3-4)의 작업을 operator 컨테이너의 Python으로 똑같이 할 수 있습니다.
- operator에는 Python 가상환경(`/openc3/venv`)에 `redis`(5.x) 패키지와 OpenC3 Python 라이브러리가 들어 있습니다.
- 아래 예시는 모두 실제 환경에서 실행해 확인했습니다. Redis 수정 → 알림 → 자동 실행까지 정상 동작합니다.

### Ruby 버전과 다른 점

| 항목 | Ruby | Python |
|---|---|---|
| 대화형 실행 | `irb -r ...` | `/openc3/venv/bin/python3` |
| sorted set 추가 | `r.zadd(key, score, member)` | `r.zadd(key, {member: score})` |
| 트랜잭션 | `r.multi { \|m\| ... }` | `pipe = r.pipeline(transaction=True)` → `pipe.execute()` |
| 응답 문자열 | 문자열로 반환 | `decode_responses=True`를 주지 않으면 `bytes`로 반환 |
| 스크립트 쓰기·삭제 | `OpenC3::TargetFile.create` / `destroy` (버킷과 로컬 동시 처리) | Python `TargetFile`은 **읽기(`body`)만** 지원 → 버킷과 로컬(local mode)을 **직접 둘 다** 처리해야 함 (10-4의 helper 사용) |
| JSON 생성 | `JSON.generate(a)` | `json.dumps(a, separators=(",", ":"), ensure_ascii=False)` |

### 10-1. 접속 준비

```bash
docker exec -it openc3-cosmos-scn3-openc3-operator-1 sh
cd /tmp
/openc3/venv/bin/python3
```

Python 프롬프트에서 아래를 한 번 입력해 둡니다.
```python
import os, json, time
import redis

r = redis.Redis(host=os.environ["OPENC3_REDIS_HOSTNAME"], port=int(os.environ["OPENC3_REDIS_PORT"]),
                username=os.environ["OPENC3_REDIS_USERNAME"], password=os.environ["OPENC3_REDIS_PASSWORD"],
                decode_responses=True)                       # 데이터 (메인 redis)
e = redis.Redis(host=os.environ["OPENC3_REDIS_EPHEMERAL_HOSTNAME"], port=int(os.environ["OPENC3_REDIS_EPHEMERAL_PORT"]),
                username=os.environ["OPENC3_REDIS_USERNAME"], password=os.environ["OPENC3_REDIS_PASSWORD"],
                decode_responses=True)                       # 알림 스트림 (ephemeral redis)
key = "DEFAULT__openc3_timelines__test"                      # <scope>__openc3_timelines__<timeline이름>
fmt = lambda t: time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(t))   # epoch → 시간 문자열 (UTC)
```

`cd /tmp`에서 실행하는 이유는, 현재 폴더의 파일이 모듈로 잘못 불러와지는 일을 피하기 위해서입니다.

### 10-2. 조회

```python
# timeline 목록
for k, v in r.hgetall("openc3_timelines").items():
    print(k, json.dumps(json.loads(v), indent=2))

# 예약 목록 (시간순)
for i, v in enumerate(r.zrange(key, 0, -1)):
    a = json.loads(v)
    d = a["data"]
    print(f"[{i}] {fmt(a['start'])} ~ {fmt(a['stop'])}  {a['kind']}  {d.get('script') or d.get('command')}  "
          f"fulfilled={a['fulfillment']}  last={a['events'][-1]['event']}")

# 앞으로 실행될 예약만
for v in r.zrangebyscore(key, time.time(), "+inf"):
    print(json.dumps(json.loads(v), indent=2, ensure_ascii=False))

# 한 activity의 이벤트 이력 (목록에서 확인한 UUID를 지정)
event_uuid = "여기에_확인할_UUID"
event_item = next((json.loads(v) for v in r.zrange(key, 0, -1)
                   if json.loads(v)["uuid"] == event_uuid), None)
if event_item is None:
    raise RuntimeError("activity not found")
for ev in event_item["events"]:
    print(fmt(ev["time"]), ev["event"], ev.get("message", ""))

# 최근 변경 알림 (ephemeral)
for msg_id, h in e.xrevrange("DEFAULT__openc3_timelines", "+", "-", count=10):
    print(msg_id, f"{h['type']}/{h['kind']}", h["timeline"])

# 스크립트 실행 결과 (3-4와 동일한 내용)
s = json.loads(r.hget("running-script-completed__DEFAULT", "15"))      # 15 = running script ID
print(s["state"], s["errors"], s["log"])
for sid in r.zrevrange("running-script-completed__DEFAULT__LIST", 0, 9):
    s = json.loads(r.hget("running-script-completed__DEFAULT", sid))
    print(sid, s["filename"], s["state"], s["end_time"], s["errors"])
```

### 10-3. Redis에서 예약된 스크립트 바꾸기 (6장의 Python 버전)

> 6장의 INST 데모에서는 새 스크립트와 원본 백업을 먼저 준비해야 합니다. 아래는 `key`가 가리키는 일반 timeline에서 **이미 존재하는** 스크립트 경로로 바꾸는 예시입니다. 과거 예약이나 `fulfilled=true`인 예약을 고르지 마세요.

```python
from openc3.utilities.target_file import TargetFile

# 1) 목록의 UUID를 확인하고 한 개를 명시적으로 고른다
rows = [(raw, json.loads(raw)) for raw in r.zrange(key, 0, -1)]
for raw, item in rows:
    print(item["uuid"], fmt(item["start"]), item["kind"],
          item["data"].get("script"), "fulfilled=", item["fulfillment"])
uuid = "여기에_목록에서_고른_UUID"
matches = [(raw, item) for raw, item in rows if item["uuid"] == uuid]
if len(matches) != 1:
    raise RuntimeError("UUID must identify exactly one activity")
old, a = matches[0]
if a["kind"] != "script" or a["fulfillment"] or any(ev.get("commit") for ev in a["events"]):
    raise RuntimeError("activity is not an unexecuted script")
if not isinstance(a["start"], (int, float)) or a["start"] <= time.time() + 120:
    raise RuntimeError("start must be at least two minutes away")

# 2) 새 경로를 먼저 확인한다. 필요하면 10-4의 helper로 새 파일·원본 백업을 만든다
new_script = "EXAMPLE/test2.py"
if TargetFile.body("DEFAULT", new_script) is None:
    raise RuntimeError("replacement script is missing")
a["data"]["script"] = new_script
a["updated_at"] = time.time_ns()
a["events"].append({"time": int(time.time()), "event": "updated"})  # commit은 추가하지 않음
new = json.dumps(a, separators=(",", ":"), ensure_ascii=False)
if json.loads(new)["uuid"] != uuid:
    raise RuntimeError("UUID changed")

# 3) WATCH 뒤에 원문·UUID를 재확인하고 ZREM/ZADD 결과를 검사한다
try:
    with r.pipeline(transaction=True) as pipe:
        pipe.watch(key)
        live = [raw for raw in pipe.zrangebyscore(key, a["start"], a["start"])
                if json.loads(raw)["uuid"] == uuid]
        if live != [old] or pipe.zscore(key, new) is not None:
            raise RuntimeError("activity changed; reselect UUID")
        pipe.multi()
        pipe.zrem(key, old)
        pipe.zadd(key, {new: a["start"]})
        result = pipe.execute()
except redis.exceptions.WatchError as exc:
    raise RuntimeError("concurrent modification; re-read the activity") from exc
if result != [1, 1]:
    raise RuntimeError(f"swap failed: {result!r}")

same_uuid = [json.loads(raw) for raw in r.zrange(key, 0, -1)
             if json.loads(raw)["uuid"] == uuid]
if len(same_uuid) != 1 or same_uuid[0]["data"]["script"] != new_script:
    raise RuntimeError("duplicate, missing, or unchanged activity")

# 4) 변경 알림은 데이터 Redis(r)가 아니라 ephemeral Redis(e)에 보낸다
timeline_name = key.split("__openc3_timelines__", 1)[1]
refresh_id = e.xadd("DEFAULT__openc3_timelines",
                    {"timeline": timeline_name, "kind": "refresh", "type": "timeline",
                     "data": json.dumps({"time": time.time()})})
if not refresh_id:
    raise RuntimeError("refresh was not published")
print("ZREM/ZADD:", result, "refresh stream ID:", refresh_id)
```

`[1, 1]`은 저장된 member가 원자적으로 교체되었다는 뜻이고, stream ID는 refresh 알림이 게시되었다는 뜻입니다. 둘 다 **실제 실행의 증거는 아닙니다.** 예약 시각 이후 `events`, Script Runner 로그, 필요한 TM을 따로 확인하세요. 시작 시간 변경은 이 예시에서 다루지 않습니다. Calendar의 **Edit**을 사용하세요.

### 10-4. 버킷의 스크립트 읽고 쓰기 (7장의 Python 버전)

Python의 `TargetFile`은 읽기만 지원합니다. 그래서 쓰기와 삭제는 아래 helper처럼 **버킷과 로컬 사본(`/plugins/DEFAULT/targets_modified/`)을 둘 다** 처리해야 합니다. 이유는 7장의 로컬 모드 주의를 참고하세요.

```python
import os
from openc3.environment import OPENC3_LOCAL_MODE, OPENC3_CONFIG_BUCKET
from openc3.utilities.bucket import Bucket
from openc3.utilities.local_mode import LocalMode
from openc3.utilities.target_file import TargetFile

SCOPE = "DEFAULT"

def read_script(name):
    """targets_modified → targets 원본 순으로 읽음 (local mode면 로컬 사본 우선)"""
    body = TargetFile.body(SCOPE, name)
    return body.decode() if isinstance(body, bytes) else body

def write_script(name, text):
    """새로 만들거나 덮어쓰기: 로컬 사본 + 버킷 모두 저장"""
    if OPENC3_LOCAL_MODE:
        LocalMode.put_target_file(f"{SCOPE}/targets_modified/{name}", text, scope=SCOPE)
    Bucket.getClient().put_object(bucket=OPENC3_CONFIG_BUCKET, key=f"{SCOPE}/targets_modified/{name}",
                                  body=text, content_type="text/plain")

def delete_script(name):
    """targets_modified에서만 삭제 (원본이 있으면 원본으로 돌아감)"""
    if OPENC3_LOCAL_MODE:
        try:
            os.remove(f"{LocalMode.LOCAL_MODE_PATH}/{SCOPE}/targets_modified/{name}")
        except FileNotFoundError:
            pass
    Bucket.getClient().delete_object(bucket=OPENC3_CONFIG_BUCKET, key=f"{SCOPE}/targets_modified/{name}")

def list_scripts(prefix=f"{SCOPE}/targets_modified/"):
    return [o["Key"] for o in Bucket.getClient().list_objects(bucket=OPENC3_CONFIG_BUCKET, prefix=prefix)]
```

사용 예:
```python
print(list_scripts())
print(read_script("EXAMPLE/test2.py"))
write_script("EXAMPLE/test2.py", "print('hello')\n")
write_script("EXAMPLE/test2.py", open("/tmp/test2.py").read())   # 컨테이너 안의 파일 내용으로 쓰기
delete_script("EXAMPLE/test2.py")
```

### 10-5. 셸에서 한 줄로 (operator 컨테이너 안)

```sh
# 예약 목록
cd /tmp && /openc3/venv/bin/python3 -c 'import os,json,redis,time; r=redis.Redis(host=os.environ["OPENC3_REDIS_HOSTNAME"],port=int(os.environ["OPENC3_REDIS_PORT"]),username=os.environ["OPENC3_REDIS_USERNAME"],password=os.environ["OPENC3_REDIS_PASSWORD"],decode_responses=True); [print(time.strftime("%F %T",time.gmtime(a["start"])),a["kind"],a["data"].get("script") or a["data"].get("command"),"last="+a["events"][-1]["event"]) for a in map(json.loads,r.zrange("DEFAULT__openc3_timelines__test",0,-1))]'

# 스크립트 읽기
cd /tmp && /openc3/venv/bin/python3 -c 'import sys; from openc3.utilities.target_file import TargetFile; b=TargetFile.body("DEFAULT",sys.argv[1]); print(b.decode() if isinstance(b,bytes) else b)' EXAMPLE/test2.py

# 스크립트 쓰기 (/tmp/test2.py 내용 → EXAMPLE/test2.py, 버킷과 로컬 모두)
cd /tmp && /openc3/venv/bin/python3 -c 'import sys; from openc3.environment import OPENC3_LOCAL_MODE as L, OPENC3_CONFIG_BUCKET as B; from openc3.utilities.bucket import Bucket; from openc3.utilities.local_mode import LocalMode; n,t=sys.argv[1],open(sys.argv[2]).read(); k=f"DEFAULT/targets_modified/{n}"; L and LocalMode.put_target_file(k,t,scope="DEFAULT"); Bucket.getClient().put_object(bucket=B,key=k,body=t,content_type="text/plain"); print("ok")' EXAMPLE/test2.py /tmp/test2.py
```

### 10-6. 참고
- **스크립트 API(`from openc3.script import *`)는 operator에서 쓸 수 없습니다.** 9장의 설정 때문에 operator에는 API 비밀번호가 없어 인증 에러가 납니다. 위의 Redis·버킷 작업에는 영향이 없습니다.
- **Ruby와 Python으로 쓴 JSON은 서로 호환됩니다.** 다만 두 언어가 만드는 문자열 형태(공백, 유니코드 표기)가 다를 수 있습니다. 그래서 `zrem`에는 항상 **Redis에서 방금 읽은 문자열(`old`)**을 그대로 넣어야 합니다.

