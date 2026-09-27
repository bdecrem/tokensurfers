//   DELETE /api/surf/apps/:slug/comments/:id → { ok: true, comments }   (the author, or the creation's owner)

import { NextRequest, NextResponse } from 'next/server'
import { getSurfUser } from '@/lib/surf/auth'
import { deleteComment } from '@/lib/surf/comments'

export const runtime = 'nodejs'

const err = (error: string, status: number) => NextResponse.json({ error }, { status })
const SLUG_RE = /^[a-z0-9]{4,12}$/
const UUID_RE = /^[0-9a-f-]{36}$/i

export async function DELETE(req: NextRequest, ctx: { params: Promise<{ slug: string; id: string }> }) {
  const { slug, id } = await ctx.params
  if (!SLUG_RE.test(slug) || !UUID_RE.test(id)) return err('not found', 404)
  const user = await getSurfUser(req)
  if (!user) return err('sign in first', 401)
  try {
    const r = await deleteComment(slug, id, user.id)
    if (r === 'gone') return err('not found', 404)
    if (r === 'forbidden') return err('not yours', 403)
    return NextResponse.json({ ok: true, comments: r.comments })
  } catch (e) {
    console.error('[surf/comments] delete', (e as Error).message)
    return err('could not delete that', 502)
  }
}
