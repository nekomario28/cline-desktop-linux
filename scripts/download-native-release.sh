#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_HOME="${CLINE_DESKTOP_LINUX_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/cline-desktop-linux}"
RELEASE_REPO="${CLDL_RELEASE_REPO:-nekomario28/cline-desktop-linux}"
RELEASE_TAG="${CLDL_RELEASE_TAG:-}"
ASSET_DIR=""
EXPECTED_REVISION=""

usage() {
  cat <<EOF
Usage: $0 [--app-home PATH] [--repo OWNER/REPO] [--tag TAG]
       [--asset-dir PATH] [--revision SHA]

Download and verify the latest (or selected) x86_64 Native GitHub Release,
then stage it as native/releases/<Cline SHA> and update native/current.
--asset-dir is for local/offline verification of an already downloaded release.
EOF
}

while (($#)); do
  case "$1" in
    --app-home) (($# >= 2)) || { echo "missing value for --app-home" >&2; exit 2; }; APP_HOME="$2"; shift 2 ;;
    --app-home=*) APP_HOME="${1#*=}"; shift ;;
    --repo) (($# >= 2)) || { echo "missing value for --repo" >&2; exit 2; }; RELEASE_REPO="$2"; shift 2 ;;
    --repo=*) RELEASE_REPO="${1#*=}"; shift ;;
    --tag) (($# >= 2)) || { echo "missing value for --tag" >&2; exit 2; }; RELEASE_TAG="$2"; shift 2 ;;
    --tag=*) RELEASE_TAG="${1#*=}"; shift ;;
    --asset-dir) (($# >= 2)) || { echo "missing value for --asset-dir" >&2; exit 2; }; ASSET_DIR="$2"; shift 2 ;;
    --asset-dir=*) ASSET_DIR="${1#*=}"; shift ;;
    --revision) (($# >= 2)) || { echo "missing value for --revision" >&2; exit 2; }; EXPECTED_REVISION="$2"; shift 2 ;;
    --revision=*) EXPECTED_REVISION="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for cmd in find python3 sha256sum tar mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing prebuilt dependency: $cmd" >&2; exit 1; }
done

cleanup_dir=""
if [[ -z "$ASSET_DIR" ]]; then
  command -v gh >/dev/null 2>&1 || { echo "gh is required to download a private GitHub Release" >&2; exit 1; }
  ASSET_DIR="$(mktemp -d "/tmp/cldl-native-release.XXXXXX")"
  cleanup_dir="$ASSET_DIR"
  cleanup_download() {
    [[ -n "$cleanup_dir" ]] || return 0
    python3 - "$cleanup_dir" <<'PY'
from pathlib import Path
import shutil, sys
p = Path(sys.argv[1])
if p.exists():
    shutil.rmtree(p)
PY
  }
  trap cleanup_download EXIT
  args=(release download)
  [[ -n "$RELEASE_TAG" ]] && args+=("$RELEASE_TAG")
  args+=(--repo "$RELEASE_REPO" --pattern '*.deb' --pattern '*-x86_64.tar.gz' --pattern '*-metadata.txt' --pattern SHA256SUMS --dir "$ASSET_DIR" --clobber)
  gh "${args[@]}"
fi

[[ -d "$ASSET_DIR" ]] || { echo "asset directory not found: $ASSET_DIR" >&2; exit 1; }
[[ -f "$ASSET_DIR/SHA256SUMS" ]] || { echo "release is missing SHA256SUMS" >&2; exit 1; }
(
  cd "$ASSET_DIR"
  sha256sum -c SHA256SUMS
)

mapfile -t archives < <(find "$ASSET_DIR" -maxdepth 1 -type f -name '*-x86_64.tar.gz' -print | sort)
mapfile -t metadata_files < <(find "$ASSET_DIR" -maxdepth 1 -type f -name '*-metadata.txt' -print | sort)
[[ "${#archives[@]}" -eq 1 ]] || { echo "expected one x86_64 portable archive, found ${#archives[@]}" >&2; exit 1; }
[[ "${#metadata_files[@]}" -eq 1 ]] || { echo "expected one release metadata file, found ${#metadata_files[@]}" >&2; exit 1; }
archive="${archives[0]}"
metadata_file="${metadata_files[0]}"

revision="$(sed -n 's/^CLINE_REVISION=//p' "$metadata_file" | head -n1)"
version="$(sed -n 's/^CLINE_VERSION=//p' "$metadata_file" | head -n1)"
arch="$(sed -n 's/^ARCH=//p' "$metadata_file" | head -n1)"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid Cline revision in release metadata" >&2; exit 1; }
[[ -n "$version" && "$arch" == x86_64 ]] || { echo "invalid release metadata" >&2; exit 1; }
if [[ -n "$EXPECTED_REVISION" && "$revision" != "$EXPECTED_REVISION" ]]; then
  echo "release revision $revision does not match expected $EXPECTED_REVISION" >&2
  exit 1
fi

tested_revision="$(tr -d '[:space:]' < "$PROJECT_ROOT/compat/cline-tested-revision.txt")"
[[ "$revision" == "$tested_revision" ]] || {
  echo "release revision $revision is not the tested revision $tested_revision" >&2
  exit 1
}

mkdir -p "$APP_HOME/native/releases"
stage="$APP_HOME/native/.download-stage-$revision-$$"
release_root="$APP_HOME/native/releases/$revision"
current_link="$APP_HOME/native/current"
cleanup_stage() {
  if [[ -n "$stage" ]]; then
    python3 - "$stage" <<'PY'
from pathlib import Path
import shutil, sys
p = Path(sys.argv[1])
if p.exists():
    shutil.rmtree(p)
PY
  fi
  if [[ -n "$cleanup_dir" ]]; then
    python3 - "$cleanup_dir" <<'PY'
from pathlib import Path
import shutil, sys
p = Path(sys.argv[1])
if p.exists():
    shutil.rmtree(p)
PY
  fi
}
trap cleanup_stage EXIT
python3 - "$stage" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.mkdir(parents=True, exist_ok=True)
PY

while IFS= read -r member; do
  case "$member" in
    /*|../*|*/../*|..|*/..)
      echo "unsafe path in release archive: $member" >&2
      exit 1
      ;;
  esac
done < <(tar -tzf "$archive")
tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$stage"
[[ -x "$stage/usr/bin/cline-app" ]] || { echo "release archive missing usr/bin/cline-app" >&2; exit 1; }
[[ -x "$stage/usr/bin/code-sidecar" ]] || { echo "release archive missing usr/bin/code-sidecar" >&2; exit 1; }
archive_revision="$(sed -n 's/^CLINE_REVISION=//p' "$stage/.cline-desktop-linux-release" | head -n1)"
[[ "$archive_revision" == "$revision" ]] || { echo "archive metadata revision mismatch" >&2; exit 1; }

python3 - "$release_root" <<'PY'
from pathlib import Path
import shutil, sys
p = Path(sys.argv[1])
if p.exists() or p.is_symlink():
    if p.is_dir() and not p.is_symlink():
        shutil.rmtree(p)
    else:
        p.unlink()
PY
mv "$stage" "$release_root"
stage=""
ln -sfn "releases/$revision" "$current_link"

echo "native_release=downloaded"
echo "native_revision=$revision"
echo "native_version=$version"
echo "native_runtime=$release_root"
