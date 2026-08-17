# Odin CUDA ROS 驱动

本项目面向 NVIDIA Jetson AGX Orin，为 Odin 相机驱动增加 CUDA 加速，同时支持：

- Ubuntu 20.04 + ROS1 Noetic + CUDA 11.4
- Ubuntu 22.04 + ROS2 Humble + CUDA 12.6

本项目基于官方仓库
[manifoldsdk/odin_ros_driver](https://github.com/manifoldsdk/odin_ros_driver)，已同步至官方
`v0.14.0`（提交 `6f993ccc4ccad9395bfc68bc3235f993d83c4fe6`），并保留本仓库的
Jetson CUDA 加速。许可证为 Apache-2.0。

## 一键安装

脚本只支持 Jetson `aarch64`，会检查系统版本、安装 JetPack/ROS/驱动依赖、配置 USB
权限、通过 GitWarp 下载源码、编译 CUDA 版本并运行 CUDA 自检。默认工作空间为执行
`sudo` 的普通用户的 `~/odincuda`，默认使用 2 个编译任务。

ROS 2 Humble（Ubuntu 22.04 + JetPack 6）：

```bash
curl -fsSL https://gitwarp.canghai.org/raw.githubusercontent.com/chaeoi/odincuda/main/script/install_ros2.sh | sudo bash
```

ROS 1 Noetic（Ubuntu 20.04 + JetPack 5）：

```bash
curl -fsSL https://gitwarp.canghai.org/raw.githubusercontent.com/chaeoi/odincuda/main/script/install_ros1.sh | sudo bash
```

不是 `ubuntu` 用户或需要调整工作空间、编译并发时，把参数传给 `sudo env`。例如：

```bash
curl -fsSL https://gitwarp.canghai.org/raw.githubusercontent.com/chaeoi/odincuda/main/script/install_ros2.sh | \
  sudo env TARGET_USER=robot ODIN_WORKSPACE=/home/robot/odincuda ODIN_BUILD_JOBS=1 bash
```

脚本不会覆盖来源不明的已有目录；脚本管理的旧归档安装或干净 Git 工作区会先备份，
Git 工作区存在未提交修改时会停止。安装完成后重新登录并物理拔插相机，使 `plugdev`
权限生效。完整检查项、手动安装和故障处理见 [DEPLOYMENT.md](DEPLOYMENT.md)。

## 与官方驱动的关系

本仓库直接沿用官方驱动的目录结构、文件名、类名、变量名、节点名和话题名，CUDA
功能在原有实现中按编译选项接入。这样后续可继续对照
[官方仓库](https://github.com/manifoldsdk/odin_ros_driver) 的变更，不需要维护一套重新命名的代码。

## 加速范围

CUDA 编译进官方目标名：`host_sdk_sample`、`pcd2depth_node` 和
`pcd2depth_ros2_node`。彩色点云渲染、BGR 去畸变、点云投影、Z-Buffer、深度滤波和
颜色映射在 CUDA 路径执行；传感器 SDK、JPEG 解码、ROS 消息序列化和发布仍由 CPU
负责。`odin_cuda_smoke_test` 只用于不连接相机时检查 CUDA 环境，不是驱动替代程序。
CUDA 运行时发生错误时会记录一次警告并使用同一官方目标内的保护性 CPU 回退。

## 官方默认配置

`config/control_command.yaml` 保持官方默认值，完整官方话题和开关均可用：原始/压缩
RGB、IMU、里程计、SLAM 点云、渲染点云和状态日志默认开启，深度补全默认关闭。需要
导航 TF 时保持 `send_odom_baselink_tf: 1`；它发布官方约定的 `odom -> imu` TF，
供 RViz 和导航消费。

保存地图前把 `custom_map_mode` 设为 `1`（SLAM），然后在驱动运行期间执行：

```bash
./set_param.sh save_map 1
```

地图默认写入 `map/{driver_start_time}/map_{map_save_time}.bin`；也可在配置中填写
`mapping_result_dest_dir` 和 `mapping_result_file_name`。驱动会先创建并校验目录，保存
完成后日志会给出最终文件路径。

## 目标环境

- 架构：Jetson AGX Orin，`aarch64`，CUDA `sm_87`
- OpenCV：4.5 或更高版本
- 厂商 SDK：`lib/liblydHostApi_arm.a`

如果源码包未包含厂商二进制 SDK，手动构建前请在驱动包目录执行一次：

```bash
./script/download_vendor_sdk.sh
```

`calib.yaml` 是设备专属的出厂标定文件。正常部署不需要用户重新标定，也不需要在
编译前手工放入仓库；驱动连接相机后会通过厂商 SDK 从设备读取，并保存到
`~/.ros/odin_ros_driver/calib.yaml`。可通过 `ODIN_CALIB_DIR` 修改保存目录。

## ROS1 编译

```bash
mkdir -p ~/odincuda/src
cd ~/odincuda/src
mkdir odin_ros_driver
curl -fL https://gitwarp.canghai.org/codeload.github.com/chaeoi/odincuda/tar.gz/refs/heads/main \
  -o /tmp/odincuda-main.tar.gz
tar -xzf /tmp/odincuda-main.tar.gz --strip-components=1 -C odin_ros_driver
cd odin_ros_driver
./script/build_ros.sh
```

## ROS2 编译

```bash
mkdir -p ~/odincuda/src
cd ~/odincuda/src
mkdir odin_ros_driver
curl -fL https://gitwarp.canghai.org/codeload.github.com/chaeoi/odincuda/tar.gz/refs/heads/main \
  -o /tmp/odincuda-main.tar.gz
tar -xzf /tmp/odincuda-main.tar.gz --strip-components=1 -C odin_ros_driver
cd odin_ros_driver
./script/build_ros2.sh
```

仓库按官方布局保留 `package.xml`、`package_ros1.xml` 和 `package_ros2.xml`。
默认 `package.xml` 是官方 ROS2 清单；ROS1/ROS2 构建脚本会临时使用对应模板，结束后
恢复原 `package.xml`，不会在源码目录留下切换痕迹。

## CUDA 自检

ROS1：

```bash
cd ~/odincuda
./devel/lib/odin_ros_driver/odin_cuda_smoke_test
```

ROS2：

```bash
cd ~/odincuda
source /opt/ros/humble/setup.bash
source install/setup.bash
ros2 run odin_ros_driver odin_cuda_smoke_test
```

自检覆盖图像映射、彩色点云渲染、深度投影、彩色深度点云，以及不传颜色图的
深度图专用路径。

## 启动相机

同一台机器只运行一个官方驱动进程，否则会同时抢占相机。

ROS1：

```bash
cd ~/odincuda
source devel/setup.bash
roslaunch odin_ros_driver odin1_ros1.launch
```

ROS2：

```bash
cd ~/odincuda
source /opt/ros/humble/setup.bash
source install/setup.bash
ros2 launch odin_ros_driver odin1_ros2.launch.py
```

两个启动文件都使用官方节点名；带 `_gpu` 的启动文件只是兼容别名，里面不会启动
重复的 `_gpu` 可执行程序。

## 性能对比

`100% CPU` 表示占满一个逻辑核。CPU 使用 `top` 每秒采样，丢弃首个累计值后统计
连续 20 个样本；GPU 使用 Jetson `tegrastats`。测试时不运行 RViz 或持续的
`ros2 topic hz`/`rostopic hz`，避免把大消息反序列化开销算入驱动。

### ROS 2 Humble + CUDA

`odin_cuda_smoke_test` 不连接相机即可验证显存分配、kernel 执行和结果回读。仓库提供
`script/benchmark_ros2_cpu_cuda.sh`，采样官方目标的 CPU、RSS 和 Jetson GPU 使用率：

```bash
cd ~/odincuda/src/odin_ros_driver
ODIN_INSTALL_DIR=~/odincuda/install \
ODIN_BENCHMARK_SAMPLES=20 \
ODIN_BENCHMARK_WARMUP=10 \
./script/benchmark_ros2_cpu_cuda.sh
```

脚本会确认实际消息、检查 CUDA fallback，并保存每秒 CPU/RSS、100 ms GPU 原始记录和
汇总。它只启动官方 `host_sdk_sample` 与 `pcd2depth_ros2_node`，不维护第二套 CPU/GPU
可执行程序。

### ROS 1 Noetic + CUDA

ROS1 使用同样的官方目标名和 CUDA 内置实现；启动、话题和配置与官方驱动保持一致。

## 支持环境

- Ubuntu 20.04、ROS1 Noetic、CUDA 11.4、OpenCV 4.5.4、Jetson AGX Orin（`aarch64`）
- Ubuntu 22.04、ROS2 Humble、CUDA 12.6、OpenCV 4.5.4、Jetson AGX Orin（`aarch64`）

## 相对官方 v0.14.0 的文件改动

对比基准是官方提交 `6f993ccc4ccad9395bfc68bc3235f993d83c4fe6`。当前仓库相对该
版本新增 10 个文件、修改 25 个文件、删除 0 个文件。

新增文件：

| 文件 | 改动 |
| --- | --- |
| `DEPLOYMENT.md` | 新增唯一部署文档，分别给出 ROS 2 Humble 和 ROS 1 Noetic 完整步骤。 |
| `include/odin_cuda_ops.hpp` | 定义图像映射、彩色点云和深度处理 CUDA 接口。 |
| `src/odin_cuda_ops.cu` | 实现 CUDA kernel、显存管理、结果回读和错误返回。 |
| `src/odin_cuda_smoke_test.cpp` | 新增不依赖相机的 CUDA 分配、kernel 和回读自检。 |
| `launch_ROS1/odin1_ros1_gpu.launch` | 兼容别名，仍调用官方 ROS 1 节点名。 |
| `launch_ROS2/odin1_ros2_gpu.launch.py` | 兼容别名，仍调用官方 ROS 2 节点名。 |
| `script/install_ros1.sh` | 新增 ROS 1 一键安装脚本，源码及本地 rosdep 快照通过 GitWarp codeload 下载。 |
| `script/install_ros2.sh` | 新增 ROS 2 一键安装脚本，源码及本地 rosdep 快照通过 GitWarp codeload 下载。 |
| `script/benchmark_ros2_cpu_cuda.sh` | 采样官方 CUDA 目标的 CPU、RSS 和 Jetson GPU 使用率。 |
| `script/download_vendor_sdk.sh` | 校验源码包内的 v0.14.0 厂商 SDK，并在缺失或损坏时通过 GitWarp 重新下载。 |

修改文件：

| 文件 | 改动 |
| --- | --- |
| `CMakeLists.txt` | 将 CUDA 编译进官方目标，保留 Orin `sm_87`、自检目标、安装规则和 ROS 依赖。 |
| `README.md` | 改为本仓库的中文安装、CUDA 范围、性能对比和上游差异说明。 |
| `config/control_command.yaml` | 恢复官方默认开关和官方配置键。 |
| `include/host_sdk_sample.h` | 接入 CUDA 去畸变/彩色点云接口，保留官方发布行为。 |
| `src/host_sdk_sample.cpp` | 修复地图目录创建和 `save_map` 请求校验，保留官方触发方式。 |
| `src/pointcloud_depth_converter.cpp` | 接入 CUDA 深度流水线和同目标内的保护性 CPU 回退。 |
| `src/depth_image_ros_node.cpp` | 恢复官方 ROS 1 深度同步和发布行为。 |
| `src/depth_image_ros2_node.cpp` | 恢复官方 ROS 2 深度同步和发布行为。 |
| `src/pcd2depth_ros2.cpp` | 保留官方参数和节点行为。 |
| `launch_ROS1/odin1_ros1.launch` | 恢复官方 RViz 参数和节点。 |
| `launch_ROS2/odin1_ros2.launch.py` | 恢复官方 RViz2 参数和节点。 |
| `script/build_ros.sh` | ROS 1 构建临时切换并恢复清单，启用 CUDA，默认限制为 2 个并行任务。 |
| `script/build_ros2.sh` | ROS 2 构建可靠恢复清单、自动找发行版、启用 CUDA并限制编译并发。 |
| `package.xml` | 保持官方 ROS2 包清单；ROS1 构建通过专用模板切换。 |
| `package_ros1.xml` | 同步 ROS 1 构建模板依赖。 |
| `package_ros2.xml` | 补充 ROS 2 深度节点使用的 `rcpputils` 等依赖。 |
| `CHANGELOG.md` | 仅清理尾部空白，不改变内容。 |
| `RELOCALIZATION_GUIDE.md` | 仅清理空白和文件尾换行，不改变说明内容。 |
| `include/lidar_api.h` | 仅清理行尾空白，不改变 SDK API。 |
| `include/lidar_api_type.h` | 仅清理行尾空白，不改变 SDK 类型。 |
| `script/rosbag2_qos.yaml` | 仅统一文件尾换行，不改变 QoS。 |

删除文件：无。官方 v0.14.0 的目录和厂商 SDK 文件均保留。

ROS 2 Humble 和 ROS 1 Noetic 的逐步安装、编译与验证统一见
[DEPLOYMENT.md](DEPLOYMENT.md)。性能对比见本 README。
