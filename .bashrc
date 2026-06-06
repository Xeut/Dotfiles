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
  # ── config — only edit these two sections ────────────────────────

  # STATIC  = single binary, no deps, always safe to copy (Go/Rust tools)
  # DYNAMIC = has deps, copy and verify — removed if broken on remote
  # SKIP    = never copy — use remote's own version (ABI/glibc sensitive)
  local -A bin_type=(
    [bash]="SKIP"
    [curl]="DYNAMIC"    [wget]="DYNAMIC"    [less]="DYNAMIC"
    [ps]="DYNAMIC"      [netstat]="DYNAMIC" [tcpdump]="DYNAMIC"
    [nmap]="DYNAMIC"    [htop]="DYNAMIC"    [vim]="DYNAMIC"
    [fzf]="STATIC"      [bat]="STATIC"      [fd]="STATIC"
    [rg]="STATIC"
  )

  local bins=(bash curl wget less ps netstat tcpdump nmap htop vim fzf bat fd rg)

  # ─────────────────────────────────────────────────────────────────

  local host=$1
  [ -z "$host" ] && { echo "Usage: sssh user@host"; return 1; }

  # ── detect remote shell ───────────────────────────────────────────
  local remote_shell
  remote_shell=$(ssh "$host" 'command -v bash || command -v sh' 2>/dev/null)
  [ -z "$remote_shell" ] && { echo "✗ Could not detect remote shell"; return 1; }
  echo "🐚 Remote shell: $remote_shell"

  # ── check what remote already has (1 SSH call) ───────────────────
  local check_script="for bin in ${bins[*]}; do command -v \"\$bin\" &>/dev/null && echo \"HAS \$bin\" || echo \"MISSING \$bin\"; done"
  local remote_status
  remote_status=$(ssh "$host" "$check_script" 2>/dev/null)

  # ── decide what to copy ───────────────────────────────────────────
  local to_copy=() to_copy_paths=() to_copy_types=()

  echo ""
  echo "📋 Planning..."
  while IFS= read -r line; do
    local bin="${line#* }"
    local type="${bin_type[$bin]:-STATIC}"
    local remote_has=false
    [[ "$line" == HAS* ]] && remote_has=true

    if [[ "$type" == "SKIP" ]]; then
      echo "  ⊘  $bin — skipped (use remote's own)"
      continue
    fi

    if $remote_has; then
      echo "  ✓  $bin — already on remote"
      continue
    fi

    local local_path
    local_path=$(which "$bin" 2>/dev/null)
    if [ -z "$local_path" ]; then
      echo "  -  $bin — not found locally"
      continue
    fi

    echo "  →  $bin [$type] will be copied"
    to_copy+=("$bin")
    to_copy_paths+=("$local_path")
    to_copy_types+=("$type")
  done <<< "$remote_status"

  # ── build env file: aliases + functions + cleanup setup ──────────
  # alias      → live shell state, captures everything active right now
  # declare -f → exact function bodies, no parsing needed
  # Both are directly sourceable — no escaping, no regex, no .bashrc parsing
  local tmp_env
  tmp_env=$(mktemp /tmp/sssh_env.XXXXXX)

  # aliases — exactly what's active in current shell
  alias >> "$tmp_env"
  echo "" >> "$tmp_env"

  # user-defined functions only (subtract clean-bash baseline)
  local clean_funcs current_funcs user_funcs
  clean_funcs=$(bash --norc --noprofile -c 'declare -F' 2>/dev/null | awk '{print $3}')
  current_funcs=$(declare -F | awk '{print $3}')
  user_funcs=$(comm -23 <(echo "$current_funcs" | sort) <(echo "$clean_funcs" | sort))
  [ -n "$user_funcs" ] && declare -f $user_funcs >> "$tmp_env"
  echo "" >> "$tmp_env"

  # build cleanup list from bins that will be copied + env file itself
  local clean_list=("/tmp/.sssh_env" "/tmp/.sssh_atjob")
  for bin in "${to_copy[@]}"; do clean_list+=("/tmp/$bin"); done
  local cleanup="rm -f ${clean_list[*]}"

  # append at-job scheduling directly into env file —
  # runs once when sourced, avoids a separate SSH call and heredoc stdin issues
  cat >> "$tmp_env" << SETUP

# ── sssh: schedule fallback cleanup after 24h ──
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

  # ── pre-clean remote /tmp to avoid overwrite errors ───────────────
  ssh "$host" "rm -f ${clean_list[*]}" 2>/dev/null

  # ── copy everything in parallel ───────────────────────────────────
  local pids=() copied=() labels=()
  echo ""
  echo "📦 Copying to $host..."

  for i in "${!to_copy[@]}"; do
    scp -q "${to_copy_paths[$i]}" "$host:/tmp/${to_copy[$i]}" 2>/dev/null &
    pids+=($!); copied+=("/tmp/${to_copy[$i]}"); labels+=("${to_copy[$i]}")
  done

  # env file — track pid separately so we can rm AFTER scp finishes
  # rm -f before wait = race condition: file deleted before scp reads it
  local env_pid
  scp -q "$tmp_env" "$host:/tmp/.sssh_env" 2>/dev/null &
  env_pid=$!
  pids+=($env_pid); copied+=("/tmp/.sssh_env"); labels+=(".sssh_env")

  # ── wait + report ─────────────────────────────────────────────────
  local actual_copied=()
  for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
      echo "  ✓  ${labels[$i]}"
      actual_copied+=("${copied[$i]}")
    else
      echo "  ✗  ${labels[$i]} (copy failed)"
    fi
  done
  rm -f "$tmp_env"  # safe now — all scps have finished reading it

  # ── verify DYNAMIC binaries on remote, remove if broken ──────────
  local verify_script=""
  for i in "${!to_copy[@]}"; do
    [[ "${to_copy_types[$i]}" != "DYNAMIC" ]] && continue
    local bin="${to_copy[$i]}"
    verify_script+="
      if /tmp/$bin --version >/dev/null 2>&1 || /tmp/$bin -h >/dev/null 2>&1; then
        echo \"OK $bin\"
      else
        echo \"BROKEN $bin\"
        rm -f /tmp/$bin
      fi"
  done

  if [ -n "$verify_script" ]; then
    echo ""
    echo "🔍 Verifying dynamic binaries on remote..."
    while IFS= read -r result; do
      local bin="${result#* }"
      if [[ "$result" == OK* ]]; then
        echo "  ✓  $bin works on remote"
      else
        echo "  ✗  $bin broken on remote (removed — deps missing)"
        actual_copied=("${actual_copied[@]/\/tmp\/$bin}")
      fi
    done < <(ssh "$host" "bash -c '$verify_script'" 2>/dev/null)
  fi

  echo ""
  echo "✓ Connecting..."

  # ── connect with trap for clean exit cleanup ──────────────────────
  ssh -t "$host" "
    trap '$cleanup; [ -f /tmp/.sssh_atjob ] && atrm \$(cat /tmp/.sssh_atjob) 2>/dev/null' EXIT
    export PATH=/tmp:\$PATH
    [ -f /tmp/.sssh_env ] && source /tmp/.sssh_env
    exec $remote_shell
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
