#!/usr/bin/env python3
"""
이메일 포워딩 데몬
Gmail IMAP 수신함을 주기적으로 폴링하여 새 이메일을 OpenC3 쪽지 API로 포워딩함.

환경변수:
  IMAP_HOST         - IMAP 서버 (기본: imap.gmail.com)
  IMAP_PORT         - IMAP 포트 (기본: 993)
  EMAIL_USER        - 이메일 계정 (예: controller@example.com)
  EMAIL_PASS        - 앱 비밀번호
  OPENC3_URL        - OpenC3 API URL (기본: http://openc3-cosmos-cmd-tlm-api:2900)
  OPENC3_SCOPE      - OpenC3 스코프 (기본: DEFAULT)
  POLL_INTERVAL     - 폴링 주기 초 (기본: 30)
"""

import email
import imaplib
import logging
import os
import re
import time
from email.header import decode_header
from email.utils import parseaddr

import requests

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
)
log = logging.getLogger(__name__)

IMAP_HOST      = os.environ.get('IMAP_HOST', 'imap.gmail.com')
IMAP_PORT      = int(os.environ.get('IMAP_PORT', '993'))
EMAIL_USER     = os.environ.get('EMAIL_USER', '')
EMAIL_PASS     = os.environ.get('EMAIL_PASS', '')
OPENC3_URL     = os.environ.get('OPENC3_URL', 'http://openc3-cosmos-cmd-tlm-api:2900')
OPENC3_SCOPE   = os.environ.get('OPENC3_SCOPE', 'DEFAULT')
POLL_INTERVAL  = int(os.environ.get('POLL_INTERVAL', '30'))


def decode_mime_words(s: str) -> str:
    """MIME 인코딩된 헤더 디코딩"""
    if s is None:
        return ''
    parts = decode_header(s)
    decoded = []
    for part, charset in parts:
        if isinstance(part, bytes):
            decoded.append(part.decode(charset or 'utf-8', errors='replace'))
        else:
            decoded.append(part)
    return ''.join(decoded)


def extract_body(msg: email.message.Message) -> str:
    """이메일에서 HTML 또는 텍스트 본문 추출"""
    html_body = None
    text_body = None

    if msg.is_multipart():
        for part in msg.walk():
            ct = part.get_content_type()
            cd = str(part.get('Content-Disposition', ''))
            if 'attachment' in cd:
                continue
            if ct == 'text/html' and html_body is None:
                charset = part.get_content_charset() or 'utf-8'
                html_body = part.get_payload(decode=True).decode(charset, errors='replace')
            elif ct == 'text/plain' and text_body is None:
                charset = part.get_content_charset() or 'utf-8'
                raw = part.get_payload(decode=True).decode(charset, errors='replace')
                # 텍스트를 HTML로 간단히 변환 (줄바꿈 보존)
                text_body = '<pre style="white-space:pre-wrap">' + raw + '</pre>'
    else:
        ct = msg.get_content_type()
        charset = msg.get_content_charset() or 'utf-8'
        payload = msg.get_payload(decode=True).decode(charset, errors='replace')
        if ct == 'text/html':
            html_body = payload
        else:
            text_body = '<pre style="white-space:pre-wrap">' + payload + '</pre>'

    return html_body or text_body or '<p>(본문 없음)</p>'


def post_to_mailbox(from_email: str, subject: str, body: str) -> bool:
    """OpenC3 쪽지 API로 메시지 전송 (인증 없음)"""
    url = f"{OPENC3_URL.rstrip('/')}/openc3-api/mailbox"
    payload = {
        'from_email': from_email,
        'subject':    subject,
        'body':       body,
        'scope':      OPENC3_SCOPE,
    }
    try:
        resp = requests.post(url, json=payload, timeout=10)
        if resp.status_code == 201:
            log.info(f"쪽지 생성 완료: [{subject}] from {from_email}")
            return True
        else:
            log.error(f"쪽지 생성 실패 HTTP {resp.status_code}: {resp.text[:200]}")
            return False
    except requests.RequestException as e:
        log.error(f"OpenC3 연결 오류: {e}")
        return False


def poll_mailbox(imap: imaplib.IMAP4_SSL) -> int:
    """UNSEEN 이메일을 가져와 쪽지로 포워딩. 처리된 수 반환."""
    imap.select('INBOX')
    status, data = imap.search(None, 'UNSEEN')
    if status != 'OK':
        log.warning("INBOX 검색 실패")
        return 0

    ids = data[0].split()
    if not ids:
        return 0

    log.info(f"미읽음 이메일 {len(ids)}개 발견")
    processed = 0

    for uid in ids:
        status, msg_data = imap.fetch(uid, '(RFC822)')
        if status != 'OK':
            continue
        raw = msg_data[0][1]
        msg = email.message_from_bytes(raw)

        from_raw = msg.get('From', '')
        _, from_addr = parseaddr(from_raw)
        subject = decode_mime_words(msg.get('Subject', '(제목 없음)'))
        body = extract_body(msg)

        if post_to_mailbox(from_addr or from_raw, subject, body):
            # 처리 완료 표시 (\Seen 플래그)
            imap.store(uid, '+FLAGS', '\\Seen')
            processed += 1

    return processed


def run():
    if not EMAIL_USER or not EMAIL_PASS:
        log.error("EMAIL_USER / EMAIL_PASS 환경변수를 설정하세요")
        raise SystemExit(1)

    log.info(f"이메일 포워딩 데몬 시작: {EMAIL_USER} → {OPENC3_URL}")
    log.info(f"폴링 주기: {POLL_INTERVAL}초")

    while True:
        try:
            with imaplib.IMAP4_SSL(IMAP_HOST, IMAP_PORT) as imap:
                imap.login(EMAIL_USER, EMAIL_PASS)
                n = poll_mailbox(imap)
                if n:
                    log.info(f"{n}개 이메일 포워딩 완료")
        except imaplib.IMAP4.error as e:
            log.error(f"IMAP 오류: {e}")
        except Exception as e:
            log.exception(f"예상치 못한 오류: {e}")

        time.sleep(POLL_INTERVAL)


if __name__ == '__main__':
    run()
