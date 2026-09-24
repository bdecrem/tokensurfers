// Root layout for the standalone mirror. In hilma the site's own root layout
// wraps /surf; everything Token Surfers needs is in app/surf/layout.tsx.
export const metadata = { title: 'Token Surfers' }

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body style={{ margin: 0 }}>{children}</body>
    </html>
  )
}
