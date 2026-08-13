#!/usr/bin/env bash

# One-command provisioner for Odin CUDA driver on JetPack 5 / Ubuntu 20.04 / ROS Noetic.
set -Eeuo pipefail
umask 022

REPO_OWNER="chaeoi"
REPO_NAME="odincuda"
ODIN_BRANCH="${ODIN_BRANCH:-main}"
GITWARP_ROOT="https://gitwarp.canghai.org"
TARGET_USER="${TARGET_USER:-${SUDO_USER:-ubuntu}}"
ODIN_BUILD_JOBS="${ODIN_BUILD_JOBS:-2}"

if [[ $EUID -ne 0 ]]; then
    echo "错误：请使用 README 中的 curl ... | sudo bash 命令执行。" >&2
    exit 1
fi

if ! id "$TARGET_USER" >/dev/null 2>&1 || [[ "$TARGET_USER" == "root" ]]; then
    echo "错误：TARGET_USER 必须是已存在的普通用户，当前值为 $TARGET_USER。" >&2
    exit 1
fi

if [[ ! "$ODIN_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "错误：ODIN_BUILD_JOBS 必须是正整数。" >&2
    exit 1
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
ODIN_WORKSPACE="${ODIN_WORKSPACE:-${TARGET_HOME}/odincuda}"
PACKAGE_DIR="${ODIN_WORKSPACE}/src/odin_ros_driver"
BACKUP_DIR="${TARGET_HOME}/odincuda-backups"
ARCHIVE_URL="${GITWARP_ROOT}/codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${ODIN_BRANCH}"

if [[ "$ODIN_WORKSPACE" != /* ]]; then
    echo "错误：ODIN_WORKSPACE 必须是绝对路径，当前值为 $ODIN_WORKSPACE。" >&2
    exit 1
fi

if [[ "$(uname -m)" != "aarch64" ]]; then
    echo "错误：该脚本只支持 Jetson aarch64，当前架构为 $(uname -m)。" >&2
    exit 1
fi

source /etc/os-release
if [[ "${VERSION_ID:-}" != "20.04" ]]; then
    echo "错误：ROS Noetic 一键脚本要求 Ubuntu 20.04，当前为 ${PRETTY_NAME:-unknown}。" >&2
    echo "Ubuntu 22.04 请使用 install_ros2.sh。" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

step() {
    echo
    echo "[$1/8] $2"
}

run_as_target() {
    runuser -u "$TARGET_USER" -- env \
        HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
        ODIN_BUILD_JOBS="$ODIN_BUILD_JOBS" "$@"
}

install_source_archive() {
    local temp_dir archive extracted backup_dir
    temp_dir="$(mktemp -d)"
    archive="${temp_dir}/odin.tar.gz"
    extracted="${temp_dir}/source"
    mkdir -p "$extracted"
    curl -fL --retry 4 --retry-delay 2 "$ARCHIVE_URL" -o "$archive"
    tar -xzf "$archive" --strip-components=1 -C "$extracted"
    test -f "${extracted}/CMakeLists.txt"
    bash "${extracted}/script/download_vendor_sdk.sh" "$extracted"

    if [[ -e "$PACKAGE_DIR" ]]; then
        if [[ -d "${PACKAGE_DIR}/.git" ]]; then
            if [[ -n "$(run_as_target git -C "$PACKAGE_DIR" status --porcelain)" ]]; then
                echo "错误：$PACKAGE_DIR 有未提交修改，为避免覆盖已停止安装。" >&2
                echo "请先提交或备份修改，再重新执行脚本。" >&2
                rm -rf "$temp_dir"
                exit 1
            fi
            install -d -o "$TARGET_USER" -g "$TARGET_USER" "$BACKUP_DIR"
            backup_dir="${BACKUP_DIR}/odin_ros_driver.git.$(date +%Y%m%d_%H%M%S)"
            mv "$PACKAGE_DIR" "$backup_dir"
            echo "已有干净 Git 仓库已备份到 $backup_dir"
        fi

        if [[ -e "$PACKAGE_DIR" && ! -f "${PACKAGE_DIR}/.odin-managed-install" ]]; then
            echo "错误：$PACKAGE_DIR 已存在且不是本脚本管理的安装，拒绝覆盖。" >&2
            rm -rf "$temp_dir"
            exit 1
        fi

        if [[ -e "$PACKAGE_DIR" ]]; then
            install -d -o "$TARGET_USER" -g "$TARGET_USER" "$BACKUP_DIR"
            backup_dir="${BACKUP_DIR}/odin_ros_driver.archive.$(date +%Y%m%d_%H%M%S)"
            mv "$PACKAGE_DIR" "$backup_dir"
            echo "已有一键安装源码已备份到 $backup_dir"
        fi
    fi

    install -d -o "$TARGET_USER" -g "$TARGET_USER" "$ODIN_WORKSPACE" "${ODIN_WORKSPACE}/src"
    chown "$TARGET_USER:$TARGET_USER" "$ODIN_WORKSPACE" "${ODIN_WORKSPACE}/src"
    mv "$extracted" "$PACKAGE_DIR"
    touch "${PACKAGE_DIR}/.odin-managed-install"
    chown -R "$TARGET_USER:$TARGET_USER" "$PACKAGE_DIR"
    rm -rf "$temp_dir"
}

update_rosdep_cache() {
    local temp_dir archive tree original_list local_list rosdep_list
    temp_dir="$(mktemp -d)"
    archive="${temp_dir}/rosdistro.tar.gz"
    tree="${temp_dir}/rosdistro"
    original_list="${temp_dir}/20-default.original.list"
    local_list="${temp_dir}/20-default.local.list"
    rosdep_list="/etc/ros/rosdep/sources.list.d/20-default.list"

    chmod 0755 "$temp_dir"
    mkdir -p "$tree"
    curl -fL --retry 4 --retry-delay 2 \
        "${GITWARP_ROOT}/codeload.github.com/ros/rosdistro/tar.gz/refs/heads/master" \
        -o "$archive"
    tar -xzf "$archive" --strip-components=1 -C "$tree"
    cp "${tree}/rosdep/sources.list.d/20-default.list" "$original_list"
    cp "$original_list" "$local_list"

    # Avoid hundreds of Raw CDN requests: let rosdep parse one local rosdistro snapshot.
    sed -i '/gbpdistro/d' "$local_list"
    sed -i \
        "s#https://raw.githubusercontent.com/ros/rosdistro/master/#file://${tree}/#g" \
        "$local_list" "${tree}/index-v4.yaml"
    install -m 0644 "$local_list" "$rosdep_list"

    if ! run_as_target env \
        ROSDISTRO_INDEX_URL="file://${tree}/index-v4.yaml" \
        bash -c 'source /opt/ros/noetic/setup.bash && rosdep update'; then
        install -m 0644 "$original_list" "$rosdep_list"
        rm -rf "$temp_dir"
        return 1
    fi

    install -m 0644 "$original_list" "$rosdep_list"
    rm -rf "$temp_dir"
}

step 1 "检查 Jetson 与 CUDA 11.4"
if [[ ! -f /etc/nv_tegra_release ]]; then
    echo "错误：未检测到 Jetson Linux。" >&2
    exit 1
fi
head -n 1 /etc/nv_tegra_release
if ! head -n 1 /etc/nv_tegra_release | grep -q '# R35'; then
    echo "错误：Ubuntu 20.04 脚本要求 Jetson Linux R35 / JetPack 5。" >&2
    exit 1
fi
if ! command -v nvcc >/dev/null 2>&1 && [[ ! -x /usr/local/cuda/bin/nvcc ]]; then
    apt-get update
    apt-get install -y nvidia-jetpack
fi
if [[ -x /usr/local/cuda/bin/nvcc ]]; then
    /usr/local/cuda/bin/nvcc --version | tail -n 1
else
    nvcc --version | tail -n 1
fi

step 2 "配置 ROS 1 软件源并安装 Noetic"
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release
ros_key_file="$(mktemp)"
curl -fsSL --retry 4 \
    "${GITWARP_ROOT}/raw.githubusercontent.com/ros/rosdistro/master/ros.key" \
    -o "$ros_key_file"
gpg --dearmor --batch --yes -o /usr/share/keyrings/ros-archive-keyring.gpg "$ros_key_file"
rm -f "$ros_key_file"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros/ubuntu focal main" \
    > /etc/apt/sources.list.d/ros1.list
apt-get update
apt-get install -y ros-noetic-ros-base python3-rosdep python3-catkin-tools

step 3 "安装 Odin 驱动依赖"
opencv_version="$(apt-cache madison libopencv-dev | awk '$3 ~ /\+dfsg/ {print $3; exit}')"
if [[ -z "$opencv_version" ]]; then
    echo "错误：未找到 Ubuntu 官方 libopencv-dev 版本，无法保证与 ROS cv_bridge ABI 一致。" >&2
    exit 1
fi
apt-get install -y --allow-downgrades \
    build-essential cmake git pkg-config usbutils \
    libeigen3-dev "libopencv-dev=${opencv_version}" libpcl-dev \
    libusb-1.0-0-dev libyaml-cpp-dev libssl-dev \
    ros-noetic-cv-bridge ros-noetic-image-transport ros-noetic-pcl-conversions \
    ros-noetic-message-filters ros-noetic-nav-msgs ros-noetic-visualization-msgs \
    ros-noetic-tf2 ros-noetic-tf2-ros ros-noetic-tf2-geometry-msgs \
    ros-noetic-message-generation ros-noetic-message-runtime
echo "OpenCV 开发包版本：$(pkg-config --modversion opencv4)"

step 4 "配置 USB 权限"
getent group plugdev >/dev/null || groupadd --system plugdev
usermod -aG plugdev "$TARGET_USER"
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="2207", ATTR{idProduct}=="0019", MODE="0660", GROUP="plugdev"' \
    > /etc/udev/rules.d/99-odin-camera.rules
udevadm control --reload-rules
udevadm trigger || true

step 5 "通过 GitWarp 下载 Odin CUDA 源码"
install_source_archive

step 6 "初始化 rosdep"
install -d /etc/ros/rosdep/sources.list.d
update_rosdep_cache

step 7 "编译 ROS 1 CUDA 驱动"
run_as_target bash -c \
    'set -e; export PATH=/usr/local/cuda/bin:$PATH; cd "$1"; ./script/build_ros.sh' \
    bash "$PACKAGE_DIR"

step 8 "运行 CUDA 自检"
run_as_target bash -c \
    'set -e; source /opt/ros/noetic/setup.bash; source "$1/devel/setup.bash"; "$1/devel/lib/odin_ros_driver/odin_cuda_smoke_test"' \
    bash "$ODIN_WORKSPACE"

echo
echo "ROS 1 Odin CUDA 驱动安装完成。"
echo "工作空间：$ODIN_WORKSPACE"
echo "请重新登录一次，使 plugdev 用户组生效，并物理拔插相机。"
echo "启动命令："
echo "  source /opt/ros/noetic/setup.bash"
echo "  source '$ODIN_WORKSPACE/devel/setup.bash'"
echo "  roslaunch odin_ros_driver odin1_ros1_gpu.launch"
