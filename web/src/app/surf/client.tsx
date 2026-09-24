'use client'

// The web gallery's interactive bits: the sandboxed player, upvoting, and a
// tiny sign-in (same handle + password as the app; the API sets the cookie).

import { useEffect, useState } from 'react'

const STORAGE_SHIM = `<script>(function(){function mem(){var m={};return{getItem:function(k){return Object.prototype.hasOwnProperty.call(m,k)?m[k]:null},setItem:function(k,v){m[k]=String(v)},removeItem:function(k){delete m[k]},clear:function(){m={}},key:function(i){return Object.keys(m)[i]||null},get length(){return Object.keys(m).length}}}
function fix(n){try{window[n].getItem('x')}catch(e){try{Object.defineProperty(window,n,{value:mem(),configurable:true})}catch(_){}}}
fix('localStorage');fix('sessionStorage');})();</script>`

/** The creation runs in a sandboxed iframe (opaque origin: it can't touch our
 *  cookies); a shim gives it an in-memory localStorage since the sandbox has none. */
export function AppFrame({ html, siteUrl, full, onClose }: { html: string; siteUrl?: string | null; full?: boolean; onClose?: () => void }) {
  const doc = /<head[^>]*>/i.test(html) ? html.replace(/<head[^>]*>/i, (m) => m + STORAGE_SHIM) : STORAGE_SHIM + html
  // an app on Vercel has its own origin, so it may keep same-origin (its own localStorage)
  const frame = siteUrl ? (
    <iframe
      title="the app"
      sandbox="allow-scripts allow-same-origin allow-forms allow-pointer-lock allow-modals allow-popups"
      src={siteUrl}
      allow="autoplay"
    />
  ) : (
    <iframe
      title="the app"
      sandbox="allow-scripts allow-forms allow-pointer-lock allow-modals allow-popups"
      srcDoc={doc}
      allow="autoplay"
    />
  )
  if (full) {
    return (
      <div className="full">
        <button className="key ink close" onClick={onClose} aria-label="Close">✕ close</button>
        {frame}
      </div>
    )
  }
  return <div className="frame">{frame}</div>
}

export function Player({ html, siteUrl }: { html: string; siteUrl?: string | null }) {
  const [full, setFull] = useState(false)
  useEffect(() => {
    if (typeof window !== 'undefined' && new URLSearchParams(window.location.search).get('full') === '1') setFull(true)
  }, [])
  return (
    <>
      <AppFrame html={html} siteUrl={siteUrl} full={full} onClose={() => setFull(false)} />
      {!full && (
        <button className="key white" style={{ marginTop: 12 }} onClick={() => setFull(true)}>
          ⤢ play full screen
        </button>
      )}
    </>
  )
}

type User = { id: string; handle: string } | null

async function me(): Promise<User> {
  try {
    const r = await fetch('/api/surf/auth/me', { credentials: 'include', cache: 'no-store' })
    return ((await r.json()) as { user: User }).user
  } catch {
    return null
  }
}

export function SignIn({ onDone, onCancel }: { onDone: (u: NonNullable<User>) => void; onCancel: () => void }) {
  const [create, setCreate] = useState(true)
  const [handle, setHandle] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      const r = await fetch(`/api/surf/auth/${create ? 'signup' : 'login'}`, {
        method: 'POST', credentials: 'include', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ handle, password }),
      })
      const j = (await r.json()) as { user?: NonNullable<User>; error?: string }
      if (!r.ok || !j.user) throw new Error(j.error || 'no luck')
      onDone(j.user)
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="modal" onClick={onCancel}>
      <form className="card" onClick={(e) => e.stopPropagation()} onSubmit={submit}>
        <div className="head stroke" style={{ fontSize: 34 }}>{create ? 'join the surfers' : 'welcome back'}</div>
        <p style={{ margin: 0, fontWeight: 700, color: 'var(--ink2)', fontSize: 13 }}>
          one handle for the gallery, the app and the leaderboard. no email.
        </p>
        <input placeholder="handle" value={handle} onChange={(e) => setHandle(e.target.value)} autoCapitalize="none" autoCorrect="off" autoFocus />
        <input placeholder="password" type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
        {error ? <div className="err">{error}</div> : null}
        <button className="key" type="submit" aria-disabled={busy || handle.length < 2 || password.length < 4}>
          {busy ? '…' : create ? 'create account' : 'sign in'}
        </button>
        <button className="switch" type="button" onClick={() => setCreate(!create)}>
          {create ? 'already surfing? sign in' : 'new here? create an account'}
        </button>
      </form>
    </div>
  )
}

export function AccountPill() {
  const [user, setUser] = useState<User>(null)
  const [open, setOpen] = useState(false)
  useEffect(() => { me().then(setUser) }, [])
  async function out() {
    await fetch('/api/surf/auth/logout', { method: 'POST', credentials: 'include' })
    setUser(null)
  }
  return (
    <>
      {user ? (
        <button className="pill on" onClick={out} title="sign out">@{user.handle} · out</button>
      ) : (
        <button className="pill" onClick={() => setOpen(true)}>sign in</button>
      )}
      {open ? <SignIn onDone={(u) => { setUser(u); setOpen(false) }} onCancel={() => setOpen(false)} /> : null}
    </>
  )
}

export function Upvote({ slug, upvotes, voted }: { slug: string; upvotes: number; voted: boolean }) {
  const [n, setN] = useState(upvotes)
  const [on, setOn] = useState(voted)
  const [ask, setAsk] = useState(false)
  const [busy, setBusy] = useState(false)

  async function vote() {
    if (busy) return
    setBusy(true)
    try {
      const r = await fetch(`/api/surf/apps/${slug}/upvote`, { method: 'POST', credentials: 'include' })
      if (r.status === 401) { setAsk(true); return }
      const j = (await r.json()) as { voted: boolean; upvotes: number }
      if (r.ok) { setOn(j.voted); setN(j.upvotes) }
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <button className={`key ${on ? '' : 'white'}`} onClick={vote} aria-pressed={on}>▲ {n}</button>
      {ask ? <SignIn onDone={() => { setAsk(false); vote() }} onCancel={() => setAsk(false)} /> : null}
    </>
  )
}

/** Flag a creation. No account needed; the reason is optional. */
export function Report({ slug }: { slug: string }) {
  const [open, setOpen] = useState(false)
  const [reason, setReason] = useState('')
  const [state, setState] = useState<'idle' | 'busy' | 'sent' | 'failed'>('idle')

  async function send() {
    if (state === 'busy') return
    setState('busy')
    try {
      const r = await fetch(`/api/surf/apps/${slug}/report`, {
        method: 'POST', credentials: 'include', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ reason }),
      })
      setState(r.ok ? 'sent' : 'failed')
    } catch {
      setState('failed')
    }
  }

  if (state === 'sent') return <p className="note">reported. thanks — we'll take a look.</p>
  if (!open) return <button className="note" style={{ background: 'none', border: 0, padding: 0, textDecoration: 'underline', cursor: 'pointer' }} onClick={() => setOpen(true)}>report this creation</button>
  return (
    <div className="card" style={{ display: 'grid', gap: 8, padding: 12 }}>
      <textarea value={reason} onChange={(e) => setReason(e.target.value)} placeholder="what's wrong with it? (optional)" rows={2} maxLength={500}
        style={{ font: 'inherit', fontSize: 14, padding: 8, borderRadius: 10, border: '2px solid #17131f' }} />
      <div style={{ display: 'flex', gap: 8 }}>
        <button className="key" onClick={send} disabled={state === 'busy'}>{state === 'busy' ? '…' : 'send report'}</button>
        <button className="key white" onClick={() => setOpen(false)}>cancel</button>
      </div>
      {state === 'failed' ? <small style={{ color: '#d2321f' }}>that didn't go through — try again or email bdecrem@gmail.com</small> : null}
    </div>
  )
}

const CAPTIONS = [
  ['ANGER', 'ISSUES'], ['SO IT’S', '3AM'], ['NO', 'COMMENTS'], ['TOK TOK', 'TOKENUR'], ['LET HIM', 'COOK'],
  ['47', 'BUGS 💀'], ['X_FINAL', '_FINAL'], ['YOU’RE ABSOLUTELY', 'RIGHT'], ['SAY', 'LESS'], ['BRUH', '💀'],
]

/** The video's karaoke caption, cycling. */
export function CaptionCycler() {
  const [i, setI] = useState(0)
  useEffect(() => {
    const t = setInterval(() => setI((n) => (n + 1) % CAPTIONS.length), 2000)
    return () => clearInterval(t)
  }, [])
  const [a, b] = CAPTIONS[i]
  return (
    <div className="sq-cap cap" key={i} aria-hidden="true">
      <span className="stroke">{a}</span> <span className="stroke yellow">{b}</span>
    </div>
  )
}
