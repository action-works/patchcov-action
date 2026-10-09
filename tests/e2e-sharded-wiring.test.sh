#!/usr/bin/env bash
# Tests for the wiring of .github/workflows/e2e-sharded.yml (#13). Plain bash, no framework:
#   tests/e2e-sharded-wiring.test.sh
# Exits non-zero if any case fails.
#
# patchcov rejects a report whose paths match no tracked file (exit 7), and a patch gate
# over a crate that is not in the diff passes vacuously. So every job that runs the action
# (`uses: ./`) on the sharded crate must commit it locally first
# (`tests/prepare-shard-crate.sh --commit`), in a step ahead of its first `uses: ./`. That was
# fixed one job at a time and missed once (#11), and nothing tied the two together.
#
# `allow-path-mismatch` is NOT an alternative to the commit: it silences the path check but
# leaves the patch empty. The `pull-request` job sets it for the baseline side and commits
# too, so the rule needs no exemption.
#
# One reader function over a workflows directory, run on the real workflow and on copies
# broken one way at a time, so each rule is shown to fail. The reader is POSIX awk (the
# ubuntu runners' default is mawk: no regex intervals) over the layout the file has: jobs at
# two spaces under `jobs:`. Comment lines are not read.

# The awk programs are single-quoted on purpose: awk reads them, not the shell.
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL="$ROOT/.github/workflows/e2e-sharded.yml"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir

# wiring <workflow>: one line per job that runs the action: `ok <job>` or
# `FAIL <job>: <reason>`. A job with no `uses: ./` is not reported.
wiring() {
  awk '
    function finish() {
      if (job == "" || first == 0) return
      if (commit > 0) print "ok " job
      else if (late > 0) print "FAIL " job ": commits the crate (line " late ") only after the action (line " first ")"
      else print "FAIL " job ": runs the action (line " first ") without committing the crate first"
    }
    /^[^ #]/ { if (injobs) { finish(); job = "" } injobs = ($0 ~ /^jobs:/) ; next }
    !injobs { next }
    /^  [A-Za-z0-9_-]+:/ {
      finish()
      job = $1; sub(/:$/, "", job); first = 0; commit = 0; late = 0
      next
    }
    /^[[:space:]]*#/ { next }
    job == "" { next }
    {
      line = $0
      sub(/[[:space:]]#.*$/, "", line)   # an inline comment is not read either
    }
    line ~ /prepare-shard-crate\.sh[[:space:]]+--commit([[:space:]]|$)/ {
      if (first == 0) { if (commit == 0) commit = NR } else if (late == 0) late = NR
    }
    line ~ /uses:[[:space:]]*["\x27]?\.\/["\x27]?[[:space:]]*$/ { if (first == 0) first = NR }
    END { if (injobs) finish() }
  ' "$1"
}

# mutate <job> <mode> <in> <out>: a copy of <in> with one change inside <job>.
#   drop      the commit call becomes `true`
#   copyonly  the commit call loses --commit
#   comment   the line holding the commit call is commented out
#   inline    the commit call is moved into an inline comment
#   late      the commit call becomes `true`, and a step with it ends the job
mutate() {
  JOB="$1" MODE="$2" awk '
    function tail() { if (inj && ENVIRON["MODE"] == "late") print "      - run: bash tests/prepare-shard-crate.sh --commit" }
    /^[^ #]/ { if (injobs) tail(); injobs = ($0 ~ /^jobs:/); inj = 0 }
    injobs && /^  [A-Za-z0-9_-]+:/ { tail(); inj = ($1 == ENVIRON["JOB"] ":") }
    inj && $0 !~ /^[[:space:]]*#/ && /bash tests\/prepare-shard-crate\.sh --commit/ {
      m = ENVIRON["MODE"]
      if (m == "drop" || m == "late") sub(/bash tests\/prepare-shard-crate\.sh --commit/, "true")
      else if (m == "copyonly") sub(/ --commit/, "")
      else if (m == "comment") $0 = "        # " $0
      else if (m == "inline") sub(/bash tests\/prepare-shard-crate\.sh --commit/, "true # &")
    }
    { print }
    END { tail() }
  ' "$3" >"$4"
}

# expect_fail <name> <file> <job> <fragment>: the job is reported FAIL with the fragment, and
# no other job is.
expect_fail() {
  local out
  out="$(wiring "$2")"
  if grep -q "^FAIL $3: .*$4" <<<"$out"; then ok "$1: $3 is reported"; else bad "$1: $3 is reported" "no '$4' for $3 in: $out"; fi
  eq "$1: only that job fails" 1 "$(grep -c '^FAIL' <<<"$out")"
}

# --- the real workflow -----------------------------------------------------------------

out="$(wiring "$REAL")"
eq "real: no job fails" 0 "$(grep -c '^FAIL' <<<"$out")"
has "real: publish is checked" "$out" "ok publish"
has "real: pull-request is checked" "$out" "ok pull-request"
lacks "real: shard runs no action and is not reported" "$out" "shard"

# --- one job at a time -----------------------------------------------------------------

for job in publish pull-request; do
  for mode in drop copyonly comment inline late; do
    c="$WORK/$job-$mode.yml"
    mutate "$job" "$mode" "$REAL" "$c"
    if cmp -s "$REAL" "$c"; then
      bad "$mode in $job: the mutation changed the copy"
      continue
    fi
    case "$mode" in
      late) frag="only after the action" ;;
      *) frag="without committing the crate first" ;;
    esac
    expect_fail "$mode in $job" "$c" "$job" "$frag"
  done
done

# --- a new job -------------------------------------------------------------------------

new() {
  cp "$REAL" "$WORK/new.yml"
  printf '\n  extra:\n    name: Extra\n    runs-on: ubuntu-latest\n    steps:\n%s' "$1" >>"$WORK/new.yml"
}

new '      - uses: actions/checkout@v7
      - uses: ./
        with:
          run-coverage: false
'
expect_fail "new job with the action and no commit" "$WORK/new.yml" extra "without committing the crate first"

new '      - uses: ./
      - run: bash tests/prepare-shard-crate.sh --commit
'
expect_fail "new job committing after the action" "$WORK/new.yml" extra "only after the action"

new '      - uses: actions/checkout@v7
      - run: bash tests/prepare-shard-crate.sh --commit
      - name: Run
        uses: ./
'
out="$(wiring "$WORK/new.yml")"
has "control: a new job committing first passes" "$out" "ok extra"
eq "control: and fails nothing" 0 "$(grep -c '^FAIL' <<<"$out")"

new '      - run: bash tests/prepare-shard-crate.sh
      - uses: actions/checkout@v7
'
out="$(wiring "$WORK/new.yml")"
lacks "control: a new job that runs no action needs no commit" "$out" "extra"
eq "control: and fails nothing" 0 "$(grep -c '^FAIL' <<<"$out")"

new '      # - uses: ./
      - run: echo "uses: ./ in a message"
'
out="$(wiring "$WORK/new.yml")"
lacks "control: a commented or quoted action is not an action" "$out" "extra"

# --- allow-path-mismatch is not a way out ----------------------------------------------

new '      - run: |
          mkdir -p .patchcov
          printf "diff:\n  allow-path-mismatch: true\n" > .patchcov/config.yaml
      - uses: ./
'
expect_fail "allow-path-mismatch does not replace the commit" "$WORK/new.yml" extra "without committing the crate first"

# --- the reader cannot be fooled into reading nothing ----------------------------------

printf 'name: x\non: push\njobs:\n  a:\n    steps:\n      - uses: ./\n' >"$WORK/small.yml"
expect_fail "a minimal workflow" "$WORK/small.yml" a "without committing the crate first"
printf 'name: x\non: push\njobs:\n  a:\n    steps:\n      - uses: ./\n  b:\n    steps:\n      - run: bash tests/prepare-shard-crate.sh --commit\n      - uses: ./\n' >"$WORK/two.yml"
out="$(wiring "$WORK/two.yml")"
has "a job after a failing one is still read" "$out" "ok b"
has "and the failing one is named" "$out" "FAIL a:"
printf 'name: x\non: push\n' >"$WORK/none.yml"
eq "a file with no jobs reports nothing" "" "$(wiring "$WORK/none.yml")"

summary
