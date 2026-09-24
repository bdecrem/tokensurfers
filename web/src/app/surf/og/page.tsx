import { TubeMan } from '../parts'

/** A 1200×630 card, screenshotted by scripts/surf/og.mjs into public/surf/og.png. */
export default function OG() {
  return (
    <div style={{ width: 1200, height: 630, position: 'relative', overflow: 'hidden', display: 'flex', alignItems: 'center', padding: '0 80px', gap: 40 }}>
      <div>
        <div className="head stroke" style={{ fontSize: 150, lineHeight: 0.9 }}>Token</div>
        <div className="head stroke yellow" style={{ fontSize: 150, lineHeight: 0.9 }}>Surfers</div>
        <div style={{ marginTop: 26, fontSize: 34, fontWeight: 900, color: '#fff', textShadow: '0 3px 0 #17131f' }}>vibe code while you surf 🏄</div>
      </div>
      <TubeMan className="ogtube" />
      <div className="phone" style={{ width: 230, position: 'absolute', right: 80, bottom: -60, transform: 'rotate(-6deg)' }}>
        <img src="/surf/hero.jpg" alt="" width={900} height={1956} />
      </div>
      <style>{`.sf .ogtube{position:absolute;right:300px;bottom:-10px;width:280px;height:auto}`}</style>
    </div>
  )
}
