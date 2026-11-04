"""Isolated regressions for the 3X-UI listener adapter."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "npmctl.sh"
STUBS = r'''
systemctl() {
  printf '%s\n' "$*" >>"$CALL_LOG"
  if [[ "$1" == restart ]]; then
    RESTART_COUNT=$((RESTART_COUNT + 1))
    [[ "$RESTART_COUNT" != 1 || "${FAIL_FIRST_RESTART:-0}" != 1 ]]
    return
  fi
  [[ "$1" == is-active ]]
}
generic_listener_is_listening_on() {
  LISTENER_CHECKS=$((LISTENER_CHECKS + 1))
  [[ "$LISTENER_CHECKS" -gt "${STARTUP_DELAY_CHECKS:-0}" ]] || return 1
  [[ "$2" != "${FAIL_BIND_ADDRESS:-}" ]] || return 1
  [[ "$(cat "$XUI_STATE")" == "$2" ]]
}
show_local_listener() { :; }
sleep() { :; }
'''


class XuiListenerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        source = SOURCE.read_text().split('if [[ $# -eq 1 && ( "$1" == --help')[0]
        source = source.replace('/usr/local/lib/npmctl', str(self.root / "manager"))
        self.library = self.root / "library.sh"
        self.library.write_text(source)
        self.binary = self.root / "x-ui"
        self.binary.write_text(r'''#!/usr/bin/env bash
if [[ "$1" == setting && "$2" == -getListen ]]; then
  printf 'listenIP: %s\n' "$(cat "$XUI_STATE")"
elif [[ "$1" == setting && "$2" == -show ]]; then
  printf 'username: private-user\npassword: private-password\nport: %s\n' "${XUI_PANEL_PORT:-38787}"
  if [[ -n "${XUI_CONTEXT_LOG:-}" ]]; then
    printf '%s|%s|%s\n' "$XUI_DB_FOLDER" "$PWD" "${CALLER_ONLY:-unset}" >"$XUI_CONTEXT_LOG"
  fi
elif [[ "$1" == setting && "$2" == -listenIP ]]; then
  printf '%s\n' "$3" >"$XUI_STATE"
  [[ "$3" != "${FAIL_CLI_ADDRESS:-}" ]] || exit 1
else
  exit 2
fi
''')
        self.binary.chmod(0o755)
        self.state = self.root / "listen-ip"
        self.state.write_text("127.0.0.1\n")
        self.calls = self.root / "calls.log"

    def tearDown(self):
        self.temporary.cleanup()

    def bash(self, script, **settings):
        return subprocess.run(["bash", "-c", script], env={
            **os.environ,
            "LIBRARY": str(self.library),
            "XUI_BINARY": str(self.binary),
            "XUI_STATE": str(self.state),
            "CALL_LOG": str(self.calls),
            "RESTART_COUNT": "0",
            "LISTENER_CHECKS": "0",
            **{key: str(value) for key, value in settings.items()},
        }, text=True, capture_output=True)

    def apply(self, target, **settings):
        script = 'source "$LIBRARY"\n' + STUBS + f'\napply_xui_listener_address 38787 "$XUI_BINARY" {target}\n'
        return self.bash(script, **settings)

    def test_updates_listen_ip_through_xui_cli_and_restarts_service(self):
        result = self.apply('"172.18.0.1"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.state.read_text().strip(), "172.18.0.1")
        calls = self.calls.read_text()
        self.assertIn("restart x-ui.service", calls)
        self.assertIn("is-active --quiet x-ui.service", calls)
        self.assertNotIn("private-password", result.stdout + result.stderr)

    def test_waits_for_service_startup_after_restart(self):
        result = self.apply('"172.18.0.1"', STARTUP_DELAY_CHECKS=3)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertGreaterEqual(self.calls.read_text().count("is-active"), 4)

    def test_failed_binding_restores_previous_address(self):
        result = self.apply('"172.18.0.1"', FAIL_BIND_ADDRESS="172.18.0.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state.read_text().strip(), "127.0.0.1")
        self.assertEqual(self.calls.read_text().count("restart x-ui.service"), 2)

    def test_cli_failure_after_writing_setting_also_rolls_back(self):
        result = self.apply('"172.18.0.1"', FAIL_CLI_ADDRESS="172.18.0.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state.read_text().strip(), "127.0.0.1")

    def test_subscription_port_is_rejected_before_changes(self):
        result = self.apply('"172.18.0.1"', XUI_PANEL_PORT=2096)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state.read_text().strip(), "127.0.0.1")
        self.assertFalse(self.calls.exists())

    def test_unchanged_ip_does_not_restart(self):
        result = self.apply('"127.0.0.1"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.calls.exists())

    def test_cli_uses_service_working_directory_and_environment(self):
        script = r'''
source "$LIBRARY"
XUI_SERVICE_WORKDIR="$CONTEXT_DIR"
XUI_SERVICE_ENV=("PATH=$PATH" "XUI_STATE=$XUI_STATE" "XUI_DB_FOLDER=custom/database"
  "XUI_CONTEXT_LOG=$CONTEXT_LOG")
xui_panel_port "$XUI_BINARY"
'''
        context = self.root / "custom context"
        context.mkdir()
        context_log = self.root / "context.log"
        result = self.bash(script, CONTEXT_DIR=context, CONTEXT_LOG=context_log, CALLER_ONLY="wrong-context")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip(), "38787")
        self.assertEqual(context_log.read_text().strip(), f"custom/database|{context}|unset")

    def test_assistant_routes_xui_to_adapter_instead_of_text_replacement(self):
        result = self.bash(r'''
source "$LIBRARY"
show_all_local_listeners() { :; }
local_tcp_listener_details() {
  printf 'LISTEN 0 128 127.0.0.1:38787 0.0.0.0:* users:(("x-ui",pid=1234,fd=5))\n'
}
docker_mapping_for_host_port() { :; }
show_native_listener_launch_info() { :; }
systemd_unit_for_pid() { printf 'x-ui.service\n'; }
manage_generic_systemd_listener() { exit 9; }
manage_xui_systemd_listener() { printf 'xui port=%s unit=%s\n' "$1" "$3"; }
local_service_listener_assistant <<<38787
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("xui port=38787 unit=x-ui.service", result.stdout)

    def test_failed_restart_restores_previous_address(self):
        result = self.apply('"172.18.0.1"', FAIL_FIRST_RESTART=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state.read_text().strip(), "127.0.0.1")
        self.assertEqual(self.calls.read_text().count("restart x-ui.service"), 2)
        self.assertIn("恢复原监听地址", result.stderr)

    def test_rejects_invalid_bind_address_without_changing_setting(self):
        result = self.apply('"not-an-ip"')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state.read_text().strip(), "127.0.0.1")
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
