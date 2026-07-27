import os

import yaml
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.conditions import IfCondition
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    package_dir = get_package_share_directory("odin_ros_driver")
    control_path = os.path.join(package_dir, "config", "control_command.yaml")
    calib_path = os.path.join(package_dir, "config", "calib.yaml")

    with open(control_path, "r", encoding="utf-8") as config_file:
        control_params = yaml.safe_load(config_file)

    depth_params = dict(control_params)
    depth_params["calib_file_path"] = calib_path
    reprojection_params = dict(control_params)
    reprojection_params["calib_file_path"] = calib_path

    enable_reprojection = LaunchConfiguration("enable_reprojection")
    enable_overlay = LaunchConfiguration("enable_overlay")

    return LaunchDescription([
        DeclareLaunchArgument("enable_reprojection", default_value="false"),
        DeclareLaunchArgument("enable_overlay", default_value="false"),
        Node(
            package="odin_ros_driver",
            executable="host_sdk_sample_gpu",
            name="host_sdk_sample_gpu",
            output="screen",
            parameters=[{"config_file": control_path}],
        ),
        Node(
            package="odin_ros_driver",
            executable="pcd2depth_ros2_node_gpu",
            name="pcd2depth_ros2_node_gpu",
            output="screen",
            parameters=[depth_params],
        ),
        Node(
            package="odin_ros_driver",
            executable="cloud_reprojection_ros2_node",
            name="cloud_reprojection_node_gpu_stack",
            output="screen",
            parameters=[reprojection_params],
            condition=IfCondition(enable_reprojection),
        ),
        Node(
            package="odin_ros_driver",
            executable="image_overlay_node",
            name="image_overlay_node_gpu_stack",
            output="screen",
            parameters=[control_params],
            condition=IfCondition(enable_overlay),
        ),
    ])
