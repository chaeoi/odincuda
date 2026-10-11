# Odin CUDA 驱动部署说明

本文是本仓库唯一的部署文档。请先根据系统选择一章，再从该章第 1 步开始按顺序执行：

- Ubuntu 22.04、JetPack 6、ROS 2 Humble：执行“ROS 2 Humble 部署”章节。
- Ubuntu 20.04、JetPack 5、ROS 1 Noetic：执行“ROS 1 Noetic 部署”章节。

不要在 Ubuntu 22.04 上混装 ROS Noetic，也不要在 Ubuntu 20.04 上照搬 ROS 2 Humble
步骤。本文目标硬件是 NVIDIA Jetson AGX Orin，CUDA 架构为 `sm_87`。

## 标定文件说明

`calib.yaml` 是每台 Odin 相机自己的出厂标定文件。正常部署不需要自行标定，也不需要
在编译前向仓库放入标定文件。主驱动第一次连接设备后，会通过厂商 SDK 从相机读取，
校验 MD5，并保存为：

```text
~/.ros/odin_ros_driver/calib.yaml
```

只有更换镜头、改变相机内部几何关系，或厂商明确要求时才重新标定。不要把另一台相机的
文件复制过来。需要修改保存目录时，在启动所有 Odin 节点前统一设置：

```bash
export ODIN_CALIB_DIR=/一个当前用户可写的目录
```

# ROS 2 Humble 部署

支持组合：Jetson AGX Orin、Ubuntu 22.04、JetPack 6、ROS 2 Humble、CUDA 12.6、
OpenCV 4.5.4。

## ROS 2 第 1 步：检查系统

```bash
uname -m
. /etc/os-release && echo "$PRETTY_NAME"
head -n 1 /etc/nv_tegra_release
```

预期分别能看到 `aarch64`、Ubuntu 22.04 和 Jetson Linux `R36`。不符合时先用
NVIDIA SDK Manager 安装正确的 JetPack 6 系统，不要继续安装 ROS 包。

确认可用磁盘空间：

```bash
df -h /
```

JetPack、ROS 和 PCL 依赖体积较大，根分区至少应保留 15 GB 可用空间。

## ROS 2 第 2 步：安装 CUDA 开发组件

先检查：

```bash
/usr/local/cuda/bin/nvcc --version
test -f /usr/local/cuda/include/cuda_runtime.h && echo "CUDA headers ready"
```

如果 `nvcc` 不存在，但第 1 步已经确认是正确的 JetPack 6 系统：

```bash
sudo apt update
sudo apt install -y nvidia-jetpack
```

安装后重新执行本节的两条检查命令。

## ROS 2 第 3 步：安装 ROS 2 Humble

已有 ROS 2 时先检查：

```bash
test -f /opt/ros/humble/setup.bash && echo "ROS 2 Humble ready"
```

文件存在就跳到第 4 步。否则执行：

```bash
sudo apt update
sudo apt install -y locales software-properties-common curl ca-certificates gnupg
sudo locale-gen en_US en_US.UTF-8
sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
export LANG=en_US.UTF-8
sudo add-apt-repository -y universe

curl -fsSL \
  https://gitwarp.canghai.org/raw.githubusercontent.com/ros/rosdistro/master/ros.key \
  -o /tmp/ros.key
sudo gpg --dearmor --yes \
  -o /usr/share/keyrings/ros-archive-keyring.gpg /tmp/ros.key
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu jammy main" | \
  sudo tee /etc/apt/sources.list.d/ros2.list >/dev/null

sudo apt update
sudo apt install -y ros-humble-ros-base ros-dev-tools
```

检查 ROS 环境：

```bash
source /opt/ros/humble/setup.bash
echo "$ROS_DISTRO"
ros2 --help >/dev/null && echo "ROS 2 CLI ready"
```

`ROS_DISTRO` 必须输出 `humble`。

## ROS 2 第 4 步：安装编译依赖

```bash
sudo apt update
opencv_version=$(apt-cache madison libopencv-dev | awk '$3 ~ /\+dfsg/ {print $3; exit}')
test -n "$opencv_version"
sudo apt install -y --allow-downgrades \
  build-essential cmake git pkg-config usbutils python3-rosdep python3-colcon-common-extensions \
  libeigen3-dev "libopencv-dev=$opencv_version" libpcl-dev \
  libusb-1.0-0-dev libyaml-cpp-dev libssl-dev \
  ros-humble-ament-index-cpp ros-humble-cv-bridge ros-humble-image-transport \
  ros-humble-pcl-conversions ros-humble-message-filters \
  ros-humble-tf2 ros-humble-tf2-ros ros-humble-tf2-geometry-msgs \
  ros-humble-rosidl-default-generators
```

检查 OpenCV：

```bash
pkg-config --modversion opencv4
```

推荐使用 4.5.4。若机器混装了其他来源的 OpenCV，并出现版本化链接库或 TBB
冲突，应先统一 OpenCV 与 `/opt/ros/humble` 中 `cv_bridge` 的 ABI，不能创建软链接伪造
缺失库。

## ROS 2 第 5 步：配置 USB 权限

插入相机并检查设备及链路速度：

```bash
lsusb | grep 2207:0019
lsusb -t
```

第一条必须看到 `2207:0019`；第二条应显示 `5000M` 或更高。若第一条没有输出，先处理
供电、USB 线、Hub 或物理连接，ROS 配置不能解决设备未枚举。

配置普通用户权限：

```bash
sudo groupadd --system plugdev 2>/dev/null || true
sudo usermod -aG plugdev "$USER"
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="2207", ATTR{idProduct}=="0019", MODE="0660", GROUP="plugdev"' | \
  sudo tee /etc/udev/rules.d/99-odin-camera.rules >/dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger
```

现在注销并重新登录，SSH 用户应断开后重新连接。然后物理拔插一次相机并确认：

```bash
id | grep plugdev
lsusb | grep 2207:0019
```

不要长期使用 root 运行相机节点绕过权限。

## ROS 2 第 6 步：下载源码

源码通过 GitWarp 的 GitHub codeload 加速地址下载。目录必须是
`~/odincuda/src/odin_ros_driver`：

```bash
mkdir -p ~/odincuda/src/odin_ros_driver
curl -fL --retry 4 \
  https://gitwarp.canghai.org/codeload.github.com/chaeoi/odincuda/tar.gz/refs/heads/main \
  -o /tmp/odincuda-main.tar.gz
tar -xzf /tmp/odincuda-main.tar.gz --strip-components=1 \
  -C ~/odincuda/src/odin_ros_driver
test -f ~/odincuda/src/odin_ros_driver/CMakeLists.txt && echo "source ready"
```

如果目录已经存在，不要覆盖。先确认内容并备份：

```bash
mkdir -p ~/odincuda-backups
mv ~/odincuda/src/odin_ros_driver \
  ~/odincuda-backups/odin_ros_driver.$(date +%Y%m%d_%H%M%S)
```

然后重新执行本节下载命令。开发人员需要保留提交历史时可自行使用 Git；部署机推荐使用
上述归档地址。

## ROS 2 第 7 步：通过 CDN 快照初始化 rosdep

```bash
rosdistro_tmp=$(mktemp -d)
chmod 755 "$rosdistro_tmp"
mkdir "$rosdistro_tmp/tree"
curl -fL --retry 4 \
  https://gitwarp.canghai.org/codeload.github.com/ros/rosdistro/tar.gz/refs/heads/master \
  -o "$rosdistro_tmp/rosdistro.tar.gz"
tar -xzf "$rosdistro_tmp/rosdistro.tar.gz" --strip-components=1 \
  -C "$rosdistro_tmp/tree"

sudo mkdir -p /etc/ros/rosdep/sources.list.d
cp "$rosdistro_tmp/tree/rosdep/sources.list.d/20-default.list" \
  "$rosdistro_tmp/20-default.original.list"
cp "$rosdistro_tmp/20-default.original.list" "$rosdistro_tmp/20-default.local.list"
sed -i '/gbpdistro/d' "$rosdistro_tmp/20-default.local.list"
sed -i \
  "s#https://raw.githubusercontent.com/ros/rosdistro/master/#file://$rosdistro_tmp/tree/#g" \
  "$rosdistro_tmp/20-default.local.list" "$rosdistro_tmp/tree/index-v4.yaml"
sudo install -m 0644 "$rosdistro_tmp/20-default.local.list" \
  /etc/ros/rosdep/sources.list.d/20-default.list

ROSDISTRO_INDEX_URL="file://$rosdistro_tmp/tree/index-v4.yaml" rosdep update
rosdep_status=$?
sudo install -m 0644 "$rosdistro_tmp/20-default.original.list" \
  /etc/ros/rosdep/sources.list.d/20-default.list
rm -rf "$rosdistro_tmp"
test "$rosdep_status" -eq 0
```

这里下载的是一个 GitWarp codeload 快照。`rosdep` 在本机解析快照，避免向 Raw CDN
连续发送大量小请求而触发 403；缓存生成后恢复标准官方源列表。

本仓库默认 `package.xml` 是 ROS 1 清单。做 ROS 2 的 `rosdep install` 时临时切换，完成
后立即恢复：

```bash
cd ~/odincuda/src/odin_ros_driver
cp package.xml /tmp/odin-package.xml
cp package_ros2.xml package.xml
cd ~/odincuda
source /opt/ros/humble/setup.bash
rosdep install --from-paths src --ignore-src -r -y --rosdistro humble
cp /tmp/odin-package.xml ~/odincuda/src/odin_ros_driver/package.xml
```

## ROS 2 第 8 步：编译 CUDA 版本

```bash
cd ~/odincuda/src/odin_ros_driver
export PATH=/usr/local/cuda/bin:$PATH
export ODIN_BUILD_JOBS=2
./script/build_ros2.sh
```

机器内存紧张或正在运行其他任务时设置 `ODIN_BUILD_JOBS=1`。看到
`ROS2 build successful` 后检查：

```bash
test -f ~/odincuda/install/setup.bash
find ~/odincuda/install/odin_ros_driver/lib -maxdepth 2 -type f \
  \( -name host_sdk_sample_gpu -o -name pcd2depth_ros2_node_gpu \
  -o -name odin_cuda_smoke_test \) -print
```

## ROS 2 第 9 步：运行 CUDA 自检

自检不需要连接相机，它会实际执行显存分配、CUDA kernel 和结果回读：

```bash
cd ~/odincuda
source /opt/ros/humble/setup.bash
source install/setup.bash
ros2 run odin_ros_driver odin_cuda_smoke_test
```

必须看到 `CUDA smoke test passed`。失败时不要继续启动相机，先解决 CUDA 驱动、Toolkit
或编译架构问题。

## ROS 2 第 10 步：确认低占用配置

```bash
cd ~/odincuda/src/odin_ros_driver
grep -E 'sendrgb:|sendrgbundistort:|sendimu:|sendodom:|send_odom_baselink_tf:|senddtof:|senddepth:|senddepthcloud:' \
  config/control_command.yaml
```

默认应为：

```text
sendrgb: 0
sendrgbundistort: 1
sendimu: 0
sendodom: 0
send_odom_baselink_tf: 1
senddtof: 1
senddepth: 1
senddepthcloud: 0
```

需要彩色深度点云时必须同时设置 `senddepthcloud: 1` 和 `sendrgb: 1`。

## ROS 2 第 11 步：首次启动并读取标定

先确认设备和进程：

```bash
lsusb | grep 2207:0019
pgrep -af 'host_sdk_sample|pcd2depth' || true
```

没有旧进程后启动：

```bash
cd ~/odincuda
source /opt/ros/humble/setup.bash
source install/setup.bash
ros2 launch odin_ros_driver odin1_ros2_gpu.launch.py
```

首次连接的关键日志应依次包含：

```text
Hardware connected
ros_driver_version:0.14.0
[recv small file]:MD5 verification successful
[CALIB] SAVED -> .../.ros/odin_ros_driver/calib.yaml
Software connection successful
Device ready and streams activated
```

另开终端检查标定：

```bash
test -s ~/.ros/odin_ros_driver/calib.yaml
stat -c '%n %s bytes' ~/.ros/odin_ros_driver/calib.yaml
sed -n '1,15p' ~/.ros/odin_ros_driver/calib.yaml
```

## ROS 2 第 12 步：验证节点和数据

保持 launch 运行，在新终端执行：

```bash
cd ~/odincuda
source /opt/ros/humble/setup.bash
source install/setup.bash
ros2 node list
ros2 topic list | sort
```

应至少看到 GPU 主驱动、GPU 深度节点和 `/depth_image_ros2_node`，并有下列话题：

```text
/odin1/cloud_raw
/odin1/image/undistorted
/odin1/depth_img_competetion
```

各取一条实际消息：

```bash
timeout 15s ros2 topic echo /odin1/image/undistorted --once --field header
timeout 15s ros2 topic echo /odin1/depth_img_competetion --once --field header
```

短时间检查频率：

```bash
timeout 15s ros2 topic hz /odin1/image/undistorted
timeout 15s ros2 topic hz /odin1/depth_img_competetion
```

`ros2 topic hz` 本身会反序列化大图，性能采样时不要让它持续运行。

## ROS 2 第 13 步：停止和再次启动

在 launch 终端按一次 `Ctrl+C`，等待退出后检查：

```bash
pgrep -af 'host_sdk_sample|pcd2depth' || true
```

无输出后可以再次执行第 11 步启动命令。同一相机不能同时运行 CPU 和 GPU 主驱动。

需要重投影或叠加图时才开启额外节点：

```bash
ros2 launch odin_ros_driver odin1_ros2_gpu.launch.py \
  enable_reprojection:=true enable_overlay:=true
```

# ROS 1 Noetic 部署

支持组合：Jetson AGX Orin、Ubuntu 20.04、JetPack 5、ROS Noetic、CUDA 11.4、
OpenCV 4.5.4。

## ROS 1 第 1 步：检查系统

```bash
uname -m
. /etc/os-release && echo "$PRETTY_NAME"
head -n 1 /etc/nv_tegra_release
```

预期为 `aarch64`、Ubuntu 20.04 和 Jetson Linux `R35`。不符合时不要继续混装软件包。
同时用 `df -h /` 确认根分区至少有 15 GB 可用空间。

## ROS 1 第 2 步：安装 CUDA 11.4 开发组件

```bash
/usr/local/cuda/bin/nvcc --version
test -f /usr/local/cuda/include/cuda_runtime.h && echo "CUDA headers ready"
```

应看到 CUDA 11.4。若 `nvcc` 不存在且系统确为 JetPack 5：

```bash
sudo apt update
sudo apt install -y nvidia-jetpack
```

## ROS 1 第 3 步：安装 ROS Noetic

已有 ROS 时检查：

```bash
test -f /opt/ros/noetic/setup.bash && echo "ROS Noetic ready"
```

不存在时执行：

```bash
sudo apt update
sudo apt install -y curl ca-certificates gnupg lsb-release
curl -fsSL \
  https://gitwarp.canghai.org/raw.githubusercontent.com/ros/rosdistro/master/ros.key \
  -o /tmp/ros.key
sudo gpg --dearmor --yes \
  -o /usr/share/keyrings/ros-archive-keyring.gpg /tmp/ros.key
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros/ubuntu focal main" | \
  sudo tee /etc/apt/sources.list.d/ros1.list >/dev/null
sudo apt update
sudo apt install -y ros-noetic-ros-base python3-rosdep python3-catkin-tools
```

检查：

```bash
source /opt/ros/noetic/setup.bash
echo "$ROS_DISTRO"
rosversion -d
```

两处都应输出 `noetic`。

## ROS 1 第 4 步：安装编译依赖

```bash
sudo apt update
opencv_version=$(apt-cache madison libopencv-dev | awk '$3 ~ /\+dfsg/ {print $3; exit}')
test -n "$opencv_version"
sudo apt install -y --allow-downgrades \
  build-essential cmake git pkg-config usbutils python3-rosdep \
  libeigen3-dev "libopencv-dev=$opencv_version" libpcl-dev \
  libusb-1.0-0-dev libyaml-cpp-dev libssl-dev \
  ros-noetic-cv-bridge ros-noetic-image-transport ros-noetic-pcl-conversions \
  ros-noetic-message-filters ros-noetic-nav-msgs ros-noetic-visualization-msgs \
  ros-noetic-tf2 ros-noetic-tf2-ros ros-noetic-tf2-geometry-msgs \
  ros-noetic-message-generation ros-noetic-message-runtime
```

检查：

```bash
pkg-config --modversion opencv4
/usr/local/cuda/bin/nvcc --version
```

## ROS 1 第 5 步：配置 USB 权限

```bash
lsusb | grep 2207:0019
lsusb -t
sudo groupadd --system plugdev 2>/dev/null || true
sudo usermod -aG plugdev "$USER"
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="2207", ATTR{idProduct}=="0019", MODE="0660", GROUP="plugdev"' | \
  sudo tee /etc/udev/rules.d/99-odin-camera.rules >/dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger
```

注销并重新登录，再物理拔插相机。然后用 `id | grep plugdev` 和
`lsusb | grep 2207:0019` 复查。

## ROS 1 第 6 步：下载源码

```bash
mkdir -p ~/odincuda/src/odin_ros_driver
curl -fL --retry 4 \
  https://gitwarp.canghai.org/codeload.github.com/chaeoi/odincuda/tar.gz/refs/heads/main \
  -o /tmp/odincuda-main.tar.gz
tar -xzf /tmp/odincuda-main.tar.gz --strip-components=1 \
  -C ~/odincuda/src/odin_ros_driver
test -f ~/odincuda/src/odin_ros_driver/CMakeLists.txt && echo "source ready"
```

已有目录时先备份，不能覆盖本地修改：

```bash
mkdir -p ~/odincuda-backups
mv ~/odincuda/src/odin_ros_driver \
  ~/odincuda-backups/odin_ros_driver.$(date +%Y%m%d_%H%M%S)
```

## ROS 1 第 7 步：通过 CDN 快照初始化 rosdep 并安装依赖

```bash
rosdistro_tmp=$(mktemp -d)
chmod 755 "$rosdistro_tmp"
mkdir "$rosdistro_tmp/tree"
curl -fL --retry 4 \
  https://gitwarp.canghai.org/codeload.github.com/ros/rosdistro/tar.gz/refs/heads/master \
  -o "$rosdistro_tmp/rosdistro.tar.gz"
tar -xzf "$rosdistro_tmp/rosdistro.tar.gz" --strip-components=1 \
  -C "$rosdistro_tmp/tree"

sudo mkdir -p /etc/ros/rosdep/sources.list.d
cp "$rosdistro_tmp/tree/rosdep/sources.list.d/20-default.list" \
  "$rosdistro_tmp/20-default.original.list"
cp "$rosdistro_tmp/20-default.original.list" "$rosdistro_tmp/20-default.local.list"
sed -i '/gbpdistro/d' "$rosdistro_tmp/20-default.local.list"
sed -i \
  "s#https://raw.githubusercontent.com/ros/rosdistro/master/#file://$rosdistro_tmp/tree/#g" \
  "$rosdistro_tmp/20-default.local.list" "$rosdistro_tmp/tree/index-v4.yaml"
sudo install -m 0644 "$rosdistro_tmp/20-default.local.list" \
  /etc/ros/rosdep/sources.list.d/20-default.list

ROSDISTRO_INDEX_URL="file://$rosdistro_tmp/tree/index-v4.yaml" rosdep update
rosdep_status=$?
sudo install -m 0644 "$rosdistro_tmp/20-default.original.list" \
  /etc/ros/rosdep/sources.list.d/20-default.list
rm -rf "$rosdistro_tmp"
test "$rosdep_status" -eq 0

cd ~/odincuda
source /opt/ros/noetic/setup.bash
rosdep install --from-paths src --ignore-src -r -y --rosdistro noetic
```

快照方案的原因和 ROS 2 相同。默认 `package.xml` 已是 ROS 1 清单，不需要手工切换。

## ROS 1 第 8 步：编译 CUDA 版本

```bash
cd ~/odincuda/src/odin_ros_driver
export PATH=/usr/local/cuda/bin:$PATH
export ODIN_BUILD_JOBS=2
./script/build_ros.sh
```

看到 `ROS1 build successful` 后检查：

```bash
test -f ~/odincuda/devel/setup.bash
find ~/odincuda/devel/lib/odin_ros_driver -maxdepth 1 -type f \
  \( -name host_sdk_sample_gpu -o -name pcd2depth_node_gpu \
  -o -name odin_cuda_smoke_test \) -print
```

## ROS 1 第 9 步：运行 CUDA 自检

```bash
cd ~/odincuda
source /opt/ros/noetic/setup.bash
source devel/setup.bash
./devel/lib/odin_ros_driver/odin_cuda_smoke_test
```

必须看到 `CUDA smoke test passed`。

## ROS 1 第 10 步：确认低占用配置

```bash
cd ~/odincuda/src/odin_ros_driver
grep -E 'sendrgb:|sendrgbundistort:|sendimu:|sendodom:|send_odom_baselink_tf:|senddtof:|senddepth:|senddepthcloud:' \
  config/control_command.yaml
```

预期值与 ROS 2 第 10 步相同。需要彩色深度点云时同时启用 `senddepthcloud` 和
`sendrgb`。

## ROS 1 第 11 步：首次启动并读取标定

```bash
lsusb | grep 2207:0019
pgrep -af 'host_sdk_sample|pcd2depth' || true
cd ~/odincuda
source /opt/ros/noetic/setup.bash
source devel/setup.bash
roslaunch odin_ros_driver odin1_ros1_gpu.launch
```

首次启动应看到硬件连接、`ros_driver_version:0.14.0`、标定 MD5 成功、软件连接成功和
数据流激活。另开终端检查：

```bash
test -s ~/.ros/odin_ros_driver/calib.yaml
stat -c '%n %s bytes' ~/.ros/odin_ros_driver/calib.yaml
sed -n '1,15p' ~/.ros/odin_ros_driver/calib.yaml
```

## ROS 1 第 12 步：验证节点、话题和 TF

保持 launch 运行，在新终端执行：

```bash
cd ~/odincuda
source /opt/ros/noetic/setup.bash
source devel/setup.bash
rosnode list
rostopic list | sort
timeout 15s rostopic echo -n 1 /odin1/image/undistorted/header
timeout 15s rostopic echo -n 1 /odin1/depth_img_competetion/header
timeout 10s rosrun tf tf_echo odom odin1_base_link
```

短时检查频率：

```bash
timeout 15s rostopic hz /odin1/image/undistorted
timeout 15s rostopic hz /odin1/depth_img_competetion
```

性能采样时停止这些命令，避免把 CLI 订阅负载计入驱动。

## ROS 1 第 13 步：停止和再次启动

在 launch 终端按一次 `Ctrl+C`，然后确认无残留：

```bash
pgrep -af 'host_sdk_sample|pcd2depth' || true
```

需要额外后处理时才开启：

```bash
roslaunch odin_ros_driver odin1_ros1_gpu.launch \
  enable_reprojection:=true enable_overlay:=true
```

# 通用故障处理

## `lsusb` 没有 `2207:0019`

设备没有被 Linux 枚举，这不是 ROS 参数问题：

```bash
lsusb -t
sudo dmesg | grep -Ei 'usb|2207|0019' | tail -n 100
```

检查相机供电、USB 线、Hub 和物理连接。

## `LIBUSB_ERROR_ACCESS`

```bash
id
ls -l /dev/bus/usb/*/*
```

确认当前会话已经包含 `plugdev`，然后重载第 5 步的 udev 规则并物理拔插相机。

## 标定文件为 0 字节或长度错误

确认驱动日志版本为 v0.14.0，并检查 ARM 厂商 SDK：

```bash
sha256sum ~/odincuda/src/odin_ros_driver/lib/liblydHostApi_arm.a
```

本仓库 v0.14.0 SDK 的 SHA-256 是：

```text
4e31dcf09afcd0c0028e3f424182195dad4fb1f5d631e1f7e6d066eabb344724
```

不要继续使用 0 字节或校验失败的标定文件。

## 找不到 ROS 包

每个新终端都必须先载入 ROS 和工作空间。ROS 2：

```bash
source /opt/ros/humble/setup.bash
source ~/odincuda/install/setup.bash
ros2 pkg prefix odin_ros_driver
```

ROS 1：

```bash
source /opt/ros/noetic/setup.bash
source ~/odincuda/devel/setup.bash
rospack find odin_ros_driver
```

## 完整重编

ROS 2：

```bash
cd ~/odincuda/src/odin_ros_driver
./script/build_ros2.sh --clean
export ODIN_BUILD_JOBS=2
./script/build_ros2.sh
```

ROS 1：

```bash
cd ~/odincuda/src/odin_ros_driver
./script/build_ros.sh --clean
export ODIN_BUILD_JOBS=2
./script/build_ros.sh
```

`--clean` 会删除该工作空间的 `build/install/log/devel`。执行前确认工作空间没有混放
其他需要保留的构建产物。
