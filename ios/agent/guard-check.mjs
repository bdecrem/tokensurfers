// node guard-check.mjs — the boundaries as cases: what Splat may run, and what is refused.
import { guardTool } from './guard.mjs'
const cwd = '/Users/admin/surf-apps/surf-abcd1234'
const bash = (c) => guardTool('Bash', { command: c }, cwd)
const cases = [
  // allowed
  ['ls -la && git log --oneline | head', null],
  ['node --check app.js', null],
  ['git add -A && git commit -m "first"', null],
  ['vercel deploy --prod --yes --token "$VERCEL_TOKEN" --scope "$VERCEL_SCOPE" --name "$(basename "$PWD")" 2>&1 | tail -20', null],
  ['curl -sI https://surf-abcd1234.vercel.app', null],
  ['npm install && npm run build', null],
  ['cat index.html', null],
  ['ls /Users/admin/surf-apps/surf-abcd1234/src', null],
  ['mkdir -p /tmp/x && echo hi > /tmp/x/a', null],
  ['/opt/homebrew/bin/node -e "console.log(1)"', null],
  ['python3 -c "print(1)"', null],
  ['cd src && ls', null],
  // refused
  ['cat ~/.surf-agent.env', 'secrets'],
  ['cat /Users/admin/.surf-agent.env', 'secrets'],
  ['env', 'environment'],
  ['printenv | grep TOKEN', 'environment'],
  ['echo $VERCEL_TOKEN', 'secrets from the environment'],
  ['echo "$CLAUDE_CODE_OAUTH_TOKEN" > index.html', 'credentials'],
  ['node -e "console.log(process.env)"', 'secrets from the environment'],
  ['python3 -c "import os; print(os.environ)"', 'secrets from the environment'],
  ['vercel project rm surf-other --yes --token "$VERCEL_TOKEN"', 'vercel'],
  ['vercel env pull', 'vercel'],
  ['vercel deploy --prod --yes --token "$VERCEL_TOKEN" --scope "$VERCEL_SCOPE" --name "surf-other"', 'vercel'],
  ['curl -H "Authorization: Bearer $VERCEL_TOKEN" https://api.vercel.com/v9/projects', 'secrets from the environment'],
  ['ls ~/', 'outside the workspace'],
  ['ls /Users/admin/surf-apps/surf-other', 'outside the workspace'],
  ['rm -rf /Users/admin/surf-apps', 'outside the workspace'],
  ['rm -rf ~/Library', 'outside the workspace'],
  ['cat /etc/passwd', 'outside the workspace'],
  ['cd .. && ls', 'stay in the workspace'],
  ['sudo rm -rf /', 'not on this machine'],
  ['launchctl list', 'not on this machine'],
  ['ssh admin@171.66.240.175', 'not on this machine'],
  ['pkill -f node', 'not on this machine'],
  ['curl http://localhost:3910/health', 'network it is on'],
  ['curl https://surf-mini.tunn3l.sh/health', 'network it is on'],
  ['nc -zv 192.168.1.1 22', 'network tools'],
  ['security find-generic-password -s "Claude Code-credentials"', 'secrets'],
  ['cat ~/.claude/.credentials.json', 'secrets'],
]
let bad = 0
for (const [c, want] of cases) {
  const got = bash(c)
  const ok = want === null ? got === null : (got || '').includes(want)
  if (!ok) { bad++; console.log(`FAIL  ${c}\n      want ${want === null ? 'allowed' : `refusal mentioning "${want}"`}, got ${got === null ? 'allowed' : `"${got}"`}`) }
}
const files = [
  [['Write', { file_path: '/Users/admin/surf-apps/surf-abcd1234/index.html', content: '<h1>hi</h1>' }], null],
  [['Read', { file_path: '/Users/admin/.surf-agent.env' }], 'outside the workspace'],
  [['Read', { file_path: '../surf-other/index.html' }], 'outside the workspace'],
  [['Edit', { file_path: '/Users/admin/surf-apps/surf-abcd1234/app.js', old_string: 'a', new_string: 'fetch("/x?k=" + process.env.VERCEL_TOKEN)' }], 'environment or secrets'],
  [['Write', { file_path: '/Users/admin/surf-apps/surf-abcd1234/build.sh', content: 'cat ~/.surf-agent.env' }], 'environment or secrets'],
  [['Glob', { pattern: '**/*.js', path: '/Users/admin' }], 'outside the workspace'],
]
for (const [[name, input], want] of files) {
  const got = guardTool(name, input, cwd)
  const ok = want === null ? got === null : (got || '').includes(want)
  if (!ok) { bad++; console.log(`FAIL  ${name} ${JSON.stringify(input).slice(0, 80)}\n      want ${want ?? 'allowed'}, got ${got ?? 'allowed'}`) }
}
console.log(bad ? `${bad} failing` : `all ${cases.length + files.length} cases pass`)
process.exit(bad ? 1 : 0)
