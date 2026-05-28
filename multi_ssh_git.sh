#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2046
set -euo pipefail

# ============================================================
# Multi-SSH-Key Git Repository Manager
#
# Manages SSH keys and repositories across multiple Git hosts
# simultaneously. Passphrases are read from environment variables
# or prompted interactively at runtime.
#
# Usage:
#   ./multi_ssh_git.sh [setup|sync|test|list|help]
#
# Quick start:
#   export GITHUB_SSH_PASSPHRASE="my-github-pass"
#   export GITLAB_SSH_PASSPHRASE="my-gitlab-pass"
#   ./multi_ssh_git.sh sync
# ============================================================


# ============================================================
# >>>  CONFIGURATION  <<<
# Edit the arrays below to describe your resources and repos.
# All arrays are positionally aligned: index 0 is one resource,
# index 1 is another, etc.
# ============================================================

# Hostnames of your Git services
declare -a GIT_HOSTS=(
    "github.com"
    "gitlab.com"
    "bitbucket.org"
)

# SSH user for each host (nearly always "git")
declare -a GIT_USERS=(
    "git"
    "git"
    "git"
)

# Absolute paths to your private SSH key files
declare -a SSH_KEY_FILES=(
    "${HOME}/.ssh/id_github"
    "${HOME}/.ssh/id_gitlab"
    "${HOME}/.ssh/id_bitbucket"
)

# Names of environment variables that hold each key's passphrase.
# If the variable is unset/empty the script falls back to an
# interactive prompt.  Use "" to mark a key as passphrase-free.
#
#   export GITHUB_SSH_PASSPHRASE="hunter2"
declare -a PASSPHRASE_ENV_VARS=(
    "GITHUB_SSH_PASSPHRASE"
    "GITLAB_SSH_PASSPHRASE"
    "BITBUCKET_SSH_PASSPHRASE"
)

# Repository list.  Each entry is "host_index:owner/repo:local_dir"
#   host_index  – position in GIT_HOSTS (0-based)
#   owner/repo  – repository path on the remote
#   local_dir   – sub-directory name under CLONE_BASE_DIR
declare -a REPOSITORIES=(
    "0:octocat/Hello-World:hello-world"
    "0:myuser/backend-api:github-backend"
    "1:mygroup/frontend-app:gitlab-frontend"
    "1:mygroup/data-models:gitlab-models"
    "2:myworkspace/devops-scripts:bitbucket-devops"
)

# Mirror URL for each repository — positionally aligned with REPOSITORIES.
# After every clone/pull the script adds a "mirror" remote and runs
# "git push --mirror" to replicate all branches, tags, and other refs.
# Use "" to skip mirroring for a particular repository.
#
# Any Git remote URL is accepted: SSH, HTTPS, or a local path.
# Mirrors stored on a second Git hosting service use the same SSH key
# routing as primary remotes — just reference the host alias when needed.
#
# WARNING: git push --mirror overwrites the mirror remote completely.
# It deletes any branch or tag on the mirror that no longer exists locally.
declare -a REPO_MIRRORS=(
    "git@mirror.example.com:backup/hello-world.git"
    "git@mirror.example.com:backup/github-backend.git"
    ""
    "git@mirror.example.com:backup/gitlab-models.git"
    "git@mirror.example.com:backup/bitbucket-devops.git"
)

# Root directory for all clones
CLONE_BASE_DIR="${CLONE_BASE_DIR:-${HOME}/git-repos}"

# Generated SSH config fragment (written under ~/.ssh/config.d/)
CUSTOM_SSH_CONFIG="${HOME}/.ssh/config.d/multi-key-manager.conf"


# ============================================================
# Internal state – do not edit
# ============================================================
SSH_AGENT_STARTED=false
TEMP_FILES=()


# ============================================================
# Cleanup
# ============================================================
cleanup() {
    local code=$?
    for f in "${TEMP_FILES[@]:-}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
    if [[ "$SSH_AGENT_STARTED" == true && -n "${SSH_AGENT_PID:-}" ]]; then
        ssh-agent -k &>/dev/null || true
    fi
    exit "$code"
}
trap cleanup EXIT INT TERM


# ============================================================
# Logging helpers
# ============================================================
log()  { printf '\033[0;34m[INFO]\033[0m  %s\n'  "$*"; }
ok()   { printf '\033[0;32m[ OK ]\033[0m  %s\n'  "$*"; }
warn() { printf '\033[0;33m[WARN]\033[0m  %s\n'  "$*"; }
err()  { printf '\033[0;31m[ERR ]\033[0m  %s\n'  "$*" >&2; }
die()  { err "$*"; exit 1; }

banner() {
    printf '\n\033[1;36m══  %s  ══\033[0m\n\n' "$*"
}


# ============================================================
# Validate that all parallel arrays have the same length
# ============================================================
validate_config() {
    banner "Validating configuration"

    local nh=${#GIT_HOSTS[@]}
    local nu=${#GIT_USERS[@]}
    local nk=${#SSH_KEY_FILES[@]}
    local np=${#PASSPHRASE_ENV_VARS[@]}

    if (( nh != nu || nh != nk || nh != np )); then
        die "Array length mismatch: GIT_HOSTS=$nh GIT_USERS=$nu \
SSH_KEY_FILES=$nk PASSPHRASE_ENV_VARS=$np — all must be equal."
    fi

    local nr=${#REPOSITORIES[@]}
    local nm=${#REPO_MIRRORS[@]}
    if (( nr != nm )); then
        die "Array length mismatch: REPOSITORIES=$nr REPO_MIRRORS=$nm — must be equal."
    fi

    local missing=0
    for i in "${!SSH_KEY_FILES[@]}"; do
        if [[ ! -f "${SSH_KEY_FILES[$i]}" ]]; then
            warn "Key file not found: ${SSH_KEY_FILES[$i]}"
            (( missing++ )) || true
        fi
    done
    (( missing > 0 )) && warn "$missing key file(s) missing — those hosts will fail."

    ok "Config OK — $nh host(s), $nr repository entry(s)"
}


# ============================================================
# SSH agent
# ============================================================
ensure_ssh_agent() {
    banner "SSH agent"

    if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
        # Verify the socket is actually alive
        if ssh-add -l &>/dev/null || [[ $? -eq 1 ]]; then
            log "Using existing SSH agent  (SSH_AUTH_SOCK=$SSH_AUTH_SOCK)"
            return 0
        fi
    fi

    log "Starting a new SSH agent..."
    eval "$(ssh-agent -s)" >/dev/null
    SSH_AGENT_STARTED=true
    ok "SSH agent started  (PID=$SSH_AGENT_PID)"
}


# ============================================================
# Add one key to the agent
#
# Passphrase resolution order:
#   1. Environment variable named by $passphrase_var
#   2. Interactive terminal prompt
#   3. Empty passphrase (key has no passphrase)
# ============================================================
add_key_to_agent() {
    local key_file="$1"
    local passphrase_var="$2"   # name of the env var, not its value
    local host_label="$3"

    [[ -f "$key_file" ]] || { warn "Skipping missing key: $key_file"; return 1; }

    # Skip if already loaded (compare fingerprints)
    local fp
    fp=$(ssh-keygen -lf "$key_file" 2>/dev/null | awk '{print $2}') || fp=""
    if [[ -n "$fp" ]] && ssh-add -l 2>/dev/null | grep -qF "$fp"; then
        ok "Key already in agent: $key_file"
        return 0
    fi

    # ---- Resolve passphrase ----
    local passphrase=""

    # 1. Try the env var
    if [[ -n "$passphrase_var" ]]; then
        passphrase="${!passphrase_var:-}"
    fi

    # 2. Interactive prompt if still empty
    if [[ -z "$passphrase" && -t 0 ]]; then
        printf '\033[0;33mPassphrase for %s\033[0m (Enter = no passphrase): ' "$key_file"
        IFS= read -rs passphrase
        echo
    fi

    # ---- Load the key ----
    if [[ -n "$passphrase" ]]; then
        _add_key_with_passphrase "$key_file" "$passphrase" "$host_label"
    else
        log "Adding key (no passphrase): $key_file"
        if ! ssh-add "$key_file" </dev/null 2>&1; then
            die "Failed to add key: $key_file"
        fi
        ok "Loaded key for $host_label: $key_file"
    fi
}

# Use the SSH_ASKPASS mechanism so no PTY is required.
# A minimal throw-away helper script echoes the passphrase.
_add_key_with_passphrase() {
    local key_file="$1"
    local passphrase="$2"
    local host_label="$3"

    local askpass
    askpass=$(mktemp /tmp/.ssh-askpass-XXXXXXXX)
    TEMP_FILES+=("$askpass")
    chmod 700 "$askpass"

    # Write the helper – use %s carefully to avoid format-string issues
    printf '#!/bin/sh\nprintf '"'"'%%s'"'"' "%s"\n' "$passphrase" > "$askpass"

    log "Adding key for $host_label via \$$([[ -n "${PASSPHRASE_ENV_VARS[*]}" ]] && \
        echo "env var" || echo "prompt") ..."

    if DISPLAY="${DISPLAY:-:0}" SSH_ASKPASS="$askpass" \
           ssh-add "$key_file" </dev/null 2>&1; then
        ok "Loaded key for $host_label: $key_file"
    else
        die "Failed to add key for $host_label: $key_file"
    fi

    # Wipe and remove the helper immediately
    printf '#!/bin/sh\nprintf ""\n' > "$askpass"
    rm -f "$askpass"
    TEMP_FILES=("${TEMP_FILES[@]/$askpass}")
}


# ============================================================
# Generate SSH config fragment
#
# Creates a Host alias per resource so each repo clone URL can
# target the correct key without touching ~/.ssh/config directly.
#
# Alias format:  <hostname>-idx<N>
# e.g. github.com becomes github.com-idx0
# ============================================================
generate_ssh_config() {
    banner "SSH config"

    mkdir -p "$(dirname "$CUSTOM_SSH_CONFIG")"
    chmod 700 "$(dirname "$CUSTOM_SSH_CONFIG")"

    {
        printf '# Auto-generated by multi_ssh_git.sh — do not edit manually.\n'
        printf '# Regenerated on: %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

        for i in "${!GIT_HOSTS[@]}"; do
            local alias="${GIT_HOSTS[$i]}-idx${i}"
            printf 'Host %s\n'                    "$alias"
            printf '    HostName %s\n'             "${GIT_HOSTS[$i]}"
            printf '    User %s\n'                 "${GIT_USERS[$i]}"
            printf '    IdentityFile %s\n'         "${SSH_KEY_FILES[$i]}"
            printf '    IdentitiesOnly yes\n'
            printf '    StrictHostKeyChecking accept-new\n'
            printf '    AddKeysToAgent yes\n'
            printf '    ServerAliveInterval 60\n'
            printf '\n'
        done
    } > "$CUSTOM_SSH_CONFIG"
    chmod 600 "$CUSTOM_SSH_CONFIG"

    # Ensure ~/.ssh/config includes the config.d directory
    local main_cfg="${HOME}/.ssh/config"
    local include_line='Include ~/.ssh/config.d/*.conf'

    if [[ ! -f "$main_cfg" ]] || ! grep -qF 'config.d' "$main_cfg"; then
        local backup="${main_cfg}.bak-$(date +%Y%m%d%H%M%S)"
        [[ -f "$main_cfg" ]] && cp "$main_cfg" "$backup" \
            && log "Backed up existing config to $backup"

        local tmp
        tmp=$(mktemp)
        TEMP_FILES+=("$tmp")
        printf '%s\n\n' "$include_line" > "$tmp"
        [[ -f "$main_cfg" ]] && cat "$main_cfg" >> "$tmp"
        cp "$tmp" "$main_cfg"
        chmod 600 "$main_cfg"
        ok "Prepended Include directive to $main_cfg"
    else
        log "Include directive already present in $main_cfg"
    fi

    ok "SSH config written to $CUSTOM_SSH_CONFIG"
}


# ============================================================
# Test SSH connectivity for every configured host
# ============================================================
test_connections() {
    banner "Testing SSH connectivity"

    for i in "${!GIT_HOSTS[@]}"; do
        local alias="${GIT_HOSTS[$i]}-idx${i}"
        printf '  %-30s' "${GIT_HOSTS[$i]} (alias: $alias) … "

        local out
        out=$(ssh -o BatchMode=yes -o ConnectTimeout=8 \
                  "${GIT_USERS[$i]}@${alias}" 2>&1 || true)

        if echo "$out" | grep -qiE \
               'success|welcome|authenticated|does not provide|shell access'; then
            printf '\033[0;32mOK\033[0m\n'
        else
            printf '\033[0;31mFAIL\033[0m  (%s)\n' "$(echo "$out" | head -1)"
        fi
    done
}


# ============================================================
# Push a complete mirror of a local clone to a mirror remote.
#
# "git push --mirror" replicates every ref (all branches, tags,
# notes, etc.) and removes refs on the mirror that no longer exist
# locally — making it an exact structural copy of the source.
# ============================================================
mirror_one() {
    local target="$1"     # local repo path
    local mirror_url="$2" # remote URL to mirror to
    local label="$3"      # display label

    # Configure the "mirror" remote: add on first run, update URL if changed.
    local current_url
    current_url=$(git -C "$target" remote get-url mirror 2>/dev/null || true)

    if [[ -z "$current_url" ]]; then
        git -C "$target" remote add mirror "$mirror_url"
        log "$label  Mirror remote added: $mirror_url"
    elif [[ "$current_url" != "$mirror_url" ]]; then
        git -C "$target" remote set-url mirror "$mirror_url"
        log "$label  Mirror remote URL updated: $mirror_url"
    fi

    log "$label  Pushing mirror → $mirror_url"
    if git -C "$target" push --mirror mirror 2>&1 | sed "s/^/  $label /"; then
        ok "$label  Mirror push complete"
    else
        warn "$label  Mirror push failed — check credentials and remote URL"
        return 1
    fi
}


# ============================================================
# Clone or pull a single repository (runs as a background job)
# ============================================================
sync_one() {
    local host_idx="$1"
    local repo_path="$2"
    local local_dir="$3"
    local mirror_url="${4:-}"   # optional mirror URL

    local alias="${GIT_HOSTS[$host_idx]}-idx${host_idx}"
    local remote_url="${GIT_USERS[$host_idx]}@${alias}:${repo_path}.git"
    local target="${CLONE_BASE_DIR}/${local_dir}"
    local label="[${local_dir}]"

    if [[ -d "${target}/.git" ]]; then
        log "$label  Pulling  $remote_url"
        if git -C "$target" pull --ff-only 2>&1 | sed "s/^/  $label /"; then
            ok "$label  Pull complete"
        else
            warn "$label  Pull failed — skipping"
            return 1
        fi
    else
        log "$label  Cloning  $remote_url"
        mkdir -p "$target"
        if git clone "$remote_url" "$target" 2>&1 | sed "s/^/  $label /"; then
            ok "$label  Clone complete"
        else
            warn "$label  Clone failed — skipping"
            return 1
        fi
    fi

    # Mirror after every successful clone/pull
    if [[ -n "$mirror_url" ]]; then
        mirror_one "$target" "$mirror_url" "$label"
    fi
}


# ============================================================
# Sync all repositories in parallel
# ============================================================
sync_all() {
    banner "Syncing repositories"
    mkdir -p "$CLONE_BASE_DIR"
    log "Clone base: $CLONE_BASE_DIR"
    log "Launching ${#REPOSITORIES[@]} parallel job(s)…"
    echo

    local pids=()
    local labels=()

    for i in "${!REPOSITORIES[@]}"; do
        IFS=':' read -r host_idx repo_path local_dir <<< "${REPOSITORIES[$i]}"
        local mirror_url="${REPO_MIRRORS[$i]:-}"
        sync_one "$host_idx" "$repo_path" "$local_dir" "$mirror_url" &
        pids+=($!)
        labels+=("$local_dir")
    done

    local failed=0
    for i in "${!pids[@]}"; do
        if wait "${pids[$i]}"; then
            : # ok message already printed inside sync_one
        else
            err "Job failed: ${labels[$i]}"
            (( failed++ )) || true
        fi
    done

    echo
    if (( failed > 0 )); then
        warn "Completed with $failed failure(s) out of ${#REPOSITORIES[@]} repo(s)."
    else
        ok "All ${#REPOSITORIES[@]} repositor(y/ies) synced successfully."
    fi
}


# ============================================================
# List configuration
# ============================================================
list_config() {
    banner "Configured resources"
    printf '  %-5s %-25s %-12s %s\n' 'IDX' 'HOST' 'USER' 'KEY FILE'
    printf '  %s\n' "$(printf '─%.0s' {1..65})"
    for i in "${!GIT_HOSTS[@]}"; do
        printf '  %-5s %-25s %-12s %s\n' \
            "$i" "${GIT_HOSTS[$i]}" "${GIT_USERS[$i]}" "${SSH_KEY_FILES[$i]}"
    done

    banner "Configured repositories"
    printf '  %-6s %-30s %-22s %s\n' 'HOST' 'REMOTE PATH' 'LOCAL DIR' 'MIRROR'
    printf '  %s\n' "$(printf '─%.0s' {1..90})"
    for i in "${!REPOSITORIES[@]}"; do
        IFS=':' read -r host_idx repo_path local_dir <<< "${REPOSITORIES[$i]}"
        local mirror_url="${REPO_MIRRORS[$i]:-}"
        printf '  %-6s %-30s %-22s %s\n' \
            "${GIT_HOSTS[$host_idx]}" "$repo_path" \
            "${CLONE_BASE_DIR##*/}/$local_dir" \
            "${mirror_url:-(none)}"
    done

    banner "Passphrase sources"
    printf '  %-6s %-30s %s\n' 'HOST' 'ENV VAR' 'STATUS'
    printf '  %s\n' "$(printf '─%.0s' {1..60})"
    for i in "${!GIT_HOSTS[@]}"; do
        local var="${PASSPHRASE_ENV_VARS[$i]}"
        local status
        if [[ -z "$var" ]]; then
            status="no passphrase"
        elif [[ -n "${!var:-}" ]]; then
            status="set (${#var} chars)"
        else
            status="not set → will prompt"
        fi
        printf '  %-6s %-30s %s\n' "${GIT_HOSTS[$i]}" "${var:-<none>}" "$status"
    done
}


# ============================================================
# Setup: agent + config
# ============================================================
setup() {
    validate_config
    ensure_ssh_agent
    generate_ssh_config

    banner "Loading SSH keys"
    for i in "${!GIT_HOSTS[@]}"; do
        add_key_to_agent \
            "${SSH_KEY_FILES[$i]}" \
            "${PASSPHRASE_ENV_VARS[$i]}" \
            "${GIT_HOSTS[$i]}"
    done

    echo
    log "Keys currently loaded in agent:"
    ssh-add -l 2>/dev/null || warn "Agent is empty — check key paths and passphrases."
}


# ============================================================
# Usage
# ============================================================
usage() {
    cat <<EOF

Usage: $(basename "$0") <command>

Commands:
  setup   Load SSH keys into the agent and write the SSH config.
  sync    Run setup, then clone/pull all repositories in parallel.
  test    Run setup, then test SSH connectivity to each host.
  list    Print the current configuration (no SSH operations).
  help    Show this message.

Passphrase environment variables (optional — script prompts if unset):
$(for v in "${PASSPHRASE_ENV_VARS[@]}"; do printf '  export %s="your-passphrase"\n' "$v"; done)

Other variables:
  CLONE_BASE_DIR   Where to clone repositories  (default: ~/git-repos)

Examples:
  # Non-interactive sync:
  export GITHUB_SSH_PASSPHRASE="s3cr3t"
  export GITLAB_SSH_PASSPHRASE="an0th3r"
  $(basename "$0") sync

  # Just inspect config:
  $(basename "$0") list

  # Verify SSH connections:
  $(basename "$0") test

EOF
}


# ============================================================
# Entry point
# ============================================================
main() {
    case "${1:-sync}" in
        setup)       setup ;;
        sync)        setup; sync_all ;;
        test)        setup; test_connections ;;
        list)        list_config ;;
        help|-h|--help) usage ;;
        *)  err "Unknown command: ${1:-}"; usage; exit 1 ;;
    esac
}

main "$@"
