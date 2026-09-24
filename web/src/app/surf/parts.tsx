import Link from 'next/link'
import type { AppCard } from '@/lib/surf/apps'
import { AccountPill } from './client'

export const GITHUB = 'https://github.com/bdecrem/hilma/tree/main/apps/tokensurfers'
export const TESTFLIGHT = process.env.SURF_TESTFLIGHT_URL || ''

/** Splat, the tube man (public/surf/splat.svg, from misc/splat.svg). */
/** Splat: the spinning splat blob (the runner in the game since 2026-09-24; the tube man before it). */
export function TubeMan({ className }: { className?: string }) {
  return <img className={className} src="/surf/blob.svg" alt="" aria-hidden="true" width={400} height={400} />
}

export function TopBar({ section }: { section?: string }) {
  return (
    <div className="bar">
      <Link className="brand" href="/surf">
        <TubeMan className="brandtube" />
        <span className="head stroke" style={{ fontSize: 26 }}>Token Surfers</span>
        {section ? <span className="pill">{section}</span> : null}
      </Link>
      <nav>
        <Link className="pill" href="/surf/gallery">gallery</Link>
        <a className="pill" href={GITHUB} target="_blank" rel="noreferrer">github</a>
        <AccountPill />
      </nav>
      <style>{`.sf .brandtube{width:30px;height:auto}`}</style>
    </div>
  )
}

export function hue(slug: string): number {
  let h = 0
  for (const ch of slug) h = (h * 31 + ch.charCodeAt(0)) % 360
  return h
}

export function AppTile({ app }: { app: AppCard }) {
  return (
    <Link className="card app" href={`/surf/a/${app.slug}`}>
      <div className="tile" style={{ background: `hsl(${hue(app.slug)} 55% 88%)` }}>
        <span>{app.emoji}</span>
        <span className={`votes ${app.voted ? 'on' : ''}`}>▲ {app.upvotes}</span>
      </div>
      <div className="t">{app.title}</div>
      <div className="by">@{app.owner}{app.remixOf ? ' · remix' : ''}</div>
    </Link>
  )
}

export function Footer() {
  return (
    <footer className="wrap">
      <span>Token Surfers</span>
      <a href={GITHUB} target="_blank" rel="noreferrer">source on GitHub</a>
      {TESTFLIGHT ? <a href={TESTFLIGHT}>TestFlight beta</a> : <span>TestFlight: soon</span>}
    </footer>
  )
}
