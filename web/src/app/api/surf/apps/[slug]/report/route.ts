//   POST /api/surf/apps/:slug/report { reason? } → { ok: true }
//
// Anyone can report a gallery creation, signed in or not (Apple's guideline
// 1.2: user-generated content needs a way to flag it). The report is stored
// (surf_reports) and the owner of the site gets a text and an email right
// away (src/lib/surf/notify.ts, env-configured); a failed note never fails
// the report.

import { NextRequest, NextResponse } from 'next/server'
import { getSurfUser } from '@/lib/surf/auth'
import { getApp, SITE } from '@/lib/surf/apps'
import { surfDb } from '@/lib/surf/db'
import { notifyReport } from '@/lib/surf/notify'

export const runtime = 'nodejs'

const err = (error: string, status: number) => NextResponse.json({ error }, { status })
const SLUG_RE = /^[a-z0-9]{4,12}$/
const REASON_MAX = 500

export async function POST(req: NextRequest, ctx: { params: Promise<{ slug: string }> }) {
  const { slug } = await ctx.params
  if (!SLUG_RE.test(slug)) return err('not found', 404)
  let body: { reason?: unknown } = {}
  try { body = await req.json() } catch { /* an empty body is a report too */ }
  const reason = typeof body.reason === 'string' ? body.reason.trim().slice(0, REASON_MAX) : ''
  const user = await getSurfUser(req)
  try {
    const app = await getApp(slug, null)
    if (!app) return err('not found', 404)
    const { error } = await surfDb().from('surf_reports').insert({ app_id: app.id, reporter_id: user?.id ?? null, reason })
    if (error) throw new Error(error.message)
    const line = `Token Surfers report: ${app.emoji} ${app.title} by @${app.owner}${reason ? ` — "${reason}"` : ''}${user ? ` (from @${user.handle})` : ''} ${SITE}/a/${app.slug}`
    await notifyReport(`Token Surfers: report on ${app.emoji} ${app.title}`, line)
    return NextResponse.json({ ok: true })
  } catch (e) {
    console.error('[surf/report]', (e as Error).message)
    return err('could not send the report', 502)
  }
}
