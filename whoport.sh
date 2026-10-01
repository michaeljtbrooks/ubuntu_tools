#!/usr/bin/env bash
#
# whoport.sh - find out what is listening on a TCP port
#
# Usage: whoport.sh [PORT]     (default 8000)
#

set -uo pipefail

PORT="${1:-8000}"

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    echo "Usage: $(basename "$0") [PORT]  (1-65535, default 8000)" >&2
    exit 2
fi

# Use sudo unless already root; process ownership is hidden otherwise
if (( EUID != 0 )); then
    SUDO="sudo"
    sudo -v || exit 1
else
    SUDO=""
fi

if ! command -v ss >/dev/null 2>&1; then
    echo "ss not found; install iproute2 (sudo apt install iproute2)" >&2
    exit 1
fi

hr() {
    printf '\n\033[1m== %s ==\033[0m\n' "$1"
}

hr "ss: listeners on TCP ${PORT}"
SS_OUT="$($SUDO ss -ltnpH "sport = :${PORT}")"
if [[ -z "$SS_OUT" ]]; then
    echo "Nothing listening on TCP ${PORT}."
    exit 0
fi
$SUDO ss -ltnp "sport = :${PORT}"

if command -v lsof >/dev/null 2>&1; then
    hr "lsof"
    $SUDO lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN
fi

if command -v fuser >/dev/null 2>&1; then
    hr "fuser"
    $SUDO fuser -v "${PORT}/tcp" 2>&1
fi

mapfile -t PIDS < <(grep -oP 'pid=\K[0-9]+' <<< "$SS_OUT" | sort -un)

for PID in "${PIDS[@]}"; do
    hr "PID ${PID}"
    ps -fp "$PID"

    # Full command line (ps truncates)
    echo
    echo "Cmdline: $(tr '\0' ' ' < "/proc/${PID}/cmdline" 2>/dev/null)"
    echo "CWD:     $($SUDO readlink "/proc/${PID}/cwd" 2>/dev/null)"

    # systemd unit, if any
    UNIT="$(ps -o unit= -p "$PID" 2>/dev/null | xargs)"
    if [[ -n "$UNIT" && "$UNIT" != "-" ]]; then
        echo "systemd: ${UNIT}"
    fi

    # Walk the parent chain
    echo
    echo "Ancestry:"
    CUR="$PID"
    IN_CONTAINER=0
    while [[ -n "$CUR" && "$CUR" != "0" ]]; do
        COMM="$(ps -o comm= -p "$CUR" 2>/dev/null)"
        [[ -z "$COMM" ]] && break
        printf '  %-8s %s\n' "$CUR" "$COMM"
        [[ "$COMM" == containerd-shim* ]] && IN_CONTAINER=1
        [[ "$CUR" == "1" ]] && break
        CUR="$(ps -o ppid= -p "$CUR" 2>/dev/null | xargs)"
    done

    COMM="$(ps -o comm= -p "$PID" 2>/dev/null)"

    if [[ "$COMM" == "docker-proxy" ]]; then
        echo
        echo ">> docker-proxy: a container is publishing port ${PORT}:"
        $SUDO docker ps --filter "publish=${PORT}" \
            --format '   {{.ID}}  {{.Names}}  {{.Image}}  {{.Ports}}'
    elif (( IN_CONTAINER )); then
        echo
        echo ">> Runs inside a container (host networking, probably)."
        CID="$(grep -oE '[0-9a-f]{64}' "/proc/${PID}/cgroup" 2>/dev/null | head -n1)"
        if [[ -n "$CID" ]] && command -v docker >/dev/null 2>&1; then
            $SUDO docker ps -a --no-trunc --filter "id=${CID}" \
                --format '   {{.ID}}  {{.Names}}  {{.Image}}  status={{.Status}}'
            echo "   Restart policy: $($SUDO docker inspect -f \
                '{{.HostConfig.RestartPolicy.Name}}' "$CID" 2>/dev/null)"
        fi
    fi
done

echo
echo "Kill with: kill ${PIDS[*]}   (or: sudo fuser -k ${PORT}/tcp)"
