FROM mcr.microsoft.com/playwright:v1.49.1-jammy

WORKDIR /app

COPY package.json .
RUN npm install

# Playwright 브라우저 설치
RUN npx playwright install chromium

COPY bot.mjs .

CMD ["node", "bot.mjs"]
