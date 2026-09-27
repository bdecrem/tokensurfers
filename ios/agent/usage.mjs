// Per-user spend on the mini, per UTC day (2026-09-26): the SDK's result
// messages carry `total_cost_usd` (list price); a user who has spent the day's
// allowance can't start another build until tomorrow. Kept in
// <root>/.usage.json so a restart doesn't reset the day. Bart (and anyone in
// SURF_UNLIMITED) is never capped; their spend is still recorded.

import fs from 'node:fs/promises'

export class Usage {
  constructor(file, { dailyUsd = 15, unlimited = ['bart'] } = {}) {
    this.file = file
    this.dailyUsd = dailyUsd
    this.unlimited = new Set(unlimited.map(u => u.trim().toLowerCase()).filter(Boolean))
    this.data = { day: this.day(), users: {} }
  }

  day() { return new Date().toISOString().slice(0, 10) }

  async load() {
    try {
      const d = JSON.parse(await fs.readFile(this.file, 'utf8'))
      if (d && d.users) this.data = d
    } catch {}
    this.roll()
  }

  async save() {
    try { await fs.writeFile(this.file, JSON.stringify(this.data)) } catch {}
  }

  roll() {
    if (this.data.day !== this.day()) this.data = { day: this.day(), users: {} }
  }

  row(user) {
    this.roll()
    const k = String(user || 'anon').toLowerCase()
    return this.data.users[k] ||= { usd: 0, builds: 0 }
  }

  /// May this user start a build now?
  check(user) {
    const r = this.row(user)
    const exempt = this.unlimited.has(String(user || '').toLowerCase())
    return { ok: exempt || r.usd < this.dailyUsd, spent: r.usd, builds: r.builds, cap: this.dailyUsd, exempt }
  }

  charge(user, usd, { build = false } = {}) {
    const r = this.row(user)
    r.usd += usd || 0
    if (build) r.builds += 1
    this.save()
  }

  today() {
    this.roll()
    const users = Object.values(this.data.users)
    return { day: this.data.day, users: users.length, usd: Number(users.reduce((s, r) => s + r.usd, 0).toFixed(2)), builds: users.reduce((s, r) => s + r.builds, 0) }
  }
}
