"""Prepare two fixed TLS routes in the private production guest. No application secrets."""
from pathlib import Path
import socket
import subprocess

root = Path("/opt/esheep-production")
if socket.gethostname().split(".")[0] != "lima-prod":
    raise SystemExit("Expected the private production guest")
gateway = subprocess.check_output(
    ["docker", "network", "inspect", "esheep-production_default", "-f", "{{range .IPAM.Config}}{{.Gateway}}{{end}}"],
    text=True,
).strip()
if gateway != "172.30.91.1":
    raise SystemExit("Unexpected internal network")
override = root / "runtime/restore.override.yml"
original = override.read_text()
marker = "  auth:\n"
entries = marker + '    extra_hosts:\n      - "smtp.mx.cloudflare.net:172.30.91.1"\n      - "appleid.apple.com:172.30.91.1"\n'
if entries not in original:
    if original.count(marker) != 1 or "extra_hosts:" in original[original.index(marker):].split("  api-gw:")[0]:
        raise SystemExit("Inspect the existing Auth override")
    override.write_text(original.replace(marker, entries, 1))
unit_dir = Path("/etc/systemd/system")
units = []
for name, port, forwarded in [("smtp", 465, 14655), ("apple", 443, 14443)]:
    unit = "esheep-auth-" + name
    (unit_dir / (unit + ".socket")).write_text(
        f"[Unit]\nDescription=eSheep Auth {name} private socket\n"
        f"[Socket]\nListenStream={gateway}:{port}\nFreeBind=true\n"
        "[Install]\nWantedBy=sockets.target\n"
    )
    (unit_dir / (unit + ".service")).write_text(
        f"[Unit]\nDescription=eSheep Auth {name} loopback forwarding\n[Service]\n"
        f"ExecStart=/usr/lib/systemd/systemd-socket-proxyd 127.0.0.1:{forwarded}\n"
        "DynamicUser=true\nNoNewPrivileges=true\nProtectSystem=strict\nProtectHome=true\n"
    )
    units.append(unit + ".socket")
subprocess.run(["systemctl", "daemon-reload"], check=True)
subprocess.run(["systemctl", "enable", "--now", *units], check=True)
subprocess.run([root / "compose", "up", "-d", "--no-deps", "--no-build", "--pull", "never",
                "--wait", "--wait-timeout", "90", "auth"], check=True)
