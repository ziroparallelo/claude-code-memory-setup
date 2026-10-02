#!/bin/bash
# Sync Claude → Obsidian
# Run manually or via /save.
#
# Adapted for the AI AGENCY vault (2026-10-02):
#   - one run at a time (several sessions may call /save together);
#   - chats with a possible secret (gitleaks) or bigger than MAX_MB stay out of the vault, in $ASIDE_DIR;
#   - only the RECENT most recent Claude Code sessions are exported (thousands exist: never --all).

# ============================================================================
# CONFIGURATION — edit these paths
# ============================================================================

VAULT_DIR="$HOME/AI AGENCY/_VAULT"        # path to your Obsidian vault
EXPORT_DIR="$HOME/claude-exports"        # staging area for exported chats
ASIDE_DIR="$HOME/claude-exports-da-guardare"  # chats kept out of the vault (possible secret, too big)
SCRIPT_DIR="$HOME/scripts"               # where this script and the .py live
LOG="$SCRIPT_DIR/claude_obsidian_sync.log"
RECENT="${RECENT:-20}"                   # how many recent Claude Code sessions to export each run
MAX_MB="${MAX_MB:-20}"                   # GitHub refuses files over 100 MB; the vault is pushed by obsidian-git
LOCK_DIR="$EXPORT_DIR/.sync.lock"

# ============================================================================

mkdir -p "$EXPORT_DIR/code" "$EXPORT_DIR/web" "$ASIDE_DIR"

# One run at a time; a lock older than an hour is left over by a killed run and is taken over
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
        touch "$LOCK_DIR"
        echo "[$(date)] Stale lock taken over" >> "$LOG"
    else
        echo "[$(date)] Another sync is running: skipped" >> "$LOG"
        echo "Another sync is running: skipped"
        exit 0
    fi
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

echo "[$(date)] Starting sync..." >> "$LOG"

# 1. Export Claude Code chats (requires claude-conversation-extractor)
if command -v claude-extract &> /dev/null; then
    claude-extract --recent "$RECENT" --output "$EXPORT_DIR/code" >> "$LOG" 2>&1
    echo "[$(date)] Claude Code chats exported" >> "$LOG"
else
    echo "[$(date)] claude-extract not found — install with:" >> "$LOG"
    echo "[$(date)]   uv tool install claude-conversation-extractor" >> "$LOG"
    echo "[$(date)] Skipping Code export" >> "$LOG"
fi

# 2. Keep out of the vault every chat with a possible secret, and every chat too big for git
if command -v gitleaks &> /dev/null; then
    REPORT="$EXPORT_DIR/.gitleaks.json"
    gitleaks detect --no-git --source "$EXPORT_DIR" --redact --no-banner \
        --report-format json --report-path "$REPORT" >> "$LOG" 2>&1
    python3 - "$REPORT" "$ASIDE_DIR" >> "$LOG" 2>&1 <<'PYEOF'
import json, pathlib, shutil, sys
report, aside = sys.argv[1], pathlib.Path(sys.argv[2])
try:
    found = {f["File"] for f in json.load(open(report))}
except (OSError, ValueError, TypeError, KeyError):
    found = set()
for name in sorted(found):
    p = pathlib.Path(name)
    if p.suffix == ".md" and p.exists():
        shutil.move(str(p), str(aside / p.name))
        print(f"possible secret, kept out of the vault: {p.name}")
PYEOF
else
    echo "[$(date)] gitleaks not found: secret scan skipped, nothing imported" >> "$LOG"
    exit 0
fi
find "$EXPORT_DIR/code" "$EXPORT_DIR/web" -name '*.md' -size +"${MAX_MB}"M -exec mv {} "$ASIDE_DIR/" \; -print >> "$LOG" 2>&1

# 3. Process and send to vault
#    Web chats should be manually exported via browser extension
#    and dropped into $EXPORT_DIR/web/ — they'll be processed too.
python3 "$SCRIPT_DIR/claude_to_obsidian.py" \
    --export-dir "$EXPORT_DIR" \
    --vault-dir "$VAULT_DIR" \
    --move >> "$LOG" 2>&1

echo "[$(date)] Sync completed" >> "$LOG"
echo "" >> "$LOG"
