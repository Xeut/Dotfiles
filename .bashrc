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
  # ── config — only edit this block ────────────────────────────────
  local -A _bin_type=(
    [bash]="SKIP"                                        # never copy — glibc/ABI sensitive
    [curl]="DYNAMIC"  [wget]="DYNAMIC"  [less]="DYNAMIC"  # copy + verify on remote
    [ps]="DYNAMIC"    [netstat]="DYNAMIC" [tcpdump]="DYNAMIC"
    [nmap]="DYNAMIC"  [htop]="DYNAMIC"  [vim]="DYNAMIC"
    [fzf]="STATIC"    [bat]="STATIC"    [fd]="STATIC"    # static; musl fallback if broken
    [rg]="STATIC"
  )
  local _bins=(bash curl wget less ps netstat tcpdump nmap htop vim fzf bat fd rg)
  local _nvim_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
  local _nvim_lazy="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy"
  local _nvim_rdir="/tmp/nvim_home"
  local _cache_ttl=14400   # 4h — skip copy if remote env file is this fresh
  # ─────────────────────────────────────────────────────────────────

  local _host="" _copy_nvim=false _copy_plugins=false _force=false

  for _arg in "$@"; do
    case "$_arg" in
      --help|-h)
        printf 'Usage: sssh user@host [--nvim] [--nvim-full] [--force]\n'
        printf '  --nvim       nvim binary (downloaded on remote) + config\n'
        printf '  --nvim-full  + all plugins synced (~100-300MB)\n'
        printf '  --force      re-copy even if remote cache is fresh\n'
        return 0 ;;
      --nvim)      _copy_nvim=true ;;
      --nvim-full) _copy_nvim=true; _copy_plugins=true ;;
      --force)     _force=true ;;
      -*)          printf 'Unknown flag: %s\n' "$_arg"; return 1 ;;
      *)           _host="$_arg" ;;
    esac
  done
  [ -z "$_host" ] && { sssh --help; return 1; }

  # ── ControlMaster — reuse one TCP+SSH connection for all calls ────
  # each subsequent ssh/scp costs ~5ms instead of ~200ms
  # socket lives in a private dir (mode 700) to prevent pre-creation attacks
  local _cm_dir; _cm_dir=$(mktemp -d /tmp/sssh.XXXXXX)
  chmod 700 "$_cm_dir"
  local _cm_sock="$_cm_dir/ctrl"
  local _cm_opts=(-o ControlMaster=no -o ControlPath="$_cm_sock" -o ConnectTimeout=10)

  # open master connection; clean up on function return regardless of path taken
  local _cm_pid=""
  _sssh_close_cm() {
    [ -n "$_cm_pid" ] && kill "$_cm_pid" 2>/dev/null
    ssh -o ControlPath="$_cm_sock" -O exit "$_host" 2>/dev/null
    rm -rf "$_cm_dir"
    unset -f _sssh_close_cm
  }
  trap '_sssh_close_cm' RETURN

  printf '🔗 Connecting to %s...\n' "$_host"
  ssh -o ControlMaster=yes -o ControlPath="$_cm_sock" \
      -o ControlPersist=120 -o ConnectTimeout=10 \
      -N "$_host" &
  _cm_pid=$!

  local _i=0
  while (( _i++ < 50 )) && [[ ! -S "$_cm_sock" ]]; do sleep 0.1; done
  [[ ! -S "$_cm_sock" ]] && { printf '✗ Could not connect to %s\n' "$_host"; return 1; }

  # ── single remote call: detect + check bins + cache check ─────────
  local _bin_list="${_bins[*]}"
  local _probe
  _probe=$(ssh "${_cm_opts[@]}" "$_host" bash -s << PROBE
printf 'SHELL=%s\n' "\$(command -v bash || command -v sh)"
printf 'ARCH=%s\n'  "\$(uname -m)"
if [ "$_force" = false ] && [ -f /tmp/.sssh_env ]; then
  _age=\$(( \$(date +%s) - \$(stat -c %Y /tmp/.sssh_env 2>/dev/null || echo 0) ))
  [ "\$_age" -lt "$_cache_ttl" ] && printf 'CACHED %s\n' "\$_age"
fi
for _b in $_bin_list; do
  command -v "\$_b" >/dev/null 2>&1 && printf 'HAS %s\n' "\$_b" || printf 'MISSING %s\n' "\$_b"
done
PROBE
)

  # ── parse probe output ────────────────────────────────────────────
  local _rshell _rarch _cached=false _cache_age=0
  _rshell=$(printf '%s\n' "$_probe" | awk -F= '/^SHELL=/{print $2}')
  _rarch=$( printf '%s\n' "$_probe" | awk -F= '/^ARCH=/{print $2}')

  # SEC: validate remote_shell — must be absolute path to a known shell
  # prevents a malicious server from injecting commands via shell path
  if [[ ! "$_rshell" =~ ^/[a-zA-Z0-9/_-]+$ ]] || [[ ! "$_rshell" =~ (ba)?sh$ ]]; then
    printf '✗ Remote returned suspicious shell path: %q\n' "$_rshell"; return 1
  fi

  if printf '%s\n' "$_probe" | grep -q '^CACHED'; then
    _cache_age=$(printf '%s\n' "$_probe" | awk '/^CACHED/{print $2}')
    _cached=true
  fi

  local _larch; _larch=$(uname -m)
  local _same_arch=false
  [[ "$_larch" = "$_rarch" ]] && _same_arch=true

  printf '🐚 Remote: %s on %s\n' "$_rshell" "$_rarch"
  $_same_arch || printf '⚠  Arch mismatch (%s → %s) — .so files excluded\n' "$_larch" "$_rarch"

  # ── helper: connect (used by cache-hit path and main path) ────────
  # no exec — bash --rcfile starts as the interactive shell directly
  # trap set inside rcfile survives because it's sourced into the final shell
  _sssh_connect() {
    local _cmd
    [[ "$_rshell" == *bash ]] \
      && _cmd="$_rshell --rcfile /tmp/.sssh_env" \
      || _cmd="ENV=/tmp/.sssh_env $_rshell -i"
    ssh -t "${_cm_opts[@]}" "$_host" "export PATH=/tmp:\$PATH; $_cmd"
  }

  # ── cache hit: connect directly ───────────────────────────────────
  if $_cached; then
    printf '⚡ Cache hit (%dm old) — connecting directly  (--force to re-copy)\n' \
      "$(( _cache_age / 60 ))"
    _sssh_connect
    return
  fi

  # ── plan copies ───────────────────────────────────────────────────
  local _to_copy=() _to_paths=() _to_types=()
  printf '\n📋 Planning...\n'

  while IFS= read -r _line; do
    local _b="${_line#* }" _t="${_bin_type[${_line#* }]:-STATIC}"
    if   [[ "$_t" == SKIP ]];       then printf '  ⊘  %s — use remote own\n' "$_b"
    elif [[ "$_line" == HAS* ]];    then printf '  ✓  %s — already present\n' "$_b"
    else
      local _lp; _lp=$(command -v "$_b" 2>/dev/null)
      if [[ -z "$_lp" ]]; then printf '  -  %s — not found locally\n' "$_b"
      else
        printf '  →  %s [%s]\n' "$_b" "$_t"
        _to_copy+=("$_b"); _to_paths+=("$_lp"); _to_types+=("$_t")
      fi
    fi
  done <<< "$(printf '%s\n' "$_probe" | grep -E '^(HAS|MISSING) ')"

  # ── plan nvim ─────────────────────────────────────────────────────
  if $_copy_nvim && [[ ! -d "$_nvim_cfg" ]]; then
    printf '  ✗  ~/.config/nvim not found — disabling --nvim\n'; _copy_nvim=false
  fi
  if $_copy_nvim; then
    printf '  →  nvim (download on remote) + config (%s)\n' \
      "$(du -sh "$_nvim_cfg" 2>/dev/null | cut -f1)"
    $_copy_plugins && [[ -d "$_nvim_lazy" ]] && \
      printf '  →  plugins (%s)\n' "$(du -sh "$_nvim_lazy" 2>/dev/null | cut -f1)"
  fi

  # ── build env file ────────────────────────────────────────────────
  local _tmp_env; _tmp_env=$(mktemp /tmp/sssh_env.XXXXXX)

  # 1. source remote's own config first (our aliases override after)
  printf '%s\n' \
    '[ -f ~/.bashrc ]  && source ~/.bashrc  2>/dev/null' \
    '[ -f ~/.profile ] && source ~/.profile 2>/dev/null' \
    >> "$_tmp_env"

  # 2. live aliases (exactly what's active now — no parsing needed)
  alias >> "$_tmp_env"
  printf '\n' >> "$_tmp_env"

  # 3. user-defined functions (subtract clean-bash baseline)
  local _clean_fns _cur_fns _user_fns
  _clean_fns=$(bash --norc --noprofile -c 'declare -F' 2>/dev/null | awk '{print $3}')
  _cur_fns=$(declare -F | awk '{print $3}')
  _user_fns=$(comm -23 <(printf '%s\n' "$_cur_fns" | sort) \
                        <(printf '%s\n' "$_clean_fns" | sort))
  # shellcheck disable=SC2086
  [[ -n "$_user_fns" ]] && declare -f $_user_fns >> "$_tmp_env"
  printf '\n' >> "$_tmp_env"

  # 4. nvim alias (if copying nvim)
  if $_copy_nvim; then
    printf "alias nvim='XDG_CONFIG_HOME=%s/.config XDG_DATA_HOME=%s/.local/share XDG_STATE_HOME=%s/.local/state XDG_CACHE_HOME=%s/.cache %s/bin/nvim'\n" \
      "$_nvim_rdir" "$_nvim_rdir" "$_nvim_rdir" "$_nvim_rdir" "$_nvim_rdir" >> "$_tmp_env"
    printf "alias vi='nvim'\n" >> "$_tmp_env"
  fi

  # 5. cleanup list
  local _clean=("/tmp/.sssh_env" "/tmp/.sssh_guardian")
  for _b in "${_to_copy[@]}"; do _clean+=("/tmp/$_b"); done
  $_copy_nvim && _clean+=("$_nvim_rdir")
  local _cleanup_cmd="rm -rf ${_clean[*]}"

  # 7. remote env filter (runs on source — purges broken aliases/completions)
  cat >> "$_tmp_env" << 'ENV_FILTER'

# ── sssh: strip plugin functions that require tools not on this server ──
_sssh_purge_plugins() {
  local _p _f _removed=()
  local _pats=('^_zoxide' '^__zoxide' '^zd$' '^_z$' '^__z$' '^_z_'
               '^_fzf_' '^__fzf_' '^_fasd' '^fasd' '^_autojump' '^autojump'
               '^_zellij' '^__zellij' '^_atuin' '^__atuin')
  while IFS= read -r _f; do
    for _p in "${_pats[@]}"; do
      if [[ "$_f" =~ $_p ]]; then unset -f "$_f" 2>/dev/null; _removed+=("$_f"); break; fi
    done
  done < <(declare -F | awk '{print $3}')
  (( ${#_removed[@]} )) && printf 'sssh: removed %d plugin functions: %s\n' \
    "${#_removed[@]}" "${_removed[*]}"
  # strip plugin hooks from PROMPT_COMMAND
  PROMPT_COMMAND=$(printf '%s' "$PROMPT_COMMAND" | tr ';' '\n' \
    | grep -vE '_zoxide_hook|__zoxide|_z_hook|atuin|__bp_' \
    | grep -v '^[[:space:]]*$' | paste -sd ';' -)
}

# ── sssh: remove aliases whose commands aren't on this server ──────
_sssh_filter_aliases() {
  local _n _body _cmds _cmd _skipped=()
  for _n in $(alias | sed "s/alias \([^=]*\)=.*/\1/"); do
    _body=$(alias "$_n" 2>/dev/null | sed "s/alias $_n=//;s/^'//;s/'$//")
    # extract all command-position tokens (start, after && || | ; $()
    _cmds=$(printf '%s' "$_body" \
      | sed 's/&&/\n/g;s/||/\n/g;s/|/\n/g;s/;/\n/g;s/\$(/\n/g' \
      | awk '{print $1}' | grep -oE '[a-zA-Z_][a-zA-Z0-9_-]+' | sort -u)
    local _miss=""
    while IFS= read -r _cmd; do
      [[ -z "$_cmd" ]] && continue
      case "$_cmd" in
        cd|echo|printf|source|export|local|return|true|false|test|if|then|else|\
        do|done|while|for|in|case|esac|fi|time|sudo|grep|awk|sed|sort|cut|\
        head|tail|xargs|find|tar|mkdir|rm|cp|mv|cat|wc|read|history|ps|\
        unset|shift|set|trap|wait|exec|eval|type|command|hash|pwd|env) continue ;;
      esac
      command -v "$_cmd" >/dev/null 2>&1 && continue
      _miss="$_cmd"; break
    done <<< "$_cmds"
    if [[ -n "$_miss" ]]; then
      _skipped+=("${_n}(${_miss})"); unalias "$_n" 2>/dev/null
    fi
  done
  (( ${#_skipped[@]} )) && {
    printf 'sssh: skipped %d aliases (commands not on this server):\n' "${#_skipped[@]}"
    printf '  ✗  %s\n' "${_skipped[@]}"
  }
}

# ── sssh: reset completions that use missing functions ──────────────
_sssh_clean_completions() {
  local _func _cmd
  while IFS= read -r _line; do
    _func=$(printf '%s' "$_line" | grep -oE '\-F \S+' | awk '{print $2}')
    _cmd=$( printf '%s' "$_line" | awk '{print $NF}')
    [[ -z "$_func" ]] && continue
    declare -f "$_func" >/dev/null 2>&1 && continue
    complete -r "$_cmd" 2>/dev/null
  done < <(complete -p 2>/dev/null)
  # always reset cd (zoxide/autojump hijack it) with a bash-version-safe spec
  complete -r cd 2>/dev/null
  complete -o filenames -o nospace -d cd
  # strip completions for copied tools — their system scripts may use bash 5.3+ features
  local _t; for _t in fzf bat rg fd delta eza; do
    command -v "$_t" >/dev/null 2>&1 && complete -r "$_t" 2>/dev/null
  done
}

_sssh_purge_plugins; _sssh_filter_aliases; _sssh_clean_completions
unset -f _sssh_purge_plugins _sssh_filter_aliases _sssh_clean_completions
ENV_FILTER

  printf '  →  env: %d aliases, %d functions\n' \
    "$(grep -c '^alias' "$_tmp_env" 2>/dev/null || true)" \
    "$(printf '%s\n' "$_user_fns" | grep -c . 2>/dev/null || true)"

  # ── pre-clean remote (via ControlMaster — fast) ───────────────────
  ssh "${_cm_opts[@]}" "$_host" "rm -rf ${_clean[*]}" 2>/dev/null

  # ── start nvim download on remote in background ───────────────────
  local _nvim_dl_pid=""
  if $_copy_nvim; then
    printf '\n⬇  Downloading nvim on remote (background)...\n'
    ssh "${_cm_opts[@]}" "$_host" bash -s > /tmp/sssh_nvim_dl.log 2>&1 << 'NVIM_DL' &
case "$(uname -m)" in
  x86_64) _na=x86_64 ;; aarch64|arm64) _na=arm64 ;; *) _na=x86_64 ;;
esac
_nv=$(curl -sL "https://api.github.com/repos/neovim/neovim/releases/latest" \
  | grep '"tag_name"' | head -1 | cut -d'"' -f4)
[ -z "$_nv" ] && _nv="v0.10.4"
mkdir -p /tmp/nvim_home
curl -sL "https://github.com/neovim/neovim/releases/download/${_nv}/nvim-linux-${_na}.tar.gz" \
  | tar -xzf - -C /tmp/nvim_home --strip-components=1
printf 'NVIM_OK %s linux-%s\n' "$_nv" "$_na"
NVIM_DL
    _nvim_dl_pid=$!
  fi

  # ── bundle all files into one tar, pipe over ControlMaster ────────
  # one transfer instead of N scp handshakes; stage dir gives files correct names
  printf '\n📦 Bundling and transferring...\n'
  local _stage; _stage=$(mktemp -d /tmp/sssh_stage.XXXXXX)

  # SEC: copy binaries with explicit 755 — avoids propagating setuid bits
  cp "$_tmp_env" "$_stage/.sssh_env"
  local _i; for _i in "${!_to_copy[@]}"; do
    install -m 755 "${_to_paths[$_i]}" "$_stage/${_to_copy[$_i]}"
  done
  rm -f "$_tmp_env"

  local _stage_size; _stage_size=$(du -sh "$_stage" 2>/dev/null | cut -f1)
  if tar -czf - -C "$_stage" . \
      | ssh "${_cm_opts[@]}" "$_host" \
          "tar -xzf - -C /tmp && chmod 600 /tmp/.sssh_env; printf 'BUNDLE_OK\n'"; then
    printf '  ✓  transferred (%s)\n' "$_stage_size"
  else
    printf '  ✗  transfer failed\n'
  fi
  rm -rf "$_stage"

  # ── verify binaries via stdin (SEC: avoids single-quote injection) ─
  local _verify_script
  _verify_script=$(cat << 'VERIFY_HDR'
_sssh_ver() {
  curl -sL "https://api.github.com/repos/$1/releases/latest" \
    | grep '"tag_name"' | head -1 | cut -d'"' -f4 | tr -d v
}
_sssh_musl() {
  local _b="$1" _a; _a=$(uname -m)
  local _v _u
  case "$_b" in
    bat) _v=$(_sssh_ver sharkdp/bat)
      case $_a in
        x86_64)  _u="https://github.com/sharkdp/bat/releases/download/v${_v}/bat-v${_v}-x86_64-unknown-linux-musl.tar.gz" ;;
        aarch64) _u="https://github.com/sharkdp/bat/releases/download/v${_v}/bat-v${_v}-aarch64-unknown-linux-musl.tar.gz" ;;
      esac
      curl -sL "$_u" | tar -xzf - --wildcards --strip-components=1 -O '*/bat' > /tmp/bat ;;
    rg) _v=$(_sssh_ver BurntSushi/ripgrep)
      case $_a in
        x86_64)  _u="https://github.com/BurntSushi/ripgrep/releases/download/${_v}/ripgrep-${_v}-x86_64-unknown-linux-musl.tar.gz" ;;
        aarch64) _u="https://github.com/BurntSushi/ripgrep/releases/download/${_v}/ripgrep-${_v}-aarch64-unknown-linux-musl.tar.gz" ;;
      esac
      curl -sL "$_u" | tar -xzf - --wildcards --strip-components=1 -O '*/rg' > /tmp/rg ;;
    fd) _v=$(_sssh_ver sharkdp/fd)
      case $_a in
        x86_64)  _u="https://github.com/sharkdp/fd/releases/download/v${_v}/fd-v${_v}-x86_64-unknown-linux-musl.tar.gz" ;;
        aarch64) _u="https://github.com/sharkdp/fd/releases/download/v${_v}/fd-v${_v}-aarch64-unknown-linux-musl.tar.gz" ;;
      esac
      curl -sL "$_u" | tar -xzf - --wildcards --strip-components=1 -O '*/fd' > /tmp/fd ;;
    fzf) _v=$(_sssh_ver junegunn/fzf)
      case $_a in
        x86_64)  _u="https://github.com/junegunn/fzf/releases/download/v${_v}/fzf-${_v}-linux_amd64.tar.gz" ;;
        aarch64) _u="https://github.com/junegunn/fzf/releases/download/v${_v}/fzf-${_v}-linux_arm64.tar.gz" ;;
      esac
      curl -sL "$_u" | tar -xzf - -O fzf > /tmp/fzf ;;
  esac
  chmod +x "/tmp/$_b" 2>/dev/null
}
VERIFY_HDR
)

  printf '\n🔍 Verifying...\n'
  for _i in "${!_to_copy[@]}"; do
    local _b="${_to_copy[$_i]}" _t="${_to_types[$_i]}"
    if [[ "$_t" == STATIC ]]; then
      _verify_script+="
/tmp/${_b} --version >/dev/null 2>&1 || /tmp/${_b} --help >/dev/null 2>&1 \
  && printf 'OK ${_b}\n' \
  || { _sssh_musl ${_b}; /tmp/${_b} --version >/dev/null 2>&1 \
    && printf 'OK_MUSL ${_b}\n' || { printf 'FAILED ${_b}\n'; rm -f /tmp/${_b}; }; }"
    else
      _verify_script+="
/tmp/${_b} --version >/dev/null 2>&1 || /tmp/${_b} -h >/dev/null 2>&1 \
  && printf 'OK ${_b}\n' || { printf 'BROKEN ${_b}\n'; rm -f /tmp/${_b}; }"
    fi
  done
  _verify_script+="
unset -f _sssh_ver _sssh_musl"

  while IFS= read -r _r; do
    case "$_r" in
      OK_MUSL*) printf '  ✓  %s (musl fallback)\n' "${_r#* }" ;;
      OK*)      printf '  ✓  %s\n'                 "${_r#* }" ;;
      BROKEN*)  printf '  ✗  %s (deps missing)\n'  "${_r#* }" ;;
      FAILED*)  printf '  ✗  %s (failed)\n'        "${_r#* }" ;;
    esac
  done < <(printf '%s\n' "$_verify_script" | ssh "${_cm_opts[@]}" "$_host" bash -s 2>/dev/null)

  # ── sync nvim config + plugins ────────────────────────────────────
  if $_copy_nvim; then
    printf '\n🔄 Syncing nvim config...\n'
    ssh "${_cm_opts[@]}" "$_host" \
      "mkdir -p $_nvim_rdir/.config $_nvim_rdir/.local/share/nvim \
                $_nvim_rdir/.local/state/nvim $_nvim_rdir/.cache/nvim" 2>/dev/null

    # inject mason-disable plugin before syncing so it lands on remote
    local _mdisable="$_nvim_cfg/lua/plugins/sssh_remote.lua"
    cat > "$_mdisable" << 'LUA'
-- auto-generated by sssh — disables mason/LSP on remote (no internet, wrong arch)
return {
  { "williamboman/mason.nvim",                   enabled = false },
  { "williamboman/mason-lspconfig.nvim",         enabled = false },
  { "WhoIsSethDaniel/mason-tool-installer.nvim", enabled = false },
}
LUA

    _sssh_sync() {
      local _src="$1" _dst="$2" _lbl="$3" _flags="${4:-}"
      if command -v rsync >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        rsync -az $_flags --info=progress2 \
          -e "ssh ${_cm_opts[*]}" "$_src" "$_host:$_dst" \
          && printf '  ✓  %s\n' "$_lbl" || printf '  ✗  %s\n' "$_lbl"
      else
        tar -czf - -C "$(dirname "$_src")" "$(basename "$_src")" \
          | ssh "${_cm_opts[@]}" "$_host" "mkdir -p $_dst && tar -xzf - -C $_dst" \
          && printf '  ✓  %s\n' "$_lbl" || printf '  ✗  %s\n' "$_lbl"
      fi
    }

    _sssh_sync "$_nvim_cfg" "$_nvim_rdir/.config/" "nvim config"

    if $_copy_plugins && [[ -d "$_nvim_lazy" ]]; then
      printf '🔄 Syncing nvim plugins...\n'
      local _so=""
      $_same_arch || _so="--exclude='*.so' --exclude='parser/' --exclude='build/'"
      _sssh_sync "$_nvim_lazy" "$_nvim_rdir/.local/share/nvim/" "nvim plugins" "$_so"
    fi

    rm -f "$_mdisable"
    unset -f _sssh_sync

    printf '\n⬇  Waiting for nvim download...\n'
    if wait "$_nvim_dl_pid" 2>/dev/null; then
      grep -q NVIM_OK /tmp/sssh_nvim_dl.log 2>/dev/null \
        && printf '  ✓  nvim %s\n' "$(awk '/NVIM_OK/{print $2,$3}' /tmp/sssh_nvim_dl.log)" \
        || { printf '  ✗  nvim download failed:\n'; sed 's/^/     /' /tmp/sssh_nvim_dl.log; }
    fi
    rm -f /tmp/sssh_nvim_dl.log

    if $_copy_plugins && ! $_same_arch; then
      printf '🔨 Recompiling treesitter parsers (arch mismatch)...\n'
      ssh "${_cm_opts[@]}" "$_host" \
        "XDG_CONFIG_HOME=$_nvim_rdir/.config \
         XDG_DATA_HOME=$_nvim_rdir/.local/share \
         XDG_STATE_HOME=$_nvim_rdir/.local/state \
         XDG_CACHE_HOME=$_nvim_rdir/.cache \
         $_nvim_rdir/bin/nvim --headless -c 'TSUpdateSync' -c 'qa' 2>/dev/null" \
        && printf '  ✓  parsers recompiled\n' \
        || printf '  ⚠  recompile errors (gcc may be missing)\n'
    fi
  fi

  # ── guardian: remote fallback for network-drop case ──────────────
  # ssh -t exits locally when session ends (clean exit, kill, pty close)
  # and we run cleanup from local side immediately after
  # guardian covers only the one case where local machine loses connectivity
  # and the remote session is also killed — cleans up after 2h in that case
  printf '\n✓  Connecting...\n'
  ssh "${_cm_opts[@]}" "$_host" bash -s << GUARDIAN
cat > /tmp/.sssh_guardian << 'SCRIPT'
#!/bin/bash
# launched before session; exits when session ends or after 2h
# the local-side cleanup runs first in normal cases; this is the fallback
_timeout=7200; _elapsed=0
# wait up to 30s for session to start (ssh -t takes a moment)
for _i in \$(seq 300); do
  ssh_procs=\$(pgrep -c sshd 2>/dev/null || echo 0)
  [ "\$ssh_procs" -gt 0 ] && break
  sleep 0.1
done
# just sleep for the timeout — local cleanup handles normal cases
sleep "\$_timeout"
# if we reach here (2h passed) run cleanup regardless
$_cleanup_cmd
SCRIPT
chmod +x /tmp/.sssh_guardian
nohup /tmp/.sssh_guardian </dev/null >/dev/null 2>&1 &
GUARDIAN

  # ── _sssh_connect: session + guaranteed local cleanup ─────────────
  # ssh -t blocks until session ends for ANY reason:
  #   clean exit, kill -9, pty close, network drop (ssh detects TCP close)
  # cleanup runs on local machine after ssh returns — always executes
  _sssh_connect() {
    local _cmd
    [[ "$_rshell" == *bash ]] \
      && _cmd="$_rshell --rcfile /tmp/.sssh_env" \
      || _cmd="ENV=/tmp/.sssh_env $_rshell -i"

    ssh -t "${_cm_opts[@]}" "$_host" "export PATH=/tmp:\$PATH; $_cmd"

    # LOCAL cleanup — guaranteed to run when ssh -t exits
    # works for: clean exit, kill, network drop (ssh returns with error)
    ssh "${_cm_opts[@]}" "$_host" "$_cleanup_cmd" 2>/dev/null || true
  }

  _sssh_connect
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
