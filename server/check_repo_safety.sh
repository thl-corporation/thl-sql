#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"
cd "${ROOT_DIR}"

echo "Running repository safety checks..."

blocked_files="$(
    git ls-files | awk '
    {
        file = tolower($0)
        if (file ~ /(^|\/)\.env($|[^\/]*$)/) {
            if (file ~ /\.example$/ || file ~ /\.sample$/) next
            print $0
            next
        }
        if (
            file ~ /(^|\/)ssh_keys\// ||
            file ~ /\.pem$/ ||
            file ~ /\.key$/ ||
            file ~ /\.p12$/ ||
            file ~ /\.pfx$/ ||
            file ~ /(^|\/)id_rsa$/ ||
            file ~ /(^|\/)id_ed25519$/ ||
            file ~ /ssh_keys.*\.zip$/
        ) {
            print $0
        }
    }'
)"
if [ -n "${blocked_files}" ]; then
    echo "ERROR: sensitive files are tracked:"
    echo "${blocked_files}"
    exit 1
fi

echo "OK: no sensitive tracked files detected."
