#!/bin/bash
# On the mini, once: the launchd job for the agent server (port 3910) and its
# tunn3l tunnel (surf-mini.tunn3l.sh). Secrets live in ~/.surf-agent.env
# (chmod 600): SURF_APP_KEY, VERCEL_TOKEN, CLAUDE_CODE_OAUTH_TOKEN.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOGS="$HOME/Library/Logs/tokensurfers"
mkdir -p "$LOGS" "$HOME/Library/LaunchAgents" "$HOME/surf-apps"
test -f "$HOME/.surf-agent.env" || { echo "missing ~/.surf-agent.env"; exit 1; }

cat > "$HOME/Library/LaunchAgents/com.tokensurfers.agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.tokensurfers.agent</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>-lc</string>
    <string>set -a; . \$HOME/.surf-agent.env; set +a; unset ANTHROPIC_API_KEY; exec /opt/homebrew/bin/node $HERE/server.mjs</string>
  </array>
  <key>WorkingDirectory</key><string>$HERE</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOGS/agent.out.log</string>
  <key>StandardErrorPath</key><string>$LOGS/agent.err.log</string>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>SURF_AGENT_PORT</key><string>3910</string>
    <key>SURF_AGENT_ROOT</key><string>$HOME/surf-apps</string>
  </dict>
</dict></plist>
PLIST

cat > "$HOME/Library/LaunchAgents/sh.tunn3l.surf-mini.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>sh.tunn3l.surf-mini</string>
  <key>ProgramArguments</key><array>
    <string>$HOME/.tunn3l/bin/tunn3l</string><string>http</string><string>3910</string><string>--subdomain</string><string>surf-mini</string>
  </array>
  <key>WorkingDirectory</key><string>$HOME</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/tunn3l/tunnel-surf-mini.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/tunn3l/tunnel-surf-mini.err.log</string>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
  </dict>
</dict></plist>
PLIST

for job in com.tokensurfers.agent sh.tunn3l.surf-mini; do
  launchctl bootout "gui/$(id -u)/$job" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$job.plist"
done
sleep 3
curl -s -m 5 http://localhost:3910/health; echo
