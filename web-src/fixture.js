// Sample transcript for testing the renderer in a browser: paste into the console, or evaluate via automation.
(function () {
  const now = Date.now() / 1000;
  const text = String.raw`## Arabic greetings 👋

In Arabic, the most common greeting is <span lang="ar">السلام عليكم</span> (*as-salāmu ʿalaykum*), which means "peace be upon you". The reply is وعليكم السلام.

> [!TIP] Pronunciation
> The ع sound comes from the throat — practise it slowly.

| Arabic | Transliteration | Meaning |
|---|---|---|
| مرحبا | marḥaban | hello |
| شكرا | shukran | thank you |
| صباح الخير | ṣabāḥ al-khayr | good morning |

~~~vocab
[{"term":"مرحبا","lang":"ar","reading":"marḥaban","meaning":"hello","example":"مرحبا يا صديقي","example_meaning":"Hello, my friend"},
 {"term":"شكرا","lang":"ar","reading":"shukran","meaning":"thank you"}]
~~~

مرحبا بك في الدرس الأول. سنتعلم اليوم التحيات الأساسية.

Japanese: <ruby>漢字<rt>かんじ</rt></ruby> means "kanji", and こんにちは is hello.

The quadratic formula: $x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}$

~~~chart
{"type":"bar","title":"Words learned","labels":["Mon","Tue","Wed","Thu"],"series":[{"name":"Arabic","data":[5,8,6,10]},{"name":"Spanish","data":[3,4,7,6]}]}
~~~

~~~timeline
[{"date":"610","title":"Revelation begins","text":"Classical Arabic standardised"},{"date":"1928","title":"Arabic script reform debates"}]
~~~

~~~steps
[{"title":"Listen","text":"Hear the word twice."},{"title":"Repeat","text":"Say it aloud."},{"title":"Use it","text":"Make a sentence."}]
~~~

~~~chart
{"type":"pie","title":"Study time","labels":["Reading","Speaking","Writing"],"series":[{"data":[40,35,25]}]}
~~~`;
  const quizInput = {
    title: 'Check your greetings', subject: 'arabic', questions: [
      { type: 'single_choice', prompt: 'What does <span lang="ar">شكرا</span> mean?', options: ['Hello', 'Thank you', 'Goodbye'], concept: 'vocabulary' },
      { type: 'true_false', prompt: 'مرحبا means "hello".' },
      { type: 'fill_blanks', prompt: 'Complete:', text: 'The reply to السلام عليكم is {{}} السلام.' },
      { type: 'ordering', prompt: 'Order the steps of learning a word', items: ['Listen', 'Repeat', 'Use it'] },
      { type: 'matching', prompt: 'Match', pairs: [['مرحبا', 'hello'], ['شكرا', 'thank you'], ['صباح الخير', 'good morning']] },
      { type: 'math', prompt: 'Simplify $2x + 3x$' },
      { type: 'scale', prompt: 'How confident are you?', labels: ['Not at all', 'Very'] },
      { type: 'drawing', prompt: 'Write the letter ب' },
      { type: 'code', prompt: 'Print hello in Python', language: 'python', starter: 'print()' },
    ],
  };
  const turn = { startedAt: now - 9, duration: 8.4, timeToFirstToken: 1.3, steps: 2, tools: [{ name: 'quiz', duration: 4.2, ok: true, waitedForLearner: 3.9 }, { name: 'memory_save', duration: 0.02, ok: true }],
    usage: { input: 1200, output: 860, cacheRead: 9300, cacheWrite: 0, reasoningTokens: 210 }, generationSeconds: 5, memoriesRecalled: ['3'], memoryWrites: 1, languages: ['en', 'ar', 'ja'] };
  const msgs = [
    { id: 'u1', role: 'user', blocks: [{ kind: 'text', text: 'Teach me Arabic greetings', meta: {} }], meta: { recalled: [{ id: '3', kind: 'goal', content: 'Learner is learning Arabic for a trip', score: 0.71 }] } },
    { id: 'a1', role: 'assistant', model: 'MiniMax-M3', blocks: [{ kind: 'thinking', text: 'The learner wants greetings…' }, { kind: 'text', text }, { kind: 'toolUse', id: 't1', name: 'quiz', input: quizInput }],
      metrics: { provider: 'minimax', model: 'MiniMax-M3', startedAt: now - 9, timeToFirstToken: 1.3, duration: 4.0, usage: { input: 600, output: 700, cacheRead: 4600, cacheWrite: 0 }, finishReason: 'tool_use', toolCalls: 1 } },
    { id: 'a2', role: 'assistant', model: 'MiniMax-M3', blocks: [{ kind: 'text', text: 'Great work! Try the quiz above.' }],
      metrics: { provider: 'minimax', model: 'MiniMax-M3', startedAt: now - 3, timeToFirstToken: 0.9, duration: 2.1, usage: { input: 600, output: 160, cacheRead: 4700, cacheWrite: 0 }, finishReason: 'end_turn', toolCalls: 0 }, turn },
  ];
  window.__fixture = { msgs, quizInput };
  T.reset(msgs, { showThinking: true });
  T.interaction({ id: 't1', kind: 'quiz', payload: { title: quizInput.title, questions: quizInput.questions } }, true);
})();
