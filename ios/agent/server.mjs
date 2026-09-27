// Token Surfers' coding agent: Claude Code (the Agent SDK) run headless, one
// workspace, git repo and session per app, with a long-poll event feed the
// phone turns into the game.
//
// Why long-poll and not SSE/WebSocket: the mini sits behind tunn3l, which
// buffers a streamed response until it ends and doesn't pass WebSocket
// upgrades (checked 2026-09-24). A GET that returns as soon as there is
// something new (or after `wait` seconds) goes through fine.
//
// Routes (all but /health need `x-surf-key: SURF_APP_KEY`; :id is the phone's
// project UUID, lowercase):
//   POST /p/:id/prompt {text}   idle: start a build. running: queue a note for
//                               Splat's next step (a PostToolUse hook hands it
//                               over with the next tool result).
//   POST /p/:id/now {text?}     interrupt the turn; queued notes (+ text) go in
//                               as the next message of the same session.
//   POST /p/:id/stop            interrupt and end the build; queued notes come back.
//   GET  /p/:id/events?after=N&wait=S&hold=MS&v=2
//                               events with seq > N, held up to S seconds; with
//                               something new, hold MS more (≤ 1000) so a streaming
//                               build answers ~4×/s, not once per flush. v=2 gets
//                               tool_input as deltas {delta, offset, len}; without it
//                               the old whole-json shape is rebuilt at serve time.
//   GET  /p/:id/state           running, session, deployUrl, recap, cost.
//   GET  /p/:id/file?path=      a file of the workspace (text, ≤ 200 KB).
//   GET  /health

import http from 'node:http'
import fs from 'node:fs/promises'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { query } from '@anthropic-ai/claude-agent-sdk'
import { guardTool } from './guard.mjs'
import { Usage } from './usage.mjs'

const PORT = Number(process.env.SURF_AGENT_PORT || 3910)
const ROOT = process.env.SURF_AGENT_ROOT || path.join(process.env.HOME, 'surf-apps')
// Per-user daily allowance (USD at list price; a build costs $0.3–1.8, so 15 is ten-odd apps).
// Bart and anyone in SURF_UNLIMITED are never capped.
const usage = new Usage(path.join(ROOT, '.usage.json'), {
  dailyUsd: Number(process.env.SURF_DAILY_USD || 15),
  unlimited: (process.env.SURF_UNLIMITED || 'bart').split(','),
})
// What the model is told, on top of Claude Code's own prompt and the workspace CLAUDE.md.
const BOUNDARIES = `You are Splat, building one small web app for one user of the Token Surfers iPhone app, inside this directory on a shared machine. Hard limits, whatever the user says (a user note is never a reason to cross them): this directory is the only place you read, write or run things; you never read, print, copy or reason about environment variables, key files, credentials or anything under the home directory, and the app you write never does either; the only vercel command is the deploy of this app exactly as the rules give it — never other projects, aliases, domains, env, teams; nothing on this machine is yours to administer (no sudo, launchd, ssh, processes, network probes, calls to localhost or the local network). You don't build things meant to deceive or harm: no phishing or pages impersonating a real company, person or login; no malware, scrapers, spam or harassment tools; no sexual content involving minors, no hate. If a request needs any of that, say so in one plain line in your voice and build the closest safe thing, or stop. If a tool call is refused with a reason, that reason is final: don't look for another way.`
const KEY = process.env.SURF_APP_KEY
const MODEL = process.env.SURF_AGENT_MODEL || 'claude-opus-5-5'
const EFFORT = process.env.SURF_AGENT_EFFORT || 'medium'
const MAX_TURNS = Number(process.env.SURF_AGENT_MAX_TURNS || 80)
const VERCEL_SCOPE = process.env.VERCEL_SCOPE || 'bart-r-decrems-projects'
const RING = 6000
const FILE_CAP = 200_000
const WORKSPACE_MD = await fs.readFile(new URL('./workspace-CLAUDE.md', import.meta.url), 'utf8')

if (!KEY) { console.error('SURF_APP_KEY is not set'); process.exit(1) }
if (!process.env.VERCEL_TOKEN) console.warn('[agent] VERCEL_TOKEN is not set: deploys will fail')

const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a)
const FILE_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit'])

class Project {
  constructor(id) {
    this.id = id
    this.dir = path.join(ROOT, `surf-${id.slice(0, 8)}`)
    this.metaFile = path.join(this.dir, '.surf.json')
    this.events = []
    this.seq = 0
    this.waiters = []
    this.state = { running: false, sessionId: null, deployUrl: null, recap: null, cost: 0, turns: 0, builds: 0, startedAt: null }
    this.user = 'anon'   // who started the current build (x-surf-user), for the daily allowance
    this.notes = []
    this.calls = new Map()
    /// Each tool_use block's input json so far, by block id (for old clients and late joiners).
    this.inputs = {}
    this.q = null
    this.push = null
    this.close = null
    this.stopping = false
    this.block = null
    this.textBuf = ''
    this.flushTimer = null
    this.loaded = false
  }

  // MARK: events

  emit(type, data = {}) {
    const ev = { seq: ++this.seq, t: Date.now(), type, ...data }
    this.events.push(ev)
    if (this.events.length > RING) this.events.splice(0, this.events.length - RING)
    for (const w of this.waiters.splice(0)) w()
    return ev
  }

  since(after, v = 1) {
    const first = this.events[0]?.seq ?? this.seq + 1
    const gap = after + 1 < first && this.events.length > 0
    let events = this.events.filter(e => e.seq > after)
    if (v < 2) {
      // the old shape: the whole input so far on every tick (quadratic; v=2 gets deltas)
      events = events.map(e => {
        if (e.type !== 'tool_input') return e
        const { delta, offset, len, ...rest } = e
        return { ...rest, json: (this.inputs[e.id] || '').slice(0, offset + delta.length) }
      })
    }
    return { events, gap }
  }

  wait(after, seconds) {
    if (this.seq > after) return Promise.resolve()
    return new Promise(r => {
      const t = setTimeout(r, seconds * 1000)
      this.waiters.push(() => { clearTimeout(t); r() })
    })
  }

  /// Text deltas and tool-input deltas are coalesced (120 ms) so a build is
  /// hundreds of events, not tens of thousands.
  buffer(kind, delta) {
    if (kind === 'text') this.textBuf += delta
    if (kind === 'thinking') this.thinkBuf = (this.thinkBuf || '') + delta
    if (!this.flushTimer) this.flushTimer = setTimeout(() => this.flush(), 120)
  }

  flush() {
    clearTimeout(this.flushTimer)
    this.flushTimer = null
    if (this.thinkBuf) { this.emit('thinking', { delta: this.thinkBuf }); this.thinkBuf = '' }
    if (this.textBuf) { this.emit('text', { delta: this.textBuf }); this.textBuf = '' }
    if (this.block && this.block.json.length > this.block.sent) {
      const b = this.block
      this.inputs[b.id] = b.json
      this.emit('tool_input', { id: b.id, name: b.name, delta: b.json.slice(b.sent), offset: b.sent, len: b.json.length })
      b.sent = b.json.length
    }
  }

  // MARK: storage

  async load() {
    if (this.loaded) return
    this.loaded = true
    try {
      const m = JSON.parse(await fs.readFile(this.metaFile, 'utf8'))
      Object.assign(this.state, { sessionId: m.sessionId ?? null, deployUrl: m.deployUrl ?? null, recap: m.recap ?? null, builds: m.builds || 0, cost: m.cost || 0 })
    } catch {}
  }

  async save() {
    const { sessionId, deployUrl, recap, builds, cost } = this.state
    await fs.writeFile(this.metaFile, JSON.stringify({ sessionId, deployUrl, recap, builds, cost }, null, 2)).catch(() => {})
  }

  async prepare() {
    await fs.mkdir(this.dir, { recursive: true })
    const md = path.join(this.dir, 'CLAUDE.md')
    if ((await fs.readFile(md, 'utf8').catch(() => '')) !== WORKSPACE_MD) await fs.writeFile(md, WORKSPACE_MD)
    try {
      await fs.access(path.join(this.dir, '.git'))
    } catch {
      spawnSync('git', ['init', '-q'], { cwd: this.dir })
      await fs.writeFile(path.join(this.dir, '.gitignore'), 'node_modules\n.vercel\n.surf.json\n.DS_Store\n')
    }
  }

  // MARK: the build

  /// Idle: start a build. Running: a note for Splat's next step (`now` interrupts).
  async send(text, { now = false } = {}) {
    if (this.state.running) {
      this.notes.push({ text })
      this.emit('queued', { text })
      if (now) await this.interrupt()
      return { queued: true }
    }
    this.state.running = true
    this.run(text).catch(e => { log(this.id, 'run crashed:', e); this.fail(String(e?.message || e)) })
    return { queued: false }
  }

  async interrupt() {
    if (!this.q) return
    try { await this.q.interrupt() } catch (e) { log(this.id, 'interrupt failed:', e?.message || e) }
  }

  async stop() {
    if (!this.state.running) return { notes: [] }
    const notes = this.notes.splice(0).filter(n => !n.app).map(n => n.text)
    this.stopping = true
    await this.interrupt()
    return { notes }
  }

  fail(message) {
    this.emit('error', { message })
  }

  async run(text, retriedFresh = false) {
    await this.load()
    await this.prepare()
    this.state.running = true
    this.state.startedAt = Date.now()
    this.state.builds++
    this.stopping = false
    this.calls.clear()
    this.inputs = {}
    this.emit('start', { text, sessionId: this.state.sessionId, resumed: !!this.state.sessionId })
    usage.charge(this.user, 0, { build: true })
    log(this.id, 'build:', text.slice(0, 80), this.state.sessionId ? `(resume ${this.state.sessionId.slice(0, 8)})` : '(new session)')

    // The input stream: the prompt now, notes pushed in later, closed when the build is over.
    const queue = []
    let wake = null
    let closed = false
    this.push = (t) => { queue.push(t); wake?.() }
    this.close = () => { closed = true; wake?.() }
    const input = async function* () {
      while (true) {
        while (queue.length) yield { type: 'user', message: { role: 'user', content: queue.shift() }, parent_tool_use_id: null }
        if (closed) return
        await new Promise(r => { wake = r })
        wake = null
      }
    }
    this.push(text)

    const self = this
    const hooks = {
      // the boundaries, enforced: see guard.mjs
      PreToolUse: [{ hooks: [async (input) => {
        const reason = guardTool(input.tool_name, input.tool_input, self.dir)
        if (!reason) return {}
        log(self.id, 'refused', input.tool_name, reason)
        self.emit('tool_result', { id: input.tool_use_id, name: input.tool_name, ok: false, summary: `refused: ${reason}` })
        return { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: `Refused: ${reason}. This is final; tell the user in one line and carry on with the rest.` } }
      }] }],
      PostToolUse: [{ hooks: [async () => {
        if (!self.notes.length) return {}
        const notes = self.notes.splice(0)
        for (const n of notes) if (!n.app) self.emit('note_in', { text: n.text, via: 'tool' })
        log(self.id, 'notes in with a tool result:', notes.map(noteLine).join(' | ').slice(0, 160))
        return { hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: notes.map(noteLine).join('\n') } }
      }] }],
    }
    const options = {
      cwd: this.dir,
      model: MODEL,
      effort: EFFORT,
      // summarized, not omitted (the default): the plan streams as thinking_delta,
      // so a long think shows on the phone instead of looking like a hang
      thinking: { type: 'adaptive', display: 'summarized' },
      maxTurns: MAX_TURNS,
      permissionMode: 'bypassPermissions',
      allowDangerouslySkipPermissions: true,
      settingSources: ['project'],
      systemPrompt: { type: 'preset', preset: 'claude_code', append: BOUNDARIES },
      includePartialMessages: true,
      env: childEnv(),
      hooks,
      ...(this.state.sessionId ? { resume: this.state.sessionId } : {}),
    }
    this.q = query({ prompt: input(), options })
    let sawInit = false
    try {
      for await (const m of this.q) {
        if (m.type === 'system' && m.subtype === 'init') sawInit = true
        await this.handle(m)
      }
    } catch (e) {
      const msg = String(e?.message || e)
      log(this.id, 'query failed:', msg)
      if (!sawInit && this.state.sessionId && !retriedFresh) {
        // the old session is gone (moved workspace, cleared transcripts): once more, fresh
        this.state.sessionId = null
        this.q = null
        this.state.running = false
        this.emit('say', { text: 'lost the old thread. starting fresh' })
        return this.run(text, true)
      }
      this.fail(msg)
    } finally {
      this.flush()
      this.q = null
      this.push = null
      this.close = null
      this.state.running = false
      this.emit('idle', { deployUrl: this.state.deployUrl, recap: this.state.recap })
      await this.save()
      log(this.id, 'idle; deploy', this.state.deployUrl, 'cost so far', this.state.cost.toFixed(2))
    }
  }

  async handle(m) {
    switch (m.type) {
      case 'system':
        if (m.subtype === 'init') {
          this.state.sessionId = m.session_id
          this.emit('session', { sessionId: m.session_id, model: m.model, tools: (m.tools || []).length })
        } else if (m.subtype === 'thinking_tokens') {
          // proof of life during a think, even when no summary text comes back (≤ 1/s)
          if (Date.now() - (this.thinkTokensAt || 0) >= 1000) {
            this.thinkTokensAt = Date.now()
            this.emit('thinking_tokens', { tokens: m.estimated_tokens || 0 })
          }
        }
        break

      case 'stream_event': {
        if (m.parent_tool_use_id) break
        const e = m.event
        if (e.type === 'content_block_start' && e.content_block?.type === 'tool_use') {
          this.flush()
          this.block = { index: e.index, id: e.content_block.id, name: e.content_block.name, json: '', sent: 0 }
          this.emit('tool_start', { id: this.block.id, name: this.block.name })
        } else if (e.type === 'content_block_delta') {
          if (e.delta?.type === 'text_delta') this.buffer('text', e.delta.text)
          else if (e.delta?.type === 'thinking_delta' && e.delta.thinking) this.buffer('thinking', e.delta.thinking)
          else if (e.delta?.type === 'input_json_delta' && this.block && e.index === this.block.index) {
            this.block.json += e.delta.partial_json
            this.buffer('input')
          }
        } else if (e.type === 'content_block_stop' && this.block && e.index === this.block.index) {
          this.flush()
          this.block = null
        }
        break
      }

      case 'assistant':
        if (m.parent_tool_use_id) break
        this.flush()
        for (const b of m.message.content || []) {
          if (b.type === 'text' && b.text.trim()) {
            this.emit('say', { text: b.text.trim() })
            this.scanForDeploy(b.text)
            const name = b.text.match(/^NAME:\s*(\S+)\s+(.{1,40}?)\s*$/m)
            if (name) this.emit('name', { emoji: name[1], title: name[2] })
          } else if (b.type === 'tool_use') {
            this.calls.set(b.id, { name: b.name, input: b.input })
            this.emit('tool_call', { id: b.id, name: b.name, input: summarize(b.name, b.input) })
          }
        }
        break

      case 'user': {
        if (m.parent_tool_use_id) break
        const blocks = Array.isArray(m.message?.content) ? m.message.content : []
        for (const b of blocks) {
          if (b.type !== 'tool_result') continue
          const text = typeof b.content === 'string' ? b.content
            : (b.content || []).filter(x => x.type === 'text').map(x => x.text).join('\n')
          const call = this.calls.get(b.tool_use_id)
          this.emit('tool_result', { id: b.tool_use_id, name: call?.name, ok: !b.is_error, summary: text.slice(0, 300) })
          if (!b.is_error) this.scanForDeploy(text)
          if (call && FILE_TOOLS.has(call.name) && !b.is_error) await this.emitFile(call.input?.file_path || call.input?.notebook_path)
        }
        break
      }

      case 'result': {
        this.flush()
        const ok = m.subtype === 'success'
        this.state.cost += m.total_cost_usd || 0
        usage.charge(this.user, m.total_cost_usd || 0)
        this.state.turns += m.num_turns || 0
        const recap = ok ? lastLine(m.result || '') : (Array.isArray(m.errors) ? m.errors.join(' ') : m.subtype)
        if (ok && recap) this.state.recap = recap
        this.emit('turn_end', { ok, subtype: m.subtype, recap, cost: m.total_cost_usd || 0, turns: m.num_turns || 0, deployUrl: this.state.deployUrl })
        log(this.id, 'turn:', m.subtype, `$${(m.total_cost_usd || 0).toFixed(2)}`, `${m.num_turns} turns`, recap?.slice(0, 80))
        if (this.stopping) { this.close?.(); break }
        if (this.notes.length) {
          const notes = this.notes.splice(0)
          for (const n of notes) if (!n.app) this.emit('note_in', { text: n.text, via: 'message' })
          log(this.id, 'notes in as the next message:', notes.map(noteLine).join(' | ').slice(0, 160))
          this.push?.(notes.map(noteLine).join('\n'))
        } else {
          this.close?.()
        }
        break
      }
    }
  }

  /// `DEPLOYED: <url>` from Splat is the word; a bare project alias
  /// (surf-xxxxxxxx.vercel.app) seen in a tool result is a candidate that
  /// stands in until then. The long per-deployment URLs are never used.
  scanForDeploy(text) {
    const said = text.match(/DEPLOYED:\s*(https?:\/\/[^\s)>"']+)/)
    const alias = text.match(/\b(https:\/\/surf-[a-z0-9]{8}\.vercel\.app)\b/)
    const url = (said?.[1] || alias?.[1] || '').replace(/[.,]+$/, '')
    if (!url || url === this.state.deployUrl) return
    if (!said && this.state.deployUrl) return
    this.state.deployUrl = url
    this.emit('deployed', { url })
    log(this.id, 'deployed:', url)
    this.checkShareCard(url)
  }

  /// Every app gets a share card: if the deployed page has no og:image, the
  /// app tells Splat so before the build is over (as an [app] note).
  async checkShareCard(url) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(8000), headers: { 'user-agent': 'tokensurfers-agent' } })
      const html = (await res.text()).slice(0, 200_000)
      if (/property=["']og:image["']/i.test(html)) { this.emit('share_card', { ok: true }); return }
      if (!this.state.running) { this.emit('share_card', { ok: false }); return }
      this.notes.push({ text: `the deployed page at ${url} has no og:image meta tag. Add the share-card tags from the rules (og:title, og:description, og:url, og:image with the tokensurfers.app/api/surf/og URL, twitter:card, twitter:image) to the <head> and deploy again.`, app: true })
      this.emit('share_card', { ok: false, nudged: true })
      log(this.id, 'no og:image on the deployed page — Splat gets a note')
    } catch (e) {
      log(this.id, 'share card check failed:', e?.message || e)
    }
  }

  async emitFile(p) {
    if (!p) return
    const abs = path.resolve(this.dir, p)
    if (!abs.startsWith(this.dir + path.sep)) return
    try {
      const st = await fs.stat(abs)
      if (st.size > FILE_CAP) { this.emit('file', { path: path.relative(this.dir, abs), size: st.size, truncated: true }); return }
      const content = await fs.readFile(abs, 'utf8')
      this.emit('file', { path: path.relative(this.dir, abs), size: st.size, content })
    } catch {}
  }

  async readFile(p) {
    const abs = path.resolve(this.dir, p || '')
    if (!abs.startsWith(this.dir + path.sep)) throw new Error('outside the workspace')
    const st = await fs.stat(abs)
    if (!st.isFile()) throw new Error('not a file')
    if (st.size > FILE_CAP) throw new Error('too big')
    return fs.readFile(abs, 'utf8')
  }
}

/// How a queued note reads to the model: the user's words, or the app's own line.
function noteLine(n) { return n.app ? `[app]: ${n.text}` : `[user, mid-build]: ${n.text}` }

function summarize(name, input = {}) {
  const s = (v, n = 160) => (typeof v === 'string' ? (v.length > n ? v.slice(0, n) + '…' : v) : v)
  switch (name) {
    case 'Write': return { file_path: input.file_path, bytes: (input.content || '').length }
    case 'Edit': return { file_path: input.file_path, old: s(input.old_string, 80), new: s(input.new_string, 80) }
    case 'MultiEdit': return { file_path: input.file_path, edits: (input.edits || []).length }
    case 'Bash': return { command: s(input.command, 200), description: input.description }
    case 'Read': return { file_path: input.file_path }
    case 'Glob': case 'Grep': return { pattern: input.pattern, path: input.path }
    case 'TodoWrite': return { todos: (input.todos || []).length }
    default: return Object.fromEntries(Object.entries(input).slice(0, 4).map(([k, v]) => [k, s(typeof v === 'string' ? v : JSON.stringify(v), 120)]))
  }
}

function lastLine(text) {
  const lines = text.split('\n').map(l => l.trim()).filter(l => l && !/^DEPLOYED:/i.test(l))
  return lines[lines.length - 1] || ''
}

// MARK: http

const projects = new Map()
function project(id) {
  let p = projects.get(id)
  if (!p) { p = new Project(id); projects.set(id, p) }
  return p
}

function json(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
  res.end(JSON.stringify(body))
}

async function body(req) {
  const chunks = []
  let n = 0
  for await (const c of req) { n += c.length; if (n > 1_000_000) throw new Error('body too large'); chunks.push(c) }
  const raw = Buffer.concat(chunks).toString('utf8')
  return raw ? JSON.parse(raw) : {}
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x')
  try {
    if (url.pathname === '/health') {
      const running = [...projects.values()].filter(p => p.state.running).length
      return json(res, 200, { ok: true, model: MODEL, effort: EFFORT, projects: projects.size, running, root: ROOT, today: usage.today(), dailyUsd: usage.dailyUsd })
    }
    if (req.headers['x-surf-key'] !== KEY) return json(res, 403, { error: 'bad key' })
    const m = url.pathname.match(/^\/p\/([a-z0-9-]{8,64})\/(prompt|now|stop|events|state|file)$/)
    if (!m) return json(res, 404, { error: 'no such route' })
    const p = project(m[1])
    await p.load()
    switch (m[2]) {
      case 'prompt': {
        if (req.method !== 'POST') return json(res, 405, { error: 'POST' })
        const { text } = await body(req)
        if (typeof text !== 'string' || !text.trim()) return json(res, 400, { error: 'text required' })
        if (!p.state.running) {
          // a new build: the day's allowance (notes into a running build ride free)
          const user = String(req.headers['x-surf-user'] || 'anon').slice(0, 64)
          const u = usage.check(user)
          if (!u.ok) {
            log(p.id, 'over the daily allowance:', user, `$${u.spent.toFixed(2)} in ${u.builds} builds`)
            return json(res, 429, { error: `Splat is out of tokens for today (${u.builds} builds). back tomorrow 🫠` })
          }
          p.user = user
        }
        const r = await p.send(text.trim())
        return json(res, 202, { ...r, seq: p.seq, state: p.state })
      }
      case 'now': {
        if (req.method !== 'POST') return json(res, 405, { error: 'POST' })
        const { text } = await body(req)
        if (!p.state.running) return json(res, 409, { error: 'not running' })
        if (typeof text === 'string' && text.trim()) await p.send(text.trim(), { now: true })
        else if (p.notes.length) await p.interrupt()
        else return json(res, 400, { error: 'nothing to send' })
        return json(res, 202, { seq: p.seq, state: p.state })
      }
      case 'stop': {
        if (req.method !== 'POST') return json(res, 405, { error: 'POST' })
        const r = await p.stop()
        return json(res, 200, { ...r, seq: p.seq, state: p.state })
      }
      case 'events': {
        const after = Number(url.searchParams.get('after') || 0)
        const wait = Math.min(25, Math.max(0, Number(url.searchParams.get('wait') || 0)))
        const hold = Math.min(1000, Math.max(0, Number(url.searchParams.get('hold') || 0)))
        const v = Number(url.searchParams.get('v') || 1)
        await p.wait(after, wait)
        if (hold > 0 && p.seq > after) await new Promise(r => setTimeout(r, hold))
        const { events, gap } = p.since(after, v)
        return json(res, 200, { events, gap, seq: p.seq, state: p.state })
      }
      case 'state':
        return json(res, 200, { seq: p.seq, state: p.state, notes: p.notes.filter(n => !n.app).map(n => n.text) })
      case 'file': {
        const content = await p.readFile(url.searchParams.get('path'))
        res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' })
        return res.end(content)
      }
    }
  } catch (e) {
    log('error', req.method, url.pathname, e?.message || e)
    return json(res, 500, { error: String(e?.message || e) })
  }
})

/// The environment the model's tools run in: the tools' needs, not the server's secrets
/// (SURF_APP_KEY never reaches it; the Claude login has to, the guard keeps it closed).
function childEnv() {
  const keep = ['PATH', 'HOME', 'USER', 'LOGNAME', 'SHELL', 'LANG', 'LC_ALL', 'TMPDIR', 'TERM', 'NODE_ENV', 'VERCEL_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN']
  const env = {}
  for (const k of keep) if (process.env[k] != null) env[k] = process.env[k]
  for (const k of Object.keys(process.env)) if (/^(CLAUDE_|npm_config_)/.test(k) && env[k] == null) env[k] = process.env[k]
  env.VERCEL_SCOPE = VERCEL_SCOPE
  return env
}

await fs.mkdir(ROOT, { recursive: true })
await usage.load()
server.listen(PORT, () => log(`agent server on :${PORT}, workspaces in ${ROOT}, ${MODEL} @ ${EFFORT}`))
