import Link from 'next/link'
import { getSurfUser } from '@/lib/surf/auth'
import { listApps, type AppCard } from '@/lib/surf/apps'
import { AppTile, Footer, TopBar } from '../parts'

export const dynamic = 'force-dynamic'

export default async function Gallery({ searchParams }: { searchParams: Promise<{ sort?: string }> }) {
  const { sort: s } = await searchParams
  const sort = s === 'new' ? 'new' : 'top'
  const user = await getSurfUser()
  let apps: AppCard[] = []
  let error: string | null = null
  try {
    apps = await listApps(sort, user?.id ?? null, 100)
  } catch (e) {
    error = (e as Error).message
  }
  return (
    <main className="wrap">
      <TopBar section="gallery" />
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap', margin: '10px 0 16px' }}>
        <h1 className="head stroke" style={{ fontSize: 'clamp(40px, 7vw, 72px)', margin: 0 }}>the gallery</h1>
        <div className="tabs">
          <Link className={sort === 'top' ? 'on' : ''} href="/surf/gallery?sort=top">TOP</Link>
          <Link className={sort === 'new' ? 'on' : ''} href="/surf/gallery?sort=new">NEW</Link>
        </div>
      </div>
      {error ? <div className="card empty">the gallery is taking a break: {error}</div> : null}
      {!error && apps.length === 0 ? <div className="card empty">nothing here yet. publish something from the app's ••• menu.</div> : null}
      <div className="grid">{apps.map((a) => <AppTile key={a.id} app={a} />)}</div>
      <Footer />
    </main>
  )
}
