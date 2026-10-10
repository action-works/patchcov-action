# Changelog

## v2.0 — 2026-10-11 (breaking)

- Move the action to `action-works/patchcov-action`, copied from
  `action-works/omni-dev-coverage-check`. GitHub does not redirect `uses:` references, so
  callers change `uses: action-works/omni-dev-coverage-check@v2` to
  `uses: action-works/patchcov-action@v2`.
- Run coverage diffs and gates with patchcov, with a default pin of 0.4.0.
- A nonempty report whose paths match no tracked file now fails with exit 7 before the
  PR comment. Correct `strip-prefix`, or set `diff.allow-path-mismatch` in
  `.patchcov/config.yaml`. Failures may exit with codes other than 1; coverage gates
  still exit 1.
- A failed comment render leaves no `coverage.md` and reports patchcov's diagnostic as
  an error annotation.
- Install versioned Linux and macOS x64/ARM64 archives or `cargo install patchcov`;
  isolate the patchcov cache. Windows has no pre-built asset. Linux binaries require
  glibc 2.35 or newer.
- Cache the patchcov binary with `actions/cache@v6`.
- Rename `omni-dev-cache-hit` to `patchcov-cache-hit`. Generic `version` and
  `release-tag` outputs now identify patchcov; existing omni-dev pins must be replaced.
- Remove obsolete omni-dev flag-floor guards and source-install audio dependencies.
- Warn about ignored legacy coverage config, environment and tracked source markers.

Before adopting v2, migrate `.omni-dev/coverage.yaml` to `.patchcov/config.yaml`,
`OMNI_DEV_CONFIG_DIR` to `PATCHCOV_CONFIG_DIR`, and `omni-dev: coverage` markers to
`patchcov: coverage`. See [README migration instructions](README.md#migrating-from-omni-dev-coverage-check).
The coverage pipeline inputs remain the same. No compatibility
aliases or dual-tool mode are provided.

The `v1` tag of this repository marks an interim patchcov 0.1.1 snapshot and is left in
place; new callers should use `v2`.
