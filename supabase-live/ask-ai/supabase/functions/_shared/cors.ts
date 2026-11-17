// CORS for browser-to-Edge-Function calls. The mobile PWA runs on a different
// origin than the Supabase project, so OPTIONS preflight has to succeed before
// the POST goes through.
//
// Allow-Origin is no longer '*': only origins in KOUNT_ALLOWED_ORIGINS
// (comma-separated; an entry ending in ':*' matches any port) get it echoed
// back. This only limits browsers; the JWT checks in each function are the
// real gate.
export const corsHeaders = {
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const DEFAULT_ALLOWED_ORIGINS = [
  'https://adityapurandare1.github.io',
  'https://kount.kevaos.ai',
  'capacitor://localhost', // the iOS app (apps/mobile)
  'http://localhost:*',
  'http://127.0.0.1:*',
];

const allowedOrigins = (Deno.env.get('KOUNT_ALLOWED_ORIGINS') || '')
  .split(',').map((s) => s.trim()).filter(Boolean);
const ALLOWED = allowedOrigins.length > 0 ? allowedOrigins : DEFAULT_ALLOWED_ORIGINS;

export function isAllowedOrigin(origin: string): boolean {
  return ALLOWED.some((entry) => {
    if (entry === origin) return true;
    if (!entry.endsWith(':*')) return false;
    const prefix = entry.slice(0, -1); // keep the ':'
    return origin.startsWith(prefix) && /^\d+$/.test(origin.slice(prefix.length));
  });
}

// Wraps a handler so every response (including OPTIONS and errors) carries the
// caller's Origin when it is allowed. Handlers keep using corsHeaders as before.
export function withCors(handler: (req: Request) => Response | Promise<Response>) {
  return async (req: Request): Promise<Response> => {
    const res = await handler(req);
    const origin = req.headers.get('Origin');
    if (origin && isAllowedOrigin(origin)) {
      res.headers.set('Access-Control-Allow-Origin', origin);
    }
    res.headers.append('Vary', 'Origin');
    return res;
  };
}
