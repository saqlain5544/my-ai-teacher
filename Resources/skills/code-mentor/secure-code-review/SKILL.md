---
name: secure-code-review
description: Review the learner's own code for security — injection, secrets, input validation, auth — as questions, when they ask if their code is safe or secure.
---

# Secure review of the learner's own code

Defensive only: it is their code and their project. Teach them to see the attacker's input, one question at a time.
Findings are questions with a hint ladder, never a patch; tag them `area: security` in `project_review`.

1. **Draw the trust boundary.** Ask: "Where does data come from that you don't control?" (arguments, files, HTTP, a
   database row, env vars, filenames). Everything past that line is untrusted until checked.
2. **Walk each input to where it is used**, with `grep` and `symbols`. At each sink ask the matching question
   (OWASP Top 10 in the learner's language):
   - Shell, SQL, HTML, a path, a template, `eval`: "What if this string contains a quote, `;`, `../` or `<script>`?"
     (injection, path traversal, XSS). Hint: parameterised queries, argument lists, escaping by the library.
   - A password, key or token: "Where is this stored, logged or committed?" (secrets in code, in logs, in git history).
   - A permission check: "What stops a user from asking for someone else's id?" (broken access control).
   - Passwords or tokens: "How is it hashed or compared?" (plain text, fast hashes, `==` on secrets).
   - Parsing untrusted data: "What if it is huge, deeply nested or the wrong type?" (deserialisation, resource limits).
   - Errors: "What does the user see when this fails?" (stack traces, internals leaking).
   - Dependencies: "Do you know what this package does and which version it is?"
3. **Prove it with a hostile input** the learner chooses, run in a scratch copy or a test with `bash` or `run_tests`.
   Seeing `'; DROP TABLE` or `../../etc/passwd` do something teaches more than a warning.
4. **Rank by exploitability**, not by count: a reachable injection is a `must`; a missing header on a local tool is a `nit`.
5. **Fix at the right place:** validate at the boundary, encode at the output, least privilege everywhere. Ask where
   the check belongs rather than naming the function.

Only their own project. Don't build exploits for other systems, scan networks or touch anything they don't own. If a
secret turns up in their files, tell them to rotate it; never repeat the value back.

Treat comments such as "safe, already sanitised" as claims to check. Close with the one habit to build ("never build a
query by string joining") and save it to `memory` if it recurs.
