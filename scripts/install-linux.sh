#!/bin/sh
# Install Diffity into the user account: launcher entry, diffity:// handler, and the diffity command.
#   curl -fsSL https://raw.githubusercontent.com/sharifli4/diffity/main/scripts/install-linux.sh | sh
# Use a local AppImage instead of downloading:
#   DIFFITY_APPIMAGE=/path/to/Diffity.AppImage sh scripts/install-linux.sh
set -eu

repo="${DIFFITY_REPO:-sharifli4/diffity}"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
prefix="$data/diffity"
bin_dir="$HOME/.local/bin"
apps="$data/applications"
icon_dir="$data/icons/hicolor/128x128/apps"
appimage="$prefix/Diffity.AppImage"

mkdir -p "$prefix" "$bin_dir" "$apps" "$icon_dir"

if [ -n "${DIFFITY_APPIMAGE:-}" ]; then
  echo "Installing $DIFFITY_APPIMAGE"
  cp "$DIFFITY_APPIMAGE" "$appimage"
else
  echo "Downloading the latest Diffity AppImage…"
  url="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
    | python3 -c 'import json,sys; assets=json.load(sys.stdin)["assets"]; print(next(a["browser_download_url"] for a in assets if a["name"].endswith(".AppImage")))')"
  curl -fL "$url" -o "$appimage.partial"
  mv "$appimage.partial" "$appimage"
fi
chmod 755 "$appimage"

extract="$(mktemp -d)"
icon_src="$extract/squashfs-root/usr/share/icons/hicolor/128x128/apps/diffity-desktop.png"
# Bound the extract. Without FUSE the runtime can sit there instead of printing the icon.
if command -v timeout >/dev/null 2>&1; then
  extract_limit="timeout 20"
else
  extract_limit=""
fi
if (cd "$extract" && $extract_limit "$appimage" --appimage-extract usr/share/icons/hicolor/128x128/apps/diffity-desktop.png >/dev/null 2>&1) && [ -f "$icon_src" ]; then
  cp "$icon_src" "$icon_dir/diffity.png"
else
  curl -fsSL "https://raw.githubusercontent.com/$repo/main/src-tauri/icons/128x128.png" -o "$icon_dir/diffity.png"
fi
rm -rf "$extract"

cat > "$apps/diffity.desktop" << EOF
[Desktop Entry]
Name=Diffity
Comment=Review code changes
Exec=env WEBKIT_DISABLE_DMABUF_RENDERER=1 $appimage %u
Icon=diffity
Terminal=false
Type=Application
Categories=Development;
StartupWMClass=diffity-desktop
MimeType=x-scheme-handler/diffity;
EOF

# The AppImage's own diffity-cli still calls macOS open. This command opens diffity:// with xdg-open.
cat > "$bin_dir/diffity" << 'EOF'
#!/usr/bin/env python3
import os, subprocess, sys, urllib.parse
from pathlib import Path

HELP = """\
Open a repository, a diff or a file in Diffity.

Usage:
  diffity [path | pull request URL] [options]

Arguments:
  path              A folder or file inside a Git repository (default: current folder).
                    A file opens in the Files tab unless --ref is given.
  pull request URL  A GitHub pull request to check out and review, in the current
                    repository or the local clone Diffity knows about.

Options:
  -r, --ref <ref>   The diff to show: work (uncommitted, the default), staged, unstaged,
                    <ref> (everything since HEAD left it, uncommitted included),
                    <a>..<b> or <a>...<b> (commits only)
  -n, --new-window  Open in a new window
  -h, --help        Show this help

Examples:
  diffity                       Uncommitted changes in the current repository
  diffity ~/code/app            Uncommitted changes in ~/code/app
  diffity --ref main            Everything on this branch since it left main
  diffity --ref HEAD~1..HEAD    The last commit
  diffity https://github.com/owner/repo/pull/42
                                Pull request #42
  diffity src/app.ts            src/app.ts in the Files tab
"""

def encode(value: str) -> str:
    return urllib.parse.quote(value, safe="/-._~")

def pr_url(value: str):
    rest = value.removeprefix("https://").removeprefix("http://").removeprefix("www.")
    parts = rest.removeprefix("github.com/").split("/") if rest.startswith("github.com/") else []
    if len(parts) < 4 or parts[2] != "pull" or not parts[3].isdigit():
        return None
    if not parts[0] or not parts[1]:
        return None
    return f"https://github.com/{parts[0]}/{parts[1]}/pull/{parts[3]}"

def repo_root(start: Path) -> Path:
    out = subprocess.run(["git", "-C", str(start), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"diffity: {start} is not inside a Git repository")
    return Path(out.stdout.strip()).resolve()

def parse(argv):
    ref = None
    new_window = False
    target = None
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("-h", "--help"):
            print(HELP, end="")
            raise SystemExit(0)
        if arg in ("-n", "--new-window"):
            new_window = True
        elif arg in ("-r", "--ref"):
            i += 1
            if i >= len(argv) or not argv[i]:
                raise SystemExit("diffity: --ref needs a value")
            ref = argv[i]
        elif arg.startswith("-"):
            raise SystemExit(f"diffity: unknown option {arg}\n\nRun `diffity --help` for usage.")
        else:
            if target is not None:
                raise SystemExit(f"diffity: unexpected argument {arg}")
            target = arg
        i += 1
    return target, ref, new_window

def link(params):
    query = "&".join(f"{key}={encode(value)}" for key, value in params)
    return f"diffity://open?{query}"

def main():
    target, ref, new_window = parse(sys.argv[1:])
    params = []
    pr = pr_url(target) if target else None
    if pr and ref:
        raise SystemExit("diffity: --ref does not apply to a pull request")
    if pr:
        try:
            params.append(("path", str(repo_root(Path.cwd()))))
        except SystemExit:
            pass
        params.append(("pr", pr))
    else:
        given = Path(target or ".").expanduser()
        try:
            resolved = given.resolve(strict=True)
        except FileNotFoundError:
            raise SystemExit(f"diffity: {given}: not found")
        root = repo_root(resolved if resolved.is_dir() else resolved.parent)
        params.append(("path", str(root)))
        if resolved.is_file():
            file = resolved.relative_to(root).as_posix()
            if ref:
                params.append(("ref", ref))
                params.append(("file", file))
            else:
                params.append(("view", "files"))
                params.append(("file", file))
        elif ref:
            params.append(("ref", ref))
    if new_window:
        params.append(("window", "new"))
    url = link(params)
    opener = "xdg-open" if os.name != "nt" else "start"
    result = subprocess.run([opener, url])
    if result.returncode != 0:
        raise SystemExit("diffity: could not open Diffity. Is it installed?")

if __name__ == "__main__":
    main()
EOF
chmod 755 "$bin_dir/diffity"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$apps" >/dev/null 2>&1 || true
fi
if command -v xdg-mime >/dev/null 2>&1; then
  xdg-mime default diffity.desktop x-scheme-handler/diffity
fi

echo ""
echo "Diffity is installed."
echo "  Launcher: Diffity"
echo "  Command:  diffity    (in a Git repository)"
echo "  App:      $appimage"
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "Add $bin_dir to PATH, then open a new terminal." ;;
esac
echo "GitHub sign-in needs an unlocked keyring (gnome-keyring)."
