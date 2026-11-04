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
elif [[ "$1" == setting && "$2" == -listenIP ]]; then
  printf '%s\n' "$3" >"$XUI_STATE"
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

    def apply(self, target, **settings):
        script = 'source "$LIBRARY"\n' + STUBS + f'\napply_xui_listener_address 38787 "$XUI_BINARY" {target}\n'
        return subprocess.run(["bash", "-c", script], env={
            **os.environ,
            "LIBRARY": str(self.library),
            "XUI_BINARY": str(self.binary),
            "XUI_STATE": str(self.state),
            "CALL_LOG": str(self.calls),
            "RESTART_COUNT": "0",
            **{key: str(value) for key, value in settings.items()},
        }, text=True, capture_output=True)

    def test_updates_listen_ip_through_xui_cli_and_restarts_service(self):
        result = self.apply('"172.18.0.1"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.state.read_text().strip(), "172.18.0.1")
        calls = self.calls.read_text()
        self.assertIn("restart x-ui.service", calls)
        self.assertIn("is-active --quiet x-ui.service", calls)

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
