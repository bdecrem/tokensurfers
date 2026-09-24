// Token Surfers — one streamed Messages call for the phone's agent loop.
//
// The loop (tools, the file, run_app) lives in the app (apps/tokensurfers);
// this route adds the key, the system prompt and the tools, and passes
// Anthropic's SSE stream straight through so the app can turn tokens into
// coins as they arrive. The client sends only { messages }.
//
// Gate: the x-surf-key header must equal SURF_APP_KEY (the app's build
// secret, Secrets.swift). The server decides model, prompt, tools and budget,
// so a leaked key buys "the Token Surfers agent", not an open proxy.

import Anthropic from '@anthropic-ai/sdk'
import { NextRequest, NextResponse } from 'next/server'
import { SURF_SYSTEM, SURF_TOOLS } from '@/lib/surf/prompt'
import { meterStream, overDailyCap, recordUsage } from '@/lib/surf/usage'

export const runtime = 'nodejs'
// One streamed turn can run long (a big write_file at 64k max_tokens); Pro + Fluid allows 800 s.
export const maxDuration = 800

// Pinned on purpose: Splat codes on Opus 5.5 at medium effort at most. No env
// override and no client can raise either (a client may ask for low).
const MODEL = 'claude-opus-5-5'
const MAX_EFFORT = 'medium'
const MAX_TOKENS = 64000
const MAX_MESSAGES = 80
const EFFORTS = new Set(['low', MAX_EFFORT])

let _client: Anthropic | null = null
function getClient() {
  if (!_client) {
    const apiKey = process.env.ANTHROPIC_API_KEY
    if (!apiKey) throw new Error('ANTHROPIC_API_KEY is not set')
    _client = new Anthropic({ apiKey })
  }
  return _client
}

const err = (error: string, status: number) => NextResponse.json({ error }, { status })

export async function POST(req: NextRequest) {
  const expected = process.env.SURF_APP_KEY
  if (!expected) return err('SURF_APP_KEY is not configured', 500)
  if (req.headers.get('x-surf-key') !== expected) return err('bad key', 403)
  // The key ships in every build, so the day has a token ceiling (surf_usage).
  try {
    if (await overDailyCap()) return err("Splat is out of tokens for today. He's back tomorrow.", 429)
  } catch (e) {
    console.error('[surf/llm] usage', (e as Error).message)
    return err('budget unavailable', 503)
  }

  let body: { messages?: unknown; effort?: unknown }
  try {
    body = await req.json()
  } catch {
    return err('invalid JSON', 400)
  }
  const { messages } = body
  if (!Array.isArray(messages) || messages.length === 0) return err('messages required', 400)
  if (messages.length > MAX_MESSAGES) return err('conversation too long', 400)
  const effort = typeof body.effort === 'string' && EFFORTS.has(body.effort) ? body.effort : MAX_EFFORT

  const params = {
    model: MODEL,
    max_tokens: MAX_TOKENS,
    stream: true,
    // Opus 5.5 always thinks; "updates" returns its between-tool notes as
    // short thinking summaries the app can show as subtitles.
    thinking: { type: 'adaptive', display: 'updates' },
    output_config: { effort },
    cache_control: { type: 'ephemeral' },
    system: [{ type: 'text', text: SURF_SYSTEM, cache_control: { type: 'ephemeral' } }],
    tools: SURF_TOOLS,
    messages,
  }

  try {
    const upstream = await getClient().messages
      .create(params as unknown as Anthropic.MessageCreateParamsStreaming, {
        headers: { 'anthropic-beta': 'thinking-display-updates-2026-08-18' },
      })
      .asResponse()
    return new Response(meterStream(upstream.body!, recordUsage), {
      headers: {
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-cache, no-transform',
        'x-accel-buffering': 'no',
      },
    })
  } catch (e) {
    if (e instanceof Anthropic.RateLimitError) return err('rate limited, try again in a minute', 429)
    if (e instanceof Anthropic.BadRequestError) {
      console.error('[surf/llm] 400', e.message)
      return err(e.message, 400)
    }
    if (e instanceof Anthropic.APIError) {
      console.error('[surf/llm] upstream', e.status, e.message)
      return err(`model unavailable (${e.status ?? 'network'})`, 502)
    }
    throw e
  }
}
