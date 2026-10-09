#!/usr/bin/env bash
# Copy the fat-mode crate to the workspace root and commit it locally, never pushed.
# Tracked report paths are required by patchcov diff. The real merge-base remains
# unchanged and has no root Cargo.toml, so baseline recomputation stays disabled.
# Usage: bash tests/prepare-fat-crate.sh (from the workspace root)
set -euo pipefail

src=tests/fixtures/fat-crate
if [ ! -d "$src" ]; then
  echo "::error::$src does not exist; run this from the workspace root"
  exit 1
fi
# Check every fixture destination before copying, including future root files.
while IFS= read -r -d '' path; do
  dest="${path#"$src"/}"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    echo "::error::$dest already exists at the repository root; the fixture would overwrite it"
    exit 1
  fi
done < <(find "$src" -mindepth 1 -maxdepth 1 -print0)

cp -R "$src"/. .
files=()
while IFS= read -r -d '' path; do
  files+=("${path#"$src"/}")
done < <(find "$src" \( -type f -o -type l \) -print0)
git add -- "${files[@]}"
for file in "${files[@]}"; do
  if ! git ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
    echo "::error::$file was not staged, probably because a .gitignore rule matches it"
    exit 1
  fi
done
git -c user.name=integration-test -c user.email=integration-test@invalid \
  commit -q -m 'test: add the fat-mode fixture crate' -- "${files[@]}"
for file in "${files[@]}"; do
  if ! git cat-file -e "HEAD:$file"; then
    echo "::error::$file was not committed; refusing to run coverage"
    exit 1
  fi
done
echo 'Prepared the fat-mode fixture crate (committed locally, never pushed)'
