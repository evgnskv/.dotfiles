#!/usr/bin/env bash

set -e

CONFIG="./tmux-session.yaml"
ACTION=""
VERBOSE=0

log() {
    [[ "$VERBOSE" -eq 1 ]] && echo "$@" >&2 || true
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
            echo "  prune   Remove sessions/windows not in config and reorder"
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

# --- Helper functions ---

# Check if a session with the exact name exists.
# tmux has-session uses prefix matching, so we use list-sessions instead.
session_exists() {
    tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -qxF "$1"
}

# Check if a window with exact name exists in a session.
# The "=" prefix forces tmux to match the session name exactly.
window_exists() {
    tmux list-windows -t "=$1" -F '#{window_name}' 2>/dev/null | grep -qxF "$2"
}

# Look up a window's index by name in a session.
# Returns the index or empty string.
get_window_index() {
    local session="$1" name="$2" i n
    while IFS=: read -r i n; do
        if [[ "$n" == "$name" ]]; then echo "$i"; return; fi
    done < <(tmux list-windows -t "=$session" -F '#{window_index}:#{window_name}' 2>/dev/null)
    return 0
}

# Look up a window's name by index in a session.
# Returns the name or empty string.
get_window_name() {
    local session="$1" idx="$2" i n
    while IFS=: read -r i n; do
        if [[ "$i" == "$idx" ]]; then echo "$n"; return; fi
    done < <(tmux list-windows -t "=$session" -F '#{window_index}:#{window_name}' 2>/dev/null)
    return 0
}

# Build the shell command string to send to a pane (cd + command).
build_exec_cmd() {
    local cmd="$1"
    local dir="$2"

    local exec_cmd=""
    if [[ -n "$dir" && "$dir" != "null" ]]; then
        local expanded_dir="${dir/#\~/$HOME}"
        if [[ ! -d "$expanded_dir" ]]; then
            log "Warning: directory '$dir' does not exist"
            return 1
        fi
        exec_cmd="cd \"$expanded_dir\" && clear"
        if [[ -n "$cmd" && "$cmd" != "null" ]]; then
            exec_cmd="$exec_cmd && $cmd"
        fi
    elif [[ -n "$cmd" && "$cmd" != "null" ]]; then
        exec_cmd="$cmd"
    fi

    echo "$exec_cmd"
}

# Recursively create panes from the YAML pane tree.
# Arguments: pane_spec_json, parent_pane_id, split_direction
# For the root call, parent_pane_id is the existing first pane, split_direction is "".
#
# Each pane spec is a JSON object that may contain:
#   cmd:  command to run in the pane
#   dir:  working directory
#   size: percentage for the split
#   h:    child pane spec to split horizontally (side by side)
#   v:    child pane spec to split vertically (top/bottom)
process_pane_tree() {
    local pane_spec="$1"
    local parent="$2"
    local split_dir="$3"

    local cmd dir size
    cmd=$(yq -r '.cmd // empty' <<< "$pane_spec")
    dir=$(yq -r '.dir // empty' <<< "$pane_spec")
    size=$(yq -r '.size // empty' <<< "$pane_spec")

    local exec_cmd
    exec_cmd=$(build_exec_cmd "$cmd" "$dir") || true
    local current_pane

    if [[ -n "$split_dir" ]]; then
        # This is a child pane — split from parent
        local split_args=("-t" "$parent")

        if [[ "$split_dir" == "h" ]]; then
            split_args+=("-h")
        fi
        # "v" is the default for tmux split-window, no flag needed

        if [[ -n "$size" ]]; then
            split_args+=("-p" "$size")
        fi

        current_pane=$(tmux split-window -P -F '#{pane_id}' "${split_args[@]}")
        log "Split $split_dir from $parent -> $current_pane"
    else
        # Root pane — parent is already the first pane of the window
        current_pane="$parent"
    fi

    if [[ -n "$exec_cmd" && -n "$current_pane" ]]; then
        log "Sending cmd to $current_pane: $exec_cmd"
        tmux send-keys -t "$current_pane" "$exec_cmd" C-m
    fi

    # Recurse into h/v child splits (direct keys on the pane node)
    local child_spec
    for dir_key in h v; do
        child_spec=$(yq -r ".$dir_key // empty" <<< "$pane_spec")
        if [[ -n "$child_spec" ]]; then
            process_pane_tree "$child_spec" "$current_pane" "$dir_key"
        fi
    done
}

# Reorder windows in a session to match config order.
# Only moves config windows; non-config windows are left in place (shifted as needed).
reorder_windows() {
    local session="$1"
    shift
    local -a config_windows=("$@")

    [[ ${#config_windows[@]} -eq 0 ]] && return

    # Check if windows are already in correct order — skip if nothing to do
    local needs_reorder=0
    for ((idx=0; idx<${#config_windows[@]}; idx++)); do
        local actual_name
        actual_name=$(get_window_name "$session" "$idx")
        if [[ "$actual_name" != "${config_windows[$idx]}" ]]; then
            needs_reorder=1
            break
        fi
    done
    [[ "$needs_reorder" -eq 0 ]] && return

    # Move config windows to temp indices (1000+) to free target slots
    local wi temp_base=1000
    for wn in "${config_windows[@]}"; do
        wi=$(get_window_index "$session" "$wn")
        if [[ -n "$wi" ]]; then
            tmux move-window -s "=$session:$wi" -t "=$session:$((temp_base++))" 2>/dev/null || true
        fi
    done

    # Move config windows back to their desired positions
    for ((idx=0; idx<${#config_windows[@]}; idx++)); do
        local target_name="${config_windows[$idx]}"
        [[ -z "$target_name" ]] && continue

        local current_idx
        current_idx=$(get_window_index "$session" "$target_name")

        if [[ -n "$current_idx" && "$current_idx" != "$idx" ]]; then
            # If target slot is occupied by a non-config window, swap it out first
            local occupant
            occupant=$(get_window_name "$session" "$idx")
            if [[ -n "$occupant" && "$occupant" != "$target_name" ]]; then
                tmux swap-window -s "=$session:$current_idx" -t "=$session:$idx" 2>/dev/null || true
            else
                tmux move-window -s "=$session:$current_idx" -t "=$session:$idx" 2>/dev/null || true
            fi
            log "Reorder: move $session:$current_idx ($target_name) -> $session:$idx"
        fi
    done
}

# --- PRUNE ACTION ---
if [[ "$ACTION" == "prune" ]]; then
    mapfile -t config_sessions < <(yq -r 'keys | .[]' "$CONFIG" | grep -v '^$')

    for session in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
        session_found=0
        for cs in "${config_sessions[@]}"; do
            [[ "$cs" == "$session" ]] && session_found=1 && break
        done

        if [[ "$session_found" -eq 0 ]]; then
            log "Pruning session: $session"
            tmux kill-session -t "=$session" 2>/dev/null || true
        else
            # Get config window names for this session
            mapfile -t config_windows < <(yq -r ".\"$session\"[] | keys | .[]" "$CONFIG" | grep -v '^$')
            window_count=$(tmux list-windows -t "=$session" 2>/dev/null | wc -l)

            for window in $(tmux list-windows -t "=$session" -F '#{window_name}' 2>/dev/null); do
                window_found=0
                for cw in "${config_windows[@]}"; do
                    [[ "$cw" == "$window" ]] && window_found=1 && break
                done

                if [[ "$window_found" -eq 0 && "$window_count" -gt 1 ]]; then
                    log "Pruning window: $session:$window"
                    tmux kill-window -t "=$session:=$window" 2>/dev/null || true
                    window_count=$((window_count - 1))
                fi
            done

            # Reorder remaining windows to match config
            reorder_windows "$session" "${config_windows[@]}"
        fi
    done
    exit 0
fi

# --- DEFAULT / ATTACH / LIST ACTION ---

mapfile -t yaml_sessions < <(yq -r 'keys | .[]' "$CONFIG" | grep -v '^$')

for session in "${yaml_sessions[@]}"; do
    [[ -z "$session" ]] && continue
    session_is_new=0

    if session_exists "$session"; then
        log "Session '$session' already exists"
    else
        log "Creating session: $session"
        tmux new-session -d -s "$session"
        session_is_new=1
    fi

    window_count=$(yq -r '.["'"$session"'"] | length' "$CONFIG")

    for ((window_idx=0; window_idx<window_count; window_idx++)); do
        window_name=$(yq -r '.["'"$session"'"]['"$window_idx"'] | keys | .[0]' "$CONFIG")
        [[ -z "$window_name" || "$window_name" == "null" ]] && continue

        # For a brand-new session, the first config window reuses the default window
        if [[ "$window_idx" -eq 0 && "$session_is_new" -eq 1 ]]; then
            first_window=$(tmux list-windows -t "=$session" -F '#{window_index}' | head -1)
            log "Renaming default window $first_window to: $window_name"
            tmux rename-window -t "=$session:$first_window" "$window_name"
            first_pane=$(tmux list-panes -t "=$session:$first_window" -F '#{pane_id}' | head -1)
        elif window_exists "$session" "$window_name"; then
            log "Window '$session:$window_name' already exists, skipping"
            continue
        else
            log "Creating window: $session:$window_name"
            first_pane=$(tmux new-window -P -F '#{pane_id}' -t "=$session:" -n "$window_name")
        fi

        # Set up panes for the new window
        root_pane_spec=$(yq -r '.["'"$session"'"]['"$window_idx"']["'"$window_name"'"].root' "$CONFIG")

        if [[ -n "$root_pane_spec" && "$root_pane_spec" != "null" && -n "$first_pane" ]]; then
            process_pane_tree "$root_pane_spec" "$first_pane" ""
        fi
    done
done

# --- POST-ACTION ---

first_session=$(yq -r 'keys | .[0]' "$CONFIG")

if [[ "$ACTION" == "attach" ]]; then
    if [[ -n "$TMUX" ]]; then
        tmux switch-client -t "=$first_session"
    else
        tmux attach-session -t "=$first_session"
    fi
elif [[ "$ACTION" == "list" ]]; then
    if [[ -z "$TMUX" ]]; then
        tmux attach-session
    fi
    tmux choose-window
fi
