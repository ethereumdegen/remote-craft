#!/usr/bin/env bash
#
# deploy-testflight.sh — archive Remote Craft and upload it to App Store
# Connect (TestFlight) in one shot, no clicking through Xcode.
#
# ONE-TIME SETUP
#   1. Paid Apple Developer Program membership.
#   2. Create the app record once: App Store Connect -> Apps -> + New App,
#      bundle id  com.remotecraft.ios.  (scripts/asc-bootstrap.py does this
#      from the command line if you would rather not click.)
#   3. Create an App Store Connect API key: App Store Connect -> Users and
#      Access -> Integrations -> App Store Connect API -> +. Download the
#      AuthKey_XXX.p8 (once only), and note the Issuer ID and the Key ID.
#   4. Copy deploy.env.example to deploy.env and fill in the three values.
#
# THEN, every release is just:   ./deploy-testflight.sh
#
# The script auto-increments the build number, regenerates the project,
# archives with automatic signing, and uploads.
#
# EXPORT COMPLIANCE, read this once: this app is an SSH client, so it uses
# encryption, and the Info.plist deliberately does NOT declare
# ITSAppUsesNonExemptEncryption. That is not an oversight — the answer is a
# legal declaration and it is yours to make, not this script's. App Store
# Connect will mark the build "Missing Compliance" and ask you; answer it
# there once per build, or add the key to project.yml when you have decided.
set -euo pipefail
cd "$(dirname "$0")"

[ -f deploy.env ] && set -a && source deploy.env && set +a

PROJECT="RemoteCraft.xcodeproj"
SCHEME="RemoteCraft"
ARCHIVE="build/RemoteCraft.xcarchive"
EXPORT_DIR="build/export"
EXPORT_PLIST="build/ExportOptions.plist"
TEAM_ID="${TEAM_ID:-SWLCQ3VGVF}"

fail() { printf '\033[31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

command -v xcodegen >/dev/null || fail "xcodegen not found (brew install xcodegen)."
: "${ASC_KEY_ID:?set ASC_KEY_ID in deploy.env (App Store Connect API Key ID)}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID in deploy.env (App Store Connect Issuer ID)}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH in deploy.env (path to your AuthKey_XXX.p8)}"
ASC_KEY_PATH="${ASC_KEY_PATH/#\~/$HOME}"
[ -f "$ASC_KEY_PATH" ] || fail "ASC_KEY_PATH does not exist: $ASC_KEY_PATH"

AUTH=(-authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

# ---- GitHub device flow -----------------------------------------------------
# project.yml ships RC_GITHUB_CLIENT_ID empty, so a build that does not override
# it here reaches a tester's phone with GitHub sign-in dead: the app names the
# missing Info.plist key on screen rather than failing at the first request, but
# the whole "publish this phone's key to your account" route is gone with it.
# Overriding on the xcodebuild command line rather than editing project.yml keeps
# the id out of the repo. It is not a secret — the device flow exchanges it with
# no client secret at all — it is simply per-account.
GITHUB_SETTING=()
if [ -n "${RC_GITHUB_CLIENT_ID:-}" ]; then
  GITHUB_SETTING=("RC_GITHUB_CLIENT_ID=$RC_GITHUB_CLIENT_ID")
else
  printf '\033[33mwarning:\033[0m RC_GITHUB_CLIENT_ID is unset; this build ships without GitHub sign-in.\n' >&2
fi

# ---- bump the build number --------------------------------------------------
# CFBundleVersion must strictly increase for every upload, so bump it in
# project.yml (the source of truth XcodeGen reads) before regenerating.
CUR=$(grep -Eo 'CURRENT_PROJECT_VERSION: "[0-9]+"' project.yml | grep -Eo '[0-9]+')
[ -n "$CUR" ] || fail "could not read CURRENT_PROJECT_VERSION from project.yml"
NEXT=$((CUR + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION: \"$CUR\"/CURRENT_PROJECT_VERSION: \"$NEXT\"/" project.yml
MARKETING=$(grep -Eo 'MARKETING_VERSION: "[^"]+"' project.yml | sed -E 's/.*"([^"]+)".*/\1/')
echo "==> Uploading Remote Craft $MARKETING (build $NEXT)"

# ---- regenerate + clean -----------------------------------------------------
echo "==> xcodegen generate"
xcodegen generate >/dev/null
rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p build

# ---- archive ----------------------------------------------------------------
# -skipPackagePluginValidation: SwiftTerm ships a build-tool plugin, and a
# non-interactive build refuses to run one until it has been trusted.
echo "==> xcodebuild archive"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -skipPackagePluginValidation \
  -allowProvisioningUpdates \
  "${AUTH[@]}" \
  ${GITHUB_SETTING[@]+"${GITHUB_SETTING[@]}"} \
  | grep -E '^(\*\*|.*(error|warning):)' || true
[ -d "$ARCHIVE" ] || fail "archive failed — rerun without the grep filter to see why"

# ---- export -----------------------------------------------------------------
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

echo "==> xcodebuild -exportArchive (uploads to TestFlight)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  "${AUTH[@]}"

echo
echo "==> Uploaded Remote Craft $MARKETING (build $NEXT)."
echo "    Processing takes ~10 minutes. Internal testers get it with no review."
echo "    App Store Connect will ask for export compliance — see the note at"
echo "    the top of this script."
