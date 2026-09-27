// Where gallery reports and sign-up notes go. Both channels are optional and
// configured by environment only, so this file has no dependency outside surf/:
//   SURF_REPORT_EMAIL + SENDGRID_API_KEY        → an email
//   SURF_REPORT_TEXT_URL (+ _SECRET, _TO)        → POST { handle, text } to an
//                                                 endpoint that sends a text
//                                                 (hilma points it at its own
//                                                 iMessage sender)
// Never throws: a report is stored (a user is created) before this runs, and a
// failed note must not fail the request.

/** A report: an email and a text. */
export async function notifyReport(subject: string, line: string): Promise<void> {
  await Promise.all([sendEmail(subject, line), sendText(line)])
}

/** A new account (Bart's ask, 2026-09-26): one iMessage, sent after the response.
 *  (Email was the first choice; SendGrid's free plan has no credits.) */
export async function notifySignup(args: { handle: string; via: 'the app' | 'the web'; total: number | null }): Promise<void> {
  const nth = args.total ? ` · surfer #${args.total}` : ''
  await sendText(`🏄 Token Surfers: @${args.handle} just signed up from ${args.via}${nth}`)
}

export async function sendEmail(subject: string, line: string): Promise<void> {
  const to = process.env.SURF_REPORT_EMAIL
  const key = process.env.SENDGRID_API_KEY
  if (!to || !key) return
  try {
    const res = await fetch('https://api.sendgrid.com/v3/mail/send', {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        personalizations: [{ to: [{ email: to }] }],
        from: { email: process.env.SURF_REPORT_FROM || 'amber@intheamber.com', name: 'Token Surfers' },
        subject,
        content: [{ type: 'text/plain', value: line }],
      }),
      signal: AbortSignal.timeout(10_000),
    })
    if (!res.ok) console.error('[surf/notify] email', res.status, (await res.text()).slice(0, 200))
  } catch (e) {
    console.error('[surf/notify] email', (e as Error).message)
  }
}

export async function sendText(line: string): Promise<void> {
  const url = process.env.SURF_REPORT_TEXT_URL
  const secret = process.env.SURF_REPORT_TEXT_SECRET
  const to = process.env.SURF_REPORT_TEXT_TO
  if (!url || !secret || !to) return
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-imsg-secret': secret },
      body: JSON.stringify({ handle: to, text: line }),
      signal: AbortSignal.timeout(15_000),
    })
    if (!res.ok) console.error('[surf/notify] text', res.status, (await res.text()).slice(0, 200))
  } catch (e) {
    console.error('[surf/notify] text', (e as Error).message)
  }
}
