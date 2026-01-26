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

# git-lookup shell integration
eval "$(git-lookup shell-hook)"
