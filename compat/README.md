# Cline compatibility baseline

`cline-tested-revision.txt` is the exact upstream Cline commit validated by
this integration. Fresh installs use this revision unless `--cline-ref` is
specified explicitly.

Promotion rule:

1. Check out the candidate Cline revision in a clean source tree.
2. Run `scripts/check-cline-compat.sh /path/to/cline --build-sdk`.
3. Run `scripts/build-native.sh --cline-source /path/to/cline --app-home /tmp/cldl-native-test`.
4. Verify Browser/headless and the staged native release runtime.
5. Replace the single SHA in `cline-tested-revision.txt`.
6. Run `scripts/check-cline-compat.sh` and
   `scripts/release-native-local.sh` on the same local system.

There is no required remote CI or runner gate. Production installs remain
pinned to the tested revision until it is explicitly promoted and rebuilt
locally.

Release assets are produced only from the exact tested revision by
`scripts/package-release-native.sh`. The local release command emits an amd64
`.deb`, a portable x86_64 tarball, metadata, and SHA-256 checksums, then can
publish them through the local authenticated `gh` command.
