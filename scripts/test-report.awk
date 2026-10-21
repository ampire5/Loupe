# Reads the output of `swift test` (or swift build) and keeps the screen readable: see scripts/test-report.sh.
# Variables: kind (test | build), label (the pass's name), stream (1: print every line, as CI does), tty (1: a
# progress line on stderr), issues (a file for the issues: test, file, line, message, tab-separated; "#unfinished"
# when the run printed no result).
# POSIX awk only: macOS's awk is BSD's.

# Bytes, not characters (test-report.sh runs awk with LC_ALL=C, as BSD awk counts anyway): a cut that splits a
# UTF-8 character drops the rest of it.
function clip(s, n) {
    if (length(s) <= n) return s
    s = substr(s, 1, n - 1)
    sub(/[\200-\377]+$/, "", s)
    return s "…"
}

function progress(   text) {
    if (!tty || stream) return
    text = sprintf("  %d passed, %d failed, %d skipped", passed, nfailed, skipped)
    if (current != "") text = text "   " clip(current, 60)
    printf "\r\033[K%s", text > "/dev/stderr"
    shown = 1
}

function clear_progress() {
    if (shown) { printf "\r\033[K" > "/dev/stderr"; shown = 0 }
}

function say(s) {
    if (stream) return
    clear_progress()
    print s
}

# "✔ Test foo(x:) with 3 test cases passed after …" → "foo(x:)"
function test_name(s, before, after,   i) {
    s = substr(s, index(s, before) + length(before))
    i = index(s, after)
    if (i > 0) s = substr(s, 1, i - 1)
    sub(/ with [0-9]+ test cases?$/, "", s)
    sub(/ with [0-9]+ arguments?.*$/, "", s)
    return s
}

function mark_failed(name) {
    if (!(name in failed_test)) { failed_test[name] = 1; nfailed++; failed_order[nfailed] = name }
}

BEGIN { passed = 0; nfailed = 0; skipped = 0; nissues = 0; nerrors = 0; issue = 0; finished = 0; shown = 0 }

{
    line = $0
    sub(/\r$/, "", line)
    if (stream) print line
}

# Details of the issue just reported (`↳ …`); the test's doc comment comes as `↳ ///` lines and is left out.
issue && /^↳ / {
    if (line ~ /^↳ \/\/\//) next
    if (ndetail[issue] < 4) {
        ndetail[issue]++
        say("      " clip(substr(line, 5), 150))
    }
    next
}
{ issue = 0 }

/^◇ Test .* started\.$/ {
    current = test_name(line, "◇ Test ", " started.")
    progress()
    next
}

/^✔ Test .* passed after / && !/^✔ Test run with / {
    passed++
    progress()
    next
}

/^➜ Test .* skipped/ {
    skipped++
    progress()
    next
}

/^✘ Test .* recorded an issue/ {
    name = test_name(line, "✘ Test ", " recorded an issue")
    mark_failed(name)
    file = ""; at = ""; message = line
    if (match(line, / at [^ ]+\.swift:[0-9]+(:[0-9]+)?: /)) {
        loc = substr(line, RSTART + 4, RLENGTH - 6)
        message = substr(line, RSTART + RLENGTH)
        n = split(loc, part, ":")
        file = part[1]; at = part[2]
    } else {
        sub(/^.* recorded an issue:? */, "", message)
    }
    nissues++
    issue = nissues
    ndetail[issue] = 0
    issue_test[issue] = name; issue_file[issue] = file; issue_line[issue] = at; issue_message[issue] = message
    if (issues != "") printf "%s\t%s\t%s\t%s\n", name, file, at, message > issues
    say("✘ " name (file != "" ? "   " file ":" at : ""))
    say("    " clip(message, 150))
    progress()
    next
}

/^✘ Test .* failed after / && !/^✘ Test run with / {
    mark_failed(test_name(line, "✘ Test ", " failed after"))
    progress()
    next
}

/^(✔|✘) Test run with [0-9]+ tests? / {
    finished = 1
    total = line
    sub(/^.* Test run with /, "", total)
    sub(/ tests? in .*$/, "", total)
    seconds = line
    sub(/^.* after /, "", seconds)
    sub(/ seconds.*$/, "", seconds)
    next
}

# Build errors, a crash, a test process that did not start: always on screen (once each).
/(^|[^a-z])error: |Fatal error|fatal error:|Exited with (unexpected )?signal/ {
    if (!(line in seen_error)) {
        seen_error[line] = 1
        nerrors++
        errors[nerrors] = line
        say(clip(line, 300))
    }
    next
}

END {
    clear_progress()
    if (kind == "build") {
        if (nerrors > 0) print "✘ " label ": the build failed (" nerrors " error" (nerrors > 1 ? "s" : "") ", above)"
        exit
    }
    rule = "────────────────────────────────────────────────────────────"
    print rule
    head = label != "" ? label ": " : ""
    took = seconds != "" ? " in " int(seconds + 0.5) " s" : ""
    if (!finished) {
        if (issues != "") print "#unfinished" > issues
        print "✘ " head "the test run did not finish (crash or build failure)" (current != "" ? "; last test started: " current : "")
        for (i = 1; i <= nerrors && i <= 10; i++) print "  " clip(errors[i], 300)
    } else if (nfailed == 0) {
        print "✔ " head (total != "" ? total : passed) " tests, all passed" (skipped ? " (" skipped " skipped)" : "") took
    } else {
        print "✘ " head nfailed " of " (total != "" ? total : passed + nfailed) " tests failed" (skipped ? " (" skipped " skipped)" : "") took ":"
        for (t = 1; t <= nfailed; t++) {
            name = failed_order[t]
            where = ""; first = ""
            for (i = 1; i <= nissues; i++) {
                if (issue_test[i] != name) continue
                if (first == "") first = issue_message[i]
                if (issue_file[i] != "") where = where (where == "" ? issue_file[i] ":" : ", ") issue_line[i]
            }
            printf "  ✘ %s%s\n", name, (where != "" ? "   " where : "")
            if (first != "") print "      " clip(first, 140)
        }
    }
}
