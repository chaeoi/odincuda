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

- `host_sdk_sample_gpu`：彩色点云渲染、BGR 图像去畸变
- `pcd2depth_node_gpu`：ROS1 点云投影、Z-Buffer、深度图滤波、颜色映射
- `pcd2depth_ros2_node_gpu`：ROS2 版本的 GPU 深度处理节点
- `odin_cuda_smoke_test`：不连接相机即可验证 CUDA 核心路径

传感器 SDK、JPEG 解码、ROS 消息序列化和发布仍在 CPU 上执行。单个 CUDA
操作失败时会输出一次警告，并自动回退到原 CPU 实现。

## 默认低占用配置

默认配置面向去畸变图和深度图使用场景，只保留：

- `/odin1/image/undistorted`
- `/odin1/cloud_raw`，供深度节点输入
- `/odin1/depth_img_competetion`
- `/tf` 中的 `odom -> odin1_base_link`，供导航节点使用

原始 RGB、压缩 RGB、IMU、里程计话题、SLAM 点云、渲染点云、彩色深度点云、状态
CSV 均默认关闭。导航所需的 TF 独立保留，不会同时发布未使用的里程计话题。需要这些
数据时，在 `config/control_command.yaml` 中把对应开关改为 `1` 即可。开启
`senddepthcloud` 时还需同时开启 `sendrgb`。

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
`package.xml` 与 `package_ros1.xml` 是 ROS1 清单；ROS1/ROS2 构建脚本会临时使用对应
模板，结束后恢复原 `package.xml`，不会在源码目录留下切换痕迹。

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

同一台机器上不能同时运行 CPU 和 GPU 驱动，否则会同时抢占相机。

ROS1：

```bash
cd ~/odincuda
source devel/setup.bash
roslaunch odin_ros_driver odin1_ros1_gpu.launch
```

ROS2：

```bash
cd ~/odincuda
source /opt/ros/humble/setup.bash
source install/setup.bash
ros2 launch odin_ros_driver odin1_ros2_gpu.launch.py
```

GPU launch 默认只启动主驱动和 GPU 深度节点，以减少 CPU 占用。需要额外后处理时
可显式开启：

```bash
# ROS1
roslaunch odin_ros_driver odin1_ros1_gpu.launch \
  enable_reprojection:=true enable_overlay:=true

# ROS2
ros2 launch odin_ros_driver odin1_ros2_gpu.launch.py \
  enable_reprojection:=true enable_overlay:=true
```

## 性能对比

`100% CPU` 表示占满一个逻辑核。CPU 使用 `top` 每秒采样，丢弃首个累计值后统计
连续 20 个样本；GPU 使用 Jetson `tegrastats`。测试时不运行 RViz 或持续的
`ros2 topic hz`/`rostopic hz`，避免把大消息反序列化开销算入驱动。

### ROS 2 Humble + CUDA 12.6

- CUDA 全量编译成功；`odin_cuda_smoke_test` 完成显存分配、kernel 执行与回读：

  ```text
  CUDA smoke test passed: remap=192 bytes, rendered_points=3, positive_depth_pixels=3, depth_cloud_points=1, depth_only_pixels=64
  ```

- GPU launch 启动主驱动、GPU 深度可执行文件和深度组件；去畸变图、DTOF 及深度图约
  `10.2 Hz`，两路图像均取得消息，日志没有 CUDA fallback 或非对齐访问错误。
- `tegrastats` 以 100 ms 采样 12 秒，GPU 平均约 `8.9%`、峰值 `22%`。
- 优化前记录为主驱动约 `81.3% CPU`、深度节点约 `25.5% CPU`，合计 `106.8%`；最终
  默认配置 20 秒采样为主驱动约 `72.5% CPU`、深度节点约 `3.9% CPU`，合计
  `76.4%`，下降约 `28.5%`。深度节点重复采样为 `3.9%` 至 `5.3%`，按较高值计算
  合计仍下降约 `27.1%`。

仓库提供 `script/benchmark_ros2_cpu_cuda.sh`，可在目标设备上自动执行 CPU/CUDA A/B：

```bash
cd ~/odincuda/src/odin_ros_driver
ODIN_INSTALL_DIR=~/odincuda/install \
ODIN_BENCHMARK_SAMPLES=20 \
ODIN_BENCHMARK_WARMUP=10 \
./script/benchmark_ros2_cpu_cuda.sh
```

脚本会确认两路实际消息、检查 CUDA fallback，并保存每秒 CPU/RSS、100 ms GPU 原始
记录和汇总。它使用相同低占用配置分别启动 CPU 与 CUDA 可执行文件，用于把 CUDA
后端收益和关闭无用输出的收益分开。

### ROS 1 Noetic + CUDA 11.4

ROS1 的 CPU 基线和 CUDA `sm_87` 版本均在独立工作空间干净编译并通过 CUDA 自检。
去畸变图和深度图均约 `10.25 Hz`；`/tf` 包含 `odom -> odin1_base_link`，默认关闭的
IMU 和里程计话题没有数据。

仅相机驱动栈：

| 进程 | 优化前平均 | 优化前峰值 | 优化后平均 | 优化后峰值 | 平均值变化 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 相机主驱动 | `165.1%` | `176.0%` | `57.9%` | `61.0%` | 降低 `64.9%` |
| 深度节点 | `157.3%` | `172.0%` | `10.6%` | `12.0%` | 降低 `93.2%` |
| 图像叠加节点 | `6.3%` | `7.9%` | 未启动 | 未启动 | 已移除 |
| 总计 | `328.7%` | - | `68.5%` | - | 降低 `79.2%` |

相机、识别和导航完整链路：

| 进程 | 优化前平均 | 优化前峰值 | 优化后平均 | 优化后峰值 | 平均值变化 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 相机主驱动 | `160.2%` | `177.0%` | `62.1%` | `67.0%` | 降低 `61.2%` |
| 深度节点 | `153.4%` | `176.0%` | `19.2%` | `21.0%` | 降低 `87.5%` |
| 图像叠加节点 | `5.7%` | `7.0%` | 未启动 | 未启动 | 已移除 |
| 感知识别节点 | `19.7%` | `25.0%` | `25.9%` | `28.0%` | 增加 `31.4%` |
| 导航节点 | `0.7%` | `2.0%` | `0.7%` | `2.0%` | 持平 |
| 总计 | `339.7%` | - | `107.9%` | - | 降低 `68.2%` |

GPU 采样条件和结果：

| 场景 | 版本 | 采样间隔 | 样本数 | GPU 平均 | GPU 峰值 |
| --- | --- | ---: | ---: | ---: | ---: |
| 仅驱动 | 优化前 CPU 版 | `1000 ms` | `20` | `0%` | `0%` |
| 仅驱动 | 优化后 CUDA 版 | `100 ms` | `193` | `7.80%` | `39%` |
| 完整链路 | 优化前 CPU 驱动 + TensorRT 感知 | `1000 ms` | `20` | `0%`* | `0%`* |
| 完整链路 | 优化后 CUDA 驱动 + TensorRT 感知 | `100 ms` | `193` | `6.87%` | `22%` |

`*` 优化前完整链路的 1 秒采样没有捕捉到 TensorRT 短脉冲，不能解释为感知未使用
GPU，也不能与 100 ms 结果做严格峰值比较。

ROS1 的降幅同时来自 CUDA 加速和默认关闭未使用的原始 RGB、IMU、SLAM 点云、渲染
点云、彩色深度点云、状态 CSV、重投影和叠加节点，不是只更换计算后端的单变量实验。

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
| `launch_ROS1/odin1_ros1_gpu.launch` | 新增 ROS 1 GPU 主驱动/深度节点启动文件和可选后处理开关。 |
| `launch_ROS2/odin1_ros2_gpu.launch.py` | 新增 ROS 2 GPU 主驱动/深度节点启动文件和可选后处理开关。 |
| `script/install_ros1.sh` | 新增 ROS 1 一键安装脚本，源码及本地 rosdep 快照通过 GitWarp codeload 下载。 |
| `script/install_ros2.sh` | 新增 ROS 2 一键安装脚本，源码及本地 rosdep 快照通过 GitWarp codeload 下载。 |
| `script/benchmark_ros2_cpu_cuda.sh` | 新增同配置 CPU/CUDA 进程 CPU、RSS、Jetson GPU A/B 采样脚本。 |
| `script/download_vendor_sdk.sh` | 校验源码包内的 v0.14.0 厂商 SDK，并在缺失或损坏时通过 GitWarp 重新下载。 |

修改文件：

| 文件 | 改动 |
| --- | --- |
| `CMakeLists.txt` | 增加 CUDA 选项、Orin `sm_87`、GPU 目标、自检目标、安装规则，并补齐 ROS 依赖和 Jazzy 识别。 |
| `README.md` | 改为本仓库的中文安装、CUDA 范围、性能对比和上游差异说明。 |
| `config/control_command.yaml` | 默认只保留去畸变图、原始点云、深度图和导航 TF；增加 `senddepthcloud`。 |
| `include/host_sdk_sample.h` | 接入 CUDA 去畸变/彩色点云接口，按发布开关跳过不需要的图像和点云工作并保留 CPU fallback。 |
| `src/host_sdk_sample.cpp` | 按实际输出计算 RGB 流需求、读取低占用开关，并仅在需要时创建相关发布器。 |
| `include/pointcloud_depth_converter.hpp` | 为深度处理增加“是否生成彩色深度点云”参数。 |
| `src/pointcloud_depth_converter.cpp` | 接入 CUDA 深度流水线和 CPU fallback，支持不订阅颜色图的纯深度路径。 |
| `include/depth_image_ros_node.hpp` | ROS 1 深度节点增加纯点云订阅和可选彩色深度点云状态。 |
| `src/depth_image_ros_node.cpp` | ROS 1 在 `senddepthcloud=0` 时跳过颜色同步和深度点云发布。 |
| `include/depth_image_ros2_node.hpp` | ROS 2 深度节点增加纯点云订阅和可选彩色深度点云状态。 |
| `src/depth_image_ros2_node.cpp` | ROS 2 在 `publish_depth_cloud=false` 时跳过颜色同步和深度点云发布。 |
| `src/pcd2depth_ros2.cpp` | 将 `senddepthcloud` 传给 ROS 2 深度节点，并隔离无关的全局 ROS 参数。 |
| `launch_ROS1/odin1_ros1.launch` | CPU launch 默认去掉 RViz和不必要的后处理节点，只保留驱动核心链路。 |
| `launch_ROS2/odin1_ros2.launch.py` | CPU launch 默认去掉 RViz和不必要的后处理节点，只保留驱动核心链路。 |
| `script/build_ros.sh` | ROS 1 构建临时切换并恢复清单，启用 CUDA，默认限制为 2 个并行任务。 |
| `script/build_ros2.sh` | ROS 2 构建可靠恢复清单、自动找发行版、启用 CUDA并限制编译并发。 |
| `package.xml` | 补齐 ROS 1 CUDA 版实际使用的消息、PCL、TF2 等依赖。 |
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
