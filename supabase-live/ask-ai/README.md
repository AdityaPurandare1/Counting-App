# ask-ai: the LIVE build (not the one in supabase/functions/ask-ai)

The `ask-ai` Edge Function that is live on mnraeesscqsaappkaldb (v16 on 2026-11-17) was deployed from a copy of the
code that is not in this repository: it has its own sign-in check (`_shared/counting-auth.ts`) and origin-limited
CORS (`_shared/cors.ts` with `withCors`). Those two files differ from `supabase/functions/_shared/`, and copying its
`cors.ts` there would take `Access-Control-Allow-Origin: *` away from every other function here.

This folder is that live build, downloaded on 2026-11-17, with ONE change: the Anthropic-direct branch is removed, so
the function runs on OpenRouter only (the user: "lets switch all to openrouter please"). Deploy it from here, as its
own project folder, so nothing else changes:

```sh
cd supabase-live/ask-ai
supabase functions deploy ask-ai --project-ref mnraeesscqsaappkaldb --use-api
```

verify_jwt stays true (the default; the live function has it on). Do not deploy `supabase/functions/ask-ai` over it
without first merging what this build has.
