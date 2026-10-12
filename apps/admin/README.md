# Admin Foundation

Minimal Next.js shell for moderation and master-data workflows.

Required environment:

```text
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_ANON_KEY=
```

Use Supabase Auth plus an admin role claim/table before enabling write actions. Do not use service role keys in browser code.
