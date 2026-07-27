# 安装与使用

本文记录 2026-07-27 的实际安装过程，并给出从零部署 Odin 相机 ROS 驱动的步骤。
示例覆盖 Jetson AGX Orin 上的 ROS1 Noetic 和 ROS2 Humble。

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

ROS1 Noetic + CUDA 11.4 的干净编译测试中，系统原有运行版缺少三个开发依赖。本次
实际补装命令如下：

```bash
sudo apt-get install -y \
  ros-noetic-nav-msgs \
  ros-noetic-visualization-msgs \
  ros-noetic-tf2-geometry-msgs
```

仓库的 `package.xml` 和 CMake 已补齐 ROS1 直接依赖声明，新环境也可在工作空间根目录
使用以下命令自动安装缺失依赖：

```bash
rosdep install --from-paths src --ignore-src -r -y
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
mkdir -p ~/odincuda/src
cd ~/odincuda/src
git clone https://github.com/chaeoi/odincuda.git odin_ros_driver
```

## 四、放入相机标定文件

标定文件与具体相机绑定，不在公开仓库中。将当前相机的 `calib.yaml` 放到：

```text
~/odincuda/src/odin_ros_driver/config/calib.yaml
```

确认文件存在：

```bash
test -f ~/odincuda/src/odin_ros_driver/config/calib.yaml && echo "标定文件已就绪"
```

## 五、确认默认配置

仓库默认只发布当前使用所需的去畸变图、原始 DTOF 点云和深度图。先确认关键开关：

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

默认不发布里程计话题，但保留导航需要的 `odom -> odin1_base_link` TF。需要 IMU、
里程计话题或原始 RGB 时，将对应开关改为 `1` 后重新启动驱动即可。需要彩色深度点云
时，同时设置 `senddepthcloud: 1` 和 `sendrgb: 1`。

## 六、编译 ROS2 GPU 版本

```bash
cd ~/odincuda/src/odin_ros_driver
export PATH=/usr/local/cuda/bin:$PATH
./script/build_ros2.sh
```

看到 `ROS2 build successful` 表示编译完成。脚本会临时切换到 ROS2 包清单，结束时自动恢复原文件。

## 七、先做 CUDA 自检

自检不需要连接相机：

```bash
cd ~/odincuda
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
cd ~/odincuda
source /opt/ros/humble/setup.bash
source install/setup.bash
ros2 launch odin_ros_driver odin1_ros2_gpu.launch.py
```

这个 launch 默认只启动相机主驱动和 GPU 深度节点，不启动重投影和图像叠加节点，以降低 CPU 使用率。

## 九、确认数据正常

保持相机启动终端不动，另开一个终端：

```bash
cd ~/odincuda
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
sudo apt-get update
sudo apt-get install -y python3-rosdep libopencv-dev libpcl-dev libusb-1.0-0-dev
mkdir -p ~/odincuda/src
cd ~/odincuda/src
git clone https://github.com/chaeoi/odincuda.git odin_ros_driver
cd ..
source /opt/ros/noetic/setup.bash
sudo rosdep init 2>/dev/null || true
rosdep update
rosdep install --from-paths src --ignore-src -r -y
catkin_make -DCMAKE_BUILD_TYPE=Release -DODIN_BUILD_CUDA=ON -DODIN_CUDA_ARCH=87
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
cd ~/odincuda/src/odin_ros_driver
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

- ROS1 Noetic 的 CPU 基线副本和 CUDA `sm_87` 优化版均从独立工作空间完整编译成功，
  `odin_cuda_smoke_test` 通过。
- 去畸变图和深度图实测均约 `10.25 Hz`；`/tf` 包含
  `odom -> odin1_base_link`，导航节点已与该 TF 建立连接。
- 感知节点实际连接 `/odin1/image/undistorted` 和
  `/odin1/depth_img_competetion`，识别请求能够返回；目标内容是否有效属于下游识别，
  不计入本次驱动验证。
- 优化配置下连续 3 秒未收到 IMU 或里程计话题数据，确认仅保留导航需要的 TF。
- CPU 使用 `top` 每秒采样一次，丢弃首个累计值后统计连续 20 个样本；`100% CPU`
  表示占满一个逻辑核。表中的总计是同一采样窗口内各进程平均值之和，不叠加各进程
  出现在不同时刻的峰值。

#### 仅相机驱动栈 CPU

| 进程 | 优化前平均 | 优化前峰值 | 优化后平均 | 优化后峰值 | 平均值变化 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 相机主驱动 | `165.1%` | `176.0%` | `57.9%` | `61.0%` | 降低 `64.9%` |
| 深度节点 | `157.3%` | `172.0%` | `10.6%` | `12.0%` | 降低 `93.2%` |
| 图像叠加节点 | `6.3%` | `7.9%` | 未启动 | 未启动 | 已移除 |
| 总计 | `328.7%` | - | `68.5%` | - | 降低 `79.2%` |

#### 相机、识别和导航完整链路 CPU

| 进程 | 优化前平均 | 优化前峰值 | 优化后平均 | 优化后峰值 | 平均值变化 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 相机主驱动 | `160.2%` | `177.0%` | `62.1%` | `67.0%` | 降低 `61.2%` |
| 深度节点 | `153.4%` | `176.0%` | `19.2%` | `21.0%` | 降低 `87.5%` |
| 图像叠加节点 | `5.7%` | `7.0%` | 未启动 | 未启动 | 已移除 |
| 感知识别节点 | `19.7%` | `25.0%` | `25.9%` | `28.0%` | 增加 `31.4%` |
| 导航节点 | `0.7%` | `2.0%` | `0.7%` | `2.0%` | 持平 |
| 总计 | `339.7%` | - | `107.9%` | - | 降低 `68.2%` |

完整链路 CPU 总计降低 `68.2%`。只计算相机主驱动、深度和叠加节点时，相机相关
进程从 `319.3%` 降到 `81.3%`，降低约 `74.5%`。

#### 为什么完整链路的增量不同

导航节点本身在优化前后都只有约 `0.7% CPU`，明显差异来自感知订阅和原配置的基础
负载，不是导航计算：

| 增量来源 | 优化前 | 优化后 |
| --- | ---: | ---: |
| 相机相关进程变化 | `-9.4%` | `+12.8%` |
| 新增感知节点 | `+19.7%` | `+25.9%` |
| 新增导航节点 | `+0.7%` | `+0.7%` |
| 完整链路相对仅驱动净增 | `+11.0%` | `+39.4%` |

优化前配置即使没有感知订阅者，也会计算原始 RGB、SLAM 点云、渲染点云、彩色深度
点云和图像叠加等输出，基础负载已经达到 `328.7% CPU`。接入感知增加的约 `20.4%`
被 20 秒采样中的线程调度和运行波动抵消了约 `9.4%`，所以总数只净增 `11.0%`。

优化后基础计算已经精简到 `68.5% CPU`。感知节点连接后，主驱动必须实际序列化并
发送约 `1600 x 1296 x 3` 字节的去畸变图，深度节点必须发送约
`1600 x 1296 x 4` 字节的浮点深度图。按 10 Hz 计算，两路未压缩载荷分别约为
`59 MiB/s` 和 `79 MiB/s`，还包含 ROS1 TCPROS 的本机内存拷贝及 Python 端反序列化。
因此主驱动从 `57.9%` 升至 `62.1%`，深度节点从 `10.6%` 升至 `19.2%`，合计增加
`12.8%`；再加感知 `25.9%` 和导航 `0.7%`，得到约 `39.4%` 的完整增量。

所以评估实际部署应以完整链路的 `107.9% CPU` 为准；仅驱动的 `68.5%` 用于观察
驱动和 CUDA 深度计算本身。即使加入订阅传输开销，完整链路相对优化前仍降低 `68.2%`。

#### GPU 占用

GPU 使用 `tegrastats` 记录。由于优化前使用了 1 秒采样，优化后为捕捉逐帧 CUDA
脉冲改用 100 ms 采样，以下表格同时保留采样条件，避免误读：

| 场景 | 版本 | 采样间隔 | 样本数 | GPU 平均 | GPU 峰值 | 说明 |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| 仅相机驱动栈 | 优化前 CPU 版 | `1000 ms` | `20` | `0%` | `0%` | 驱动不使用 CUDA |
| 仅相机驱动栈 | 优化后 CUDA 版 | `100 ms` | `193` | `7.80%` | `39%` | 每帧短时使用 GPU |
| 完整链路 | 优化前 CPU 版 | `1000 ms` | `20` | `0%`（见说明） | `0%`（见说明） | 采样过慢，漏掉 TensorRT 脉冲 |
| 完整链路 | 优化后 CUDA 版 | `100 ms` | `193` | `6.87%` | `22%` | CUDA 深度与 TensorRT 共同运行 |

说明：优化前完整链路中的感知节点使用 TensorRT，`0%` 只表示 1 秒采样点没有撞上短时
GPU 工作，不能解释为感知未使用 GPU，也不能作为严格的峰值对照。此前短间隔观察曾
捕捉到 TensorRT 瞬时峰值约 `73%`，但不属于本次同一采样窗口，因此单独记录、不纳入
上表的 A/B 计算。

- 以上是现有 CPU 部署配置与面向当前下游需求的 CUDA 默认配置对比，收益包含 CUDA
  加速，以及关闭原始 RGB、IMU、SLAM 点云、渲染点云、彩色深度点云、状态 CSV、
  重投影和图像叠加。它不是只改变 CPU/GPU 后端的单变量测试。
- 测试全程未在原驱动工作空间内编译或启动。测试前后的原代码 HEAD、Git 差异哈希和
  标定文件 SHA-256 均一致；停止后没有 ROS 或相机驱动进程残留。
