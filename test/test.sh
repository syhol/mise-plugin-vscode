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
# A private state dir keeps this run's package ownership and tracked configs to
# itself: `prune` holds on to anything another trusted config still declares,
# so a stray config elsewhere would otherwise make the prune case fail.
export MISE_STATE_DIR="$WORK_DIR/state"
mkdir -p "$MISE_CONFIG_DIR" "$MISE_STATE_DIR"
: >"$MISE_GLOBAL_CONFIG_FILE"
trap 'rm -rf "$WORK_DIR"' EXIT

pass() { printf '  ok: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1" >&2; exit 1; }

write_config() { # write_config <version-or-empty>
  if [ -n "${1:-}" ]; then
    printf '[bootstrap.packages]\n"vscode:%s" = "%s"\n' "$EXT" "$1" >"$WORK_DIR/mise.toml"
  else
    printf '[bootstrap.packages]\n' >"$WORK_DIR/mise.toml"
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

echo "==> a bad id in the batch does not stop the good ones"
printf '[bootstrap.packages]\n"vscode:%s" = "latest"\n"vscode:this.definitely-does-not-exist" = "latest"\n' "$EXT" >"$WORK_DIR/mise.toml"
mise trust --quiet "$WORK_DIR/mise.toml" >/dev/null
mise -C "$WORK_DIR" bootstrap packages apply -y >/dev/null 2>&1 && fail "expected the bad id to fail the run"
"${MISE_VSCODE_CLI:-code}" --extensions-dir "$MISE_VSCODE_EXTENSIONS_DIR" --list-extensions | grep -qi "$EXT" || fail "the good extension was skipped"
pass "partial failure"

echo "==> a transient marketplace error is retried"
STUB="$WORK_DIR/flaky-code"
cat >"$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
# Fails with a 503 on the first two install attempts, then succeeds.
case " $* " in
  *--install-extension*)
    n=$(cat "$RETRY_STATE" 2>/dev/null || echo 0)
    n=$((n + 1)); echo "$n" >"$RETRY_STATE"
    if [ "$n" -le 2 ]; then
      echo "(node:1) [DEP0169] DeprecationWarning: noise" >&2
      echo "Error while installing extensions: Server returned 503" >&2
      exit 1
    fi
    exit 0 ;;
esac
exit 0
STUB_EOF
chmod +x "$STUB"
printf '[bootstrap.packages]\n"vscode:some.extension" = "latest"\n' >"$WORK_DIR/mise.toml"
mise trust --quiet "$WORK_DIR/mise.toml" >/dev/null
RETRY_STATE="$WORK_DIR/attempts" MISE_VSCODE_CLI="$STUB" \
  mise -C "$WORK_DIR" bootstrap packages apply -y >/dev/null 2>&1 || fail "retries did not recover from a 503"
[ "$(cat "$WORK_DIR/attempts")" = "3" ] || fail "expected 3 attempts, got $(cat "$WORK_DIR/attempts")"
pass "transient retry"

echo "all tests passed"
