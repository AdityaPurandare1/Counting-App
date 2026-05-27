const { test, expect, loginAs, selectVenueAndStart, startAuditAs } = require('../fixtures');

test.describe('auth + audit lifecycle entry', () => {
  test('each persona signs in and lands on the venue picker', async ({ page }) => {
    for (const persona of ['corporate', 'manager', 'counter']) {
      await loginAs(page, persona);
      await expect(page.locator('#page-venues')).toBeVisible();
    }
  });

  test('unknown user is rejected (no app_users profile)', async ({ page }) => {
    await page.goto('/counting-app.html', { waitUntil: 'domcontentloaded' });
    await page.fill('#loginEmail', 'nobody@nowhere.com');
    await page.fill('#loginPassword', 'pw');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page.locator('#loginError')).toBeVisible();
    await expect(page.locator('#page-login')).toBeVisible();
  });

  test('manager starts a networked audit (code + kount_audits row)', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await expect(page.locator('#activeAuditContent')).toBeVisible();
    expect(db.t.kount_audits.length).toBe(1);
    expect(db.t.kount_audits[0].status).toBe('active');
    expect(db.t.kount_audits[0].count_phase).toBe('count1');
    expect(db.t.kount_audits[0].join_code).toMatch(/^TST-/);
    // starter is recorded as a member
    expect(db.t.kount_members.length).toBe(1);
  });

  test('a second counter joins the existing audit by code', async ({ page, db }) => {
    // Manager starts, capturing the code.
    await startAuditAs(page, 'manager');
    await expect.poll(() => db.t.kount_audits.length).toBe(1);
    const code = db.t.kount_audits[0].join_code;

    // Counter joins via the join-code modal.
    await loginAs(page, 'counter');
    await page.getByText('Delilah LA').first().click();
    await page.locator('#preAuditScreen').waitFor({ state: 'visible' });
    await page.getByRole('button', { name: /^Join audit/i }).click();
    await page.fill('#joinAuditCodeInput', code);
    await page.getByRole('button', { name: /^Join$/ }).click();
    await expect(page.locator('#activeAuditContent')).toBeVisible();
  });
});
