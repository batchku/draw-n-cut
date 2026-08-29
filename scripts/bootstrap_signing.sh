#!/usr/bin/env bash
# One-time signing setup for headless TestFlight deploys.
#
# Gives this repo a *local* iOS distribution identity: a private key that
# lives on this machine, a certificate Apple issued for it, and an App Store
# provisioning profile binding both to ai.kidwiz.drawncut. After this runs,
# deploy-testflight.sh signs and uploads with no Apple ID session, no Xcode
# account and no cloud-signing permission -- which is what makes a deploy
# runnable from a phone.
#
# It prefers to ADOPT an existing team distribution identity over minting a
# new one. Apple caps distribution certificates per team at a small number,
# and revoking one invalidates every build ever signed with it, so a second
# certificate for the same team is a cost with no benefit: certificates are
# per-team, and only the provisioning profile is per-app.
#
#   scripts/bootstrap_signing.sh          # create what is missing
#   scripts/bootstrap_signing.sh --force  # replace the profile
#   scripts/bootstrap_signing.sh --new-cert  # mint a certificate anyway
#
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=./lib/deploy_common.sh
source "scripts/lib/deploy_common.sh"

FORCE=""
NEW_CERT=0
for arg in "$@"; do
  case "$arg" in
    --force)    FORCE="--force" ;;
    --new-cert) NEW_CERT=1 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *)          die "unknown argument: $arg" ;;
  esac
done

require_tools openssl security curl
load_deploy_env
PY=$(python_for_asc)

mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"

# -- 1. a distribution identity ---------------------------------------------
if [[ -f "$SIGNING_KEY" && -f "$SIGNING_CERT" && -f "$SIGNING_CERT_ID" ]]; then
  say "reusing this repo's certificate, id $(cat "$SIGNING_CERT_ID")"
elif [[ $NEW_CERT -eq 0 ]] && adopted=$(find_adoptable_identity); then
  say "adopting the existing $TEAM_ID distribution identity from $adopted"
  cp "$adopted/distribution.key" "$SIGNING_KEY"
  cp "$adopted/distribution.cer" "$SIGNING_CERT"
  cp "$adopted/distribution.cert-id" "$SIGNING_CERT_ID"
  chmod 600 "$SIGNING_KEY"
  say "certificate id $(cat "$SIGNING_CERT_ID") now serves both apps"
else
  # The private key never leaves this machine; Apple only ever sees the CSR.
  say "generating a 2048-bit RSA private key"
  openssl genrsa -out "$SIGNING_KEY" 2048 2>/dev/null
  chmod 600 "$SIGNING_KEY"
  say "building certificate signing request"
  openssl req -new -key "$SIGNING_KEY" -out "$SIGNING_CSR" \
    -subj "/CN=DrawNCut headless distribution/O=$TEAM_ID/C=US"
  say "asking App Store Connect for an iOS distribution certificate"
  "$PY" scripts/lib/asc.py create-cert \
    --csr "$SIGNING_CSR" --out "$SIGNING_CERT" --id-file "$SIGNING_CERT_ID"
fi
CERT_ID=$(cat "$SIGNING_CERT_ID")

# -- 2. keychain ------------------------------------------------------------
# A dedicated keychain, not the login one: signing must work while the Mac is
# locked, and must not need the user's login password to authorise codesign.
if [[ ! -f "$KEYCHAIN_PATH" ]]; then
  say "creating signing keychain $KEYCHAIN_PATH"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
fi
security set-keychain-settings "$KEYCHAIN_PATH"          # no auto-lock timeout
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

say "importing certificate and private key"
# -A would allow any binary to use the key; scope it to the signing tools.
security import "$SIGNING_CERT" -k "$KEYCHAIN_PATH" -T /usr/bin/codesign \
  -T /usr/bin/security -T /usr/bin/productsign >/dev/null 2>&1 || true
security import "$SIGNING_KEY" -k "$KEYCHAIN_PATH" -T /usr/bin/codesign \
  -T /usr/bin/security -T /usr/bin/productsign >/dev/null 2>&1 || true

# Without this, codesign blocks on a GUI prompt the first time it touches the
# key -- the single most common cause of a "headless" build hanging forever.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null 2>&1 || true

ensure_wwdr_in_keychain
add_keychain_to_search_list

IDENTITY=$(distribution_identity)
[[ -n "$IDENTITY" ]] || die "the distribution identity did not import; \
check that $SIGNING_KEY matches the certificate Apple issued"
say "signing identity ready: $IDENTITY"

# -- 3. provisioning profile ------------------------------------------------
# This is the only per-app Apple resource the bootstrap creates.
say "resolving bundle id $BUNDLE_ID"
BUNDLE_INTERNAL_ID=$("$PY" scripts/lib/asc.py bundle-id "$BUNDLE_ID")
say "ensuring App Store profile \"$PROFILE_NAME\""
"$PY" scripts/lib/asc.py ensure-profile \
  --name "$PROFILE_NAME" \
  --bundle-id "$BUNDLE_INTERNAL_ID" \
  --cert-id "$CERT_ID" \
  --out "$SIGNING_PROFILE" $FORCE

say ""
say "signing bootstrap complete. Deploy with:"
say "    scripts/deploy-testflight.sh"
