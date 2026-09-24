import { createClient, type SupabaseClient } from '@supabase/supabase-js'

let _client: SupabaseClient | null = null

/** Service-role client for the surf_* tables (lazy: never at module top level). */
export function surfDb(): SupabaseClient {
  if (!_client) {
    const url = process.env.SUPABASE_URL
    const key = process.env.SUPABASE_SERVICE_KEY
    if (!url || !key) throw new Error('SUPABASE_URL or SUPABASE_SERVICE_KEY is not set')
    _client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
  }
  return _client
}
