"""Configure mini Auth from a dedicated Cloudflare Email Sending token supplied on stdin."""
import fcntl
import os
from pathlib import Path
import re
import smtplib
import socket
import ssl
import subprocess
import sys
import tempfile

root = Path("/opt/esheep-production")
host = "smtp.mx.cloudflare.net"
sender = "noreply@notify.esheepplus.com"
if socket.gethostname().split(".")[0] != "lima-prod":
    raise SystemExit("Wrong guest")
if os.geteuid() != 0 or sys.stdin.isatty():
    raise SystemExit("Supply the token through a private pipe as the guest administrator")
token = sys.stdin.buffer.read(513).decode("ascii").strip()
if not re.fullmatch(r"[A-Za-z0-9_.-]{20,512}", token):
    raise SystemExit("Unexpected token format")


class AuthSMTP(smtplib.SMTP_SSL):
    def _get_socket(self, name, port, timeout):
        # Auth maps the provider hostname to this bridge. Validate its public TLS certificate.
        sock = socket.create_connection(("172.30.91.1", port), timeout)
        return self.context.wrap_socket(sock, server_hostname=name)


def write_environment(path, content):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as out:
        tmp = Path(out.name)
        try:
            os.fchmod(out.fileno(), 0o600)
            out.write(content)
            out.flush()
            os.fsync(out.fileno())
            os.replace(tmp, path)
        finally:
            tmp.unlink(missing_ok=True)


os.umask(0o077)
env = root / "runtime/.env"
launch = [root / "compose", "up", "-d", "--no-build", "--no-deps", "--pull", "never",
          "--wait", "--wait-timeout", "90", "auth"]
with (env.parent / ".smtp-config.lock").open("a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    with AuthSMTP(host, 465, timeout=45, context=ssl.create_default_context()) as client:
        client.login("api_token", token)
        status, _ = client.mail(sender)
        if status != 250:
            raise SystemExit("Provider did not accept the envelope sender")
        client.rset()
    settings = {"SMTP_HOST": host, "SMTP_PORT": "465", "SMTP_USER": "api_token",
                "SMTP_PASS": token, "SMTP_ADMIN_EMAIL": sender, "SMTP_SENDER_NAME": "eSheep+"}
    previous = env.read_bytes()
    lines = previous.decode().splitlines()
    for name, value in settings.items():
        matches = [i for i, line in enumerate(lines) if line.startswith(name + "=")]
        if len(matches) != 1:
            raise SystemExit("Missing or ambiguous Auth setting " + name)
        lines[matches[0]] = name + "=" + value
    write_environment(env, ("\n".join(lines) + "\n").encode())
    try:
        subprocess.run(launch, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except BaseException:
        write_environment(env, previous)
        subprocess.run(launch, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        raise
print("SMTP authenticated, envelope sender accepted, Auth healthy. No recipient or email submitted.")
