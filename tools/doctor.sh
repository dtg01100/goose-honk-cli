#!/usr/bin/env bash
# tools/doctor.sh — verify that honk's runtime requirements are available.
#
# Exit 0 if everything is present; exit 1 with a list of missing items
# otherwise. Designed to be invoked by `make doctor` after a fresh
# checkout, but safe to run directly.

set -euo pipefail

missing=()

have_cmd() {
    local label="$1"; shift
    if command -v "$1" >/dev/null 2>&1; then
        local version
        version=$("$@" 2>/dev/null | head -1 || true)
        if [[ -n "$version" ]]; then
            printf '  \033[32m✓\033[0m %-22s %s\n' "$label" "$version"
        else
            printf '  \033[32m✓\033[0m %s\n' "$label"
        fi
    else
        printf '  \033[31m✗\033[0m %s (not found on PATH)\n' "$label"
        missing+=("$label")
    fi
}

have_version_ge() {
    local label="$1" current="$2" min_major="$3" min_minor="$4"
    local major minor
    if [[ "$current" =~ ([0-9]+)\.([0-9]+) ]]; then
        major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"
    else
        printf '  \033[33m?\033[0m %-22s could not parse version: %s\n' "$label" "$current"
        return 0
    fi
    if (( major > min_major )) || (( major == min_major && minor >= min_minor )); then
        printf '  \033[32m✓\033[0m %-22s %s (>= %d.%d)\n' "$label" "$current" "$min_major" "$min_minor"
    else
        printf '  \033[31m✗\033[0m %-22s %s (need >= %d.%d)\n' "$label" "$current" "$min_major" "$min_minor"
        missing+=("$label < $min_major.$min_minor")
    fi
}

printf '\n\033[1mhonk doctor\033[0m — checking runtime requirements\n\n'

# bash — required, must be >= 4
if have_cmd bash bash --version | head -1 | grep -q -- 'bash'; then
    bash_ver=$(bash --version | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    have_version_ge bash "$bash_ver" 4 0
else
    printf '  \033[31m✗\033[0m bash (not found on PATH)\n'
    missing+=("bash")
fi

# fzf — required for the interactive picker, >= 0.40
if command -v fzf >/dev/null 2>&1; then
    fzf_ver=$(fzf --version | awk '{print $1}')
    have_version_ge fzf "$fzf_ver" 0 40
else
    printf '  \033[31m✗\033[0m fzf (not found on PATH)\n'
    missing+=("fzf")
fi

have_cmd jq jq --version
have_cmd goose goose --version

# readlink -f (or equivalent) — used by the picker cache and install.sh
if readlink -f / >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m readlink -f\n'
else
    printf '  \033[33m?\033[0m readlink -f — your readlink may not support -f (BSD/macOS); install coreutils if needed\n'
fi

# Optional: shellcheck (only required for `make check`, not for runtime)
if command -v shellcheck >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m shellcheck          %s (optional, for "make check")\n' \
        "$(shellcheck --version | awk '/^version:/ {print $2}')"
else
    printf '  \033[33m-\033[0m shellcheck          not installed (optional, needed only for "make check")\n'
fi

echo
if (( ${#missing[@]} > 0 )); then
    printf '\033[31mmissing:%s\033[0m\n' "${missing[*]}"
    echo "Install the items above and re-run \`make doctor\`."
    exit 1
fi

printf '\033[32mall runtime requirements satisfied\033[0m\n'
exit 0
