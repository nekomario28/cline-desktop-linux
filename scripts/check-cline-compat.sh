#!/usr/bin/env bash
set -euo pipefail

CLINE_SOURCE="${1:-}"
shift || true
BUILD_SDK=no

while (($#)); do
  case "$1" in
    --build-sdk) BUILD_SDK=yes; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$CLINE_SOURCE" ]] || { echo "usage: $0 PATH_TO_CLINE [--build-sdk]" >&2; exit 2; }
[[ -d "$CLINE_SOURCE/.git" ]] || { echo "not a Cline git checkout: $CLINE_SOURCE" >&2; exit 1; }

for path in \
  package.json \
  apps/examples/desktop-app/package.json \
  apps/examples/desktop-app/scripts/dev-headless.ts \
  apps/examples/desktop-app/scripts/build-sidecar-bin.ts \
  apps/examples/desktop-app/src-tauri/tauri.conf.json \
  apps/examples/desktop-app/src-tauri/src/main.rs; do
  [[ -f "$CLINE_SOURCE/$path" ]] || { echo "missing upstream contract path: $path" >&2; exit 1; }
done

python3 - "$CLINE_SOURCE" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
package = json.loads((root / "package.json").read_text())
desktop = json.loads((root / "apps/examples/desktop-app/package.json").read_text())
tauri = json.loads((root / "apps/examples/desktop-app/src-tauri/tauri.conf.json").read_text())

if package.get("packageManager") != "bun@1.3.13":
    raise SystemExit(f"unsupported packageManager: {package.get('packageManager')!r}")

node_range = str(package.get("engines", {}).get("node", ""))
if "22" not in node_range:
    raise SystemExit(f"upstream Node contract changed: {node_range!r}")

scripts = desktop.get("scripts", {})
for name in ("build:sidecar:bin", "build:binary", "dev:headless"):
    if not scripts.get(name):
        raise SystemExit(f"missing desktop script: {name}")

bundle = tauri.get("bundle", {})
external = bundle.get("externalBin", [])
if "bin/code-sidecar" not in external:
    raise SystemExit("Tauri externalBin no longer contains bin/code-sidecar")

frontend = tauri.get("build", {}).get("frontendDist")
if frontend != "../webview/out":
    raise SystemExit(f"unexpected Tauri frontendDist: {frontend!r}")
PY

main_rs="$CLINE_SOURCE/apps/examples/desktop-app/src-tauri/src/main.rs"
grep -q 'CLINE_CODE_SIDECAR_BIN' "$main_rs" || {
  echo "release sidecar override contract disappeared: CLINE_CODE_SIDECAR_BIN" >&2
  exit 1
}

revision="$(git -C "$CLINE_SOURCE" rev-parse HEAD)"
echo "cline_revision=$revision"
echo "compatibility_contract=ok"

if [[ "$BUILD_SDK" == yes ]]; then
  command -v bun >/dev/null 2>&1 || { echo "bun is required for --build-sdk" >&2; exit 1; }
  (cd "$CLINE_SOURCE" && bun run build:sdk)
fi
