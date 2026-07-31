/* v1.98 BUG 1 — isRetryableError queue-poison fix (counting-app.html ~6526).

   The sync retry queue replays FIFO and STOPS on the first retryable failure.
   So an error shape wrongly classified as "retryable" wedges every op queued
   behind it forever. The fix: an error with no usable message ({}, an Error
   whose message is empty/whitespace, a thrown non-Error object, a bare
   {code:…} with no text) is an UNKNOWN/malformed shape → NON-retryable (drop &
   surface), NOT retryable. Genuine transients (offline / DNS / socket / 5xx)
   ALWAYS carry a message, and those stay retryable.

   Pure function — called directly via page.evaluate. Error objects can't cross
   the evaluate boundary, so we build every shape in-page and return booleans.

   FAIL-BEFORE: pre-fix the empty/unclassifiable shapes returned TRUE (that was
   the poison). The `false` assertions below flip red if that regression returns. */
const { test, expect } = require('../fixtures');

test.describe('v1.98 isRetryableError classification', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/counting-app.html', { waitUntil: 'domcontentloaded' });
    await expect.poll(() => page.evaluate(() => typeof window.isRetryableError)).toBe('function');
  });

  test('empty / unclassifiable shapes are NON-retryable (no queue poison)', async ({ page }) => {
    const r = await page.evaluate(() => {
      const f = window.isRetryableError;
      return {
        nullErr:      f(null),
        undefErr:     f(undefined),
        emptyString:  f(''),
        emptyErr:     f(new Error('')),
        whitespace:   f(new Error('   ')),
        emptyObj:     f({}),
        codeOnly:     f({ code: 'PGRST123' }),   // no message text
        thrownNon:    f({ foo: 1, bar: 2 }),     // a thrown non-Error object
      };
    });
    expect(r).toEqual({
      nullErr: false, undefErr: false, emptyString: false, emptyErr: false,
      whitespace: false, emptyObj: false, codeOnly: false, thrownNon: false,
    });
  });

  test('transient failures WITH a message stay retryable', async ({ page }) => {
    const r = await page.evaluate(() => {
      const f = window.isRetryableError;
      return {
        failedToFetch: f(new Error('Failed to fetch')),
        networkError:  f(new Error('NetworkError when attempting to fetch resource')),
        loadFailed:    f({ message: 'Load failed' }),
        http500:       f(new Error('HTTP 500: internal server error')),
        http503:       f({ message: 'HTTP 503: Service Unavailable' }),
        stringMsg:     f('socket hang up'),
        collisionMarker: f(new Error('entry-collision-unresolved: merge-key row not found for merge')),
      };
    });
    expect(r).toEqual({
      failedToFetch: true, networkError: true, loadFailed: true,
      http500: true, http503: true, stringMsg: true, collisionMarker: true,
    });
  });

  test('hard failures (23505 / HTTP 4xx) stay NON-retryable', async ({ page }) => {
    const r = await page.evaluate(() => {
      const f = window.isRetryableError;
      return {
        dupKeyText:  f(new Error('duplicate key value violates unique constraint "kount_entries_merge_key"')),
        code23505:   f({ message: 'error code 23505 collision' }),
        http404:     f(new Error('HTTP 404: Not Found')),
        http403rls:  f({ message: 'HTTP 403: row-level security' }),
        http422:     f(new Error('HTTP 422: unprocessable')),
      };
    });
    expect(r).toEqual({
      dupKeyText: false, code23505: false, http404: false, http403rls: false, http422: false,
    });
  });
});
