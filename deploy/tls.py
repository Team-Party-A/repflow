"""人工初始化；用户级定时器续期。命令原始输出只保存到服务器私有目录。"""

import argparse
import fcntl
import hashlib
import ipaddress
import json
import logging
import os
import ssl
import subprocess
import time
from pathlib import Path

from https_probe import TLSCheckError, probe

DEPLOY = Path(__file__).resolve().parent
logger = logging.getLogger(__name__)


class TLSManager:
    def __init__(self, state, ip, compose, environment, *, cafile=None):
        self.state, self.ip = Path(state), str(ipaddress.IPv4Address(ip))
        self.compose, self.environment, self.cafile = compose, environment, cafile
        self.lineage = self.state / "letsencrypt/live/repflow-ip"
        self.pending = self.state / "letsencrypt/repflow-reload-required"

    def initialize(self):
        self.state.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.state.chmod(0o700)
        for name in ("letsencrypt", "staging", "logs", "webroot", "status"):
            directory = self.state / name
            directory.mkdir(exist_ok=True)
            directory.chmod(0o755 if name in {"webroot", "status"} else 0o700)

    def run(self, arguments, **overrides):
        # CalledProcessError 会包含带 IP 的参数，不把原始异常写到日志。
        with (self.state / "last-command.log").open("wb") as log:
            os.chmod(log.name, 0o600)
            result = subprocess.run(
                arguments,
                env=dict(self.environment, **overrides),
                stdout=log,
                stderr=log,
                timeout=600,
            )
        if result.returncode:
            raise TLSCheckError("command failed; inspect the private last-command.log")

    def compose_run(self, *arguments, **overrides):
        self.run([*self.compose, *arguments], **overrides)

    def status(self, ok):
        path = self.state / "status/status.next"
        path.write_text(json.dumps({"ok": ok, "checked_at": int(time.time())}) + "\n")
        path.chmod(0o644)
        path.replace(path.with_name("status.json"))

    def bootstrap(self):
        config = {"TLS_NGINX_CONFIG": str(DEPLOY / "nginx.acme.conf")}
        self.status(False)
        self.compose_run("run", "--rm", "--no-deps", "nginx", "nginx", "-t", **config)
        self.compose_run("up", "-d", "--no-deps", "--force-recreate", "nginx", **config)

    def certbot(self, *arguments, **overrides):
        self.compose_run("run", "--rm", "--no-deps", "certbot", *arguments, **overrides)

    def issue(self, staging=False):
        if not ipaddress.ip_address(self.ip).is_global:
            raise TLSCheckError("issuance requires a global IPv4 address")
        verified = self.state / "staging-ok"
        identity = hashlib.sha256(self.ip.encode()).hexdigest()
        if not staging and (not verified.exists() or verified.read_text() != identity):
            raise TLSCheckError("complete staging issuance for this IP first")
        arguments = [
            "certonly",
            "--non-interactive",
            "--agree-tos",
            "--register-unsafely-without-email",
            "--required-profile",
            "shortlived",
            "--webroot",
            "--webroot-path",
            "/var/www/acme",
            "--preferred-challenges",
            "http",
            "--cert-name",
            "repflow-ip",
            "--key-type",
            "ecdsa",
            "--elliptic-curve",
            "secp256r1",
            "--ip-address",
            self.ip,
        ]
        if staging:
            self.certbot(
                *arguments,
                "--staging",
                "--force-renewal",
                TLS_CERT_DIR=str(self.state / "staging"),
            )
            verified.write_text(identity)
        else:
            self.certbot(*arguments)
            self.activate(recreate=True)

    def validate_candidate(self):
        certificate = str(self.lineage / "fullchain.pem")
        self.run(
            ["openssl", "x509", "-in", certificate, "-noout", "-checkend", "172800"]
        )
        command = ["openssl", "verify", "-purpose", "sslserver", "-verify_ip", self.ip]
        if self.cafile:
            command.extend(["-CAfile", str(self.cafile)])
        self.run([*command, "-untrusted", certificate, certificate])
        leaf = Path(certificate).read_text().split("-----END CERTIFICATE-----")[0]
        der = ssl.PEM_cert_to_DER_cert(leaf + "-----END CERTIFICATE-----\n")
        return hashlib.sha256(der).hexdigest()

    def activate(self, recreate=False):
        fingerprint = self.validate_candidate()
        applied = self.state / "applied-fingerprint"
        changed = not applied.exists() or applied.read_text() != fingerprint
        if recreate:
            self.compose_run("run", "--rm", "--no-deps", "nginx", "nginx", "-t")
            self.compose_run("up", "-d", "--no-deps", "--force-recreate", "nginx")
        elif changed or self.pending.exists():
            self.compose_run("exec", "-T", "nginx", "nginx", "-t")
            self.compose_run("exec", "-T", "nginx", "nginx", "-s", "reload")
        for attempt in range(10):
            try:
                served = probe(
                    self.ip,
                    int(self.environment.get("HTTPS_PORT", "8080")),
                    connect_host="127.0.0.1",
                    cafile=self.cafile,
                    check_status=False,
                )
                if served == fingerprint:
                    applied.write_text(fingerprint)
                    self.pending.unlink(missing_ok=True)
                    self.status(True)
                    return
            except (TLSCheckError, OSError, ValueError):
                if attempt == 9:
                    self.pending.touch()
                    raise
            time.sleep(1)
        self.pending.touch()
        raise TLSCheckError("nginx did not serve the current certificate")

    def renew(self, dry_run=False):
        # systemd 已提供随机延迟；避免 Certbot 再等待数分钟占用命令超时预算。
        arguments = [
            "renew",
            "--non-interactive",
            "--no-random-sleep-on-renew",
            "--cert-name",
            "repflow-ip",
        ]
        if dry_run:
            arguments.extend(["--dry-run", "--run-deploy-hooks"])
        self.certbot(
            *arguments,
            "--deploy-hook",
            "touch /etc/letsencrypt/repflow-reload-required",
        )
        self.activate()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=["bootstrap", "staging", "issue", "renew", "dry-run", "activate"],
    )
    parser.add_argument("--env-file", default=str(DEPLOY / ".env"))
    parser.add_argument("--context", default="rootless")
    parser.add_argument("--project", default="repflow")
    arguments = parser.parse_args()
    os.umask(0o077)
    environment = dict(os.environ)
    state = Path(environment["TLS_STATE_DIR"]).expanduser().resolve()
    if state.is_relative_to(DEPLOY.parent):
        raise TLSCheckError("TLS_STATE_DIR must be outside the repository")
    environment["TLS_STATE_DIR"] = str(state)
    environment["TLS_NGINX_CONFIG"] = str(DEPLOY / "nginx.tls.conf")
    environment.pop("TLS_CERT_DIR", None)
    compose = [
        "docker",
        "--context",
        arguments.context,
        "compose",
        "--env-file",
        arguments.env_file,
        "-p",
        arguments.project,
        "-f",
        str(DEPLOY / "compose.yaml"),
    ]
    if environment.get("TLS_USE_GHCR") == "1":
        compose.extend(["-f", str(DEPLOY / "compose.ghcr.yaml")])
    compose.extend(["-f", str(DEPLOY / "compose.tls.yaml")])
    if environment.get("TLS_USE_GHCR") == "1":
        compose.extend(["-f", str(DEPLOY / "compose.tls.ghcr.yaml")])
    manager = TLSManager(state, environment["PUBLIC_IP"], compose, environment)
    manager.initialize()
    with (state / "operation.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            if arguments.action in {"staging", "issue"}:
                manager.issue(staging=arguments.action == "staging")
            elif arguments.action in {"renew", "dry-run"}:
                manager.renew(dry_run=arguments.action == "dry-run")
            elif arguments.action == "activate":
                manager.activate(recreate=True)
            else:
                getattr(manager, arguments.action)()
        except Exception:
            manager.status(False)
            raise


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    try:
        main()
    except Exception as error:
        logger.error(
            "TLS operation failed: kind=%s; inspect private logs", type(error).__name__
        )
        raise SystemExit(1) from None
    logger.info("TLS operation completed")
