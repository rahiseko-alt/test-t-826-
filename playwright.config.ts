import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './e2e',
  timeout: 30_000,
  use: {
    baseURL: process.env.BASE_URL || 'http://localhost:3000',
    // この環境には Chromium が同梱済み。playwright install は実行しない。
    launchOptions: { executablePath: process.env.CHROMIUM_PATH || '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' },
  },
  webServer: {
    command: 'python3 -m http.server 3000',
    url: 'http://localhost:3000/index.html',
    reuseExistingServer: true,
    timeout: 30_000,
  },
});
