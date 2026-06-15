import os
from urllib.parse import urlparse


def get_proxy_from_env():
    raw = (
        os.environ.get("TG_PROXY")
        or os.environ.get("ALL_PROXY")
        or os.environ.get("all_proxy")
        or os.environ.get("HTTPS_PROXY")
        or os.environ.get("https_proxy")
        or os.environ.get("HTTP_PROXY")
        or os.environ.get("http_proxy")
    )
    if not raw:
        return None

    parsed = urlparse(raw)
    scheme = (parsed.scheme or "").lower()
    host = parsed.hostname
    port = parsed.port
    if not host or not port:
        raise ValueError(f"Invalid proxy url: {raw}")

    if scheme in {"socks5", "socks5h"}:
        return {
            "proxy_type": "socks5",
            "addr": host,
            "port": port,
            "username": parsed.username,
            "password": parsed.password,
            "rdns": scheme == "socks5h",
        }
    if scheme in {"http", "https"}:
        return {
            "proxy_type": "http",
            "addr": host,
            "port": port,
            "username": parsed.username,
            "password": parsed.password,
        }
    raise ValueError(f"Unsupported proxy scheme: {scheme}")
