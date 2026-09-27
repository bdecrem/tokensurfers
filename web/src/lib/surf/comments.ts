// Comments on gallery creations (surf_comments, schema 005). Anyone signed in
// can comment on a published creation; the author or the creation's owner can
// delete one. surf_apps.comments is the count, kept exact by the two SQL
// functions.

import { surfDb } from './db'

export const COMMENT_MAX = 500
export const MAX_COMMENTS_PER_DAY = Number(process.env.SURF_MAX_COMMENTS_PER_DAY || 100)

export type Comment = {
  id: string
  handle: string
  body: string
  createdAt: string
  mine: boolean
  canDelete: boolean   // mine, or on my creation
}

export class CommentCap extends Error {}

/** Control characters out, runs of blanks collapsed, at most COMMENT_MAX characters. */
export function cleanComment(raw: unknown): string {
  const s = typeof raw === 'string'
    ? raw.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '').replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim()
    : ''
  return Array.from(s).slice(0, COMMENT_MAX).join('').trim()
}

type Row = { id: string; user_id: string; body: string; created_at: string }

async function handles(ids: string[]): Promise<Map<string, string>> {
  const m = new Map<string, string>()
  if (ids.length === 0) return m
  const { data } = await surfDb().from('surf_users').select('id, handle').in('id', ids)
  for (const u of data ?? []) m.set(u.id, u.handle)
  return m
}

function toComment(r: Row, h: Map<string, string>, ownerId: string, viewer: string | null): Comment {
  const mine = viewer !== null && r.user_id === viewer
  return {
    id: r.id, handle: h.get(r.user_id) ?? 'someone', body: r.body, createdAt: r.created_at,
    mine, canDelete: mine || (viewer !== null && viewer === ownerId),
  }
}

/** Newest first. */
export async function listComments(appId: string, ownerId: string, viewer: string | null, limit = 100): Promise<Comment[]> {
  const { data, error } = await surfDb().from('surf_comments').select('id, user_id, body, created_at')
    .eq('app_id', appId).order('created_at', { ascending: false }).limit(limit)
  if (error) throw new Error(error.message)
  const rows = (data ?? []) as Row[]
  const h = await handles([...new Set(rows.map((r) => r.user_id))])
  return rows.map((r) => toComment(r, h, ownerId, viewer))
}

async function appBySlug(slug: string): Promise<{ id: string; owner_id: string } | null> {
  const { data, error } = await surfDb().from('surf_apps').select('id, owner_id').eq('slug', slug).eq('published', true).maybeSingle()
  if (error) throw new Error(error.message)
  return data ?? null
}

const utcDayStart = () => new Date(new Date().toISOString().slice(0, 10) + 'T00:00:00Z').toISOString()

/** null when the creation doesn't exist; throws CommentCap past the daily allowance. */
export async function addComment(slug: string, user: { id: string; handle: string }, body: string): Promise<{ comment: Comment; comments: number } | null> {
  const db = surfDb()
  const app = await appBySlug(slug)
  if (!app) return null
  const { count } = await db.from('surf_comments').select('id', { count: 'exact', head: true }).eq('user_id', user.id).gte('created_at', utcDayStart())
  if ((count ?? 0) >= MAX_COMMENTS_PER_DAY) throw new CommentCap(`that's ${MAX_COMMENTS_PER_DAY} comments today — back tomorrow`)
  const { data, error } = await db.rpc('surf_add_comment', { p_app: app.id, p_user: user.id, p_body: body })
  if (error) throw new Error(error.message)
  const row = (Array.isArray(data) ? data[0] : data) as { id: string; created_at: string; comments: number }
  return {
    comment: { id: row.id, handle: user.handle, body, createdAt: row.created_at, mine: true, canDelete: true },
    comments: Number(row.comments ?? 0),
  }
}

/** 'gone' when there is no such comment on that creation, 'forbidden' when the caller may not, else the new count. */
export async function deleteComment(slug: string, commentId: string, userId: string): Promise<{ comments: number } | 'gone' | 'forbidden'> {
  const db = surfDb()
  const app = await appBySlug(slug)
  if (!app) return 'gone'
  const { data: c, error } = await db.from('surf_comments').select('id, user_id').eq('id', commentId).eq('app_id', app.id).maybeSingle()
  if (error) throw new Error(error.message)
  if (!c) return 'gone'
  if (c.user_id !== userId && app.owner_id !== userId) return 'forbidden'
  const { data, error: e2 } = await db.rpc('surf_delete_comment', { p_comment: commentId })
  if (e2) throw new Error(e2.message)
  return { comments: Number(data ?? 0) }
}
