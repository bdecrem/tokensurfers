#!/bin/bash
# Ship Token Surfers to TestFlight when this Mac has only a beta Xcode (App Store Connect
# refuses beta-SDK archives): the archive is built UNSIGNED on the Mac mini (release Xcode,
# checkout ~/ts-ship), tarred back here, and exported with this Mac's distribution profile and
# ASC key — the export re-signs and uploads; ASC judges the SDK from the archive. Then
# asc-submit.mjs waits for processing, adds the build to the public group and submits it.
#
#   ASC_KEY_ID=748UX45NAP TS_PROFILE="tokensurfers appstore m1" ./apps/tokensurfers/testflight/ship-via-mini.sh
#
# Ships the build number in project.yml as committed and PUSHED (the mini pulls main).
set -euo pipefail
cd "$(dirname "$0")/.."
MINI=${MINI:-admin@100.95.51.98}
KEYS="$HOME/.appstoreconnect/private_keys"
KEY_ID="${ASC_KEY_ID:?set ASC_KEY_ID, the App Store Connect key id on this Mac}"
ISSUER="69a6de80-eb13-47e3-e053-5b8c7c11a4d1"
PROFILE="${TS_PROFILE:?set TS_PROFILE, the IOS_APP_STORE profile name on this Mac}"
[ -f "$KEYS/AuthKey_$KEY_ID.p8" ] || { echo "error: $KEYS/AuthKey_$KEY_ID.p8 missing" >&2; exit 1; }
BUILD=$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' project.yml | sed -E 's/.*"([0-9]+)".*/\1/')
VERSION=$(grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')
[ -z "$(git status --porcelain project.yml)" ] || { echo "error: project.yml has uncommitted changes; commit and push the build number first" >&2; exit 1; }
git fetch -q origin && [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "error: push main first (the mini pulls it)" >&2; exit 1; }
OUT=$(mktemp -d "${TMPDIR:-/tmp}/tokensurfers-ship.XXXXXX")

echo "== archiving $VERSION ($BUILD) on the mini"
ssh -o ConnectTimeout=10 "$MINI" 'set -e; export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; cd ~/ts-ship && git pull -q --ff-only && cd apps/tokensurfers && [ -f TokenSurfers/App/Secrets.swift ] && { command -v xcodegen >/dev/null && xcodegen generate -q || echo "no xcodegen on the mini: using the committed .xcodeproj"; } && rm -rf /tmp/ts.xcarchive && xcodebuild archive -project TokenSurfers.xcodeproj -scheme TokenSurfers -destination "generic/platform=iOS" -archivePath /tmp/ts.xcarchive -configuration Release CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO > /tmp/ts-archive.log 2>&1 || { grep -E "error:" /tmp/ts-archive.log | head; exit 1; }; /usr/libexec/PlistBuddy -c "Print CFBundleVersion" /tmp/ts.xcarchive/Products/Applications/TokenSurfers.app/Info.plist; cd /tmp && tar czf ts.xcarchive.tgz ts.xcarchive' \
  || { echo "archive on the mini failed" >&2; exit 1; }
scp -q "$MINI:/tmp/ts.xcarchive.tgz" "$OUT/" && tar xzf "$OUT/ts.xcarchive.tgz" -C "$OUT"
GOT=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$OUT/ts.xcarchive/Products/Applications/TokenSurfers.app/Info.plist")
[ "$GOT" = "$BUILD" ] || { echo "error: the mini archived build $GOT, project.yml says $BUILD" >&2; exit 1; }

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
echo "== signing with \"$PROFILE\" and uploading"
xcodebuild -exportArchive -archivePath "$OUT/ts.xcarchive" -exportOptionsPlist "$OUT/export.plist" -exportPath "$OUT/export" \
  -authenticationKeyPath "$KEYS/AuthKey_$KEY_ID.p8" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER" \
  > "$OUT/export.log" 2>&1 || { grep -E "error|Error" "$OUT/export.log" | head -20; echo "upload failed — $OUT/export.log"; exit 1; }
echo "== uploaded; waiting for App Store Connect"
ASC_KEY_ID="$KEY_ID" node testflight/asc-submit.mjs "$BUILD"
echo "Token Surfers $VERSION ($BUILD) shipped via the mini. Logs: $OUT"
