// Sample lesson with every kind of tool card (running, finished, failed, waiting for approval, compact), for working on
// the transcript's look in a browser: open Resources/web/index.html from scripts/serve-web.py and evaluate this file.
(function () {
  const now = Date.now() / 1000;
  const use = (id, name, input) => ({ kind: 'toolUse', id, name, input });
  const res = (id, name, text, extra) => ({ id: 'r-' + id, role: 'user', blocks: [Object.assign({ kind: 'toolResult', id, name, text }, extra || {})] });
  const BT = '`';
  const prose = String.raw`## How recursion unwinds

A recursive function solves a problem by calling **itself** on a smaller piece of it. Every call waits on the stack until the one it made returns — then the stack *unwinds*.

1. Find the **base case**: the input small enough to answer directly.
2. Make the problem smaller on each call.
3. Combine the answers on the way back up.

~~~python
def factorial(n: int) -> int:
    if n <= 1:          # base case
        return 1
    return n * factorial(n - 1)
~~~

> [!TIP] Picture the stack
> Each call is a plate on a stack: the last one placed is the first one taken off.

| Call | Waits for | Returns |
|---|---|---|
| ${BT}factorial(3)${BT} | ${BT}factorial(2)${BT} | 6 |
| ${BT}factorial(2)${BT} | ${BT}factorial(1)${BT} | 2 |
| ${BT}factorial(1)${BT} | — | 1 |

The running time is $O(n)$, and so is the stack depth — which is why Python stops you at about 1000 calls.`;
  const plan = { title: 'Recursion from scratch', subject: 'Computer science', goal: 'Write and trace recursive functions with confidence.', modules: [
    { title: 'What a call stack is', status: 'done', objectives: ['Trace a call stack by hand'] },
    { title: 'Base cases and progress', status: 'in_progress', objectives: ['Spot a missing base case', 'Explain why each call must shrink the input'] },
    { title: 'Recursion vs. iteration', status: 'todo', objectives: ['Rewrite a loop recursively'] },
  ] };
  const msgs = [
    { id: 'u1', role: 'user', blocks: [{ kind: 'text', text: 'Can you explain recursion with a real example? Check my `fact.py` too.' }] },
    { id: 'a1', role: 'assistant', model: 'MiniMax-M3.1-Flash', blocks: [
      { kind: 'thinking', text: 'The learner wants recursion explained. I should look at their file first, then search for a good visual, and set up a plan.' },
      use('t-plan', 'lesson_plan', { action: 'create', title: plan.title }),
      use('t-mem', 'memory', { action: 'search', query: 'recursion prior knowledge' }),
      use('t-load', 'load_tools', { names: ['web_search', 'web_fetch'] }),
      use('t-search', 'web_search', { query: 'recursion call stack visualisation' }),
      use('t-fetch', 'web_fetch', { url: 'https://en.wikipedia.org/wiki/Recursion_(computer_science)' }),
      use('t-read', 'read', { path: 'src/fact.py' }),
      use('t-grep', 'grep', { pattern: 'def factorial', path: 'src' }),
      use('t-edit', 'edit', { path: 'src/fact.py', old_string: 'if n == 0:\n    return 0', new_string: 'if n <= 1:\n    return 1' }),
      use('t-tests', 'run_tests', { command: 'pytest -q' }),
      use('t-todo', 'todo_write', { todos: [{ content: 'Read the learner\'s file', status: 'completed' }, { content: 'Fix the base case', status: 'completed' }, { content: 'Explain the call stack', status: 'in_progress' }, { content: 'Quiz the learner', status: 'pending' }] }),
      use('t-mystery', 'quantum_lookup', { q: 42 }),
    ], metrics: { provider: 'minimax', model: 'MiniMax-M3.1-Flash', startedAt: now - 30, timeToFirstToken: 1.1, duration: 12, usage: { input: 3200, output: 900, cacheRead: 9000, cacheWrite: 0 }, finishReason: 'tool_use', toolCalls: 11 } },
    res('t-plan', 'lesson_plan', 'Plan created.', { meta: { plan } }),
    res('t-mem', 'memory', 'Found 2 memories.'),
    res('t-load', 'load_tools', 'Loaded.'),
    res('t-search', 'web_search', '3 results', { meta: { ms: 820, results: [
      { title: 'Recursion (computer science) — Wikipedia', url: 'https://en.wikipedia.org/wiki/Recursion_(computer_science)', snippet: 'In computer science, recursion is a method of solving a computational problem where the solution depends on solutions to smaller instances of the same problem.' },
      { title: 'Visualizing recursion with the call stack', url: 'https://pythontutor.com/visualize.html', snippet: 'Step through code and watch every frame appear and disappear.' },
    ] } }),
    res('t-fetch', 'web_fetch', 'Recursion occurs when the definition of a concept or process depends on a simpler or previous version of itself…', { meta: { title: 'Recursion (computer science)', ms: 1430 } }),
    res('t-read', 'read', '1\tdef factorial(n):\n2\t    if n == 0:\n3\t        return 0\n4\t    return n * factorial(n - 1)\n', { meta: { ms: 4 } }),
    res('t-grep', 'grep', 'src/fact.py:1:def factorial(n):', { meta: { ms: 31 } }),
    res('t-edit', 'edit', 'Edited src/fact.py (1 change).', { meta: { ms: 12 } }),
    res('t-tests', 'run_tests', '3 passed, 1 failed', { meta: { ms: 2100, passed: 3, total: 4, tests: [
      { name: 'test_base_case', passed: true, seconds: 0.01 }, { name: 'test_small', passed: true, seconds: 0.02 }, { name: 'test_large', passed: true, seconds: 0.4 },
      { name: 'test_negative', passed: false, seconds: 0.01, output: 'AssertionError: factorial(-1) should raise ValueError' }] } }),
    res('t-todo', 'todo_write', 'Updated.'),
    res('t-mystery', 'quantum_lookup', 'Error: the quantum service is unreachable (timeout after 30 s).', { isError: true }),
    { id: 'a2', role: 'assistant', model: 'MiniMax-M3.1-Flash', blocks: [{ kind: 'text', text: prose }, use('t-bash', 'bash', { command: 'python3 -c "import sys; print(sys.getrecursionlimit())"' })],
      metrics: { provider: 'minimax', model: 'MiniMax-M3.1-Flash', startedAt: now - 12, timeToFirstToken: 0.8, duration: 6, usage: { input: 600, output: 700, cacheRead: 12000, cacheWrite: 0 }, finishReason: 'tool_use', toolCalls: 1 } },
    res('t-bash', 'bash', '1000\n', { meta: { ms: 64 } }),
    { id: 'a3', role: 'assistant', model: 'MiniMax-M3.1-Flash', blocks: [{ kind: 'text', text: 'Python allows **1000** nested calls by default. Want to see what happens past it?' }],
      metrics: { provider: 'minimax', model: 'MiniMax-M3.1-Flash', startedAt: now - 4, timeToFirstToken: 0.6, duration: 1.8, usage: { input: 300, output: 60, cacheRead: 12500, cacheWrite: 0 }, finishReason: 'end_turn', toolCalls: 0 },
      turn: { startedAt: now - 30, duration: 26.4, timeToFirstToken: 1.1, steps: 3, tools: [{ name: 'web_search', duration: 0.8, ok: true }, { name: 'run_tests', duration: 2.1, ok: true }],
        usage: { input: 4100, output: 1660, cacheRead: 33500, cacheWrite: 0 }, generationSeconds: 14, memoriesRecalled: ['3'], memoryWrites: 0, languages: ['en'] } },
    { id: 'u2', role: 'user', blocks: [{ kind: 'text', text: 'Yes! Run it with 5000.' }] },
    { id: 'a4', role: 'assistant', model: 'MiniMax-M3.1-Flash', blocks: [{ kind: 'text', text: 'Running it now — this one needs your OK first.' }, use('t-approve', 'bash', { command: 'python3 deep.py --depth 5000' }), use('t-agent', 'task', { description: 'Find three recursion puzzles', prompt: 'Find three short recursion puzzles for a beginner.' })] },
  ];
  window.__toolsFixture = { msgs };
  T.reset(msgs, { showThinking: true, lesson: 'fixture-tools' });
  T.interaction({ id: 't-approve', kind: 'permission', payload: { title: 'Allow Teacher to run this command?', detail: 'python3 deep.py --depth 5000',
    options: [{ id: 'once', label: 'Allow once', style: 'primary' }, { id: 'lesson', label: 'Allow for this lesson' }, { id: 'deny', label: 'Deny', style: 'danger' }] } }, true);
  T.status('Searching for puzzles…', true);
})();
