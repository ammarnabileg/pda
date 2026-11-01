#!/usr/bin/env python3
"""Start the Tamween server (devices API + dashboard) on the local network.

    python run.py            # port 9001 on all network interfaces
    python run.py --port 9002
"""
import argparse
import os
import secrets
import socket
from pathlib import Path

ENV = Path(__file__).resolve().parent / ".env"


def ensure_secret():
    text = ENV.read_text(encoding="utf-8") if ENV.exists() else ""
    if "SECRET_KEY=" not in text:
        with ENV.open("a", encoding="utf-8") as f:
            f.write(("\n" if text and not text.endswith("\n") else "") + f"SECRET_KEY={secrets.token_urlsafe(32)}\n")


def lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return "<this computer's IP>"


def main():
    ensure_secret()
    from app import config  # noqa: E402  (reads .env after the secret is written)
    from app.db import init_db

    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=config.PORT)
    ap.add_argument("--host", default=config.HOST)
    args = ap.parse_args()

    init_db()
    print("Tamween server is running.")
    print(f"  Dashboard (on this computer): http://localhost:{args.port}")
    print(f"  Devices and other computers:  http://{lan_ip()}:{args.port}")
    print("Press Ctrl+C to stop.\n")

    import uvicorn
    uvicorn.run("app.main:app", host=args.host, port=args.port, proxy_headers=False,
                workers=int(os.environ.get("WORKERS", "1")))


if __name__ == "__main__":
    main()
