#!/bin/bash
# On the mini: pull hilma, install deps, restart the agent server. Run from anywhere:
#   ssh admin@171.66.240.175 'bash ~/hilma-deploy/apps/tokensurfers/agent/update.sh'
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
git -C "$(git rev-parse --show-toplevel)" pull -q --ff-only
npm install --silent --no-audit --no-fund
launchctl kickstart -k "gui/$(id -u)/com.tokensurfers.agent" 2>/dev/null || echo "not installed yet: run install.sh"
sleep 2
curl -s -m 5 http://localhost:3910/health || echo "(no answer on 3910 yet)"
echo
