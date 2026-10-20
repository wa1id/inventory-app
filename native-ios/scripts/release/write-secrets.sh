#!/usr/bin/env bash
# Writes native-ios/Config/Secrets.xcconfig (gitignored) from the EAS production environment, on
# this Linux machine, without printing a value (DECISIONS U1, docs/RELEASE.md "App keys"):
#
#   INV_RECOGNITION_KEY  ← eas env:get production --variable-name EXPO_PUBLIC_RECOGNITION_KEY
#   INV_SYNC_KEY         ← eas env:get production --variable-name EXPO_PUBLIC_SYNC_KEY
#
#   scripts/release/write-secrets.sh                write Config/Secrets.xcconfig
#   scripts/release/write-secrets.sh --out <file>   write somewhere else (for trying it out)
#
# It runs `eas` from the repository root (where app.json names the EAS project; you must be
# logged in), or `npx --yes eas-cli` when `eas` is not installed; EAS_BIN overrides the command.
# Each value is parsed from the `NAME=value` line of `eas env:get --format short` and refused when
# it is empty, masked (`*****`) or holds `//`, `$`, a quote or white space, any of which an
# xcconfig would cut or expand. The file is written with mode 600, and only "set" is reported.
# Never set -x here.
set -euo pipefail
set +x

NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_DIR="$(cd "$NATIVE_DIR/.." && pwd)"
OUT="$NATIVE_DIR/Config/Secrets.xcconfig"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?--out needs a file}"; shift 2 ;;
    *) echo "usage: $0 [--out <file>]" >&2; exit 2 ;;
  esac
done

fail() { echo "[secrets] $*" >&2; exit 1; }

if [ -n "${EAS_BIN:-}" ]; then
  read -ra EAS <<<"$EAS_BIN"
elif command -v eas >/dev/null 2>&1; then
  EAS=(eas)
else
  EAS=(npx --yes eas-cli)
fi

# Prints the value of one EAS production variable on stdout (captured by the caller, never shown).
fetch() {
  local name="$1" output status=0 errors
  errors="$(mktemp)"
  output="$(cd "$REPO_DIR" && NO_COLOR=1 FORCE_COLOR=0 "${EAS[@]}" env:get production \
    --variable-name "$name" --scope project --format short --non-interactive 2>"$errors")" || status=$?
  if [ "$status" -ne 0 ]; then
    # eas reports problems (not logged in, unknown or secret variable) on stderr, without values.
    sed 's/^/[secrets]   /' "$errors" >&2
    rm -f "$errors"
    fail "eas env:get failed for $name (exit $status)"
  fi
  # The `NAME=value` line, with any colour codes removed; everything after the first `=`.
  local value
  value="$(printf '%s\n' "$output" | sed 's/\x1b\[[0-9;]*m//g' | awk -v k="$name" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }')"
  # A variable eas cannot find is reported on stderr with exit 0 (`Variable with name … not
  # found`); show that reason, which never holds a value (values only go to stdout).
  [ -n "$value" ] || sed 's/^/[secrets]   /' "$errors" >&2
  rm -f "$errors"
  printf '%s' "$value"
}

# Refuses a value an xcconfig would mangle or that is not a real key. Prints nothing about it.
validate() {
  local name="$1" value="$2"
  [ -n "$value" ] || fail "$name: no value in the eas output (is it set for production?)"
  # The mask first: eas prints `***** (This is a … env variable …)` in place of a value it
  # withholds, and that text would otherwise be refused for its spaces or quote.
  case "$value" in
    \**) fail "$name: the value is masked (sensitive, secret or file in EAS); it cannot be read here" ;;
    *//*) fail "$name: the value holds '//', which an xcconfig reads as a comment" ;;
    *'$'*) fail "$name: the value holds '\$', which an xcconfig expands" ;;
    *\"* | *\'*) fail "$name: the value holds a quote" ;;
  esac
  if printf '%s' "$value" | LC_ALL=C grep -q '[[:space:][:cntrl:]]'; then
    fail "$name: the value holds white space or a control character"
  fi
}

recognition="$(fetch EXPO_PUBLIC_RECOGNITION_KEY)"
validate EXPO_PUBLIC_RECOGNITION_KEY "$recognition"
sync_key="$(fetch EXPO_PUBLIC_SYNC_KEY)"
validate EXPO_PUBLIC_SYNC_KEY "$sync_key"

mkdir -p "$(dirname "$OUT")"
umask 077
tmp="$(mktemp "$(dirname "$OUT")/.secrets.XXXXXX")"
{
  echo "// Written by scripts/release/write-secrets.sh from the EAS production environment."
  echo "// Gitignored; never commit, print or paste it."
  echo "INV_RECOGNITION_KEY = $recognition"
  echo "INV_SYNC_KEY = $sync_key"
} >"$tmp"
chmod 600 "$tmp"
mv "$tmp" "$OUT"
recognition="" sync_key=""

if [ "$OUT" = "$NATIVE_DIR/Config/Secrets.xcconfig" ]; then
  git -C "$NATIVE_DIR" check-ignore -q Config/Secrets.xcconfig || fail "Config/Secrets.xcconfig is not gitignored; delete it and fix native-ios/.gitignore"
fi
echo "[secrets] wrote $OUT: INV_RECOGNITION_KEY set, INV_SYNC_KEY set"
