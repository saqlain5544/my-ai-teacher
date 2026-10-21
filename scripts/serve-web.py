#!/usr/bin/env python3
"""Dev server for the transcript renderer harness: like `python3 -m http.server`, but never cached."""
import http.server, sys, functools

class NoStore(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
handler = functools.partial(NoStore, directory=".")
http.server.ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()
