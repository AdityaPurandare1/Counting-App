/* v2.20 — the photo new-product rule.

   Aditya's rule: a counter photographs a bottle -> the AI reads the label ->
   the details are filled in -> if it is a NEW product it is STORED -> when the
   count closes, all the stored products are created together.

   Before v2.20 storing needed a manual "Suggest" tap per bottle (Little Luck's
   10/18 count recorded ZERO photo entries), the name dropped the vintage so
   two vintages collapsed onto one product, and the brand was prefixed even
   when the AI's name already contained it.

   This spec covers the phone half: naming, the automatic store, and the
   offline/close guarantees. The close half -- creating the products and
   linking the entries -- is a database trigger (migration 0089), which the
   mock DB does not run; it is verified against production in a rolled-back
   transaction instead (see APPLIED.md, 0089). */
const { test, expect, startAuditAs } = require('../fixtures');

const fill = (page, parsed) => page.evaluate((p) => {
  const status = document.getElementById('photoStatus') || document.createElement('div');
  if (!status.parentNode) document.body.appendChild(status);
  window.populatePhotoFormFromParsed(p, status);
  const el = document.getElementById('photoName');
  return { name: el.value, aiNew: el.dataset.aiNew || null, aiSize: el.dataset.aiSize || null,
           masterId: el.dataset.masterId || null };
}, parsed);

const NEW_WINE = {
  name: 'Bordeaux Supérieur', brand: 'Domaine des Justices', category: 'wine',
  vintage: '2020', size: '750ml', details: '', matchedId: null, confidence: 'high',
};

async function submitPhoto(page, qty) {
  await page.evaluate((q) => {
    document.getElementById('photoQty').value = String(q);
    window.capturedPhotoData = window.capturedPhotoData || 'data:image/jpeg;base64,AAAA';
    return window.submitPhotoEntry();
  }, qty);
}

test.describe('v2.20 photo new-product rule', () => {
  test('a new wine is named Brand Name Vintage Size and flagged as new', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const r = await fill(page, NEW_WINE);
    expect(r.name).toBe('Domaine des Justices Bordeaux Supérieur 2020 750ml');
    expect(r.aiNew).toBe('1');
    expect(r.aiSize).toBe('750ml');
    expect(r.masterId).toBeNull();
  });

  test('two vintages of the same wine get two distinct names', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const a = await fill(page, { ...NEW_WINE, vintage: '2020' });
    const b = await fill(page, { ...NEW_WINE, vintage: '2021' });
    expect(a.name).not.toBe(b.name);
    expect(b.name).toContain('2021');
  });

  test('the brand is not repeated when the AI name already contains it', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const r = await fill(page, { name: 'Clase Azul Reposado', brand: 'Clase Azul', category: 'spirits',
      vintage: '', size: '750ml', details: '', matchedId: null });
    expect(r.name).toBe('Clase Azul Reposado 750ml');   // not "Clase Azul Clase Azul Reposado"
  });

  test('saving a new photographed product STORES it automatically — no Suggest tap', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    const auditId = db.t.kount_audits[0].id;
    await fill(page, NEW_WINE);
    await submitPhoto(page, 3);

    const NAME = 'Domaine des Justices Bordeaux Supérieur 2020 750ml';
    // The count is recorded, unlinked for now (the close links it).
    await expect.poll(() => db.t.kount_entries.filter((e) => e.item_name === NAME).length).toBe(1);
    const entry = db.t.kount_entries.find((e) => e.item_name === NAME);
    expect(entry.method).toBe('photo');
    expect(entry.master_item_id == null).toBe(true);

    // And the product is stored for the close, tied to this count.
    await expect.poll(() => db.t.kount_pending_items.filter((p) => p.name === NAME).length).toBe(1);
    const stored = db.t.kount_pending_items.find((p) => p.name === NAME);
    expect(stored.status).toBe('pending');
    expect(stored.audit_id).toBe(auditId);
    expect(stored.category).toBe('Wine Cost');   // catalog vocabulary, not the selector's "wine"
    expect(stored.size).toBe('750ml');
  });

  test('a photo that matched the catalog is NOT stored as new', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    const before = db.t.kount_pending_items.length;
    const known = db.t.master_items.find((m) => /Belvedere/i.test(m.name));
    await fill(page, { name: known.name, brand: '', category: 'spirits', vintage: '', size: '',
      details: '', matchedId: known.id, confidence: 'high' });
    await submitPhoto(page, 1);
    await expect.poll(() => db.t.kount_entries.filter((e) => e.master_item_id === known.id).length)
      .toBeGreaterThan(0);
    expect(db.t.kount_pending_items.length).toBe(before);
  });

  test('if the counter picks an existing catalog item instead, nothing is stored', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    const before = db.t.kount_pending_items.length;
    const known = db.t.master_items.find((m) => /Belvedere/i.test(m.name));
    await fill(page, NEW_WINE);
    // The counter decides it is actually a catalog item and picks it.
    await page.evaluate((id) => { document.getElementById('photoName').dataset.masterId = id; }, known.id);
    await submitPhoto(page, 1);
    await page.waitForTimeout(400);
    expect(db.t.kount_pending_items.length).toBe(before);
  });

  test('offline: the store is queued, and closing waits for it', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(() => {
      Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => false });
      window.dispatchEvent(new Event('offline'));
    });
    await fill(page, NEW_WINE);
    await submitPhoto(page, 1);

    const queued = await page.evaluate(() =>
      pendingMutations.filter((op) => op.args && op.args.table === 'kount_pending_items').length);
    expect(queued).toBe(1);
    expect(db.t.kount_pending_items.some((p) => /Domaine des Justices/.test(p.name))).toBe(false);

    // Closing must refuse while the product is still waiting to upload.
    await page.evaluate(() => window.closeCount1());
    await expect(page.locator('.toast')).toContainText(/still need to upload/i);

    // Back online: it lands.
    await page.evaluate(() => {
      Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => true });
      window.dispatchEvent(new Event('online'));
    });
    await expect.poll(() => db.t.kount_pending_items.filter((p) => /Domaine des Justices/.test(p.name)).length,
      { timeout: 10000 }).toBe(1);
  });
});
