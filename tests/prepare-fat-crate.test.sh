#!/usr/bin/env bash
# Real Git regression tests for the root fixture's tracked coverage paths.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/tests/prepare-fat-crate.sh"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir

repo() {
  local dir
  dir="$(mktemp -d "$WORK/repo.XXXXXX")"
  (
    cd "$dir" || exit 1
    git init -q -b main .
    git config user.name test
    git config user.email test@invalid
    mkdir -p tests/fixtures
    cp -R "$ROOT/tests/fixtures/fat-crate" tests/fixtures/
    git add .
    git commit -q -m base
    git update-ref refs/remotes/origin/main HEAD
    echo unrelated >unrelated.txt
    git add unrelated.txt
    git commit -q -m unrelated
  ) || return
  echo "$dir"
}

d="$(repo)"
head_before="$(git -C "$d" rev-parse HEAD)"
echo staged >"$d/staged.txt"
git -C "$d" add staged.txt
out="$(cd "$d" && bash "$SCRIPT" 2>&1)"
rc=$?
eq 'preparation succeeds' 0 "$rc"
eq 'one local commit is added' 1 "$(git -C "$d" rev-list --count "$head_before"..HEAD)"
eq 'integration identity is used' integration-test "$(git -C "$d" log -1 --format=%an)"
for file in Cargo.toml src/lib.rs src/ignored.rs; do
  pass "$file: copy matches fixture" cmp "$d/$file" "$ROOT/tests/fixtures/fat-crate/$file"
  pass "$file: tracked in HEAD" git -C "$d" cat-file -e "HEAD:$file"
done
eq 'commit contains only copied files' 'Cargo.toml src/ignored.rs src/lib.rs ' \
  "$(git -C "$d" diff --name-only "$head_before" HEAD | tr '\n' ' ')"
eq 'unrelated staged file is left staged' 'A  staged.txt' "$(git -C "$d" status --porcelain)"
eq 'real merge-base is unchanged' "$(git -C "$d" rev-parse origin/main)" \
  "$(git -C "$d" merge-base origin/main HEAD)"
# The expression expands in the child shell.
# shellcheck disable=SC2016
pass 'merge-base has no root Cargo.toml' bash -c '! git -C "$1" cat-file -e origin/main:Cargo.toml 2>/dev/null' _ "$d"

for collision in Cargo.toml src; do
  d="$(repo)"
  echo precious >"$d/$collision"
  head_before="$(git -C "$d" rev-parse HEAD)"
  out="$(cd "$d" && bash "$SCRIPT" 2>&1)"
  eq "$collision: refuses overwrite" 1 "$?"
  eq "$collision: preserves existing content" precious "$(cat "$d/$collision")"
  eq "$collision: no commit" "$head_before" "$(git -C "$d" rev-parse HEAD)"
done

for ignored in /src/ignored.rs /src/ /Cargo.toml; do
  d="$(repo)"
  echo "$ignored" >"$d/.gitignore"
  git -C "$d" add .gitignore
  git -C "$d" commit -q -m ignore
  head_before="$(git -C "$d" rev-parse HEAD)"
  out="$(cd "$d" && bash "$SCRIPT" 2>&1)"
  eq "$ignored: fails if Git skips a file" 1 "$?"
  name="${ignored#/}"
  has "$ignored: names ignored path" "$out" "${name%/}"
  eq "$ignored: no commit" "$head_before" "$(git -C "$d" rev-parse HEAD)"
done
out="$(cd "$WORK" && bash "$SCRIPT" 2>&1)"
eq 'missing fixture: fails' 1 "$?"
has 'missing fixture: explains workspace requirement' "$out" 'run this from the workspace root'
summary
