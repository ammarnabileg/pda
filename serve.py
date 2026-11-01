#!/usr/bin/env python3
"""Serve the Tamween PDA app on the local network.

Usage:
    python serve.py                 # http on port 9001
    python serve.py --port 9001
    python serve.py --cert cert.pem --key key.pem   # https (needed for offline mode / install as app)

Then open the printed address on the PDA's browser (Chrome).
Only standard library is used, so any Python 3.8+ works.
"""
import argparse
import functools
import http.server
import os
import socket
import ssl
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".html": "text/html; charset=utf-8",
        ".js": "application/javascript; charset=utf-8",
        ".json": "application/manifest+json; charset=utf-8",
        ".svg": "image/svg+xml",
    }

    def end_headers(self):
        # Devices must always fetch the newest app files and service worker.
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def log_message(self, fmt, *args):
        sys.stdout.write("%s  %s\n" % (self.client_address[0], fmt % args))


def lan_addresses():
    addrs = set()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))  # no packet is sent; picks the LAN interface
        addrs.add(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addrs.add(info[4][0])
    except OSError:
        pass
    return sorted(a for a in addrs if not a.startswith("127."))


def main():
    ap = argparse.ArgumentParser(description="Serve the Tamween PDA app on the LAN")
    ap.add_argument("--port", type=int, default=9001)
    ap.add_argument("--bind", default="0.0.0.0", help="address to listen on (default: all interfaces)")
    ap.add_argument("--cert", help="TLS certificate file (enables https)")
    ap.add_argument("--key", help="TLS private key file")
    args = ap.parse_args()

    handler = functools.partial(Handler, directory=ROOT)
    httpd = http.server.ThreadingHTTPServer((args.bind, args.port), handler)

    scheme = "http"
    if args.cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(args.cert, args.key)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        scheme = "https"

    print("Tamween PDA is running. Open one of these on the device:")
    for a in lan_addresses() or ["<this computer's IP>"]:
        print("   %s://%s:%d" % (scheme, a, args.port))
    print("   %s://localhost:%d  (this computer only)" % (scheme, args.port))
    if scheme == "http":
        print("\nNote: over plain http on the network, the browser disables offline mode and")
        print("'install as app'. The screens still work. See README for how to enable them.")
    print("\nPress Ctrl+C to stop.\n")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
