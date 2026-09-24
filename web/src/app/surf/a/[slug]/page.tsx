import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { getSurfUser } from '@/lib/surf/auth'
import { getApp, ogImageURL } from '@/lib/surf/apps'
import { Player, Report, Upvote } from '../../client'
import { Footer, TESTFLIGHT, TopBar } from '../../parts'

export const dynamic = 'force-dynamic'

type Params = { params: Promise<{ slug: string }> }

export async function generateMetadata({ params }: Params): Promise<Metadata> {
  const { slug } = await params
  const app = await getApp(slug, null).catch(() => null)
  if (!app) return { title: 'Token Surfers' }
  return {
    title: `${app.emoji} ${app.title} · Token Surfers`,
    description: app.prompt ? `“${app.prompt}” — by @${app.owner}` : `by @${app.owner}`,
    openGraph: { title: `${app.emoji} ${app.title}`, description: `by @${app.owner} on Token Surfers`, images: [ogImageURL(app)] },
    twitter: { card: 'summary_large_image', images: [ogImageURL(app)] },
  }
}

export default async function AppPage({ params }: Params) {
  const { slug } = await params
  const user = await getSurfUser()
  const app = await getApp(slug, user?.id ?? null).catch(() => null)
  if (!app) notFound()
  const deep = `tokensurfers://remix/${app.slug}`
  return (
    <main className="wrap">
      <TopBar />
      <div className="play">
        <div><Player html={app.html} siteUrl={app.siteUrl} /></div>
        <div className="meta">
          <h1 className="head stroke">{app.emoji} {app.title}</h1>
          <div className="by">
            by @{app.owner}
            {app.remixOf ? <> · remix of <Link href={`/surf/a/${app.remixOf.slug}`} style={{ textDecoration: 'underline' }}>{app.remixOf.title}</Link></> : null}
            {app.remixes > 0 ? <> · {app.remixes} remix{app.remixes === 1 ? '' : 'es'}</> : null}
          </div>
          {app.prompt ? (
            <div className="card prompt"><small>THE ASK</small>“{app.prompt}”</div>
          ) : null}
          <div className="actions">
            <Upvote slug={app.slug} upvotes={app.upvotes} voted={app.voted} />
            {app.siteUrl
              ? <a className="key" href={app.siteUrl} target="_blank" rel="noopener">open it ↗</a>
              : <a className="key" href={deep}>remix it in the app 🔁</a>}
          </div>
          {app.siteUrl ? (
            <p className="note">built by Claude Code on the Token Surfers agent and deployed on Vercel; it opens in its own tab.</p>
          ) : (
            <p className="note">
              remixing opens Token Surfers on your phone with a copy of this app to change.{' '}
              {TESTFLIGHT ? <a href={TESTFLIGHT} style={{ textDecoration: 'underline' }}>don't have it? TestFlight →</a> : 'the TestFlight beta is coming.'}
            </p>
          )}
          <Report slug={app.slug} />
        </div>
      </div>
      <Footer />
    </main>
  )
}
