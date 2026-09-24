#!/bin/bash
# Ship Token Surfers to TestFlight from this iMac.
#
#   ./apps/tokensurfers/testflight/ship.sh            # bump the build, archive, upload, submit
#   ./apps/tokensurfers/testflight/ship.sh 0.2        # also set the marketing version
#   SKIP_BUMP=1 ./apps/tokensurfers/testflight/ship.sh
#
# Signing is manual: profile "tokensurfers appstore imac" (IOS_APP_STORE,
# minted 2026-09-24 over the ASC API on this Mac's Apple Distribution cert
# 4YB38SZ2F2) and API key 5A5HNSWA33. Another Mac needs its own profile on its
# own distribution cert — see the Polly runbook for the POST /profiles call.
set -euo pipefail
cd "$(dirname "$0")/.."

KEYS="$HOME/.appstoreconnect/private_keys"
KEY_ID="${ASC_KEY_ID:-5A5HNSWA33}"
ISSUER="69a6de80-eb13-47e3-e053-5b8c7c11a4d1"
PROFILE="${TS_PROFILE:-tokensurfers appstore imac}"
[ -f "$KEYS/AuthKey_$KEY_ID.p8" ] || { echo "error: $KEYS/AuthKey_$KEY_ID.p8 missing" >&2; exit 1; }
[ -f TokenSurfers/App/Secrets.swift ] || { echo "error: TokenSurfers/App/Secrets.swift missing (see Secrets.swift.example)" >&2; exit 1; }
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"

if [ "${SKIP_BUMP:-}" != 1 ]; then
  CUR=$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' project.yml | sed -E 's/.*"([0-9]+)".*/\1/')
  NEXT=$((CUR + 1))
  sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:) \"[0-9]+\"/\1 \"$NEXT\"/" project.yml
  if [ -n "${1:-}" ]; then sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:) \"[^\"]+\"/\1 \"$1\"/" project.yml; fi
fi
BUILD=$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' project.yml | sed -E 's/.*"([0-9]+)".*/\1/')
VERSION=$(grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')
xcodegen generate -q
OUT=$(mktemp -d "${TMPDIR:-/tmp}/tokensurfers-ship.XXXXXX")

cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>upload</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>Apple Distribution</string>
<key>teamID</key><string>274T5WCVD2</string>
<key>provisioningProfiles</key><dict><key>com.bartdecrem.tokensurfers</key><string>$PROFILE</string></dict>
</dict></plist>
PLIST

echo "== archiving $VERSION ($BUILD) with \"$PROFILE\""
xcodebuild archive -project TokenSurfers.xcodeproj -scheme TokenSurfers -destination 'generic/platform=iOS' \
  -archivePath "$OUT/TokenSurfers.xcarchive" -configuration Release \
  CODE_SIGN_STYLE=Manual "PROVISIONING_PROFILE_SPECIFIER=$PROFILE" "CODE_SIGN_IDENTITY=Apple Distribution" \
  > "$OUT/archive.log" 2>&1 || { grep -E "error:" "$OUT/archive.log" | head -20; echo "archive failed — $OUT/archive.log"; exit 1; }
echo "== uploading"
xcodebuild -exportArchive -archivePath "$OUT/TokenSurfers.xcarchive" -exportOptionsPlist "$OUT/export.plist" -exportPath "$OUT/export" \
  -authenticationKeyPath "$KEYS/AuthKey_$KEY_ID.p8" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER" \
  > "$OUT/export.log" 2>&1 || { grep -E "error|Error" "$OUT/export.log" | head -20; echo "upload failed — $OUT/export.log"; exit 1; }
echo "== uploaded; waiting for App Store Connect"
ASC_KEY_ID="$KEY_ID" node testflight/asc-submit.mjs "$BUILD"
echo "Token Surfers $VERSION ($BUILD) shipped. Logs: $OUT"
