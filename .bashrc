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
  local cache_ttl=14400  # seconds — skip copy if env file is fresher than this (4h)
  # ─────────────────────────────────────────────────────────────────

  local host="" copy_nvim=false copy_plugins=false force=false

  for arg in "$@"; do
    case "$arg" in
      --help|-h)
        echo "Usage: sssh user@host [--nvim] [--nvim-full] [--force]"
        echo "  --nvim       nvim binary (downloaded on remote) + config"
        echo "  --nvim-full  + all plugins synced (~100-300MB)"
        echo "  --force      re-copy even if remote cache is fresh"
        return 0 ;;
      --nvim)      copy_nvim=true ;;
      --nvim-full) copy_nvim=true; copy_plugins=true ;;
      --force)     force=true ;;
      -*)          echo "Unknown flag: $arg"; return 1 ;;
      *)           host="$arg" ;;
    esac
  done
  [ -z "$host" ] && { sssh --help; return 1; }

  # ── ControlMaster — one persistent connection for ALL subsequent calls ──
  # eliminates repeated TCP+SSH handshakes (~200ms each → ~5ms each)
  local cm_socket="/tmp/sssh_cm_${host//[@:.]/_}"
  local cm_opts=(-o ControlMaster=no -o ControlPath="$cm_socket" -o ConnectTimeout=10)
  local cm_pid=""

  _sssh_cleanup_cm() {
    [ -n "$cm_pid" ] && kill "$cm_pid" 2>/dev/null
    ssh -o ControlPath="$cm_socket" -O exit "$host" 2>/dev/null
    rm -f "$cm_socket"
  }
  trap '_sssh_cleanup_cm' RETURN

  echo "🔗 Connecting to $host..."
  ssh -o ControlMaster=yes \
      -o ControlPath="$cm_socket" \
      -o ControlPersist=120 \
      -o ConnectTimeout=10 \
      -N "$host" &
  cm_pid=$!

  # wait for socket (max 5s)
  local i=0
  while [ $i -lt 50 ] && [ ! -S "$cm_socket" ]; do sleep 0.1; ((i++)); done
  [ ! -S "$cm_socket" ] && { echo "✗ Could not connect to $host"; return 1; }

  # ── ONE SSH call: detect + check bins + cache check + pre-clean ───
  local bin_list="${bins[*]}"
  local setup_result
  setup_result=$(ssh "${cm_opts[@]}" "$host" "bash -s" << SETUP
# detect
echo "SHELL=\$(command -v bash || command -v sh)"
echo "ARCH=\$(uname -m)"
echo "BASH_VER=\${BASH_VERSINFO[0]}.\${BASH_VERSINFO[1]}"

# cache check — if env file is fresh and force not requested, skip copy
if [ "$force" = false ] && [ -f /tmp/.sssh_env ]; then
  age=\$(( \$(date +%s) - \$(stat -c %Y /tmp/.sssh_env 2>/dev/null || echo 0) ))
  if [ "\$age" -lt "$cache_ttl" ]; then
    echo "CACHED \$age"
  fi
fi

# check which bins are present
for bin in $bin_list; do
  command -v "\$bin" &>/dev/null && echo "HAS \$bin" || echo "MISSING \$bin"
done

# pre-clean stale sssh files (not cached case)
echo "READY"
SETUP
)

  # ── parse setup result ────────────────────────────────────────────
  local remote_shell remote_arch remote_bash_ver cached=false cache_age=0
  remote_shell=$(echo "$setup_result" | grep '^SHELL=' | cut -d= -f2)
  remote_arch=$(echo  "$setup_result" | grep '^ARCH='  | cut -d= -f2)
  remote_bash_ver=$(echo "$setup_result" | grep '^BASH_VER=' | cut -d= -f2)
  [ -z "$remote_shell" ] && { echo "✗ Could not detect remote shell"; return 1; }

  if echo "$setup_result" | grep -q '^CACHED'; then
    cache_age=$(echo "$setup_result" | grep '^CACHED' | awk '{print $2}')
    cached=true
  fi

  local local_arch; local_arch=$(uname -m)
  local same_arch=false
  [ "$local_arch" = "$remote_arch" ] && same_arch=true

  echo "🐚 Remote: $remote_shell (bash $remote_bash_ver) on $remote_arch"
  $same_arch || echo "⚠ Arch mismatch ($local_arch → $remote_arch)"

  # ── cache hit: skip all copies, just connect ──────────────────────
  if $cached; then
    local mins=$(( cache_age / 60 ))
    echo "⚡ Cache hit (${mins}m old) — skipping copy, connecting directly"
    echo "   (use --force to re-copy)"

    local connect_cmd
    [[ "$remote_shell" == *bash ]] \
      && connect_cmd="exec $remote_shell --rcfile /tmp/.sssh_env" \
      || connect_cmd="ENV=/tmp/.sssh_env exec $remote_shell -i"

    ssh -t "${cm_opts[@]}" "$host" "
      export PATH=/tmp:\$PATH
      $connect_cmd
    "
    return
  fi

  # ── plan what to copy ─────────────────────────────────────────────
  local to_copy=() to_copy_paths=() to_copy_types=()
  echo ""
  echo "📋 Planning..."

  while IFS= read -r line; do
    local bin="${line#* }" type="${bin_type[$bin]:-STATIC}" remote_has=false
    [[ "$line" == HAS* ]] && remote_has=true
    if   [[ "$type" == "SKIP" ]]; then echo "  ⊘  $bin — use remote's own"
    elif $remote_has;              then echo "  ✓  $bin — already present"
    else
      local lp; lp=$(which "$bin" 2>/dev/null)
      if [ -z "$lp" ]; then echo "  -  $bin — not found locally"
      else
        echo "  →  $bin [$type]"
        to_copy+=("$bin"); to_copy_paths+=("$lp"); to_copy_types+=("$type")
      fi
    fi
  done <<< "$(echo "$setup_result" | grep -E '^(HAS|MISSING) ')"

  # ── plan nvim ─────────────────────────────────────────────────────
  if $copy_nvim && [ ! -d "$nvim_config_dir" ]; then
    echo "  ✗ ~/.config/nvim not found — disabling --nvim"; copy_nvim=false
  fi
  if $copy_nvim; then
    echo "  →  nvim (download on remote) + config ($(du -sh "$nvim_config_dir" 2>/dev/null | cut -f1))"
    if $copy_plugins && [ -d "$nvim_plugins_dir" ]; then
      echo "  →  plugins ($(du -sh "$nvim_plugins_dir" 2>/dev/null | cut -f1))"
    fi
  fi

  # ── build env file ────────────────────────────────────────────────
  local tmp_env; tmp_env=$(mktemp /tmp/sssh_env.XXXXXX)

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

  if $copy_nvim; then
    cat >> "$tmp_env" << NVIMALIAS
alias nvim='XDG_CONFIG_HOME=$nvim_remote_home/.config XDG_DATA_HOME=$nvim_remote_home/.local/share XDG_STATE_HOME=$nvim_remote_home/.local/state XDG_CACHE_HOME=$nvim_remote_home/.cache $nvim_remote_home/bin/nvim'
alias vi='nvim'
NVIMALIAS
  fi

  # alias + plugin + completion filter (runs on source on remote)
  cat >> "$tmp_env" << 'ENV_FILTER'

_sssh_purge_plugins() {
  local _patterns=(
    '^_zoxide' '^__zoxide' '^zd$' '^_z$' '^__z$' '^_z_'
    '^_fzf_' '^__fzf_' '^_fasd' '^fasd' '^_autojump' '^autojump'
    '^_zellij' '^__zellij' '^_atuin' '^__atuin'
  )
  local _funcs _func _pat _removed=()
  _funcs=$(declare -F | awk '{print $3}')
  while IFS= read -r _func; do
    for _pat in "${_patterns[@]}"; do
      if echo "$_func" | grep -qE "$_pat"; then
        unset -f "$_func" 2>/dev/null; _removed+=("$_func"); break
      fi
    done
  done <<< "$_funcs"
  [ ${#_removed[@]} -gt 0 ] && \
    echo "sssh: removed ${#_removed[@]} plugin functions: ${_removed[*]}"
  PROMPT_COMMAND=$(printf '%s' "$PROMPT_COMMAND" | \
    tr ';' '\n' | grep -vE '_zoxide_hook|__zoxide|_z_hook|atuin|__bp_' | \
    grep -v '^[[:space:]]*$' | paste -sd ';' -)
}

_sssh_filter_aliases() {
  local _name _body _cmds _cmd _skipped=()
  for _name in $(alias | sed "s/alias \([^=]*\)=.*/\1/"); do
    _body=$(alias "$_name" 2>/dev/null | sed "s/alias $_name=//;s/^'//;s/'$//")
    _cmds=$(echo "$_body" | \
      sed 's/&&/\n/g; s/||/\n/g; s/|/\n/g; s/;/\n/g; s/\$(/\n/g' | \
      awk '{print $1}' | grep -oE '[a-zA-Z_][a-zA-Z0-9_-]+' | sort -u)
    local _missing=""
    while IFS= read -r _cmd; do
      [ -z "$_cmd" ] && continue
      case "$_cmd" in
        cd|echo|printf|source|export|local|return|true|false|test|if|then|else|\
        do|done|while|for|in|case|esac|fi|time|sudo|grep|awk|sed|sort|cut|\
        head|tail|xargs|find|tar|mkdir|rm|cp|mv|cat|wc|read|history|ps|\
        unset|shift|set|trap|wait|exec|eval|type|command|hash|pwd|env)
          continue ;;
      esac
      command -v "$_cmd" &>/dev/null && continue
      _missing="$_cmd"; break
    done <<< "$_cmds"
    if [ -n "$_missing" ]; then
      _skipped+=("$_name($_missing)"); unalias "$_name" 2>/dev/null
    fi
  done
  if [ ${#_skipped[@]} -gt 0 ]; then
    echo "sssh: skipped ${#_skipped[@]} aliases (not on this server):"
    local _s; for _s in "${_skipped[@]}"; do echo "  ✗  $_s"; done
  fi
}

_sssh_clean_completions() {
  while IFS= read -r _line; do
    local _func _cmd
    _func=$(echo "$_line" | grep -oE '\-F \S+' | awk '{print $2}')
    _cmd=$(echo "$_line"  | awk '{print $NF}')
    [ -z "$_func" ] && continue
    declare -f "$_func" &>/dev/null && continue
    complete -r "$_cmd" 2>/dev/null
  done < <(complete -p 2>/dev/null)
  complete -r cd 2>/dev/null
  complete -o filenames -o nospace -d cd
  for _cmd in fzf bat rg fd delta eza; do
    command -v "$_cmd" &>/dev/null || continue
    complete -r "$_cmd" 2>/dev/null
  done
}

_sssh_purge_plugins
_sssh_filter_aliases
_sssh_clean_completions
unset -f _sssh_purge_plugins _sssh_filter_aliases _sssh_clean_completions
ENV_FILTER

  # build cleanup list
  local clean_list=("/tmp/.sssh_env" "/tmp/.sssh_atjob")
  for bin in "${to_copy[@]}"; do clean_list+=("/tmp/$bin"); done
  $copy_nvim && clean_list+=("$nvim_remote_home")
  local cleanup="rm -rf ${clean_list[*]}"

  cat >> "$tmp_env" << SETUP

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
  echo "  →  env: $alias_count aliases, $func_count functions"

  # ── pre-clean via ControlMaster (fast — reuses connection) ────────
  ssh "${cm_opts[@]}" "$host" "rm -rf ${clean_list[*]}" 2>/dev/null

  # ── start nvim download on remote in background ───────────────────
  local nvim_dl_pid=""
  if $copy_nvim; then
    echo ""
    echo "⬇  Downloading nvim on remote (background)..."
    ssh "${cm_opts[@]}" "$host" "bash -s" << 'REMOTENVIM' > /tmp/sssh_nvim_dl.log 2>&1 &
set -e
NRH="/tmp/nvim_home"
case "$(uname -m)" in
  x86_64)        NA="x86_64" ;; aarch64|arm64) NA="arm64" ;; *) NA="x86_64" ;;
esac
NV=$(curl -sL "https://api.github.com/repos/neovim/neovim/releases/latest" \
  | grep '"tag_name"' | head -1 | cut -d'"' -f4)
[ -z "$NV" ] && NV="v0.10.4"
mkdir -p "$NRH"
curl -sL "https://github.com/neovim/neovim/releases/download/${NV}/nvim-linux-${NA}.tar.gz" \
  | tar -xzf - -C "$NRH" --strip-components=1
echo "NVIM_OK ${NV} linux-${NA}"
REMOTENVIM
    nvim_dl_pid=$!
  fi

  # ── bundle ALL files into ONE tar, pipe over ControlMaster ────────
  # one TCP transfer instead of N parallel scp connections
  echo ""
  echo "📦 Bundling and transferring..."

  local bundle_files=("$tmp_env")
  local bundle_names=(".sssh_env")
  for i in "${!to_copy[@]}"; do
    bundle_files+=("${to_copy_paths[$i]}")
    bundle_names+=("${to_copy[$i]}")
  done

  # create bundle: rename files to their target names during tar
  # tar -C srcdir file works but we need different source and dest names
  # solution: copy to a staging dir with target names, tar that
  local stage_dir; stage_dir=$(mktemp -d /tmp/sssh_stage.XXXXXX)
  cp "$tmp_env" "$stage_dir/.sssh_env"
  for i in "${!to_copy[@]}"; do
    cp "${to_copy_paths[$i]}" "$stage_dir/${to_copy[$i]}"
  done
  rm -f "$tmp_env"

  # pipe tar bundle through ControlMaster — single SSH connection
  local transferred=() failed=()
  if tar -czf - -C "$stage_dir" . \
      | ssh "${cm_opts[@]}" "$host" \
          "tar -xzf - -C /tmp && chmod +x $(printf '/tmp/%s ' "${to_copy[@]}") 2>/dev/null; echo BUNDLE_OK"; then
    echo "  ✓  bundle transferred ($(du -sh "$stage_dir" 2>/dev/null | cut -f1) compressed)"
    transferred=("${to_copy[@]}" ".sssh_env")
  else
    echo "  ✗  bundle transfer failed"
    failed=("${to_copy[@]}")
  fi
  rm -rf "$stage_dir"

  # ── verify binaries — static with musl fallback, dynamic check ────
  local verify_script='
_sssh_get_ver() {
  curl -sL "https://api.github.com/repos/$1/releases/latest" \
    | grep "\"tag_name\"" | head -1 | cut -d"\"" -f4 | tr -d "v"
}
_sssh_musl() {
  local b="$1" a=$(uname -m)
  case "$b" in
    bat) v=$(_sssh_get_ver sharkdp/bat)
      case $a in
        x86_64)  u="https://github.com/sharkdp/bat/releases/download/v${v}/bat-v${v}-x86_64-unknown-linux-musl.tar.gz" ;;
        aarch64) u="https://github.com/sharkdp/bat/releases/download/v${v}/bat-v${v}-aarch64-unknown-linux-musl.tar.gz" ;;
      esac; curl -sL "$u" | tar -xzf - --wildcards --strip-components=1 -O "*/bat" > /tmp/bat ;;
    rg) v=$(_sssh_get_ver BurntSushi/ripgrep)
      case $a in
        x86_64)  u="https://github.com/BurntSushi/ripgrep/releases/download/${v}/ripgrep-${v}-x86_64-unknown-linux-musl.tar.gz" ;;
        aarch64) u="https://github.com/BurntSushi/ripgrep/releases/download/${v}/ripgrep-${v}-aarch64-unknown-linux-musl.tar.gz" ;;
      esac; curl -sL "$u" | tar -xzf - --wildcards --strip-components=1 -O "*/rg" > /tmp/rg ;;
    fd) v=$(_sssh_get_ver sharkdp/fd)
      case $a in
        x86_64)  u="https://github.com/sharkdp/fd/releases/download/v${v}/fd-v${v}-x86_64-unknown-linux-musl.tar.gz" ;;
        aarch64) u="https://github.com/sharkdp/fd/releases/download/v${v}/fd-v${v}-aarch64-unknown-linux-musl.tar.gz" ;;
      esac; curl -sL "$u" | tar -xzf - --wildcards --strip-components=1 -O "*/fd" > /tmp/fd ;;
    fzf) v=$(_sssh_get_ver junegunn/fzf)
      case $a in
        x86_64)  u="https://github.com/junegunn/fzf/releases/download/v${v}/fzf-${v}-linux_amd64.tar.gz" ;;
        aarch64) u="https://github.com/junegunn/fzf/releases/download/v${v}/fzf-${v}-linux_arm64.tar.gz" ;;
      esac; curl -sL "$u" | tar -xzf - -O fzf > /tmp/fzf ;;
  esac
  chmod +x "/tmp/$b" 2>/dev/null
}
'
  echo ""
  echo "🔍 Verifying..."
  for i in "${!to_copy[@]}"; do
    local bin="${to_copy[$i]}" type="${to_copy_types[$i]}"
    if [[ "$type" == "STATIC" ]]; then
      verify_script+="
        if /tmp/$bin --version >/dev/null 2>&1 || /tmp/$bin --help >/dev/null 2>&1; then
          echo \"OK $bin\"
        else
          _sssh_musl $bin
          /tmp/$bin --version >/dev/null 2>&1 && echo \"OK_MUSL $bin\" || { echo \"FAILED $bin\"; rm -f /tmp/$bin; }
        fi"
    else
      verify_script+="
        /tmp/$bin --version >/dev/null 2>&1 || /tmp/$bin -h >/dev/null 2>&1 \
          && echo \"OK $bin\" || { echo \"BROKEN $bin\"; rm -f /tmp/$bin; }"
    fi
  done
  verify_script+="
unset -f _sssh_get_ver _sssh_musl"

  while IFS= read -r result; do
    local bin="${result#* }"
    case "$result" in
      OK_MUSL*) echo "  ✓  $bin (musl)" ;;
      OK*)      echo "  ✓  $bin" ;;
      BROKEN*)  echo "  ✗  $bin (deps missing, removed)" ;;
      FAILED*)  echo "  ✗  $bin (failed, removed)" ;;
    esac
  done < <(ssh "${cm_opts[@]}" "$host" "bash -c '$verify_script'" 2>/dev/null)

  # ── sync nvim config + plugins ────────────────────────────────────
  if $copy_nvim; then
    echo ""
    echo "🔄 Syncing nvim config..."
    ssh "${cm_opts[@]}" "$host" "mkdir -p \
      $nvim_remote_home/.config $nvim_remote_home/.local/share/nvim \
      $nvim_remote_home/.local/state/nvim $nvim_remote_home/.cache/nvim" 2>/dev/null

    local mason_disable="$nvim_config_dir/lua/plugins/sssh_remote.lua"
    cat > "$mason_disable" << 'LUA'
return {
  { "williamboman/mason.nvim",                   enabled = false },
  { "williamboman/mason-lspconfig.nvim",         enabled = false },
  { "WhoIsSethDaniel/mason-tool-installer.nvim", enabled = false },
}
LUA

    _sssh_sync() {
      local src="$1" dst="$2" label="$3" flags="${4:-}"
      if command -v rsync &>/dev/null; then
        # shellcheck disable=SC2086
        rsync -az $flags --info=progress2 \
          -e "ssh ${cm_opts[*]}" "$src" "$host:$dst" \
          && echo "  ✓  $label" || echo "  ✗  $label"
      else
        tar -czf - -C "$(dirname "$src")" "$(basename "$src")" \
          | ssh "${cm_opts[@]}" "$host" "mkdir -p $dst && tar -xzf - -C $dst" \
          && echo "  ✓  $label" || echo "  ✗  $label"
      fi
    }

    _sssh_sync "$nvim_config_dir" "$nvim_remote_home/.config/" "nvim config"

    if $copy_plugins && [ -d "$nvim_plugins_dir" ]; then
      echo "🔄 Syncing nvim plugins..."
      local so_flags=""
      $same_arch || so_flags="--exclude='*.so' --exclude='parser/' --exclude='build/'"
      _sssh_sync "$nvim_plugins_dir" "$nvim_remote_home/.local/share/nvim/" "nvim plugins" "$so_flags"
    fi

    rm -f "$mason_disable"
    unset -f _sssh_sync

    echo ""
    echo "⬇  Waiting for nvim download..."
    if wait "$nvim_dl_pid" 2>/dev/null; then
      grep -q "NVIM_OK" /tmp/sssh_nvim_dl.log 2>/dev/null \
        && echo "  ✓  nvim $(grep NVIM_OK /tmp/sssh_nvim_dl.log | awk '{print $2,$3}')" \
        || { echo "  ✗  nvim download failed:"; sed 's/^/     /' /tmp/sssh_nvim_dl.log; }
    fi
    rm -f /tmp/sssh_nvim_dl.log

    if $copy_plugins && ! $same_arch; then
      echo "🔨 Recompiling treesitter parsers..."
      ssh "${cm_opts[@]}" "$host" "
        XDG_CONFIG_HOME=$nvim_remote_home/.config \
        XDG_DATA_HOME=$nvim_remote_home/.local/share \
        XDG_STATE_HOME=$nvim_remote_home/.local/state \
        XDG_CACHE_HOME=$nvim_remote_home/.cache \
          $nvim_remote_home/bin/nvim --headless -c 'TSUpdateSync' -c 'qa' 2>/dev/null
      " && echo "  ✓  parsers recompiled" || echo "  ⚠  recompile had errors"
    fi
  fi

  echo ""
  echo "✓ Connecting..."

  local connect_cmd
  [[ "$remote_shell" == *bash ]] \
    && connect_cmd="exec $remote_shell --rcfile /tmp/.sssh_env" \
    || connect_cmd="ENV=/tmp/.sssh_env exec $remote_shell -i"

  ssh -t "${cm_opts[@]}" "$host" "
    trap '$cleanup; [ -f /tmp/.sssh_atjob ] && atrm \$(cat /tmp/.sssh_atjob) 2>/dev/null' EXIT
    export PATH=/tmp:\$PATH
    $connect_cmd
  "

  unset -f _sssh_cleanup_cm
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
