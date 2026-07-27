#include "odin_cuda_ops.hpp"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <numeric>
#include <string>
#include <vector>

namespace
{

void setIdentity(float *matrix)
{
    std::fill(matrix, matrix + 16, 0.0f);
    matrix[0] = 1.0f;
    matrix[5] = 1.0f;
    matrix[10] = 1.0f;
    matrix[15] = 1.0f;
}

} // namespace

int main()
{
    constexpr int width = 8;
    constexpr int height = 8;
    std::vector<std::uint8_t> image(width * height * 3);
    std::iota(image.begin(), image.end(), static_cast<std::uint8_t>(0));
    std::vector<float> map_x(width * height);
    std::vector<float> map_y(width * height);
    for (int y = 0; y < height; ++y)
    {
        for (int x = 0; x < width; ++x)
        {
            map_x[y * width + x] = static_cast<float>(x);
            map_y[y * width + x] = static_cast<float>(y);
        }
    }

    std::string error;
    std::vector<std::uint8_t> remapped(image.size());
    if (!odin_cuda::remapBgr(image.data(), width, height, width * 3,
                             map_x.data(), map_y.data(), width,
                             remapped.data(), width * 3, error))
    {
        std::cerr << "remap failed: " << error << std::endl;
        return 1;
    }
    if (!std::equal(image.begin(), image.end(), remapped.begin()))
    {
        std::cerr << "identity remap mismatch" << std::endl;
        return 2;
    }

    struct PointXYZPad { float x, y, z, pad; };
    const std::vector<PointXYZPad> points = {
        {0.10f, 0.05f, 1.0f, 0.0f},
        {-0.10f, 0.05f, 1.0f, 0.0f},
        {0.05f, -0.10f, 1.2f, 0.0f}
    };

    constexpr std::size_t packed_point_step = 19;
    std::vector<std::uint8_t> packed_points(points.size() * packed_point_step, 0);
    for (std::size_t index = 0; index < points.size(); ++index)
    {
        std::uint8_t *destination = packed_points.data() + index * packed_point_step;
        std::memcpy(destination, &points[index].x, sizeof(float));
        std::memcpy(destination + sizeof(float), &points[index].y, sizeof(float));
        std::memcpy(destination + 2 * sizeof(float), &points[index].z, sizeof(float));
    }

    odin_cuda::RawRenderParams render_params;
    render_params.image_width = width;
    render_params.image_height = height;
    render_params.fx = 10.0f;
    render_params.fy = 10.0f;
    render_params.cx = 4.0f;
    render_params.cy = 4.0f;
    setIdentity(render_params.camera_from_lidar);

    std::vector<float> rendered_cloud;
    error.clear();
    if (!odin_cuda::renderColoredCloud(
            packed_points.data(), points.size(), packed_point_step,
            0, sizeof(float), 2 * sizeof(float),
            image.data(), width, height, width * 3, render_params,
            rendered_cloud, error))
    {
        std::cerr << "colored cloud failed: " << error << std::endl;
        return 3;
    }
    if (rendered_cloud.size() != points.size() * 4)
    {
        std::cerr << "colored cloud returned " << rendered_cloud.size() / 4
                  << " points, expected " << points.size() << std::endl;
        return 4;
    }

    odin_cuda::DepthParams depth_params;
    depth_params.scaled_width = width;
    depth_params.scaled_height = height;
    depth_params.image_width = width;
    depth_params.image_height = height;
    depth_params.point_sampling_rate = 2;
    depth_params.A11 = 10.0f;
    depth_params.A22 = 10.0f;
    depth_params.u0 = 4.0f;
    depth_params.v0 = 4.0f;
    setIdentity(depth_params.Kcl);
    setIdentity(depth_params.Tlc);
    depth_params.Kcl[0] = 10.0f;
    depth_params.Kcl[3] = 4.0f;
    depth_params.Kcl[5] = 10.0f;
    depth_params.Kcl[7] = 4.0f;

    std::vector<float> depth(width * height);
    std::vector<float> depth_cloud;
    error.clear();
    if (!odin_cuda::processDepth(
            reinterpret_cast<const float *>(points.data()), points.size(), 4,
            image.data(), width, height, width * 3,
            map_x.data(), map_y.data(), width,
            depth_params, true, depth.data(), depth.size(), depth_cloud, error))
    {
        std::cerr << "depth pipeline failed: " << error << std::endl;
        return 5;
    }
    const auto positive_depth = std::count_if(depth.begin(), depth.end(),
        [](float value) { return value > 0.0f; });
    if (depth.size() != width * height || positive_depth == 0)
    {
        std::cerr << "depth pipeline produced no valid depth" << std::endl;
        return 6;
    }

    std::vector<float> depth_only(width * height);
    std::vector<float> unused_depth_cloud{1.0f};
    error.clear();
    if (!odin_cuda::processDepth(
            reinterpret_cast<const float *>(points.data()), points.size(), 4,
            nullptr, 0, 0, 0, nullptr, nullptr, 0,
            depth_params, false, depth_only.data(), depth_only.size(), unused_depth_cloud, error))
    {
        std::cerr << "depth-only pipeline failed: " << error << std::endl;
        return 7;
    }
    if (depth_only.size() != depth.size() || !unused_depth_cloud.empty())
    {
        std::cerr << "depth-only pipeline returned unexpected output" << std::endl;
        return 8;
    }

    std::cout << "CUDA smoke test passed: remap=" << remapped.size()
              << " bytes, rendered_points=" << rendered_cloud.size() / 4
              << ", positive_depth_pixels=" << positive_depth
              << ", depth_cloud_points=" << depth_cloud.size() / 4
              << ", depth_only_pixels=" << depth_only.size() << std::endl;
    return 0;
}
