// The app's "new for you" card.
//   GET   /api/surf/inbox                                   → { seenAt, prefs, items }   (signed in)
//   PATCH /api/surf/inbox { seen?: true, upvotes?, comments? } → the same, after the change
// `seen` moves the mark to now (the × on the card); `upvotes` / `comments` are
// the two toggles. Nothing is pushed: the app asks when Home shows.

import { NextRequest, NextResponse } from 'next/server'
import { getSurfUser } from '@/lib/surf/auth'
import { inbox, markSeen, setPrefs } from '@/lib/surf/inbox'

export const runtime = 'nodejs'

const err = (error: string, status: number) => NextResponse.json({ error }, { status })
const NO_STORE = { headers: { 'cache-control': 'no-store' } }

export async function GET(req: NextRequest) {
  const user = await getSurfUser(req)
  if (!user) return err('sign in first', 401)
  try {
    return NextResponse.json(await inbox(user.id), NO_STORE)
  } catch (e) {
    console.error('[surf/inbox] get', (e as Error).message)
    return err('inbox unavailable', 502)
  }
}

export async function PATCH(req: NextRequest) {
  const user = await getSurfUser(req)
  if (!user) return err('sign in first', 401)
  let body: { seen?: unknown; upvotes?: unknown; comments?: unknown } = {}
  try { body = await req.json() } catch { return err('invalid JSON', 400) }
  try {
    await setPrefs(user.id, {
      upvotes: typeof body.upvotes === 'boolean' ? body.upvotes : undefined,
      comments: typeof body.comments === 'boolean' ? body.comments : undefined,
    })
    if (body.seen === true) await markSeen(user.id)
    return NextResponse.json(await inbox(user.id), NO_STORE)
  } catch (e) {
    console.error('[surf/inbox] patch', (e as Error).message)
    return err('inbox unavailable', 502)
  }
}
