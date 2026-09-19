#!/usr/bin/env bash
set -euo pipefail

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
REPO_HOME="${CLINE_DESKTOP_LINUX_HOME:-$DATA_HOME/cline-desktop-linux}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLINE_SOURCE="${CLINE_SOURCE:-$HOME/Documents/cline-desktop}"
CLINE_REPO="https://github.com/cline/cline.git"
CLINE_REF="${CLINE_REF:-tested}"
MODE="native"
SKIP_BUILD=no
NATIVE_SOURCE="${NATIVE_SOURCE:-auto}"
NATIVE_RELEASE_REPO="${NATIVE_RELEASE_REPO:-nekomario28/cline-desktop-linux}"
NATIVE_RELEASE_TAG="${NATIVE_RELEASE_TAG:-}"

usage() {
  cat <<EOF
Usage: ./install.sh [options]
  --mode native|browser|headless    Default mode (default: native; desktop is an alias for native)
  --cline-source PATH               Cline source checkout path
  --cline-ref tested|main|REF       Cline ref when cloning (default: tested)
  --native-source auto|prebuilt|build Native acquisition (default: auto)
  --native-release-tag TAG         Release tag (default: latest release)
  --skip-build                      Skip initial SDK build
EOF
}
while (($#)); do
  case "$1" in
    --mode) (($# >= 2)) || { echo "missing value for --mode" >&2; exit 2; }; MODE="$2"; shift 2 ;;
    --mode=*) MODE="${1#*=}"; shift ;;
    --cline-source) (($# >= 2)) || { echo "missing value for --cline-source" >&2; exit 2; }; CLINE_SOURCE="$2"; shift 2 ;;
    --cline-source=*) CLINE_SOURCE="${1#*=}"; shift ;;
    --cline-ref) (($# >= 2)) || { echo "missing value for --cline-ref" >&2; exit 2; }; CLINE_REF="$2"; shift 2 ;;
    --cline-ref=*) CLINE_REF="${1#*=}"; shift ;;
    --native-source) (($# >= 2)) || { echo "missing value for --native-source" >&2; exit 2; }; NATIVE_SOURCE="$2"; shift 2 ;;
    --native-source=*) NATIVE_SOURCE="${1#*=}"; shift ;;
    --native-release-tag) (($# >= 2)) || { echo "missing value for --native-release-tag" >&2; exit 2; }; NATIVE_RELEASE_TAG="$2"; shift 2 ;;
    --native-release-tag=*) NATIVE_RELEASE_TAG="${1#*=}"; shift ;;
    --skip-build) SKIP_BUILD=yes; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "$MODE" == desktop ]] && MODE=native
case "$MODE" in browser|native|headless) ;; *) echo "invalid --mode" >&2; exit 2;; esac
case "$NATIVE_SOURCE" in auto|prebuilt|build) ;; *) echo "invalid --native-source" >&2; exit 2;; esac

for cmd in git curl python3; do command -v "$cmd" >/dev/null || { echo "missing dependency: $cmd" >&2; exit 1; }; done

NODE_BIN=""
for candidate in /usr/local/bin/node /usr/bin/node "$HOME/.local/bin/node" "$(command -v node 2>/dev/null || true)"; do
  [[ -x "$candidate" ]] || continue
  node_version="$($candidate --version 2>/dev/null || true)"
  node_major="${node_version#v}"
  node_major="${node_major%%.*}"
  if [[ "$node_major" =~ ^[0-9]+$ ]] && ((node_major >= 22)); then
    NODE_BIN="$candidate"
    break
  fi
done
[[ -n "$NODE_BIN" ]] || {
  echo "Node.js 22 or newer is required by upstream Cline" >&2
  exit 1
}

if [[ ! -x "$HOME/.bun/bin/bun" ]] || [[ "$($HOME/.bun/bin/bun --version 2>/dev/null || true)" != "1.3.13" ]]; then
  echo "Installing Bun 1.3.13..."
  curl -fsSL https://bun.sh/install | bash -s "bun-v1.3.13"
fi
BUN="$HOME/.bun/bin/bun"
RUNTIME_PATH="$(dirname "$NODE_BIN"):$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export PATH="$RUNTIME_PATH${PATH:+:$PATH}"

TESTED_REVISION="$(tr -d '[:space:]' < "$SCRIPT_DIR/compat/cline-tested-revision.txt")"
[[ "$TESTED_REVISION" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid tested Cline revision" >&2; exit 1; }
if [[ "$CLINE_REF" == tested ]]; then
  RESOLVED_CLINE_REF="$TESTED_REVISION"
else
  RESOLVED_CLINE_REF="$CLINE_REF"
fi

if [[ ! -d "$CLINE_SOURCE/.git" ]]; then
  mkdir -p "$(dirname "$CLINE_SOURCE")"
  git clone "$CLINE_REPO" "$CLINE_SOURCE"
  git -C "$CLINE_SOURCE" checkout --detach "$RESOLVED_CLINE_REF"
fi

if [[ ! -f "$CLINE_SOURCE/apps/examples/desktop-app/package.json" ]]; then
  echo "Not a compatible Cline source tree: $CLINE_SOURCE" >&2
  exit 1
fi

"$SCRIPT_DIR/scripts/check-cline-compat.sh" "$CLINE_SOURCE"
SOURCE_REVISION="$(git -C "$CLINE_SOURCE" rev-parse HEAD)"
if [[ "$SOURCE_REVISION" != "$TESTED_REVISION" ]]; then
  echo "Note: Cline source $SOURCE_REVISION differs from tested revision $TESTED_REVISION" >&2
fi

if [[ ! -d "$CLINE_SOURCE/node_modules" ]]; then
  (cd "$CLINE_SOURCE" && "$BUN" install --frozen-lockfile)
fi
if [[ "$SKIP_BUILD" != yes ]]; then
  (cd "$CLINE_SOURCE" && "$BUN" run build:sdk)
fi

CONFIG_DIR="$CONFIG_HOME/cline-desktop-linux"
APPLICATIONS_DIR="$DATA_HOME/applications"
ICON_DIR="$DATA_HOME/icons/hicolor/256x256/apps"
mkdir -p "$REPO_HOME" "$HOME/.local/bin" "$CONFIG_DIR" "$APPLICATIONS_DIR" "$ICON_DIR"
if [[ "$SCRIPT_DIR" != "$REPO_HOME" ]]; then
  python3 - "$REPO_HOME" <<'PY2'
from pathlib import Path
import shutil, sys
root=Path(sys.argv[1])
for name in ("bin", "lib", "scripts", "compat", "docs", ".github"):
    target=root/name
    if target.exists(): shutil.rmtree(target)
PY2
  cp -a "$SCRIPT_DIR/bin" "$SCRIPT_DIR/lib" "$SCRIPT_DIR/scripts" "$SCRIPT_DIR/compat" "$REPO_HOME/"
  [[ -d "$SCRIPT_DIR/.github" ]] && cp -a "$SCRIPT_DIR/.github" "$REPO_HOME/"
  cp -a "$SCRIPT_DIR/bootstrap.sh" "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/uninstall.sh" "$SCRIPT_DIR/README.md" "$SCRIPT_DIR/LICENSE" "$SCRIPT_DIR/NOTICE" "$REPO_HOME/"
fi
chmod +x "$REPO_HOME/bootstrap.sh" "$REPO_HOME/bin/cline-desktop-linux" "$REPO_HOME/scripts/check-cline-compat.sh" "$REPO_HOME/scripts/build-native.sh" "$REPO_HOME/scripts/download-native-release.sh" "$REPO_HOME/scripts/package-release-native.sh"
ln -sfn "$REPO_HOME/bin/cline-desktop-linux" "$HOME/.local/bin/cline-desktop-linux"
cp "$CLINE_SOURCE/apps/examples/desktop-app/src-tauri/icons/128x128@2x.png" "$ICON_DIR/cline-desktop-linux.png"

{
  printf 'CLINE_SOURCE=%q\n' "$CLINE_SOURCE"
  printf 'BUN_BIN=%q\n' "$BUN"
  printf 'NODE_BIN=%q\n' "$NODE_BIN"
  printf 'CLINE_TESTED_REVISION=%q\n' "$TESTED_REVISION"
  printf 'NATIVE_SOURCE=%q\n' "$NATIVE_SOURCE"
  printf 'NATIVE_RELEASE_REPO=%q\n' "$NATIVE_RELEASE_REPO"
  printf 'NATIVE_RELEASE_TAG=%q\n' "$NATIVE_RELEASE_TAG"
  printf 'DEFAULT_MODE=%q\n' "$MODE"
} > "$CONFIG_DIR/config"

# Remove any user units created by older installers. The complete desktop app
# is launched directly by the user-level launcher now.
if command -v systemctl >/dev/null 2>&1; then
  SYSTEMD_USER_DIR="$CONFIG_HOME/systemd/user"
  for legacy_unit in \
    cline-desktop-linux-headless.service \
    cline-desktop-linux-native.service \
    cline-desktop-headless.service \
    cline-desktop-native.service; do
    systemctl --user stop "$legacy_unit" 2>/dev/null || true
    systemctl --user disable "$legacy_unit" 2>/dev/null || true
    rm -f "$SYSTEMD_USER_DIR/$legacy_unit"
  done
  systemctl --user daemon-reload 2>/dev/null || true
fi

rm -f "$APPLICATIONS_DIR/cline-desktop-linux-browser.desktop"
rm -f "$APPLICATIONS_DIR/cline-desktop-linux-tauri.desktop"
cat > "$APPLICATIONS_DIR/cline-desktop-linux-native.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Cline Desktop
GenericName=AI Coding Agent
Comment=Native Cline Desktop release client
Exec=$HOME/.local/bin/cline-desktop-linux native
Icon=cline-desktop-linux
Terminal=false
Categories=Development;IDE;
Keywords=Cline;AI;Coding;Agent;Native;Tauri;
StartupNotify=true
EOF
chmod 0644 "$APPLICATIONS_DIR/cline-desktop-linux-native.desktop"

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPLICATIONS_DIR" || true
command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental >/dev/null 2>&1 || true

if [[ "$MODE" == native ]]; then
  case "$NATIVE_SOURCE" in
    build)
      "$REPO_HOME/bin/cline-desktop-linux" build-native
      ;;
    prebuilt)
      "$REPO_HOME/bin/cline-desktop-linux" download-native
      ;;
    auto)
      if ! "$REPO_HOME/bin/cline-desktop-linux" download-native; then
        echo "No usable prebuilt Native Release found; building locally." >&2
        "$REPO_HOME/bin/cline-desktop-linux" build-native
      fi
      ;;
  esac
fi

echo "Installed cline-desktop-linux"
echo "  mode=$MODE"
echo "  process=direct"
echo "  source=$CLINE_SOURCE"
echo "Run: cline-desktop-linux start"
