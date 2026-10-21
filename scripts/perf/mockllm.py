#!/usr/bin/env python3
"""A local OpenAI-compatible model for perf runs: deterministic, free, and as fast or slow as asked.

    scripts/perf/mockllm.py [--port 0]      prints "PORT <n>" when ready

The lesson's last learner message steers it with one line starting "PERF:" (only in requests that carry tools, so the
app's own reflection, compaction and title requests never trigger a workload):
    PERF:stream chars=60000 cps=6000     stream a long Markdown reply (maths, code, tables, a diagram) at cps chars/s
    PERF:agents n=4 chars=4000           call the `task` tool n times in parallel; each sub-agent streams a chars-long report
    PERF:fetch url=http://…              call web_fetch on the url
Anything else gets a one-line reply. After tool results it answers with a short summary.
GET /big.html?kb=3000&depth=60 serves a large, deeply nested article for web_fetch (tables, lists, MathML, scripts, nav).
"""
import json, re, sys, time, argparse, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

SECTION = """## Section {i}: composite functions

The chain rule turns a hard derivative into two easy ones. For $f(x) = \\sin(x^{k})$ with $k = {k}$, write $u = x^{k}$ so that

$$\\frac{{df}}{{dx}} = \\cos(u) \\cdot k x^{{k-1}}$$

- **Outer:** differentiate $\\sin u$ to get $\\cos u$, keeping $u$ as it is.
- **Inner:** differentiate $x^{k}$ to get ${k}x^{{{km}}}$.
- **Combine:** multiply, then simplify; check numerically at $x = 1$.

```python
import math
h = 1e-6
f = lambda x: math.sin(x ** {k})
print(round((f(1 + h) - f(1 - h)) / (2 * h), 4), round(math.cos(1) * {k}, 4))
```

| step | expression | value at x = 1 |
|------|------------|----------------|
| outer | $\\cos(x^{k})$ | 0.5403 |
| inner | ${k}x^{{{km}}}$ | {k} |

Practice: differentiate $\\cos({k}x^2)$ and explain each step in your own words. A common slip is to forget the inner
derivative, which gives $-\\sin({k}x^2)$ instead of $-{k2}x\\sin({k}x^2)$.

"""
DIAGRAM = "```mermaid\nflowchart LR\n  A[outer f] --> B[inner g]\n  B --> C[product]\n```\n\n"


def long_reply(chars):
    out, i = [], 0
    while sum(map(len, out)) < chars:
        k = i % 7 + 2
        out.append(SECTION.format(i=i + 1, k=k, km=k - 1, k2=2 * k))
        if i % 6 == 5: out.append(DIAGRAM)
        i += 1
    return "".join(out)[:chars]


def big_html(kb, depth):
    """A Wikipedia-like page: navigation chrome, scripts, a deep nest of divs, long paragraphs, tables, lists and MathML."""
    para = ("<p>The light-dependent reactions use <a href='/wiki/Light'>light</a> energy to make <b>ATP</b> and <i>NADPH</i>; "
            "the Calvin cycle then fixes carbon dioxide into sugars. Chlorophyll absorbs red and blue light most strongly.</p>")
    math = ("<math><semantics><mrow><mi>E</mi><mo>=</mo><mi>h</mi><mi>ν</mi></mrow>"
            "<annotation encoding='application/x-tex'>E = h\\nu</annotation></semantics></math>")
    table = "<table><tr><th>pigment</th><th>peak (nm)</th></tr>" + "".join(f"<tr><td>p{j}</td><td>{400 + j}</td></tr>" for j in range(12)) + "</table>"
    lst = "<ul>" + "".join(f"<li>item {j} with <code>code</code> and a <a href='/x{j}'>link</a></li>" for j in range(10)) + "</ul>"
    chrome = "<nav>" + "".join(f"<a href='/n{j}'>nav {j}</a>" for j in range(200)) + "</nav><script>var x = 1;" + "x++;" * 2000 + "</script>"
    unit = "<div class='sec'><h2>Section</h2>" + para * 6 + math + table + lst + "</div>"
    body, n = [], 0
    while n < kb * 1024:
        body.append(unit); n += len(unit)
    nest = "<div>" * depth + "".join(body) + "</div>" * depth
    return ("<!doctype html><html><head><title>Big page</title><style>body{}</style></head><body>" + chrome +
            "<div id='mw-content-text'>" + nest + "</div><footer>" + "f" * 2000 + "</footer></body></html>")


def directive(body):
    if not body.get("tools"): return None
    msgs = body.get("messages") or []
    last = msgs[-1] if msgs else {}
    if last.get("role") == "tool": return ("after_tools", {})
    content = last.get("content")
    text = content if isinstance(content, str) else "\n".join(p.get("text", "") for p in content or [] if isinstance(p, dict))
    m = re.search(r"(?m)^PERF:(\w+)(.*)$", text or "")
    if not m: return ("short", {})
    return (m.group(1), dict(kv.split("=", 1) for kv in m.group(2).split() if "=" in kv))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *a): pass

    def do_GET(self):
        u = urlparse(self.path)
        if u.path.endswith("/models"):
            return self.json({"object": "list", "data": [{"id": "perf-mock", "object": "model", "context_length": 200000}]})
        if u.path == "/big.html":
            q = parse_qs(u.query)
            page = big_html(int(q.get("kb", ["3000"])[0]), int(q.get("depth", ["60"])[0])).encode()
            self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8"); self.send_header("Content-Length", str(len(page)))
            self.end_headers(); self.wfile.write(page); return
        self.send_response(404); self.end_headers()

    def json(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        kind, args = directive(body) or ("plain", {})
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Cache-Control", "no-cache"); self.end_headers()
        try:
            if kind == "stream": self.text(long_reply(int(args.get("chars", 30000))), float(args.get("cps", 4000)))
            elif kind == "sub": self.text(long_reply(int(args.get("chars", 4000))), float(args.get("cps", 8000)))
            elif kind == "agents":
                n, chars = int(args.get("n", 3)), int(args.get("chars", 4000))
                self.calls([("task", {"description": f"perf research {j + 1}", "prompt": f"PERF:sub chars={chars}\nResearch part {j + 1}."}) for j in range(n)])
            elif kind == "fetch": self.calls([("web_fetch", {"url": args.get("url", "http://127.0.0.1/big.html")})])
            elif kind == "after_tools": self.text("Done: the tool results are in. " * 20, 20000)
            elif kind == "plain": self.text("Nothing to add.", 1e9)
            else: self.text("OK — a short reply from the perf model.", 1e9)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def chunk(self, delta, finish=None, usage=None):
        obj = {"id": "perf", "object": "chat.completion.chunk", "model": "perf-mock", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
        if usage: obj["usage"] = usage
        self.wfile.write(b"data: " + json.dumps(obj).encode() + b"\n\n"); self.wfile.flush()

    def text(self, s, cps):
        step, t0, sent = 24, time.time(), 0
        for i in range(0, len(s), step):
            self.chunk({"content": s[i:i + step]})
            sent += step
            lag = sent / cps - (time.time() - t0)
            if lag > 0: time.sleep(lag)
        self.chunk({}, "stop", {"prompt_tokens": 4000, "completion_tokens": len(s) // 4})
        self.wfile.write(b"data: [DONE]\n\n")

    def calls(self, calls):
        for j, (name, args) in enumerate(calls):
            self.chunk({"tool_calls": [{"index": j, "id": f"call_perf_{int(time.time() * 1000)}_{j}", "type": "function",
                                        "function": {"name": name, "arguments": json.dumps(args)}}]})
        self.chunk({}, "tool_calls", {"prompt_tokens": 4000, "completion_tokens": 60 * len(calls)})
        self.wfile.write(b"data: [DONE]\n\n")


def serve(port=0):
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("--port", type=int, default=0)
    s = serve(ap.parse_args().port)
    print("PORT", s.server_address[1], flush=True)
    try:
        while True: time.sleep(3600)
    except KeyboardInterrupt:
        pass
