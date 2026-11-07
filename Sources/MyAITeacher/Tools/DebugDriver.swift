import Foundation

/// The program lldb's own Python (the SB API) runs for the `debug` tool: one process per debugging session that reads one
/// JSON command per line on stdin and answers with one `@@DBG@@{json}` line on stdout. Structured values (types, children,
/// frames, line entries) come from the API instead of scraping `frame variable`'s text, and a second thread can interrupt a
/// running program, which `lldb --batch` cannot do. The inferior's own output goes to files, never to the protocol.
/// Every bound is applied here (variables, children, string length, frames), so a huge array or a deep recursion can't
/// make a reply large; the Swift side enforces the wall time on top.
enum DebugDriver {
    static let source = #"""
    import sys, os, json, re, time, threading
    sys.path.insert(0, sys.argv[1])
    import lldb

    PROTO = sys.stdout
    def send(d):
        PROTO.write('@@DBG@@' + json.dumps(d) + '\n'); PROTO.flush()

    SYSTEM = ('/usr/', '/System/', '/Library/', '/Applications/Xcode', '/AppleInternal/', '/private/var/db/', '/rustc/', '/opt/homebrew/Cellar/',
              '/Applications/', '/usr/local/Cellar/')
    TOOLCHAIN = ('/.cargo/registry/', '/.rustup/', '/.cargo/git/', '/.build/checkouts/', '/lib/zig/', '/usr/local/go/', '/.local/zig/')
    MAX_VARS, MAX_KIDS, MAX_STR, MAX_DEPTH, MAX_FRAMES, MAX_USER_FRAMES = 24, 8, 100, 2, 12, 5
    MAX_OUTPUT = 4000000   # bytes the program may write to stdout and stderr together

    dbg = lldb.SBDebugger.Create()
    dbg.SkipLLDBInitFiles(True)
    dbg.SetAsync(False)
    dbg.HandleCommand('settings set target.process.thread.max-backtrace-depth 3000')
    S = {'target': None, 'process': None, 'timer_fired': False, 'output_limit': False, 'out': None, 'err': None, 'out_off': 0, 'err_off': 0,
         'files': {}, 'refs': {}, 'root': os.path.realpath(os.getcwd()), 'deadline': 0.0, 'src': {}, 'tmp': []}

    def clip(s, n=MAX_STR):
        s = '' if s is None else str(s)
        return s if len(s) <= n else s[:n - 1] + '…'

    def user_path(p):
        if not p: return False
        try: rp = os.path.realpath(p)
        except Exception: return False
        if not os.path.exists(rp): return False
        if rp.startswith(S['root'] + os.sep): return not any(t in rp for t in TOOLCHAIN) and '/.teacher/' not in rp
        return not rp.startswith(SYSTEM) and not any(t in rp for t in TOOLCHAIN)

    def display(p):
        rp = os.path.realpath(p)
        if rp.startswith(S['root'] + os.sep): return rp[len(S['root']) + 1:]
        parts = rp.split(os.sep)
        return os.sep.join(parts[-2:])

    def source_of(p):
        name = display(p)
        if name not in S['files']:
            try: txt = open(p, encoding='utf-8', errors='replace').read()[:40000]
            except Exception: txt = ''
            if len(S['files']) < 8: S['files'][name] = txt
            S['src'][name] = txt.splitlines()
        return name, S['src'].get(name, [])

    def ref(addr):
        r = S['refs']
        if addr not in r: r[addr] = len(r) + 1
        return r[addr]

    # ── values ────────────────────────────────────────────────────────────
    def text_of(v, depth):
        """One line for a value: its summary (strings), pointer + pointee, {fields}, [elements], or the scalar."""
        if v is None or not v.IsValid(): return '?'
        if v.GetError().Fail(): return '<' + clip(v.GetError().GetCString() or 'unavailable', 40) + '>'
        t = v.GetType()
        summ = v.GetSummary()
        if t.IsPointerType():
            s = v.GetValue() or '?'
            if summ: return clip(s + ' ' + summ)
            addr = v.GetValueAsUnsigned()
            if addr and depth < MAX_DEPTH and not t.GetPointeeType().IsFunctionType() and t.GetPointeeType().GetBasicType() != lldb.eBasicTypeVoid:
                d = v.Dereference()
                if d.IsValid() and d.GetError().Success() and d.GetNumChildren() > 0: return clip(s + ' → ' + text_of(d, depth + 1), 160)
            return s
        if summ and not (t.IsArrayType() and not summ): return clip(summ)
        n = v.GetNumChildren()
        if n and depth < MAX_DEPTH + 1:
            kids = []
            for i in range(min(n, MAX_KIDS)):
                c = v.GetChildAtIndex(i)
                kids.append(text_of(c, depth + 1) if t.IsArrayType() else (c.GetName() or str(i)) + '=' + text_of(c, depth + 1))
            more = ', … (%d in all)' % n if n > MAX_KIDS else ''
            return clip(('[' if t.IsArrayType() else '{') + ', '.join(kids) + more + (']' if t.IsArrayType() else '}'), 200)
        return clip(v.GetValue() if v.GetValue() is not None else v.GetObjectDescription() or '')

    def var(v):
        d = {'v': text_of(v, 0), 't': clip(v.GetTypeName() or '', 40)}
        if v.GetType().IsPointerType():
            a = v.GetValueAsUnsigned()
            if a: d['r'] = ref(a)
        return d

    def locals_of(frame, limit=MAX_VARS):
        out, names = {}, 0
        try: vs = frame.GetVariables(True, True, False, True)
        except Exception: return out
        total = vs.GetSize()
        for i in range(total):
            v = vs.GetValueAtIndex(i)
            nm = v.GetName()
            if not nm or nm.startswith('$'): continue
            if len(out) >= limit: out['…'] = {'v': '+%d more' % (total - i), 't': ''}; break
            try: out[nm] = var(v)
            except Exception as e: out[nm] = {'v': '<%s>' % clip(e, 30), 't': ''}
        return out

    def frame_name(fr):
        n = None
        try: n = fr.GetDisplayFunctionName()
        except Exception: pass
        return n or fr.GetFunctionName() or (fr.GetSymbol().GetName() if fr.GetSymbol().IsValid() else None) or '?'

    def frame_path(fr):
        le = fr.GetLineEntry()
        if not le.IsValid(): return None, 0
        fs = le.GetFileSpec()
        return (fs.fullpath if fs.IsValid() else None), le.GetLine()

    def frame_record(fr, with_locals, limit=MAX_VARS):
        p, line = frame_path(fr)
        user = user_path(p)
        d = {'i': fr.GetFrameID(), 'fn': clip(frame_name(fr), 80), 'l': line, 'user': user}
        if user:
            name, lines = source_of(p)
            d['f'] = name
            d['src'] = clip(lines[line - 1].strip(), 120) if 0 < line <= len(lines) else ''
            if with_locals: d['v'] = locals_of(fr, limit); d['vo'] = list(d['v'].keys())
        elif with_locals:
            d['v'] = {}
        return d

    # ── stops ─────────────────────────────────────────────────────────────
    def read_new(kind):
        path, off = S[kind], S[kind + '_off']
        if not path: return ''
        try:
            with open(path, 'rb') as f:
                f.seek(off); data = f.read(200000)
            S[kind + '_off'] = off + len(data)
            return data.decode('utf-8', 'replace')
        except Exception: return ''

    def pick_thread(p):
        best = None
        for t in p:
            r = t.GetStopReason()
            if r not in (lldb.eStopReasonNone, lldb.eStopReasonInvalid):
                best = t; break
        if best is None: best = p.GetSelectedThread()
        if best is not None and best.IsValid(): p.SetSelectedThread(best)
        return best

    def report(deep=False, selected_only=False):
        """The current state as a stop record, or an exit record."""
        p = S['process']
        r = {'out': read_new('out'), 'err': read_new('err'), 'pid': p.GetProcessID() if p and p.IsValid() else 0}
        st = p.GetState() if p and p.IsValid() else lldb.eStateInvalid
        if st == lldb.eStateExited:
            r['exited'] = p.GetExitStatus(); r['desc'] = p.GetExitDescription() or ''
            return r
        if st == lldb.eStateDetached or st == lldb.eStateInvalid or st == lldb.eStateUnloaded:
            r['exited'] = -1; r['desc'] = 'the process is gone'
            return r
        if st != lldb.eStateStopped and st != lldb.eStateCrashed:
            r['running'] = True
            return r
        th = pick_thread(p)
        reason = th.GetStopReason()
        r['kind'] = {3: 'breakpoint', 5: 'signal', 6: 'exception', 8: 'step', 4: 'watchpoint'}.get(reason, 'other')
        if S['timer_fired']: r['kind'] = 'timeout'
        if S['output_limit']: r['kind'] = 'outputlimit'
        r['desc'] = clip(th.GetStopDescription(256), 200)
        if reason == lldb.eStopReasonSignal: r['signo'] = th.GetStopReasonDataAtIndex(0)
        if reason == lldb.eStopReasonException:
            r['exc_data'] = [th.GetStopReasonDataAtIndex(i) for i in range(min(th.GetStopReasonDataCount(), 4))]
        if reason == lldb.eStopReasonBreakpoint and th.GetStopReasonDataCount() >= 1:
            r['bp'] = th.GetStopReasonDataAtIndex(0)
        n = th.GetNumFrames()
        r['depth'] = n
        sel = th.GetSelectedFrame().GetFrameID()
        r['selected'] = sel
        frames, user_seen = [], 0
        for i in range(min(n, 3000)):
            if len(frames) >= MAX_FRAMES: break
            fr = th.GetFrameAtIndex(i)
            if not fr.IsValid(): break
            u = user_path(frame_path(fr)[0])
            if u: user_seen += 1
            if not (i == 0 or i == sel or u): continue
            lim = MAX_USER_FRAMES if deep else 3
            frames.append(frame_record(fr, with_locals=(i == sel or (u and user_seen <= lim)), limit=MAX_VARS if i == sel else 12))
        if not any(f['i'] == sel for f in frames):   # a frame the learner chose, however deep, is never swapped for another
            fr = th.GetFrameAtIndex(sel)
            if fr.IsValid(): frames.append(frame_record(fr, with_locals=True))
        r['frames'] = frames; r['hidden'] = max(0, n - len(frames))
        r['sp'] = th.GetFrameAtIndex(0).GetSP(); r['pc'] = th.GetFrameAtIndex(0).GetPC()
        ret = th.GetStopReturnValue() if reason == lldb.eStopReasonPlanComplete else None
        if ret is not None and ret.IsValid() and ret.GetError().Success(): r['ret'] = var(ret)
        return r

    def resume(fn, seconds):
        """Runs `fn` (a continue or a step) and interrupts the program when the wall time is up."""
        p = S['process']; S['timer_fired'] = False; S['output_limit'] = False
        done = threading.Event()
        def fire():
            S['timer_fired'] = True
            try: p.SendAsyncInterrupt()
            except Exception: pass
        def watch():
            while not done.wait(0.25):
                size = sum(os.path.getsize(f) for f in (S['out'], S['err']) if f and os.path.exists(f))
                if size > MAX_OUTPUT:
                    S['output_limit'] = True
                    try: p.SendAsyncInterrupt()
                    except Exception: pass
                    return
        t = threading.Timer(max(0.2, seconds), fire); t.daemon = True; t.start()
        w = threading.Thread(target=watch, daemon=True); w.start()
        try: fn()
        finally: t.cancel(); done.set()
        if S['timer_fired'] and p.GetState() == lldb.eStateRunning:
            time.sleep(1)

    # ── commands ──────────────────────────────────────────────────────────
    def inspect_target(program, cwd):
        err = lldb.SBError()
        target = dbg.CreateTarget(program, None, None, True, err)
        if err.Fail() or not target.IsValid(): return None, 'Could not open ' + program + ': ' + (err.GetCString() or 'not an executable')
        return target, None

    def has_debug_info(target):
        cus, user_cus = 0, 0
        for m in target.module_iter():
            fs = m.GetFileSpec()
            if fs.IsValid() and fs.fullpath and (fs.fullpath.startswith('/usr/lib') or fs.fullpath.startswith('/System')): continue
            n = m.GetNumCompileUnits()
            cus += n
            for i in range(min(n, 200)):
                cu = m.GetCompileUnitAtIndex(i)
                f = cu.GetFileSpec()
                if f.IsValid() and user_path(f.fullpath.split('/@/')[0]): user_cus += 1   # Rust names a unit `file.rs/@/crate.cgu`
        return cus, user_cus

    def cmd_inspect(c):
        target, e = inspect_target(c['program'], c.get('cwd'))
        if e: return {'ok': False, 'error': e}
        cus, user = has_debug_info(target)
        dbg.DeleteTarget(target)
        return {'ok': True, 'compile_units': cus, 'user_units': user}

    def breakpoint_spec(target, b):
        spec, cond = (b, None) if isinstance(b, str) else (b.get('at') or b.get('spec') or '', b.get('condition'))
        m = re.match(r'^(.+?):(\d+)$', spec.strip())
        bp = target.BreakpointCreateByLocation(m.group(1), int(m.group(2))) if m else target.BreakpointCreateByName(spec.strip())
        if cond: bp.SetCondition(str(cond))
        info = {'spec': spec, 'locations': bp.GetNumLocations(), 'id': bp.GetID()}
        if bp.GetNumLocations():
            a = bp.GetLocationAtIndex(0).GetAddress().GetLineEntry()
            if a.IsValid(): info['line'] = a.GetLine()
        return info

    def cmd_start(c):
        if S['process']: return {'ok': False, 'error': 'a program is already being debugged'}
        target, e = inspect_target(c['program'], c.get('cwd'))
        if e: return {'ok': False, 'error': e}
        S['target'] = target
        cus, user = has_debug_info(target)
        if user == 0:
            return {'ok': False, 'nodebug': True, 'compile_units': cus, 'error': 'no debug info'}
        bps = [breakpoint_spec(target, b) for b in c.get('breakpoints', [])]
        if c.get('panics'):   # Rust panics exit with 101 and no signal: stop where they start
            for name in ('rust_panic', 'rust_begin_unwind'):
                b = target.BreakpointCreateByName(name)
                bps.append({'spec': name, 'locations': b.GetNumLocations(), 'id': b.GetID(), 'panic': True})
        if c.get('entry'):
            b = target.BreakpointCreateByName('main')
            ok = b.GetNumLocations() > 0 and b.GetLocationAtIndex(0).GetAddress().GetLineEntry().IsValid()
            if not ok:
                target.BreakpointDelete(b.GetID())
                b = target.BreakpointCreateByRegex(r'::main$')
            bps.append({'spec': 'main', 'locations': b.GetNumLocations(), 'id': b.GetID(), 'entry': True})
        d = c['tmp']
        S['out'], S['err'] = os.path.join(d, 'stdout.txt'), os.path.join(d, 'stderr.txt')
        for f in (S['out'], S['err']): open(f, 'wb').close()
        li = lldb.SBLaunchInfo(c.get('args') or [])
        if c.get('cwd'): li.SetWorkingDirectory(c['cwd'])
        if c.get('env'): li.SetEnvironmentEntries([k + '=' + v for k, v in c['env'].items()], True)
        li.SetLaunchFlags(li.GetLaunchFlags() | lldb.eLaunchFlagStopAtEntry)   # so the wall-time timer covers a loop that never stops
        li.AddOpenFileAction(0, c.get('stdin') or '/dev/null', True, False)
        li.AddOpenFileAction(1, S['out'], False, True)
        li.AddOpenFileAction(2, S['err'], False, True)
        err = lldb.SBError()
        S['deadline'] = time.time() + c.get('seconds', 20)
        S['process'] = target.Launch(li, err)
        if err.Fail() or not S['process'].IsValid():
            S['process'] = None
            return {'ok': False, 'error': 'launch failed: ' + (err.GetCString() or '?'), 'breakpoints': bps}
        pass_signals()
        resume(S['process'].Continue, c.get('seconds', 20))
        r = report(c.get('deep', False)); r['ok'] = True; r['breakpoints'] = bps
        return r

    def pass_signals():
        """Only crashes stop the program: SIGUSR1, SIGINT, SIGPIPE and the rest a program raises on purpose are delivered to it."""
        keep = ('SIGSEGV', 'SIGBUS', 'SIGILL', 'SIGFPE', 'SIGABRT', 'SIGTRAP', 'SIGKILL', 'SIGSTOP')
        us = S['process'].GetUnixSignals()
        for i in range(us.GetNumSignals()):
            n = us.GetSignalAtIndex(i)
            if us.GetSignalAsCString(n) in keep: continue
            us.SetShouldStop(n, False); us.SetShouldNotify(n, False); us.SetShouldSuppress(n, False)

    def need_process():
        p = S['process']
        if not p or not p.IsValid() or p.GetState() in (lldb.eStateExited, lldb.eStateDetached):
            raise RuntimeError('the program is not running (it exited or was never started)')
        return p

    def cmd_continue(c):
        p = need_process(); resume(p.Continue, c.get('seconds', 20))
        r = report(c.get('deep', False)); r['ok'] = True; return r

    def stepper(kind):
        def run(c):
            p = need_process(); th = p.GetSelectedThread()
            fn = {'step': th.StepInto, 'next': th.StepOver, 'finish': th.StepOut}[kind]
            resume(fn, c.get('seconds', 20))
            r = report(c.get('deep', False)); r['ok'] = True; return r
        return run

    def cmd_print(c):
        p = need_process(); th = p.GetSelectedThread(); fr = th.GetSelectedFrame()
        expr = c['expr']
        v = None
        if re.match(r'^[A-Za-z_][\w]*([.\[\]\w]|->|\*)*$', expr.strip()):
            v = fr.GetValueForVariablePath(expr.strip())
            if v is not None and (not v.IsValid() or v.GetError().Fail()): v = None
        if v is None:
            o = lldb.SBExpressionOptions(); o.SetTimeoutInMicroSeconds(3000000); o.SetUnwindOnError(True); o.SetTryAllThreads(False)
            v = fr.EvaluateExpression(expr, o)
        if v is None or not v.IsValid() or v.GetError().Fail():
            return {'ok': False, 'error': clip(v.GetError().GetCString() if v is not None else 'cannot evaluate', 300)}
        d = var(v); d['ok'] = True; d['expr'] = expr; return d

    def cmd_frame(c):
        p = need_process(); th = p.GetSelectedThread()
        i = int(c.get('index', 0))
        if i < 0 or i >= th.GetNumFrames(): return {'ok': False, 'error': 'no frame %d (the stack has %d frames)' % (i, th.GetNumFrames())}
        th.SetSelectedFrame(i)
        r = report(False); r['ok'] = True; return r

    def cmd_stop(c):
        p = S['process']
        if p and p.IsValid():
            try: p.Kill()
            except Exception: pass
        return {'ok': True, 'bye': True}

    H = {'inspect': cmd_inspect, 'start': cmd_start, 'continue': cmd_continue, 'step': stepper('step'), 'next': stepper('next'),
         'finish': stepper('finish'), 'print': cmd_print, 'frame': cmd_frame, 'stop': cmd_stop}

    send({'ok': True, 'ready': True, 'version': lldb.SBDebugger.GetVersionString().splitlines()[0]})
    for line in sys.stdin:
        c = None
        try:
            c = json.loads(line)
            r = H[c['cmd']](c)
            r['files'] = S['files']
        except Exception as e:
            r = {'ok': False, 'error': '%s: %s' % (type(e).__name__, clip(e, 300))}
        r['id'] = c.get('id') if isinstance(c, dict) else None
        send(r)
        if r.get('bye'): break
    p = S['process']
    if p and p.IsValid():
        try: p.Kill()
        except Exception: pass
    lldb.SBDebugger.Destroy(dbg)
    """#
}
