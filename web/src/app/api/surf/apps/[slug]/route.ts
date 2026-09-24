//   GET    /api/surf/apps/:slug → { app } with html (public)
//   DELETE /api/surf/apps/:slug → unpublish (owner)

import { NextRequest, NextResponse } from 'next/server'
import { getSurfUser } from '@/lib/surf/auth'
import { getApp, unpublish } from '@/lib/surf/apps'

export const runtime = 'nodejs'

const err = (error: string, status: number) => NextResponse.json({ error }, { status })
const SLUG_RE = /^[a-z0-9]{4,12}$/

export async function GET(req: NextRequest, ctx: { params: Promise<{ slug: string }> }) {
  const { slug } = await ctx.params
  if (!SLUG_RE.test(slug)) return err('not found', 404)
  const user = await getSurfUser(req)
  try {
    const app = await getApp(slug, user?.id ?? null)
    if (!app) return err('not found', 404)
    return NextResponse.json({ app }, { headers: { 'cache-control': 'no-store' } })
  } catch (e) {
    console.error('[surf/apps] get', (e as Error).message)
    return err('gallery unavailable', 502)
  }
}

export async function DELETE(req: NextRequest, ctx: { params: Promise<{ slug: string }> }) {
  const { slug } = await ctx.params
  if (!SLUG_RE.test(slug)) return err('not found', 404)
  const user = await getSurfUser(req)
  if (!user) return err('sign in first', 401)
  try {
    const ok = await unpublish(slug, user.id)
    return ok ? NextResponse.json({ ok: true }) : err('not yours, or not found', 404)
  } catch (e) {
    console.error('[surf/apps] delete', (e as Error).message)
    return err('could not unpublish', 502)
  }
}
