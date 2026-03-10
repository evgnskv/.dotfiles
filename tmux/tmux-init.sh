#!/usr/bin/env bash

set -euo pipefail

TAB=$'\t'

CONFIG="./tmux-session.yaml"
ACTION=""
VERBOSE=0

declare -a CONFIG_SESSIONS=()
declare -a LIVE_SESSIONS=()
declare -a CONFIG_WINDOWS=()
declare -a LIVE_WINDOWS=()
declare -A SESSION_WINDOW_COUNTS=()
declare -A WINDOW_ROOT_SPECS=()
declare -A SESSION_WINDOWS_JOINED=()
declare -A WINDOW_INDEX_BY_NAME=()
declare -A WINDOW_NAME_BY_INDEX=()

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

if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed"
    exit 1
fi

session_exists() {
    tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -qxF "$1"
}

window_exists() {
    tmux list-windows -t "=$1" -F '#{window_name}' 2>/dev/null | grep -qxF "$2"
}

get_window_index() {
    local key="$1$TAB$2"
    printf '%s\n' "${WINDOW_INDEX_BY_NAME[$key]-}"
}

get_window_name() {
    local key="$1$TAB$2"
    printf '%s\n' "${WINDOW_NAME_BY_INDEX[$key]-}"
}

refresh_window_maps() {
    local session="$1" i n key

    while IFS=: read -r i n; do
        key="$session$TAB$n"
        WINDOW_INDEX_BY_NAME["$key"]="$i"
        key="$session$TAB$i"
        WINDOW_NAME_BY_INDEX["$key"]="$n"
    done < <(tmux list-windows -t "=$session" -F '#{window_index}:#{window_name}' 2>/dev/null)
}

in_array() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

read_config_sessions() {
    mapfile -t CONFIG_SESSIONS < <(yq -r 'keys[]' "$CONFIG" 2>/dev/null | grep -v '^$')
}

read_config_windows() {
    local session="$1"
    IFS='|' read -r -a CONFIG_WINDOWS <<< "${SESSION_WINDOWS_JOINED[$session]-}"
}

read_live_sessions() {
    mapfile -t LIVE_SESSIONS < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
}

read_live_windows() {
    local session="$1"
    mapfile -t LIVE_WINDOWS < <(tmux list-windows -t "=$session" -F '#{window_name}' 2>/dev/null)
}

window_total() {
    tmux list-windows -t "=$1" -F '#{window_index}' 2>/dev/null | wc -l
}

load_config() {
    local config_json session window_count window_idx window_name root_spec

    config_json=$(yq '.' "$CONFIG")
    mapfile -t CONFIG_SESSIONS < <(jq -r 'keys_unsorted[]' <<< "$config_json" | grep -v '^$')

    for session in "${CONFIG_SESSIONS[@]}"; do
        window_count=$(jq -r --arg session "$session" '.[$session] | length' <<< "$config_json")
        SESSION_WINDOW_COUNTS["$session"]="$window_count"
        CONFIG_WINDOWS=()

        for ((window_idx=0; window_idx<window_count; window_idx++)); do
            window_name=$(jq -r --arg session "$session" --argjson index "$window_idx" '.[$session][$index] | keys_unsorted[0] // empty' <<< "$config_json")
            [[ -z "$window_name" || "$window_name" == "null" ]] && continue
            CONFIG_WINDOWS+=("$window_name")
            root_spec=$(jq -c --arg session "$session" --argjson index "$window_idx" --arg window "$window_name" '.[$session][$index][$window].root // null' <<< "$config_json")
            WINDOW_ROOT_SPECS["$session$TAB$window_idx"]="$root_spec"
        done

        SESSION_WINDOWS_JOINED["$session"]=$(IFS='|'; printf '%s' "${CONFIG_WINDOWS[*]-}")
    done
}

expand_dir() {
    local dir="$1"
    local expanded="${dir/#\~/$HOME}"
    if [[ ! -d "$expanded" ]]; then
        log "Warning: directory '$dir' does not exist"
        return 1
    fi
    echo "$expanded"
}

DEFERRED_CMDS=()
LAST_SPLIT_PANE=""

wait_for_pane() {
    local pane="$1" cx
    for _ in {1..12}; do
        cx=$(tmux display-message -p -t "$pane" '#{cursor_x}' 2>/dev/null) || return 0
        [[ "$cx" -gt 0 ]] && return 0
        sleep 0.01
    done
    log "Warning: timed out waiting for pane $pane to be ready"
}

flush_deferred_cmds() {
    [[ ${#DEFERRED_CMDS[@]} -eq 0 ]] && return

    if [[ -n "$LAST_SPLIT_PANE" ]]; then
        wait_for_pane "$LAST_SPLIT_PANE"
    fi

    local pane_id cmd
    for entry in "${DEFERRED_CMDS[@]}"; do
        pane_id="${entry%%$TAB*}"
        cmd="${entry#*$TAB}"
        log "Sending cmd to $pane_id: $cmd"
        tmux send-keys -t "$pane_id" "$cmd" C-m
    done
    DEFERRED_CMDS=()
    LAST_SPLIT_PANE=""
}

process_pane_tree() {
    local pane_spec="$1"
    local parent="$2"
    local split_dir="$3"

    local cmd dir size split_count
    cmd=$(jq -r '.cmd // empty' <<< "$pane_spec")
    dir=$(jq -r '.dir // empty' <<< "$pane_spec")
    size=$(jq -r '.size // empty' <<< "$pane_spec")
    split_count=$(jq -r '.split | length // 0' <<< "$pane_spec" 2>/dev/null || printf '0')

    local current_pane expanded_dir

    if [[ -n "$split_dir" ]]; then
        local split_args=("-t" "$parent")

        if [[ "$split_dir" == "h" ]]; then
            split_args+=("-h")
        fi

        if [[ -n "$size" ]]; then
            split_args+=("-p" "$size")
        fi

        if [[ -n "$dir" ]]; then
            expanded_dir=$(expand_dir "$dir") && split_args+=("-c" "$expanded_dir")
        fi

        current_pane=$(tmux split-window -P -F '#{pane_id}' "${split_args[@]}")
        LAST_SPLIT_PANE="$current_pane"
        log "Split $split_dir from $parent -> $current_pane"
    else
        current_pane="$parent"
        if [[ -n "$dir" ]]; then
            expanded_dir=$(expand_dir "$dir") && DEFERRED_CMDS+=("${current_pane}${TAB}cd \"$expanded_dir\" && clear")
        fi
    fi

    if [[ -n "$cmd" && -n "$current_pane" ]]; then
        DEFERRED_CMDS+=("${current_pane}${TAB}${cmd}")
    fi

    local split_idx child_dir child_spec
    for ((split_idx=0; split_idx<split_count; split_idx++)); do
        child_dir=$(jq -r ".split[$split_idx] | keys[0] // empty" <<< "$pane_spec")
        [[ "$child_dir" != "h" && "$child_dir" != "v" ]] && continue
        child_spec=$(jq -c ".split[$split_idx].$child_dir" <<< "$pane_spec")
        [[ -z "$child_spec" || "$child_spec" == "null" ]] && continue
        process_pane_tree "$child_spec" "$current_pane" "$child_dir"
    done
}

reorder_windows() {
    local session="$1"
    shift
    local -a config_windows=("$@")

    [[ ${#config_windows[@]} -eq 0 ]] && return
    refresh_window_maps "$session"

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

    local wi temp_base=1000
    for wn in "${config_windows[@]}"; do
        wi=$(get_window_index "$session" "$wn")
        if [[ -n "$wi" ]]; then
            tmux move-window -s "=$session:$wi" -t "=$session:$((temp_base++))" 2>/dev/null || true
        fi
    done

    refresh_window_maps "$session"

    for ((idx=0; idx<${#config_windows[@]}; idx++)); do
        local target_name="${config_windows[$idx]}"
        [[ -z "$target_name" ]] && continue

        local current_idx
        current_idx=$(get_window_index "$session" "$target_name")

        if [[ -n "$current_idx" && "$current_idx" != "$idx" ]]; then
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

    refresh_window_maps "$session"
}

if [[ "$ACTION" == "prune" ]]; then
    load_config
    read_live_sessions

    for session in "${LIVE_SESSIONS[@]}"; do
        if ! in_array "$session" "${CONFIG_SESSIONS[@]}"; then
            log "Pruning session: $session"
            tmux kill-session -t "=$session" 2>/dev/null || true
        else
            read_config_windows "$session"
            window_count=$(window_total "$session")
            read_live_windows "$session"

            for window in "${LIVE_WINDOWS[@]}"; do
                if ! in_array "$window" "${CONFIG_WINDOWS[@]}" && [[ "$window_count" -gt 1 ]]; then
                    log "Pruning window: $session:$window"
                    tmux kill-window -t "=$session:=$window" 2>/dev/null || true
                    window_count=$((window_count - 1))
                fi
            done

            reorder_windows "$session" "${CONFIG_WINDOWS[@]}"
        fi
    done
    exit 0
fi

load_config

for session in "${CONFIG_SESSIONS[@]}"; do
    [[ -z "$session" ]] && continue
    session_is_new=0

    if session_exists "$session"; then
        log "Session '$session' already exists"
    else
        log "Creating session: $session"
        tmux new-session -d -s "$session"
        session_is_new=1
    fi

    window_count="${SESSION_WINDOW_COUNTS[$session]}"
    read_config_windows "$session"

    for ((window_idx=0; window_idx<window_count; window_idx++)); do
        window_name="${CONFIG_WINDOWS[$window_idx]-}"
        [[ -z "$window_name" || "$window_name" == "null" ]] && continue

        if [[ "$window_idx" -eq 0 && "$session_is_new" -eq 1 ]]; then
            first_window=$(tmux list-windows -t "=$session" -F '#{window_index}' | sed -n '1p')
            log "Renaming default window $first_window to: $window_name"
            tmux rename-window -t "=$session:$first_window" "$window_name"
            first_pane=$(tmux list-panes -t "=$session:$first_window" -F '#{pane_id}' | sed -n '1p')
        elif window_exists "$session" "$window_name"; then
            log "Window '$session:$window_name' already exists, skipping"
            continue
        else
            log "Creating window: $session:$window_name"
            first_pane=$(tmux new-window -P -F '#{pane_id}' -t "=$session:" -n "$window_name")
        fi

        root_pane_spec="${WINDOW_ROOT_SPECS["$session$TAB$window_idx"]-}"

        if [[ -n "$root_pane_spec" && "$root_pane_spec" != "null" && -n "$first_pane" ]]; then
            DEFERRED_CMDS=()
            process_pane_tree "$root_pane_spec" "$first_pane" ""
            flush_deferred_cmds
        fi
    done
done

first_session="${CONFIG_SESSIONS[0]-}"

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
