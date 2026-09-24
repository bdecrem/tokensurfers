// Where gallery reports go. Both channels are optional and configured by
// environment only, so this file has no dependency outside surf/:
//   SURF_REPORT_EMAIL + SENDGRID_API_KEY        → an email
//   SURF_REPORT_TEXT_URL (+ _SECRET, _TO)        → POST { handle, text } to an
//                                                 endpoint that sends a text
//                                                 (hilma points it at its own
//                                                 iMessage sender)
// Never throws: a report is stored before this runs, and a failed note must
// not fail the report.

export async function notifyReport(subject: string, line: string): Promise<void> {
  await Promise.all([emailReport(subject, line), textReport(line)])
}

async function emailReport(subject: string, line: string): Promise<void> {
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

async function textReport(line: string): Promise<void> {
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
