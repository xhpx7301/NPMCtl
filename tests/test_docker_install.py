"""Installation regression tests. All Docker/package/service/network calls are stubs."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "npmctl.sh"
STUBS = r'''
engine_installed=${ENGINE_INSTALLED:-0}
daemon_running=${DAEMON_RUNNING:-0}
confirm_action() { [[ "${CONFIRM:-yes}" == yes ]]; }
command() {
  if [[ "$1" == -v && "$2" == docker && "$engine_installed" == 0 ]]; then return 1; fi
  builtin command "$@"
}
docker() {
  printf 'docker %s\n' "$*" >>"$CALL_LOG"
  if [[ "$1" == info ]]; then [[ "$daemon_running" == 1 ]]; return; fi
  if [[ "$1" == compose && "$2" == version ]]; then
    [[ -f "$COMPOSE_MARKER" ]] || return 1
    printf 'v2.40.3\n'; return 0
  fi
  return 1
}
apt-cache() {
  if [[ " $AVAILABLE_PACKAGES " == *" $2 "* ]]; then
    printf '  Candidate: %s\n' "${COMPOSE_CANDIDATE_VERSION:-2.40.3}"
  else
    printf '  Candidate: (none)\n'
  fi
}
apt-get() {
  printf 'apt-get %s\n' "$*" >>"$CALL_LOG"
  [[ "$1" != update || "${FAIL_UPDATE:-0}" == 0 ]] || return 1
  if [[ "$*" == *'install -y docker.io'* || "$*" == *'install -y docker-ce '* ]]; then
    [[ "${FAIL_ENGINE:-0}" == 0 ]] || return 1
    engine_installed=1
  fi
  for package in $READY_PACKAGES; do
    if [[ " $* " == *" $package "* ]]; then : >"$COMPOSE_MARKER"; fi
  done
  return 0
}
dpkg() {
  if [[ "$1" == --print-architecture ]]; then printf 'arm64\n'
  else /usr/bin/dpkg "$@"; fi
}
systemctl() {
  printf 'systemctl %s\n' "$*" >>"$CALL_LOG"
  [[ "${FAIL_SERVICE:-0}" == 0 ]] || return 1
  daemon_running=1
}
install_compose_plugin_release() {
  printf 'verified-compose-plugin %s\n' "$1" >>"$CALL_LOG"
  [[ "${FAIL_RELEASE:-0}" == 0 ]] || { error '官方 SHA-256 校验失败，已停止安装。'; return 1; }
  : >"$COMPOSE_MARKER"
}
'''


class DockerInstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        source = SOURCE.read_text().split('if [[ $# -eq 1 && ( "$1" == --help')[0]
        # Even the real download/install helper can only write inside this test.
        source = source.replace('/usr/local/lib/docker/cli-plugins', str(self.root / 'plugins'))
        self.library = self.root / "library.sh"
        self.library.write_text(source)
        self.log = self.root / "calls.log"
        self.marker = self.root / "compose-ready"

    def tearDown(self):
        self.temporary.cleanup()

    def run_install(self, **settings):
        script = 'source "$LIBRARY"\n' + STUBS + '\ninstall_docker\n'
        env = {
            **os.environ, "LIBRARY": str(self.library), "CALL_LOG": str(self.log),
            "COMPOSE_MARKER": str(self.marker), "AVAILABLE_PACKAGES": "docker.io",
            "READY_PACKAGES": "", **{k: str(v) for k, v in settings.items()},
        }
        return subprocess.run(["bash"], input=script, env=env, text=True, capture_output=True)

    def test_debian13_arm64_missing_plugin_package_uses_verified_release(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.log.read_text()
        self.assertIn("apt-get install -y docker.io\n", calls)
        self.assertNotIn("apt-get install -y docker.io docker-compose-plugin", calls)
        self.assertIn("verified-compose-plugin arm64", calls)
        self.assertIn("systemctl enable --now docker", calls)
        self.assertIn("已就绪", result.stdout)

    def test_debian13_modern_docker_compose_package_is_accepted(self):
        result = self.run_install(AVAILABLE_PACKAGES="docker.io docker-compose", READY_PACKAGES="docker-compose")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("apt-get install -y docker-compose\n", self.log.read_text())
        self.assertNotIn("verified-compose-plugin", self.log.read_text())

    def test_old_python_compose_is_skipped(self):
        result = self.run_install(AVAILABLE_PACKAGES="docker.io docker-compose", COMPOSE_CANDIDATE_VERSION="1:1.29.2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("apt-get install -y docker-compose\n", self.log.read_text())
        self.assertIn("verified-compose-plugin", self.log.read_text())

    def test_existing_engine_only_adds_compose_without_restarting_daemon(self):
        result = self.run_install(ENGINE_INSTALLED=1, DAEMON_RUNNING=1)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.log.read_text()
        self.assertNotIn("install -y docker.io", calls)
        self.assertNotIn("systemctl", calls)
        self.assertIn("verified-compose-plugin arm64", calls)

    def test_healthy_installation_does_not_touch_packages_or_services(self):
        self.marker.touch()
        result = self.run_install(ENGINE_INSTALLED=1, DAEMON_RUNNING=1)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("apt-get", self.log.read_text())
        self.assertNotIn("systemctl", self.log.read_text())

    def test_stopped_daemon_with_compose_only_starts_service(self):
        self.marker.touch()
        result = self.run_install(ENGINE_INSTALLED=1)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("apt-get", self.log.read_text())
        self.assertIn("systemctl enable --now docker", self.log.read_text())

    def test_existing_official_repository_packages_are_used(self):
        result = self.run_install(AVAILABLE_PACKAGES="docker-ce docker-ce-cli docker-compose-plugin", READY_PACKAGES="docker-compose-plugin")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("apt-get install -y docker-ce docker-ce-cli containerd.io", self.log.read_text())
        self.assertNotIn("verified-compose-plugin", self.log.read_text())

    def test_release_verification_failure_never_starts_daemon(self):
        result = self.run_install(FAIL_RELEASE=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256", result.stderr)
        self.assertNotIn("systemctl", self.log.read_text())

    def test_repository_failure_stops_before_installing_packages(self):
        result = self.run_install(FAIL_UPDATE=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("apt-get install", self.log.read_text())

    def test_real_release_helper_validates_checksum_before_execution(self):
        # A mock HTTPS client emits a version-pinned release and a harmless
        # executable fixture. A checksum mismatch must never execute/install it.
        downloader = r'''
curl() {
  local url='' output='' arg
  while (($#)); do
    case "$1" in -o) output="$2"; shift 2;; https://*) url="$1"; shift;; *) shift;; esac
  done
  case "$url" in
    */releases/latest) printf '{"tag_name":"v2.40.3"}\n' >"$output";;
    *.sha256)
      if [[ "$BAD_CHECKSUM" == 1 ]]; then printf '%064d *docker-compose-linux-aarch64\n' 0 >"$output"
      else sha256sum "${output%.sha256}" >"$output"; fi;;
    */v2.40.3/docker-compose-linux-aarch64)
      printf '#!/bin/sh\nprintf "v2.40.3\\n"\ntouch "$EXECUTED"\n' >"$output";;
    *) return 1;;
  esac
}
install_compose_plugin_release arm64
'''
        for bad in ("1", "0"):
            executed = self.root / "executed"
            result = subprocess.run(["bash"], input='source "$LIBRARY"\n' + downloader,
                env={**os.environ, "LIBRARY": str(self.library), "BAD_CHECKSUM": bad, "EXECUTED": str(executed)},
                text=True, capture_output=True)
            if bad == "1":
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(executed.exists())
                self.assertFalse((self.root / "plugins/docker-compose").exists())
            else:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(executed.exists())
                self.assertTrue((self.root / "plugins/docker-compose").exists())


if __name__ == "__main__":
    unittest.main()
