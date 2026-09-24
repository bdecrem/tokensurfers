// The share card for an app Token Surfers made: its emoji and name on the
// paper card, one line about it, who made it, the Token Surfers line.
//   GET /api/surf/og?emoji=🎆&title=Zero+Hour&line=…&by=bart  → 1200×630 PNG
// Every deployed app links to it as its og:image (the workspace rules give
// the exact tag), and the gallery page uses it too. Public, cached a day.

import { ImageResponse } from 'next/og'
import type { NextRequest } from 'next/server'

export const runtime = 'edge'

const clean = (s: string | null, n: number) =>
  Array.from((s || '').replace(/[\u0000-\u001f\u007f]/g, '').replace(/\s+/g, ' ').trim()).slice(0, n).join('')

export async function GET(req: NextRequest) {
  const q = req.nextUrl.searchParams
  const emoji = clean(q.get('emoji'), 2) || '✨'
  const title = clean(q.get('title'), 40) || 'an app'
  const line = clean(q.get('line'), 90)
  const by = clean(q.get('by'), 24)
  const titleSize = title.length > 24 ? 66 : title.length > 14 ? 88 : 108

  return new ImageResponse(
    (
      <div
        style={{
          width: '100%', height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center',
          position: 'relative', overflow: 'hidden', background: '#f4703a',
          fontFamily: 'Arial, Helvetica, sans-serif',
        }}
      >
        {/* the sunburst: twelve rays from the centre, every other one darker */}
        {Array.from({ length: 12 }, (_, i) => (
          <div
            key={i}
            style={{
              position: 'absolute', left: 600 - 1000, top: 315 - 56, width: 2000, height: 112,
              background: i % 2 ? '#e85b26' : '#f4703a', transform: `rotate(${i * 15}deg)`,
            }}
          />
        ))}
        <div
          style={{
            display: 'flex', flexDirection: 'column', alignItems: 'center', width: 1000,
            padding: '40px 60px 44px', background: '#fbf4ea', borderRadius: 40,
            border: '5px solid #17131f', boxShadow: '0 12px 0 #17131f',
          }}
        >
          <div style={{ fontSize: 150, lineHeight: 1, display: 'flex' }}>{emoji}</div>
          <div style={{ fontSize: titleSize, fontWeight: 900, color: '#17131f', marginTop: 18, textAlign: 'center', lineHeight: 1.05, display: 'flex' }}>{title}</div>
          {line ? <div style={{ fontSize: 30, color: '#5b5566', marginTop: 12, textAlign: 'center', display: 'flex' }}>“{line}”</div> : null}
          {by ? <div style={{ fontSize: 30, fontWeight: 700, color: '#17131f', marginTop: 14, display: 'flex' }}>by @{by}</div> : null}
        </div>
        <div style={{ position: 'absolute', bottom: 30, left: 0, right: 0, display: 'flex', justifyContent: 'center', fontSize: 30, fontWeight: 900, color: '#ffffff' }}>
          made with Token Surfers 🏄 · tokensurfers.app
        </div>
      </div>
    ),
    { width: 1200, height: 630, emoji: 'twemoji', headers: { 'cache-control': 'public, max-age=86400, s-maxage=86400' } },
  )
}
