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

ROS1 + CUDA 11.4 已完成干净编译、CUDA 自检、接入相机及识别导航链路测试。
去畸变图和深度图均稳定在约 `10.25 Hz`，导航节点能收到
`odom -> odin1_base_link` TF；默认关闭的 IMU 和里程计话题没有数据。

同一环境、同一相机下使用 `top` 进行 20 秒采样，`100% CPU` 表示占满一个逻辑核：

| 场景 | 现有 CPU 部署 | CUDA 默认配置 | 降幅 |
| --- | ---: | ---: | ---: |
| 仅相机驱动栈 | `328.7%` | `68.5%` | `79.2%` |
| 相机 + 识别 + 导航 | `339.7%` | `107.9%` | `68.2%` |

CUDA 驱动栈的 100 ms GPU 采样平均约 `7.8%`、峰值 `39%`。这里比较的是现有 CPU
部署配置与面向当前下游需求的 CUDA 默认配置，降幅同时来自 CUDA 加速和关闭未使用的
原始 RGB、IMU、点云及后处理链路，不是只替换计算后端的单变量对照。ROS2 环境也已
完成编译、CUDA 自检和相机测试，详细记录见 [DEPLOYMENT.md](DEPLOYMENT.md)。

## 已验证环境

- Ubuntu 20.04、ROS1 Noetic、CUDA 11.4、OpenCV 4.5.4、Jetson AGX Orin（`aarch64`）
- Ubuntu 22.04、ROS2 Humble、CUDA 12.6、OpenCV 4.5.4、Jetson AGX Orin（`aarch64`）

完整安装、编译和使用步骤见 [DEPLOYMENT.md](DEPLOYMENT.md)。
