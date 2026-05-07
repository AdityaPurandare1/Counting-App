// supabase/functions/admin-user-mgmt/index.ts
//
// Edge Function: server-side proxy for the admin portal's user-lifecycle
// actions. The phone + admin SPA can never hold the SUPABASE_SERVICE_ROLE_KEY
// (it would ship to browsers), so all admin-only auth operations route here.
//
// Env: SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY are
// all auto-injected by the Supabase Edge platform — no secrets to set
// manually for this function.
//
// Auth model:
//   1. Caller must present their own JWT in the Authorization header.
//   2. We resolve that JWT to a user, look them up in app_users, and reject
//      if their role isn't 'corporate'. Even if a managed admin somehow
//      got the function URL, they can't bypass the role check.
//   3. Only after both checks do we instantiate the service-role client
//      and perform the requested action.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { corsHeaders } from '../_shared/cors.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') || '';
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') || '';
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';

type Role = 'corporate' | 'manager' | 'counter';

interface InvitePayload {
  action: 'invite';
  email: string;
  name?: string;
  role: Role;
  venue_ids?: string[];
  redirect_to?: string;  // where the invite link sends the user (defaults to app origin)
}

interface DisablePayload  { action: 'disable';  email: string; }
interface EnablePayload   { action: 'enable';   email: string; }
interface DeletePayload   { action: 'delete';   email: string; }
interface ResetPayload    { action: 'reset_password'; email: string; redirect_to?: string; }
interface UpdatePayload {
  action: 'update_profile';
  email: string;
  name?: string;
  role?: Role;
  venue_ids?: string[];
  is_active?: boolean;
}

interface MigrateLegacyPayload {
  action: 'migrate_legacy';
  dry_run?: boolean;
  redirect_to?: string;
}

type Payload =
  | InvitePayload | DisablePayload | EnablePayload
  | DeletePayload | ResetPayload | UpdatePayload
  | MigrateLegacyPayload;

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function reject(status: number, message: string): Response {
  return jsonResponse(status, { error: message });
}

// App identity tag we write into auth.users.user_metadata.apps so we can
// distinguish Counting-App users from sibling apps (e.g. Keva) sharing
// this Supabase project. Multi-app users have multiple entries in this
// array; smart-delete checks it before tearing down the auth account.
const APP_TAG = 'kount';

// auth.users isn't exposed via PostgREST by default. Migration 0018 added
// SECURITY DEFINER RPCs (find_auth_user_by_email + list_auth_user_emails)
// granted only to service_role — Edge Functions invoke them from the admin
// client. This replaced the prior admin.auth.admin.listUsers() approach,
// which was O(n) (paged scan through every auth user) and occasionally
// returned "Database error finding users" on multi-app projects.
async function findAuthUserByEmail(
  admin: ReturnType<typeof createClient>,
  email: string,
): Promise<{ id: string; user_metadata: Record<string, unknown> } | null> {
  const { data, error } = await admin.rpc('find_auth_user_by_email', { p_email: email.toLowerCase() });
  if (error) throw new Error('find_auth_user_by_email rpc failed: ' + error.message);
  const row = (data as Array<{ user_id: string; user_metadata: Record<string, unknown> | null }> | null)?.[0];
  if (!row) return null;
  return { id: row.user_id, user_metadata: (row.user_metadata || {}) as Record<string, unknown> };
}

// Convenience for the existing single-purpose callers.
async function findAuthUserIdByEmail(admin: ReturnType<typeof createClient>, email: string): Promise<string | null> {
  const u = await findAuthUserByEmail(admin, email);
  return u?.id ?? null;
}

// Returns the app-tags array from user metadata, normalized. Treats
// missing / non-array values as empty.
function appTagsFromMetadata(meta: Record<string, unknown> | null | undefined): string[] {
  if (!meta) return [];
  const v = (meta as { apps?: unknown }).apps;
  if (!Array.isArray(v)) return [];
  return v.filter((x): x is string => typeof x === 'string');
}

// Adds APP_TAG to the apps array if not already present. Returns the
// merged metadata to pass to updateUserById. Idempotent.
function metadataWithKountTag(existing: Record<string, unknown> | null | undefined): Record<string, unknown> {
  const base = (existing || {}) as Record<string, unknown>;
  const tags = appTagsFromMetadata(base);
  if (tags.includes(APP_TAG)) return base;
  return { ...base, apps: [...tags, APP_TAG] };
}

// Removes APP_TAG from the apps array. Returns the updated metadata.
// Idempotent (no-op if APP_TAG isn't in the list).
function metadataWithoutKountTag(existing: Record<string, unknown> | null | undefined): Record<string, unknown> {
  const base = (existing || {}) as Record<string, unknown>;
  const tags = appTagsFromMetadata(base);
  if (!tags.includes(APP_TAG)) return base;
  return { ...base, apps: tags.filter((t) => t !== APP_TAG) };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST')    return reject(405, 'Method not allowed');

  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return reject(500, 'Edge Function misconfigured: missing SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY in secrets');
  }

  // --- 1. Verify caller presented a JWT ---
  const authHeader = req.headers.get('Authorization') || '';
  const callerJwt = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!callerJwt) return reject(401, 'Missing Authorization header');

  // --- 2. Resolve the JWT to a real user (Supabase Auth API, not RLS-gated). ---
  const supabaseAsCaller = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: 'Bearer ' + callerJwt } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: userResp, error: userErr } = await supabaseAsCaller.auth.getUser();
  if (userErr || !userResp.user || !userResp.user.email) {
    return reject(401, 'Invalid or expired JWT');
  }
  const callerEmail = userResp.user.email.toLowerCase();

  // --- 3. Service-role client. Used both for the role-check lookup
  // (bypasses any RLS gaps on app_users for the authenticated role) and
  // for the privileged actions below. Defense-in-depth: even if the dev
  // policies forget to grant SELECT to authenticated, the role check
  // still works. ---
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // --- 4. Authorize: only corporate role can hit this function. ---
  const { data: callerProfile, error: profileErr } = await admin
    .from('app_users')
    .select('role,is_active')
    .eq('email', callerEmail)
    .limit(1)
    .maybeSingle();

  if (profileErr) {
    console.error('[admin-user-mgmt] profile lookup error:', profileErr);
    return reject(500, 'Failed to verify caller role');
  }
  if (!callerProfile || callerProfile.is_active === false) {
    return reject(403, 'Caller is not an active app user');
  }
  if (callerProfile.role !== 'corporate') {
    return reject(403, 'Corporate role required');
  }

  // --- 5. Parse + dispatch ---
  let body: Payload;
  try {
    body = await req.json();
  } catch {
    return reject(400, 'Body must be JSON');
  }
  if (!body || typeof body !== 'object' || !body.action) {
    return reject(400, 'Body must include an `action`');
  }

  try {
    switch (body.action) {
      case 'invite':          return await handleInvite(admin, body, callerEmail);
      case 'disable':         return await handleDisable(admin, body, callerEmail);
      case 'enable':          return await handleEnable(admin, body, callerEmail);
      case 'delete':          return await handleDelete(admin, body, callerEmail);
      case 'reset_password':  return await handleResetPassword(admin, body, callerEmail);
      case 'update_profile':  return await handleUpdateProfile(admin, body, callerEmail);
      case 'migrate_legacy':  return await handleMigrateLegacy(admin, body, callerEmail);
      default:
        return reject(400, 'Unknown action: ' + (body as { action?: string }).action);
    }
  } catch (e) {
    console.error('[admin-user-mgmt] action threw:', e);
    return reject(500, 'Action failed: ' + ((e as Error).message || 'unknown'));
  }
});

// -----------------------------------------------------------------------------
// Action handlers
// -----------------------------------------------------------------------------

async function handleInvite(
  admin: ReturnType<typeof createClient>,
  payload: InvitePayload,
  callerEmail: string,
): Promise<Response> {
  const email = (payload.email || '').toLowerCase().trim();
  if (!email || !email.includes('@')) return reject(400, 'Valid email required');
  if (!payload.role || !['corporate', 'manager', 'counter'].includes(payload.role)) {
    return reject(400, 'role must be corporate | manager | counter');
  }
  const venueIds = Array.isArray(payload.venue_ids) ? payload.venue_ids : [];

  const profileRow = {
    email,
    name: payload.name || email,
    role: payload.role,
    venue_ids: venueIds,
    is_active: true,
  };

  // Send the invite email. The user clicks the link → lands on the app →
  // Supabase establishes their session → app prompts for password.
  // We tag user_metadata.apps with APP_TAG so we can later distinguish
  // Counting-App users from sibling-app users on the shared project.
  const { data: invited, error: inviteErr } = await admin.auth.admin.inviteUserByEmail(email, {
    redirectTo: payload.redirect_to,
    data: metadataWithKountTag(null),  // becomes user_metadata
  });

  if (inviteErr || !invited.user) {
    // "Already registered" means the email exists in auth.users — possibly
    // from a sibling app on the same Supabase project. Two sub-cases:
    //   (a) They're ALSO in our app_users → true duplicate, 409.
    //   (b) They're in auth.users but NOT in app_users → just add them to
    //       Counting-App. They already have a password from the other app
    //       context; no invite email is needed (and would fail anyway).
    //       We MERGE the kount tag into their existing user_metadata.apps
    //       so a future cross-app delete can see they're multi-app.
    if (/already.*registered|already.*exist|user_repeated_signup/i.test(inviteErr?.message || '')) {
      const existing = await findAuthUserByEmail(admin, email);
      if (!existing) {
        return reject(500, 'Auth says user exists but lookup failed: ' + (inviteErr?.message || 'unknown'));
      }
      const { data: existingProfile, error: profileLookupErr } = await admin
        .from('app_users')
        .select('email')
        .eq('email', email)
        .maybeSingle();
      if (profileLookupErr) {
        return reject(500, 'app_users lookup failed: ' + profileLookupErr.message);
      }
      if (existingProfile) {
        return reject(409, 'User already in this app — use Edit instead');
      }
      // Merge kount tag without disturbing other-app tags.
      const mergedMeta = metadataWithKountTag(existing.user_metadata);
      const { error: tagErr } = await admin.auth.admin.updateUserById(existing.id, {
        user_metadata: mergedMeta,
      });
      if (tagErr) {
        // Don't hard-fail — tagging is observability, not security. Log
        // and proceed to the app_users insert.
        console.warn('[admin-user-mgmt] tag merge failed (continuing):', tagErr);
      }
      const { error: linkErr } = await admin.from('app_users').insert(profileRow);
      if (linkErr) {
        return reject(500, 'Failed to add existing user to app_users: ' + linkErr.message);
      }
      const otherApps = appTagsFromMetadata(existing.user_metadata).filter((t) => t !== APP_TAG);
      console.log('[admin-user-mgmt] linked existing auth user by', callerEmail, '→', email, 'other_apps=', otherApps);
      return jsonResponse(200, {
        ok: true,
        email,
        user_id: existing.id,
        action: 'invite',
        linked_existing_user: true,
        other_apps: otherApps,  // tells UI which sibling apps the user is also in
      });
    }
    return reject(500, 'Invite failed: ' + (inviteErr?.message || 'unknown'));
  }

  // Normal new-user path: provision the app_users row. Upsert so a re-
  // invite of someone whose app_users row was created by hand still
  // lands consistently.
  const { error: profErr } = await admin.from('app_users').upsert(profileRow, { onConflict: 'email' });
  if (profErr) {
    // Best-effort rollback so we don't leave an orphaned auth user. If the
    // rollback ALSO fails, log loudly — admin will need to clean up the
    // dangling auth.users row by hand.
    const rb = await admin.auth.admin.deleteUser(invited.user.id).then(
      () => null,
      (rbErr: Error) => rbErr,
    );
    if (rb) {
      console.error('[admin-user-mgmt] ROLLBACK FAILED — orphan auth user:', invited.user.id, email, rb);
      return reject(500, 'app_users upsert failed AND auth rollback failed — clean up auth.users row for ' + email + ' manually. Original error: ' + profErr.message);
    }
    return reject(500, 'app_users upsert failed (auth user rolled back): ' + profErr.message);
  }

  console.log('[admin-user-mgmt] invite issued by', callerEmail, '→', email);
  return jsonResponse(200, { ok: true, email, user_id: invited.user.id, action: 'invite' });
}

async function handleDisable(
  admin: ReturnType<typeof createClient>,
  payload: DisablePayload,
  callerEmail: string,
): Promise<Response> {
  const email = (payload.email || '').toLowerCase().trim();
  if (!email) return reject(400, 'email required');
  if (email === callerEmail) return reject(400, 'Cannot disable yourself');

  const userId = await findAuthUserIdByEmail(admin, email);
  if (!userId) {
    // Auth user missing — only flip app_users so the legacy/in-flight
    // record stops working in the app.
    await admin.from('app_users').update({ is_active: false }).eq('email', email);
    return jsonResponse(200, { ok: true, email, action: 'disable', note: 'no auth user; app_users is_active=false' });
  }

  // 100 years ≈ permanent ban. Existing JWTs become invalid within the
  // refresh window (~1 hour); if you need instant kick-out, we'd also
  // call admin.auth.admin.signOut(userId) but that's a 2.x method.
  const { error: banErr } = await admin.auth.admin.updateUserById(userId, { ban_duration: '876000h' });
  if (banErr) return reject(500, 'Ban failed: ' + banErr.message);

  await admin.from('app_users').update({ is_active: false }).eq('email', email);
  console.log('[admin-user-mgmt] disable by', callerEmail, '→', email);
  return jsonResponse(200, { ok: true, email, user_id: userId, action: 'disable' });
}

async function handleEnable(
  admin: ReturnType<typeof createClient>,
  payload: EnablePayload,
  callerEmail: string,
): Promise<Response> {
  const email = (payload.email || '').toLowerCase().trim();
  if (!email) return reject(400, 'email required');

  const userId = await findAuthUserIdByEmail(admin, email);
  if (!userId) return reject(404, 'No auth user for that email — invite them instead');

  const { error: unbanErr } = await admin.auth.admin.updateUserById(userId, { ban_duration: 'none' });
  if (unbanErr) return reject(500, 'Unban failed: ' + unbanErr.message);

  await admin.from('app_users').update({ is_active: true }).eq('email', email);
  console.log('[admin-user-mgmt] enable by', callerEmail, '→', email);
  return jsonResponse(200, { ok: true, email, user_id: userId, action: 'enable' });
}

async function handleDelete(
  admin: ReturnType<typeof createClient>,
  payload: DeletePayload,
  callerEmail: string,
): Promise<Response> {
  const email = (payload.email || '').toLowerCase().trim();
  if (!email) return reject(400, 'email required');
  if (email === callerEmail) return reject(400, 'Cannot delete yourself');

  const existing = await findAuthUserByEmail(admin, email);

  // Smart delete based on the user_metadata.apps tag.
  //   - If the auth user has tags for OTHER apps (e.g. ['kount','keva'])
  //     → preserve auth.users so they keep working in those apps; just
  //     strip the kount tag and remove our app_users row.
  //   - If the auth user is kount-only (or has no tag at all) → remove
  //     auth.users entirely as before.
  // Either branch always removes the app_users row.
  let keptAuthAccount = false;
  let otherApps: string[] = [];
  if (existing) {
    const tags = appTagsFromMetadata(existing.user_metadata);
    otherApps = tags.filter((t) => t !== APP_TAG);
    if (otherApps.length > 0) {
      // Multi-app user — keep their auth account, just untag kount.
      const { error: untagErr } = await admin.auth.admin.updateUserById(existing.id, {
        user_metadata: metadataWithoutKountTag(existing.user_metadata),
      });
      if (untagErr) console.warn('[admin-user-mgmt] untag failed (continuing):', untagErr);
      keptAuthAccount = true;
    } else {
      const { error: delErr } = await admin.auth.admin.deleteUser(existing.id);
      if (delErr) return reject(500, 'auth delete failed: ' + delErr.message);
    }
  }
  // Always remove the app_users row.
  await admin.from('app_users').delete().eq('email', email);
  console.log('[admin-user-mgmt] delete by', callerEmail, '→', email,
    keptAuthAccount ? '(kept auth, also in ' + otherApps.join(',') + ')' : '(full delete)');
  return jsonResponse(200, {
    ok: true,
    email,
    action: 'delete',
    kept_auth_account: keptAuthAccount,
    other_apps: otherApps,
  });
}

async function handleResetPassword(
  admin: ReturnType<typeof createClient>,
  payload: ResetPayload,
  callerEmail: string,
): Promise<Response> {
  const email = (payload.email || '').toLowerCase().trim();
  if (!email) return reject(400, 'email required');

  // Two calls, by design:
  //   1. resetPasswordForEmail — this is what actually triggers Supabase
  //      to SEND the recovery email via the project's SMTP. generateLink
  //      alone does NOT send anything (it just returns a link); that was
  //      a real bug from the first pass of this function.
  //   2. generateLink — gives us back the recovery link in the response
  //      so the admin UI can show "if they don't receive the email,
  //      copy this link". Belt-and-braces for flaky SMTP.
  // If (1) succeeds and (2) fails, we still return ok — the user got
  // their email and that's the main thing.
  const { error: sendErr } = await admin.auth.resetPasswordForEmail(email, {
    redirectTo: payload.redirect_to,
  });
  if (sendErr) return reject(500, 'Reset email failed to send: ' + sendErr.message);

  let actionLink: string | null = null;
  try {
    const { data: linkData, error: linkErr } = await admin.auth.admin.generateLink({
      type: 'recovery',
      email,
      options: { redirectTo: payload.redirect_to },
    });
    if (!linkErr) actionLink = linkData?.properties?.action_link || null;
  } catch (e) {
    console.warn('[admin-user-mgmt] generateLink fallback failed (email already sent):', e);
  }

  console.log('[admin-user-mgmt] reset_password by', callerEmail, '→', email);
  return jsonResponse(200, {
    ok: true,
    email,
    action: 'reset_password',
    action_link: actionLink,
  });
}

async function handleUpdateProfile(
  admin: ReturnType<typeof createClient>,
  payload: UpdatePayload,
  callerEmail: string,
): Promise<Response> {
  const email = (payload.email || '').toLowerCase().trim();
  if (!email) return reject(400, 'email required');

  const update: Record<string, unknown> = {};
  if (typeof payload.name === 'string')          update.name = payload.name;
  if (typeof payload.role === 'string') {
    if (!['corporate', 'manager', 'counter'].includes(payload.role)) {
      return reject(400, 'role must be corporate | manager | counter');
    }
    update.role = payload.role;
  }
  if (Array.isArray(payload.venue_ids))          update.venue_ids = payload.venue_ids;
  if (typeof payload.is_active === 'boolean')    update.is_active = payload.is_active;

  if (Object.keys(update).length === 0) return reject(400, 'Nothing to update');

  // Guard: don't let an admin demote themselves out of corporate (would
  // lock them out of this function on the very next call).
  if (email === callerEmail && update.role && update.role !== 'corporate') {
    return reject(400, 'Cannot demote yourself out of corporate role');
  }
  if (email === callerEmail && update.is_active === false) {
    return reject(400, 'Cannot deactivate yourself');
  }

  const { error } = await admin.from('app_users').update(update).eq('email', email);
  if (error) return reject(500, 'app_users update failed: ' + error.message);

  console.log('[admin-user-mgmt] update_profile by', callerEmail, '→', email, Object.keys(update).join(','));
  return jsonResponse(200, { ok: true, email, action: 'update_profile', updated_fields: Object.keys(update) });
}

// One-shot migration: walk every active app_users row, find the ones that
// don't have a matching auth.users yet, and invite them. Dry-run mode
// returns the candidate list without sending any emails — admin should
// always dry-run first to confirm the target set before triggering real
// invite emails.
async function handleMigrateLegacy(
  admin: ReturnType<typeof createClient>,
  payload: MigrateLegacyPayload,
  callerEmail: string,
): Promise<Response> {
  const dryRun = !!payload.dry_run;

  // 1. Pull all active app_users.
  const { data: appUsersData, error: appErr } = await admin
    .from('app_users')
    .select('email, name, role, venue_ids, is_active')
    .eq('is_active', true);
  if (appErr) return reject(500, 'Failed to load app_users: ' + appErr.message);
  const appUsers = (appUsersData || []) as Array<{ email: string; name: string | null; role: Role; venue_ids: string[] | null; is_active: boolean }>;

  // 2. Pull all auth.users emails via the SECURITY DEFINER RPC from
  // migration 0018. Single indexed query — replaces the prior paged
  // listUsers scan that occasionally hit "Database error finding users".
  const { data: authRows, error: authErr } = await admin.rpc('list_auth_user_emails');
  if (authErr) return reject(500, 'list_auth_user_emails rpc failed: ' + authErr.message);
  const authEmails = new Set<string>(
    ((authRows as Array<{ email: string }> | null) || []).map((r) => r.email),
  );

  // 3. Diff.
  const needsInvite = appUsers.filter((u) => !authEmails.has((u.email || '').toLowerCase()));
  const alreadyAuthed = appUsers.length - needsInvite.length;

  if (dryRun) {
    return jsonResponse(200, {
      ok: true,
      action: 'migrate_legacy',
      dry_run: true,
      total_active: appUsers.length,
      already_authed: alreadyAuthed,
      would_invite_count: needsInvite.length,
      would_invite: needsInvite.map((u) => ({ email: u.email, name: u.name, role: u.role })),
    });
  }

  // 4. Apply: invite each. We do NOT re-upsert app_users since the rows
  // already exist (we just queried them). Per-user errors don't stop
  // the loop — we collect and return them so admin can see exactly who
  // failed and retry just those.
  const results: Array<{ email: string; ok: boolean; user_id?: string; error?: string }> = [];
  for (const u of needsInvite) {
    const targetEmail = (u.email || '').toLowerCase().trim();
    if (!targetEmail) {
      results.push({ email: u.email || '(blank)', ok: false, error: 'empty email' });
      continue;
    }
    try {
      const { data: invited, error: inviteErr } = await admin.auth.admin.inviteUserByEmail(targetEmail, {
        redirectTo: payload.redirect_to,
      });
      if (inviteErr || !invited.user) {
        results.push({ email: targetEmail, ok: false, error: inviteErr?.message || 'no user returned' });
        continue;
      }
      results.push({ email: targetEmail, ok: true, user_id: invited.user.id });
    } catch (e) {
      results.push({ email: targetEmail, ok: false, error: (e as Error).message });
    }
  }

  const ok = results.filter((r) => r.ok).length;
  const failed = results.length - ok;
  console.log('[admin-user-mgmt] migrate_legacy by', callerEmail, '— invited', ok, '/ failed', failed);
  return jsonResponse(200, {
    ok: true,
    action: 'migrate_legacy',
    dry_run: false,
    total_active: appUsers.length,
    already_authed: alreadyAuthed,
    invited: ok,
    failed,
    results,
  });
}
