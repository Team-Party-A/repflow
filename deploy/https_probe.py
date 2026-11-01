"""验证实际送出的证书、健康检查和续期状态；日志不含服务器地址。"""

import hashlib
import http.client
import ipaddress
import json
import logging
import os
import socket
import ssl
import time

STATUS_PATH = "/.well-known/repflow-tls-status"
MIN_VALIDITY_SECONDS = 48 * 3600
MAX_STATUS_AGE_SECONDS = 26 * 3600


class TLSCheckError(Exception):
    pass


def probe(ip, port=443, *, connect_host=None, cafile=None, check_status=True):
    ip = str(ipaddress.IPv4Address(ip))
    if not 1 <= port <= 65535:
        raise TLSCheckError("monitoring port must be between 1 and 65535")
    authority = ip if port == 443 else f"{ip}:{port}"
    context = ssl.create_default_context(cafile=cafile)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    paths = ["/health", STATUS_PATH] if check_status else ["/health"]
    fingerprint = None
    for path in paths:
        with socket.create_connection((connect_host or ip, port), timeout=5) as raw:
            with context.wrap_socket(raw, server_hostname=ip) as connection:
                certificate = connection.getpeercert()
                expires_at = ssl.cert_time_to_seconds(certificate["notAfter"])
                if expires_at - time.time() < MIN_VALIDITY_SECONDS:
                    raise TLSCheckError("certificate has less than 48 hours remaining")
                fingerprint = hashlib.sha256(
                    connection.getpeercert(binary_form=True)
                ).hexdigest()
                connection.sendall(
                    f"GET {path} HTTP/1.1\r\nHost: {authority}\r\nConnection: close\r\n\r\n".encode()
                )
                response = http.client.HTTPResponse(connection)
                response.begin()
                body = response.read(4097)
                if response.status != 200 or len(body) > 4096:
                    raise TLSCheckError(
                        "HTTPS endpoint did not return a bounded 200 response"
                    )
                data = json.loads(body)
                if path == "/health":
                    if data != {"status": "ok"}:
                        raise TLSCheckError("health check is unavailable")
                else:
                    check_renewal_status(data)
    return fingerprint


def check_renewal_status(data):
    if not isinstance(data, dict) or data.get("ok") is not True:
        raise TLSCheckError("last certificate operation failed")
    checked_at = data.get("checked_at")
    if type(checked_at) is not int:
        raise TLSCheckError("renewal status timestamp is invalid")
    if not -300 <= time.time() - checked_at <= MAX_STATUS_AGE_SECONDS:
        raise TLSCheckError("renewal status is stale or clock is incorrect")


def monitor():
    address = ipaddress.IPv4Address(os.environ["HTTPS_MONITOR_IP"])
    if not address.is_global:
        raise TLSCheckError("monitoring requires a public IPv4 address")
    probe(str(address), int(os.environ.get("HTTPS_MONITOR_PORT", "8080")))


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    try:
        monitor()
    except TLSCheckError as error:
        logging.error("HTTPS monitoring failed: %s", error)
        raise SystemExit(1) from None
    except (OSError, ValueError, KeyError, http.client.HTTPException) as error:
        logging.error("HTTPS monitoring failed: kind=%s", type(error).__name__)
        raise SystemExit(1) from None
    logging.info("HTTPS certificate, health and renewal status verified")
