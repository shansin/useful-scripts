#!/bin/bash
# Installer for Claude Code 1-line compact statusline (bash + jq).
# Usage:
#   ./install-claude-statusline.sh            # clean + install
#   ./install-claude-statusline.sh --uninstall # remove customization only
#   CLAUDE_DIR=~/.claude ./install-claude-statusline.sh
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
TARGET="$CLAUDE_DIR/statusline.sh"

uninstall_only=false
if [ "${1:-}" = "--uninstall" ]; then uninstall_only=true; fi

mkdir -p "$CLAUDE_DIR"
if [ ! -f "$SETTINGS" ]; then echo '{}' > "$SETTINGS"; fi

# --- backup (only if valid JSON, else reset safely) ---
if python3 -c "import json; json.load(open('$SETTINGS'))" 2>/dev/null; then
  BACKUP="$CLAUDE_DIR/settings.json.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$SETTINGS" "$BACKUP"
  echo "Backed up settings -> $BACKUP"
else
  echo "WARNING: $SETTINGS is not valid JSON; resetting to {} (old file saved as .invalid)"
  cp "$SETTINGS" "$CLAUDE_DIR/settings.json.invalid.$(date +%Y%m%d-%H%M%S)"
  echo '{}' > "$SETTINGS"
fi

# --- STEP 1: remove whatever customization already exists ---
echo "Removing existing statusline customization..."
rm -f "$TARGET" "$CLAUDE_DIR/statusline.py" "$CLAUDE_DIR/statusline.js" \
      "$CLAUDE_DIR/status-line.sh" "$HOME/.claude/statusline.sh"
python3 - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
data.pop("statusLine", None)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
echo "  - removed statusLine key + old scripts"

if [ "$uninstall_only" = true ]; then
  echo "Uninstalled. $SETTINGS now has no statusLine."
  exit 0
fi

# --- STEP 2: dependency check ---
if ! command -v jq >/dev/null 2>&1; then
  echo "WARNING: 'jq' not found. Install it first:"
  echo "  macOS:  brew install jq"
  echo "  Ubuntu: sudo apt-get install -y jq"
  echo "Continuing anyway (statusline will not render without jq)..."
fi
if ! command -v git >/dev/null 2>&1; then
  echo "WARNING: 'git' not found; branch segment will be empty."
fi

# --- STEP 3: install statusline.sh (exact config you loved) ---
cat > "$TARGET" <<'STATUSLINE_EOF'
#!/bin/bash
# Claude Code 1-line compact statusline (bash + jq)
# stdin: JSON session data. stdout: single statusline row.
# Shows: model, dir, git, context used, 5h/7d budget remaining + reset,
#        cost, + extras (cache, lines, effort, PR/MR, worktree, agent, vim).
input=$(cat)

jq_get() { echo "$input" | jq -r "$1"; }

# --- terminal width (Claude sets COLUMNS; tput won't work inside statusline) ---
COLS=${COLUMNS:-120}
# strip non-numeric just in case
COLS=$(printf '%s' "$COLS" | tr -cd '0-9')
[ -z "$COLS" ] && COLS=120

# --- colors ---
RST='\033[0m'
DIM='\033[2m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
CYAN='\033[36m'
MAGENTA='\033[35m'

pct_color() {
  # $1 = used pct (0-100 float). green<50 yellow<80 red>=80
  local p=${1%.*}; [ -z "$p" ] && p=0
  if [ "$p" -ge 80 ] 2>/dev/null; then printf '%s' "$RED"
  elif [ "$p" -ge 50 ] 2>/dev/null; then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"; fi
}

fmt_tokens() {
  # 64231 -> 64k, 1500000 -> 1.5M, 950 -> 950
  local n=$1
  case "$n" in ''|null|none) printf '?' ; return ;; esac
  n=${n%.*}
  case "$n" in *[!0-9]*) printf '?' ; return ;; esac
  if [ "$n" -ge 1000000 ] 2>/dev/null; then
    awk -v n="$n" 'BEGIN{printf "%.1fM", n/1000000}' | sed 's/\.0M$/M/'
  elif [ "$n" -ge 1000 ] 2>/dev/null; then
    awk -v n="$n" 'BEGIN{printf "%.0fk", n/1000}'
  else printf '%s' "$n"; fi
}

fmt_rel() {
  # $1 = resets_at epoch. prints 12m / 2h13m / 3d4h / soon
  local target=$1 now diff
  case "$target" in ''|null|none|0) printf ''; return ;; esac
  now=$(date +%s)
  diff=$((target - now))
  if [ "$diff" -le 0 ] 2>/dev/null; then printf 'soon'; return; fi
  if [ "$diff" -lt 60 ]; then printf '%ds' "$diff"
  elif [ "$diff" -lt 3600 ]; then printf '%dm' $((diff/60))
  elif [ "$diff" -lt 86400 ]; then printf '%dh%02dm' $((diff/3600)) $(((diff%3600)/60))
  else printf '%dd%dh' $((diff/86400)) $(((diff%86400)/3600)); fi
}

# --- core fields (single jq each; missing -> empty/0) ---
MODEL=$(jq_get '.model.display_name // empty')
[ -z "$MODEL" ] && MODEL=$(jq_get '.model.id // "claude"')
DIR=$(jq_get '.workspace.current_dir // .cwd // empty')
DIRBASE=${DIR##*/}; [ -z "$DIRBASE" ] && DIRBASE='?'
CTX_PCT=$(jq_get '.context_window.used_percentage // 0')
[ "$CTX_PCT" = "null" ] && CTX_PCT=0
CTX_IN=$(jq_get '.context_window.total_input_tokens // 0')
CTX_SIZE=$(jq_get '.context_window.context_window_size // 200000')
EXCEEDS=$(jq_get '.exceeds_200k_tokens // false')
COST=$(jq_get '.cost.total_cost_usd // 0')
LINES_ADD=$(jq_get '.cost.total_lines_added // 0')
LINES_RM=$(jq_get '.cost.total_lines_removed // 0')

FIVE_USED=$(jq_get '.rate_limits.five_hour.used_percentage // empty')
FIVE_RESET=$(jq_get '.rate_limits.five_hour.resets_at // empty')
SEVEN_USED=$(jq_get '.rate_limits.seven_day.used_percentage // empty')
SEVEN_RESET=$(jq_get '.rate_limits.seven_day.resets_at // empty')
SPEND_USED=$(jq_get '.rate_limits.spend_limit.used_percentage // empty')
SPEND_RESET=$(jq_get '.rate_limits.spend_limit.resets_at // empty')

CACHE_WARM=$(jq_get '.prompt_cache.warm // empty')
CACHE_HIT=$(jq_get '.prompt_cache.hit_ratio // empty')
CACHE_TTL=$(jq_get '.prompt_cache.ttl // empty')
CACHE_EXP=$(jq_get '.prompt_cache.expires_at // empty')

EFFORT=$(jq_get '.effort.level // empty')
FAST=$(jq_get '.fast_mode // false')
VIM=$(jq_get '.vim.mode // empty')
AGENT=$(jq_get '.agent.name // empty')
SESSION=$(jq_get '.session_name // empty')
PR_NUM=$(jq_get '.pr.number // empty')
PR_STATE=$(jq_get '.pr.review_state // empty')
PR_KIND=$(jq_get '.pr.kind // empty')
WT=$(jq_get '.worktree.name // .workspace.git_worktree // empty')
ADDED_N=$(jq_get '(.workspace.added_dirs // []) | length')

# --- git branch (fast, no diff scan to keep 1-line snappy) ---
BRANCH=''
if [ -n "$DIR" ] && [ -d "$DIR" ]; then
  BRANCH=$(git -C "$DIR" branch --show-current 2>/dev/null)
fi

# --- build segments ---
CTX_PCT_INT=$(printf '%s' "$CTX_PCT" | cut -d. -f1)
case "$CTX_PCT_INT" in *[!0-9]*) CTX_PCT_INT=0 ;; esac
CTX_C=$(pct_color "$CTX_PCT_INT")
CTX_TOKS="$(fmt_tokens "$CTX_IN")/$(fmt_tokens "$CTX_SIZE")"
CTX_WARN=''; [ "$EXCEEDS" = "true" ] && CTX_WARN='!'
CTX_SEG=$(printf "${CTX_C}🧠 %s%% %s%s${RST}" "$CTX_PCT_INT" "$CTX_TOKS" "$CTX_WARN")

budget_seg() {
  # $1=used $2=resets_at $3=label ; prints "5h 77%⏳2h12m" colored by used; empty if no data
  local used=$1 reset=$2 label=$3 rem rem_int c rel
  case "$used" in ''|null|none) return 1 ;; esac
  rem=$(awk -v u="$used" 'BEGIN{printf "%.0f", 100-u}')
  rem_int=$(printf '%s' "$rem" | cut -d. -f1)
  c=$(pct_color "${used%.*}")
  rel=$(fmt_rel "$reset")
  if [ -n "$rel" ]; then
    printf "${c}%s %s%%⏳%s${RST}" "$label" "$rem" "$rel"
  else
    printf "${c}%s %s%%${RST}" "$label" "$rem"
  fi
}
B5=$(budget_seg "$FIVE_USED" "$FIVE_RESET" "5h"); B5_OK=$?
B7=$(budget_seg "$SEVEN_USED" "$SEVEN_RESET" "7d"); B7_OK=$?
BSP=''; BSP_OK=1
if [ -n "$SPEND_USED" ] && [ "$SPEND_USED" != "null" ]; then
  BSP=$(budget_seg "$SPEND_USED" "$SPEND_RESET" "spend"); BSP_OK=$?
fi

COST_SEG=$(printf "${DIM}\$%.2f${RST}" "$COST" 2>/dev/null || printf "${DIM}\$?${RST}")

# extras (added only if width allows)
EXTRA1=''  # cache + lines + effort/fast
EXTRA2=''  # pr + worktree/added + agent/vim/session

# cache: ⚡91% / ❄cold
CACHE_SEG=''
if [ -n "$CACHE_HIT" ] && [ "$CACHE_HIT" != "null" ]; then
  HITPCT=$(awk -v h="$CACHE_HIT" 'BEGIN{printf "%.0f", h*100}')
  if [ "$CACHE_WARM" = "true" ]; then CACHE_SEG=$(printf "⚡%s%%" "$HITPCT")
  elif [ "$CACHE_WARM" = "false" ]; then CACHE_SEG=$(printf "❄%s%%" "$HITPCT")
  else CACHE_SEG=$(printf "⚡%s%%" "$HITPCT"); fi
elif [ "$CACHE_WARM" = "false" ]; then CACHE_SEG='❄cold'
elif [ "$CACHE_WARM" = "true" ]; then CACHE_SEG='⚡warm'; fi
# append cache TTL expiry countdown when warm and known
if [ "$CACHE_WARM" = "true" ] && [ -n "$CACHE_EXP" ] && [ "$CACHE_EXP" != "null" ]; then
  CRE=$(fmt_rel "$CACHE_EXP")
  [ -n "$CRE" ] && CACHE_SEG="${CACHE_SEG}⏳${CRE}"
fi

LINES_SEG=''
if { [ "$LINES_ADD" != "0" ] && [ "$LINES_ADD" != "null" ]; } || { [ "$LINES_RM" != "0" ] && [ "$LINES_RM" != "null" ]; }; then
  LINES_SEG=$(printf "${DIM}+%s-%s${RST}" "${LINES_ADD:-0}" "${LINES_RM:-0}")
fi

MODE_SEG=''
[ -n "$EFFORT" ] && [ "$EFFORT" != "null" ] && MODE_SEG="${MODE_SEG}[${EFFORT}]"
[ "$FAST" = "true" ] && MODE_SEG="${MODE_SEG}⚡fast"
MODE_SEG=$(printf '%s' "$MODE_SEG" | sed 's/^ //')

PR_SEG=''
if [ -n "$PR_NUM" ] && [ "$PR_NUM" != "null" ]; then
  KIND='PR'; [ "$PR_KIND" = "mr" ] && KIND='MR'
  case "$PR_STATE" in
    approved) PR_SEG=$(printf "${GREEN}%s#%s ✓${RST}" "$KIND" "$PR_NUM") ;;
    changes_requested) PR_SEG=$(printf "${RED}%s#%s ✗${RST}" "$KIND" "$PR_NUM") ;;
    draft) PR_SEG=$(printf "${DIM}%s#%s 📝${RST}" "$KIND" "$PR_NUM") ;;
    pending|'') PR_SEG=$(printf "${CYAN}%s#%s${RST}" "$KIND" "$PR_NUM") ;;
    *) PR_SEG=$(printf "${CYAN}%s#%s %s${RST}" "$KIND" "$PR_NUM" "$PR_STATE") ;;
  esac
fi

CTX2_SEG=''
[ -n "$WT" ] && [ "$WT" != "null" ] && CTX2_SEG="${CTX2_SEG} ⌥${WT}"
if [ -n "$ADDED_N" ] && [ "$ADDED_N" != "null" ] && [ "$ADDED_N" -gt 0 ] 2>/dev/null; then CTX2_SEG="${CTX2_SEG} +${ADDED_N}d"; fi
[ -n "$AGENT" ] && [ "$AGENT" != "null" ] && CTX2_SEG="${CTX2_SEG} @${AGENT}"
[ -n "$VIM" ] && [ "$VIM" != "null" ] && CTX2_SEG="${CTX2_SEG} ${MAGENTA}${VIM}${RST}"
[ -n "$SESSION" ] && [ "$SESSION" != "null" ] && CTX2_SEG="${CTX2_SEG} ${DIM}#${SESSION}${RST}"
CTX2_SEG=$(printf '%s' "$CTX2_SEG" | sed 's/^ //')

[ -n "$CACHE_SEG" ] && EXTRA1="${EXTRA1} | ${CACHE_SEG}"
[ -n "$LINES_SEG" ] && EXTRA1="${EXTRA1} | ${LINES_SEG}"
[ -n "$MODE_SEG" ] && EXTRA1="${EXTRA1} | ${MODE_SEG}"
[ -n "$PR_SEG" ] && EXTRA2="${EXTRA2} | ${PR_SEG}"
[ -n "$CTX2_SEG" ] && EXTRA2="${EXTRA2} | ${CTX2_SEG}"
[ "$BSP_OK" -eq 0 ] && EXTRA2="${EXTRA2} | ${BSP}"

# --- assemble with width tiers ---
HEAD=$(printf "[%s] 📁 %s" "$MODEL" "$DIRBASE")
[ -n "$BRANCH" ] && HEAD="${HEAD} ${CYAN}🌿 ${BRANCH}${RST}"

BUDGETS=''
[ "$B5_OK" -eq 0 ] && BUDGETS="$B5"
[ "$B7_OK" -eq 0 ] && BUDGETS="${BUDGETS:+$BUDGETS }${B7}"
[ -z "$BUDGETS" ] && BUDGETS=$(printf "${DIM}no limits${RST}")

LINE="${HEAD} | ${CTX_SEG} | ${BUDGETS} | ${COST_SEG}"
# tier 1: >=100 cols -> cache/lines/effort
if [ "$COLS" -ge 100 ]; then LINE="${LINE}${EXTRA1}"; fi
# tier 2: >=130 cols -> pr/worktree/agent/vim/session/spend
if [ "$COLS" -ge 130 ]; then LINE="${LINE}${EXTRA2}"; fi

printf '%b\n' "$LINE"
STATUSLINE_EOF
chmod +x "$TARGET"
echo "Installed $TARGET"

# --- STEP 4: wire into settings.json (absolute path = portable across usernames) ---
TARGET_ABS="$TARGET"
# normalize $HOME prefix already handled; ensure absolute
case "$TARGET_ABS" in ~*) TARGET_ABS="$HOME${TARGET_ABS#"~"}";; esac
python3 - "$SETTINGS" "$TARGET_ABS" <<'PY'
import json, sys
path, target = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
data["statusLine"] = {
    "type": "command",
    "command": target,
    "padding": 0,
    "refreshInterval": 60,
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
echo "Wired statusLine -> $TARGET_ABS (padding 0, refresh 60s)"

# --- STEP 5: smoke test ---
python3 -c "import json; json.load(open('$SETTINGS')); print('settings.json valid')"
SAMPLE='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"cost":{"total_cost_usd":0.01},"context_window":{"total_input_tokens":15500,"context_window_size":200000,"used_percentage":8},"rate_limits":{"five_hour":{"used_percentage":23,"resets_at":1999999999}}}'
echo "$SAMPLE" | COLUMNS=120 "$TARGET"
echo "Done. Restart or start a new Claude Code turn to see the bar."
