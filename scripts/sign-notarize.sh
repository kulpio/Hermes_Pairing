#!/bin/bash
# sign-notarize.sh — Developer ID sign, notarize, staple, and package the release.
#
# Inputs:
#   IDENTITY  env var — signing identity (default: auto-detect the sole
#             "Developer ID Application" identity in the keychain)
#   Notary credentials stored once as keychain profile "hermes-pong"
#
# Degrades gracefully when credentials are missing: hygiene checks still run,
# signing/notarizing no-op with a clear message, and a setup checklist prints.
# Never asks for or stores credential values.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/HermesPong.app"
ENTITLEMENTS="$ROOT/resources/entitlements.plist"
PROFILE="hermes-pong"
ZIP_NOTARIZE="$ROOT/dist/HermesPong-notarize.zip"
ZIP_RELEASE="$ROOT/dist/HermesPong-macOS.zip"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -d "$APP" ]] || fail "no app at $APP — run: bash scripts/build-app.sh (without --dev)"
[[ -f "$ENTITLEMENTS" ]] || fail "missing $ENTITLEMENTS"

# ---------- release hygiene (always runs, credentials or not) ----------
echo "→ Release hygiene check"
HYGIENE_BAD=0
LEAKS="$(find "$APP" \( -name "venv" -o -name ".env*" -o -name ".wa-auth" -o -name "project_root" \) -print)"
if [[ -n "$LEAKS" ]]; then
  echo "  ✗ forbidden files in bundle:" >&2
  echo "$LEAKS" >&2
  HYGIENE_BAD=1
fi
if grep -rIq "/Users/" "$APP" 2>/dev/null; then
  echo "  ✗ absolute user paths in bundle:" >&2
  grep -rIl "/Users/" "$APP" >&2
  HYGIENE_BAD=1
fi
[[ "$HYGIENE_BAD" == "0" ]] || fail "hygiene check failed — rebuild without --dev and inspect the files above"
echo "  ✓ bundle clean (no venv/.env*/.wa-auth/project_root, no /Users/ paths)"

find "$APP" -name ".DS_Store" -delete

# ---------- credential gate ----------
IDENTITY="${IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  MATCHES="$(security find-identity -v -p codesigning | grep "Developer ID Application" || true)"
  COUNT="$(printf '%s' "$MATCHES" | grep -c '"' || true)"
  if [[ "$COUNT" -eq 1 ]]; then
    IDENTITY="$(printf '%s' "$MATCHES" | sed -n 's/.*"\(.*\)".*/\1/p')"
  elif [[ "$COUNT" -gt 1 ]]; then
    echo "$MATCHES"
    fail "multiple Developer ID Application identities — set IDENTITY=\"...\" explicitly"
  fi
fi

HAVE_PROFILE=0
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  HAVE_PROFILE=1
fi

if [[ -z "$IDENTITY" || "$HAVE_PROFILE" == "0" ]]; then
  [[ -z "$IDENTITY" ]] && echo "→ Signing skipped: no \"Developer ID Application\" identity in keychain"
  [[ "$HAVE_PROFILE" == "0" ]] && echo "→ Notarization skipped: no keychain profile \"$PROFILE\""
  cat <<'CHECKLIST'

BLOCKED — needs Dylan (one-time, ~$99/yr, can take 1-2 days for Apple approval):
1. Enroll: developer.apple.com/programs (Apple Developer Program)
2. Create a "Developer ID Application" certificate (Xcode → Settings → Accounts → Manage Certificates, or developer portal) and install it in your login keychain
3. Store notary credentials once:
   xcrun notarytool store-credentials hermes-pong --apple-id <id> --team-id <TEAMID> --password <app-specific-password>
Then run: bash scripts/sign-notarize.sh
CHECKLIST
  exit 0
fi

# ---------- sign (no --deep; the bundle has a single Mach-O executable) ----------
echo "→ Signing with: $IDENTITY"
codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" -s "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "  ✓ signed + verified"

# ---------- notarize ----------
echo "→ Notarizing"
rm -f "$ZIP_NOTARIZE"
ditto -c -k --keepParent "$APP" "$ZIP_NOTARIZE"
SUBMIT_LOG="$(mktemp)"
if ! xcrun notarytool submit "$ZIP_NOTARIZE" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$SUBMIT_LOG"; then
  echo "notarytool submit failed" >&2
fi
STATUS="$(awk '/status:/ {s=$2} END {print s}' "$SUBMIT_LOG")"
SUBMISSION_ID="$(awk '/id:/ {print $2; exit}' "$SUBMIT_LOG")"
if [[ "$STATUS" != "Accepted" ]]; then
  echo "→ Notarization not accepted (status: ${STATUS:-unknown}) — fetching log" >&2
  if [[ -n "$SUBMISSION_ID" ]]; then
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" >&2 || true
  fi
  exit 1
fi
echo "  ✓ notarization accepted (id: $SUBMISSION_ID)"

# ---------- staple + package ----------
echo "→ Stapling"
xcrun stapler staple "$APP"

echo "→ Packaging release zip (post-staple)"
rm -f "$ZIP_RELEASE"
ditto -c -k --keepParent "$APP" "$ZIP_RELEASE"

# zip must contain only HermesPong.app
if zipinfo -1 "$ZIP_RELEASE" | grep -v "^HermesPong.app/" | grep -q .; then
  zipinfo -1 "$ZIP_RELEASE" | grep -v "^HermesPong.app/" >&2
  fail "release zip contains entries outside HermesPong.app/"
fi
echo "  ✓ zip contains only HermesPong.app"

echo "→ Gatekeeper assessment"
spctl --assess --type execute -vv "$APP"

echo ""
echo "Release ready: $ZIP_RELEASE"
