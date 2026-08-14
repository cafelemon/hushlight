import { defineConfig } from '@playwright/test'

const viewports = [
  { name: 'desktop-1280x720', viewport: { width: 1280, height: 720 } },
  { name: 'desktop-1440x900', viewport: { width: 1440, height: 900 } },
  { name: 'desktop-1920x1080', viewport: { width: 1920, height: 1080 } },
  { name: 'mobile-390x844', viewport: { width: 390, height: 844 } },
]

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: true,
  forbidOnly: true,
  retries: 0,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: 'http://127.0.0.1:4173',
    channel: 'chrome',
    reducedMotion: 'reduce',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: viewports.map(({ name, viewport }) => ({ name, use: { viewport } })),
  webServer: {
    command: 'npm run dev -- --host 127.0.0.1',
    url: 'http://127.0.0.1:4173',
    reuseExistingServer: false,
    timeout: 20_000,
  },
})

