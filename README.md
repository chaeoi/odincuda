# Odin CUDA ROS 驱动

本项目面向 NVIDIA Jetson AGX Orin，为 Odin 相机驱动增加 CUDA 加速，同时支持：

- Ubuntu 20.04 + ROS1 Noetic + CUDA 11.4
- Ubuntu 22.04 + ROS2 Humble + CUDA 12.6

项目基于 Manifold Tech `odin_ros_driver` 的提交
`cc69880db4cc26ec2682b0d0e038cf457f813f4c`，许可证为 Apache-2.0。

## 与官方驱动的关系

本仓库直接沿用官方驱动的目录结构、文件名、类名、变量名、节点名和话题名，CUDA
功能在原有实现中按编译选项接入。这样后续可继续对照
`https://github.com/manifoldsdk/odin_ros_driver.git` 的变更，不需要维护一套重新命名的代码。

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

`config/calib.yaml` 是设备专属标定文件，不提交到公开仓库。编译和启动前需将
当前相机对应的标定文件放到该路径。

## ROS1 编译

```bash
mkdir -p ~/odin_gpu_ws/src
cd ~/odin_gpu_ws/src
git clone https://github.com/chaeoi/odincuda.git odin_ros_driver
cd ..
source /opt/ros/noetic/setup.bash
catkin_make -DODIN_BUILD_CUDA=ON -DODIN_CUDA_ARCH=87
```

## ROS2 编译

```bash
mkdir -p ~/odin_gpu_ws/src
cd ~/odin_gpu_ws/src
git clone https://github.com/chaeoi/odincuda.git odin_ros_driver
cd odin_ros_driver
./script/build_ros2.sh
```

ROS2 构建脚本会临时使用 `package_ros2.xml` 完成 colcon 构建，结束后恢复 ROS1
清单文件。

## CUDA 自检

ROS1：

```bash
cd ~/odin_gpu_ws
./devel/lib/odin_ros_driver/odin_cuda_smoke_test
```

ROS2：

```bash
cd ~/odin_gpu_ws
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
cd ~/odin_gpu_ws
source devel/setup.bash
roslaunch odin_ros_driver odin1_ros1_gpu.launch
```

ROS2：

```bash
cd ~/odin_gpu_ws
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

## 实机结果

ROS2 + CUDA 默认配置已完成全量编译、CUDA 自检和接入相机测试。驱动内部统计的
RGB、DTOF 接收频率稳定在约 `10.2 Hz`，去畸变图和深度图均能收到有效消息。

同一环境下，优化前记录为主驱动约 `81.3% CPU`、深度节点约 `25.5% CPU`；当前
20 秒采样为主驱动约 `72.5% CPU`、深度节点约 `3.9%`，深度节点重复采样范围为
`3.9%` 至 `5.3%`。两进程合计 CPU 约降低 `27%` 至 `28%`。GPU 12 秒采样平均
约 `8.9%`、峰值 `22%`，表现为每帧短时间工作。数值会随功耗模式、订阅者和系统
负载变化。

## 已验证环境

- Ubuntu 20.04、ROS1 Noetic、CUDA 11.4、OpenCV 4.5.4、Jetson AGX Orin（`aarch64`）
- Ubuntu 22.04、ROS2 Humble、CUDA 12.6、OpenCV 4.5.4、Jetson AGX Orin（`aarch64`）

完整安装、编译和使用步骤见 [DEPLOYMENT.md](DEPLOYMENT.md)。
