#!/bin/bash
# GPU usage monitor for Frigate Intel HW transcoding (VAAPI and QSV)
# Reads drm-engine fdinfo from ffmpeg processes (accurate for Alder Lake-N)
# Usage: gpu_usage.sh [interval_seconds] (default: 5)

INTERVAL=${1:-5}

get_drm_fd() {
    local pid=$1
    docker exec frigate grep -l 'drm-driver:' /proc/$pid/fdinfo/* 2>/dev/null | head -1
}

get_engine_ns() {
    local pid=$1 engine=$2
    local fdinfo=$(get_drm_fd $pid)
    [ -z "$fdinfo" ] && echo 0 && return
    docker exec frigate awk "/drm-engine-${engine}:/ {print \$2}" "$fdinfo" 2>/dev/null
}

# Find ffmpeg PIDs using Intel HW acceleration (VAAPI or QSV)
PIDS=$(docker exec frigate ps aux | grep -E 'ffmpeg.*(vaapi|qsv)' | grep -v grep | awk '{print $2}')

if [ -z "$PIDS" ]; then
    echo "No VAAPI/QSV ffmpeg processes found."
    exit 1
fi

# Map PIDs to camera names
declare -A PID_NAMES
for pid in $PIDS; do
    cmd=$(docker exec frigate ps -p $pid -o args= 2>/dev/null)
    if echo "$cmd" | grep -q '184:554'; then name="dahua_front"
    elif echo "$cmd" | grep -q '198:554'; then name="tapo_backyard"
    elif echo "$cmd" | grep -q '1.25'; then name="doorbell"
    elif echo "$cmd" | grep -q '188:554'; then name="livingroom"
    elif echo "$cmd" | grep -q '245:554'; then name="mancave"
    else name="unknown"; fi
    PID_NAMES[$pid]=$name
done

# Snapshot 1
declare -A S1_RENDER S1_VIDEO
for pid in $PIDS; do
    S1_RENDER[$pid]=$(get_engine_ns $pid render)
    S1_VIDEO[$pid]=$(get_engine_ns $pid video)
done

sleep $INTERVAL

# Snapshot 2
declare -A S2_RENDER S2_VIDEO
for pid in $PIDS; do
    S2_RENDER[$pid]=$(get_engine_ns $pid render)
    S2_VIDEO[$pid]=$(get_engine_ns $pid video)
done

# Calculate and display
INTERVAL_NS=$((INTERVAL * 1000000000))
TOTAL_RENDER=0
TOTAL_VIDEO=0

printf "\n%-16s %8s %8s %8s\n" "Camera" "Render%" "Video%" "Total%"
printf "%-16s %8s %8s %8s\n" "----------------" "--------" "--------" "--------"

for pid in $PIDS; do
    name=${PID_NAMES[$pid]}
    dr=$(( ${S2_RENDER[$pid]} - ${S1_RENDER[$pid]} ))
    dv=$(( ${S2_VIDEO[$pid]} - ${S1_VIDEO[$pid]} ))
    TOTAL_RENDER=$((TOTAL_RENDER + dr))
    TOTAL_VIDEO=$((TOTAL_VIDEO + dv))
    rp=$(awk "BEGIN {printf \"%.1f\", $dr / $INTERVAL_NS * 100}")
    vp=$(awk "BEGIN {printf \"%.1f\", $dv / $INTERVAL_NS * 100}")
    tp=$(awk "BEGIN {printf \"%.1f\", ($dr + $dv) / $INTERVAL_NS * 100}")
    printf "%-16s %7s%% %7s%% %7s%%\n" "$name" "$rp" "$vp" "$tp"
done

rp=$(awk "BEGIN {printf \"%.1f\", $TOTAL_RENDER / $INTERVAL_NS * 100}")
vp=$(awk "BEGIN {printf \"%.1f\", $TOTAL_VIDEO / $INTERVAL_NS * 100}")
tp=$(awk "BEGIN {printf \"%.1f\", ($TOTAL_RENDER + $TOTAL_VIDEO) / $INTERVAL_NS * 100}")
printf "%-16s %8s %8s %8s\n" "----------------" "--------" "--------" "--------"
printf "%-16s %7s%% %7s%% %7s%%\n" "TOTAL" "$rp" "$vp" "$tp"

# Memory
FIRST_PID=$(echo $PIDS | awk '{print $1}')
DRM_FD=$(get_drm_fd $FIRST_PID)
if [ -n "$DRM_FD" ]; then
    MEM=$(docker exec frigate awk '/drm-total-system0/ {print $2}' "$DRM_FD" 2>/dev/null)
    if [ -n "$MEM" ]; then
        MEM_MB=$((MEM / 1024))
        printf "\nGPU memory (per process): %d MB\n" "$MEM_MB"
    fi
fi

echo ""
echo "Render = scale_vaapi/qsv (downscale), Video = h264_vaapi/qsv (encode)"
echo "Sampled over ${INTERVAL}s interval"
