#!/usr/bin/env bash
set -euo pipefail

# Anonymous installer for the public repository. GitHub CLI authentication is
# not required; the repository itself must be public for this URL to work.
REPO_SLUG="${CLDL_REPO_SLUG:-nekomario28/cline-desktop-linux}"
REF="${CLDL_REF:-main}"
TMP_PARENT="${TMPDIR:-/tmp}"
STAGE_ROOT="$(mktemp -d "$TMP_PARENT/cline-desktop-linux-bootstrap.XXXXXX")"
ARCHIVE="$STAGE_ROOT/source.tar.gz"
ARCHIVE_URL="${CLDL_ARCHIVE_URL:-https://codeload.github.com/$REPO_SLUG/tar.gz/refs/heads/$REF}"

cleanup() {
  python3 - "$STAGE_ROOT" "$TMP_PARENT" <<'PY'
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1]).resolve()
parent = Path(sys.argv[2]).resolve()
if root.parent == parent and root.name.startswith("cline-desktop-linux-bootstrap.") and not root.is_symlink():
    shutil.rmtree(root)
PY
}
trap cleanup EXIT

for cmd in curl find python3 tar; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing dependency: $cmd" >&2; exit 1; }
done

curl --fail --location --proto '=https' --tlsv1.2 "$ARCHIVE_URL" --output "$ARCHIVE"
tar -xzf "$ARCHIVE" -C "$STAGE_ROOT"
SOURCE_ROOT="$(find "$STAGE_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'cline-desktop-linux-*' -print -quit)"
[[ -n "$SOURCE_ROOT" && -f "$SOURCE_ROOT/install.sh" ]] || {
  echo "downloaded archive does not contain cline-desktop-linux" >&2
  exit 1
}

bash "$SOURCE_ROOT/install.sh" "$@"
