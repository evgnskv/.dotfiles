#!/bin/bash
set -euo pipefail

BASE_DIR="$HOME/obsidian-slate"

selected=$(rg -n . "$BASE_DIR" | \
           fzf --preview 'less -N -j 15 +{2} {1}' \
               --delimiter ':' \
               -e)

if [[ -n "$selected" ]]; then
    filepath_full=$(echo "$selected" | cut -d':' -f1)
    filepath_relative="${filepath_full#$BASE_DIR/}"
    VAULT_NAME="${filepath_relative%%/*}"
    
    filepath_short="${filepath_relative#$VAULT_NAME/}"
    filepath_enc="$(printf '%s\n' "$filepath_short" | jq -Rr @uri)"
    
    obsidian_url="obsidian://open?vault=${VAULT_NAME}&file=${filepath_enc}"
    echo "$obsidian_url"
    open "$obsidian_url"
else
    echo "No selection"
fi
