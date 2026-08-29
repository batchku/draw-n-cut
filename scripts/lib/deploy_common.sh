#!/usr/bin/env bash
# Shared configuration and helpers for the signing/deploy scripts.
# Sourced with the repository root as the working directory.

TEAM_ID="V9DBGV72NL"                       # IRL Labs LLC (paid)
BUNDLE_ID="ai.kidwiz.drawncut"
SCHEME="DrawNCut"
PROJECT="DrawNCut.xcodeproj"
PROFILE_NAME="DrawNCut App Store (headless)"

# Signing material. Gitignored by living outside the repo: a private key and
# a certificate belong on the machine, never in version control.
SIGNING_DIR="${DRAWNCUT_SIGNING_DIR:-$HOME/.drawncut-signing}"
SIGNING_KEY="$SIGNING_DIR/distribution.key"
SIGNING_CSR="$SIGNING_DIR/distribution.csr"
SIGNING_CERT="$SIGNING_DIR/distribution.cer"
SIGNING_CERT_ID="$SIGNING_DIR/distribution.cert-id"
SIGNING_PROFILE="$SIGNING_DIR/appstore.mobileprovision"
KEYCHAIN_PATH="$HOME/Library/Keychains/drawncut-signing.keychain-db"

# Where an existing team distribution identity may already live. Apple caps
# distribution certificates per team at a small number and revoking one
# invalidates every build ever signed with it, so adopting a working identity
# beats minting a second one. Scoranger's bootstrap created this team's.
ADOPT_SIGNING_DIRS=(
  "${ADOPT_SIGNING_DIR:-}"
  "$HOME/.scoranger-signing"
)

ARCHIVE_PATH="build-archive/DrawNCut.xcarchive"
EXPORT_DIR="build-archive/export"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_tools() {
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "'$t' is not on PATH"
  done
}

# Credentials live in .deploy.env (gitignored) or the environment.
# Values are never echoed.
load_deploy_env() {
  if [[ -f ".deploy.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source ".deploy.env"
    set +a
  fi
  [[ -n "${ASC_KEY_ID:-}" ]] || die "ASC_KEY_ID is not set (see .deploy.env.example)"
  [[ -n "${ASC_ISSUER_ID:-}" ]] || die "ASC_ISSUER_ID is not set (see .deploy.env.example)"
  KEYCHAIN_PASSWORD="${SIGNING_KEYCHAIN_PASSWORD:-}"
  [[ -n "$KEYCHAIN_PASSWORD" ]] || die "SIGNING_KEYCHAIN_PASSWORD is not set (see .deploy.env.example)"
  ASC_KEY_FILE="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
  [[ -f "$ASC_KEY_FILE" ]] || die "App Store Connect key not found at $ASC_KEY_FILE"
}

# asc.py signs its JWT with openssl and speaks HTTP with the standard library,
# so any python3 will do — this repo carries no Python environment.
python_for_asc() {
  command -v python3 >/dev/null 2>&1 || die "python3 is not on PATH"
  command -v python3
}

# An Apple leaf certificate only forms a *valid* signing identity if the Apple
# WWDR intermediate is reachable. Trust evaluation scoped to our dedicated
# keychain cannot be relied on to find it in the login keychain, so put a copy
# alongside the leaf.
ensure_wwdr_in_keychain() {
  if security find-certificate -c "Apple Worldwide Developer Relations" \
       "$KEYCHAIN_PATH" >/dev/null 2>&1; then
    return 0
  fi
  local tmp; tmp=$(mktemp -d)
  local pem="$tmp/wwdr.pem"
  local found=0
  for kc in "$HOME/Library/Keychains/login.keychain-db" /Library/Keychains/System.keychain; do
    if security find-certificate -c "Apple Worldwide Developer Relations" -p "$kc" \
         > "$pem" 2>/dev/null && [[ -s "$pem" ]]; then
      found=1; break
    fi
  done
  if [[ $found -eq 0 ]]; then
    say "fetching the Apple WWDR intermediate"
    curl -fsSL "https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer" \
      -o "$tmp/wwdr.cer" || { rm -rf "$tmp"; die "could not obtain the Apple WWDR intermediate"; }
    openssl x509 -inform DER -in "$tmp/wwdr.cer" -out "$pem"
  fi
  security import "$pem" -k "$KEYCHAIN_PATH" -T /usr/bin/codesign >/dev/null 2>&1 || true
  rm -rf "$tmp"
  say "Apple WWDR intermediate present in the signing keychain"
}

# Apple names IOS_DISTRIBUTION certificates "iPhone Distribution: ..." and the
# newer universal DISTRIBUTION type "Apple Distribution: ...". Both sign an App
# Store build, so match either rather than one spelling.
distribution_identity() {
  security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null \
    | grep -E '"(iPhone|Apple) Distribution' | head -1 | sed -E 's/.*"(.*)"/\1/'
}

add_keychain_to_search_list() {
  # `security list-keychains` prints one quoted, indented path per line. Parse
  # it into an array: splitting the output on whitespace mangles any path with
  # a space in it and corrupts the whole search list -- which, if the login
  # keychain is the casualty, silently breaks every other tool that reads it.
  local -a current=()
  local line
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"   # strip leading whitespace
    line="${line%\"}"                          # strip surrounding quotes
    line="${line#\"}"
    [[ -n "$line" ]] && current+=("$line")
  done < <(security list-keychains -d user)

  local k
  for k in "${current[@]}"; do
    [[ "$k" == "$KEYCHAIN_PATH" ]] && return 0
  done
  security list-keychains -d user -s "${current[@]}" "$KEYCHAIN_PATH" >/dev/null
  say "added signing keychain to the search list"
}

# Prints the path of a signing directory already holding a usable distribution
# identity for this team, or fails. "Usable" is checked here rather than
# assumed: the certificate must be unexpired, issued to this team, and matched
# by the private key sitting next to it. Adopting a mismatched pair would fail
# much later, inside codesign, with a far less obvious message.
find_adoptable_identity() {
  local dir
  for dir in "${ADOPT_SIGNING_DIRS[@]}"; do
    [[ -n "$dir" && -d "$dir" ]] || continue
    [[ -f "$dir/distribution.key" && -f "$dir/distribution.cer" \
       && -f "$dir/distribution.cert-id" ]] || continue

    local cert_pem key_modulus cert_modulus subject
    cert_pem=$(openssl x509 -inform DER -in "$dir/distribution.cer" 2>/dev/null) || continue
    printf '%s' "$cert_pem" | openssl x509 -checkend 0 -noout >/dev/null 2>&1 || continue

    subject=$(printf '%s' "$cert_pem" | openssl x509 -noout -subject 2>/dev/null)
    [[ "$subject" == *"$TEAM_ID"* ]] || continue

    cert_modulus=$(printf '%s' "$cert_pem" | openssl x509 -noout -modulus 2>/dev/null)
    key_modulus=$(openssl rsa -in "$dir/distribution.key" -noout -modulus 2>/dev/null) || continue
    [[ "$cert_modulus" == "$key_modulus" ]] || continue

    printf '%s' "$dir"
    return 0
  done
  return 1
}
