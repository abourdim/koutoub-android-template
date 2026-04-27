#!/usr/bin/env bash
# ============================================================================
#  koutoub-spawn.sh — generate a Capacitor Android wrapper repo for one book
#
#  Usage:
#    ./koutoub-spawn.sh <slug>              # spawn locally
#    ./koutoub-spawn.sh <slug> --push       # also create+push GitHub repo
#    ./koutoub-spawn.sh <slug> --force      # overwrite existing target dir
#
#  Reads books.yaml, looks up <slug>, renders all template files into
#  ../<slug>-android/, clones the source web app www/, overlays Capacitor
#  helpers, and prints a manual TODO checklist.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

# ---------- colors ----------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  CYAN=$'\033[36m'; MAGENTA=$'\033[35m'
else BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; CYAN=""; MAGENTA=""; fi

ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
err()  { printf "  ${RED}✗${RESET} %s\n" "$*"; }
info() { printf "  ${CYAN}ℹ${RESET} %s\n" "$*"; }
head1(){ printf "\n${BOLD}${MAGENTA}══ %s ══${RESET}\n\n" "$*"; }

# ---------- args ----------
SLUG="${1:-}"
PUSH=0
FORCE=0
ALLOW_DRAFT=0
shift || true
for arg in "$@"; do
  case "$arg" in
    --push)  PUSH=1 ;;
    --force) FORCE=1 ;;
    --draft) ALLOW_DRAFT=1 ;;
    *) err "unknown flag: $arg"; exit 2 ;;
  esac
done

if [ -z "$SLUG" ]; then
  cat <<EOF
${BOLD}koutoub-spawn${RESET} — generate an Android wrapper repo for one book

  ${CYAN}./koutoub-spawn.sh <slug>${RESET}              spawn locally
  ${CYAN}./koutoub-spawn.sh <slug> --push${RESET}       also push to GitHub
  ${CYAN}./koutoub-spawn.sh <slug> --force${RESET}      overwrite existing dir

Slugs available in books.yaml:
EOF
  python3 -c "import yaml,sys; [print(f'  - {b[\"slug\"]}') for b in yaml.safe_load(open('$TPL_DIR/books.yaml'))['books']]" 2>/dev/null || true
  exit 1
fi

# ---------- prerequisites ----------
command -v python3 >/dev/null || { err "python3 required"; exit 1; }
python3 -c "import yaml" 2>/dev/null || { err "PyYAML required: pip install pyyaml"; exit 1; }
command -v git >/dev/null || { err "git required"; exit 1; }

[ -f "$TPL_DIR/books.yaml" ] || { err "books.yaml not found at $TPL_DIR"; exit 1; }

# ---------- look up book ----------
TARGET_DIR="$PARENT_DIR/${SLUG}-android"
BOOK_JSON="$(ALLOW_DRAFT=$ALLOW_DRAFT python3 - "$TPL_DIR/books.yaml" "$SLUG" <<'PY'
import sys, yaml, json, datetime, re
yaml_path, slug = sys.argv[1], sys.argv[2]
data = yaml.safe_load(open(yaml_path))
book = next((b for b in data['books'] if b['slug'] == slug), None)
if not book:
    print(f"NOT_FOUND", file=sys.stderr); sys.exit(1)
# Draft guard
import os
if book.get('draft', False) and os.environ.get('ALLOW_DRAFT', '0') != '1':
    print(f"DRAFT", file=sys.stderr); sys.exit(2)
# Derived fields
book['SLUG'] = slug                                            # uppercase token
# Allow per-book override for APPID_SEGMENT and APP_ID (e.g. when slug starts with a digit,
# Java package rules require a letter prefix — slugs like 3d-lab need 'app3dlab' not '3dlab').
if 'APPID_SEGMENT' not in book:
    book['APPID_SEGMENT'] = re.sub(r'[^a-z0-9]', '', slug.lower())
    if book['APPID_SEGMENT'][:1].isdigit():
        book['APPID_SEGMENT'] = 'app' + book['APPID_SEGMENT']
if 'APP_ID' not in book:
    book['APP_ID'] = f"org.workshopdiy.{book['APPID_SEGMENT']}"
book['AVD_NAME'] = slug.replace('-', '_') + '_test'
book['SOURCE_BOOK_REPO'] = f"abourdim/{slug}"
book['DATE'] = datetime.date.today().isoformat()
print(json.dumps(book, ensure_ascii=False))
PY
)" || {
  rc=$?
  if [ $rc -eq 2 ]; then
    err "'$SLUG' is marked draft: true in books.yaml — fill in TODO fields then re-run, or pass --draft to spawn anyway"
  else
    err "slug not in books.yaml: $SLUG"
  fi
  exit 1
}

APP_NAME=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['APP_NAME'])" "$BOOK_JSON")
APP_ID=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['APP_ID'])" "$BOOK_JSON")
SRC_REPO=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['SOURCE_BOOK_REPO'])" "$BOOK_JSON")

head1 "Spawning ${APP_NAME} (${SLUG})"
info "target dir: $TARGET_DIR"
info "appId:      $APP_ID"
info "src repo:   $SRC_REPO"
info "push:       $([ $PUSH -eq 1 ] && echo yes || echo no)"

# ---------- target dir guard ----------
if [ -e "$TARGET_DIR" ]; then
  if [ $FORCE -eq 1 ]; then
    warn "target exists — removing (--force)"
    rm -rf "$TARGET_DIR"
  else
    err "target already exists: $TARGET_DIR (use --force to overwrite)"
    exit 1
  fi
fi
mkdir -p "$TARGET_DIR"

# ---------- render template tree ----------
head1 "Rendering template files"

python3 - "$TPL_DIR" "$TARGET_DIR" "$BOOK_JSON" <<'PY'
import sys, os, shutil, json, pathlib, fnmatch

tpl, dst, book_json = sys.argv[1], sys.argv[2], sys.argv[3]
book = json.loads(book_json)

# files we DO NOT copy from the template into the rendered repo
EXCLUDE_FILES = {'books.yaml', 'koutoub-spawn.sh'}
EXCLUDE_DIRS  = {'docs', 'www-overlay', '.git', '_bulk-logs', 'node_modules', 'android', 'ios', 'releases'}

# files that should NOT have placeholder substitution (binary or copy-as-is)
NO_RENDER_PATTERNS = ['*.png', '*.jpg', '*.jpeg', '*.svg', '*.apk', '*.aab', '*.ipa', '*.keystore', '*.jks']

def render_text(text: str, vars: dict) -> str:
    for k, v in vars.items():
        text = text.replace('{{' + k + '}}', str(v))
    return text

def is_renderable(name: str) -> bool:
    return not any(fnmatch.fnmatch(name.lower(), pat) for pat in NO_RENDER_PATTERNS)

# Mapping for file renames during render
RENAME = {
    'README.md.tpl':    'README.md',
    'LICENSE.template': 'LICENSE',
    'README.md':        '_TEMPLATE_README.md',  # the template's own README → ignored
}

count_files = 0
count_dirs  = 0
for root, dirs, files in os.walk(tpl):
    rel_root = os.path.relpath(root, tpl)
    # prune excluded dirs
    parts = rel_root.split(os.sep)
    if any(p in EXCLUDE_DIRS for p in parts):
        continue
    if rel_root == '.':
        rel_root = ''

    target_root = os.path.join(dst, rel_root)
    os.makedirs(target_root, exist_ok=True)
    if rel_root:
        count_dirs += 1

    for fn in files:
        if fn in EXCLUDE_FILES:
            continue
        # skip the template's own top-level README (it documents the template, not the spawned repo)
        if rel_root == '' and fn == 'README.md':
            continue
        out_name = RENAME.get(fn, fn)
        if out_name == '_TEMPLATE_README.md':
            continue
        src_path = os.path.join(root, fn)
        out_path = os.path.join(target_root, out_name)
        if is_renderable(fn):
            try:
                txt = open(src_path, 'r', encoding='utf-8').read()
            except UnicodeDecodeError:
                shutil.copy2(src_path, out_path)
                continue
            open(out_path, 'w', encoding='utf-8').write(render_text(txt, book))
            # preserve exec bit
            mode = os.stat(src_path).st_mode
            if mode & 0o111:
                os.chmod(out_path, mode)
        else:
            shutil.copy2(src_path, out_path)
        count_files += 1

print(f"  rendered {count_files} files in {count_dirs+1} dirs")
PY

ok "template rendered"

# ---------- clone source www/ ----------
head1 "Fetching source web app www/"
mkdir -p "$TARGET_DIR/www"
TMP_WWW="$(mktemp -d)"
trap "rm -rf $TMP_WWW" EXIT

if git clone --depth=1 -q "https://github.com/${SRC_REPO}.git" "$TMP_WWW/src"; then
  ok "cloned $SRC_REPO"
  src_size=$(du -sh "$TMP_WWW/src" | awk '{print $1}')
  # Slim the source: keep runtime files, drop docs/marketing/firmware-source.
  # Excluded directories: docs, etsy-package, makecode-extension, tests, .github
  # Excluded file patterns: *.md, *.ts (firmware source), pxt.json, package.json, package-lock.json, etc.
  ( cd "$TMP_WWW/src" && tar -cf - \
      --exclude='.git' \
      --exclude='./docs' --exclude='./etsy-package' --exclude='./makecode-extension' \
      --exclude='./tests' --exclude='./.github' --exclude='./node_modules' \
      --exclude='./.vscode' --exclude='./.idea' \
      --exclude='*.md' --exclude='*.ts' \
      --exclude='./pxt.json' --exclude='./product.json' \
      --exclude='./package.json' --exclude='./package-lock.json' \
      --exclude='./.gitignore' --exclude='./.gitattributes' \
      --exclude='./LICENSE' --exclude='./LICENSE.txt' \
      --exclude='./tests.html' --exclude='./_TEMPLATE_README.md' \
      . ) | ( cd "$TARGET_DIR/www" && tar -xf - )
  dst_size=$(du -sh "$TARGET_DIR/www" | awk '{print $1}')
  ok "www/ populated ($(ls "$TARGET_DIR/www" | wc -l) entries, slimmed $src_size → $dst_size)"
else
  warn "could not clone $SRC_REPO — leaving www/ empty (you can populate it manually)"
fi

# ---------- overlay www-overlay/ files (e.g. tts-polyfill.js) ----------
# Skip BLE-specific overlays here — they're applied conditionally below.
if [ -d "$TPL_DIR/www-overlay" ] && [ -n "$(ls -A "$TPL_DIR/www-overlay" 2>/dev/null)" ]; then
  head1 "Overlaying Capacitor helpers into www/"
  for f in "$TPL_DIR/www-overlay"/*; do
    base=$(basename "$f")
    case "$base" in
      web-bluetooth-shim.js) continue ;;  # BLE-only, applied below
    esac
    cp "$f" "$TARGET_DIR/www/"
    ok "overlaid $base"
  done
fi

# ---------- BLE wiring (if books.yaml has needs_ble: true) ----------
NEEDS_BLE=$(printf '%s' "$BOOK_JSON" | python3 -c "import json,sys; b=json.load(sys.stdin); print('1' if b.get('needs_ble') else '0')" 2>/dev/null || echo 0)
if [ "$NEEDS_BLE" = "1" ]; then
  head1 "BLE wiring (needs_ble: true)"
  # 1. Copy shim into www/
  cp "$TPL_DIR/www-overlay/web-bluetooth-shim.js" "$TARGET_DIR/www/web-bluetooth-shim.js"
  ok "shim → www/web-bluetooth-shim.js"

  # 2. Inject <script> tags into www/index.html (cordova.js bridge + shim, before app code)
  python3 - <<PY
import pathlib
p = pathlib.Path("$TARGET_DIR/www/index.html")
if not p.exists():
    print('  ! www/index.html not found — skipping injection')
else:
    s = p.read_text()
    if 'web-bluetooth-shim.js' in s:
        print('  · already injected')
    else:
        tags = '<script src="cordova.js"></script>\n<script src="cordova_plugins.js"></script>\n<script src="web-bluetooth-shim.js"></script>\n'
        if '<head>' in s:
            s = s.replace('<head>', '<head>\n' + tags, 1)
        else:
            s = tags + s
        p.write_text(s)
        print('  ✓ injected script tags into www/index.html')
PY

  # 3. Add @capacitor-community/bluetooth-le to package.json dependencies
  python3 - <<PY
import json, pathlib
p = pathlib.Path("$TARGET_DIR/package.json")
d = json.loads(p.read_text())
deps = d.setdefault('dependencies', {})
if '@capacitor-community/bluetooth-le' not in deps:
    deps['@capacitor-community/bluetooth-le'] = '^8.1.3'
    p.write_text(json.dumps(d, indent=2))
    print('  ✓ added @capacitor-community/bluetooth-le to package.json')
else:
    print('  · BLE plugin already in package.json')
PY

  # 4. Copy _patch_ble.py into wrapper so manage-*.sh can call it after `cap add android`
  cp "$TPL_DIR/_patch_ble.py" "$TARGET_DIR/_patch_ble.py"
  chmod +x "$TARGET_DIR/_patch_ble.py"
  ok "_patch_ble.py copied (run after `npx cap add android` to wire AndroidManifest)"
fi

# ---------- git init ----------
head1 "git init"
( cd "$TARGET_DIR" && git init -q -b main && git add . && git commit -q -m "Initial commit: spawned from koutoub-android-template ($(date +%Y-%m-%d))" )
ok "initial commit created"

# ---------- optional push ----------
if [ $PUSH -eq 1 ]; then
  head1 "Creating GitHub repo + push"
  if command -v gh >/dev/null; then
    ( cd "$TARGET_DIR" && gh repo create "abourdim/${SLUG}-android" \
        --public \
        --description "Capacitor Android/iOS wrapper for ${APP_NAME} — Sheikh Mohammed al-Ghazali" \
        --source=. --push )
    ok "pushed to https://github.com/abourdim/${SLUG}-android"
  else
    warn "gh CLI not found — skipping push. Run: cd $TARGET_DIR && gh repo create ..."
  fi
fi

# ---------- next steps ----------
head1 "Next steps for ${APP_NAME}"
cat <<EOF
  ${BOLD}1.${RESET} Generate visual assets (these are book-specific, the template has no defaults):
       ${DIM}- store-assets/play-store-icon-512.png  (512×512 app icon)${RESET}
       ${DIM}- store-assets/feature-graphic.png      (1024×500, render store-assets/feature-graphic.html)${RESET}
  ${BOLD}2.${RESET} Review per-book copy:
       ${DIM}- $TARGET_DIR/PLAY_STORE_LISTING.md${RESET}
       ${DIM}- $TARGET_DIR/index.html (landing)${RESET}
  ${BOLD}3.${RESET} Run the build menu:
       ${CYAN}cd $TARGET_DIR && ./manage.sh${RESET}
       ${DIM}This will: install npm deps → cap add android → build APK → optionally launch emulator${RESET}
  ${BOLD}4.${RESET} Verify the APK on a device, then publish:
       ${DIM}- Sign release AAB (option 8 in manage menu)${RESET}
       ${DIM}- Upload to Play Console using PLAY_STORE_LISTING.md${RESET}
EOF

[ $PUSH -eq 0 ] && info "spawn complete (local only). Pass --push to also create the GitHub repo."

ok "done."
