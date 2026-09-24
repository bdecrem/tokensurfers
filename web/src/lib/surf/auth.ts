// Token Surfers accounts: handle + password, an HMAC-signed session token.
// The app sends it as `Authorization: Bearer <token>`; the web gallery keeps
// it in the httpOnly cookie `surf_session`. Same shape as Jam auth
// (src/lib/jam/auth.ts), its own table and secret.

import { createHmac, timingSafeEqual } from 'node:crypto'
import bcrypt from 'bcryptjs'
import type { NextRequest, NextResponse } from 'next/server'
import { cookies } from 'next/headers'
import { surfDb } from './db'

export type SurfUser = { id: string; handle: string }

export const COOKIE_NAME = 'surf_session'
const MAX_AGE = 60 * 60 * 24 * 180 // 180 days

const HANDLE_RE = /^[a-z0-9][a-z0-9_]{1,19}$/
const PASSWORD_MIN = 4

function secret(): string {
  const s = process.env.SURF_SESSION_SECRET
  if (!s) throw new Error('SURF_SESSION_SECRET not set')
  return s
}

export function normalizeHandle(raw: unknown): string {
  return typeof raw === 'string' ? raw.trim().toLowerCase().replace(/^@/, '') : ''
}

export function validateCredentials(handle: string, password: unknown): string | null {
  if (!HANDLE_RE.test(handle)) return 'Handle: 2–20 characters, letters, numbers or underscores.'
  if (typeof password !== 'string' || password.length < PASSWORD_MIN) return `Password: at least ${PASSWORD_MIN} characters.`
  return null
}

export function signToken(userId: string): string {
  const exp = Date.now() + MAX_AGE * 1000
  const payload = `${userId}.${exp}`
  const sig = createHmac('sha256', secret()).update(payload).digest('hex')
  return `${payload}.${sig}`
}

function verifyToken(token: string): string | null {
  const parts = token.split('.')
  if (parts.length !== 3) return null
  const [userId, expStr, sig] = parts
  const expected = createHmac('sha256', secret()).update(`${userId}.${expStr}`).digest('hex')
  const a = Buffer.from(sig, 'hex')
  const b = Buffer.from(expected, 'hex')
  if (a.length !== b.length || !timingSafeEqual(a, b)) return null
  const exp = Number(expStr)
  if (!Number.isFinite(exp) || exp < Date.now()) return null
  return userId
}

export function setSessionCookie(res: NextResponse, token: string): void {
  res.cookies.set({
    name: COOKIE_NAME, value: token, httpOnly: true,
    secure: process.env.NODE_ENV === 'production', sameSite: 'lax', path: '/', maxAge: MAX_AGE,
  })
}

export function clearSessionCookie(res: NextResponse): void {
  res.cookies.set({ name: COOKIE_NAME, value: '', httpOnly: true, path: '/', maxAge: 0 })
}

async function userById(id: string): Promise<SurfUser | null> {
  const { data, error } = await surfDb().from('surf_users').select('id, handle').eq('id', id).maybeSingle()
  if (error) throw new Error(error.message)
  return data ? { id: data.id, handle: data.handle } : null
}

/** The signed-in user from a bearer header or the session cookie, else null. */
export async function getSurfUser(req?: NextRequest): Promise<SurfUser | null> {
  let token: string | undefined
  const auth = req?.headers.get('authorization')
  if (auth?.startsWith('Bearer ')) token = auth.slice(7).trim()
  if (!token) {
    try {
      token = (await cookies()).get(COOKIE_NAME)?.value
    } catch {
      token = req?.cookies.get(COOKIE_NAME)?.value
    }
  }
  if (!token) return null
  const id = verifyToken(token)
  if (!id) return null
  try {
    return await userById(id)
  } catch {
    return null
  }
}

export async function signup(handle: string, password: string): Promise<SurfUser | { error: string }> {
  const { data: existing } = await surfDb().from('surf_users').select('id').eq('handle', handle).maybeSingle()
  if (existing) return { error: 'That handle is taken.' }
  const hash = await bcrypt.hash(password, 10)
  const { data, error } = await surfDb().from('surf_users').insert({ handle, password_hash: hash }).select('id, handle').single()
  if (error) return { error: error.code === '23505' ? 'That handle is taken.' : error.message }
  return { id: data.id, handle: data.handle }
}

export async function login(handle: string, password: string): Promise<SurfUser | { error: string }> {
  const { data, error } = await surfDb().from('surf_users').select('id, handle, password_hash').eq('handle', handle).maybeSingle()
  if (error) return { error: error.message }
  if (!data || !(await bcrypt.compare(password, data.password_hash))) return { error: 'Wrong handle or password.' }
  return { id: data.id, handle: data.handle }
}
