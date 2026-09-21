# Agent instructions

Use this repository's own files as canonical truth. This is a Linux integration layer around upstream Cline, not a fork authority for changing upstream behavior.

Before substantial work:

1. Read `README.md` and the relevant scripts/docs for the affected path.
2. Record the current repository revision and the tested upstream Cline revision in `compat/cline-tested-revision.txt` when compatibility is relevant.
3. Preserve the existing revision-keyed Native runtime, checksum verification, and explicit compatibility/promotion boundaries.
4. Prefer affected checks while iterating; run the repository-native compatibility/release checks required by the changed surface before making completion claims.
5. Preserve the first concrete failure and fix the smallest cause before broadening scope.

Do not forcibly reset or switch an existing upstream Cline checkout. Do not treat a compatible-but-untested upstream revision as the recorded tested revision. Do not publish releases, tags, or other external artifacts without the authority and exact-revision evidence required by the repository's existing release procedure.

Keep changes small and reversible. Reuse existing scripts and compatibility machinery instead of creating a second launcher, state store, updater, or release path.