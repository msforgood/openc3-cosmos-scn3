/**
 * 관제사 봇 (Playwright 기반)
 *
 * Python/curl 스크립트로 구현하면 안 되는 이유:
 *   - 쪽지 본문이 HTML이며 서버에서 렌더링되지 않음
 *   - XSS 페이로드는 클라이언트 브라우저에서 JavaScript로 실행됨
 *   - Python requests / curl은 JavaScript를 실행하지 않으므로 XSS 트리거 불가
 *   - Playwright는 실제 Chromium 브라우저를 구동하므로 XSS가 봇 컨텍스트에서 실행됨
 *
 * 봇이 쪽지를 열면 본문의 악성 JS가 봇의 브라우저 세션 내에서 실행되고,
 * 해당 세션은 OpenC3에 인증된 상태이므로 /openc3-api/api 등 모든 엔드포인트에
 * 인증 없이(쿠키/세션 기반) 요청을 보낼 수 있게 됨.
 */

import { chromium } from 'playwright'

const OPENC3_URL   = process.env.OPENC3_URL  || 'http://openc3-traefik:2900'
const BOT_USERNAME = process.env.BOT_USERNAME || 'operator'
const BOT_PASSWORD = process.env.BOT_PASSWORD || 'operator'
const CHECK_INTERVAL_MS = parseInt(process.env.CHECK_INTERVAL_MS || '60000', 10)

async function loginToOpenC3(page) {
  const loginUrl = `${OPENC3_URL}/login`
  console.log(`[BOT] OpenC3 로그인: ${loginUrl}`)
  await page.goto(loginUrl, { waitUntil: 'networkidle', timeout: 30000 })

  // OpenC3 로그인 폼 처리 (기본 인증 또는 Keycloak SSO)
  try {
    // 기본 COSMOS Core 로그인 (비밀번호 입력 방식)
    // 주의: 로그인 페이지는 /auth/token-exists 응답이 오기 전까지 잠깐
    // "비밀번호 생성"(New/Confirm Password) 폼을 렌더링하는 레이스가 있어,
    // password input 개수만으로 판단하면 안 되고 실제 Login 버튼을 기다려야 함.
    const loginButton = page.getByRole('button', { name: 'Login', exact: true })
    await loginButton.waitFor({ timeout: 15000 })
    await page.locator('input[type="password"]').last().fill(BOT_PASSWORD)
    await loginButton.click()
    // 문자열 glob('/**')은 현재 /login 페이지 자체도 매칭해버려 로그인 성공을
    // 확인하지 못하므로, /login을 벗어났는지로 판단하는 predicate를 사용
    await page.waitForURL((url) => !url.pathname.includes('/login'), { timeout: 15000 })
    console.log('[BOT] 로그인 성공')
  } catch {
    // Keycloak 또는 다른 SSO 방식 시도
    try {
      await page.fill('#username', BOT_USERNAME)
      await page.fill('#password', BOT_PASSWORD)
      await page.click('input[type="submit"]')
      // 문자열 glob('/**')은 현재 /login 페이지 자체도 매칭해버려 로그인 성공을
    // 확인하지 못하므로, /login을 벗어났는지로 판단하는 predicate를 사용
    await page.waitForURL((url) => !url.pathname.includes('/login'), { timeout: 15000 })
      console.log('[BOT] SSO 로그인 성공')
    } catch (e) {
      console.error('[BOT] 로그인 실패:', e.message)
      throw e
    }
  }
}

// 이미 열람한 쪽지 id 모음. 매 주기마다 전체 목록을 다시 클릭하면 비효율적이므로
// (같은 쪽지를 10초마다 무한 재열람) 한 번 연 쪽지는 다시 열지 않도록 기억해둠.
const readMessageIds = new Set()

async function readMailbox(page) {
  const mailboxUrl = `${OPENC3_URL}/tools/mailbox`
  console.log(`[BOT] Mailbox 접속: ${mailboxUrl}`)

  await page.goto(mailboxUrl, { waitUntil: 'networkidle', timeout: 30000 })

  // 메시지 목록 로드 대기
  // 주의: .v-list-item 은 좌측 내비게이션 드로어에도 쓰이는 범용 Vuetify 클래스라
  // 실제 쪽지 목록만 가리키려면 Mailbox.vue의 전용 클래스(.mailbox-item)를 써야 함.
  try {
    await page.waitForSelector('.mailbox-item', { timeout: 10000 })
  } catch {
    console.log('[BOT] 쪽지 없음 또는 목록 로드 대기 중')
    return
  }

  const items = await page.locator('.mailbox-item').all()
  // 각 항목은 Mailbox.vue에서 data-msg-id 속성으로 쪽지 id를 노출함
  const unread = []
  for (const item of items) {
    const msgId = await item.getAttribute('data-msg-id')
    if (msgId !== null && readMessageIds.has(msgId)) continue
    unread.push({ item, msgId })
  }
  console.log(`[BOT] 쪽지 ${items.length}개 중 미확인 ${unread.length}개`)

  for (let i = 0; i < unread.length; i++) {
    const { item, msgId } = unread[i]
    try {
      // 리스트가 길어지면 아래쪽 항목은 뷰포트 밖이라 클릭이 막히므로 먼저 스크롤
      await item.scrollIntoViewIfNeeded()
      // 쪽지 클릭 → 본문 렌더링 → XSS 실행
      await item.click()
      console.log(`[BOT] 쪽지 #${i + 1} 열람 (id=${msgId})`)
      // 본문 렌더링 및 잠재적 XSS 스크립트 실행 대기
      await page.waitForTimeout(2000)
      if (msgId !== null) readMessageIds.add(msgId)
    } catch (e) {
      console.warn(`[BOT] 쪽지 #${i + 1} 열람 실패: ${e.message}`)
    }
  }
}

async function main() {
  console.log('[BOT] 관제사 봇 시작')
  console.log(`[BOT] 대상: ${OPENC3_URL}`)
  console.log(`[BOT] 점검 주기: ${CHECK_INTERVAL_MS / 1000}초`)

  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox'],
  })

  const context = await browser.newContext({
    ignoreHTTPSErrors: true,
    locale: 'en-US',
  })
  const page = await context.newPage()

  // 콘솔 로그 출력 (XSS 디버깅용)
  page.on('console', (msg) => {
    if (msg.type() === 'error') {
      console.log(`[BROWSER ERROR] ${msg.text()}`)
    }
  })

  // 초기 로그인
  try {
    await loginToOpenC3(page)
  } catch (e) {
    console.error('[BOT] 초기 로그인 실패, 재시도 예정:', e.message)
  }

  // 주기적 Mailbox 열람
  while (true) {
    try {
      // 세션 만료 확인: 현재 URL이 로그인 페이지면 재로그인
      const currentUrl = page.url()
      if (currentUrl.includes('/login') || currentUrl === 'about:blank') {
        console.log('[BOT] 세션 만료, 재로그인')
        await loginToOpenC3(page)
      }

      await readMailbox(page)
    } catch (e) {
      console.error('[BOT] 오류 발생:', e.message)
      // 오류 발생 시 재로그인 시도
      try {
        await loginToOpenC3(page)
      } catch {}
    }

    console.log(`[BOT] ${CHECK_INTERVAL_MS / 1000}초 후 다시 확인`)
    await page.waitForTimeout(CHECK_INTERVAL_MS)
  }
}

main().catch((e) => {
  console.error('[BOT] 치명적 오류:', e)
  process.exit(1)
})
