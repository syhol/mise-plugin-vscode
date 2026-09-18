#!/usr/bin/env bash
# End-to-end test for the vscode package plugin.
#
# Runs against a disposable extensions directory (never your real VS Code
# profile) and a throwaway mise config, so it can install/remove for real.
# Needs the `code` CLI, network access, and mise on PATH.
#
#   ./test/test.sh [extension-id] [older-version]

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT="${1:-mikestead.dotenv}"
OLD_VERSION="${2:-1.0.0}"

WORK_DIR="$(mktemp -d)"
export MISE_VSCODE_EXTENSIONS_DIR="$WORK_DIR/extensions"
mkdir -p "$MISE_VSCODE_EXTENSIONS_DIR"
# Ignore the real global config, so the run only ever sees the test's packages
# (and `prune` isn't held back by the extension being declared somewhere else).
export MISE_CONFIG_DIR="$WORK_DIR/config"
export MISE_GLOBAL_CONFIG_FILE="$WORK_DIR/config/config.toml"
mkdir -p "$MISE_CONFIG_DIR"
: >"$MISE_GLOBAL_CONFIG_FILE"
trap 'rm -rf "$WORK_DIR"' EXIT

pass() { printf '  ok: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1" >&2; exit 1; }

write_config() { # write_config <version-or-empty>
  if [ -n "${1:-}" ]; then
    printf '[settings]\nexperimental = true\n\n[bootstrap.packages]\n"vscode:%s" = "%s"\n' "$EXT" "$1" >"$WORK_DIR/mise.toml"
  else
    printf '[settings]\nexperimental = true\n\n[bootstrap.packages]\n' >"$WORK_DIR/mise.toml"
  fi
  mise trust --quiet "$WORK_DIR/mise.toml" >/dev/null
}

status() { mise -C "$WORK_DIR" bootstrap packages status 2>&1 | grep -i "^vscode" || true; }

echo "plugin:      $PLUGIN_DIR"
echo "extension:   $EXT"
echo "extensions:  $MISE_VSCODE_EXTENSIONS_DIR"

echo "==> linking plugin"
mise plugins link -f vscode "$PLUGIN_DIR" >/dev/null

echo "==> empty batch is a no-op"
write_config ""
mise -C "$WORK_DIR" bootstrap packages status >/dev/null || fail "status failed on an empty config"
pass "status with nothing declared"

echo "==> reports a missing extension"
write_config "latest"
status | grep -q "missing" || fail "expected $EXT to be missing"
pass "missing state"

echo "==> dry run does not install"
mise -C "$WORK_DIR" bootstrap packages apply --dry-run -y 2>&1 | grep -q "would run" || fail "dry run printed no command"
status | grep -q "missing" || fail "dry run changed state"
pass "dry run"

echo "==> installs"
mise -C "$WORK_DIR" bootstrap packages apply -y >/dev/null
status | grep -q "installed" || fail "expected $EXT to be installed"
pass "install"

echo "==> status is idempotent and reports the observed version"
before="$(status)"
[ "$before" = "$(status)" ] || fail "status is not side-effect free"
pass "repeat status"

echo "==> a mismatched pin reads as missing, then installs that exact version"
write_config "$OLD_VERSION"
status | grep -q "missing" || fail "expected pin mismatch to read as missing"
mise -C "$WORK_DIR" bootstrap packages apply -y >/dev/null
status | grep -q "$OLD_VERSION" || fail "expected $EXT to be pinned at $OLD_VERSION"
pass "version pin"

echo "==> id casing does not matter"
write_config "latest"
UPPER_EXT="$EXT"
EXT="$(printf '%s' "$EXT" | tr '[:lower:]' '[:upper:]')"
write_config "latest"
status | grep -q "installed" || fail "expected case-insensitive id match"
EXT="$UPPER_EXT"
pass "case-insensitive ids"

echo "==> prune removes it only when scoped to this manager"
write_config ""
mise -C "$WORK_DIR" bootstrap packages prune -m vscode --dry-run 2>&1 | grep -q "$EXT" || fail "dry run prune listed nothing"
"${MISE_VSCODE_CLI:-code}" --extensions-dir "$MISE_VSCODE_EXTENSIONS_DIR" --list-extensions | grep -qi "$EXT" || fail "dry run prune removed it"
mise -C "$WORK_DIR" bootstrap packages prune -m vscode -y >/dev/null
"${MISE_VSCODE_CLI:-code}" --extensions-dir "$MISE_VSCODE_EXTENSIONS_DIR" --list-extensions | grep -qi "$EXT" && fail "prune did not remove it"
pass "prune"

echo "all tests passed"
