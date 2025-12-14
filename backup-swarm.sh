#!/bin/sh
set -eu

# ----------------------
# Default variables
# ----------------------
: "${APP_NAME:=Swarm}"
: "${BACKUP_SRC:=/data}"
: "${RSYNC_EXCLUDES:=}"
: "${SCALE_LABEL:=com.example.autobackup.enable}"
: "${SCALE_VALUE:=true}"
: "${SNAPSHOT_DIR:?SNAPSHOT_DIR not set by wrapper}"
: "${BACKUP_DEST:?BACKUP_DEST not set}"

export APP_NAME

latest_link="${BACKUP_DEST}/latest"
SERVICES_STOPPED=false
GLOBAL_STOP_CONSTRAINT="node.labels.backup_pause==true"

# ----------------------
# Rsync snapshot helper
# ----------------------
rsync_snapshot() {
    src="$1"
    dest="$2"
    latest="$3"

    [ -d "$src" ] || { log_error "Rsync source not found: $src"; return 1; }
    mkdir -p "$dest"

    rsync_opts="-a --delete --numeric-ids"
    [ -n "$RSYNC_EXCLUDES" ] && rsync_opts="$rsync_opts $RSYNC_EXCLUDES"

    if [ -L "$latest" ] && [ -d "$latest" ]; then
        link_dest="$(readlink -f "$latest")"
        rsync_opts="$rsync_opts --link-dest=$link_dest"
    fi

    log "Rsync snapshot: $src -> $dest"

    if [ "${DRY_RUN:-false}" = "true" ]; then
        log "[DRY-RUN] rsync $rsync_opts $src/ $dest/"
        return 0
    fi

    rsync $rsync_opts "$src/" "$dest/"
    rc=$?

    case "$rc" in
        0) return 0 ;;
        24)
            log "WARNING: rsync completed with vanished files (code 24)"
            return 0 ;;
        *)
            log_error "Rsync snapshot failed (exit code $rc)"
            return 1 ;;
    esac
}

# ----------------------
# Discover services BEFORE scaling
# ----------------------
services=""
log "Discovering Swarm services with label $SCALE_LABEL=$SCALE_VALUE..."
for svc in $(docker service ls -q); do
    label_value=$(docker service inspect --format '{{ if .Spec.Labels }}{{ index .Spec.Labels "'"$SCALE_LABEL"'" }}{{ else }}{{ end }}' "$svc" 2>/dev/null || true)
    if [ "$label_value" = "$SCALE_VALUE" ]; then
        services="$services $svc"
    fi
done
services="$(echo "$services" | xargs)"

# ----------------------
# Capture service state
# ----------------------
capture_service_state() {
    [ -n "$services" ] || return
    service_state=""
    for svc in $services; do
        name="$(docker service inspect --format '{{.Spec.Name}}' "$svc")"
        if docker service inspect --format '{{if .Spec.Mode.Global}}true{{else}}false{{end}}' "$svc" | grep -q true; then
            mode="Global"
            replicas=1
        else
            mode="Replicated"
            replicas="$(docker service inspect --format '{{.Spec.Mode.Replicated.Replicas}}' "$svc")"
        fi
        service_state="$service_state$svc|$name|$mode|$replicas"$'\n'
    done
}

# ----------------------
# Wait for service tasks
# ----------------------
wait_for_service() {
    svc="$1"
    desired="$2"
    timeout=60
    interval=2
    elapsed=0

    while [ $elapsed -lt $timeout ]; do
        running=$(docker service ps --filter "desired-state=running" --format '{{.ID}}' "$svc" | wc -l)
        if [ "$running" -eq "$desired" ]; then
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    log "WARNING: service $svc did not reach desired running count $desired within $timeout seconds"
}

# ----------------------
# Rollback handler
# ----------------------
rollback_services() {
    [ "$SERVICES_STOPPED" = "true" ] || return
    [ -n "${service_state:-}" ] || return

    log_error "Backup failed — rolling back services"

    printf '%s\n' "$service_state" | while IFS="|" read -r svc svc_name mode replicas; do
        [ -z "$svc_name" ] && continue
        if [ "$mode" = "Global" ]; then
            docker service update --constraint-rm "$GLOBAL_STOP_CONSTRAINT" "$svc_name" >/dev/null 2>&1 || true
        else
            docker service scale "$svc_name=$replicas" >/dev/null 2>&1 || true
            wait_for_service "$svc" "$replicas"
        fi
    done
}

# ----------------------
# Validate backup source
# ----------------------
[ -d "$BACKUP_SRC" ] || { log_error "Backup source directory not found: $BACKUP_SRC"; exit 1; }

# ----------------------
# Pre-populate snapshot
# ----------------------
if [ -L "$latest_link" ] && [ -d "$(readlink -f "$latest_link")" ]; then
    prev="$(readlink -f "$latest_link")"
    log "Pre-populating snapshot from latest: $prev -> $SNAPSHOT_DIR"
    if [ "${DRY_RUN:-false}" = "true" ]; then
        log "[DRY-RUN] cp -al $prev/. $SNAPSHOT_DIR/"
    else
        cp -al "$prev/." "$SNAPSHOT_DIR/" || { log_error "Failed to pre-populate snapshot"; exit 1; }
    fi
fi

# ----------------------
# Scale down services
# ----------------------
if [ -n "$services" ]; then
    log "Scaling down Swarm services..."
    SERVICES_STOPPED=true
    trap rollback_services ERR INT TERM

    capture_service_state

    for svc in $services; do
        line=$(echo "$service_state" | grep "^$svc|")
        svc_name=$(echo "$line" | cut -d'|' -f2)
        mode=$(echo "$line" | cut -d'|' -f3)
        replicas=$(echo "$line" | cut -d'|' -f4)

        if [ "$mode" = "Global" ]; then
            log "Scaling DOWN Global service: $svc_name (adding constraint $GLOBAL_STOP_CONSTRAINT)"
            if [ "${DRY_RUN:-false}" = "true" ]; then
                log "[DRY-RUN] docker service update --constraint-add $GLOBAL_STOP_CONSTRAINT $svc_name"
            else
                docker service update --constraint-add "$GLOBAL_STOP_CONSTRAINT" "$svc_name" >/dev/null
            fi
        else
            log "Scaling DOWN Replicated service: $svc_name from $replicas to 0"
            if [ "${DRY_RUN:-false}" = "true" ]; then
                log "[DRY-RUN] docker service scale $svc_name=0"
            else
                docker service scale "$svc_name=0" >/dev/null
            fi
            wait_for_service "$svc" 0
        fi
    done
else
    log "No services matched for scaling."
fi

# ----------------------
# Snapshot
# ----------------------
rsync_snapshot "$BACKUP_SRC" "$SNAPSHOT_DIR" "$latest_link" || exit 1

# ----------------------
# Restore services
# ----------------------
trap - ERR INT TERM
SERVICES_STOPPED=false

if [ -n "$services" ]; then
    log "Restoring Swarm services..."
    printf '%s\n' "$service_state" | while IFS="|" read -r svc svc_name mode replicas; do
        [ -z "$svc_name" ] && continue
        if [ "$mode" = "Global" ]; then
            log "Scaling UP Global service: $svc_name (removing constraint $GLOBAL_STOP_CONSTRAINT)"
            if [ "${DRY_RUN:-false}" = "true" ]; then
                log "[DRY-RUN] docker service update --constraint-rm $GLOBAL_STOP_CONSTRAINT $svc_name"
            else
                docker service update --constraint-rm "$GLOBAL_STOP_CONSTRAINT" "$svc_name" >/dev/null
            fi
        else
            log "Scaling UP Replicated service: $svc_name from 0 to $replicas"
            if [ "${DRY_RUN:-false}" = "true" ]; then
                log "[DRY-RUN] docker service scale $svc_name=$replicas"
            else
                docker service scale "$svc_name=$replicas" >/dev/null
            fi
            wait_for_service "$svc" "$replicas"
        fi
    done
fi

# ----------------------
# Debug mode
# ----------------------
if [ "${DEBUG:-false}" = "true" ]; then
    log "DEBUG mode enabled — container will remain running."
    tail -f /dev/null
fi
