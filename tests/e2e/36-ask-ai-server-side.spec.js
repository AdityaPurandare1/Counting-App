/* v2.22 — Ask AI runs server-side, on the same router as KevaOS.

   Before: the chat called api.anthropic.com straight from the browser with an
   Anthropic key each user had to paste into AI Settings (kept in localStorage
   on shared floor phones). Without a pasted key the chat refused to answer.

   Now: the chat calls the ask-ai Edge Function with the signed-in user's JWT;
   the function routes OpenRouter -> Anthropic with keys held in Supabase
   secrets. No key on the phone, and any old one is wiped on load.
   FAIL-BEFORE (v2.21): "I need an Anthropic API key to answer." */
const { test, expect, startAuditAs } = require('../fixtures');

async function sendChat(page, text) {
  await page.evaluate(() => window.openAIChat());
  await page.fill('#aiChatInput', text);
  await page.evaluate(() => window.sendAIMessage());
}

test.describe('v2.22 Ask AI is server-side', () => {
  test('answers with NO key on the device, via ask-ai with the user JWT', async ({ page }) => {
    const direct = [];
    page.on('request', (r) => { if (r.url().includes('api.anthropic.com')) direct.push(r.url()); });
    await startAuditAs(page, 'manager');

    const reqP = page.waitForRequest((r) => r.url().includes('/functions/v1/ask-ai'));
    await sendChat(page, 'how do I recount a zone?');
    const req = await reqP;

    expect(req.headers()['authorization']).toMatch(/^Bearer mocktok\./);
    const body = JSON.parse(req.postData() || '{}');
    expect(body.messages[body.messages.length - 1]).toEqual({ role: 'user', content: 'how do I recount a zone?' });
    expect(typeof body.system).toBe('string');
    expect(body).not.toHaveProperty('model');

    await expect(page.locator('#aiChatMessages')).toContainText('Mock answer to: how do I recount a zone?');
    await expect(page.locator('#aiChatMessages')).not.toContainText('Anthropic API key');
    expect(direct).toEqual([]);
  });

  test('a failed call shows the error and drops the turn so a retry is clean', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.route('**/functions/v1/ask-ai', (route) =>
      route.fulfill({ status: 429, contentType: 'application/json', body: JSON.stringify({ error: 'AI is busy right now' }) }));
    await sendChat(page, 'first try');
    await expect(page.locator('#aiChatMessages')).toContainText('Failed: AI is busy right now');
    expect(await page.evaluate(() => window.aiChatHistory.length)).toBe(0);
  });

  test('an Anthropic key left on the device from v2.21 is wiped on load', async ({ page }) => {
    await page.addInitScript(() => {
      try { localStorage.setItem('hwood_anthropic_key', 'sk-ant-old-device-key'); } catch (e) {}
    });
    await startAuditAs(page, 'manager');
    // The init script re-seeds on every navigation; the app's load-time cleanup runs after it.
    expect(await page.evaluate(() => localStorage.getItem('hwood_anthropic_key'))).toBeNull();
  });

  test('AI Settings no longer asks for an Anthropic key', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(() => window.openAPIKeySettings());
    await expect(page.locator('#apiKeyInput')).toHaveCount(0);
    await expect(page.locator('#apiKeySettingsModal')).toContainText('no key needed');
    await expect(page.locator('#apiKeyStatus')).toContainText('AI runs on the server');
  });
});
