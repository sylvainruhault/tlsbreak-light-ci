# TLSbreak light: CI

Portability tests for the free **light** bundle of TLSbreak (the TLS Challenge
Lab by cryptoschola), run with GitHub Actions on Linux (x64 and arm64),
Windows (WSL2) and macOS.

- The bundle under test is the `light.zip` asset of the
  [`light-bundle` release](../../releases/tag/light-bundle). It is the same
  file students download.
- `test/ci/` holds the scripts that drive the bundle like a student would:
  load the images, pick challenges from the menu, submit proofs, and start the
  browser workstation (Option B).
- `.github/workflows/light-bundle.yml` holds the test matrix.

This repository is generated. Every sync overwrites its contents, so changes
made here won't last.
