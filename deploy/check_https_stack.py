"""可丢弃 Compose 项目的 HTTPS 验收；只生成测试证书，不访问 ACME。"""

import json
import logging
import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import urlopen

from https_probe import STATUS_PATH, TLSCheckError, probe
from test_https_probe import create_test_certificates
from tls import TLSManager

logger = logging.getLogger(__name__)


def free_ports():
    with socket.socket() as first, socket.socket() as second:
        first.bind(("127.0.0.1", 0))
        second.bind(("127.0.0.1", 0))
        return first.getsockname()[1], second.getsockname()[1]


def expect_rejected(operation):
    try:
        operation()
    except TLSCheckError:
        logger.info("Invalid candidate or failed status was correctly rejected")
        return
    raise AssertionError("invalid candidate or failed status was accepted")


def check():
    source = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="repflow-https-check-") as temporary:
        root = Path(temporary)
        for name in (
            "compose.yaml",
            "compose.tls.yaml",
            "nginx.conf",
            "nginx.acme.conf",
            "nginx.tls.conf",
        ):
            shutil.copyfile(source / name, root / name)
        create_test_certificates(root)
        http_port, https_port = free_ports()
        environment = dict(
            os.environ,
            POSTGRES_DB="repflow_https_test",
            POSTGRES_USER="repflow_https_test",
            POSTGRES_PASSWORD="repflow_https_test_only",
            HTTP_BIND="127.0.0.1",
            ACME_HTTP_PORT=str(http_port),
            HTTPS_PORT=str(https_port),
            TLS_STATE_DIR=str(root / "tls"),
            TLS_NGINX_CONFIG=str(root / "nginx.tls.conf"),
        )
        for name in ("TLS_CERT_DIR", "CERTBOT_IMAGE"):
            environment.pop(name, None)
        compose = [
            "docker",
            "compose",
            "--env-file",
            os.devnull,
            "-p",
            f"repflow-https-check-{os.getpid()}",
            "-f",
            str(root / "compose.yaml"),
            "-f",
            str(root / "compose.tls.yaml"),
        ]
        manager = TLSManager(
            root / "tls", "127.0.0.1", compose, environment, cafile=root / "ca.pem"
        )
        manager.initialize()

        def command(*arguments):
            return subprocess.run(
                [*compose, *arguments],
                env=environment,
                text=True,
                capture_output=True,
                check=True,
                timeout=180,
            ).stdout

        def verify():
            return probe("127.0.0.1", https_port, cafile=root / "ca.pem")

        try:
            command("config", "--quiet")
            version = command("run", "--rm", "--no-deps", "certbot", "--version")
            assert version.strip() == "certbot 5.9.0", version
            command("up", "-d", "--wait", "--wait-timeout", "120", "db", "api")
            manager.bootstrap()
            challenge = manager.state / "webroot/.well-known/acme-challenge/probe"
            challenge.parent.mkdir(parents=True, exist_ok=True)
            challenge.write_text("repflow-http-01-test")
            with urlopen(
                f"http://127.0.0.1:{http_port}/.well-known/acme-challenge/probe",
                timeout=5,
            ) as response:
                assert response.read() == b"repflow-http-01-test"
            manager.lineage.mkdir(parents=True)
            shutil.copyfile(root / "certificate.pem", manager.lineage / "fullchain.pem")
            shutil.copyfile(root / "key.pem", manager.lineage / "privkey.pem")
            (manager.lineage / "privkey.pem").chmod(0o600)
            manager.activate(recreate=True)
            original = verify()
            for path in ("/health", STATUS_PATH, "/api/v1/auth/login"):
                try:
                    urlopen(f"http://127.0.0.1:{http_port}{path}", timeout=5)
                except HTTPError as error:
                    error.close()
                    assert error.code == 404
                else:
                    raise AssertionError("plaintext route was exposed")

            # 真实替换证书并验证 nginx 发出的指纹改变，覆盖 reload 链路。
            shutil.copyfile(root / "replacement.pem", manager.lineage / "fullchain.pem")
            manager.pending.touch()
            manager.activate()
            renewed = verify()
            assert renewed != original
            (manager.lineage / "fullchain.pem").write_text("invalid certificate")
            expect_rejected(manager.activate)
            assert verify() == renewed
            shutil.copyfile(root / "replacement.pem", manager.lineage / "fullchain.pem")

            # 原子替换配置，预检应阻止重建；恢复配置后显式重建以完成回退。
            nginx = root / "nginx.tls.conf"
            saved = nginx.read_text()
            candidate = root / "candidate.conf"
            candidate.write_text(saved + "\ninvalid_repflow_directive;\n")
            candidate.replace(nginx)
            expect_rejected(lambda: manager.activate(recreate=True))
            assert verify() == renewed
            candidate.write_text(saved)
            candidate.replace(nginx)
            manager.activate(recreate=True)
            assert verify() == renewed
            command("restart", "nginx")
            manager.activate()
            assert verify() == renewed
            manager.status(False)
            expect_rejected(verify)
            manager.activate()
            assert json.loads((manager.state / "status/status.json").read_text())["ok"]
            logger.info(
                "HTTPS checks passed: HTTP-01, TLS trust, certificate reload, failure detection, nginx restart and configuration rollback"
            )
        finally:
            # 仅删除本脚本新建的独立测试项目和测试库卷。
            command("down", "--volumes", "--remove-orphans")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    check()
