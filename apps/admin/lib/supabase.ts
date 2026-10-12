import { createClient } from '@supabase/supabase-js';

// The admin browser bundle is intentionally limited to the public anon key.
// Global-admin authorization is evaluated by the database on every RPC call.
export const supabase = createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:55321',
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? 'phase15-local-anon-key',
  { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } },
);
