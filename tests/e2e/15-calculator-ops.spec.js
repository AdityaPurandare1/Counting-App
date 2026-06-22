const { test, expect, startAuditAs } = require('../fixtures');

/* Full calculator keypad coverage — exercises EVERY operation on the Calculator
   page (showPage('calculator')) by clicking the real keypad buttons, so a headed
   run shows each tap. Buttons are targeted by their calcInput() action (robust
   against the unicode glyphs ÷ × − ⌫). The big #calcResult div is the display. */

// Click a real keypad button by the argument its onclick passes to calcInput().
async function key(page, k) {
  await page.locator(`#calcKeypad button[onclick="calcInput('${k}')"]`).click();
}
// Press a sequence of keys in order.
async function press(page, keys) {
  for (const k of keys) await key(page, k);
}
async function result(page) {
  return (await page.locator('#calcResult').innerText()).trim();
}

test.describe('calculator — full keypad', () => {
  test.beforeEach(async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(() => window.showPage('calculator'));
    await page.locator('#calcKeypad').waitFor({ state: 'visible' });
    await key(page, 'C'); // start from a clean slate
    await expect(page.locator('#calcResult')).toHaveText('0');
  });

  test('addition: 2 + 3 = 5', async ({ page }) => {
    await press(page, ['2', '+', '3', '=']);
    expect(await result(page)).toBe('5');
  });

  test('subtraction: 9 − 4 = 5', async ({ page }) => {
    await press(page, ['9', '-', '4', '=']);
    expect(await result(page)).toBe('5');
  });

  test('multiplication: 6 × 7 = 42', async ({ page }) => {
    await press(page, ['6', '*', '7', '=']);
    expect(await result(page)).toBe('42');
  });

  test('division: 8 ÷ 2 = 4', async ({ page }) => {
    await press(page, ['8', '/', '2', '=']);
    expect(await result(page)).toBe('4');
  });

  test('decimals: 1.5 + 2.25 = 3.75', async ({ page }) => {
    await press(page, ['1', '.', '5', '+', '2', '.', '2', '5', '=']);
    expect(await result(page)).toBe('3.75');
  });

  test('percent: 200 × 10% = 20', async ({ page }) => {
    await press(page, ['2', '0', '0', '*', '1', '0', '%', '=']);
    expect(await result(page)).toBe('20');
  });

  test('operator precedence: 2 + 3 × 4 = 14', async ({ page }) => {
    await press(page, ['2', '+', '3', '*', '4', '=']);
    expect(await result(page)).toBe('14');
  });

  test('backspace ⌫ removes the last entry', async ({ page }) => {
    await press(page, ['1', '2', '3']);
    await key(page, 'back'); // 123 -> 12
    await key(page, '=');
    expect(await result(page)).toBe('12');
  });

  test('clear C resets the display to 0', async ({ page }) => {
    await press(page, ['7', '+', '8', '=']); // 15
    expect(await result(page)).toBe('15');
    await key(page, 'C');
    expect(await result(page)).toBe('0');
  });

  test('divide by zero surfaces a non-finite guard (Error or Infinity-safe)', async ({ page }) => {
    await press(page, ['5', '/', '0', '=']);
    // calcInput guards non-finite results -> "Error" (never a crash / blank).
    expect(await result(page)).toBe('Error');
  });
});
