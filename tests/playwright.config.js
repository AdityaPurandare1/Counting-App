const { defineConfig, devices } = require('@playwright/test');

const PORT = 5599;

// Human-watchable runs: PW_SLOWMO=<ms> npx playwright test --headed
// Slows every action (click/type) by <ms> so a person can follow along.
// Timeout scales up because slowMo inflates wall-clock per test.
const SLOWMO = Number(process.env.PW_SLOWMO || 0) || 0;

module.exports = defineConfig({
  testDir: './e2e',
  // The personas share one in-memory mock DB, so run serially.
  fullyParallel: false,
  workers: 1,
  timeout: SLOWMO ? 180000 : 30000,
  expect: { timeout: 7000 },
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: 'http://127.0.0.1:' + PORT,
    serviceWorkers: 'block',          // the PWA's SW would cache/intercept; off for tests
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    trace: 'retain-on-failure',
    viewport: { width: 414, height: 896 },  // phone-sized (counters use phones)
  },
  webServer: {
    command: 'node static-server.js',
    port: PORT,
    reuseExistingServer: true,
    stdout: 'ignore',
    stderr: 'pipe',
  },
  projects: [{
    name: 'chromium',
    use: {
      ...devices['Pixel 5'],
      launchOptions: SLOWMO ? { slowMo: SLOWMO } : {},
    },
  }],
});
