// The inbox behind the app's "new for you" card: upvotes and comments on the
// signed-in user's creations since they last cleared it. Nothing is stored
// per notification — it is read off surf_upvotes and surf_comments rows newer
// than surf_users.inbox_seen_at, filtered by the two notify_* toggles
// (schema 005). Their own votes and comments never count.

import { surfDb } from './db'

export type InboxPrefs = { upvotes: boolean; comments: boolean }

export type InboxItem =
  | { kind: 'upvotes'; slug: string; title: string; emoji: string; count: number; handles: string[]; at: string }
  | { kind: 'comment'; id: string; slug: string; title: string; emoji: string; handle: string; body: string; at: string }

export type Inbox = { seenAt: string; prefs: InboxPrefs; items: InboxItem[] }

const ITEMS_MAX = 30

type UserRow = { notify_upvotes: boolean; notify_comments: boolean; inbox_seen_at: string }
type AppRow = { id: string; slug: string; title: string; emoji: string }

async function userRow(userId: string): Promise<UserRow> {
  const { data, error } = await surfDb().from('surf_users').select('notify_upvotes, notify_comments, inbox_seen_at').eq('id', userId).single()
  if (error) throw new Error(error.message)
  return data as UserRow
}

export async function inbox(userId: string): Promise<Inbox> {
  const db = surfDb()
  const u = await userRow(userId)
  const prefs = { upvotes: u.notify_upvotes, comments: u.notify_comments }
  const seenAt = u.inbox_seen_at
  const base: Inbox = { seenAt, prefs, items: [] }
  if (!prefs.upvotes && !prefs.comments) return base

  const { data: appsData, error } = await db.from('surf_apps').select('id, slug, title, emoji').eq('owner_id', userId).eq('published', true)
  if (error) throw new Error(error.message)
  const apps = new Map((appsData ?? []).map((a) => [a.id, a as AppRow]))
  if (apps.size === 0) return base
  const ids = [...apps.keys()]

  const [votes, comments] = await Promise.all([
    prefs.upvotes
      ? db.from('surf_upvotes').select('app_id, user_id, created_at').in('app_id', ids).gt('created_at', seenAt).neq('user_id', userId)
        .order('created_at', { ascending: false }).limit(300)
      : Promise.resolve({ data: [] as { app_id: string; user_id: string; created_at: string }[], error: null }),
    prefs.comments
      ? db.from('surf_comments').select('id, app_id, user_id, body, created_at').in('app_id', ids).gt('created_at', seenAt).neq('user_id', userId)
        .order('created_at', { ascending: false }).limit(60)
      : Promise.resolve({ data: [] as { id: string; app_id: string; user_id: string; body: string; created_at: string }[], error: null }),
  ])
  if (votes.error) throw new Error(votes.error.message)
  if (comments.error) throw new Error(comments.error.message)

  const userIds = new Set<string>()
  for (const v of votes.data ?? []) userIds.add(v.user_id)
  for (const c of comments.data ?? []) userIds.add(c.user_id)
  const handles = new Map<string, string>()
  if (userIds.size > 0) {
    const { data } = await db.from('surf_users').select('id, handle').in('id', [...userIds])
    for (const r of (data ?? []) as { id: string; handle: string }[]) handles.set(r.id, r.handle)
  }
  const handleOf = (id: string) => handles.get(id) ?? 'someone'

  const items: InboxItem[] = []
  // upvotes grouped per creation: "▲ 3 on Snake · @a, @b"
  const grouped = new Map<string, { count: number; handles: string[]; at: string }>()
  for (const v of votes.data ?? []) {
    const g = grouped.get(v.app_id) ?? { count: 0, handles: [] as string[], at: v.created_at }
    g.count++
    const h = handleOf(v.user_id)
    if (g.handles.length < 3 && !g.handles.includes(h)) g.handles.push(h)
    if (v.created_at > g.at) g.at = v.created_at
    grouped.set(v.app_id, g)
  }
  for (const [appId, g] of grouped) {
    const a = apps.get(appId)!
    items.push({ kind: 'upvotes', slug: a.slug, title: a.title, emoji: a.emoji, count: g.count, handles: g.handles, at: g.at })
  }
  for (const c of comments.data ?? []) {
    const a = apps.get(c.app_id)!
    items.push({ kind: 'comment', id: c.id, slug: a.slug, title: a.title, emoji: a.emoji, handle: handleOf(c.user_id), body: c.body, at: c.created_at })
  }
  items.sort((x, y) => (x.at < y.at ? 1 : x.at > y.at ? -1 : 0))
  return { seenAt, prefs, items: items.slice(0, ITEMS_MAX) }
}

/** The × on the card: everything up to now is seen. */
export async function markSeen(userId: string): Promise<void> {
  const { error } = await surfDb().from('surf_users').update({ inbox_seen_at: new Date().toISOString() }).eq('id', userId)
  if (error) throw new Error(error.message)
}

export async function setPrefs(userId: string, prefs: Partial<InboxPrefs>): Promise<void> {
  const patch: Record<string, boolean> = {}
  if (typeof prefs.upvotes === 'boolean') patch.notify_upvotes = prefs.upvotes
  if (typeof prefs.comments === 'boolean') patch.notify_comments = prefs.comments
  if (Object.keys(patch).length === 0) return
  const { error } = await surfDb().from('surf_users').update(patch).eq('id', userId)
  if (error) throw new Error(error.message)
}
