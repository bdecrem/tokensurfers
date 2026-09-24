// Token Surfers — the global leaderboard.
//
//   GET  /api/surf/scores?device=<id>&limit=50 → { top, you, surfers }
//   POST /api/surf/scores { device, handle, score, coins, distance, mode, version }
//        → { rank, best, top }
//
// Gate: x-surf-key must equal SURF_APP_KEY (the app's build secret). The
// device id is minted by the app on first launch; the handle is whatever the
// player typed, cleaned. Scores are checked against what the engine can
// produce for the run's distance and coins.

import { NextRequest, NextResponse } from 'next/server'
import { cleanHandle, leaderboard, plausible, submit, validDevice } from '@/lib/surf/scores'

export const runtime = 'nodejs'

const err = (error: string, status: number) => NextResponse.json({ error }, { status })

function gate(req: NextRequest): NextResponse | null {
  const expected = process.env.SURF_APP_KEY
  if (!expected) return err('SURF_APP_KEY is not configured', 500)
  if (req.headers.get('x-surf-key') !== expected) return err('bad key', 403)
  return null
}

export async function GET(req: NextRequest) {
  const blocked = gate(req)
  if (blocked) return blocked
  const device = req.nextUrl.searchParams.get('device')
  const limit = Math.min(100, Math.max(1, Number(req.nextUrl.searchParams.get('limit')) || 50))
  try {
    const board = await leaderboard(validDevice(device) ? device : null, limit)
    return NextResponse.json(board, { headers: { 'cache-control': 'no-store' } })
  } catch (e) {
    console.error('[surf/scores] read', (e as Error).message)
    return err('leaderboard unavailable', 502)
  }
}

export async function POST(req: NextRequest) {
  const blocked = gate(req)
  if (blocked) return blocked
  let body: Record<string, unknown>
  try {
    body = await req.json()
  } catch {
    return err('invalid JSON', 400)
  }
  const { device, score, coins, distance } = body
  if (!validDevice(device)) return err('device required', 400)
  const s = Number(score), c = Number(coins ?? 0), d = Number(distance ?? 0)
  if (!plausible(s, c, d)) return err('that score is not a real run', 400)
  const version = typeof body.version === 'string' ? body.version.slice(0, 32) : null
  try {
    const result = await submit({
      device, handle: cleanHandle(body.handle), score: s, coins: c, distance: d,
      mode: String(body.mode ?? 'solo'), version,
    })
    return NextResponse.json(result)
  } catch (e) {
    console.error('[surf/scores] write', (e as Error).message)
    return err('leaderboard unavailable', 502)
  }
}
