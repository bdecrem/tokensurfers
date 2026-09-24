// After an upload: wait for App Store Connect to process the build, add it to
// every public-link group, and submit it for beta review.
//   node testflight/asc-submit.mjs <buildNumber>
// Key 5A5HNSWA33 (this iMac; ASC_KEY_ID overrides), app 6815840420.
import crypto from 'crypto'; import fs from 'fs'; import dns from 'dns'; dns.setDefaultResultOrder('ipv4first')
const KID = process.env.ASC_KEY_ID ?? '5A5HNSWA33', ISS = '69a6de80-eb13-47e3-e053-5b8c7c11a4d1', APP = '6815840420', VER = process.argv[2]
if (!VER) { console.error('usage: node asc-submit.mjs <buildNumber>'); process.exit(1) }
const key = fs.readFileSync(process.env.HOME + '/.appstoreconnect/private_keys/AuthKey_' + KID + '.p8')
const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url')
const now = Math.floor(Date.now() / 1000)
const unsigned = b64({ alg: 'ES256', kid: KID, typ: 'JWT' }) + '.' + b64({ iss: ISS, iat: now, exp: now + 1100, aud: 'appstoreconnect-v1' })
const sig = crypto.sign('sha256', Buffer.from(unsigned), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url')
const TOK = unsigned + '.' + sig, B = 'https://api.appstoreconnect.apple.com/v1'
const api = async (p, m = 'GET', body) => {
  const r = await fetch(p.startsWith('http') ? p : B + p, { method: m, headers: { Authorization: 'Bearer ' + TOK, 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined })
  const t = await r.text(); if (!r.ok) throw new Error(m + ' ' + p + ' ' + r.status + ' ' + t.slice(0, 300)); return t ? JSON.parse(t) : {}
}
const sleep = ms => new Promise(r => setTimeout(r, ms))
let build
for (let i = 0; i < 40; i++) {
  const d = await api(`/builds?filter[app]=${APP}&filter[version]=${VER}&filter[preReleaseVersion.platform]=IOS`)
  build = d.data[0]; const st = build?.attributes.processingState
  console.log('build ' + VER + ':', st ?? 'not yet')
  if (st === 'VALID') break
  if (st === 'FAILED' || st === 'INVALID') process.exit(1)
  await sleep(30000)
}
const groups = (await api(`/apps/${APP}/betaGroups`)).data
console.log('groups:', groups.map(g => g.attributes.name + (g.attributes.publicLinkEnabled ? ' (public: ' + g.attributes.publicLink + ')' : '')).join(', '))
for (const g of groups.filter(g => g.attributes.publicLinkEnabled)) {
  try { await api(`/betaGroups/${g.id}/relationships/builds`, 'POST', { data: [{ type: 'builds', id: build.id }] }); console.log('added to', g.attributes.name) } catch (e) { console.log('add:', e.message.slice(0, 160)) }
}
try {
  await api('/betaAppReviewSubmissions', 'POST', { data: { type: 'betaAppReviewSubmissions', relationships: { build: { data: { type: 'builds', id: build.id } } } } })
  console.log('submitted ' + VER + ' for beta review')
} catch (e) { console.log('submit:', e.message.slice(0, 300)) }
