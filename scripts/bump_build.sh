#!/usr/bin/env bash
# Increments CURRENT_PROJECT_VERSION in project.yml and regenerates the Xcode
# project. This is the ONLY thing that owns the build number: App Store
# Connect rejects a build whose CFBundleVersion is not higher than the last
# one, and ExportOptions sets manageAppVersionAndBuildNumber=false so Xcode
# never quietly picks its own at upload time.
set -euo pipefail
cd "$(dirname "$0")/.."

CURRENT=$(awk '/^ *CURRENT_PROJECT_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' project.yml)
[[ "$CURRENT" =~ ^[0-9]+$ ]] || { echo "cannot read CURRENT_PROJECT_VERSION from project.yml" >&2; exit 1; }
NEXT=$((CURRENT + 1))

# Anchored to the two-space indent under settings.base so nothing else that
# happens to mention the key is touched.
/usr/bin/sed -i '' "s/^\( *CURRENT_PROJECT_VERSION: \).*/\1\"$NEXT\"/" project.yml
xcodegen generate >/dev/null

echo "build $CURRENT -> $NEXT"
