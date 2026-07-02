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
    const passInput = page.locator('input[type="password"]')
    await passInput.waitFor({ timeout: 5000 })
    await passInput.fill(BOT_PASSWORD)
    await page.keyboard.press('Enter')
    await page.waitForURL(`${OPENC3_URL}/**`, { timeout: 15000 })
    console.log('[BOT] 로그인 성공')
  } catch {
    // Keycloak 또는 다른 SSO 방식 시도
    try {
      await page.fill('#username', BOT_USERNAME)
      await page.fill('#password', BOT_PASSWORD)
      await page.click('input[type="submit"]')
      await page.waitForURL(`${OPENC3_URL}/**`, { timeout: 15000 })
      console.log('[BOT] SSO 로그인 성공')
    } catch (e) {
      console.error('[BOT] 로그인 실패:', e.message)
      throw e
    }
  }
}

async function readMailbox(page) {
  const mailboxUrl = `${OPENC3_URL}/tools/mailbox`
  console.log(`[BOT] 쪽지함 접속: ${mailboxUrl}`)

  await page.goto(mailboxUrl, { waitUntil: 'networkidle', timeout: 30000 })

  // 메시지 목록 로드 대기
  try {
    await page.waitForSelector('.v-list-item', { timeout: 10000 })
  } catch {
    console.log('[BOT] 쪽지 없음 또는 목록 로드 대기 중')
    return
  }

  const items = await page.locator('.v-list-item').all()
  console.log(`[BOT] 쪽지 ${items.length}개 발견`)

  for (let i = 0; i < items.length; i++) {
    try {
      // 쪽지 클릭 → 본문 렌더링 → XSS 실행
      await items[i].click()
      console.log(`[BOT] 쪽지 #${i + 1} 열람`)
      // 본문 렌더링 및 잠재적 XSS 스크립트 실행 대기
      await page.waitForTimeout(2000)
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

  // 주기적 쪽지함 열람
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
