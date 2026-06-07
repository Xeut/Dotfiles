# 1. PRE-FLIGHT CHECKS & SOURCING
# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# Source default Omarchy configuration
source ~/.local/share/omarchy/default/bash/rc

# 2. ENVIRONMENT VARIABLES (Exports)
export EDITOR='nvim'
export VISUAL='nvim'
export BAT_PAGER="less -R"
export LESS="--mouse"
export HISTSIZE=100000
export HISTFILESIZE=200000

# Path updates
export PATH="$HOME/Scripts:$HOME/.local/bin:$PATH"

# 3. SHELL OPTIONS & COMPLETION
shopt -s histappend      # Append to history instead of overwriting
shopt -s cdspell         # Autocorrect minor cd mistakes
shopt -s globstar        # Recursive globbing (**)
set -o noclobber         # Don't overwrite files accidentally

# Case-insensitive and colored completions
bind 'set completion-ignore-case on'
bind 'set completion-map-case on'
bind 'set colored-stats on'
bind 'set colored-completion-prefix on'

# Keybindings
bind '"\e[1;3C": forward-word'    # Alt+Right
bind '"\e[1;3D": backward-word'   # Alt+Left
bind '"\C-l": clear-screen'       # Ctrl+L

# 4. HISTORY CONFIGURATION
# Avoid useless entries
export HISTCONTROL=ignoreboth:erasedups
export HISTIGNORE="ls:cd:pwd:exit"
# Save/Sync history after every command
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }history -a; history -n"

# 5. ALIASES
# Development & Editors
alias p='python'
alias vim='nvim'
alias f='nvim $(ff)'
alias bashrc='nvim ~/.bashrc && source ~/.bashrc'
alias pyserve='python3 -m http.server'

# System Tools
alias bat='bat --style=numbers --color=always --paging=always'
alias fp='fzf --preview "bat --style=numbers --color=always --line-range :500 {}"'
alias please='sudo $(history -p !!)'
alias showmem='ps -eo pid,ppid,cmd,%mem --sort=-%mem | head -n 10'
alias showcpu='ps -eo pid,ppid,cmd,%cpu --sort=-%cpu | head -n 10'
alias psg='ps aux | grep -v grep | grep -i -E'
alias port='lsof -i :'

# Misc
alias weather='curl -s wttr.in?0'
alias hallo="echo HALLO WELT"

# 6. FUNCTIONS
# Fuzzy finder for history
__fzf_history__() {
  local selected
  selected=$(history | fzf --tac +s | sed 's/ *[0-9]* *//')
  READLINE_LINE="$selected"
  READLINE_POINT=${#READLINE_LINE}
}
bind -x '"\C-r": __fzf_history__'

# Navigation & Files
mkcd() { mkdir -p "$1" && cd "$1"; }
cl() { cd "$1" && ls; }
#unalias countthis 2>/dev/null  # Add this line to clear any existing alias
countthis() { find . -path "./.venv" -prune -o -type f -exec wc -lw {} +; }

# Network
myip() {
  echo "Local IP: $(hostname -I | awk '{print $1}')"
  echo "Public IP: $(curl -s https://ifconfig.me)"
}

sssh() {
  # ── config ────────────────────────────────────────────────────────
  local -A bin_type=(
    [bash]="SKIP"
    [curl]="DYNAMIC"    [wget]="DYNAMIC"    [less]="DYNAMIC"
    [ps]="DYNAMIC"      [netstat]="DYNAMIC" [tcpdump]="DYNAMIC"
    [nmap]="DYNAMIC"    [htop]="DYNAMIC"    [vim]="DYNAMIC"
    [fzf]="STATIC"      [bat]="STATIC"      [fd]="STATIC"
    [rg]="STATIC"
  )
  local bins=(bash curl wget less ps netstat tcpdump nmap htop vim fzf bat fd rg)

  local nvim_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
  local nvim_plugins_dir="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy"
  local nvim_remote_home="/tmp/nvim_home"
  # ─────────────────────────────────────────────────────────────────

  local host="" copy_nvim=false copy_plugins=false

  for arg in "$@"; do
    case "$arg" in
      --help|-h)
        echo "Usage: sssh user@host [--nvim] [--nvim-full]"
        echo "  --nvim       nvim binary (downloaded on remote) + config"
        echo "  --nvim-full  + all plugins synced (~100-300MB)"
        return 0 ;;
      --nvim)      copy_nvim=true ;;
      --nvim-full) copy_nvim=true; copy_plugins=true ;;
      -*)          echo "Unknown flag: $arg"; return 1 ;;
      *)           host="$arg" ;;
    esac
  done

  [ -z "$host" ] && { sssh --help; return 1; }

  # ── detect remote shell + arch in one call ────────────────────────
  local remote_info
  remote_info=$(ssh "$host" 'echo "SHELL=$(command -v bash || command -v sh)"; echo "ARCH=$(uname -m)"' 2>/dev/null)
  local remote_shell remote_arch
  remote_shell=$(echo "$remote_info" | grep '^SHELL=' | cut -d= -f2)
  remote_arch=$(echo  "$remote_info" | grep '^ARCH='  | cut -d= -f2)
  [ -z "$remote_shell" ] && { echo "✗ Could not detect remote shell"; return 1; }
  echo "🐚 Remote: $remote_shell on $remote_arch"

  local local_arch
  local_arch=$(uname -m)
  local same_arch=false
  [ "$local_arch" = "$remote_arch" ] && same_arch=true
  $same_arch && echo "✓ Arch match ($local_arch) — compiled files (.so) are portable" \
             || echo "⚠ Arch mismatch ($local_arch → $remote_arch) — .so files will be excluded, parsers recompiled"

  # ── check what remote already has ────────────────────────────────
  local check_script="for bin in ${bins[*]}; do command -v \"\$bin\" &>/dev/null && echo \"HAS \$bin\" || echo \"MISSING \$bin\"; done"
  local remote_status
  remote_status=$(ssh "$host" "$check_script" 2>/dev/null)

  # ── plan binary copies ────────────────────────────────────────────
  local to_copy=() to_copy_paths=() to_copy_types=()
  echo ""
  echo "📋 Planning..."
  while IFS= read -r line; do
    local bin="${line#* }" type="${bin_type[$bin]:-STATIC}" remote_has=false
    [[ "$line" == HAS* ]] && remote_has=true
    if   [[ "$type" == "SKIP" ]];  then echo "  ⊘  $bin — skipped (use remote's own)"
    elif $remote_has;               then echo "  ✓  $bin — already on remote"
    else
      local local_path; local_path=$(which "$bin" 2>/dev/null)
      if [ -z "$local_path" ]; then echo "  -  $bin — not found locally"
      else
        echo "  →  $bin [$type] will be copied"
        to_copy+=("$bin"); to_copy_paths+=("$local_path"); to_copy_types+=("$type")
      fi
    fi
  done <<< "$remote_status"

  # ── plan nvim ─────────────────────────────────────────────────────
  if $copy_nvim; then
    echo ""
    echo "📋 Planning nvim..."
    if [ ! -d "$nvim_config_dir" ]; then
      echo "  ✗ ~/.config/nvim not found — disabling --nvim"
      copy_nvim=false
    else
      local cfg_size; cfg_size=$(du -sh "$nvim_config_dir" 2>/dev/null | cut -f1)
      echo "  →  nvim binary — will download on remote (correct arch, bundled runtime)"
      echo "  →  config (~$cfg_size) will be synced"
      if $copy_plugins; then
        if [ ! -d "$nvim_plugins_dir" ]; then
          echo "  -  plugins dir not found — skipping plugins"
          copy_plugins=false
        else
          local pl_size; pl_size=$(du -sh "$nvim_plugins_dir" 2>/dev/null | cut -f1)
          echo "  →  plugins (~$pl_size) will be synced"
          $same_arch \
            && echo "       (.so files included — same arch)" \
            || echo "       (.so files excluded — parsers will recompile on remote, needs gcc)"
        fi
      fi
    fi
  fi

  # ── build env file ────────────────────────────────────────────────
  local tmp_env; tmp_env=$(mktemp /tmp/sssh_env.XXXXXX)

  # source remote's own shell config first — our aliases override after
  cat >> "$tmp_env" << 'HEADER'
[ -f ~/.bashrc ]  && source ~/.bashrc  2>/dev/null
[ -f ~/.profile ] && source ~/.profile 2>/dev/null
HEADER

  alias >> "$tmp_env"; echo "" >> "$tmp_env"

  local clean_funcs current_funcs user_funcs
  clean_funcs=$(bash --norc --noprofile -c 'declare -F' 2>/dev/null | awk '{print $3}')
  current_funcs=$(declare -F | awk '{print $3}')
  user_funcs=$(comm -23 <(echo "$current_funcs" | sort) <(echo "$clean_funcs" | sort))
  [ -n "$user_funcs" ] && declare -f $user_funcs >> "$tmp_env"
  echo "" >> "$tmp_env"

  # inject nvim alias with all XDG vars pointing to /tmp/nvim_home
  if $copy_nvim; then
    cat >> "$tmp_env" << NVIMALIAS
alias nvim='XDG_CONFIG_HOME=$nvim_remote_home/.config XDG_DATA_HOME=$nvim_remote_home/.local/share XDG_STATE_HOME=$nvim_remote_home/.local/state XDG_CACHE_HOME=$nvim_remote_home/.cache $nvim_remote_home/bin/nvim'
alias vi='nvim'
NVIMALIAS
  fi

  # build cleanup list
  local clean_list=("/tmp/.sssh_env" "/tmp/.sssh_atjob")
  for bin in "${to_copy[@]}"; do clean_list+=("/tmp/$bin"); done
  $copy_nvim && clean_list+=("$nvim_remote_home")
  local cleanup="rm -rf ${clean_list[*]}"

  # append at-job fallback cleanup into env file (no heredoc/stdin issues)
  cat >> "$tmp_env" << SETUP

# ── sssh: fallback cleanup after 24h ──
if command -v at &>/dev/null && pgrep atd &>/dev/null 2>&1; then
  _SSSH_ATJOB=\$(echo '$cleanup' | at now + 24 hours 2>&1 | awk '/job/{print \$2}')
  [ -n "\$_SSSH_ATJOB" ] && echo "\$_SSSH_ATJOB" > /tmp/.sssh_atjob
else
  ( sleep 86400 && $cleanup ) </dev/null >/dev/null 2>&1 &
  disown
fi
unset _SSSH_ATJOB
SETUP

  local alias_count func_count
  alias_count=$(grep -c '^alias' "$tmp_env" 2>/dev/null || echo 0)
  func_count=$(echo "$user_funcs" | grep -c '.' 2>/dev/null || echo 0)
  echo "  →  env snapshot: $alias_count aliases, $func_count functions"

  # ── pre-clean remote ──────────────────────────────────────────────
  ssh "$host" "rm -rf ${clean_list[*]}" 2>/dev/null

  # ── download nvim on remote IN BACKGROUND (runs while we rsync) ──
  local nvim_dl_pid=""
  if $copy_nvim; then
    echo ""
    echo "⬇  Downloading nvim on remote (background)..."
    local nvim_setup_script
    nvim_setup_script=$(cat << REMOTENVIM
set -e
NVIM_REMOTE_HOME="$nvim_remote_home"
REMOTE_ARCH=\$(uname -m)
case "\$REMOTE_ARCH" in
  x86_64)        NVIM_ARCH="x86_64" ;;
  aarch64|arm64) NVIM_ARCH="arm64"  ;;
  *)             NVIM_ARCH="x86_64" ;;
esac
NVIM_VER=\$(curl -sL "https://api.github.com/repos/neovim/neovim/releases/latest" \
  | grep '"tag_name"' | head -1 | cut -d'"' -f4)
[ -z "\$NVIM_VER" ] && NVIM_VER="v0.10.4"  # fallback if API unreachable
NVIM_URL="https://github.com/neovim/neovim/releases/download/\${NVIM_VER}/nvim-linux-\${NVIM_ARCH}.tar.gz"
mkdir -p "\$NVIM_REMOTE_HOME"
curl -sL "\$NVIM_URL" | tar -xzf - -C "\$NVIM_REMOTE_HOME" --strip-components=1
echo "NVIM_OK \${NVIM_VER} linux-\${NVIM_ARCH}"
REMOTENVIM
)
    ssh "$host" "bash -s" <<< "$nvim_setup_script" > /tmp/sssh_nvim_dl.log 2>&1 &
    nvim_dl_pid=$!
  fi

  # ── copy binaries in parallel ─────────────────────────────────────
  local pids=() copied=() labels=()
  echo ""
  echo "📦 Copying binaries to $host..."

  for i in "${!to_copy[@]}"; do
    scp -q "${to_copy_paths[$i]}" "$host:/tmp/${to_copy[$i]}" 2>/dev/null &
    pids+=($!); copied+=("/tmp/${to_copy[$i]}"); labels+=("${to_copy[$i]}")
  done

  # env file — track pid, rm only after wait (race condition fix)
  local env_pid
  scp -q "$tmp_env" "$host:/tmp/.sssh_env" 2>/dev/null &
  env_pid=$!
  pids+=($env_pid); copied+=("/tmp/.sssh_env"); labels+=(".sssh_env")

  local actual_copied=()
  for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
      echo "  ✓  ${labels[$i]}"
      actual_copied+=("${copied[$i]}")
    else
      echo "  ✗  ${labels[$i]} (copy failed)"
    fi
  done
  rm -f "$tmp_env"

  # ── sync nvim config + plugins ────────────────────────────────────
  if $copy_nvim; then
    echo ""
    echo "🔄 Syncing nvim config..."
    ssh "$host" "mkdir -p \
      $nvim_remote_home/.config \
      $nvim_remote_home/.local/share/nvim \
      $nvim_remote_home/.local/state/nvim \
      $nvim_remote_home/.cache/nvim" 2>/dev/null

    # inject mason-disable plugin BEFORE syncing so it lands on remote
    local mason_disable="$nvim_config_dir/lua/plugins/sssh_remote.lua"
    cat > "$mason_disable" << 'LUA'
-- auto-generated by sssh — disables mason/LSP on remote (no internet, wrong arch)
return {
  { "williamboman/mason.nvim",                   enabled = false },
  { "williamboman/mason-lspconfig.nvim",         enabled = false },
  { "WhoIsSethDaniel/mason-tool-installer.nvim", enabled = false },
}
LUA

    _sssh_sync() {
      local src="$1" remote_dst="$2" label="$3" extra_flags="${4:-}"
      if command -v rsync &>/dev/null; then
        # shellcheck disable=SC2086
        rsync -az $extra_flags --info=progress2 -e ssh \
          "$src" "$host:$remote_dst" \
          && echo "  ✓  $label" || echo "  ✗  $label"
      else
        echo "  (rsync not found — using tar)"
        tar -czf - -C "$(dirname "$src")" "$(basename "$src")" \
          | ssh "$host" "mkdir -p $remote_dst && tar -xzf - -C $remote_dst" \
          && echo "  ✓  $label" || echo "  ✗  $label"
      fi
    }

    # always sync config (includes sssh_remote.lua we just wrote)
    _sssh_sync "$nvim_config_dir" \
      "$nvim_remote_home/.config/" \
      "nvim config"

    # sync plugins
    if $copy_plugins && [ -d "$nvim_plugins_dir" ]; then
      echo "🔄 Syncing nvim plugins..."
      local so_flags=""
      $same_arch || so_flags="--exclude='*.so' --exclude='parser/' --exclude='build/'"
      _sssh_sync "$nvim_plugins_dir" \
        "$nvim_remote_home/.local/share/nvim/" \
        "nvim plugins" \
        "$so_flags"
    fi

    # remove local sssh_remote.lua — it only belongs on the remote
    rm -f "$mason_disable"
    unset -f _sssh_sync

    # wait for nvim download + report
    echo ""
    echo "⬇  Waiting for nvim download..."
    if wait "$nvim_dl_pid"; then
      local dl_result; dl_result=$(cat /tmp/sssh_nvim_dl.log 2>/dev/null)
      if echo "$dl_result" | grep -q "NVIM_OK"; then
        local ver; ver=$(echo "$dl_result" | grep "NVIM_OK" | awk '{print $2, $3}')
        echo "  ✓  nvim $ver"
      else
        echo "  ✗  nvim download failed:"
        cat /tmp/sssh_nvim_dl.log 2>/dev/null | sed 's/^/     /'
      fi
    else
      echo "  ✗  nvim download failed"
      cat /tmp/sssh_nvim_dl.log 2>/dev/null | sed 's/^/     /'
    fi
    rm -f /tmp/sssh_nvim_dl.log

    # recompile treesitter parsers if arch mismatch
    if $copy_plugins && ! $same_arch; then
      echo "🔨 Recompiling treesitter parsers (arch mismatch, needs gcc on remote)..."
      ssh "$host" "
        XDG_CONFIG_HOME=$nvim_remote_home/.config \
        XDG_DATA_HOME=$nvim_remote_home/.local/share \
        XDG_STATE_HOME=$nvim_remote_home/.local/state \
        XDG_CACHE_HOME=$nvim_remote_home/.cache \
          $nvim_remote_home/bin/nvim --headless \
            -c 'TSUpdateSync' -c 'qa' 2>/dev/null
      " && echo "  ✓  parsers recompiled" \
        || echo "  ⚠  parser recompile had errors (gcc may be missing — some languages may not highlight)"
    fi
  fi

  # ── verify DYNAMIC binaries ───────────────────────────────────────
  local verify_script=""
  for i in "${!to_copy[@]}"; do
    [[ "${to_copy_types[$i]}" != "DYNAMIC" ]] && continue
    local bin="${to_copy[$i]}"
    verify_script+="
      if /tmp/$bin --version >/dev/null 2>&1 || /tmp/$bin -h >/dev/null 2>&1; then
        echo \"OK $bin\"
      else
        echo \"BROKEN $bin\"; rm -f /tmp/$bin
      fi"
  done

  if [ -n "$verify_script" ]; then
    echo ""
    echo "🔍 Verifying dynamic binaries..."
    while IFS= read -r result; do
      local bin="${result#* }"
      [[ "$result" == OK*     ]] && echo "  ✓  $bin works" \
                                 || echo "  ✗  $bin broken (deps missing, removed)"
    done < <(ssh "$host" "bash -c '$verify_script'" 2>/dev/null)
  fi

  echo ""
  echo "✓ Connecting..."

  # aliases need --rcfile to survive into the new shell process
  local connect_cmd
  if [[ "$remote_shell" == *bash ]]; then
    connect_cmd="exec $remote_shell --rcfile /tmp/.sssh_env"
  else
    connect_cmd="ENV=/tmp/.sssh_env exec $remote_shell -i"
  fi

  ssh -t "$host" "
    trap '$cleanup; [ -f /tmp/.sssh_atjob ] && atrm \$(cat /tmp/.sssh_atjob) 2>/dev/null' EXIT
    export PATH=/tmp:\$PATH
    $connect_cmd
  "
}

# Utilities
timer() { sleep "$1" && echo -e "\aTimer Finished: $(date)"; }

# Extraction logic
extract() {
  if [ -f "$1" ] ; then
    case "$1" in
      *.tar.bz2)   tar xjf "$1"     ;;
      *.tar.gz)    tar xzf "$1"     ;;
      *.bz2)       bunzip2 "$1"     ;;
      *.rar)       unrar e "$1"     ;;
      *.gz)        gunzip "$1"      ;;
      *.tar)       tar xf "$1"      ;;
      *.tbz2)      tar xjf "$1"     ;;
      *.tgz)       tar xzf "$1"     ;;
      *.zip)       unzip "$1"       ;;
      *.Z)         uncompress "$1"  ;;
      *.7z)        7z x "$1"        ;;
      *)           echo "'$1' cannot be extracted via extract()" ;;
    esac
  else
    echo "'$1' is not a valid file"
  fi
}

# Quick Notes
qnote() {
  local timestamp=$(date +"%Y-%m-%d : %H:%M:%S")
  local note_file=~/.quicknotes.txt
  if [ -t 0 ]; then
    if [ -n "$1" ]; then
      echo -e "DATE: $timestamp\nNOTE: $*\n\n\e[31m$(printf '%.0s-' {1..40})\e[0m\n" >> "$note_file"
    else
      echo "Usage: qnote 'your message' OR your_command | qnote"
    fi
  else
    local last_cmd=$(history 1 | sed 's/^[ ]*[0-9]*[ ]*//')
    {
      echo "DATE:    $timestamp"
      echo "COMMAND: $last_cmd"
      echo -e "OUTPUT:\n"
      cat
      echo -e "\n\e[31m$(printf '%.0s-' {1..40})\e[0m\n"
    } >> "$note_file"
  fi
}
alias vnote='bat ~/.quicknotes.txt --style="full" --paging="always" -l log'

# Programmable completion
if ! shopt -oq posix; then
  if [ -f /usr/local/etc/bash_completion ]; then
    . /usr/local/etc/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# 7. AUTO-START TMUX
# Only run if we are NOT already in a tmux session
if [[ -z "$TMUX" ]]; then
    # This creates a brand new session every time you open a terminal.
    # Ghostty will now spawn a fresh tmux session (e.g., session 0, then 1, then 2).
    exec tmux new-session
fi

# Added by tt installer
export PATH="$HOME/bin:$PATH"
