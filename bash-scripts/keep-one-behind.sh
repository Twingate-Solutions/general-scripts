#!/usr/bin/env bash
#
# keep-one-behind.sh — Keep an apt package one version behind the latest
# Usage:
#   keep-one-behind.sh <package> [--apply] [--allow-downgrades]
#
# Behavior:
#   - Prints whether updates exist compared to the installed version
#   - Prints latest and second-latest versions available in your repos
#   - If --apply is passed and installed < second-latest, installs that exact version
#
# Notes:
#   - Handles Debian/Ubuntu version semantics (epochs, ~, etc.) by delegating
#     all comparisons to `dpkg --compare-versions`.
#   - Requires the target version to be present in your configured repos.
#   - Use --allow-downgrades if you ever need to step *down* to the second-latest.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <package> [--apply] [--allow-downgrades]" >&2
  exit 2
fi

PKG="$1"; shift || true
DO_APPLY=0
ALLOW_DOWNGRADES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) DO_APPLY=1 ;;
    --allow-downgrades) ALLOW_DOWNGRADES=1 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# Helper: compare versions using dpkg semantics
ver_lt() { dpkg --compare-versions "$1" lt "$2"; }
ver_gt() { dpkg --compare-versions "$1" gt "$2"; }
ver_eq() { dpkg --compare-versions "$1" eq "$2"; }

# Refresh package lists quietly
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# Installed version (may be empty if not installed)
INSTALLED="$(dpkg-query -W -f='${Version}\n' "$PKG" 2>/dev/null || true)"
INSTALLED="${INSTALLED//$'\n'/}"

# Collect available versions. `apt-cache madison` lists newest first (by policy).
# De-duplicate because multiple repos can advertise the same version.
mapfile -t VERSIONS < <(apt-cache madison "$PKG" | awk '{print $3}' | awk '!seen[$0]++')

if [[ ${#VERSIONS[@]} -eq 0 ]]; then
  echo "No available versions for '$PKG' were found in your configured repositories."
  exit 1
fi

LATEST="${VERSIONS[0]}"
SECOND=""
if [[ ${#VERSIONS[@]} -ge 2 ]]; then
  SECOND="${VERSIONS[1]}"
fi

echo "Package: $PKG"
echo "Installed: ${INSTALLED:-<not installed>}"
echo "Latest available: $LATEST"
if [[ -n "$SECOND" ]]; then
  echo "Second-latest available: $SECOND"
else
  echo "Second-latest available: <none — only one version is in the repos>"
fi
echo

# (1) Are there updates compared to the current version?
if [[ -z "$INSTALLED" ]]; then
  echo "Update status: Not installed. (An install would bring you to second-latest if you --apply.)"
else
  if ver_lt "$INSTALLED" "$LATEST"; then
    echo "Update status: Updates exist (installed < latest)."
  elif ver_eq "$INSTALLED" "$LATEST"; then
    echo "Update status: You're on the latest."
  else
    echo "Update status: Installed is newer than the repo latest (local/backport?)."
  fi
fi

# (2) Report the last and second-to-last explicitly (done above).
#     Nothing else to do here besides printing, which we already did.

# (3) If current < second-to-last, install that specific version (only with --apply)
if [[ -n "$SECOND" ]]; then
  SHOULD_INSTALL=0

  if [[ -z "$INSTALLED" ]]; then
    # Not installed: bring it to SECOND if applying
    SHOULD_INSTALL=1
    echo "Action: Package not installed — target will be second-latest ($SECOND)."
  else
    if ver_lt "$INSTALLED" "$SECOND"; then
      SHOULD_INSTALL=1
      echo "Action: Installed ($INSTALLED) is older than second-latest ($SECOND) — eligible to install second-latest."
    elif ver_eq "$INSTALLED" "$SECOND"; then
      echo "Action: Already on second-latest; no change."
    elif ver_eq "$INSTALLED" "$LATEST"; then
      echo "Action: On latest; staying one-behind implies a downgrade to $SECOND."
      if [[ $ALLOW_DOWNGRADES -eq 1 ]]; then
        SHOULD_INSTALL=1
      else
        echo "        (Pass --allow-downgrades if you want to step back to second-latest automatically.)"
      fi
    else
      # Installed newer than both latest and second-latest (unusual)
      echo "Action: Installed version ($INSTALLED) is newer than repo second-latest ($SECOND). No change."
    fi
  fi

  if [[ $DO_APPLY -eq 1 && $SHOULD_INSTALL -eq 1 ]]; then
    echo
    echo "=== Applying change: Installing exact version '$SECOND' ==="
    # Make sure apt won't prompt and allow optional downgrades if requested
    APT_ARGS=(-y)
    if [[ $ALLOW_DOWNGRADES -eq 1 ]]; then
      APT_ARGS+=(--allow-downgrades)
    fi
    apt-get install "${APT_ARGS[@]}" "$PKG=$SECOND"
    echo "Done."
  elif [[ $DO_APPLY -eq 0 && $SHOULD_INSTALL -eq 1 ]]; then
    echo "Dry-run: Would run -> apt-get install -y$([[ $ALLOW_DOWNGRADES -eq 1 ]] && echo ' --allow-downgrades') '$PKG=$SECOND'"
  fi
else
  echo
  echo "Only one version appears in your repos; can't enforce 'one behind latest'."
fi
