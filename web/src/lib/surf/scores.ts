// Token Surfers leaderboard: surf_scores (every run) and the
// surf_leaderboard view (best run per device). apps/tokensurfers/schema/001.

import { createClient, type SupabaseClient } from '@supabase/supabase-js'

let _client: SupabaseClient | null = null
function db() {
  if (!_client) {
    const url = process.env.SUPABASE_URL
    const key = process.env.SUPABASE_SERVICE_KEY
    if (!url || !key) throw new Error('SUPABASE_URL or SUPABASE_SERVICE_KEY is not set')
    _client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
  }
  return _client
}

export type LeaderRow = { rank: number; handle: string; score: number; coins: number; distance: number; you: boolean }
export type You = { rank: number; best: number; handle: string }

const DEVICE_RE = /^[A-Za-z0-9-]{8,64}$/

export function validDevice(id: unknown): id is string {
  return typeof id === 'string' && DEVICE_RE.test(id)
}

/** Trims, strips control characters, caps at 16 characters. Empty → "surfer". */
export function cleanHandle(raw: unknown): string {
  if (typeof raw !== 'string') return 'surfer'
  const s = raw.replace(/[\u0000-\u001f\u007f]/g, '').replace(/\s+/g, ' ').trim()
  const chars = Array.from(s).slice(0, 16).join('').trim()
  return chars || 'surfer'
}

/** Plausibility: the engine can't score more than this for a run's distance and coins. */
export function plausible(score: number, coins: number, distance: number): boolean {
  if (![score, coins, distance].every((n) => Number.isInteger(n) && n >= 0)) return false
  if (score > 5_000_000 || coins > 100_000 || distance > 500_000) return false
  return score <= distance * 2 + coins * 50 + 5_000
}

async function rankOf(score: number): Promise<number> {
  const { count, error } = await db().from('surf_leaderboard').select('*', { count: 'exact', head: true }).gt('score', score)
  if (error) throw new Error(error.message)
  return (count ?? 0) + 1
}

export async function leaderboard(device: string | null, limit = 50): Promise<{ top: LeaderRow[]; you: You | null; surfers: number }> {
  const { data, error, count } = await db()
    .from('surf_leaderboard')
    .select('device_id, handle, score, coins, distance', { count: 'exact' })
    .order('score', { ascending: false })
    .order('created_at', { ascending: true })
    .limit(limit)
  if (error) throw new Error(error.message)
  const top: LeaderRow[] = (data ?? []).map((r, i) => ({
    rank: i + 1, handle: r.handle, score: r.score, coins: r.coins, distance: r.distance, you: r.device_id === device,
  }))
  let you: You | null = null
  if (device) {
    const mine = top.find((r) => r.you)
    if (mine) {
      you = { rank: mine.rank, best: mine.score, handle: mine.handle }
    } else {
      const { data: row, error: e2 } = await db().from('surf_leaderboard').select('handle, score').eq('device_id', device).maybeSingle()
      if (e2) throw new Error(e2.message)
      if (row) you = { rank: await rankOf(row.score), best: row.score, handle: row.handle }
    }
  }
  return { top, you, surfers: count ?? top.length }
}

export async function submit(args: {
  device: string; handle: string; score: number; coins: number; distance: number; mode: string; version: string | null
}): Promise<{ rank: number; best: number; top: boolean }> {
  const { device, handle } = args
  // A renamed surfer keeps one name on the board.
  const { error: e1 } = await db().from('surf_scores').update({ handle }).eq('device_id', device).neq('handle', handle)
  if (e1) throw new Error(e1.message)
  const { error: e2 } = await db().from('surf_scores').insert({
    device_id: device, handle, score: args.score, coins: args.coins, distance: args.distance,
    mode: args.mode === 'build' ? 'build' : 'solo', app_version: args.version,
  })
  if (e2) throw new Error(e2.message)
  const { data: row, error: e3 } = await db().from('surf_leaderboard').select('score').eq('device_id', device).maybeSingle()
  if (e3) throw new Error(e3.message)
  const best = row?.score ?? args.score
  const rank = await rankOf(best)
  return { rank, best, top: rank <= 50 }
}
