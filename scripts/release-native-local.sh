#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLINE_SOURCE="${CLINE_SOURCE:-$HOME/Documents/cline-desktop}"
DIST_DIR="$PROJECT_ROOT/dist"
PUBLISH_TAG=""
PUBLISH=no
BUN_BIN="${BUN_BIN:-$HOME/.bun/bin/bun}"

usage() {
  cat <<EOF
Usage: $0 [options]
  --cline-source PATH   Tested Cline checkout (default: ~/Documents/cline-desktop)
  --dist-dir PATH       Release asset directory (default: ./dist)
  --publish TAG         Upload assets to a GitHub Release from this machine (e.g. v0.0.32-linux.1)
  --bun PATH             Bun binary (default: ~/.bun/bin/bun)

Without --publish this only builds and verifies local assets. With --publish,
the tag must already exist on origin, gh must be authenticated, and the
release is created or updated locally; no GitHub Actions runner is used.
EOF
}

while (($#)); do
  case "$1" in
    --cline-source) (($# >= 2)) || { echo "missing value for --cline-source" >&2; exit 2; }; CLINE_SOURCE="$2"; shift 2 ;;
    --cline-source=*) CLINE_SOURCE="${1#*=}"; shift ;;
    --dist-dir) (($# >= 2)) || { echo "missing value for --dist-dir" >&2; exit 2; }; DIST_DIR="$2"; shift 2 ;;
    --dist-dir=*) DIST_DIR="${1#*=}"; shift ;;
    --publish) (($# >= 2)) || { echo "missing value for --publish" >&2; exit 2; }; PUBLISH_TAG="$2"; PUBLISH=yes; shift 2 ;;
    --publish=*) PUBLISH_TAG="${1#*=}"; PUBLISH=yes; shift ;;
    --bun) (($# >= 2)) || { echo "missing value for --bun" >&2; exit 2; }; BUN_BIN="$2"; shift 2 ;;
    --bun=*) BUN_BIN="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for cmd in git python3 sha256sum tar mktemp gh; do
  if [[ "$cmd" == gh && "$PUBLISH" != yes ]]; then
    continue
  fi
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing local release dependency: $cmd" >&2; exit 1; }
done

[[ -d "$CLINE_SOURCE/.git" ]] || { echo "not a Cline git checkout: $CLINE_SOURCE" >&2; exit 1; }
[[ -x "$BUN_BIN" ]] || { echo "Bun not found: $BUN_BIN" >&2; exit 1; }

tested_revision="$(tr -d '[:space:]' < "$PROJECT_ROOT/compat/cline-tested-revision.txt")"
source_revision="$(git -C "$CLINE_SOURCE" rev-parse HEAD)"
[[ "$source_revision" == "$tested_revision" ]] || {
  echo "local release requires tested Cline revision $tested_revision" >&2
  echo "current Cline revision is $source_revision" >&2
  exit 1
}

"$PROJECT_ROOT/scripts/check-cline-compat.sh" "$CLINE_SOURCE"
build_home="$(mktemp -d /tmp/cldl-release-build.XXXXXX)"
export CLDL_BUILD_BASELINE="local-system"
"$PROJECT_ROOT/scripts/package-release-native.sh" \
  --cline-source "$CLINE_SOURCE" \
  --dist-dir "$DIST_DIR" \
  --app-home "$build_home" \
  --bun "$BUN_BIN"

(
  cd "$DIST_DIR"
  sha256sum -c SHA256SUMS
  archive_count="$(find . -maxdepth 1 -type f -name '*-x86_64.tar.gz' | wc -l)"
  deb_count="$(find . -maxdepth 1 -type f -name '*.deb' | wc -l)"
  [[ "$archive_count" -eq 1 && "$deb_count" -eq 1 ]] || {
    echo "release asset count is invalid" >&2
    exit 1
  }
  check_dir="$(mktemp -d /tmp/cldl-release-check.XXXXXX)"
  tar -xzf ./*-x86_64.tar.gz -C "$check_dir"
  test -x "$check_dir/usr/bin/cline-app"
  test -x "$check_dir/usr/bin/code-sidecar"
  actual="$(sed -n 's/^CLINE_REVISION=//p' "$check_dir/.cline-desktop-linux-release")"
  test "$actual" = "$tested_revision"
  echo "local_release_assets=verified"
  echo "local_release_check=$check_dir"
  echo "local_release_build_home=$build_home"
)

if [[ "$PUBLISH" == yes ]]; then
  [[ "$PUBLISH_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
    echo "--publish requires a SemVer tag such as v0.0.32-linux.1" >&2
    exit 2
  }
  repo="$(git -C "$PROJECT_ROOT" remote get-url origin | sed -E 's#^https://github.com/##; s#\.git$##')"
  [[ "$repo" != */* ]] && { echo "origin must be a GitHub OWNER/REPO URL" >&2; exit 1; }
  if gh release view "$PUBLISH_TAG" --repo "$repo" >/dev/null 2>&1; then
    gh release upload "$PUBLISH_TAG" "$DIST_DIR"/* --repo "$repo" --clobber
  else
    gh release create "$PUBLISH_TAG" "$DIST_DIR"/* --repo "$repo" --verify-tag --generate-notes --title "$PUBLISH_TAG"
  fi
  echo "github_release=$repo/releases/tag/$PUBLISH_TAG"
fi

echo "release_dist=$DIST_DIR"
