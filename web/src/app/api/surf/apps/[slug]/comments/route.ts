//   GET  /api/surf/apps/:slug/comments          → { comments: [...] }        (public; mine/canDelete when signed in)
//   POST /api/surf/apps/:slug/comments { body } → { comment, comments }     (signed in; comments = the new count)

import { NextRequest, NextResponse } from 'next/server'
import { getSurfUser } from '@/lib/surf/auth'
import { getApp } from '@/lib/surf/apps'
import { addComment, cleanComment, CommentCap, listComments } from '@/lib/surf/comments'

export const runtime = 'nodejs'

const err = (error: string, status: number) => NextResponse.json({ error }, { status })
const SLUG_RE = /^[a-z0-9]{4,12}$/

export async function GET(req: NextRequest, ctx: { params: Promise<{ slug: string }> }) {
  const { slug } = await ctx.params
  if (!SLUG_RE.test(slug)) return err('not found', 404)
  const user = await getSurfUser(req)
  try {
    const app = await getApp(slug, null)
    if (!app) return err('not found', 404)
    const comments = await listComments(app.id, app.ownerId, user?.id ?? null)
    return NextResponse.json({ comments, count: app.comments }, { headers: { 'cache-control': 'no-store' } })
  } catch (e) {
    console.error('[surf/comments] list', (e as Error).message)
    return err('comments unavailable', 502)
  }
}

export async function POST(req: NextRequest, ctx: { params: Promise<{ slug: string }> }) {
  const { slug } = await ctx.params
  if (!SLUG_RE.test(slug)) return err('not found', 404)
  const user = await getSurfUser(req)
  if (!user) return err('sign in first', 401)
  let body: { body?: unknown } = {}
  try { body = await req.json() } catch { return err('invalid JSON', 400) }
  const text = cleanComment(body.body)
  if (!text) return err('say something first', 400)
  try {
    const result = await addComment(slug, user, text)
    if (!result) return err('not found', 404)
    return NextResponse.json(result)
  } catch (e) {
    if (e instanceof CommentCap) return err(e.message, 429)
    console.error('[surf/comments] add', (e as Error).message)
    return err('could not post that', 502)
  }
}
