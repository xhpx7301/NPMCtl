"""Exercise the official NPM image in disposable deployments (Linux + Docker).

Requires jc21/nginx-proxy-manager:latest locally. Never uses /opt/npmctl or
the production container. All published bridge ports are random loopback ports.
"""
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import tempfile
import time
import uuid

IMAGE = os.environ.get("NPMCTL_TEST_IMAGE", "jc21/nginx-proxy-manager:latest")
NAME = "npmctl-l4-test-" + uuid.uuid4().hex[:10]
ROOT = Path(__file__).resolve().parents[1]


def run(*args, check=True, env=None):
    result = subprocess.run(args, text=True, capture_output=True, env=env)
    if check and result.returncode:
        raise RuntimeError(f"{args[0]} failed:\n{result.stdout}\n{result.stderr}")
    return result


def request(port, sni):
    context = ssl._create_unverified_context()
    with socket.create_connection(("127.0.0.1", port), timeout=8) as connection:
        with context.wrap_socket(connection, server_hostname=sni) as tls:
            tls.sendall(f"GET / HTTP/1.1\r\nHost: {sni}\r\nConnection: close\r\n\r\n".encode())
            data = b""
            while part := tls.recv(65536):
                data += part
    return data.decode()


def main():
    run("docker", "image", "inspect", IMAGE)
    with tempfile.TemporaryDirectory(prefix=NAME) as temporary:
        root = Path(temporary)
        deployment = root / "deployment"
        backups = root / "backups"
        data = deployment / "data"
        (data / "nginx/proxy_host").mkdir(parents=True)
        (data / "nginx/custom").mkdir()
        (data / "test").mkdir()
        (data / "nginx/custom/stream.conf").write_text("# Existing user stream config\n")
        run("openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048", "-days", "1",
            "-subj", "/CN=panel.example", "-keyout", str(data / "test/key.pem"),
            "-out", str(data / "test/cert.pem"))
        panel = data / "nginx/proxy_host/1.conf"
        original_panel = '''server {
    listen 443 ssl;
    server_name panel.example;
    ssl_certificate /data/test/cert.pem;
    ssl_certificate_key /data/test/key.pem;
    location / { return 200 "$remote_addr|$proxy_protocol_addr|$server_port"; }
}
'''
        panel.write_text(original_panel)
        source = (ROOT / "npmctl.sh").read_text().split('if [[ $# -eq 1 && ( "$1" == --help')[0]
        source = source.replace("nginx-proxy-manager", NAME)
        for name, value in {"INSTALL_DIR": deployment, "BACKUP_DIR": backups, "NPM_IMAGE": IMAGE}.items():
            source = re.sub(rf'^readonly {name}=.*$', f'readonly {name}="{value}"', source, flags=re.M)
        for port in (80, 81, 443):
            source = source.replace(f'"{port}:{port}"', f'"127.0.0.1:0:{port}"')
        # Keep this offline test independent of NPM's optional CDN range fetch.
        source = source.replace('      DISABLE_IPV6: "true"', '      DISABLE_IPV6: "true"\n      IP_RANGES_FETCH_ENABLED: "false"')
        # Host TCP 80 may belong to another app. Move only the test image's HTTP
        # listener to 18080; HTTPS 443/8443 and admin 81 exercise real host mode.
        source = source.replace('exec /init "$@"', '''sed -i 's/listen 80/listen 18080/g;s/listen \\[::\\]:80/listen [::]:18080/g' /etc/nginx/conf.d/default.conf /app/templates/_listen.conf /app/templates/default.conf
exec /init "$@"''')
        # Keep failed-image rollback tests bounded; normal starts get 60 attempts.
        library = root / "library.sh"
        library.write_text(source)
        env = {**os.environ, "LIBRARY": str(library), "COMPOSE_PROJECT_NAME": NAME}

        def bash(script, check=True):
            return run("bash", "-c", 'source "$LIBRARY"\n' + script, check=check, env=env)

        def port():
            return int(run("docker", "port", NAME, "443/tcp").stdout.strip().rsplit(":", 1)[1])

        def backends():
            code = '''const tls=require('tls'), fs=require('fs');
const options={key:fs.readFileSync('/data/test/key.pem'),cert:fs.readFileSync('/data/test/cert.pem')};
for (const port of [15443,25443]) tls.createServer(options,s=>s.once('data',()=>s.end('raw-tls-'+port))).listen(port,'127.0.0.1');
'''
            run("docker", "exec", "-d", NAME, "node", "-e", code)
            for _ in range(20):
                if run("docker", "exec", NAME, "bash", "-c", "</dev/tcp/127.0.0.1/25443", check=False).returncode == 0:
                    return
                time.sleep(0.2)
            raise AssertionError("TLS backend did not start")

        def verify(public_port, host=False):
            body = request(public_port, "panel.example").split("\r\n\r\n", 1)[1]
            remote, proxy, internal = body.split("|")
            assert remote == proxy and remote and internal == "8443", body
            if not host:
                assert remote != "127.0.0.1", body
            assert request(public_port, "reality.example") == "raw-tls-15443"
            assert request(public_port, "second.example") == "raw-tls-25443"

        try:
            bash('write_compose_file bridge\ncd "$INSTALL_DIR"\ndocker compose up -d npm\nl4_wait_ready')
            assert request(port(), "panel.example").endswith("||443")
            print("PASS: baseline official NPM HTTPS", flush=True)
            candidate = root / "routes.tsv"
            candidate.write_text("reality.example\t127.0.0.1\t15443\nsecond.example\t127.0.0.1\t25443\n")
            bash(f'l4_apply "{candidate}" 1')
            backends()
            verify(port())
            print("PASS: bridge HTTPS real IP and two raw TLS SNI backends", flush=True)
            # Saving a new NPM site must use the adapted image template too.
            template = run("docker", "exec", NAME, "cat", "/app/templates/_listen.conf").stdout
            assert "listen 127.0.0.1:8443 ssl proxy_protocol;" in template
            assert "real_ip_header proxy_protocol;" in template
            bash('cd "$INSTALL_DIR"\ndocker compose up -d --force-recreate npm\nl4_wait_ready')
            backends()
            verify(port())
            print("PASS: recreated container retains routes and real IP", flush=True)

            # Force an actual nginx parse failure after taking the snapshot.
            # The persisted original stream config must recover with the image.
            failed = bash('''
eval "$(declare -f write_l4_runtime | sed '1s/write_l4_runtime/original_write_l4_runtime/')"
write_l4_runtime() { original_write_l4_runtime || return 1; printf 'npmctl_invalid_directive;\n' >>"$L4_DIR/stream.conf"; }
''' + f'l4_wait_ready() {{ for ((i=0;i<12;i++)); do docker exec {NAME} nginx -t >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }}\nl4_apply "$L4_ROUTES" 1', check=False)
            assert failed.returncode != 0, failed.stdout
            bash('l4_wait_ready')
            backends()
            verify(port())
            print("PASS: failed application restores working routes and image", flush=True)

            host_free = True
            probes = []
            try:
                for value in (18080, 81, 443, 8443):
                    probe = socket.socket()
                    probes.append(probe)
                    probe.bind(("0.0.0.0", value))
            except OSError:
                host_free = False
            finally:
                for probe in probes:
                    probe.close()
            if host_free:
                bash('l4_apply "$L4_ROUTES" 1 host')
                backends()
                verify(443, host=True)
                bash('l4_apply "$L4_ROUTES" 1 bridge')
                backends()
                verify(port())
                print("PASS: bridge → host → bridge preserves routing", flush=True)
            else:
                print("SKIP: host network test (a required host port is occupied)", flush=True)

            bash('l4_apply "$L4_ROUTES" 0')
            assert request(port(), "panel.example").endswith("||443")
            assert panel.read_text() == original_panel
            custom = (data / "nginx/custom/stream.conf").read_text()
            assert "# Existing user stream config" in custom and "# NPMCTL L4" not in custom
            assert (deployment / "l4/routes.tsv").read_text() == candidate.read_text()
            print("PASS: disable restores original HTTPS and retains saved routes", flush=True)
            bash('l4_apply "$L4_ROUTES" 1')
            backends()
            verify(port())
            print("PASS: re-enable saved configuration", flush=True)
        except Exception:
            logs = run("docker", "logs", "--tail", "60", NAME, check=False)
            print(logs.stdout + logs.stderr)
            raise
        finally:
            bash('cd "$INSTALL_DIR"\ndocker compose down --remove-orphans', check=False)
            run("docker", "rm", "-f", NAME, check=False)


if __name__ == "__main__":
    main()
