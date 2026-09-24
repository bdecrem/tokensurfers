import type { Metadata } from 'next'
import { Footer, TopBar } from '../parts'

export const metadata: Metadata = { title: 'Token Surfers · privacy' }

// The privacy policy App Store Connect asks for before a public TestFlight
// link. Plain words, and only what the app and the site actually do — keep it
// in step with the tables in apps/tokensurfers/schema/ and the LLM route.
export default function Privacy() {
  return (
    <main className="wrap">
      <TopBar section="privacy" />
      <div className="card" style={{ maxWidth: 720, margin: '10px auto 24px', padding: '22px 24px', fontSize: 16, lineHeight: 1.55 }}>
        <h1 className="head stroke" style={{ fontSize: 'clamp(36px, 6vw, 56px)', margin: '0 0 6px' }}>privacy</h1>
        <p style={{ margin: '0 0 18px', opacity: 0.75 }}>Token Surfers, the app and tokensurfers.app. Last updated September 24, 2026.</p>

        <h2 style={{ fontSize: 20, margin: '18px 0 6px' }}>What we keep</h2>
        <ul style={{ margin: 0, paddingLeft: 22 }}>
          <li><b>Your creations.</b> The things you build stay on your phone unless you publish them. Publishing sends the creation (its title, emoji, the ask you typed and the page Splat wrote) to our server so it can appear in the gallery, together with the handle it was published under.</li>
          <li><b>Accounts.</b> A handle and a password. The password is stored hashed. No email, no phone number, no name — so a lost password can't be reset yet.</li>
          <li><b>Scores.</b> A random id made on your phone, the handle you chose for the leaderboard, and your runs (score, coins, distance). The id is not tied to your Apple ID or anything else about you.</li>
          <li><b>Upvotes and reports.</b> Which creations your account upvoted, and any report you send about a creation.</li>
          <li><b>What you ask Splat.</b> Your requests, your notes while he works and the current state of your creation are sent to our server, which passes them to an AI model provider (Anthropic) to write the code. We don't store these conversations on the server; they live on your phone with the project.</li>
          <li><b>Voice.</b> If you hold the mic, speech recognition runs through Apple's speech service on your phone and only the resulting text is sent to us, as a note to Splat. Audio never reaches our server.</li>
        </ul>

        <h2 style={{ fontSize: 20, margin: '18px 0 6px' }}>What we don't do</h2>
        <ul style={{ margin: 0, paddingLeft: 22 }}>
          <li>No ads, no trackers, no analytics SDKs, no selling or sharing of data with anyone other than the AI model provider named above and the hosting we run on (Vercel, Supabase).</li>
          <li>No access to your contacts, photos, location or anything else on your phone.</li>
          <li>Creations run in a sandboxed web view inside the app. They can't read anything outside their own little page.</li>
        </ul>

        <h2 style={{ fontSize: 20, margin: '18px 0 6px' }}>Your choices</h2>
        <ul style={{ margin: 0, paddingLeft: 22 }}>
          <li>Unpublish any of your creations from the app or the site; it leaves the gallery right away.</li>
          <li>Delete the app and everything on the phone goes with it. To delete your account and everything published under it, email us.</li>
          <li>Something in the gallery shouldn't be there? Use Report on the creation, in the app or on the site.</li>
        </ul>

        <h2 style={{ fontSize: 20, margin: '18px 0 6px' }}>Children</h2>
        <p style={{ margin: 0 }}>Token Surfers is not directed at children under 13, and we don't knowingly collect anything from them.</p>

        <h2 style={{ fontSize: 20, margin: '18px 0 6px' }}>Contact</h2>
        <p style={{ margin: 0 }}>Bart Decrem · <a href="mailto:bdecrem@gmail.com" style={{ textDecoration: 'underline' }}>bdecrem@gmail.com</a></p>
      </div>
      <Footer />
    </main>
  )
}
