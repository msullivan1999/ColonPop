#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo 'Usage: check-upgrade.sh PREVIOUS.app UPDATE.app' >&2
    exit 2
fi
previous="$1"
update="$2"

# macOS can remember a permission grant using the old app's designated requirement.
codesign --verify --strict --all-architectures "$previous"
details="$(codesign --display --requirements - "$previous" 2>&1)"
requirement="$(sed -nE 's/^#? *designated => //p' <<< "$details")"
if [[ -z "$requirement" ]]; then
    echo "Could not read the signing requirement from $previous." >&2
    exit 1
fi

if ! codesign --verify --strict --all-architectures --test-requirement "=$requirement" "$update"; then
    echo "Update failed the previous app’s signing requirement. Existing Accessibility approval cannot be assumed." >&2
    exit 1
fi
echo 'Update satisfies the previous app’s signing requirement.'
