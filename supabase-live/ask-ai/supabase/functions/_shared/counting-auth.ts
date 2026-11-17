// Who may use the AI functions: exactly the people the database lets count.
//
// The caller's OWN JWT must resolve to a user (the anon key is public and
// resolves to no user, so it gets 401). Then kount_is_active_user() is called
// AS THE CALLER, so it sees their auth.jwt() and applies the same rule RLS
// does: an active app_users row, or (after 0093) an access grant or Keva
// membership that reaches at least one venue.
//
// Rollout fallback: until 0091 is applied the RPC does not exist, so we fall
// back to the older service-role app_users check instead of locking everyone
// out. shortcut: drop the fallback once 0091 is applied everywhere.

import { createClient, SupabaseClient, User } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { corsHeaders } from './cors.ts';

// 2026-11 key rotation: read the new API keys (SUPABASE_SECRET_KEYS / SUPABASE_PUBLISHABLE_KEYS are JSON maps
// keyed by key name). Legacy env fallback only until the legacy keys are disabled; remove it at cleanup.
function newApiKey(mapEnv: string, names: string[], legacyEnv: string): string {
  try {
    const m = JSON.parse(Deno.env.get(mapEnv) ?? "{}") as Record<string, string>;
    for (const n of names) if (typeof m?.[n] === "string" && m[n]) return m[n];
  } catch { /* fall through */ }
  return Deno.env.get(legacyEnv) ?? "";
}
const NEW_SECRET_KEY = () => newApiKey("SUPABASE_SECRET_KEYS", ["keva_secret_2026_11", "default"], "SUPABASE_SERVICE_ROLE_KEY");
const NEW_PUBLISHABLE_KEY = () => newApiKey("SUPABASE_PUBLISHABLE_KEYS", ["default"], "SUPABASE_ANON_KEY");


const SUPABASE_URL = Deno.env.get('SUPABASE_URL') || '';
const SUPABASE_ANON_KEY = NEW_PUBLISHABLE_KEY();
const SUPABASE_SERVICE_ROLE_KEY = NEW_SECRET_KEY();

// PostgREST: PGRST202 = function not in schema cache; 42883 = undefined_function.
const MISSING_FUNCTION_CODES = new Set(['PGRST202', '42883']);

function deny(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

export async function requireCountingUser(
  req: Request,
  tag: string,
): Promise<{ user: User; callerClient: SupabaseClient } | Response> {
  const authHeader = req.headers.get('Authorization') || '';
  const callerJwt = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!callerJwt) return deny(401, 'Missing Authorization header');

  const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: 'Bearer ' + callerJwt } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userResp, error: userErr } = await callerClient.auth.getUser();
  if (userErr || !userResp.user || !userResp.user.email) {
    return deny(401, 'Invalid or expired JWT');
  }
  const user = userResp.user;

  const { data: allowed, error: rpcErr } = await callerClient.rpc('kount_is_active_user');
  if (!rpcErr) {
    return allowed === true ? { user, callerClient } : deny(403, 'Caller is not an active app user');
  }
  if (!MISSING_FUNCTION_CODES.has(rpcErr.code)) {
    console.error(`[${tag}] access check error:`, rpcErr);
    return deny(500, 'Failed to verify caller');
  }

  // Service-role lookup so a gap in the app_users SELECT policy can't turn
  // into an auth bypass.
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: profile, error: profileErr } = await admin
    .from('app_users')
    .select('is_active')
    .eq('email', user.email!.toLowerCase())
    .limit(1)
    .maybeSingle();
  if (profileErr) {
    console.error(`[${tag}] profile lookup error:`, profileErr);
    return deny(500, 'Failed to verify caller');
  }
  if (!profile || profile.is_active === false) {
    return deny(403, 'Caller is not an active app user');
  }
  return { user, callerClient };
}
