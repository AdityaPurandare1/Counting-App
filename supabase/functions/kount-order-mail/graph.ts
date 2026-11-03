// supabase/functions/kount-order-mail/graph.ts
//
// Microsoft sign-in (device code) and the few Graph reads the morning mail pull
// makes. Delegated Mail.Read through the existing "Order Tracker" Entra app
// registration (public client, the one the desktop Order Tracker uses), so no
// client secret exists anywhere and nothing can send or change mail.

export const TENANT_ID = '6711dee9-6622-4505-b955-381bfc5305cc';
export const CLIENT_ID = 'acd56be2-30a1-4db9-b62d-5f2f9b6d6d85';
// EXACTLY what the desktop Order Tracker asks for (MSAL ["Mail.Read"] + the sign-in scopes MSAL
// adds). Anything more — User.Read, email — is a permission the user never consented to for this
// app, and the tenant then sends the sign-in for admin approval. The mailbox address comes from
// the sign-in's id token, not from /me (which would need User.Read).
export const SCOPE = 'Mail.Read openid profile offline_access';
const AUTH = `https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0`;
const GRAPH = 'https://graph.microsoft.com/v1.0';

export class GraphError extends Error {
  constructor(public status: number, public code: string, message: string, public reauth = false) { super(message); }
}

interface FormReply { ok: boolean; status: number; json: Record<string, unknown> }

async function postForm(url: string, body: Record<string, string>): Promise<FormReply> {
  const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(body) });
  const json = await r.json().catch(() => ({})) as Record<string, unknown>;
  return { ok: r.ok, status: r.status, json };
}

export async function deviceCodeStart(): Promise<{ device_code: string; user_code: string; verification_uri: string; expires_in: number; interval: number }> {
  const r = await postForm(`${AUTH}/devicecode`, { client_id: CLIENT_ID, scope: SCOPE });
  if (!r.ok) throw new GraphError(r.status, String(r.json.error ?? ''), String(r.json.error_description ?? 'Microsoft refused to start a sign-in').slice(0, 300));
  return r.json as unknown as { device_code: string; user_code: string; verification_uri: string; expires_in: number; interval: number };
}

export const deviceCodePoll = (deviceCode: string) =>
  postForm(`${AUTH}/token`, { grant_type: 'urn:ietf:params:oauth:grant-type:device_code', client_id: CLIENT_ID, device_code: deviceCode });

/** A fresh access token (+ the rotated refresh token). A dead sign-in is a GraphError with reauth = true. */
export async function refreshAccess(refreshToken: string): Promise<{ access_token: string; refresh_token?: string }> {
  const r = await postForm(`${AUTH}/token`, { grant_type: 'refresh_token', client_id: CLIENT_ID, refresh_token: refreshToken, scope: SCOPE });
  if (r.ok && r.json.access_token) return r.json as unknown as { access_token: string; refresh_token?: string };
  const code = String(r.json.error ?? '');
  const dead = code === 'invalid_grant' || code === 'interaction_required' || code === 'consent_required';
  throw new GraphError(r.status, code, dead ? 'The Outlook sign-in has expired — reconnect Outlook in the Order tracker Inbox.'
    : String(r.json.error_description ?? 'Could not refresh the Outlook sign-in').slice(0, 300), dead);
}

/** GET a Graph path (or a full @odata.nextLink). Immutable ids, so a message moved between folders keeps its id. */
export async function graphGet<T = Record<string, unknown>>(accessToken: string, pathOrUrl: string, opts: { textBody?: boolean } = {}): Promise<T> {
  const url = pathOrUrl.startsWith('https://') ? pathOrUrl : GRAPH + pathOrUrl;
  for (let attempt = 0; ; attempt++) {
    const prefer = 'IdType="ImmutableId"' + (opts.textBody ? ', outlook.body-content-type="text"' : '');
    const r = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}`, Prefer: prefer } });
    if ((r.status === 429 || r.status === 503 || r.status === 504) && attempt < 3) {
      const wait = Math.min(20, Number(r.headers.get('Retry-After')) || 2 ** attempt * 2);
      await new Promise(res => setTimeout(res, wait * 1000));
      continue;
    }
    const json = await r.json().catch(() => ({})) as Record<string, unknown>;
    if (!r.ok) {
      const err = (json.error ?? {}) as { code?: string; message?: string };
      throw new GraphError(r.status, err.code ?? '', `Outlook: ${err.message ?? r.statusText}`.slice(0, 300), r.status === 401);
    }
    return json as T;
  }
}
