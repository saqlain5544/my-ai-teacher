import Foundation

// Tools that show what code does, for the code mentor: a line-by-line trace (the page's stepper) and timings over
// growing inputs (a chart and a growth estimate). Both run real code, so the pictures are what the program does.

/// Steps through a Python program: every line, every frame's variables, shared objects marked, the output so far.
/// The learner gets the stepper card; the model gets the steps as changes, a few hundred tokens instead of the trace.
struct TraceTool: Tool {
    let name = "trace"
    let description = """
    Show how state changes as Python runs (aliasing, mutation, loops, recursion): the learner gets a stepper (each \
    line, every frame's variables, shared objects marked, output so far); you get the steps as changes. Steps into the lesson's own modules (`from shop import total`, \
    then call it), not libraries. Optional `stdin`, `max_steps` (default 200, max 1000).
    """
    let risk = ToolRisk.execute
    var schema: JSON {
        Schema.object([
            "code": Schema.string("Complete Python program (short: a trace is read step by step)."),
            "stdin": Schema.string("Optional standard input."),
            "max_steps": Schema.integer("Stop after this many steps (default 200, max 1000)."),
        ], required: ["code"])
    }
    func summary(_ input: JSON) -> String { "Python, step by step" }
    func timeout(_ input: JSON) -> Double? { 90 }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard let python = ProcessRunner.which("python3") else { throw ToolError("`python3` is not installed on this Mac.") }
        let (code, _) = HeredocSlip.strip(try input.req("code"))
        let steps = min(1000, max(1, input["max_steps"]?.int ?? 200))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiteacher-trace-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let main = dir.appendingPathComponent("main.py"), driver = dir.appendingPathComponent("trace.py")
        try Data(code.utf8).write(to: main)
        try Data(Self.driver.utf8).write(to: driver)
        let r = await ProcessRunner.run(python, ["-u", driver.path, main.path, String(steps)], cwd: ctx.workspace,
                                        stdin: input["stdin"]?.string, timeout: 60, outputLimit: 8_000_000)
        if r.timedOut { return .error("The trace timed out after 60 s (a loop waiting for input, or too slow to trace).") }
        guard let trace = CodeLab.marked(r.stdout) else {
            return .error("The tracer failed:\n" + truncateMiddle(r.combined, max: 4000))
        }
        var meta = trace
        let text = trace["summary"]?.string ?? "Traced."
        if case .object(var o) = meta { o["summary"] = nil; meta = .object(o) }
        return ToolOutput(text: text, isError: trace["error"]?.string != nil, meta: meta)
    }

    /// The tracer, run as `python3 trace.py main.py MAX` in the lesson's folder. It prints one marked JSON line on the real
    /// stdout: the files traced, the steps (short keys: f file, l line, e event, s stack, o output length, ret, exc), the
    /// program's output, and a summary for the model.
    static let driver = #"""
    import sys, os, io, json, types, traceback
    MAIN, MAX = sys.argv[1], int(sys.argv[2])
    ROOT, DRIVER = os.getcwd(), os.path.abspath(__file__)
    sys.path[0] = ROOT
    real_out = sys.stdout
    buf = io.StringIO()
    class Tee(io.TextIOBase):
        def write(self, s): buf.write(s); return len(s)
        def flush(self): pass
    files, steps, refs = {}, [], {}
    SKIP = ('/site-packages/', '/.venv/', '/venv/', '/node_modules/', '/.teacher/')
    def traced(fn):
        if fn == MAIN: return 'main.py'
        if fn == DRIVER: return None
        if fn.startswith(ROOT + os.sep) and not any(s in fn for s in SKIP) and fn.endswith('.py'):
            rel = os.path.relpath(fn, ROOT)
            if rel not in files:
                try: files[rel] = open(fn, encoding='utf-8').read()[:40000]
                except Exception: files[rel] = ''
            return rel
        return None
    def ref(v):
        i = id(v)
        if i not in refs: refs[i] = len(refs) + 1
        return refs[i]
    def show(v):
        if isinstance(v, types.FunctionType): return {'v': 'function ' + v.__name__, 't': 'function'}
        if isinstance(v, type): return {'v': 'class ' + v.__name__, 't': 'class'}
        try: r = repr(v)
        except Exception: r = '<' + type(v).__name__ + '>'
        if ' object at 0x' in r and isinstance(getattr(v, '__dict__', None), dict):   # P(x=5), not an address
            r = type(v).__name__ + '(' + ', '.join(k + '=' + show(x)['v'] for k, x in list(v.__dict__.items())[:6]) + ')'
        if len(r) > 60: r = r[:59] + '…'
        d = {'v': r, 't': type(v).__name__}
        if isinstance(v, (list, dict, set, bytearray)) or (hasattr(v, '__dict__') and type(v).__module__ in {'__main__'} | {m[:-3].replace(os.sep, '.') for m in files}):
            d['r'] = ref(v)
        return d
    def frame_vars(f):
        out = {}
        for k, v in list(f.f_locals.items()):
            if k.startswith('__') or isinstance(v, types.ModuleType): continue
            if len(out) >= 16: out['…'] = {'v': '+%d more' % (len(f.f_locals) - 16), 't': ''}; break
            out[k] = show(v)
        return out
    def stack(f):
        s = []
        while f is not None:
            name = traced(f.f_code.co_filename)
            if name:
                e = {'fn': f.f_code.co_name, 'f': name, 'l': f.f_lineno, 'v': frame_vars(f)}
                if not f.f_code.co_flags & 2 and e['fn'] != '<module>': e['b'] = 1   # a class body, not a call
                s.append(e)
            f = f.f_back
        return s[::-1][-8:]
    class Stop(BaseException): pass
    def tracer(frame, event, arg):
        name = traced(frame.f_code.co_filename)
        if not name: return None
        if event in ('line', 'return', 'exception'):
            if len(steps) >= MAX: raise Stop()
            st = {'f': name, 'l': frame.f_lineno, 'e': event, 's': stack(frame), 'o': len(buf.getvalue())}
            if event == 'return': st['ret'] = show(arg)
            if event == 'exception': st['exc'] = arg[0].__name__ + ': ' + str(arg[1])[:200]
            steps.append(st)
        return tracer
    src = open(MAIN, encoding='utf-8').read()
    files['main.py'] = src
    g = {'__name__': '__main__', '__builtins__': __builtins__}
    error, truncated = None, False
    sys.stdout = Tee()
    try:
        code = compile(src, MAIN, 'exec')
        sys.settrace(tracer)
        exec(code, g)
    except Stop:
        truncated = True
    except SystemExit:
        pass
    except SyntaxError as e:
        error = 'SyntaxError: %s (main.py:%s)' % (e.msg, e.lineno)
    except BaseException as e:
        tb = traceback.extract_tb(e.__traceback__)
        where = next((('main.py' if t.filename == MAIN else os.path.relpath(t.filename, ROOT)) + ':' + str(t.lineno) for t in reversed(tb) if traced(t.filename)), '')
        error = type(e).__name__ + ': ' + str(e)[:300] + (' (' + where + ')' if where else '')
    finally:
        sys.settrace(None)
        sys.stdout = real_out
    out = buf.getvalue()
    if not truncated:
        last = steps[-1]['l'] if steps else 1
        steps.append({'f': 'main.py', 'l': last, 'e': 'end', 's': [{'fn': '<module>', 'f': 'main.py', 'l': last, 'v': frame_vars(types.SimpleNamespace(f_locals=g))}], 'o': len(out)})
    # The model's view: one line per executed line, with its source and what it changed (calls and returns marked).
    def src(f, l):
        try: return files[f].splitlines()[l - 1].strip()[:48]
        except Exception: return ''
    def vals(d): return ', '.join(k + '=' + v['v'] for k, v in d.items() if v['t'] not in ('function', 'class'))
    lines, prev, printed = [], {}, 0
    for i, st in enumerate(steps, 1):
        top = st['s'][-1] if st['s'] else {'fn': '?', 'f': st['f'], 'l': st['l'], 'v': {}}
        key, body = (len(st['s']), top['fn']), top['fn'] == '<module>' or top.get('b')
        p, said = prev.get(key), []
        if p is not None:
            said = [k + '=' + v['v'] for k, v in top['v'].items() if p['v'].get(k, {}).get('v') != v['v'] and v['t'] not in ('function', 'class')]
        if st['o'] > printed: said.append('printed ' + json.dumps(out[printed:st['o']][:60])); printed = st['o']
        if st['e'] == 'end': lines.append('%d end: %s' % (i, vals(top['v']) or 'no variables')); continue
        if p is None and not body: lines.append('%d %s:%d → %s(%s)' % (i, st['f'], st['l'], top['fn'], vals(top['v'])))
        elif p is not None and (said or st['e'] != 'line'):
            what = ', '.join(said)
            if st['e'] == 'return' and not body: what = (what + '; ' if what else '') + '← ' + top['fn'] + ' returned ' + st['ret']['v']
            if st['e'] == 'exception': what = (what + '; ' if what else '') + 'raised ' + st['exc']
            if what: lines.append('%d %s:%d %s → %s' % (i, p['f'], p['l'], src(p['f'], p['l']), what))
        if st['e'] == 'return': prev.pop(key, None)
        else: prev[key] = {'v': top['v'], 'f': st['f'], 'l': st['l']}
    if len(lines) > 120: lines = lines[:60] + ['… %d steps …' % (len(lines) - 110)] + lines[-50:]
    summary = 'Traced %d steps%s (%s). The learner has the stepper.' % (len(steps), ' — stopped at the limit' if truncated else '', ', '.join(files))
    if error: summary += '\nError: ' + error
    summary += '\nOutput:\n' + (out[:1500] + ('…' if len(out) > 1500 else '') if out else '(none)')
    summary += '\nSteps (step, the line that ran → what it changed):\n' + '\n'.join(lines)
    real_out.write('\n@@CODELAB@@' + json.dumps({'files': files, 'steps': steps, 'output': out[:20000], 'error': error, 'truncated': truncated, 'summary': summary}) + '\n')
    """#
}

/// Times code over growing input sizes and fits the growth (O(1) … O(2ⁿ)): the learner sees the curves, the model a
/// table and the estimate. Several `run_*` variants make the classic comparison (list vs set membership) one call.
struct BenchTool: Tool {
    let name = "bench"
    let description = """
    Answer "which is faster?" and "how does it scale?" by measuring: times code over growing input sizes, charts it \
    for the learner and fits its growth (O(1) … O(2ⁿ)); you get the table. Python or JavaScript: `setup(n)` builds the \
    input, untimed (`setup_<name>(n)` for one variant's own input: the set for run_set); each `run_<name>(x)` is timed \
    and charted on its own line, so a comparison is one function per variant (`run_list(x)`, `run_set(x)`), never both \
    in one; a single `run(x)` when there is nothing to compare. Imports from the lesson's folder work. Optional `sizes` (default \
    [1000, 3000, 10000, 30000, 100000]).
    """
    let risk = ToolRisk.execute
    var schema: JSON {
        Schema.object([
            "language": Schema.string("python or javascript."),
            "code": Schema.string("e.g. `def setup(n): return list(range(n))` · `def setup_set(n): return set(range(n))` · `def run_list(xs): return -1 in xs` · `def run_set(s): return -1 in s`: inputs are built in setup, only the work is in run."),
            "sizes": Schema.array(Schema.integer("n"), "Input sizes, ascending (3–8 of them)."),
        ], required: ["language", "code"])
    }
    func summary(_ input: JSON) -> String { "\(input["language"]?.string ?? "code") timings" }
    func timeout(_ input: JSON) -> Double? { 150 }
    /// A hundredfold range: over less, a log factor and timing noise look alike.
    static let defaultSizes = [1000, 3000, 10000, 30000, 100000]

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let (code, _) = HeredocSlip.strip(try input.req("code"))
        let lang = RunCodeTool.normalize(try input.req("language"))
        var sizes = (input["sizes"]?.array ?? []).compactMap(\.int).filter { $0 > 0 }
        if sizes.count < 3 { sizes = Self.defaultSizes }
        sizes = Array(Set(sizes)).sorted().prefix(8).map { $0 }
        let r: ProcessResult
        switch lang {
        case "python":
            guard let python = ProcessRunner.which("python3") else { throw ToolError("`python3` is not installed on this Mac.") }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiteacher-bench-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let main = dir.appendingPathComponent("main.py"), driver = dir.appendingPathComponent("bench.py")
            try Data(code.utf8).write(to: main); try Data(Self.pythonDriver.utf8).write(to: driver)
            r = await ProcessRunner.run(python, ["-u", driver.path, main.path, sizes.map(String.init).joined(separator: ",")], cwd: ctx.workspace, timeout: 120)
        case "javascript":
            guard let node = ProcessRunner.which("node") else { throw ToolError("`node` is not installed on this Mac.") }
            let variants = Self.jsNames(code, "run")
            guard !variants.isEmpty else { return .error("Define `run(x)` (or `run_<name>(x)` variants) and `setup(n)` as functions.") }
            let program = code + "\n;" + Self.jsDriver(variants: variants, setups: Self.jsNames(code, "setup"), sizes: sizes)
            let module = !RunCodeTool.isCommonJS(code) && code.range(of: #"(?m)^\s*(import|export)\s"#, options: .regularExpression) != nil
            r = await ProcessRunner.run(node, module ? ["--input-type=module", "-e", program] : ["-e", program], cwd: ctx.workspace, timeout: 120)
        default:
            return .error("bench times Python or JavaScript; for other languages, time with `run_code`.")
        }
        if r.timedOut { return .error("The timings took over 120 s: use smaller sizes.") }
        guard let raw = CodeLab.marked(r.stdout) else { return .error("The timing run failed:\n" + truncateMiddle(r.combined, max: 4000)) }
        if let e = raw["error"]?.string { return .error(e) }
        let series = (raw["series"]?.array ?? []).compactMap { s -> CodeLab.Series? in
            guard let n = s["name"]?.string else { return nil }
            return CodeLab.Series(name: n, seconds: (s["times"]?.array ?? []).map(\.double))
        }
        guard !series.isEmpty else { return .error("Nothing was timed: define `run(x)` or `run_<name>(x)`.") }
        return CodeLab.benchOutput(sizes: sizes, series: series)
    }

    /// Top-level `function run…` / `const run… =` names (or `setup…`) in the code: the driver calls them by name.
    static func jsNames(_ code: String, _ prefix: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"(?m)^\s*(?:export\s+)?(?:async\s+)?(?:function\s*\*?\s*("# + prefix + #"(?:_\w+)?)\s*\(|(?:const|let|var)\s+("# + prefix + #"(?:_\w+)?)\s*=)"#)
        var out: [String] = []
        for m in re.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            for g in 1...2 where m.range(at: g).location != NSNotFound {
                let n = String(code[Range(m.range(at: g), in: code)!])
                if !out.contains(n) { out.append(n) }
            }
        }
        return out
    }

    static func jsDriver(variants: [String], setups: [String] = [], sizes: [Int]) -> String {
        func table(_ names: [String], _ drop: Int) -> String {
            names.map { "\"\($0.count == drop - 1 ? $0 : String($0.dropFirst(drop)))\": \($0)" }.joined(separator: ", ")
        }
        return """
        (() => {
          const runs = { \(table(variants, 4)) };
          const setups = { \(table(setups.filter { $0 != "setup" }, 6)) };
          const sizes = [\(sizes.map(String.init).joined(separator: ","))];
          const setupFor = name => setups[name] || (typeof setup === 'function' ? setup : null);
          const missing = Object.keys(runs).filter(n => !setupFor(n));
          if (missing.length) { console.log('\\n@@CODELAB@@' + JSON.stringify({ error: 'Define setup(n) (or setup_<name>(n) for ' + missing.join(', ') + '): it builds the input for size n.' })); return; }
          const series = [];
          for (const [name, fn] of Object.entries(runs)) {
            const setup = setupFor(name);
            const times = []; let spent = 0, stop = false;
            for (const n of sizes) {
              if (stop) { times.push(null); continue; }
              let best = Infinity, total = 0, reps = 0;
              while (reps < 5 && (reps < 2 || total < 0.05)) {
                const x = setup(n); const t0 = performance.now(); fn(x); const dt = (performance.now() - t0) / 1000;
                best = Math.min(best, dt); total += dt; reps++;
                if (dt > 2) break;
              }
              times.push(best); spent += total;
              if (best > 2 || spent > 20) stop = true;
            }
            series.push({ name, times });
          }
          console.log('\\n@@CODELAB@@' + JSON.stringify({ series }));
        })();
        """
    }

    static let pythonDriver = #"""
    import sys, os, time, json, runpy
    MAIN, SIZES = sys.argv[1], [int(s) for s in sys.argv[2].split(',')]
    sys.path[0] = os.getcwd()
    def done(d): print('\n@@CODELAB@@' + json.dumps(d))
    ns = runpy.run_path(MAIN, run_name='__bench__')
    setup = ns.get('setup')
    runs = {('run' if k == 'run' else k[4:]): v for k, v in ns.items() if (k == 'run' or k.startswith('run_')) and callable(v)}
    setups = {k[6:]: v for k, v in ns.items() if k.startswith('setup_') and callable(v)}
    missing = [n for n in runs if not callable(setups.get(n, setup))]
    if missing: done({'error': 'Define setup(n) (or setup_<name>(n) for %s): it builds the input for size n.' % ', '.join(missing)}); sys.exit()
    series = []
    for name, fn in runs.items():
        setup_n = setups.get(name, setup)
        times, spent, stop = [], 0.0, False
        for n in SIZES:
            if stop: times.append(None); continue
            best, total, reps = float('inf'), 0.0, 0
            while reps < 5 and (reps < 2 or total < 0.05):
                x = setup_n(n); t0 = time.perf_counter(); fn(x); dt = time.perf_counter() - t0
                best = min(best, dt); total += dt; reps += 1
                if dt > 2: break
            times.append(best); spent += total
            if best > 2 or spent > 20: stop = True
        series.append({'name': name, 'times': times})
    done({'series': series})
    """#
}

enum CodeLab {
    /// The JSON a driver printed after its marker (the last one: the program's own output comes before it).
    static func marked(_ stdout: String) -> JSON? {
        guard let r = stdout.range(of: "@@CODELAB@@", options: .backwards) else { return nil }
        let line = stdout[r.upperBound...].split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return JSON.parse(line)
    }

    struct Series { var name: String; var seconds: [Double?] }

    /// Growth models, as log g(n) (2ⁿ in log space, so it never overflows).
    static let models: [(String, (Double) -> Double)] = [
        ("O(1)", { _ in 0 }), ("O(log n)", { log(log($0)) }), ("O(n)", { log($0) }), ("O(n log n)", { log($0) + log(log($0)) }),
        ("O(n²)", { 2 * log($0) }), ("O(n³)", { 3 * log($0) }), ("O(2ⁿ)", { $0 * log(2) }),
    ]

    /// The simplest model whose shape fits the timings about as well as the best one (least squares in log space, the
    /// constant free; "about" = within timing noise, so a flat O(1) isn't called O(log n)), and the log-log slope. nil
    /// below three timed sizes. Times under a microsecond are noise and count as one.
    static func fit(sizes: [Int], seconds: [Double?]) -> (model: String, exponent: Double)? {
        let pts = zip(sizes, seconds).compactMap { n, t in t.map { (log(Double(max(n, 2))), Double(max(n, 2)), log(max($0, 1e-6))) } }
        guard pts.count >= 3 else { return nil }
        let mx = pts.map(\.0).reduce(0, +) / Double(pts.count), my = pts.map(\.2).reduce(0, +) / Double(pts.count)
        let sxx = pts.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +), sxy = pts.map { ($0.0 - mx) * ($0.2 - my) }.reduce(0, +)
        let slope = sxx > 0 ? sxy / sxx : 0
        let r = models.map { residual(pts, $0.1) }, tolerance = 0.02 * Double(pts.count)
        let pick = r.firstIndex { $0 <= r.min()! + tolerance }!
        return (models[pick].0, slope)
    }

    private static func residual(_ pts: [(Double, Double, Double)], _ g: (Double) -> Double) -> Double {
        let d = pts.map { $0.2 - g($0.1) }
        let c = d.reduce(0, +) / Double(d.count)
        return d.map { ($0 - c) * ($0 - c) }.reduce(0, +)
    }

    static func ms(_ s: Double?) -> String {
        guard let s else { return "—" }
        let v = s * 1000
        return v >= 100 ? String(format: "%.0f", v) : v >= 1 ? String(format: "%.2f", v) : String(format: "%.4f", v)
    }

    static func benchOutput(sizes: [Int], series: [Series]) -> ToolOutput {
        let fits = series.map { fit(sizes: sizes, seconds: $0.seconds) }
        let width = max(8, series.map(\.name.count).max() ?? 0) + 2
        func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s + " " : s + String(repeating: " ", count: w - s.count) }
        var text = "Timings (best of up to 5 runs, ms; — = skipped after a slow size):\n" + pad("n", 10) + series.map { pad($0.name, width) }.joined() + "\n"
        for (i, n) in sizes.enumerated() {
            text += pad(String(n), 10) + series.map { pad(ms($0.seconds[safe: i] ?? nil), width) }.joined() + "\n"
        }
        text += "Growth: " + zip(series, fits).map { s, f in
            f.map { "\(s.name) ≈ \($0.model) (log-log slope \(String(format: "%.2f", $0.exponent)))" } ?? "\(s.name): too few sizes timed"
        }.joined(separator: "; ") + ". Timings are noisy below ~0.01 ms. The learner has the chart: it is the evidence, explain what it shows."
        let meta: JSON = ["sizes": .array(sizes.map { .number(Double($0)) }),
                          "series": .array(zip(series, fits).map { s, f in
                              ["name": .string(s.name), "times": .array(s.seconds.map { $0.map(JSON.number) ?? .null }),
                               "fit": f.map { .string($0.model) } ?? .null, "slope": f.map { .number(($0.exponent * 100).rounded() / 100) } ?? .null]
                          })]
        return ToolOutput(text: text, meta: meta)
    }
}
