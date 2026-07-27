#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace odin_cuda
{

struct DepthParams
{
    int scaled_width = 0;
    int scaled_height = 0;
    int image_width = 0;
    int image_height = 0;
    int point_sampling_rate = 1;
    float A11 = 0.0f;
    float A12 = 0.0f;
    float A22 = 0.0f;
    float u0 = 0.0f;
    float v0 = 0.0f;
    float Kcl[16]{};
    float Tlc[16]{};
};

struct RawRenderParams
{
    int image_width = 0;
    int image_height = 0;
    float fx = 0.0f;
    float fy = 0.0f;
    float cx = 0.0f;
    float cy = 0.0f;
    float skew = 0.0f;
    float k2 = 0.0f;
    float k3 = 0.0f;
    float k4 = 0.0f;
    float k5 = 0.0f;
    float k6 = 0.0f;
    float k7 = 0.0f;
    float camera_from_lidar[16]{};
};

bool processDepth(
    const float *cloud,
    std::size_t point_count,
    std::size_t point_stride_floats,
    const std::uint8_t *bgr,
    int color_width,
    int color_height,
    std::size_t color_step_bytes,
    const float *inverse_map_x,
    const float *inverse_map_y,
    std::size_t map_step_floats,
    const DepthParams &params,
    std::vector<float> &depth,
    std::vector<float> &colored_cloud_xyzw,
    std::string &error);

bool renderColoredCloud(
    const std::uint8_t *cloud_data,
    std::size_t point_count,
    std::size_t point_step_bytes,
    std::size_t x_offset,
    std::size_t y_offset,
    std::size_t z_offset,
    const std::uint8_t *bgr,
    int image_width,
    int image_height,
    std::size_t image_step_bytes,
    const RawRenderParams &params,
    std::vector<float> &colored_cloud_xyzw,
    std::string &error);

bool remapBgr(
    const std::uint8_t *source,
    int width,
    int height,
    std::size_t source_step_bytes,
    const float *map_x,
    const float *map_y,
    std::size_t map_step_floats,
    std::uint8_t *destination,
    std::size_t destination_step_bytes,
    std::string &error);

} // namespace odin_cuda
