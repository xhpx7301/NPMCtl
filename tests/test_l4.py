"""Isolated Bash regressions; no Docker daemon or host deployment required."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "npmctl.sh"


class L4Tests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        source = SOURCE.read_text().split('if [[ $# -eq 1 && ( "$1" == --help')[0]
        for name, path in {
            "INSTALL_DIR": self.root / "deployment",
            "BACKUP_DIR": self.root / "backups",
        }.items():
            import re
            source = re.sub(rf'^readonly {name}=.*$', f'readonly {name}="{path}"', source, flags=re.M)
        self.library = self.root / "library.sh"
        self.library.write_text(source)

    def tearDown(self):
        self.temporary.cleanup()

    def bash(self, script, ok=True):
        result = subprocess.run(
            ["bash", "-c", 'source "$LIBRARY"\n' + script],
            env={**os.environ, "LIBRARY": str(self.library)},
            text=True, capture_output=True,
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def runtime(self):
        self.bash('''
install -d "$L4_DIR"
printf 'reality.example\t127.0.0.1\t15443\nsecond.example\t::1\t25443\n' >"$L4_ROUTES"
write_l4_runtime
''')
        return self.root / "deployment" / "l4"

    def test_validation_rejects_invalid_or_ambiguous_routes(self):
        self.bash('''
install -d "$L4_DIR"
for row in 'invalid|127.0.0.1|15443' 'valid.example|127.0.0.1|443' \
  'valid.example|127.0.0.1|8443' 'valid.example|127.0.0.1|08' \
  'valid.example|127.0.0.1|65536' 'valid.example|bad;host|15443' \
  'valid.example|127.0.0.1|15443|extra'; do
  printf '%s\n' "$row" | tr '|' '\t' >"$L4_ROUTES"
  if validate_l4_routes "$L4_ROUTES"; then exit 1; fi
done
printf 'valid.example\t127.0.0.1\t15443\nvalid.example\t::1\t25443\n' >"$L4_ROUTES"
if validate_l4_routes "$L4_ROUTES"; then exit 2; fi
printf 'valid.example\t::1\t15443\nsecond.example\txray-service\t25443\n' >"$L4_ROUTES"
validate_l4_routes "$L4_ROUTES"
''')

    def test_backend_default_follows_managed_container_network(self):
        self.bash('''
docker_network_mode_for_container() { [[ "$1" == nginx-proxy-manager ]] || exit 9; printf '%s' "$MODE"; }
docker_gateway_targets_for_container() {
  [[ "$1" == nginx-proxy-manager ]] || exit 9
  printf 'id\\tnpm\\tnpmctl_default\\t172.25.0.1\\n'
}
config_value() { printf host; }
MODE=host
[[ "$(l4_default_backend_host)" == 127.0.0.1 ]] || exit 1
MODE=npmctl_default
[[ "$(l4_default_backend_host)" == 172.25.0.1 ]] || exit 2
MODE=''
[[ "$(l4_default_backend_host)" == 127.0.0.1 ]] || exit 3
MODE=none
[[ -z "$(l4_default_backend_host)" ]] || exit 4
MODE=container:other
[[ -z "$(l4_default_backend_host)" ]] || exit 5
MODE=npmctl_default
docker_gateway_targets_for_container() {
  printf 'id\\tnpm\\tone\\t172.25.0.1\\nid\\tnpm\\ttwo\\t172.26.0.1\\n'
}
[[ -z "$(l4_default_backend_host)" ]] || exit 6
docker_gateway_targets_for_container() { :; }
[[ -z "$(l4_default_backend_host)" ]] || exit 7
MODE=''
config_value() { printf bridge; }
[[ -z "$(l4_default_backend_host)" ]] || exit 8
''')

    def test_route_prompt_accepts_default_override_and_preserves_existing_host(self):
        self.bash('''
l4_default_backend_host() { printf 172.25.0.1; }
confirm_action() { return 0; }
backup_file() { :; }
edit_l4_routes add <<'INPUT'
reality.example

15443
INPUT
[[ "$(cat "$L4_ROUTES")" == $'reality.example\\t172.25.0.1\\t15443' ]] || exit 1
l4_default_backend_host() { printf 127.0.0.1; }
edit_l4_routes edit <<'INPUT'
1



INPUT
[[ "$(cat "$L4_ROUTES")" == $'reality.example\\t172.25.0.1\\t15443' ]] || exit 2
edit_l4_routes add <<'INPUT'
other.example
xray-service
25443
INPUT
grep -Fx $'other.example\\txray-service\\t25443' "$L4_ROUTES" || exit 3
''')

    def test_conflict_with_existing_site_including_wildcard(self):
        self.bash('''
install -d "$L4_DIR" "$DATA_DIR/nginx/proxy_host"
printf 'server_name panel.example *.sites.example;\n' >"$DATA_DIR/nginx/proxy_host/1.conf"
for domain in panel.example x.sites.example; do
  printf '%s\t127.0.0.1\t15443\n' "$domain" >"$L4_ROUTES"
  if l4_check_host_conflicts "$L4_ROUTES"; then exit 1; fi
done
printf 'reality.example\t127.0.0.1\t15443\n' >"$L4_ROUTES"
l4_check_host_conflicts "$L4_ROUTES"
''')

    def test_both_network_modes_preserve_feature_config(self):
        self.runtime()
        self.bash('''
write_config bridge
sed -i 's/L4_ENABLED=0/L4_ENABLED=1/' "$CONFIG_FILE"
for mode in bridge host; do
  write_compose_file "$mode"
  [[ "$(config_value NETWORK_MODE)" == "$mode" ]] || exit 1
  l4_enabled || exit 2
  grep -F 'entrypoint: ["/bin/bash", "/opt/npmctl-l4/entrypoint.sh"]' "$COMPOSE_FILE" || exit 3
  grep -F './l4:/opt/npmctl-l4:ro' "$COMPOSE_FILE" || exit 4
  if [[ "$mode" == bridge ]]; then grep -F '"443:443"' "$COMPOSE_FILE" || exit 5
  else grep -F 'network_mode: host' "$COMPOSE_FILE" || exit 6; fi
done
''')

    def test_stream_uses_proxy_header_only_on_internal_hops(self):
        runtime = self.runtime()
        content = (runtime / "stream.conf").read_text()
        self.assertIn("default 127.0.0.1:8443;", content)
        self.assertIn("reality.example unix:/tmp/npmctl-l4-1.sock;", content)
        self.assertIn("listen unix:/tmp/npmctl-l4-1.sock proxy_protocol;", content)
        self.assertIn("proxy_pass [::1]:25443;", content)
        self.assertEqual(content.count("proxy_protocol on;"), 1)

    def prepare_fake_image(self):
        runtime = self.runtime()
        fake = self.root / "image"
        for folder in ["app/templates", "etc/nginx/conf.d", "data/nginx/proxy_host", "data/nginx/custom", "bin"]:
            (fake / folder).mkdir(parents=True, exist_ok=True)
        fixture = ('server {\n  listen 80;\n  listen 443 ssl;\n'
                   '  listen [::]:443 ssl;\n  server_name panel.example;\n}\n')
        for path in ["app/templates/_listen.conf", "etc/nginx/conf.d/default.conf", "data/nginx/proxy_host/1.conf"]:
            (fake / path).write_text(fixture)
        custom = fake / "data/nginx/custom/stream.conf"
        custom.write_text("# User configuration must survive\n")
        nginx = fake / "bin/nginx"
        nginx.write_text("#!/bin/sh\necho --with-stream_ssl_preread_module --with-http_realip_module >&2\n")
        nginx.chmod(0o755)
        script = (runtime / "entrypoint.sh").read_text()
        for path in ["/app/", "/etc/nginx/", "/data/nginx/"]:
            script = script.replace(path, str(fake) + path)
        script = script.replace("runtime=/opt/npmctl-l4", f"runtime='{runtime}'")
        script = script.replace("exec /init", "true")
        entry = fake / "entrypoint.sh"
        entry.write_text(script)
        return fake, fixture, entry

    def run_entry(self, fake, entry, enabled, ok=True):
        result = subprocess.run(["bash", str(entry)], text=True, capture_output=True, env={
            **os.environ, "L4_ENABLED": str(enabled), "PATH": f"{fake}/bin:" + os.environ["PATH"],
        })
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_listener_adaptation_is_reversible_and_idempotent(self):
        fake, fixture, entry = self.prepare_fake_image()
        conf = fake / "data/nginx/proxy_host/1.conf"
        custom = fake / "data/nginx/custom/stream.conf"
        self.run_entry(fake, entry, 1)
        first = conf.read_text()
        self.assertIn("listen 80;", first)
        self.assertIn("listen 127.0.0.1:8443 ssl proxy_protocol;", first)
        self.assertIn("listen [::1]:8443 ssl proxy_protocol;", first)
        self.assertEqual(first.count("real_ip_header proxy_protocol;"), 1)
        self.run_entry(fake, entry, 1)
        self.assertEqual(conf.read_text(), first)
        self.assertEqual(custom.read_text().count("# NPMCTL L4"), 1)
        self.run_entry(fake, entry, 0)
        self.assertEqual(conf.read_text(), fixture)
        self.assertIn("# User configuration must survive", custom.read_text())
        self.assertNotIn("# NPMCTL L4", custom.read_text())
        self.assertFalse((fake / "data/nginx/custom/npmctl-l4.conf").exists())
        self.run_entry(fake, entry, 1)
        self.assertEqual(conf.read_text(), first)

    def test_incompatible_image_fails_before_persistent_edits(self):
        fake, fixture, entry = self.prepare_fake_image()
        (fake / "app/templates/_listen.conf").write_text("unsupported future format\n")
        result = self.run_entry(fake, entry, 1, ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((fake / "data/nginx/proxy_host/1.conf").read_text(), fixture)

    def test_failed_application_restores_files_and_previous_image(self):
        self.bash('''
write_compose_file bridge
install -d "$DATA_DIR/nginx/proxy_host"
printf 'original site\n' >"$DATA_DIR/nginx/proxy_host/1.conf"
printf 'reality.example\t127.0.0.1\t15443\n' >"$INSTALL_DIR/candidate"
cp "$COMPOSE_FILE" "$INSTALL_DIR/original-compose"
cp "$CONFIG_FILE" "$INSTALL_DIR/original-env"
require_docker() { return 0; }
docker() {
  printf '%s\n' "$*" >>"$INSTALL_DIR/docker-calls"
  if [[ "$1" == inspect ]]; then printf 'sha256:previous-image\n'; fi
}
l4_wait_ready() { ! l4_enabled; }
if l4_apply "$INSTALL_DIR/candidate" 1; then exit 1; fi
cmp "$COMPOSE_FILE" "$INSTALL_DIR/original-compose" || exit 2
cmp "$CONFIG_FILE" "$INSTALL_DIR/original-env" || exit 3
[[ ! -e "$L4_DIR" ]] || exit 4
[[ "$(cat "$DATA_DIR/nginx/proxy_host/1.conf")" == 'original site' ]] || exit 5
grep -F 'image: sha256:previous-image' "$BACKUP_DIR"/l4-*/rollback-image.yml || exit 6
''')


if __name__ == "__main__":
    unittest.main()
