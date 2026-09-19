#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLINE_SOURCE=""
DIST_DIR="$PROJECT_ROOT/dist"
APP_HOME=""
BUN_BIN="${BUN_BIN:-$HOME/.bun/bin/bun}"
BUILD_BASELINE="${CLDL_BUILD_BASELINE:-unknown}"

usage() {
  cat <<EOF
Usage: $0 --cline-source PATH [--dist-dir PATH] [--app-home PATH] [--bun PATH]

Build/stage the tested Cline native release and emit redistributable Linux
release assets:
  - upstream Tauri .deb
  - portable x86_64 tar.gz runtime
  - release metadata
  - SHA256SUMS
EOF
}

while (($#)); do
  case "$1" in
    --cline-source) (($# >= 2)) || { echo "missing value for --cline-source" >&2; exit 2; }; CLINE_SOURCE="$2"; shift 2 ;;
    --cline-source=*) CLINE_SOURCE="${1#*=}"; shift ;;
    --dist-dir) (($# >= 2)) || { echo "missing value for --dist-dir" >&2; exit 2; }; DIST_DIR="$2"; shift 2 ;;
    --dist-dir=*) DIST_DIR="${1#*=}"; shift ;;
    --app-home) (($# >= 2)) || { echo "missing value for --app-home" >&2; exit 2; }; APP_HOME="$2"; shift 2 ;;
    --app-home=*) APP_HOME="${1#*=}"; shift ;;
    --bun) (($# >= 2)) || { echo "missing value for --bun" >&2; exit 2; }; BUN_BIN="$2"; shift 2 ;;
    --bun=*) BUN_BIN="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$CLINE_SOURCE" ]] || { echo "--cline-source is required" >&2; exit 2; }
[[ -d "$CLINE_SOURCE/.git" ]] || { echo "not a Cline git checkout: $CLINE_SOURCE" >&2; exit 1; }
for cmd in git python3 find tar gzip sha256sum mktemp uname; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing release-packaging dependency: $cmd" >&2; exit 1; }
done
[[ "$(uname -m)" == "x86_64" ]] || { echo "release packaging currently supports x86_64 only" >&2; exit 1; }

if [[ -z "$APP_HOME" ]]; then
  APP_HOME="$(mktemp -d "/tmp/cldl-release.XXXXXX")"
  cleanup_app_home=yes
else
  cleanup_app_home=no
fi
cleanup() {
  if [[ "$cleanup_app_home" == yes && -n "$APP_HOME" ]]; then
    python3 - "$APP_HOME" <<'PY'
from pathlib import Path
import shutil, sys
p = Path(sys.argv[1])
if p.exists():
    shutil.rmtree(p)
PY
  fi
}
trap cleanup EXIT

tested_revision="$(tr -d '[:space:]' < "$PROJECT_ROOT/compat/cline-tested-revision.txt")"
source_revision="$(git -C "$CLINE_SOURCE" rev-parse HEAD)"
if [[ "$source_revision" != "$tested_revision" ]]; then
  echo "release packaging requires tested Cline revision $tested_revision" >&2
  echo "current Cline revision is $source_revision" >&2
  exit 1
fi

"$PROJECT_ROOT/scripts/build-native.sh" --cline-source "$CLINE_SOURCE" --app-home "$APP_HOME" --bun "$BUN_BIN"

runtime="$APP_HOME/native/releases/$source_revision"
metadata="$runtime/.cline-desktop-linux-release"
[[ -x "$runtime/usr/bin/cline-app" ]] || { echo "missing staged cline-app" >&2; exit 1; }
[[ -x "$runtime/usr/bin/code-sidecar" ]] || { echo "missing staged code-sidecar" >&2; exit 1; }
[[ -f "$metadata" ]] || { echo "missing native release metadata" >&2; exit 1; }

cline_version="$(sed -n 's/^CLINE_VERSION=//p' "$metadata" | head -n1)"
[[ -n "$cline_version" ]] || { echo "missing CLINE_VERSION in release metadata" >&2; exit 1; }

desktop_app="$CLINE_SOURCE/apps/examples/desktop-app"
deb_count="$(find "$desktop_app/src-tauri/target/release/bundle/deb" -maxdepth 1 -type f -name '*.deb' -print | wc -l)"
if [[ "$deb_count" -ne 1 ]]; then
  echo "expected exactly one upstream Tauri .deb artifact, found $deb_count" >&2
  exit 1
fi
deb="$(find "$desktop_app/src-tauri/target/release/bundle/deb" -maxdepth 1 -type f -name '*.deb' -print -quit)"

short_revision="$(printf '%s' "$source_revision" | cut -c1-12)"
asset_base="cline-desktop-linux-native-cline-$cline_version-$short_revision"
portable="$DIST_DIR/$asset_base-x86_64.tar.gz"
deb_asset="$DIST_DIR/$(basename "$deb")"
release_metadata="$DIST_DIR/$asset_base-metadata.txt"

python3 - "$DIST_DIR" <<'PY'
from pathlib import Path
import shutil, sys
p = Path(sys.argv[1])
if p.exists():
    shutil.rmtree(p)
p.mkdir(parents=True)
PY

cp "$deb" "$deb_asset"

tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner -C "$runtime" -cf - . | gzip -n > "$portable"

integration_revision="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
cat > "$release_metadata" <<EOF
CLINE_DESKTOP_LINUX_REVISION=$integration_revision
CLINE_REVISION=$source_revision
CLINE_VERSION=$cline_version
ARCH=x86_64
BUILD_BASELINE=$BUILD_BASELINE
PORTABLE_ASSET=$(basename "$portable")
DEB_ASSET=$(basename "$deb_asset")
EOF

(
  cd "$DIST_DIR"
  sha256sum "$(basename "$deb_asset")" "$(basename "$portable")" "$(basename "$release_metadata")" > SHA256SUMS
)

echo "release_dist=$DIST_DIR"
echo "release_deb=$deb_asset"
echo "release_portable=$portable"
echo "release_metadata=$release_metadata"
echo "release_checksums=$DIST_DIR/SHA256SUMS"
