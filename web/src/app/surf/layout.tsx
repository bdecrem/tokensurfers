import type { Metadata, Viewport } from 'next'
import { Anton, Montserrat } from 'next/font/google'
import './surf.css'

const display = Anton({ weight: '400', subsets: ['latin'], variable: '--font-display' })
const body = Montserrat({ weight: ['600', '800', '900'], subsets: ['latin'], variable: '--font-body' })

export const metadata: Metadata = {
  title: 'Token Surfers',
  description: 'Vibe code while you surf. A brainrot coding agent builds little apps on your phone while you play a runner. Every token is a coin.',
  metadataBase: new URL(process.env.SURF_SITE_URL || 'https://tokensurfers.app'),
  openGraph: {
    title: 'Token Surfers',
    description: 'Vibe code while you surf. Tokens become coins, tool calls become trains.',
    images: ['/surf/og.png'],
  },
  twitter: { card: 'summary_large_image', images: ['/surf/og.png'] },
}

export const viewport: Viewport = { themeColor: '#f4703a', viewportFit: 'cover', colorScheme: 'light' }

export default function SurfLayout({ children }: { children: React.ReactNode }) {
  return <div className={`sf burst ${display.variable} ${body.variable}`}>{children}</div>
}
