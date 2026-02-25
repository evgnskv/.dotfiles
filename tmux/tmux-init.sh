#!/usr/bin/env bash

set -e

CONFIG="./tmux-session.yaml"
ACTION=""
VERBOSE=0

log() {
    [[ "$VERBOSE" -eq 1 ]] && echo "$@" || true
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f)
            CONFIG="$2"
            shift 2
            ;;
        -v)
            VERBOSE=1
            shift
            ;;
        -h)
            echo "Usage: $0 [-f config_file] [-v] [attach|list|prune]"
            echo "  -f  Path to config file (default: ./tmux-session.yaml)"
            echo "  -v  Verbose output"
            echo "  attach  Attach to first session in config"
            echo "  list    Show session chooser (choose-window)"
            echo "  prune   Remove sessions/windows not in config"
            exit 0
            ;;
        attach|list|prune)
            ACTION="$1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

if [[ ! -f "$CONFIG" ]]; then
    echo "Error: $CONFIG not found"
    exit 1
fi

if ! command -v yq &> /dev/null; then
    echo "Error: yq is not installed"
    exit 1
fi

if ! command -v tmux &> /dev/null; then
    echo "Error: tmux is not installed"
    exit 1
fi

array_contains() {
    local elem
    for elem in "${@:2}"; do
        [[ "$elem" == "$1" ]] && return 0
    done
    return 1
}

count_panes_in_tree() {
    local pane_spec="$1"
    local count=1
    
    for dir_key in h v; do
        local child_spec=$(yq -r ".$dir_key // empty" <<< "$pane_spec")
        if [[ -n "$child_spec" && "$child_spec" != "null" ]]; then
            count=$((count + $(count_panes_in_tree "$child_spec")))
        fi
    done
    
    echo "$count"
}

build_exec_cmd() {
    local cmd="$1"
    local dir="$2"
    
    local exec_cmd=""
    if [[ -n "$dir" && "$dir" != "null" ]]; then
        dir="${dir/#\~/$HOME}"
        if [[ ! -d "$dir" ]]; then
            log "Error: directory '$dir' does not exist"
            echo ""
            return 1
        else
            exec_cmd="cd \"$dir\" && clear"
            if [[ -n "$cmd" && "$cmd" != "null" ]]; then
                exec_cmd="$exec_cmd && $cmd"
            fi
        fi
    elif [[ -n "$cmd" && "$cmd" != "null" ]]; then
        exec_cmd="$cmd"
    fi
    
    echo "$exec_cmd"
}

process_pane_tree() {
    local session="$1"
    local window="$2"
    local pane_spec="$3"
    local parent="$4"
    local split_dir="$5"
    
    local cmd=$(yq -r '.cmd // empty' <<< "$pane_spec")
    local dir=$(yq -r '.dir // empty' <<< "$pane_spec")
    local size=$(yq -r '.size // empty' <<< "$pane_spec")
    
    local exec_cmd=$(build_exec_cmd "$cmd" "$dir")
    local current_parent="$parent"
    
    local new_pane
    if [[ -n "$parent" ]]; then
        local split_args=("-t" "$parent")
        
        if [[ "$split_dir" == "h" ]]; then
            split_args+=("-h")
        else
            split_args+=("-v")
        fi
        
        if [[ -n "$size" && "$size" != "null" ]]; then
            split_args+=("-p" "$size")
        fi
        
        new_pane=$(tmux split-window -P -F '#{pane_id}' "${split_args[@]}")
        
        if [[ -n "$exec_cmd" ]]; then
            log "Sending cmd to $new_pane: $exec_cmd"
            tmux send-keys -t "$new_pane" "$exec_cmd" C-m
        fi
        
        current_parent="$new_pane"
    else
        local first_pane=$(tmux list-panes -t "$session:$window" -F '#{pane_id}' | head -1)
        current_parent="$first_pane"
        
        if [[ -n "$exec_cmd" ]]; then
            if [[ -n "$first_pane" ]]; then
                log "Sending cmd to first pane $first_pane: $exec_cmd"
                tmux send-keys -t "$first_pane" "$exec_cmd" C-m
            fi
        fi
    fi
    
    for dir_key in h v; do
        local child_spec=$(yq -r ".$dir_key // empty" <<< "$pane_spec")
        if [[ -n "$child_spec" && "$child_spec" != "null" ]]; then
            process_pane_tree "$session" "$window" "$child_spec" "$current_parent" "$dir_key"
        fi
    done
}

yaml_sessions=($(yq -r 'keys | .[]' "$CONFIG" | grep -v '^$'))

if [[ "$ACTION" == "prune" ]]; then
    mapfile -t tmux_sessions < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
    
    for tmux_session in "${tmux_sessions[@]}"; do
        [[ -z "$tmux_session" ]] && continue
        
        if ! array_contains "$tmux_session" "${yaml_sessions[@]}"; then
            log "Pruning session: $tmux_session"
            tmux kill-session -t "$tmux_session" 2>/dev/null || true
            continue
        fi
        
        mapfile -t tmux_windows < <(tmux list-windows -t "$tmux_session" -F '#{window_name}' 2>/dev/null || true)
        mapfile -t config_windows < <(yq -r '.["'$tmux_session'"][] | keys | .[0]' "$CONFIG" | grep -v '^$')
        
        for tmux_window in "${tmux_windows[@]}"; do
            [[ -z "$tmux_window" ]] && continue
            
            if ! array_contains "$tmux_window" "${config_windows[@]}"; then
                log "Pruning window: $tmux_session:$tmux_window"
                tmux kill-window -t "$tmux_session:$tmux_window" 2>/dev/null || true
            fi
        done
    done
    
    exit 0
fi

for yaml_session in "${yaml_sessions[@]}"; do
    [[ -z "$yaml_session" ]] && continue
    
    if ! tmux has-session -t "$yaml_session" 2>/dev/null; then
        log "Creating session: $yaml_session"
        tmux new-session -d -s "$yaml_session"
    else
        log "Session '$yaml_session' already exists"
    fi

    mapfile -t config_windows < <(yq -r '.["'$yaml_session'"][] | keys | .[0]' "$CONFIG" | grep -v '^$')
    
    first_config_window="${config_windows[0]}"
    
    existing_window_count=$(tmux list-windows -t "$yaml_session" 2>/dev/null | wc -l)
    if [[ -n "$first_config_window" && "$existing_window_count" -gt 0 ]]; then
        first_existing_window=$(tmux list-windows -t "$yaml_session" -F '#{window_index}' | head -1)
        first_existing_name=$(tmux list-windows -t "$yaml_session" -F '#{window_name}' | head -1)
        if [[ "$first_existing_name" != "$first_config_window" ]]; then
            log "Renaming window $first_existing_window to: $first_config_window"
            tmux rename-window -t "$yaml_session:$first_existing_window" "$first_config_window"
        fi
    fi
    
    for config_window in "${config_windows[@]}"; do
        [[ -z "$config_window" ]] && continue
        [[ "$config_window" == "$first_config_window" ]] && continue
        
        if ! tmux list-windows -t "$yaml_session" 2>/dev/null | grep -qF "$config_window"; then
            log "Creating window: $yaml_session:$config_window"
            tmux new-window -t "$yaml_session:" -n "$config_window"
        fi
    done
    
    for config_window in "${config_windows[@]}"; do
        [[ -z "$config_window" ]] && continue
        
        pane_count=$(tmux list-panes -t "$yaml_session:$config_window" 2>/dev/null | wc -l)
        
        for ((window_idx=0; ; window_idx++)); do
            window_name_check=$(yq -r '.["'$yaml_session'"]['$window_idx'] | keys | .[0] // empty' "$CONFIG")
            [[ "$window_name_check" == "$config_window" ]] && break
            [[ "$window_name_check" == "empty" ]] && break
        done
        
        root_pane_spec=$(yq -r '.["'$yaml_session'"]['$window_idx']["'$config_window'"].root // empty' "$CONFIG")
        
        if [[ -n "$root_pane_spec" && "$root_pane_spec" != "null" && "$root_pane_spec" != "empty" ]]; then
            expected_panes=$(count_panes_in_tree "$root_pane_spec")
            
            if [[ "$pane_count" -lt "$expected_panes" ]]; then
                panes_to_create=$((expected_panes - pane_count))
                log "Creating $panes_to_create pane(s) in $yaml_session:$config_window (have $pane_count, need $expected_panes)"
                process_pane_tree "$yaml_session" "$config_window" "$root_pane_spec" ""
            elif [[ "$pane_count" -eq "$expected_panes" ]]; then
                log "Panes in $yaml_session:$config_window match config ($pane_count panes)"
            fi
        fi
    done
done

first_session=$(yq -r 'keys | .[0]' "$CONFIG")

if [[ "$ACTION" == "attach" ]]; then
    if [[ -n "$TMUX" ]]; then
        tmux switch-client -t "$first_session"
    else
        tmux attach-session -t "$first_session"
    fi
elif [[ "$ACTION" == "list" ]]; then
    if [[ -n "$TMUX" ]]; then
        tmux choose-window
    else
        tmux attach-session -t "$first_session" && tmux choose-window
    fi
fi

exit 0
