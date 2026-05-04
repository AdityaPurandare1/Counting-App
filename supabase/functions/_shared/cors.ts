// Standard CORS headers for browser-to-Edge-Function calls. The mobile PWA
// runs on a different origin than the Supabase project, so OPTIONS preflight
// has to succeed before the POST goes through.
export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
