#!/usr/bin/env bash
# Interactive walkthrough for passwordless SSH to other machines (e.g. Tailscale peers).
# Usage:
#   ./passwordless-ssh-setup.sh            # pick hosts from `tailscale status` or type them
#   ./passwordless-ssh-setup.sh host1 host2 # skip discovery, set up these hosts
#
# Steps: create an ed25519 key (if missing) -> copy it to each host -> verify login
#        -> optionally add short aliases to ~/.ssh/config.
# Safe to re-run: existing keys, working hosts, and existing config entries are left alone.
# Works with macOS's stock bash 3.2 and Linux.
set -euo pipefail

KEY="${KEY:-$HOME/.ssh/id_ed25519}"
SSH_CONFIG="$HOME/.ssh/config"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32m✔ %s\033[0m\n' "$*"; }
warn() { printf '  \033[33m! %s\033[0m\n' "$*"; }
err()  { printf '  \033[31m✘ %s\033[0m\n' "$*"; }

# Prompts read from the terminal so ssh/ssh-copy-id can't swallow stdin.
ask() {  # ask "Question" default -> echoes answer
    local reply
    printf '  %s [%s]: ' "$1" "$2" > /dev/tty
    read -r reply < /dev/tty || true
    echo "${reply:-$2}"
}
confirm() {  # confirm "Question" (default yes)
    local reply
    printf '  %s [Y/n]: ' "$1" > /dev/tty
    read -r reply < /dev/tty || true
    case "$reply" in [nN]*) return 1 ;; *) return 0 ;; esac
}

find_tailscale() {
    if command -v tailscale >/dev/null 2>&1; then echo tailscale
    elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
        echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
    fi
}

# ---------- Step 1: key ----------
bold "Step 1/4: SSH key"
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
if [ -f "$KEY" ]; then
    ok "Using existing key $KEY"
else
    info "No key at $KEY — creating one."
    info "A passphrase is optional; on macOS step 4 can store it in Keychain."
    ssh-keygen -t ed25519 -f "$KEY" -C "$(whoami)@$(hostname -s)" < /dev/tty
    ok "Created $KEY"
fi
# A passphrase-protected key goes into the agent once, so later steps don't re-prompt.
if ! ssh-keygen -y -P "" -f "$KEY" >/dev/null 2>&1; then
    info "Key has a passphrase — adding it to ssh-agent."
    if [ "$(uname)" = Darwin ]; then ssh-add --apple-use-keychain "$KEY" < /dev/tty || true
    elif [ -n "${SSH_AUTH_SOCK:-}" ]; then ssh-add "$KEY" < /dev/tty || true
    fi
fi
echo

# ---------- Step 2: choose hosts ----------
bold "Step 2/4: Choose machines"
HOSTS=()
if [ $# -gt 0 ]; then
    HOSTS=("$@")
else
    TS="$(find_tailscale)"
    PEERS=()
    if [ -n "$TS" ]; then
        # status columns: IP NAME USER OS STATUS...
        self_ip="$("$TS" ip -4 2>/dev/null || true)"
        while read -r ip name _ os rest; do
            [ "$ip" = "$self_ip" ] && continue
            case "$os" in linux|macOS) ;; *) continue ;; esac
            case "$rest" in *offline*) continue ;; esac
            PEERS+=("$name")
        done < <("$TS" status 2>/dev/null | awk '$1 ~ /^100\./')
    fi
    if [ ${#PEERS[@]} -gt 0 ]; then
        info "Online Tailscale machines (Linux/macOS):"
        for i in "${!PEERS[@]}"; do printf '    %2d) %s\n' $((i + 1)) "${PEERS[$i]}"; done
        info "Enter numbers and/or hostnames separated by spaces (e.g. 1 3 myhost)."
    else
        info "No Tailscale peers found. Enter hostnames or IPs separated by spaces."
    fi
    picks="$(ask "Machines" "none")"; [ "$picks" = none ] && picks=""
    for p in $picks; do
        if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le ${#PEERS[@]} ]; then
            HOSTS+=("${PEERS[$((p - 1))]}")
        else
            HOSTS+=("$p")
        fi
    done
fi
if [ ${#HOSTS[@]} -eq 0 ]; then err "No machines chosen."; exit 1; fi
ok "Setting up: ${HOSTS[*]}"
echo

# ---------- Step 3: copy key + verify ----------
bold "Step 3/4: Copy key to each machine"
DONE_HOSTS=(); DONE_USERS=(); FAILED=()
for h in "${HOSTS[@]}"; do
    echo
    bold "  → $h"
    u="$(ask "Username on $h" "$(whoami)")"
    target="$u@$h"
    if ssh -n -o PreferredAuthentications=publickey -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
           -i "$KEY" "$target" true 2>/dev/null; then
        ok "Key login already works — skipping copy."
    else
        info "You'll be asked for $target's password one last time."
        if command -v ssh-copy-id >/dev/null 2>&1; then
            ssh-copy-id -i "$KEY.pub" -o StrictHostKeyChecking=accept-new "$target" < /dev/tty || true
        else
            ssh -o StrictHostKeyChecking=accept-new "$target" \
                'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys' < "$KEY.pub" || true
        fi
    fi
    if ssh -n -o PreferredAuthentications=publickey -o ConnectTimeout=5 -i "$KEY" "$target" true 2>/dev/null; then
        ok "Passwordless login to $target works."
        DONE_HOSTS+=("$h"); DONE_USERS+=("$u")
    else
        err "Still can't log in to $target without a password."
        info "On $h, check: chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
        info "and that sshd allows PubkeyAuthentication."
        FAILED+=("$h")
    fi
done
echo

# ---------- Step 4: ~/.ssh/config aliases ----------
bold "Step 4/4: Short aliases in $SSH_CONFIG (optional)"
if [ ${#DONE_HOSTS[@]} -gt 0 ] && confirm "Add aliases so you can type 'ssh <alias>'?"; then
    touch "$SSH_CONFIG" && chmod 600 "$SSH_CONFIG"
    cp "$SSH_CONFIG" "$SSH_CONFIG.bak.$(date +%Y%m%d-%H%M%S)"
    if [ "$(uname)" = Darwin ] && ! grep -q 'UseKeychain' "$SSH_CONFIG"; then
        printf '\nHost *\n  AddKeysToAgent yes\n  UseKeychain yes\n  IdentityFile %s\n' "$KEY" >> "$SSH_CONFIG"
        ok "Added Keychain settings (passphrase remembered)."
    fi
    for i in "${!DONE_HOSTS[@]}"; do
        h="${DONE_HOSTS[$i]}"
        alias_name="$(ask "Alias for $h" "${h%-linux}")"
        if awk -v a="$alias_name" 'tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i == a) f = 1 }
                                   END { exit !f }' "$SSH_CONFIG"; then
            warn "'Host $alias_name' already exists — left unchanged."
            continue
        fi
        printf '\nHost %s\n  HostName %s\n  User %s\n  IdentityFile %s\n' \
            "$alias_name" "$h" "${DONE_USERS[$i]}" "$KEY" >> "$SSH_CONFIG"
        ok "ssh $alias_name  →  ${DONE_USERS[$i]}@$h"
    done
else
    info "Skipped."
fi
echo

# ---------- Summary ----------
bold "Summary"
[ ${#DONE_HOSTS[@]} -gt 0 ] && ok "Working: ${DONE_HOSTS[*]}"
[ ${#FAILED[@]} -gt 0 ] && err "Failed: ${FAILED[*]}"
if [ ${#FAILED[@]} -gt 0 ]; then exit 1; fi
