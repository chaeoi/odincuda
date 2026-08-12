#!/bin/bash

set -u
set -o pipefail

PKG_DIR="$(cd "$(dirname "$0")/.."; pwd)"
WORKSPACE_ROOT="$(dirname "$(dirname "$PKG_DIR")")"
INSTALL_DIR="${ODIN_INSTALL_DIR:-${WORKSPACE_ROOT}/install}"
ROS_SETUP="${ODIN_ROS_SETUP:-/opt/ros/humble/setup.bash}"
RESULT_DIR="${ODIN_BENCHMARK_DIR:-${WORKSPACE_ROOT}/benchmark_$(date +%Y%m%d_%H%M%S)}"
SAMPLES="${ODIN_BENCHMARK_SAMPLES:-20}"
WARMUP_SECONDS="${ODIN_BENCHMARK_WARMUP:-10}"
ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-87}"

export ROS_DOMAIN_ID
export LC_ALL=C

ACTIVE_HOST_PID=""
ACTIVE_DEPTH_PID=""
TEGRASTATS_PID=""

cleanup_variant() {
    local pid
    for pid in "$ACTIVE_DEPTH_PID" "$ACTIVE_HOST_PID"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -INT "$pid" 2>/dev/null || true
        fi
    done

    for _ in $(seq 1 8); do
        local running=0
        for pid in "$ACTIVE_DEPTH_PID" "$ACTIVE_HOST_PID"; do
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                running=1
            fi
        done
        [[ "$running" -eq 0 ]] && break
        sleep 1
    done

    for pid in "$ACTIVE_DEPTH_PID" "$ACTIVE_HOST_PID"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    sleep 1
    for pid in "$ACTIVE_DEPTH_PID" "$ACTIVE_HOST_PID"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
        if [[ -n "$pid" ]]; then
            wait "$pid" 2>/dev/null || true
        fi
    done

    if [[ -n "$TEGRASTATS_PID" ]] && kill -0 "$TEGRASTATS_PID" 2>/dev/null; then
        kill -INT "$TEGRASTATS_PID" 2>/dev/null || true
        wait "$TEGRASTATS_PID" 2>/dev/null || true
    fi

    ACTIVE_HOST_PID=""
    ACTIVE_DEPTH_PID=""
    TEGRASTATS_PID=""
}

handle_signal() {
    trap - EXIT INT TERM
    cleanup_variant
    exit 130
}

trap cleanup_variant EXIT
trap handle_signal INT TERM

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

wait_for_log() {
    local log_file="$1"
    local pattern="$2"
    local pid="$3"
    local timeout_seconds="$4"

    for _ in $(seq 1 "$timeout_seconds"); do
        if grep -q "$pattern" "$log_file" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        sleep 1
    done
    return 1
}

wait_for_usb() {
    for _ in $(seq 1 30); do
        if lsusb | grep -q '2207:0019'; then
            return 0
        fi
        sleep 1
    done
    return 1
}

read_ticks() {
    awk '{print $14 + $15}' "/proc/$1/stat"
}

read_rss_kb() {
    awk '/^VmRSS:/ {print $2}' "/proc/$1/status"
}

sample_processes() {
    local csv_file="$1"
    local host_pid="$2"
    local depth_pid="$3"
    local clock_ticks
    local prev_host prev_depth prev_uptime
    local current_host current_depth current_uptime host_rss depth_rss

    clock_ticks="$(getconf CLK_TCK)"
    prev_host="$(read_ticks "$host_pid")"
    prev_depth="$(read_ticks "$depth_pid")"
    prev_uptime="$(awk '{print $1}' /proc/uptime)"
    echo 'sample,host_cpu_pct,host_rss_kb,depth_cpu_pct,depth_rss_kb,total_cpu_pct' > "$csv_file"

    for sample in $(seq 1 "$SAMPLES"); do
        sleep 1
        kill -0 "$host_pid" 2>/dev/null || return 1
        kill -0 "$depth_pid" 2>/dev/null || return 1

        current_host="$(read_ticks "$host_pid")"
        current_depth="$(read_ticks "$depth_pid")"
        current_uptime="$(awk '{print $1}' /proc/uptime)"
        host_rss="$(read_rss_kb "$host_pid")"
        depth_rss="$(read_rss_kb "$depth_pid")"

        awk -v sample="$sample" \
            -v ph="$prev_host" -v ch="$current_host" \
            -v pd="$prev_depth" -v cd="$current_depth" \
            -v pu="$prev_uptime" -v cu="$current_uptime" \
            -v hz="$clock_ticks" -v hr="$host_rss" -v dr="$depth_rss" \
            'BEGIN {
                elapsed = cu - pu;
                host = (ch - ph) * 100.0 / (hz * elapsed);
                depth = (cd - pd) * 100.0 / (hz * elapsed);
                printf "%d,%.2f,%d,%.2f,%d,%.2f\n", sample, host, hr, depth, dr, host + depth;
            }' >> "$csv_file"

        prev_host="$current_host"
        prev_depth="$current_depth"
        prev_uptime="$current_uptime"
    done
}

summarize_variant() {
    local variant="$1"
    local csv_file="$2"
    local tegra_file="$3"
    local summary_file="$4"
    local gpu_file="${tegra_file}.gpu"

    sed -n 's/.*GR3D_FREQ \([0-9][0-9]*\)%.*/\1/p' "$tegra_file" > "$gpu_file"

    {
        echo "variant=$variant"
        awk -F, 'NR > 1 {
            host_sum += $2; host_peak = ($2 > host_peak ? $2 : host_peak);
            depth_sum += $4; depth_peak = ($4 > depth_peak ? $4 : depth_peak);
            total_sum += $6; total_peak = ($6 > total_peak ? $6 : total_peak);
            host_rss += $3; depth_rss += $5; n++;
        } END {
            if (n == 0) exit 1;
            printf "samples=%d\n", n;
            printf "host_cpu_avg=%.2f\n", host_sum / n;
            printf "host_cpu_peak=%.2f\n", host_peak;
            printf "depth_cpu_avg=%.2f\n", depth_sum / n;
            printf "depth_cpu_peak=%.2f\n", depth_peak;
            printf "total_cpu_avg=%.2f\n", total_sum / n;
            printf "total_cpu_peak=%.2f\n", total_peak;
            printf "host_rss_avg_mib=%.2f\n", host_rss / n / 1024.0;
            printf "depth_rss_avg_mib=%.2f\n", depth_rss / n / 1024.0;
        }' "$csv_file"
        awk '{sum += $1; peak = ($1 > peak ? $1 : peak); n++} END {
            if (n == 0) {
                print "gpu_samples=0";
                print "gpu_avg=unavailable";
                print "gpu_peak=unavailable";
            } else {
                printf "gpu_samples=%d\n", n;
                printf "gpu_avg=%.2f\n", sum / n;
                printf "gpu_peak=%d\n", peak;
            }
        }' "$gpu_file"
    } > "$summary_file"

    cat "$summary_file"
}

run_variant() {
    local variant="$1"
    local host_executable depth_executable host_binary depth_binary
    local variant_dir host_log depth_log cpu_csv tegra_log summary_file

    case "$variant" in
        cpu)
            host_executable='host_sdk_sample'
            depth_executable='pcd2depth_ros2_node'
            ;;
        gpu)
            host_executable='host_sdk_sample_gpu'
            depth_executable='pcd2depth_ros2_node_gpu'
            ;;
        *)
            fail "unknown variant: $variant"
            ;;
    esac

    host_binary="${INSTALL_DIR}/odin_ros_driver/lib/odin_ros_driver/${host_executable}"
    depth_binary="${INSTALL_DIR}/odin_ros_driver/lib/odin_ros_driver/${depth_executable}"
    [[ -x "$host_binary" ]] || fail "executable not found: $host_binary"
    [[ -x "$depth_binary" ]] || fail "executable not found: $depth_binary"

    wait_for_usb || fail "Odin USB device 2207:0019 is not connected"
    variant_dir="${RESULT_DIR}/${variant}"
    mkdir -p "$variant_dir"
    host_log="${variant_dir}/host.log"
    depth_log="${variant_dir}/depth.log"
    cpu_csv="${variant_dir}/cpu.csv"
    tegra_log="${variant_dir}/tegrastats.log"
    summary_file="${variant_dir}/summary.txt"

    echo "Starting ${variant} variant"
    stdbuf -oL -eL "$depth_binary" > "$depth_log" 2>&1 &
    ACTIVE_DEPTH_PID=$!
    stdbuf -oL -eL "$host_binary" > "$host_log" 2>&1 &
    ACTIVE_HOST_PID=$!

    if ! wait_for_log "$host_log" 'Device ready and streams activated' "$ACTIVE_HOST_PID" 60; then
        tail -n 80 "$host_log" >&2 || true
        fail "${variant} host driver did not become ready"
    fi
    if ! wait_for_log "$depth_log" 'DepthImageRos2Node initialized successfully' "$ACTIVE_DEPTH_PID" 30; then
        tail -n 80 "$depth_log" >&2 || true
        fail "${variant} depth node did not become ready"
    fi

    timeout 20s ros2 topic echo --no-daemon --spin-time 3 \
        /odin1/image/undistorted sensor_msgs/msg/Image --once --field header \
        > "${variant_dir}/undistorted_sample.txt" 2>&1 || \
        fail "${variant} did not publish /odin1/image/undistorted"
    timeout 20s ros2 topic echo --no-daemon --spin-time 3 \
        /odin1/depth_img_competetion sensor_msgs/msg/Image --once --field header \
        > "${variant_dir}/depth_sample.txt" 2>&1 || \
        fail "${variant} did not publish /odin1/depth_img_competetion"

    echo "Warming up ${variant} for ${WARMUP_SECONDS} seconds"
    sleep "$WARMUP_SECONDS"

    timeout --signal=INT "$((SAMPLES + 5))s" tegrastats --interval 100 > "$tegra_log" 2>&1 &
    TEGRASTATS_PID=$!
    sample_processes "$cpu_csv" "$ACTIVE_HOST_PID" "$ACTIVE_DEPTH_PID" || \
        fail "${variant} process exited during sampling"
    if kill -0 "$TEGRASTATS_PID" 2>/dev/null; then
        kill -INT "$TEGRASTATS_PID" 2>/dev/null || true
    fi
    wait "$TEGRASTATS_PID" 2>/dev/null || true
    TEGRASTATS_PID=""

    if grep -Eqi 'CUDA .*fallback|CUDA .*unavailable' "$host_log" "$depth_log"; then
        fail "${variant} logged a CUDA fallback"
    fi

    summarize_variant "$variant" "$cpu_csv" "$tegra_log" "$summary_file"
    cleanup_variant
    sleep 8
}

[[ -f "$ROS_SETUP" ]] || fail "ROS setup not found: $ROS_SETUP"
[[ -f "${INSTALL_DIR}/setup.bash" ]] || fail "workspace setup not found: ${INSTALL_DIR}/setup.bash"
command -v tegrastats >/dev/null 2>&1 || fail "tegrastats is required on Jetson"
command -v lsusb >/dev/null 2>&1 || fail "lsusb is required"
[[ "$SAMPLES" =~ ^[1-9][0-9]*$ ]] || fail "ODIN_BENCHMARK_SAMPLES must be a positive integer"
[[ "$WARMUP_SECONDS" =~ ^[0-9]+$ ]] || fail "ODIN_BENCHMARK_WARMUP must be a non-negative integer"

# shellcheck disable=SC1090
source "$ROS_SETUP"
# shellcheck disable=SC1090
source "${INSTALL_DIR}/setup.bash"

wait_for_usb || fail "Odin USB device 2207:0019 is not connected"
if pgrep -af '/odin_ros_driver/(host_sdk_sample|pcd2depth)' >/dev/null 2>&1; then
    fail "another Odin driver process is already running"
fi

mkdir -p "$RESULT_DIR"
{
    echo "ros_distro=${ROS_DISTRO:-unknown}"
    echo "samples=$SAMPLES"
    echo "warmup_seconds=$WARMUP_SECONDS"
    echo "opencv=$(pkg-config --modversion opencv4 2>/dev/null || echo unknown)"
    nvcc --version 2>/dev/null | tail -n 1 || true
    nvpmodel -q 2>/dev/null || true
} > "${RESULT_DIR}/environment.txt"

echo "Running CUDA smoke test"
ros2 run odin_ros_driver odin_cuda_smoke_test > "${RESULT_DIR}/cuda_smoke.txt" 2>&1 || \
    fail "CUDA smoke test failed"
cat "${RESULT_DIR}/cuda_smoke.txt"

run_variant cpu
run_variant gpu

cpu_avg="$(awk -F= '$1 == "total_cpu_avg" {print $2}' "${RESULT_DIR}/cpu/summary.txt")"
gpu_avg="$(awk -F= '$1 == "total_cpu_avg" {print $2}' "${RESULT_DIR}/gpu/summary.txt")"
awk -v cpu="$cpu_avg" -v gpu="$gpu_avg" 'BEGIN {
    reduction = (cpu > 0) ? (cpu - gpu) * 100.0 / cpu : 0;
    printf "cpu_total_avg=%.2f%%\n", cpu;
    printf "cuda_total_avg=%.2f%%\n", gpu;
    printf "cpu_reduction=%.2f%%\n", reduction;
}' | tee "${RESULT_DIR}/comparison.txt"

echo "Benchmark results: $RESULT_DIR"
