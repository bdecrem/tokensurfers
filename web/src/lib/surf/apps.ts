// Token Surfers creations: publish, list, read, upvote, unpublish.
// The whole index.html lives in surf_apps.html (apps are a few tens of KB), or,
// for an app Claude Code built on the mini, site_url points at it on Vercel.

import { surfDb } from './db'

export const HTML_MAX = 400_000
export const SITE = process.env.SURF_SITE_URL || 'https://tokensurfers.app'

export type AppCard = {
  id: string
  slug: string
  title: string
  emoji: string
  prompt: string
  owner: string
  upvotes: number
  remixOf: { slug: string; title: string } | null
  createdAt: string
  updatedAt: string
  voted: boolean
  url: string
  siteUrl: string | null
}

export type AppFull = AppCard & { html: string; remixes: number; ownerId: string }

/** The share card for a creation (the same one its deployed page links to). */
export function ogImageURL(a: { emoji: string; title: string; prompt?: string; owner?: string }): string {
  const q = new URLSearchParams({ emoji: a.emoji, title: a.title })
  if (a.prompt) q.set('line', a.prompt.slice(0, 90))
  if (a.owner) q.set('by', a.owner)
  return `${SITE}/api/surf/og?${q.toString()}`
}

const SELECT = 'id, slug, title, emoji, prompt, upvotes, created_at, updated_at, owner_id, remix_of, site_url'

type Row = {
  id: string; slug: string; title: string; emoji: string; prompt: string; upvotes: number
  created_at: string; updated_at: string; owner_id: string; remix_of: string | null; html?: string; site_url?: string | null
}

type Lookups = { owners: Map<string, string>; parents: Map<string, { slug: string; title: string }> }

/** Owner handles and remix parents for a set of rows (plain lookups, no embedded joins). */
async function lookups(rows: Row[]): Promise<Lookups> {
  const owners = new Map<string, string>()
  const parents = new Map<string, { slug: string; title: string }>()
  const ownerIds = [...new Set(rows.map((r) => r.owner_id))]
  const parentIds = [...new Set(rows.map((r) => r.remix_of).filter((x): x is string => Boolean(x)))]
  const [o, p] = await Promise.all([
    ownerIds.length ? surfDb().from('surf_users').select('id, handle').in('id', ownerIds) : Promise.resolve({ data: [] as { id: string; handle: string }[] }),
    parentIds.length ? surfDb().from('surf_apps').select('id, slug, title').in('id', parentIds) : Promise.resolve({ data: [] as { id: string; slug: string; title: string }[] }),
  ])
  for (const u of o.data ?? []) owners.set(u.id, u.handle)
  for (const a of p.data ?? []) parents.set(a.id, { slug: a.slug, title: a.title })
  return { owners, parents }
}

function toCard(r: Row, l: Lookups, voted = false): AppCard {
  const parent = r.remix_of ? l.parents.get(r.remix_of) ?? null : null
  return {
    id: r.id, slug: r.slug, title: r.title, emoji: r.emoji, prompt: r.prompt,
    owner: l.owners.get(r.owner_id) ?? 'someone', upvotes: r.upvotes,
    remixOf: parent, createdAt: r.created_at, updatedAt: r.updated_at, voted, url: `${SITE}/a/${r.slug}`,
    siteUrl: r.site_url ?? null,
  }
}

export function cleanTitle(raw: unknown): string {
  const s = typeof raw === 'string' ? raw.replace(/[\u0000-\u001f\u007f]/g, '').replace(/\s+/g, ' ').trim() : ''
  return Array.from(s).slice(0, 40).join('') || 'untitled'
}

export function cleanEmoji(raw: unknown): string {
  const s = typeof raw === 'string' ? raw.trim() : ''
  const chars = Array.from(s)
  return chars.length > 0 && chars.length <= 2 ? s : '✨'
}

export function cleanPrompt(raw: unknown): string {
  const s = typeof raw === 'string' ? raw.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '').trim() : ''
  return Array.from(s).slice(0, 500).join('')
}

async function votedSet(userId: string | null, ids: string[]): Promise<Set<string>> {
  if (!userId || ids.length === 0) return new Set()
  const { data } = await surfDb().from('surf_upvotes').select('app_id').eq('user_id', userId).in('app_id', ids)
  return new Set((data ?? []).map((r) => r.app_id as string))
}

export async function listApps(sort: 'top' | 'new', viewer: string | null, limit = 50, owner?: string): Promise<AppCard[]> {
  let q = surfDb().from('surf_apps').select(SELECT).eq('published', true)
  if (owner) q = q.eq('owner_id', owner)
  q = sort === 'top'
    ? q.order('upvotes', { ascending: false }).order('created_at', { ascending: false })
    : q.order('created_at', { ascending: false })
  const { data, error } = await q.limit(limit)
  if (error) throw new Error(error.message)
  const rows = (data ?? []) as unknown as Row[]
  const [voted, l] = await Promise.all([votedSet(viewer, rows.map((r) => r.id)), lookups(rows)])
  return rows.map((r) => toCard(r, l, voted.has(r.id)))
}

export async function getApp(slug: string, viewer: string | null): Promise<AppFull | null> {
  const { data, error } = await surfDb().from('surf_apps').select(`${SELECT}, html`).eq('slug', slug).eq('published', true).maybeSingle()
  if (error) throw new Error(error.message)
  if (!data) return null
  const r = data as unknown as Row
  const [{ count }, voted, l] = await Promise.all([
    surfDb().from('surf_apps').select('id', { count: 'exact', head: true }).eq('remix_of', r.id).eq('published', true),
    votedSet(viewer, [r.id]),
    lookups([r]),
  ])
  return { ...toCard(r, l, voted.has(r.id)), html: r.html ?? '', remixes: count ?? 0, ownerId: r.owner_id }
}

function newSlug(): string {
  const chars = 'abcdefghjkmnpqrstuvwxyz23456789'
  let s = ''
  for (let i = 0; i < 7; i++) s += chars[Math.floor(Math.random() * chars.length)]
  return s
}

/** Publish (insert) or re-publish (update the row this device's project already has). */
export async function publish(args: {
  ownerId: string; clientId: string; title: string; emoji: string; prompt: string; html: string; siteUrl?: string | null; remixOfSlug?: string | null
}): Promise<AppCard> {
  const db = surfDb()
  let remixOf: string | null = null
  if (args.remixOfSlug) {
    const { data } = await db.from('surf_apps').select('id').eq('slug', args.remixOfSlug).maybeSingle()
    remixOf = data?.id ?? null
  }
  const { data: existing } = await db.from('surf_apps').select('id, slug').eq('owner_id', args.ownerId).eq('client_id', args.clientId).maybeSingle()
  if (existing) {
    const { data, error } = await db.from('surf_apps')
      .update({ title: args.title, emoji: args.emoji, prompt: args.prompt, html: args.html, site_url: args.siteUrl ?? null, published: true, updated_at: new Date().toISOString() })
      .eq('id', existing.id).select(SELECT).single()
    if (error) throw new Error(error.message)
    const row = data as unknown as Row
    return toCard(row, await lookups([row]))
  }
  for (let attempt = 0; attempt < 5; attempt++) {
    const { data, error } = await db.from('surf_apps').insert({
      slug: newSlug(), owner_id: args.ownerId, client_id: args.clientId, title: args.title, emoji: args.emoji,
      prompt: args.prompt, html: args.html, site_url: args.siteUrl ?? null, remix_of: remixOf,
    }).select(SELECT).single()
    if (!error) {
      const row = data as unknown as Row
      return toCard(row, await lookups([row]))
    }
    if (error.code !== '23505') throw new Error(error.message)
  }
  throw new Error('could not allocate a slug')
}

export async function unpublish(slug: string, ownerId: string): Promise<boolean> {
  const { data, error } = await surfDb().from('surf_apps').update({ published: false }).eq('slug', slug).eq('owner_id', ownerId).select('id')
  if (error) throw new Error(error.message)
  return (data ?? []).length > 0
}

export async function toggleUpvote(slug: string, userId: string): Promise<{ voted: boolean; upvotes: number } | null> {
  const db = surfDb()
  const { data: app } = await db.from('surf_apps').select('id').eq('slug', slug).eq('published', true).maybeSingle()
  if (!app) return null
  const { data, error } = await db.rpc('surf_toggle_upvote', { p_app: app.id, p_user: userId })
  if (error) throw new Error(error.message)
  const row = Array.isArray(data) ? data[0] : data
  return { voted: Boolean(row?.voted), upvotes: Number(row?.upvotes ?? 0) }
}
