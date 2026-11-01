import json
import logging
import os
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from https_probe import STATUS_PATH, TLSCheckError, monitor, probe
from tls import TLSManager


def create_test_certificates(root):
    """只在临时目录生成测试 CA/证书，不请求公网签发。"""
    root = Path(root)
    commands = [
        [
            "req",
            "-x509",
            "-newkey",
            "ec",
            "-pkeyopt",
            "ec_paramgen_curve:P-256",
            "-nodes",
            "-days",
            "7",
            "-subj",
            "/CN=RepFlow-test-CA",
            "-addext",
            "basicConstraints=critical,CA:TRUE",
            "-addext",
            "keyUsage=critical,keyCertSign,cRLSign",
            "-keyout",
            "ca.key",
            "-out",
            "ca.pem",
        ],
        [
            "req",
            "-new",
            "-newkey",
            "ec",
            "-pkeyopt",
            "ec_paramgen_curve:P-256",
            "-nodes",
            "-subj",
            "/CN=repflow-test",
            "-keyout",
            "key.pem",
            "-out",
            "request.pem",
        ],
    ]
    (root / "extensions").write_text(
        "subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\n"
        "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n"
        "authorityKeyIdentifier=keyid,issuer\nsubjectKeyIdentifier=hash\n"
    )
    for name, serial in (("certificate.pem", "1"), ("replacement.pem", "2")):
        commands.append(
            [
                "x509",
                "-req",
                "-in",
                "request.pem",
                "-CA",
                "ca.pem",
                "-CAkey",
                "ca.key",
                "-set_serial",
                serial,
                "-days",
                "4",
                "-extfile",
                "extensions",
                "-out",
                name,
            ]
        )
    for arguments in commands:
        subprocess.run(
            ["openssl", *arguments],
            cwd=root,
            check=True,
            capture_output=True,
            timeout=10,
        )


class HTTPSProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="repflow-https-test-")
        cls.root = Path(cls.directory.name)
        create_test_certificates(cls.root)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def setUp(self):
        self.health = {"status": "ok"}
        self.status = {"ok": True, "checked_at": int(time.time())}
        self.health_code = 200
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def handle(self):
                try:
                    super().handle()
                except (ConnectionResetError, BrokenPipeError):
                    # 客户端发现证书余期不足时会在发送 HTTP 请求前断开。
                    logging.getLogger(__name__).debug(
                        "test client rejected certificate before HTTP"
                    )

            def do_GET(self):
                owner.last_host = self.headers["Host"]
                status = owner.health_code if self.path == "/health" else 200
                data = owner.status if self.path == STATUS_PATH else owner.health
                body = json.dumps(data).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format, *args):
                return

        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.context.load_cert_chain(
            self.root / "certificate.pem", self.root / "key.pem"
        )
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.socket = self.context.wrap_socket(
            self.server.socket, server_side=True
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def check(self, **overrides):
        arguments = dict(
            ip="127.0.0.1", port=self.server.server_port, cafile=self.root / "ca.pem"
        )
        return probe(**dict(arguments, **overrides))

    def test_real_tls_certificate_and_renewal_status(self):
        fingerprint = self.check()
        self.assertEqual(len(fingerprint), 64)
        self.assertEqual(self.last_host, f"127.0.0.1:{self.server.server_port}")
        self.context.load_cert_chain(
            self.root / "replacement.pem", self.root / "key.pem"
        )
        self.assertNotEqual(self.check(), fingerprint)

    def test_untrusted_certificate_and_wrong_ip_are_rejected(self):
        for overrides in (
            {"cafile": None},
            {"ip": "127.0.0.2", "connect_host": "127.0.0.1"},
        ):
            with (
                self.subTest(overrides=overrides),
                self.assertRaises(ssl.SSLCertVerificationError),
            ):
                self.check(**overrides)

    def test_expiring_certificate_is_rejected(self):
        with patch("https_probe.time.time", return_value=time.time() + 3 * 86400):
            with self.assertRaises(TLSCheckError):
                self.check()

    def test_health_failure_or_renewal_failure_is_rejected(self):
        self.health_code = 503
        with self.assertRaises(TLSCheckError):
            self.check()
        self.health_code = 200
        self.status["ok"] = False
        with self.assertRaises(TLSCheckError):
            self.check()

    def test_candidate_verification_checks_real_ip_chain_and_expiry(self):
        manager = TLSManager(
            self.root, "127.0.0.1", [], dict(os.environ), cafile=self.root / "ca.pem"
        )
        manager.lineage = self.root
        (self.root / "fullchain.pem").write_text(
            (self.root / "certificate.pem").read_text()
        )
        self.assertEqual(manager.validate_candidate(), self.check())
        manager.ip = "127.0.0.2"
        with self.assertRaises(TLSCheckError):
            manager.validate_candidate()

    def test_monitor_configuration_error_does_not_echo_secret_value(self):
        secret = "invalid-address-private-sentinel"
        result = subprocess.run(
            [sys.executable, str(Path(__file__).with_name("https_probe.py"))],
            env=dict(os.environ, HTTPS_MONITOR_IP=secret),
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("HTTPS monitoring failed", result.stderr)
        self.assertNotIn(secret, result.stdout + result.stderr)

    def test_monitor_uses_selected_public_port(self):
        for configured, expected in (({}, 8080), ({"HTTPS_MONITOR_PORT": "443"}, 443)):
            with (
                self.subTest(port=expected),
                patch.dict(
                    os.environ,
                    {"HTTPS_MONITOR_IP": "1.1.1.1", **configured},
                    clear=True,
                ),
                patch("https_probe.probe") as checked,
            ):
                monitor()
                checked.assert_called_once_with("1.1.1.1", expected)

    def test_invalid_ports_are_rejected_before_connecting(self):
        for port in (0, -1, 65536):
            with self.subTest(port=port), self.assertRaises(TLSCheckError):
                self.check(port=port)
