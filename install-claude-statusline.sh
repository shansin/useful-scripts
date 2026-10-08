#!/bin/bash
# Installer for Claude Code 2-line statusline (bash + jq): model/path/git/cost + context, cache and quota gauges.
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
      "$CLAUDE_DIR/status-line.sh"
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
  echo "WARNING: 'git' not found; git segment will be empty."
fi

# --- STEP 3: install statusline.sh ---
cat > "$TARGET" <<'STATUSLINE_EOF'
#!/bin/bash
# Claude Code status line: two lines.
#   1: model · effort   path   git branch + state   cost
#   2: gauges — context, cache, 5h/7d quotas (smooth bars, green→yellow→red for health)
input=$(cat)

N=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'
fg() { printf '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"; }
bg() { printf '\033[48;2;%s;%s;%sm' "$1" "$2" "$3"; }
GRN=$(fg 74 222 128); YEL=$(fg 250 204 21); RED=$(fg 248 113 113); CYN=$(fg 103 232 249); MUT=$(fg 113 113 122)
BLU=$(fg 129 140 248); PNK=$(fg 244 114 182); VIO=$(fg 192 132 252); TEAL=$(fg 45 212 191)
ORG=$(fg 251 146 60); GOLD=$(fg 234 179 8); SKY=$(fg 125 211 252)
TRACK=$(bg 39 39 46)

IFS=$'\t' read -r model effort cwd ctx cost p5 r5 p7 r7 cexp cttl chit transcript < <(
  printf '%s' "$input" | jq -r '[
    (.model.display_name // .model.id // "-"),
    (.effort.level // "-"),
    (.workspace.current_dir // .cwd // "-"),
    (.context_window.used_percentage // "-"),
    (.cost.total_cost_usd // 0),
    (.rate_limits.five_hour.used_percentage // "-"),
    (.rate_limits.five_hour.resets_at // "-"),
    (.rate_limits.seven_day.used_percentage // "-"),
    (.rate_limits.seven_day.resets_at // "-"),
    (.prompt_cache.expires_at // "-"),
    (.prompt_cache.ttl // "-"),
    (.prompt_cache.hit_ratio // "-"),
    (.transcript_path // "-")
  ] | map(tostring) | join("\t")' 2>/dev/null
)

num() { case "$1" in ''|-|*[!0-9.]*) echo "";; *) printf '%.0f' "$1" 2>/dev/null;; esac; }
now=$(date +%s)
dur() { local s=$1; if [ "$s" -ge 86400 ]; then echo "$((s/86400))d$((s%86400/3600))h";
        elif [ "$s" -ge 3600 ]; then printf '%dh%02d' $((s/3600)) $((s%3600/60)); else echo "$((s/60))m"; fi; }

# bar <pct 0-100> <color>: 8 cells on a dark track, 1/8-cell precision
PART=("" "▏" "▎" "▍" "▌" "▋" "▊" "▉")
bar() {
  local w=8 units=$(( $1 * 64 / 100 )) out="" i
  [ "$1" -gt 0 ] && [ $units -eq 0 ] && units=1
  local full=$(( units / 8 )) rem=$(( units % 8 ))
  for ((i=0;i<full;i++)); do out+="█"; done
  [ $rem -gt 0 ] && { out+="${PART[$rem]}"; full=$((full + 1)); }
  for ((i=full;i<w;i++)); do out+=" "; done
  printf '%s%s%s%s' "$TRACK" "$2" "$out" "$N"
}

SEP="   "
DOT=" ${MUT}·${N} "

# ================= Line 1: who / where =================
l1=""
[ "$model" = "-" ] && model="Claude"
l1+="${CYN}${B}◆ ${model}${N}"
if [ "$effort" != "-" ]; then
  case "$effort" in low) ecol=$SKY;; medium) ecol=$VIO;; high) ecol=$PNK;; *) ecol=$ORG;; esac
  l1+="${DOT}${ecol}${effort}${N}"
fi

[ "$cwd" = "-" ] && cwd=$PWD
short=$cwd
case "$cwd" in "$HOME") short="~";; "$HOME"/*) short="~${cwd#"$HOME"}";; esac
l1+="${SEP}${BLU}${B}${short}${N}"

# Git: branch, ahead/behind, staged / modified / untracked counts
if [ -d "$cwd" ]; then
  gs=$(git --no-optional-locks -C "$cwd" status --porcelain=v2 --branch 2>/dev/null)
  if [ -n "$gs" ]; then
    read -r branch ahead behind staged modified untracked < <(printf '%s\n' "$gs" | awk '
      /^# branch.head/ { b = $3 } /^# branch.oid/ { o = substr($3, 1, 7) }
      /^# branch.ab/   { a = substr($3, 2); h = substr($4, 2) }
      /^[12u] /        { if (substr($2,1,1) != ".") s++; if (substr($2,2,1) != ".") m++ }
      /^\? /           { u++ }
      END { if (b == "(detached)") b = o; printf "%s %d %d %d %d %d\n", b, a, h, s, m, u }')
    git_s="${PNK}⎇ ${branch}${N}"
    [ "$ahead" -gt 0 ] && git_s+=" ${CYN}↑${ahead}${N}"
    [ "$behind" -gt 0 ] && git_s+=" ${ORG}↓${behind}${N}"
    st=""
    [ "$staged" -gt 0 ] && st+=" ${GRN}+${staged}${N}"
    [ "$modified" -gt 0 ] && st+=" ${YEL}~${modified}${N}"
    [ "$untracked" -gt 0 ] && st+=" ${MUT}?${untracked}${N}"
    [ -z "$st" ] && st=" ${GRN}✓${N}"
    l1+="${SEP}${git_s}${st}"
  fi
fi

l1+="${SEP}${GOLD}$(printf '$%.2f' "${cost:-0}" 2>/dev/null)${N}"

# ================= Line 2: gauges =================
l2=""

# Context: bar shows how FULL it is
c=$(num "$ctx")
if [ -n "$c" ]; then
  [ "$c" -gt 100 ] && c=100
  col=$GRN; [ "$c" -ge 60 ] && col=$YEL; [ "$c" -ge 85 ] && col=$RED
  l2+="${VIO}ctx${N} $(bar "$c" "$col") ${col}${B}${c}%${N}"
fi

# Cache: bar shows time LEFT before it goes cold
case "$cttl" in *h) ttl=$(( ${cttl%h} * 3600 ));; *m) ttl=$(( ${cttl%m} * 60 ));; *) ttl=3600;; esac
exp=$(num "$cexp")
if [ -z "$exp" ] && [ -f "$transcript" ]; then   # fallback: last transcript write + TTL
  last=$(stat -f %m "$transcript" 2>/dev/null || stat -c %Y "$transcript" 2>/dev/null)
  [ -n "$last" ] && exp=$(( last + ttl ))
fi
if [ -n "$exp" ]; then
  left=$(( exp - now ))
  if [ "$left" -le 0 ]; then
    l2+="${l2:+$SEP}${TEAL}cache${N} $(bar 0 "$MUT") ${RED}${B}cold${N}"
  else
    pct=$(( left * 100 / ttl )); [ $pct -gt 100 ] && pct=100
    col=$GRN; [ $pct -lt 20 ] && col=$YEL
    at=$(date -r "$exp" +%H:%M 2>/dev/null || date -d "@$exp" +%H:%M 2>/dev/null)
    l2+="${l2:+$SEP}${TEAL}cache${N} $(bar "$pct" "$col") ${col}${B}$(dur "$left")${N} ${MUT}→${at}${N}"
  fi
  # Only mention hit ratio when it's poor
  h=$(awk -v r="$chit" 'BEGIN{ if (r ~ /^[0-9.]+$/) printf "%d", r*100 }')
  [ -n "$h" ] && [ "$h" -lt 50 ] && l2+=" ${YEL}${h}% hit${N}"
fi

# Quotas: bar shows how much is LEFT; color by burn rate vs. time elapsed
quota() {
  local label=$1 used=$(num "$2") reset=$3 win=$4
  [ -z "$used" ] && return; [[ "$reset" =~ ^[0-9]+$ ]] || return
  local rem=$(( reset - now )); [ $rem -lt 0 ] && rem=0; [ $rem -gt "$win" ] && rem=$win
  local elapsed=$(( (win - rem) * 100 / win )) left=$(( 100 - used )); [ $left -lt 0 ] && left=0
  local col=$GRN
  if [ "$used" -gt $((elapsed + 15)) ]; then col=$RED; elif [ "$used" -gt "$elapsed" ]; then col=$YEL; fi
  l2+="${l2:+$SEP}${ORG}${label}${N} $(bar "$left" "$col") ${col}${B}${left}%${N} ${MUT}↻$(dur "$rem")${N}"
}
quota 5h "$p5" "$r5" 18000
quota 7d "$p7" "$r7" 604800

printf '%s\n' "$l1"
if [ -n "$l2" ]; then printf '%s\n' "$l2"; fi
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
