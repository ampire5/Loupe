# Sourced by scripts/test.sh: runs the build and the tests with their whole output in a log, and on screen only what
# matters, read by scripts/test-report.awk:
#   - by hand: build errors, each failing expectation as it happens (test, file:line, message, a few lines of
#     detail), a progress line, and at the end a summary of the failed tests. Nothing of the passing tests, the
#     compiler's warnings or FFmpeg's console messages: those stay in the log.
#   - in CI (GITHUB_ACTIONS) or with TEST_VERBOSE=1: everything, as before, then the same summary. In CI each issue
#     is also an annotation on its line, the job summary lists the failed tests, and the failed tests run once more
#     (TEST_RETRY=0 turns that off): a test that passes then counts as flaky, a warning, and does not fail the job.
# The log: .build/test.log (TEST_LOG), started anew by each scripts/test.sh.
# Bash 3.2 (macOS's /bin/bash) is enough.

TEST_LOG=${TEST_LOG:-.build/test.log}
mkdir -p "$(dirname "$TEST_LOG")"
: >"$TEST_LOG"
if [[ -n ${GITHUB_ACTIONS:-} ]]; then
    test_stream=1
    test_retry=${TEST_RETRY:-1}
else
    test_stream=${TEST_VERBOSE:-0}
    test_retry=${TEST_RETRY:-0}
fi
test_tty=0
[[ -t 2 && $test_stream != 1 ]] && test_tty=1
test_report_awk=$(dirname "${BASH_SOURCE[0]}")/test-report.awk
test_failed_runs=0

# report KIND LABEL ISSUES-FILE COMMAND...: runs COMMAND through the reader; returns its status.
test_report_run() {
    local kind=$1 label=$2 issues=$3 errexit=0 status
    shift 3
    [[ $- == *e* ]] && errexit=1
    set +e
    echo "\$ $*" >>"$TEST_LOG"
    "$@" 2>&1 | tee -a "$TEST_LOG" | LC_ALL=C awk -v kind="$kind" -v label="$label" -v stream="$test_stream" \
        -v tty="$test_tty" -v issues="$issues" -f "$test_report_awk"
    status=${PIPESTATUS[0]}
    ((errexit)) && set -e
    return "$status"
}

# A file name as Swift Testing prints it → its path in the repository, for annotations.
test_report_path() {
    local found
    found=$(git ls-files "*/$1" 2>/dev/null | head -1)
    echo "${found:-$1}"
}

# GitHub's workflow commands want %, CR and LF escaped.
test_report_escape() {
    local s=${1//%/%25}
    s=${s//$'\r'/%0D}
    echo "${s//$'\n'/%0A}"
}

# report_build LABEL COMMAND...: a build; on screen only its errors.
report_build() {
    local label=$1
    shift
    test_report_run build "$label" "" "$@"
}

# report_tests LABEL COMMAND...: a test run (`swift test`, or the swift-testing helper), which takes `--filter`.
report_tests() {
    local label=$1 issues status names name args retry_status
    shift
    issues=$(mktemp)
    if test_report_run test "$label" "$issues" "$@"; then status=0; else status=$?; fi
    if [[ $status == 0 ]]; then rm -f "$issues"; return 0; fi
    names=$(grep -v '^#' "$issues" | cut -f1 | awk '!seen[$0]++')
    # Once more, only the failed tests: not after a crash or a build failure, nor for a long list (a real breakage).
    if [[ $test_retry == 1 && -n $names ]] && ! grep -q '^#unfinished' "$issues" && (($(wc -l <<<"$names") <= 10)); then
        args=()
        while IFS= read -r name; do args+=(--filter "${name%%(*}"); done <<<"$names"
        echo "Running the failed tests once more:" $names
        : >"$issues.again"
        if test_report_run test "$label (again)" "$issues.again" "$@" "${args[@]}"; then retry_status=0; else retry_status=$?; fi
        if [[ $retry_status == 0 ]]; then
            while IFS= read -r name; do
                echo "::warning title=Flaky test::$(test_report_escape "$name") failed, then passed when run again"
            done <<<"$names"
            if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
                { echo "### $label: flaky tests (failed, then passed when run again)"; echo
                  while IFS= read -r name; do echo "- \`$name\`"; done <<<"$names"; echo; } >>"$GITHUB_STEP_SUMMARY"
            fi
            rm -f "$issues" "$issues.again"
            return 0
        fi
        # The second run's failures are the ones that count.
        mv "$issues.again" "$issues"
    fi
    if [[ -n ${GITHUB_ACTIONS:-} ]]; then
        while IFS=$'\t' read -r name file line message; do
            [[ $name == "#unfinished" || -z $file ]] && continue
            echo "::error file=$(test_report_path "$file"),line=$line,title=$(test_report_escape "$name")::$(test_report_escape "$message")"
        done <"$issues"
    fi
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
        { echo "### $label: failed tests"; echo
          if grep -q '^#unfinished' "$issues"; then echo "The test run did not finish (a crash or a build failure): see the log."; echo; fi
          if [[ -n $names ]]; then
              echo "| Test | Where | Expectation |"; echo "|---|---|---|"
              while IFS=$'\t' read -r name file line message; do
                  [[ $name == "#unfinished" ]] && continue
                  message=${message//|/\\|}
                  echo "| \`$name\` | $file:$line | ${message:0:200} |"
              done <"$issues"
          fi
          echo; } >>"$GITHUB_STEP_SUMMARY"
    fi
    rm -f "$issues"
    test_failed_runs=$((test_failed_runs + 1))
    echo "Full log: $TEST_LOG"
    return "$status"
}
