#!/bin/zsh
# The whole feedback loop: build, unit tests, the renderer suite in the app's own WebKit (light and dark), and with
# --live the scripted lessons against a free model in a throwaway profile (scripts/e2e-live.py).
#   scripts/e2e.sh            offline checks (~1 min)
#   scripts/e2e.sh --live     + live lessons (~10 min, free models only, needs build/My AI Teacher.app)
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
step() { print -P "%B▸ $1%b" }
step "Build"; swift build 2>&1 | grep -E "error|Build complete" || fail=1
step "Unit tests"; swift test 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests" | tail -2; [[ ${pipestatus[1]} -eq 0 ]] || fail=1
for mode in light dark; do
  step "Renderer suite ($mode)"
  .build/debug/MyAITeacher --webtest Tests/web/renderer.test.js ${${mode:#light}:+--dark} | grep -v "✓"
  [[ ${pipestatus[1]} -eq 0 ]] || fail=1
done
step "Frozen-page recovery (watchdog)"
.build/debug/MyAITeacher --webtest --watchdog | tail -1; [[ ${pipestatus[1]} -eq 0 ]] || fail=1
if [[ "${1:-}" == "--live" ]]; then
  step "Live lessons (free model, test profile)"
  scripts/build-app.sh >/dev/null && python3 scripts/e2e-live.py || fail=1
fi
(( fail )) && { print -P "%F{red}✗ something failed%f"; exit 1 } || print -P "%F{green}✓ all checks passed%f"
