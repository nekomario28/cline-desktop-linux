#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLINE_SOURCE=""
APP_HOME="${CLINE_DESKTOP_LINUX_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/cline-desktop-linux}"
BUN_BIN="${BUN_BIN:-$HOME/.bun/bin/bun}"
stage=""

cleanup_stage() {
  [[ -n "$stage" ]] || return 0
  python3 - "$stage" <<'PY'
from pathlib import Path
import shutil, sys
p = Path(sys.argv[1])
if p.exists():
    shutil.rmtree(p)
PY
}
trap cleanup_stage EXIT

usage() {
  cat <<EOF
Usage: $0 --cline-source PATH [--app-home PATH] [--bun PATH]

Build upstream Cline's release Tauri .deb bundle, unpack it into a revision-
keyed portable runtime, and atomically point native/current at that release.
EOF
}

while (($#)); do
  case "$1" in
    --cline-source) (($# >= 2)) || { echo "missing value for --cline-source" >&2; exit 2; }; CLINE_SOURCE="$2"; shift 2 ;;
    --cline-source=*) CLINE_SOURCE="${1#*=}"; shift ;;
    --app-home) (($# >= 2)) || { echo "missing value for --app-home" >&2; exit 2; }; APP_HOME="$2"; shift 2 ;;
    --app-home=*) APP_HOME="${1#*=}"; shift ;;
    --bun) (($# >= 2)) || { echo "missing value for --bun" >&2; exit 2; }; BUN_BIN="$2"; shift 2 ;;
    --bun=*) BUN_BIN="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$CLINE_SOURCE" ]] || { echo "--cline-source is required" >&2; exit 2; }
for cmd in git python3 ar tar sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing native-build dependency: $cmd" >&2; exit 1; }
done
[[ -x "$BUN_BIN" ]] || { echo "Bun not found: $BUN_BIN" >&2; exit 1; }

DESKTOP_APP="$CLINE_SOURCE/apps/examples/desktop-app"
[[ -d "$DESKTOP_APP/src-tauri" ]] || { echo "incompatible Cline source: $CLINE_SOURCE" >&2; exit 1; }

if [[ -n "$(git -C "$CLINE_SOURCE" status --porcelain --untracked-files=no)" ]]; then
  echo "refusing native release build from a dirty Cline checkout" >&2
  exit 1
fi

"$PROJECT_ROOT/scripts/check-cline-compat.sh" "$CLINE_SOURCE"

revision="$(git -C "$CLINE_SOURCE" rev-parse HEAD)"
short_revision="${revision:0:12}"
release_root="$APP_HOME/native/releases/$revision"
current_link="$APP_HOME/native/current"

if [[ -x "$release_root/usr/bin/cline-app" && -x "$release_root/usr/bin/code-sidecar" ]]; then
  ln -sfn "releases/$revision" "$current_link"
  echo "native_release=cached"
  echo "native_revision=$revision"
  echo "native_runtime=$release_root"
  exit 0
fi

mkdir -p "$APP_HOME/native/releases"

runtime_path="$(dirname "$BUN_BIN"):$HOME/.cargo/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"
export PATH="$runtime_path"

echo "Building Cline native release at $short_revision..."
(cd "$DESKTOP_APP" && env CI=true ./node_modules/.bin/tauri build --bundles deb)

mapfile -t debs < <(find "$DESKTOP_APP/src-tauri/target/release/bundle/deb" -maxdepth 1 -type f -name '*.deb' -print | sort)
if ((${#debs[@]} != 1)); then
  echo "expected exactly one Tauri .deb artifact, found ${#debs[@]}" >&2
  printf '  %s\n' "${debs[@]}" >&2
  exit 1
fi
deb="${debs[0]}"

stage="$APP_HOME/native/.stage-$revision-$$"
python3 - "$stage" <<'PY'
from pathlib import Path
import shutil, sys
p = Path(sys.argv[1])
if p.exists():
    shutil.rmtree(p)
p.mkdir(parents=True)
PY

archive_dir="$stage/.deb"
mkdir -p "$archive_dir"
(cd "$archive_dir" && ar x "$deb")
data_archive="$(find "$archive_dir" -maxdepth 1 -type f -name 'data.tar.*' -print -quit)"
[[ -n "$data_archive" ]] || { echo "Tauri .deb has no data archive" >&2; exit 1; }
tar -xf "$data_archive" -C "$stage"
python3 - "$archive_dir" <<'PY'
from pathlib import Path
import shutil, sys
shutil.rmtree(Path(sys.argv[1]))
PY

[[ -x "$stage/usr/bin/cline-app" ]] || { echo "release runtime missing usr/bin/cline-app" >&2; exit 1; }
[[ -x "$stage/usr/bin/code-sidecar" ]] || { echo "release runtime missing usr/bin/code-sidecar" >&2; exit 1; }

version="$(python3 - "$DESKTOP_APP/package.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("version", "unknown"))
PY
)"
deb_sha="$(sha256sum "$deb" | awk '{print $1}')"
cat > "$stage/.cline-desktop-linux-release" <<EOF
CLINE_REVISION=$revision
CLINE_VERSION=$version
SOURCE_DEB_SHA256=$deb_sha
EOF

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

echo "native_release=built"
echo "native_revision=$revision"
echo "native_version=$version"
echo "native_runtime=$release_root"
