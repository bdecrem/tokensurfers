// Shared handler for signup and login: JSON in, { token, user } out, and
// the session cookie set for browsers. The app keeps the token; the web
// keeps the cookie.

import { NextRequest, NextResponse } from 'next/server'
import { login, normalizeHandle, setSessionCookie, signToken, signup, validateCredentials, type SurfUser } from './auth'

export async function handleAuth(req: NextRequest, mode: 'signup' | 'login'): Promise<NextResponse> {
  let body: { handle?: unknown; password?: unknown }
  try {
    body = await req.json()
  } catch {
    return NextResponse.json({ error: 'invalid JSON' }, { status: 400 })
  }
  const handle = normalizeHandle(body.handle)
  const password = typeof body.password === 'string' ? body.password : ''
  const invalid = validateCredentials(handle, password)
  if (invalid) return NextResponse.json({ error: invalid }, { status: 400 })
  let result: SurfUser | { error: string }
  try {
    result = mode === 'signup' ? await signup(handle, password) : await login(handle, password)
  } catch (e) {
    console.error(`[surf/auth] ${mode}`, (e as Error).message)
    return NextResponse.json({ error: 'accounts are unavailable right now' }, { status: 502 })
  }
  if ('error' in result) return NextResponse.json({ error: result.error }, { status: mode === 'signup' ? 409 : 401 })
  const token = signToken(result.id)
  const res = NextResponse.json({ token, user: result })
  setSessionCookie(res, token)
  return res
}
