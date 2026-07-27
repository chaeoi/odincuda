# 安装与使用

本文记录 2026-07-27 的实际安装过程，并给出从零部署 Odin 相机 ROS 驱动的步骤。
示例以 Jetson AGX Orin、Ubuntu 22.04、ROS2 Humble、CUDA 12.6 为主。

## 一、安装记录

测试环境原有配置：

- Ubuntu 22.04，`aarch64`
- ROS2 Humble
- CUDA 12.6，安装目录为 `/usr/local/cuda-12.6`
- OpenCV 4.5.4
- 相机可通过 `lsusb` 识别为 `2207:0019`

本次实际执行的依赖安装命令：

```bash
sudo apt-get update
sudo apt-get install -y \
  libopencv-dev \
  libpcl-dev \
  libusb-1.0-0-dev \
  ros-humble-cv-bridge \
  ros-humble-image-transport \
  ros-humble-pcl-conversions \
  ros-humble-ament-index-cpp
```

`libpcl-dev` 会同时安装 Boost、VTK、OpenNI 等较多依赖，下载和安装耗时较长属于正常现象。

实机启用了 NVIDIA 软件源，第一次安装时 `libopencv-dev` 被选为 4.8.0，但该包缺少
对应的版本化链接库，而且 ROS2 Humble 的 `cv_bridge` 使用 OpenCV 4.5.4。实际通过
以下命令统一到 Ubuntu 22.04 的 OpenCV 4.5.4 后编译成功：

```bash
sudo apt-get install -y --allow-downgrades \
  libopencv-dev=4.5.4+dfsg-9ubuntu4
```

执行下面命令应输出 `4.5.4`：

```bash
pkg-config --modversion opencv4
```

## 二、部署前检查

1. 确认 ROS2：

   ```bash
   source /opt/ros/humble/setup.bash
   echo "$ROS_DISTRO"
   ```

   应输出 `humble`。

2. 确认 CUDA：

   ```bash
   /usr/local/cuda/bin/nvcc --version
   ```

3. 插入相机并确认 USB：

   ```bash
   lsusb | grep 2207:0019
   ```

   能看到设备才继续。如果普通用户没有 USB 权限，先确认自己属于 `plugdev` 组：

   ```bash
   groups
   ```

## 三、下载代码

以下目录名不要随意修改，构建脚本会从目录结构中找到工作空间：

```bash
mkdir -p ~/odin_gpu_ws/src
cd ~/odin_gpu_ws/src
git clone https://github.com/chaeoi/odincuda.git odin_ros_driver
```

## 四、放入相机标定文件

标定文件与具体相机绑定，不在公开仓库中。将当前相机的 `calib.yaml` 放到：

```text
~/odin_gpu_ws/src/odin_ros_driver/config/calib.yaml
```

确认文件存在：

```bash
test -f ~/odin_gpu_ws/src/odin_ros_driver/config/calib.yaml && echo "标定文件已就绪"
```

## 五、确认默认配置

仓库默认只发布当前使用所需的去畸变图、原始 DTOF 点云和深度图。先确认关键开关：

```bash
cd ~/odin_gpu_ws/src/odin_ros_driver
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

默认不发布里程计话题，但保留导航需要的 `odom -> odin1_base_link` TF。需要 IMU、
里程计话题或原始 RGB 时，将对应开关改为 `1` 后重新启动驱动即可。需要彩色深度点云
时，同时设置 `senddepthcloud: 1` 和 `sendrgb: 1`。

## 六、编译 ROS2 GPU 版本

```bash
cd ~/odin_gpu_ws/src/odin_ros_driver
export PATH=/usr/local/cuda/bin:$PATH
./script/build_ros2.sh
```

看到 `ROS2 build successful` 表示编译完成。脚本会临时切换到 ROS2 包清单，结束时自动恢复原文件。

## 七、先做 CUDA 自检

自检不需要连接相机：

```bash
cd ~/odin_gpu_ws
source /opt/ros/humble/setup.bash
source install/setup.bash
ros2 run odin_ros_driver odin_cuda_smoke_test
```

正常结果包含：

```text
CUDA smoke test passed
```

如果自检失败，不要继续启动相机节点，先检查 CUDA 驱动、CUDA Toolkit 和编译架构。

## 八、启动相机

确保没有另一份 CPU 或 GPU 驱动正在占用同一台相机，然后执行：

```bash
cd ~/odin_gpu_ws
source /opt/ros/humble/setup.bash
source install/setup.bash
ros2 launch odin_ros_driver odin1_ros2_gpu.launch.py
```

这个 launch 默认只启动相机主驱动和 GPU 深度节点，不启动重投影和图像叠加节点，以降低 CPU 使用率。

## 九、确认数据正常

保持相机启动终端不动，另开一个终端：

```bash
cd ~/odin_gpu_ws
source /opt/ros/humble/setup.bash
source install/setup.bash
ros2 node list
ros2 topic list
```

先各取一条消息，确认去畸变图和深度图都在发布：

```bash
ros2 topic echo /odin1/image/undistorted --once --field header
ros2 topic echo /odin1/depth_img_competetion --once --field header
```

大分辨率深度图和点云会让 Python 实现的 `ros2 topic hz` 本身产生较高反序列化
开销，显示值可能低于驱动实际接收频率。需要检查时可短时间执行：

```bash
ros2 topic hz /odin1/image/undistorted
```

按 `Ctrl+C` 停止频率统计。回到启动终端按 `Ctrl+C`，即可安全停止驱动。

## 十、按需开启额外处理

只有确实需要时才开启重投影和图像叠加，因为它们会增加 CPU 占用：

```bash
ros2 launch odin_ros_driver odin1_ros2_gpu.launch.py \
  enable_reprojection:=true enable_overlay:=true
```

## 十一、ROS1 使用方法

ROS1 Noetic 环境使用同一份源码：

```bash
mkdir -p ~/odin_gpu_ws/src
cd ~/odin_gpu_ws/src
git clone https://github.com/chaeoi/odincuda.git odin_ros_driver
cd ..
source /opt/ros/noetic/setup.bash
catkin_make -DODIN_BUILD_CUDA=ON -DODIN_CUDA_ARCH=87
./devel/lib/odin_ros_driver/odin_cuda_smoke_test
source devel/setup.bash
roslaunch odin_ros_driver odin1_ros1_gpu.launch
```

同样需要提前把相机对应的标定文件放到 `config/calib.yaml`。

## 十二、常见问题

### 找不到 `nvcc`

```bash
export PATH=/usr/local/cuda/bin:$PATH
```

### 找不到 `calib.yaml`

确认文件位于源码目录的 `config/calib.yaml`，然后重新编译，使其安装到 ROS2 工作空间。

### 相机启动失败或 USB 被占用

```bash
ps -ef | grep -E 'host_sdk_sample|pcd2depth' | grep -v grep
```

先正常停止已有驱动，再启动 GPU 版本。不要同时运行 CPU 和 GPU 主驱动。

### 需要重新完整编译

```bash
cd ~/odin_gpu_ws/src/odin_ros_driver
./script/build_ros2.sh --clean
./script/build_ros2.sh
```

## 十三、实机验证结果

### ROS2 + CUDA 12.6

- 上述依赖命令已实际执行，OpenCV 统一到 4.5.4 后 ROS2 CUDA 全量编译成功。
- `odin_cuda_smoke_test` 连续执行两次均通过，输出为：

  ```text
  CUDA smoke test passed: remap=192 bytes, rendered_points=3, positive_depth_pixels=3, depth_cloud_points=1, depth_only_pixels=64
  ```

- 连接相机后，GPU launch 正常启动以下 3 个 ROS2 节点，未出现重复节点：

  ```text
  /host_sdk_sample_gpu
  /pcd2depth_ros2_node_gpu
  /depth_image_ros2_node
  ```

- 驱动内部连续统计的 RGB、DTOF 发送和接收频率均稳定在约 `10.2 Hz`；
  `/odin1/image/undistorted` 和 `/odin1/depth_img_competetion` 均已实际取得消息。
- 原始 RGB、压缩 RGB 和渲染点云在默认配置下没有数据发布；彩色深度点云发布器
  不创建，深度节点也不再订阅 RGB 或执行颜色映射。
- 运行日志中没有 CUDA 回退或非对齐访问错误。最终配置的 `tegrastats` 12 秒采样为
  GPU 平均约 `8.9%`、峰值 `22%`，确认相机数据进入 GPU 路径。
- 优化前同环境记录为主驱动约 `81.3% CPU`、GPU 深度节点约 `25.5% CPU`。
  最终默认配置 20 秒采样为主驱动约 `72.5% CPU`、深度节点约 `3.9% CPU`；
  深度节点重复采样范围为 `3.9%` 至 `5.3%`，两进程合计 CPU 约降低 `27%` 至
  `28%`。厂商 SDK、JPEG 解码和 ROS 消息发布仍使用 CPU，数值会随功耗模式、
  订阅者和系统负载波动。
- `devstatuslog` 和设备日志关闭时不再创建 `Conn_*` 目录或空 CSV 文件。
- 启动前后标定文件 SHA-256 保持不变；驱动会优先使用有效的现有标定，不再覆盖它。
- 多轮启动、发布和停止均成功，停止后无驱动进程残留，可立即重新启动相机。

### ROS1 + CUDA 11.4

- ROS1 Noetic 的 CUDA 版本使用 `sm_87` 实际编译成功。
- `odin_cuda_smoke_test` 连续执行两次均通过。
- 未替换正在运行的 CPU 驱动，避免影响现有使用；正式切换时先停止 CPU 版本，再启动本项目的 GPU launch。
