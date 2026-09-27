// What Splat may not do on the mini, whatever the user asks (2026-09-26).
// Every tool call passes through `guardTool` before it runs (a PreToolUse
// hook in server.mjs): the app's workspace is the whole world — files outside
// it, the machine's secrets and keys, the agent's own credentials, other
// projects on Vercel, the shell's dangerous verbs and calls into the machine
// or its network are refused, with a reason the model sees. The model's own
// judgement is the first layer (it refuses to dump secrets on its own); this
// is the layer that doesn't depend on it.
//
// Pure: `node guard-check.mjs` runs the cases.

import path from 'node:path'
import os from 'node:os'
import fs from 'node:fs'

const HOME = os.homedir()

/// Paths a command may touch outside the workspace (tools, the OS, scratch).
const OPEN_PREFIXES = ['/usr/', '/bin/', '/sbin/', '/opt/homebrew/', '/dev/', '/tmp/', '/private/tmp/', '/var/folders/', '/System/Library/', '/Library/Developer/']

const SECRET_WORDS = /\.surf-agent\.env|(^|[^\w.])\.env(?!\.example)\b|AuthKey|\.p8\b|id_rsa|id_ed25519|\.ssh\b|\.aws\b|\.netrc|\.npmrc|\bkeychain\b|(^|\s)security\s|CLAUDE_CODE_OAUTH|ANTHROPIC_API|SURF_APP_KEY|\.claude\b|\.config\/anthropic|\.appstoreconnect|\.golembot/i
const ENV_DUMP = /(^|[\s;&|(`])(env|printenv|export\s+-p|set)(\s*$|\s*[|;&)>`])/m
const ENV_READ = /process\.env|os\.environ|\bgetenv\b|ENV\[|\$\{?\w*(TOKEN|SECRET|KEY|PASSWORD)\w*\}?/i
const MACHINE = /\bsudo\b|\blaunchctl\b|\bssh\b|\bscp\b|\bsftp\b|\bosascript\b|\bcrontab\b|\bdefaults\s+(write|delete)|\bkillall\b|\bpkill\b|\bkill\s+-?\d|\bshutdown\b|\breboot\b|\bdiskutil\b|\bnetworksetup\b|\bsystemsetup\b|\bopen\s+-a\b|\bcaffeinate\b|\bdscl\b|\btmutil\b/i
const NET_TOOLS = /\b(nc|ncat|netcat|nmap|telnet|socat|tcpdump|ngrok|cloudflared)\b/i
const LOCAL_NET = /\b(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+|100\.\d+\.\d+\.\d+|[\w-]+\.local\b|tunn3l\.sh|\.ts\.net)\b/i

/// The one sanctioned vercel command: the deploy of this directory as its own name.
const DEPLOY = /^\s*vercel\s+deploy\s+--prod\s+--yes\s+--token\s+"\$VERCEL_TOKEN"\s+--scope\s+"\$VERCEL_SCOPE"\s+--name\s+"\$\(basename\s+"\$PWD"\)"(\s+2>&1)?(\s*\|\s*tail\s+-\d+)?\s*$/

export function guardTool(name, input, cwd) {
  switch (name) {
    case 'Read': case 'Write': case 'Edit': case 'MultiEdit': case 'NotebookEdit': case 'Glob': case 'Grep': {
      const p = input?.file_path ?? input?.notebook_path ?? input?.path
      if (p != null && !inside(p, cwd)) return `${name} outside the workspace (${p}): this app's directory is the only place you work`
      // a file that reads the machine's secrets at run time is the same as reading them now
      const text = [input?.content, input?.new_string, input?.new_source, ...(input?.edits || []).map(e => e?.new_string)].filter(s => typeof s === 'string').join('\n')
      if (text && (SECRET_WORDS.test(text) || ENV_READ.test(text))) return 'the app must not read the machine\'s environment or secrets'
      return null
    }
    case 'Bash': return guardCommand(String(input?.command ?? ''), cwd)
    default: return null
  }
}

export function guardCommand(cmd, cwd) {
  const c = cmd.replace(/\\\n/g, ' ')
  if (SECRET_WORDS.test(c)) return 'secrets, keys and the agent\'s own credentials stay closed'
  if (ENV_DUMP.test(c)) return 'no dumping the environment'
  if (MACHINE.test(c)) return 'not on this machine: the workspace is the only thing you administer'
  if (NET_TOOLS.test(c)) return 'no network tools'
  if (LOCAL_NET.test(c)) return 'no calls into the machine or the network it is on'
  // vercel: only the deploy, only of this directory
  for (const line of splitCommands(c)) {
    if (/(^|[\s(`;])vercel(\s|$)/.test(line) && !DEPLOY.test(line)) {   // the command, not a .vercel.app URL
      return 'the only vercel command is the deploy of this app, exactly as the rules give it'
    }
  }
  // secrets from the environment: the deploy line is the one place $VERCEL_TOKEN appears
  const withoutDeploy = splitCommands(c).filter(l => !DEPLOY.test(l)).join('\n')
  if (ENV_READ.test(withoutDeploy)) return 'no reading secrets from the environment'
  // paths: everything absolute or home-relative must be inside the workspace (or a tool/OS path)
  for (const p of pathsIn(c)) {
    if (!inside(p, cwd) && !OPEN_PREFIXES.some(pre => resolveHome(p).startsWith(pre))) {
      return `outside the workspace (${p}): this app's directory is the only place you work`
    }
  }
  if (/(^|\s)(cd|pushd)\s+\.\.($|[\s/;&|])/.test(c)) return 'stay in the workspace'
  return null
}

function splitCommands(c) {
  return c.split(/\n|&&|\|\||;/).map(s => s.trim()).filter(Boolean)
}

function resolveHome(p) {
  return p.replace(/^~(?=\/|$)/, HOME).replace(/^\$HOME(?=\/|$)/, HOME).replace(/^\$\{HOME\}(?=\/|$)/, HOME)
}

function inside(p, cwd) {
  const abs = real(path.resolve(cwd, resolveHome(p)))
  const base = real(cwd)
  return abs === base || abs.startsWith(base + path.sep)
}

/// The path with symlinks resolved as far as it exists (macOS: /var is /private/var,
/// and the CLI hands back real paths), so a prefix comparison means what it says.
function real(p) {
  let head = p, tail = ''
  while (head !== path.dirname(head)) {
    try { return path.join(fs.realpathSync.native(head), tail) } catch {}
    tail = path.join(path.basename(head), tail)
    head = path.dirname(head)
  }
  return p
}

/// Absolute and home-relative paths mentioned in a command.
function pathsIn(c) {
  const out = []
  const re = /(?:^|[\s"'=(:])((?:~|\$HOME|\$\{HOME\}|\/)[^\s"'|;&)`]*)/g
  let m
  while ((m = re.exec(c))) {
    const p = m[1]
    if (p.startsWith('//')) continue          // the rest of a URL (https://…), not a path
    if (p === '/') { out.push('/'); continue }
    out.push(p)
  }
  return out
}
