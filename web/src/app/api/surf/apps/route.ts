// Token Surfers creations.
//   GET  /api/surf/apps?sort=top|new&limit=50&mine=1  → { apps }   (public; `voted` when signed in)
//   POST /api/surf/apps { client_id, title, emoji, prompt, html | site_url, remix_of? } → { app }   (signed in)
// Publishing the same client_id again updates that creation in place.

import { NextRequest, NextResponse } from 'next/server'
import { getSurfUser } from '@/lib/surf/auth'
import { cleanEmoji, cleanPrompt, cleanTitle, HTML_MAX, listApps, publish } from '@/lib/surf/apps'

export const runtime = 'nodejs'

const err = (error: string, status: number) => NextResponse.json({ error }, { status })

export async function GET(req: NextRequest) {
  const user = await getSurfUser(req)
  const sort = req.nextUrl.searchParams.get('sort') === 'new' ? 'new' : 'top'
  const limit = Math.min(100, Math.max(1, Number(req.nextUrl.searchParams.get('limit')) || 50))
  const mine = req.nextUrl.searchParams.get('mine') === '1'
  if (mine && !user) return err('sign in first', 401)
  try {
    const apps = await listApps(sort, user?.id ?? null, limit, mine ? user!.id : undefined)
    return NextResponse.json({ apps }, { headers: { 'cache-control': 'no-store' } })
  } catch (e) {
    console.error('[surf/apps] list', (e as Error).message)
    return err('gallery unavailable', 502)
  }
}

export async function POST(req: NextRequest) {
  const user = await getSurfUser(req)
  if (!user) return err('sign in first', 401)
  let body: Record<string, unknown>
  try {
    body = await req.json()
  } catch {
    return err('invalid JSON', 400)
  }
  const clientId = typeof body.client_id === 'string' && /^[A-Za-z0-9-]{4,64}$/.test(body.client_id) ? body.client_id : null
  if (!clientId) return err('client_id required', 400)
  const html = typeof body.html === 'string' ? body.html : ''
  // an app Claude Code deployed: the gallery plays it from Vercel, nothing to host
  const siteUrl = typeof body.site_url === 'string' && /^https:\/\/[a-z0-9-]+(\.[a-z0-9-]+)*\.vercel\.app\/?$/i.test(body.site_url)
    ? body.site_url.replace(/\/$/, '') : null
  if (!siteUrl && html.trim().length < 20) return err('there is no app to publish yet', 400)
  if (html.length > HTML_MAX) return err(`the app is too big to host (${Math.round(html.length / 1000)} KB, max ${HTML_MAX / 1000} KB)`, 413)
  try {
    const app = await publish({
      ownerId: user.id, clientId, title: cleanTitle(body.title), emoji: cleanEmoji(body.emoji),
      prompt: cleanPrompt(body.prompt), html: siteUrl ? '' : html, siteUrl,
      remixOfSlug: typeof body.remix_of === 'string' && /^[a-z0-9]{4,12}$/.test(body.remix_of) ? body.remix_of : null,
    })
    return NextResponse.json({ app })
  } catch (e) {
    console.error('[surf/apps] publish', (e as Error).message)
    return err('could not publish', 502)
  }
}
