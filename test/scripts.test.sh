#!/usr/bin/env bash
# Runs scripts/mullvad-package-info (fake pacman DB via PACMAN_LOCAL_DIR)
# and scripts/mullvad-update-check (checkupdates shadowed by test/mocks),
# asserting exit codes and output shapes. Plain assertions, no framework.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures"
MOCKS="$SCRIPT_DIR/mocks"

fail_count=0
pass_count=0

ok() {
  pass_count=$((pass_count + 1))
  echo "ok - $1"
}

not_ok() {
  fail_count=$((fail_count + 1))
  echo "NOT OK - $1"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    ok "$desc"
  else
    not_ok "$desc (expected [$expected], got [$actual])"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$desc"
  else
    not_ok "$desc (expected to find [$needle])"
  fi
}

# ------------------------------------------------------------ package-info

out="$(PACMAN_LOCAL_DIR="$FIXTURES/pacman-local" "$PLUGIN_DIR/scripts/mullvad-package-info")"
code=$?
assert_eq "mullvad-package-info exits 0 against the fixture tree" "0" "$code"
assert_contains "mullvad-package-info reports mullvad-vpn" "$out" \
  "$(printf 'mullvad-vpn\t2026.4-1\t1787763238\t1786971553')"
assert_contains "mullvad-package-info reports mullvad-vpn-daemon" "$out" \
  "$(printf 'mullvad-vpn-daemon\t2026.4-1\t1787763238\t1786971553')"
line_count="$(echo "$out" | grep -c .)"
assert_eq "mullvad-package-info prints exactly 2 lines" "2" "$line_count"

empty_dir="$(mktemp -d)"
trap 'rm -rf "$empty_dir"' EXIT
out="$(PACMAN_LOCAL_DIR="$empty_dir" "$PLUGIN_DIR/scripts/mullvad-package-info")"
code=$?
assert_eq "mullvad-package-info exits 0 with no packages installed" "0" "$code"
assert_eq "mullvad-package-info prints nothing with no packages installed" "" "$out"

daemon_only="$(mktemp -d)"
cp -r "$FIXTURES/pacman-local/mullvad-vpn-daemon-2026.4-1" "$daemon_only/"
out="$(PACMAN_LOCAL_DIR="$daemon_only" "$PLUGIN_DIR/scripts/mullvad-package-info")"
line_count="$(echo "$out" | grep -c .)"
assert_eq "mullvad-package-info skips a missing package, reports only the one present" "1" "$line_count"
assert_contains "mullvad-package-info (daemon only) reports the right name" "$out" "mullvad-vpn-daemon"
rm -rf "$daemon_only"

# ----------------------------------------------------------- update-check

out="$(MOCK_MODE=updates PATH="$MOCKS:$PATH" "$PLUGIN_DIR/scripts/mullvad-update-check")"
code=$?
assert_eq "mullvad-update-check (updates) exits 0" "0" "$code"
assert_contains "mullvad-update-check (updates) reports mullvad-vpn" "$out" \
  "$(printf 'mullvad-vpn\t2026.3-1\t2026.4-1')"
assert_contains "mullvad-update-check (updates) reports mullvad-vpn-daemon" "$out" \
  "$(printf 'mullvad-vpn-daemon\t2026.3-1\t2026.4-1')"
line_count="$(echo "$out" | grep -c .)"
assert_eq "mullvad-update-check (updates) filters out the non-Mullvad package" "2" "$line_count"

out="$(MOCK_MODE=none PATH="$MOCKS:$PATH" "$PLUGIN_DIR/scripts/mullvad-update-check")"
code=$?
assert_eq "mullvad-update-check (none) exits 0" "0" "$code"
assert_eq "mullvad-update-check (none) prints nothing" "" "$out"

out="$(MOCK_MODE=offline PATH="$MOCKS:$PATH" "$PLUGIN_DIR/scripts/mullvad-update-check")"
code=$?
assert_eq "mullvad-update-check (offline) exits 3" "3" "$code"
assert_eq "mullvad-update-check (offline) prints nothing" "" "$out"

out="$(MOCK_MODE=hang MULLVAD_UPDATE_CHECK_TIMEOUT=1 PATH="$MOCKS:$PATH" "$PLUGIN_DIR/scripts/mullvad-update-check")"
code=$?
assert_eq "mullvad-update-check (internal timeout) exits 3" "3" "$code"
assert_eq "mullvad-update-check (internal timeout) prints nothing" "" "$out"

# ----------------------------------------------------------------- install

# scripts/install-mullvad shells out to omarchy-pkg-add / systemctl / sudo --
# all three PATH-shadowed by test/mocks so no real package/service/sudo
# command ever runs. MOCK_LOG captures every invocation in call order.

run_install() {
  local log
  log="$(mktemp)"
  MOCK_LOG="$log" PATH="$MOCKS:$PATH" "$PLUGIN_DIR/scripts/install-mullvad" \
    >/dev/null 2>&1
  echo "$?"
  cat "$log"
  rm -f "$log"
}

# The daemon is only left alone when BOTH enabled and active -- active
# alone used to be enough, which stranded an active-but-disabled daemon
# disabled forever after a reboot (never re-tested by the installer).

result="$(MOCK_DAEMON_ACTIVE=0 MOCK_DAEMON_ENABLED=0 run_install)"
code="$(echo "$result" | head -n1)"
log="$(echo "$result" | tail -n+2)"
assert_eq "install-mullvad (inactive, disabled) exits 0" "0" "$code"
assert_contains "install-mullvad (inactive, disabled) calls omarchy-pkg-add mullvad-vpn" "$log" \
  "omarchy-pkg-add mullvad-vpn"
assert_contains "install-mullvad (inactive, disabled) checks systemctl is-enabled" "$log" \
  "systemctl is-enabled --quiet mullvad-daemon"
assert_contains "install-mullvad (inactive, disabled) enables the daemon via sudo" "$log" \
  "sudo systemctl enable --now mullvad-daemon"
pkg_line="$(echo "$log" | grep -n "omarchy-pkg-add" | head -n1 | cut -d: -f1)"
sudo_line="$(echo "$log" | grep -n "^sudo " | head -n1 | cut -d: -f1)"
if [[ -n "$pkg_line" && -n "$sudo_line" && "$pkg_line" -lt "$sudo_line" ]]; then
  ok "install-mullvad (inactive, disabled) installs before enabling"
else
  not_ok "install-mullvad (inactive, disabled) installs before enabling (pkg line $pkg_line, sudo line $sudo_line)"
fi

result="$(MOCK_DAEMON_ACTIVE=1 MOCK_DAEMON_ENABLED=0 run_install)"
code="$(echo "$result" | head -n1)"
log="$(echo "$result" | tail -n+2)"
assert_eq "install-mullvad (active, disabled) exits 0" "0" "$code"
assert_contains "install-mullvad (active, disabled) enables the daemon via sudo" "$log" \
  "sudo systemctl enable --now mullvad-daemon"

result="$(MOCK_DAEMON_ACTIVE=1 MOCK_DAEMON_ENABLED=1 run_install)"
code="$(echo "$result" | head -n1)"
log="$(echo "$result" | tail -n+2)"
assert_eq "install-mullvad (active, enabled) exits 0" "0" "$code"
assert_contains "install-mullvad (active, enabled) calls omarchy-pkg-add mullvad-vpn" "$log" \
  "omarchy-pkg-add mullvad-vpn"
sudo_calls="$(echo "$log" | grep -c "^sudo " || true)"
assert_eq "install-mullvad (active, enabled) never calls sudo" "0" "$sudo_calls"

result="$(MOCK_PKG_ADD_EXIT=1 MOCK_DAEMON_ACTIVE=0 run_install)"
code="$(echo "$result" | head -n1)"
log="$(echo "$result" | tail -n+2)"
assert_eq "install-mullvad (omarchy-pkg-add fails) exits non-zero" "1" "$code"
systemctl_calls="$(echo "$log" | grep -c "^systemctl " || true)"
assert_eq "install-mullvad (omarchy-pkg-add fails) never calls systemctl" "0" "$systemctl_calls"

# ------------------------------------------------------------------- summary

echo
echo "$pass_count passed, $fail_count failed"
if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
exit 0
