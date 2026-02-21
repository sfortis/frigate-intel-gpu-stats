#!/bin/bash
# GPU usage monitor for Frigate Intel HW acceleration
# Reads drm-engine fdinfo from ALL GPU-using processes (VAAPI, QSV, OpenVINO)
# Usage: gpu_usage.sh [interval_seconds] (default: 5)

INTERVAL=${1:-5}

# Collect snapshot inside container in a single docker exec call
collect_snapshot() {
    docker exec frigate bash -c '
        for pid in $(grep -rls "drm-driver:" /proc/[0-9]*/fdinfo/* 2>/dev/null | cut -d/ -f3 | sort -u); do
            FD=$(grep -l "drm-driver:" /proc/$pid/fdinfo/* 2>/dev/null | head -1)
            [ -z "$FD" ] && continue
            CMD=$(cat /proc/$pid/comm 2>/dev/null)
            ARGS=$(cat /proc/$pid/cmdline 2>/dev/null | tr "\0" " ")
            R=$(awk "/drm-engine-render:/ {printf \"%.0f\", \$2}" "$FD" 2>/dev/null)
            V=$(awk "/drm-engine-video:/ {printf \"%.0f\", \$2}" "$FD" 2>/dev/null)
            echo "$pid|${CMD}|${R:-0}|${V:-0}|${ARGS}"
        done
    '
}

# Take snapshot 1
declare -A S1_R S1_V PID_NAMES
while IFS='|' read -r pid cmd r v args; do
    [ -z "$pid" ] && continue
    S1_R[$pid]=$r
    S1_V[$pid]=$v
    PID_NAMES[$pid]=$cmd
done < <(collect_snapshot)

if [ ${#S1_R[@]} -eq 0 ]; then
    echo "No GPU-using processes found."
    exit 1
fi

sleep $INTERVAL

# Take snapshot 2
declare -A S2_R S2_V
while IFS='|' read -r pid cmd r v args; do
    [ -z "$pid" ] && continue
    S2_R[$pid]=$r
    S2_V[$pid]=$v
done < <(collect_snapshot)

# Calculate and display
INTERVAL_NS=$((INTERVAL * 1000000000))
TOTAL_RENDER=0
TOTAL_VIDEO=0

printf "\n%-24s %8s %8s %8s\n" "Process" "Render%" "Video%" "Total%"
printf "%-24s %8s %8s %8s\n" "------------------------" "--------" "--------" "--------"

for pid in "${!S1_R[@]}"; do
    [ -z "${S2_R[$pid]}" ] && continue
    name=${PID_NAMES[$pid]}
    dr=$(( ${S2_R[$pid]:-0} - ${S1_R[$pid]:-0} ))
    dv=$(( ${S2_V[$pid]:-0} - ${S1_V[$pid]:-0} ))
    [ "$dr" -lt 0 ] && dr=0
    [ "$dv" -lt 0 ] && dv=0
    TOTAL_RENDER=$((TOTAL_RENDER + dr))
    TOTAL_VIDEO=$((TOTAL_VIDEO + dv))
    rp=$(awk "BEGIN {printf \"%.2f\", $dr / $INTERVAL_NS * 100}")
    vp=$(awk "BEGIN {printf \"%.2f\", $dv / $INTERVAL_NS * 100}")
    tp=$(awk "BEGIN {printf \"%.2f\", ($dr + $dv) / $INTERVAL_NS * 100}")
    if [ "$rp" != "0.00" ] || [ "$vp" != "0.00" ]; then
        printf "%-24s %7s%% %7s%% %7s%%\n" "$name ($pid)" "$rp" "$vp" "$tp"
    fi
done

rp=$(awk "BEGIN {printf \"%.2f\", $TOTAL_RENDER / $INTERVAL_NS * 100}")
vp=$(awk "BEGIN {printf \"%.2f\", $TOTAL_VIDEO / $INTERVAL_NS * 100}")
tp=$(awk "BEGIN {printf \"%.2f\", ($TOTAL_RENDER + $TOTAL_VIDEO) / $INTERVAL_NS * 100}")
printf "%-24s %8s %8s %8s\n" "------------------------" "--------" "--------" "--------"
printf "%-24s %7s%% %7s%% %7s%%\n" "TOTAL" "$rp" "$vp" "$tp"

echo ""
echo "Render = GPU compute (OpenVINO, scale_vaapi/qsv)"
echo "Video  = HW codec (h264_vaapi/qsv encode/decode)"
echo "Sampled over ${INTERVAL}s interval"
