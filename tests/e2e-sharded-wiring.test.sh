#!/usr/bin/env bash
# Tests for the wiring of .github/workflows/e2e-sharded.yml (#13). Plain bash, no framework:
#   tests/e2e-sharded-wiring.test.sh
# Exits non-zero if any case fails.
#
# patchcov rejects a report whose paths match no tracked file (exit 7), and a patch gate
# over a crate that is not in the diff passes vacuously. So every job that runs the action
# (`uses: ./`) on the sharded crate must commit it locally first
# (`tests/prepare-shard-crate.sh --commit`), in an unconditional step after the latest
# checkout and ahead of its first `uses: ./`. That was
# fixed one job at a time and missed once (#11), and nothing tied the two together.
#
# `allow-path-mismatch` is NOT an alternative to the commit: it silences the path check but
# leaves the patch empty. The `pull-request` job sets it for the baseline side and commits
# too, so the rule needs no exemption.
#
# One reader function over a workflows directory, run on the real workflow and on copies
# broken one way at a time, so each rule is shown to fail. The reader is POSIX awk (the
# ubuntu runners' default is mawk: no regex intervals) over the layout the file has: jobs at
# two spaces under `jobs:` (including quoted IDs), steps at six spaces, and literal
# run blocks. Any step-level working-directory rejects preparation, even `.`; nested
# environment values do not. Workflow/job defaults.run.working-directory is unsupported.
# Comments are not read. General YAML and shell execution are out of scope.

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
  awk -v q="'" '
    function step_end() {
      if (checkout && first == 0) commit = 0
      if (action && first == 0) first = step_line
      if (prepare && !conditional && !directory && !action) {
        if (first == 0) commit = prepare
        else if (late == 0) late = prepare
      }
      checkout = action = prepare = conditional = directory = run_block = 0
    }
    function finish() {
      step_end()
      if (job == "" || first == 0) return
      if (commit > 0) print "ok " job
      else if (late > 0) print "FAIL " job ": commits the crate (line " late ") only after the action (line " first ")"
      else print "FAIL " job ": runs the action (line " first ") without committing the crate first after checkout"
    }
    /^[^ #]/ { if (injobs) { finish(); job = "" } injobs = ($0 ~ /^jobs:/) ; next }
    !injobs { next }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/[[:space:]]#.*$/, "", line)
    }
    line ~ ("^  ([A-Za-z0-9_-]+|\"[A-Za-z0-9_-]+\"|" q "[A-Za-z0-9_-]+" q "):[[:space:]]*$") {
      finish()
      job = line; sub(/^  /, "", job); sub(/:[[:space:]]*$/, "", job)
      gsub("[\"" q "]", "", job)
      first = commit = late = 0
      next
    }
    job == "" { next }
    line ~ /^      -[[:space:]]/ {
      step_end()
      step_line = NR
      sub(/^      -[[:space:]]+/, "        ", line)
    }
    # Only step-level fields are evidence, not values under env/with. Process the
    # whole step before accepting preparation: if/working-directory may follow run.
    line ~ /^        if:/ { conditional = 1 }
    line ~ /^        working-directory:/ { directory = 1 }
    line ~ ("^        [{]?[[:space:]]*uses:[[:space:]]*[\"" q "]?actions/checkout@") { checkout = 1 }
    line ~ ("^        [{]?[[:space:]]*uses:[[:space:]]*[\"" q "]?\\./[\"" q "]?([[:space:]}]|$)") { action = 1 }
    line ~ /^        [^ ]/ {
      run_block = (line ~ /^        run:[[:space:]]*\|[-+]?[[:space:]]*$/)
      command = line
      sub(/^        run:[[:space:]]*/, "", command)
      if (line !~ /^        run:/) next
    }
    line ~ /^          [^ ]/ && run_block { command = line; sub(/^          /, "", command) }
    # Standalone command starts only; comments, echo and nested mapping values do
    # not prove preparation. Shell control flow is outside this reader contract.
    (line ~ /^        run:/ || (run_block && line ~ /^          [^ ]/)) && command ~ /^(bash|sh)[[:space:]]+(\.\/)?tests\/prepare-shard-crate\.sh[[:space:]]+--commit([[:space:]]|$)/ { prepare = NR }
    END { if (injobs) finish() }
  ' "$1"
}

# mutate <job> <mode> <in> <out>: a copy of <in> with one change inside <job>.
#   drop      the commit call becomes `true`
#   copyonly  the commit call loses --commit
#   comment   the line holding the commit call is commented out
#   inline    the commit call is moved into an inline comment
#   late      the commit call becomes `true`, and a step with it ends the job
#   conditional / before-checkout / checkout: disable or invalidate preparation
#   directory-before / directory-after: preparation changes working directory
mutate() {
  JOB="$1" MODE="$2" awk '
    function flush(   i, m, prep) {
      m = ENVIRON["MODE"]
      prep = (inj && block ~ /bash tests\/prepare-shard-crate\.sh --commit/)
      if (inj && m == "before-checkout" && block ~ /uses: actions\/checkout@/)
        print "      - run: bash tests/prepare-shard-crate.sh --commit"
      if (prep && m == "conditional") {
        sub(/^      - /, "      - if: false\n        ", block)
      }
      if (prep && m == "directory-before") {
        sub(/^      - /, "      - working-directory: elsewhere\n        ", block)
      }
      if (prep && m == "directory-after") block = block "        working-directory: elsewhere\n"
      n = split(block, lines, "\n")
      for (i = 1; i < n; i++) {
        if (prep && lines[i] ~ /bash tests\/prepare-shard-crate\.sh --commit/) {
          if (m == "drop" || m == "late" || m == "before-checkout") sub(/bash tests\/prepare-shard-crate\.sh --commit/, "true", lines[i])
          else if (m == "copyonly") sub(/ --commit/, "", lines[i])
          else if (m == "comment") lines[i] = "        # " lines[i]
          else if (m == "inline") sub(/bash tests\/prepare-shard-crate\.sh --commit/, "true # &", lines[i])
        }
        print lines[i]
      }
      if (prep && m == "checkout") print "      - uses: actions/checkout@v7"
      block = ""
    }
    function tail() { if (inj && ENVIRON["MODE"] == "late") print "      - run: bash tests/prepare-shard-crate.sh --commit" }
    /^[^ #]/ { flush(); if (injobs) tail(); injobs = ($0 ~ /^jobs:/); inj = 0 }
    injobs && /^  [A-Za-z0-9_-]+:/ { flush(); tail(); inj = ($1 == ENVIRON["JOB"] ":") }
    /^      - / { flush() }
    { block = block $0 "\n" }
    END { flush(); tail() }
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
eq "real: exactly those two jobs are reported (shard runs no action)" "ok publish
ok pull-request" "$out"

# --- one job at a time -----------------------------------------------------------------

for job in publish pull-request; do
  for mode in drop copyonly comment inline late conditional before-checkout checkout directory-before directory-after; do
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

# Quoted IDs still identify the same jobs, both intact and without preparation.
for job in publish pull-request; do
  for quote in "'" '"'; do
    c="$WORK/$job-quoted.yml"
    JOB="$job" QUOTE="$quote" awk '
      $0 == "  " ENVIRON["JOB"] ":" { $0 = "  " ENVIRON["QUOTE"] ENVIRON["JOB"] ENVIRON["QUOTE"] ":" }
      { print }
    ' "$REAL" >"$c"
    if cmp -s "$REAL" "$c"; then bad "quoted $job: mutation changed the copy"; continue; fi
    eq "quoted $job: intact jobs pass and are checked" "ok publish
ok pull-request" "$(wiring "$c")"
    mutate "$job" drop "$REAL" "$WORK/dropped.yml"
    JOB="$job" QUOTE="$quote" awk '
      $0 == "  " ENVIRON["JOB"] ":" { $0 = "  " ENVIRON["QUOTE"] ENVIRON["JOB"] ENVIRON["QUOTE"] ":" }
      { print }
    ' "$WORK/dropped.yml" >"$c"
    expect_fail "quoted $job without preparation" "$c" "$job" "without committing the crate first"
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

new "      - run: echo 'bash tests/prepare-shard-crate.sh --commit'
      - uses: ./
"
expect_fail "a commit that is only echoed is not a commit" "$WORK/new.yml" extra "without committing the crate first"

new "      - uses: './'
"
expect_fail "a quoted action is read" "$WORK/new.yml" extra "without committing the crate first"

new "      - {uses: ./}
"
expect_fail "a flow-style action is read" "$WORK/new.yml" extra "without committing the crate first"

new "      - name: Commit
        run: |
          set -e
          bash tests/prepare-shard-crate.sh --commit
      - uses: ./
"
out="$(wiring "$WORK/new.yml")"
has "control: a commit inside a run block counts" "$out" "ok extra"

new '      - uses: actions/checkout@v7
      - run: bash tests/prepare-shard-crate.sh --commit
      - uses: ./
      - uses: actions/checkout@v7
'
has "control: checkout after the first action does not change its preparation" "$(wiring "$WORK/new.yml")" "ok extra"

# Conditions after run must also invalidate the whole preparation step.
for condition in 'if: false' 'if: ${{ always() }}'; do
  new "      - run: bash tests/prepare-shard-crate.sh --commit
        $condition
      - uses: ./
"
  expect_fail "preparation with trailing $condition" "$WORK/new.yml" extra "without committing the crate first"
done

# Explicit root directories are conservatively rejected too. Nested environment
# values in either field order must not invalidate real preparation.
for directory in elsewhere .; do
  new "      - uses: actions/checkout@v7
      - run: bash tests/prepare-shard-crate.sh --commit
        working-directory: $directory
      - uses: ./
"
  expect_fail "explicit preparation directory $directory" "$WORK/new.yml" extra "without committing the crate first"
done

for order in before after; do
  if [[ "$order" == before ]]; then
    preparation='      - env:
          working-directory: elsewhere
        run: bash tests/prepare-shard-crate.sh --commit'
  else
    preparation='      - run: bash tests/prepare-shard-crate.sh --commit
        env:
          working-directory: elsewhere'
  fi
  new "      - uses: actions/checkout@v7
$preparation
      - uses: ./
"
  eq "env.working-directory $order run: all jobs pass and are checked" "ok publish
ok pull-request
ok extra" "$(wiring "$WORK/new.yml")"
done

new '      - uses: actions/checkout@v7
      - run: true
        working-directory: elsewhere
      - run: bash tests/prepare-shard-crate.sh --commit
      - uses: ./
'
eq "working-directory on an earlier step does not leak into preparation" "ok publish
ok pull-request
ok extra" "$(wiring "$WORK/new.yml")"

new '      - uses: actions/checkout@v7
      - run: bash tests/prepare-shard-crate.sh --commit
      - uses: actions/checkout@v7
      - run: bash tests/prepare-shard-crate.sh --commit
      - uses: ./
'
has "control: preparation after the latest checkout passes" "$(wiring "$WORK/new.yml")" "ok extra"

new '      - name: Environment is not execution
        env:
          run: bash tests/prepare-shard-crate.sh --commit
      - uses: ./
'
expect_fail "env.run is not preparation" "$WORK/new.yml" extra "without committing the crate first"

new '      - run: true
        env:
          COMMAND: |
            bash tests/prepare-shard-crate.sh --commit
      - uses: ./
'
expect_fail "an environment block is not preparation" "$WORK/new.yml" extra "without committing the crate first"

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
