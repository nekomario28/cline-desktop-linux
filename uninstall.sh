#!/usr/bin/env bash
set -euo pipefail
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
REPO_HOME="${CLINE_DESKTOP_LINUX_HOME:-$DATA_HOME/cline-desktop-linux}"

if [[ -x "$HOME/.local/bin/cline-desktop-linux" ]]; then
  "$HOME/.local/bin/cline-desktop-linux" stop >/dev/null 2>&1 || true
elif [[ -x "$REPO_HOME/bin/cline-desktop-linux" ]]; then
  "$REPO_HOME/bin/cline-desktop-linux" stop >/dev/null 2>&1 || true
fi
for legacy_unit in \
  cline-desktop-linux-headless.service \
  cline-desktop-linux-native.service \
  cline-desktop-headless.service \
  cline-desktop-native.service; do
  systemctl --user stop "$legacy_unit" 2>/dev/null || true
  systemctl --user disable "$legacy_unit" 2>/dev/null || true
  rm -f "$CONFIG_HOME/systemd/user/$legacy_unit"
done
systemctl --user daemon-reload 2>/dev/null || true
rm -f "$HOME/.local/bin/cline-desktop-linux"
rm -f "$DATA_HOME/applications/cline-desktop-linux-browser.desktop" \
  "$DATA_HOME/applications/cline-desktop-linux-native.desktop" \
  "$DATA_HOME/applications/cline-desktop-linux-tauri.desktop"
rm -f "$DATA_HOME/icons/hicolor/256x256/apps/cline-desktop-linux.png"
rm -rf "$CONFIG_HOME/cline-desktop-linux" "$STATE_HOME/cline-desktop-linux"
python3 - "$REPO_HOME/native" <<'PY'
from pathlib import Path
import shutil, sys
p = Path(sys.argv[1])
if p.exists() or p.is_symlink():
    if p.is_dir() and not p.is_symlink():
        shutil.rmtree(p)
    else:
        p.unlink()
PY
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DATA_HOME/applications" || true
command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
echo "Removed integration files. Cline source checkout was preserved."
