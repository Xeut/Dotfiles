# If not running interactively, don't do anything (leave this at the top of this file)
[[ $- != *i* ]] && return

# All the default Omarchy aliases and functions
# (don't mess with these directly, just overwrite them here!)
source ~/.local/share/omarchy/default/bash/rc

# Add your own exports, aliases, and functions here.
#
export PATH="$HOME/Scripts:$PATH"
export PATH="$HOME/.local/bin:$PATH"

# Make an alias for invoking commands you use constantly
alias p='python'
alias f='nvim $(ff)'
alias vim='nvim'
alias fp='fzf --preview "bat --style=numbers --color=always --line-range :500 {}"'
alias bat='bat --style=numbers --color=always --paging=always'
alias please='sudo $(history -p !!)'
alias bashrc='nvim ~/.bashrc && source ~/.bashrc'
alias showmem='ps -eo pid,ppid,cmd,%mem --sort=-%mem | head -n 10'
alias showcpu='ps -eo pid,ppid,cmd,%cpu --sort=-%cpu | head -n 10'
alias weather='curl -s wttr.in?0'
alias countthis='find . -path "./.venv" -prune -o -type f -exec wc -lw {} +'

# Accessible at http://localhost:8000
alias pyserve='python3 -m http.server'

# Usage: psg firefox
alias psg='ps aux | grep -v grep | grep -i -E'

# fuzzy finder for history 
__fzf_history__() {
  local selected
  selected=$(history | fzf --tac +s | sed 's/ *[0-9]* *//')
  READLINE_LINE="$selected"
  READLINE_POINT=${#READLINE_LINE}
}
bind -x '"\C-r": __fzf_history__'

# mkdir + cd 
mkcd() {
  mkdir -p "$1" && cd "$1"
}

port() {
  lsof -i :"$1"
}

cl() {
  cd "$1" && ls
}

# Usage: timer 60 (for 60 seconds)
timer() {
  sleep "$1" && echo -e "\aTimer Finished: $(date)"
}

# Enhanced Quick Notes with Command Capture & Pipe Support
qnote() {
  local timestamp=$(date +"%Y-%m-%d : %H:%M:%S")
  local note_file=~/.quicknotes.txt
  
  if [ -t 0 ]; then
    # Case 1: Direct input (e.g., qnote "Hello")
    if [ -n "$1" ]; then
      echo -e "DATE: $timestamp\nNOTE: $*\n\n\e[31m$(printf '%.0s-' {1..40})\e[0m\n" >> "$note_file"
    else
      echo "Usage: qnote 'your message' OR your_command | qnote"
    fi
  else
    # Case 2: Piped input (e.g., ip a | qnote)
    # We grab the last command from history
    local last_cmd=$(history 1 | sed 's/^[ ]*[0-9]*[ ]*//')
    
    {
      echo "DATE:    $timestamp"
      echo "COMMAND: $last_cmd"
      echo -e "OUTPUT:\n"
      cat # This captures the entire piped output as one block
      echo -e "\n\e[31m$(printf '%.0s-' {1..40})\e[0m\n"
    } >> "$note_file"
  fi
}

# View Notes with 'bat'
# Usage: vnote (shows all) or vnote 20 (shows last 20 lines)
alias vnote='bat ~/.quicknotes.txt --style="full" --paging="always" -l log'

# extract everything
extract() {
  if [ -f $1 ] ; then
    case $1 in
      *.tar.bz2)   tar xjf $1     ;;
      *.tar.gz)    tar xzf $1     ;;
      *.bz2)       bunzip2 $1     ;;
      *.rar)       unrar e $1     ;;
      *.gz)        gunzip $1      ;;
      *.tar)       tar xf $1      ;;
      *.tbz2)      tar xjf $1     ;;
      *.tgz)       tar xzf $1     ;;
      *.zip)       unzip $1       ;;
      *.Z)         uncompress $1  ;;
      *.7z)        7z x $1        ;;
      *)     echo "'$1' cannot be extracted via extract()" ;;
    esac
  else
    echo "'$1' is not a valid file"
  fi
}

# Enable programmable completion
if ! shopt -oq posix; then
  if [ -f /usr/local/etc/bash_completion ]; then
    . /usr/local/etc/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# shows my local and public ip
myip() {
  echo "Local IP: $(hostname -I | awk '{print $1}')"
  echo "Public IP: $(curl -s https://ifconfig.me)"
}

# Case-insensitive completion
bind 'set completion-ignore-case on'

# Hyphen/underscore equivalence
bind 'set completion-map-case on'

# Colorized completions
bind 'set colored-stats on'
bind 'set colored-completion-prefix on'

# Big, shared history
export HISTSIZE=100000
export HISTFILESIZE=200000
shopt -s histappend

# Avoid useless entries
export HISTCONTROL=ignoreboth:erasedups
export HISTIGNORE="ls:cd:pwd:exit"

# Save after every command
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }history -a; history -n"

# Autocorrect minor cd mistakes
shopt -s cdspell

# Recursive globbing (**)
shopt -s globstar

# Don't overwrite files accidentally
set -o noclobber

# Alt+← / Alt+→ move by word
bind '"\e[1;3C": forward-word'
bind '"\e[1;3D": backward-word'

# Ctrl+L clears screen cleanly
bind '"\C-l": clear-screen'

# My exports
export EDITOR='nvim'
export VISUAL='nvim'
export BAT_PAGER="less -R"
export LESS="--mouse"

alias hallo="echo HALLO WELT"

if [[ -z "$TMUX" ]]; then
    #bash ~/Scripts/tmux-init
    tmux attach-session
fi
