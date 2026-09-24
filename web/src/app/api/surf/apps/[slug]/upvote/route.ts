//   POST /api/surf/apps/:slug/upvote → { voted, upvotes }  (toggles; signed in)

import { NextRequest, NextResponse } from 'next/server'
import { getSurfUser } from '@/lib/surf/auth'
import { toggleUpvote } from '@/lib/surf/apps'

export const runtime = 'nodejs'

export async function POST(req: NextRequest, ctx: { params: Promise<{ slug: string }> }) {
  const { slug } = await ctx.params
  const user = await getSurfUser(req)
  if (!user) return NextResponse.json({ error: 'sign in first' }, { status: 401 })
  try {
    const result = await toggleUpvote(slug, user.id)
    if (!result) return NextResponse.json({ error: 'not found' }, { status: 404 })
    return NextResponse.json(result)
  } catch (e) {
    console.error('[surf/apps] upvote', (e as Error).message)
    return NextResponse.json({ error: 'could not upvote' }, { status: 502 })
  }
}
