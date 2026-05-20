#!/bin/bash
# Interactive helper to populate the GitHub Actions secrets the
# release workflow needs. Run this once after cloning Pacer for the
# first time; subsequent runs are no-ops for secrets that already
# exist (the script confirms before overwriting).
#
# Already-set by the initial public-release setup (you can skip):
#   - APPLE_TEAM_ID
#   - SPARKLE_ED_PRIVATE_KEY
#   - KEYCHAIN_PASSWORD
#
# This script collects the remaining five:
#   - MACOS_CERTIFICATE              (base64 of Developer ID Application .p12)
#   - MACOS_CERTIFICATE_PASSWORD     (password used during .p12 export)
#   - NOTARY_KEY_ID                  (App Store Connect API key ID)
#   - NOTARY_ISSUER_ID               (App Store Connect issuer UUID)
#   - NOTARY_KEY_P8                  (the AuthKey_<id>.p8 file contents)
#
# Run:  bin/setup-release-secrets.sh
#
# Prereqs: `gh auth status` shows you're logged in with repo scope;
# you have the .p12 + .p8 files on disk.

set -euo pipefail

REPO="EricAndrechek/Pacer"

prompt_path() {
    local label="$1"
    local path
    while true; do
        read -r -p "${label}: " path
        # Expand ~ in case the user typed it literally.
        path="${path/#\~/$HOME}"
        if [ -f "${path}" ]; then
            echo "${path}"
            return
        fi
        echo "  -> not found: ${path}"
    done
}

confirm_overwrite() {
    local name="$1"
    if gh secret list --repo "${REPO}" 2>/dev/null | grep -q "^${name}[[:space:]]"; then
        read -r -p "${name} already exists. Overwrite? [y/N] " yn
        [ "${yn}" = "y" ] || [ "${yn}" = "Y" ]
        return $?
    fi
    return 0
}

echo "==> Pacer release-secrets setup for ${REPO}"
echo
echo "    Currently configured:"
gh secret list --repo "${REPO}" | awk '{print "        " $1}'
echo

# 1. Developer ID Application .p12
echo "----- 1/3: Developer ID Application certificate -----"
echo "If you haven't exported the .p12 yet:"
echo "  - Open Keychain Access"
echo "  - Find: Developer ID Application: Eric Andrechek (YZXWMJ5VBY)"
echo "  - Right-click → Export → save as a .p12 with a password you'll remember"
echo
if confirm_overwrite MACOS_CERTIFICATE; then
    P12_PATH="$(prompt_path 'Path to .p12 file')"
    read -r -s -p "Password used to export the .p12: " P12_PW
    echo
    base64 -i "${P12_PATH}" | gh secret set MACOS_CERTIFICATE --repo "${REPO}"
    printf '%s' "${P12_PW}" | gh secret set MACOS_CERTIFICATE_PASSWORD --repo "${REPO}"
    echo "  -> MACOS_CERTIFICATE + MACOS_CERTIFICATE_PASSWORD set"
fi

# 2. App Store Connect API key
echo
echo "----- 2/3: App Store Connect API key (notarization) -----"
echo "If you haven't created the key yet:"
echo "  - App Store Connect → Users and Access → Integrations → App Store Connect API"
echo "  - New key, role: Developer"
echo "  - Download the .p8 file (one-time download), note the Key ID and Issuer ID"
echo
if confirm_overwrite NOTARY_KEY_P8; then
    P8_PATH="$(prompt_path 'Path to AuthKey_<id>.p8')"
    cat "${P8_PATH}" | gh secret set NOTARY_KEY_P8 --repo "${REPO}"
    echo "  -> NOTARY_KEY_P8 set"
fi
if confirm_overwrite NOTARY_KEY_ID; then
    read -r -p "App Store Connect Key ID (10 chars, e.g. ABC123XYZ4): " KEY_ID
    printf '%s' "${KEY_ID}" | gh secret set NOTARY_KEY_ID --repo "${REPO}"
fi
if confirm_overwrite NOTARY_ISSUER_ID; then
    read -r -p "App Store Connect Issuer ID (UUID): " ISSUER_ID
    printf '%s' "${ISSUER_ID}" | gh secret set NOTARY_ISSUER_ID --repo "${REPO}"
fi

# 3. Final check
echo
echo "----- 3/3: Done -----"
echo "Configured secrets:"
gh secret list --repo "${REPO}" | awk '{print "  " $1}'
echo
echo "Smoke-test the release workflow without publishing:"
echo "  gh workflow run release.yml --repo ${REPO} -f dry_run=true"
