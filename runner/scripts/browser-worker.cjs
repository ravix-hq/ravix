/* Private machine service. One persistent profile, one controller, many tabs.
 * Deployed as source so the Sprite uses its own Node and Chromium installation. */
const fs = require('node:fs/promises');
const path = require('node:path');
const http = require('node:http');
const { randomUUID, timingSafeEqual } = require('node:crypto');
const { chromium } = require('playwright-core');
const VERSION = 1;
const LIMIT = 16 * 1024 * 1024;
const WIDTH = 1280, HEIGHT = 800;
const fail = (message, status = 422) => Object.assign(new Error(message), { status });
const webURL = value => {
  if (typeof value !== 'string' || value.length > 8192) throw fail('Supply an HTTP or HTTPS URL.');
  const url = new URL(value);
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw fail('Supply an HTTP or HTTPS URL without embedded credentials.');
  return url.href;
};

async function createWorker({ directory, executablePath, token, port = 0 }) {
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  const manifestPath = path.join(directory, 'session.json');
  const read = async file => { try { return JSON.parse(await fs.readFile(file, 'utf8')); } catch (error) { if (error.code === 'ENOENT') return null; throw error; } };
  const atomic = async (file, value) => { await fs.writeFile(file + '.tmp', JSON.stringify(value), { mode: 0o600 }); await fs.rename(file + '.tmp', file); };
  let manifest = await read(manifestPath) || { profile: randomUUID(), tabs: [] };
  if (!/^[a-f0-9-]{36}$/.test(manifest.profile)) throw fail('Invalid saved profile.');
  let context, controller = null, revision = randomUUID(), sequence = 0, closing = false, tail = Promise.resolve();
  const pages = new Map();
  const serial = fn => { const task = tail.then(fn); tail = task.catch(() => {}); return task; };
  const lease = () => { if (controller && controller.expires <= Date.now()) controller = null; return controller; };
  const launch = async profile => chromium.launchPersistentContext(path.join(directory, profile), {
    executablePath, headless: true, viewport: { width: WIDTH, height: HEIGHT },
    acceptDownloads: false, chromiumSandbox: true, timeout: 15000,
  });
  const register = (page, id = randomUUID()) => {
    if ([...pages.values()].includes(page)) return;
    if (pages.size >= 20) { void page.close().catch(() => {}); return; }
    pages.set(id, page);
    page.setDefaultTimeout(8000); page.setDefaultNavigationTimeout(15000);
    page.on('dialog', dialog => void dialog.dismiss().catch(() => {}));
    page.on('close', () => pages.delete(id));
  };
  const attach = async next => {
    context = next;
    context.setDefaultTimeout(8000);
    for (const page of context.pages()) await page.close();
    context.on('page', page => register(page));
  };
  const tabs = async () => Promise.all([...pages].map(async ([id, page]) => ({ id, url: page.url(), title: await page.title().catch(() => '') })));
  const state = async () => ({ tabs: await tabs(), controller: lease(), revision, sequence: ++sequence });
  const save = async () => {
    manifest.tabs = (await tabs()).filter(tab => /^https?:/.test(tab.url));
    await Promise.all(manifest.tabs.map(async tab => {
      tab.sessionStorage = await pages.get(tab.id).evaluate(() => Object.fromEntries(Object.entries(sessionStorage))).catch(() => ({}));
    }));
    await atomic(manifestPath, manifest);
    // Preserve session cookies as well as Chromium's on-disk persistent cookies.
    await atomic(path.join(directory, manifest.profile, 'switchyard-storage.json'), await context.storageState({ indexedDB: true }));
  };
  const reopen = async entries => {
    await Promise.all(entries.slice(0, 20).map(async entry => {
      const url = webURL(entry.url), page = await context.newPage();
      const assigned = [...pages].find(([, p]) => p === page)?.[0];
      if (assigned) pages.delete(assigned);
      register(page, entry.id || randomUUID());
      if (entry.sessionStorage) await page.addInitScript(({ origin, items }) => {
        if (location.origin === origin) for (const [key, value] of Object.entries(items)) sessionStorage.setItem(key, String(value));
      }, { origin: new URL(url).origin, items: entry.sessionStorage });
      await page.goto(url, { waitUntil: 'commit', timeout: 8000 }).catch(() => {});
    }));
  };
  await attach(await launch(manifest.profile));
  const savedStorage = await read(path.join(directory, manifest.profile, 'switchyard-storage.json'));
  if (savedStorage) await context.setStorageState(savedStorage);
  await reopen(manifest.tabs);
  const requireControl = actor => {
    if (!actor || lease()?.id !== actor.id) throw fail('Take control before changing the shared browser.', 409);
    controller.expires = Date.now() + 30000;
  };
  const snapshot = async () => {
    const entries = (await tabs()).filter(tab => /^https?:/.test(tab.url));
    for (const tab of entries) {
      webURL(tab.url);
      tab.sessionStorage = await pages.get(tab.id).evaluate(() => Object.fromEntries(Object.entries(sessionStorage))).catch(() => ({}));
    }
    return { version: VERSION, engine: 'chromium', storage: await context.storageState({ indexedDB: true }), tabs: entries };
  };
  async function command(body) {
    const { action, actor } = body;
    if (action === 'status') return state();
    if (action === 'acquire') {
      if (!actor || !['human', 'agent'].includes(actor.kind) || typeof actor.id !== 'string' || typeof actor.label !== 'string') throw fail('Invalid controller.');
      const current = lease();
      if (current && current.id !== actor.id && !(actor.kind === 'human' && current.kind === 'agent')) throw fail(`${current.label} is controlling the shared browser.`, 409);
      controller = { id: actor.id, kind: actor.kind, label: actor.label, expires: Date.now() + 30000 };
      return state();
    }
    if (action === 'release') { if (lease()?.id === actor?.id) controller = null; return state(); }
    if (action === 'checkpoint') { requireControl(actor); await save(); return snapshot(); }
    if (action === 'restore') {
      requireControl(actor);
      const cp = body.checkpoint;
      if (!cp || cp.version !== VERSION || cp.engine !== 'chromium' || !Array.isArray(cp.tabs) || cp.tabs.length > 20 || !Array.isArray(cp.storage?.cookies) || !Array.isArray(cp.storage?.origins)) throw fail('Unsupported browser checkpoint.');
      for (const tab of cp.tabs) webURL(tab.url);
      await save();
      const previous = manifest;
      await context.close(); pages.clear();
      const next = { profile: randomUUID(), tabs: [] };
      try {
        await attach(await launch(next.profile));
        await context.setStorageState(cp.storage);
        await reopen(cp.tabs);
        manifest = next;
        await save();
      } catch (error) {
        await context.close().catch(() => {}); pages.clear(); manifest = previous;
        await attach(await launch(previous.profile));
        const storage = await read(path.join(directory, previous.profile, 'switchyard-storage.json'));
        if (storage) await context.setStorageState(storage);
        await reopen(previous.tabs);
        await atomic(manifestPath, previous);
        await fs.rm(path.join(directory, next.profile), { recursive: true, force: true });
        controller = null; revision = randomUUID();
        throw error;
      }
      controller = null; revision = randomUUID();
      await fs.rm(path.join(directory, previous.profile), { recursive: true, force: true }).catch(() => {});
      return state();
    }
    let page = body.tabId && pages.get(body.tabId);
    if (action === 'open') {
      requireControl(actor); const url = webURL(body.url);
      if (pages.size >= 20) throw fail('Close a tab before opening another.');
      page = await context.newPage();
      await page.goto(url, { waitUntil: 'domcontentloaded' });
      await save();
      return { ...await state(), tabId: [...pages].find(([, p]) => p === page)[0] };
    }
    if (!page || page.isClosed()) throw fail('This tab has closed. Refresh the browser.', 404);
    if (action === 'screenshot') return { ...await state(), image: (await page.screenshot({ type: 'jpeg', quality: 65, timeout: 8000 })).toString('base64') };
    if (action === 'inspect') return { ...await state(), text: (await page.locator('body').ariaSnapshot()).slice(0, 64000) };
    requireControl(actor);
    if (body.revision !== revision) throw fail('The browser was restored or restarted. Refresh before interacting.', 409);
    const point = () => {
      if (![body.x, body.y].every(v => typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= 1)) throw fail('Invalid input coordinates.');
      return { x: body.x * (WIDTH - 1), y: body.y * (HEIGHT - 1) };
    };
    switch (action) {
      case 'navigate': await page.goto(webURL(body.url), { waitUntil: 'domcontentloaded' }); break;
      case 'close': await page.close(); break;
      case 'back': await page.goBack({ waitUntil: 'domcontentloaded' }); break;
      case 'forward': await page.goForward({ waitUntil: 'domcontentloaded' }); break;
      case 'reload': await page.reload({ waitUntil: 'domcontentloaded' }); break;
      case 'click': { const p = point(); await page.mouse.click(p.x, p.y); break; }
      case 'scroll': {
        const p = point();
        if (![body.deltaX, body.deltaY].every(v => typeof v === 'number' && Number.isFinite(v) && Math.abs(v) <= 2000)) throw fail('Invalid scroll.');
        await page.mouse.move(p.x, p.y); await page.mouse.wheel(body.deltaX, body.deltaY); break;
      }
      case 'text': if (typeof body.text !== 'string' || body.text.length > 16000) throw fail('Text is too long.'); await page.keyboard.insertText(body.text); break;
      case 'key': if (typeof body.key !== 'string' || body.key.length > 80) throw fail('Invalid key.'); await page.keyboard.press(body.key); break;
      default: throw fail('Unknown browser command.');
    }
    return state();
  }
  const server = http.createServer(async (req, res) => {
    res.setHeader('cache-control', 'no-store');
    res.setHeader('content-type', 'application/json');
    const supplied = Buffer.from(req.headers.authorization || ''), expected = Buffer.from(`Bearer ${token}`);
    if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected) || req.headers.origin || req.method !== 'POST' || req.url !== '/command') {
      res.writeHead(403); res.end(JSON.stringify({ error: 'Browser access denied.' })); return;
    }
    try {
      let size = 0; const chunks = [];
      for await (const chunk of req) { size += chunk.length; if (size > LIMIT) throw fail('Browser request is too large.', 413); chunks.push(chunk); }
      const body = JSON.parse(Buffer.concat(chunks).toString());
      const result = await serial(() => { if (closing) throw fail('Browser is stopping.', 503); return command(body); });
      res.end(JSON.stringify(result));
    } catch (error) { res.writeHead(error.status || 422); res.end(JSON.stringify({ error: String(error.message).slice(0, 500) })); }
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  const timer = setInterval(() => { if (!closing) void serial(save).catch(() => {}); }, 30000);
  return { server, port: server.address().port, close: async () => {
    closing = true; clearInterval(timer); server.close(); server.closeIdleConnections();
    await serial(async () => { await save(); await context.close(); });
  } };
}
module.exports = { createWorker };
if (require.main === module) {
  (async () => {
    const directory = process.env.SWITCHYARD_BROWSER_DIR;
    if (!directory) throw Error('SWITCHYARD_BROWSER_DIR is required.');
    const token = (await fs.readFile(path.join(directory, 'token'), 'utf8')).trim();
    if (token.length < 32) throw Error('Invalid browser service credential.');
    const worker = await createWorker({ directory, token, executablePath: process.env.SWITCHYARD_CHROMIUM || undefined, port: Number(process.env.PORT || 40000) });
    console.log(`Shared browser listening on loopback:${worker.port}`);
    let stopping = false;
    for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => { if (stopping) return; stopping = true; void worker.close().finally(() => process.exit(0)); });
  })().catch(error => { console.error(error.message); process.exit(1); });
}
