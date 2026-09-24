import { CaptionCycler } from './client'

const TESTFLIGHT = process.env.SURF_TESTFLIGHT_URL || ''
const GITHUB = process.env.SURF_GITHUB_URL || ''

// One paragraph, one image, two links. A sidequest, not a landing page.
export default function SurfLanding() {
  return (
    <main className="sq">
      <div className="sq-rays" aria-hidden="true" />
      <div className="sq-coins" aria-hidden="true">
        {Array.from({ length: 14 }, (_, i) => (
          <span key={i} style={{ left: `${(i * 37) % 100}%`, animationDelay: `${(i * 0.73) % 5}s`, animationDuration: `${4 + (i % 4)}s` }} />
        ))}
      </div>

      <h1 className="sq-title head">
        <span className="stroke">TOKEN</span>
        <span className="stroke yellow">SURFERS</span>
      </h1>

      <CaptionCycler />

      <div className="sq-shot">
        <img src="/surf/hero.jpg" alt="Splat writing a scream timer at 11pm while the surfer runs the rails underneath" width={900} height={1956} />
        <span className="sq-sticker s1">tokens = coins</span>
        <span className="sq-sticker s2">made with code</span>
      </div>

      <p className="sq-para">
        it&apos;s 3am. you ask your brainrot coding agent for &quot;a timer that screams at me&quot; and it just… starts
        writing it, live, on your phone, narrating like a tiktok voiceover, while you surf a subway track underneath
        where every token it types is a coin, every tool call is a train, and every bug it finds crawls onto the rails
        for you to stomp. it ships. you publish it. someone remixes it. nobody asked for this. you&apos;re absolutely right.
      </p>

      <div className="sq-links">
        <a className="key yellow" href="/surf/gallery">stuff people made at 3am 🌙</a>
        {TESTFLIGHT ? <a className="key" href={TESTFLIGHT}>get it on testflight 🏄</a> : <span className="key" aria-disabled="true">testflight · soon 🏄</span>}
        {GITHUB ? <a className="key ink" href={GITHUB} target="_blank" rel="noreferrer">github</a> : <span className="key ink" aria-disabled="true">github · soon</span>}
      </div>
    </main>
  )
}
