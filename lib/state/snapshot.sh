#!/usr/bin/env bash
# shellcheck shell=bash
# modes.cfg snapshot/backup and the saved-mode write used before a switch.

set -Eeuo pipefail

backup_modes_file() {
    rm -f -- "$MODES_BACKUP"
    if [[ -f "$MODES_FILE" ]]; then
        cp --reflink=auto -- "$MODES_FILE" "$MODES_BACKUP"
        MODES_EXISTED=1
    else
        : >"$MODES_BACKUP"
        MODES_EXISTED=0
    fi
    BACKUP_TAKEN=1
    log "Backed up modes.cfg to $MODES_BACKUP (existed=$MODES_EXISTED)"
}

restore_modes_file() {
    [[ -n "$MODES_BACKUP" ]] || return 0
    if (( MODES_EXISTED )); then
        mkdir -p "$(dirname -- "$MODES_FILE")"
        local tmp
        tmp=$(mktemp --tmpdir="$(dirname -- "$MODES_FILE")" '.modes.cfg.restore.XXXXXX')
        cp --reflink=auto -- "$MODES_BACKUP" "$tmp"
        mv -f -- "$tmp" "$MODES_FILE"
        # Postcondition: the file must be the backup, byte for byte. A partial
        # or refused write would leave Gamescope with a modes.cfg it never had,
        # which is worse than the streamed mode being still selected.
        if ! cmp -s -- "$MODES_BACKUP" "$MODES_FILE"; then
            log "ERROR: modes.cfg restore did not reproduce the backup"
            log_event MODES_CFG_VERIFY_FAILED
            return 1
        fi
    else
        rm -f -- "$MODES_FILE"
        if [[ -e "$MODES_FILE" ]]; then
            log "ERROR: modes.cfg was absent at session start but still exists after restore"
            log_event MODES_CFG_VERIFY_FAILED
            return 1
        fi
    fi
    log "Restored modes.cfg"
}

write_saved_mode_for_description() {
    local description=$1
    local width=$2
    local height=$3
    local refresh=$4
    local tmp dir

    dir=$(dirname -- "$MODES_FILE")
    mkdir -p "$dir"
    tmp=$(mktemp --tmpdir="$dir" '.modes.cfg.stream.XXXXXX')

    if [[ -f "$MODES_FILE" ]]; then
        awk -v d="$description" -v w="$width" -v h="$height" -v r="$refresh" '
            BEGIN { replaced=0 }
            {
                line=$0
                split(line, a, ":")
                if (index(line, ":") > 0 && a[1] == d) {
                    if (!replaced) {
                        printf "%s:%dx%d@%d\n", d, w, h, r
                        replaced=1
                    }
                    next
                }
                print line
            }
            END {
                if (!replaced)
                    printf "%s:%dx%d@%d\n", d, w, h, r
            }
        ' "$MODES_FILE" >"$tmp"
    else
        printf '%s:%dx%d@%d\n' "$description" "$width" "$height" "$refresh" >"$tmp"
    fi

    mv -f -- "$tmp" "$MODES_FILE"
    log "Configured saved mode: ${description}:${width}x${height}@${refresh}"
}
