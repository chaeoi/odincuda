import os

import yaml
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def get_odin_runtime_dir():
    custom = os.environ.get("ODIN_CALIB_DIR")
    if custom:
        return custom
    ros_home = os.environ.get("ROS_HOME")
    if ros_home:
        return os.path.join(ros_home, "odin_ros_driver")
    home = os.environ.get("HOME")
    if home:
        return os.path.join(home, ".ros", "odin_ros_driver")
    return "/tmp/odin_ros_driver"


def generate_launch_description():
    package_dir = get_package_share_directory("odin_ros_driver")
    control_path = os.path.join(package_dir, "config", "control_command.yaml")
    calib_path = os.path.join(get_odin_runtime_dir(), "calib.yaml")

    with open(control_path, "r", encoding="utf-8") as config_file:
        control_params = yaml.safe_load(config_file)

    depth_params = dict(control_params)
    depth_params["calib_file_path"] = calib_path
    reprojection_params = dict(control_params)
    reprojection_params["calib_file_path"] = calib_path

    return LaunchDescription([
        DeclareLaunchArgument(
            "rviz_config",
            default_value=os.path.join(package_dir, "config", "odin_ros2.rviz"),
        ),
        Node(
            package="odin_ros_driver",
            executable="host_sdk_sample",
            name="host_sdk_sample",
            output="screen",
            parameters=[{"config_file": control_path}],
        ),
        Node(
            package="odin_ros_driver",
            executable="pcd2depth_ros2_node",
            name="pcd2depth_ros2_node",
            output="screen",
            parameters=[depth_params],
        ),
        Node(
            package="odin_ros_driver",
            executable="cloud_reprojection_ros2_node",
            name="cloud_reprojection_ros2_node",
            output="screen",
            parameters=[reprojection_params],
        ),
        Node(
            package="odin_ros_driver",
            executable="image_overlay_node",
            name="image_overlay_node",
            output="screen",
            parameters=[control_params],
        ),
        Node(
            package="rviz2",
            executable="rviz2",
            name="rviz2",
            output="screen",
            arguments=["-d", LaunchConfiguration("rviz_config")],
        ),
    ])
