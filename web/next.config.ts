import type { NextConfig } from 'next'

// The whole site lives under /surf (that's how it runs inside hilma, where
// tokensurfers.app is rewritten to /surf). The root just goes there.
const config: NextConfig = {
  async redirects() {
    return [{ source: '/', destination: '/surf', permanent: false }]
  },
}

export default config
