// Token Surfers — the global daily token budget behind /api/surf/llm.
//
// The app key ships inside every build, so the route needs a ceiling that
// doesn't depend on who is calling: one row per UTC day (surf_usage,
// apps/tokensurfers/schema/004_surf_usage_reports.sql) holding calls, input
// and output tokens. SURF_DAILY_TOKENS caps input + output for the day.
// Usage is read out of the Messages stream as it passes through (meterStream),
// so the app never waits on the database.
//
// A missing table is a deployment error: the route fails loudly rather than
// running unmetered.

import { surfDb } from './db'

// Opus 5.5 at medium: a build is a handful of calls of a few thousand output
// tokens each on a cached prompt, so a day of real beta use is well under this.
export const DEFAULT_DAILY_TOKENS = 10_000_000

export function dailyTokenLimit(): number {
  const raw = process.env.SURF_DAILY_TOKENS
  if (raw === undefined || raw.trim() === '') return DEFAULT_DAILY_TOKENS
  const n = Number(raw)
  if (!Number.isFinite(n) || n <= 0) throw new Error(`SURF_DAILY_TOKENS must be a positive number, got "${raw}"`)
  return Math.floor(n)
}

const usageDay = (now = new Date()) => now.toISOString().slice(0, 10)

// Read at most every 30 s per server instance; overshoot is bounded by that
// window plus the calls already streaming.
let seen: { day: string; tokens: number; at: number } | null = null

/** True when today's tokens are spent. Throws if the table is unreachable. */
export async function overDailyCap(): Promise<boolean> {
  const day = usageDay()
  if (!seen || seen.day !== day || Date.now() - seen.at > 30_000) {
    const { data, error } = await surfDb().from('surf_usage').select('input_tokens, output_tokens').eq('day', day).maybeSingle()
    if (error) throw new Error(`surf_usage read failed: ${error.message}`)
    seen = { day, tokens: (Number(data?.input_tokens) || 0) + (Number(data?.output_tokens) || 0), at: Date.now() }
  }
  return seen.tokens >= dailyTokenLimit()
}

/** Add one finished call to today's row (atomic upsert-increment). */
export async function recordUsage(input: number, output: number): Promise<void> {
  if (seen && seen.day === usageDay()) seen.tokens += input + output
  const { error } = await surfDb().rpc('surf_add_usage', { p_day: usageDay(), p_calls: 1, p_input: Math.round(input), p_output: Math.round(output) })
  if (error) throw new Error(`surf_usage write failed: ${error.message}`)
}

/**
 * Passes an Anthropic SSE stream through untouched and, once it ends, records
 * what it cost: input tokens (including cache reads and writes) from
 * message_start, output tokens from the last message_delta.
 */
export function meterStream(upstream: ReadableStream<Uint8Array>, onDone: (input: number, output: number) => Promise<void>): ReadableStream<Uint8Array> {
  const decoder = new TextDecoder()
  let buffer = ''
  let input = 0
  let output = 0
  const scan = (chunk: string) => {
    buffer += chunk
    const lines = buffer.split('\n')
    buffer = lines.pop() ?? ''
    for (const line of lines) {
      if (!line.startsWith('data: ')) continue
      let ev: { type?: string; message?: { usage?: Usage }; usage?: Usage }
      try { ev = JSON.parse(line.slice(6)) } catch { continue }
      if (ev.type === 'message_start' && ev.message?.usage) {
        const u = ev.message.usage
        input = (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0)
      } else if (ev.type === 'message_delta' && ev.usage?.output_tokens !== undefined) {
        output = ev.usage.output_tokens
      }
    }
  }
  return upstream.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      scan(decoder.decode(chunk, { stream: true }))
      controller.enqueue(chunk)
    },
    async flush() {
      scan(decoder.decode())
      try { await onDone(input, output) } catch (e) { console.error('[surf/llm] usage', (e as Error).message) }
    },
  }))
}

type Usage = { input_tokens?: number; output_tokens?: number; cache_read_input_tokens?: number; cache_creation_input_tokens?: number }
