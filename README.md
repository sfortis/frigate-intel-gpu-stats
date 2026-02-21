# Frigate Intel GPU Stats Fix (Alder Lake-N / Gen 12+)

A drop-in replacement for `intel_gpu_top` that provides **accurate GPU usage stats** in [Frigate NVR](https://frigate.video/) on Intel Alder Lake-N (N100/N200/N305) and other Gen 12+ processors.

> **Note**
> - This script measures **all GPU consumers** including VAAPI, QSV, and OpenVINO processes (embeddings, face recognition, etc.).
> - Supports both **i915** and **xe** kernel drivers.
> - The first reading after a container restart will show **0%** (the cache needs one cycle to initialize, stats appear after ~15 seconds).
> - Requires the container to run in **privileged mode** (or with access to `/proc/PID/fdinfo`).
> - This is a **read-only volume mount**, nothing is permanently modified. Remove the volume line from `docker-compose.yml` to revert to the original `intel_gpu_top`.

## The Problem

Frigate uses `intel_gpu_top` to display GPU utilization in the web UI. On Intel Alder Lake-N (Gen 12.2) and newer GPUs, `intel_gpu_top` v1.27 (bundled in Frigate and Debian 12) **reports 0%** for the Video and Render engines, even when VAAPI/QSV hardware transcoding is actively running.

This is a known limitation of `intel_gpu_top`'s performance counter reading on Gen 12+ architectures. The fixed-function media engines (hardware encode/decode) are not properly captured by the legacy perf counters.

**Before (broken):**
```
Frigate UI: Intel GPU: 0%
Frigate API: {"intel-vaapi": {"gpu": "", "mem": ""}}
```

**After (with this fix):**

![Frigate GPU Stats Working](screenshot.png)

```
Frigate API: {"intel-vaapi": {"gpu": "18.07%", "mem": "-%"}}
```

## How It Works

Instead of using broken perf counters, this script reads GPU engine usage directly from the **Linux DRM fdinfo interface** (`/proc/PID/fdinfo`), which provides accurate per-process GPU engine time.

The script:
1. Finds **all processes** using the Intel GPU via DRM fdinfo (not just ffmpeg)
2. Auto-detects the kernel driver (i915 or xe) and parses accordingly
3. Reads cumulative GPU engine time from the DRM fdinfo
4. Compares with a cached snapshot from the previous invocation (every ~15s)
5. Calculates the delta to get real-time utilization percentages
6. Reports per-engine values (Render and Video separately) so Frigate's built-in averaging produces a correctly scaled 0-100% result
7. Outputs JSON in the exact format Frigate expects from `intel_gpu_top`

Engines measured:
- **Render/3D** (`drm-engine-render` / `drm-cycles-rcs`): Used by OpenVINO inference, `scale_vaapi`/`scale_qsv` for resolution scaling
- **Video** (`drm-engine-video` / `drm-cycles-vcs`): Used by `h264_vaapi`/`h264_qsv` for H.264 hardware encode/decode

## Installation

### 1. Copy the script to your Frigate config directory

```bash
# Copy to your Frigate config directory
cp intel_gpu_top /path/to/frigate/config/intel_gpu_top
chmod +x /path/to/frigate/config/intel_gpu_top
```

### 2. Add a volume mount in `docker-compose.yml`

```yaml
services:
  frigate:
    volumes:
      # ... your existing volumes ...
      # Fix GPU stats for Alder Lake-N (replaces broken intel_gpu_top)
      - /path/to/frigate/config/intel_gpu_top:/usr/bin/intel_gpu_top:ro
```

### 3. Recreate the container

```bash
docker compose up -d
```

The first stats reading after restart will show 0% (cache is empty). After ~15 seconds, accurate stats will appear.

## Bonus: Detailed GPU Usage Script

The `gpu_usage.sh` script provides a detailed per-process breakdown of GPU usage. Copy it to your Frigate host and run it:

```bash
chmod +x gpu_usage.sh
./gpu_usage.sh 5   # 5-second sampling interval
```

Example output:
```
Process                   Render%   Video%   Total%
------------------------ -------- -------- --------
ffmpeg (1234)               3.40%    6.20%    9.60%
ffmpeg (1235)               3.30%    5.20%    8.50%
ffmpeg (1236)               3.80%    4.20%    8.00%
frigate.embeddi (720)       0.05%    0.00%    0.05%
------------------------ -------- -------- --------
TOTAL                      10.55%   15.60%   26.15%

Render = GPU compute (OpenVINO, scale_vaapi/qsv)
Video  = HW codec (h264_vaapi/qsv encode/decode)
Sampled over 5s interval
```

> **Note:** Frigate displays the average of Render and Video engine usage as its GPU percentage. The script reports each engine separately (Render = GPU compute, Video = HW codec), and Frigate's averaging naturally scales the result to 0-100%. Use `gpu_usage.sh` to see the per-engine breakdown.

## Compatibility

| Feature | Supported |
|---------|-----------|
| **Intel Gen 12+** (Alder Lake, Raptor Lake) | i915 driver |
| **Intel Xe2+** (Lunar Lake, Battlemage) | xe driver |
| **HW acceleration** | VAAPI and QSV |
| **OpenVINO / embeddings** | Captured via DRM fdinfo |
| **Frigate versions** | 0.14.x through 0.17.x |
| **Container mode** | Privileged (or `SYS_PTRACE` capability) |

### Driver-specific fdinfo format

| Driver | Render engine | Video engine | Unit |
|--------|--------------|--------------|------|
| **i915** | `drm-engine-render` | `drm-engine-video` | nanoseconds |
| **xe** | `drm-cycles-rcs` | `drm-cycles-vcs` | cycles |

The script auto-detects the driver and parses the correct format.

## How Frigate Polls GPU Stats

Frigate internally runs:
```bash
timeout 0.5s intel_gpu_top -J -o - -s 1000
```

Every **15 seconds** (`FREQUENCY_STATS_POINTS`), expecting:
- JSON output with `engines.Render/3D/0.busy` and `engines.Video/0.busy`
- Exit code **124** (killed by timeout)

Frigate calculates the GPU percentage as `(Render + Video) / 2`. Since Render and Video are independent GPU engines (each 0-100%), this averaging naturally scales the combined usage to a 0-100% range. Our script reports accurate per-engine values, letting Frigate's formula produce a correctly scaled result.

Our script completes in <100ms (well within the 0.5s timeout).

## Technical Details

### i915 driver
The Linux kernel exposes per-process GPU engine usage via DRM fdinfo:

```
$ cat /proc/<pid>/fdinfo/<drm_fd>
drm-driver:     i915
drm-engine-render:    62418463951 ns
drm-engine-video:     52567609040 ns
drm-engine-video-enhance: 0 ns
```

These are cumulative nanosecond counters. By taking two snapshots and dividing the delta by elapsed wall-clock time, we get accurate utilization percentages.

### xe driver
The xe driver uses a different format with GPU cycles:

```
$ cat /proc/<pid>/fdinfo/<drm_fd>
drm-driver:     xe
drm-cycles-rcs:       12345
drm-total-cycles-rcs: 67890
drm-cycles-vcs:       2345
drm-total-cycles-vcs: 67890
```

The script uses `drm-total-cycles` for normalization when available, falling back to wall-clock time.

### Process discovery
The script finds GPU-using processes by scanning `/proc/[0-9]*/fdinfo/*` for files containing `drm-driver:`. This captures all GPU consumers regardless of process type (ffmpeg, OpenVINO, Python, etc.).

## License

MIT
