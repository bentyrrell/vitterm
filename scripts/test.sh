#!/bin/bash
# Run vitterm's test suites.
#
#   scripts/test.sh             unit + integration tests, then the performance regression check
#   scripts/test.sh --e2e       also build the app and run end-to-end tests (opens windows briefly)
#   scripts/test.sh --extended  fuzz/differential tests at 20x their normal size
#   scripts/test.sh --quick     unit + integration tests only
set -euo pipefail
cd "$(dirname "$0")/.."

E2E=0; EXTENDED=0; QUICK=0
for arg in "$@"; do
    case "$arg" in
        --e2e) E2E=1 ;;
        --extended) EXTENDED=1 ;;
        --quick) QUICK=1 ;;
        *) echo "unknown option $arg" >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
summary() { sed 's/\x1b\[[0-9;]*m//g' | grep -E "error:|Executed [0-9]+ tests?, with [0-9]+ failures? \(0 unexpected\) in .*\) seconds$|failed" | grep -v "Executed 0 tests" | sort -u || true; }

step "Unit and integration tests (VitCore, VitConfig, VitRender, VitPTY)"
swift build --build-tests >/dev/null
swift test 2>&1 | tee /tmp/vitterm-test.log | summary
if grep -qE "error:|with [1-9][0-9]* failures?" /tmp/vitterm-test.log; then echo "TESTS FAILED"; exit 1; fi

if [ "$EXTENDED" = 1 ]; then
    step "Extended fuzzing (20x)"
    VITTERM_FUZZ_SCALE=20 swift test --filter "InvariantTests|DifferentialTests|GrammarFuzzTests" 2>&1 | tee /tmp/vitterm-fuzz.log | summary
    if grep -qE "error:|with [1-9][0-9]* failures?" /tmp/vitterm-fuzz.log; then echo "FUZZING FAILED"; exit 1; fi
fi

if [ "$QUICK" = 0 ]; then
    step "Performance regression check (release build)"
    swift build -c release --product vitbench >/dev/null
    "$(swift build -c release --show-bin-path)/vitbench" --check --mb 32
fi

if [ "$E2E" = 1 ]; then
    step "End-to-end tests (launches build/vitterm.app)"
    TEST_HOOKS=1 APP=build/e2e/vitterm.app ./scripts/bundle.sh >/dev/null
    VITTERM_E2E=1 swift test --filter E2ETests 2>&1 | tee /tmp/vitterm-e2e.log | summary
    if grep -qE "error:|with [1-9][0-9]* failures?" /tmp/vitterm-e2e.log; then echo "E2E FAILED"; exit 1; fi
fi

step "All requested test suites passed"
