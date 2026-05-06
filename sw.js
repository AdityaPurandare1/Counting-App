const CACHE_NAME = 'hwood-count-v1.31';

// Allowlist: only same-origin static assets are cached. Anything dynamic
// (Supabase REST, Edge Functions, auth, third-party CDNs) passes through
// to the network with no service-worker involvement, so responses are
// never stored and never served stale.
//
// Match by BASENAME (not absolute path) so a deploy under a subpath like
// /Counting-App/counting-app.html still hits the allowlist. The scope root
// itself (whatever pathname this SW is registered at — '/' or
// '/Counting-App/') is matched separately.
const STATIC_BASENAMES = [
  'counting-app.html',
  'index.html',
  'items.json',
  'manifest.json',
  'sw.js',
  '404.html',
];
const STATIC_EXTENSIONS = /\.(png|jpg|jpeg|svg|webp|ico|woff2?|ttf|otf|eot)$/i;

let _scopePathname = null;
function scopePathname() {
  if (_scopePathname !== null) return _scopePathname;
  try { _scopePathname = new URL(self.registration.scope).pathname; }
  catch (e) { _scopePathname = '/'; }
  return _scopePathname;
}

function shouldCache(request) {
  if (request.method !== 'GET') return false;
  let url;
  try { url = new URL(request.url); } catch (e) { return false; }
  if (url.origin !== self.location.origin) return false;
  if (url.pathname === scopePathname()) return true;
  for (let i = 0; i < STATIC_BASENAMES.length; i++) {
    if (url.pathname.endsWith('/' + STATIC_BASENAMES[i])) return true;
  }
  if (STATIC_EXTENSIONS.test(url.pathname)) return true;
  return false;
}

self.addEventListener('install', event => {
  self.skipWaiting();
});

self.addEventListener('fetch', event => {
  if (!shouldCache(event.request)) {
    // No respondWith → browser handles the request normally, bypassing
    // the SW entirely. Critical for Supabase/Edge Function calls.
    return;
  }
  // Network-first for static assets so deploys land instantly online,
  // with cache as the offline fallback.
  event.respondWith(
    fetch(event.request)
      .then(response => {
        if (response.ok) {
          const clone = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(event.request, clone));
        }
        return response;
      })
      .catch(() => caches.match(event.request))
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(names => Promise.all(
      names.filter(n => n !== CACHE_NAME).map(n => caches.delete(n))
    )).then(() => self.clients.claim())
  );
});
