#include "odin_cuda_ops.hpp"

#include <cuda_runtime.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <sstream>

namespace odin_cuda
{
namespace
{

constexpr int kThreads = 256;

template <typename T>
class DeviceBuffer
{
public:
    ~DeviceBuffer()
    {
        if (data_ != nullptr)
            cudaFree(data_);
    }

    bool ensure(std::size_t count)
    {
        if (count <= capacity_)
            return true;
        if (data_ != nullptr)
            cudaFree(data_);
        data_ = nullptr;
        capacity_ = 0;
        if (cudaMalloc(reinterpret_cast<void **>(&data_), count * sizeof(T)) != cudaSuccess)
            return false;
        capacity_ = count;
        return true;
    }

    T *get() { return data_; }
    const T *get() const { return data_; }

private:
    T *data_ = nullptr;
    std::size_t capacity_ = 0;
};

struct DevicePoint
{
    float x;
    float y;
    float z;
    float rgb;
};

struct DepthContext
{
    std::mutex mutex;
    DeviceBuffer<std::uint8_t> cloud;
    DeviceBuffer<std::uint8_t> image;
    DeviceBuffer<float> map_x;
    DeviceBuffer<float> map_y;
    DeviceBuffer<std::uint8_t> remapped;
    DeviceBuffer<std::uint32_t> scaled_depth;
    DeviceBuffer<float> depth;
    DeviceBuffer<DevicePoint> colored;
    DeviceBuffer<float> matrices;
    const float *last_map_x = nullptr;
    const float *last_map_y = nullptr;
    int last_map_width = 0;
    int last_map_height = 0;
};

struct RenderContext
{
    std::mutex mutex;
    DeviceBuffer<std::uint8_t> cloud;
    DeviceBuffer<std::uint8_t> image;
    DeviceBuffer<DevicePoint> output;
    DeviceBuffer<std::uint32_t> output_count;
};

struct RemapContext
{
    std::mutex mutex;
    DeviceBuffer<std::uint8_t> source;
    DeviceBuffer<std::uint8_t> destination;
    DeviceBuffer<float> map_x;
    DeviceBuffer<float> map_y;
    const float *last_map_x = nullptr;
    const float *last_map_y = nullptr;
    int last_width = 0;
    int last_height = 0;
};

DepthContext &depthContext()
{
    static DepthContext context;
    return context;
}

RenderContext &renderContext()
{
    static RenderContext context;
    return context;
}

RemapContext &remapContext()
{
    static RemapContext context;
    return context;
}

bool checkCuda(cudaError_t status, const char *operation, std::string &error)
{
    if (status == cudaSuccess)
        return true;
    std::ostringstream message;
    message << operation << ": " << cudaGetErrorString(status);
    error = message.str();
    return false;
}

__device__ float matrixTransform(const float *matrix, int row, float x, float y, float z)
{
    const int base = row * 4;
    return matrix[base] * x + matrix[base + 1] * y + matrix[base + 2] * z + matrix[base + 3];
}

__device__ float loadUnalignedFloat(const std::uint8_t *data)
{
    const std::uint32_t bits = static_cast<std::uint32_t>(data[0]) |
                               (static_cast<std::uint32_t>(data[1]) << 8) |
                               (static_cast<std::uint32_t>(data[2]) << 16) |
                               (static_cast<std::uint32_t>(data[3]) << 24);
    return __uint_as_float(bits);
}

__global__ void initializeDepth(std::uint32_t *depth, int count)
{
    const int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < count)
        depth[index] = 0xffffffffu;
}

__global__ void projectDepth(
    const std::uint8_t *cloud,
    int point_count,
    int point_stride_bytes,
    const float *Kcl,
    int width,
    int height,
    std::uint32_t *depth)
{
    const int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index >= point_count)
        return;

    const std::uint8_t *point = cloud + static_cast<std::size_t>(index) * point_stride_bytes;
    const float x = loadUnalignedFloat(point);
    const float y = loadUnalignedFloat(point + sizeof(float));
    const float z = loadUnalignedFloat(point + 2 * sizeof(float));
    if (!isfinite(x) || !isfinite(y) || !isfinite(z))
        return;

    const float projected_x = matrixTransform(Kcl, 0, x, y, z);
    const float projected_y = matrixTransform(Kcl, 1, x, y, z);
    const float projected_z = matrixTransform(Kcl, 2, x, y, z);
    if (!(projected_z > 0.0f) || !isfinite(projected_z))
        return;

    const int u = __float2int_rn(projected_x / projected_z);
    const int v = __float2int_rn(projected_y / projected_z);
    if (u < 0 || u >= width || v < 0 || v >= height)
        return;

    const std::uint32_t depth_bits = __float_as_uint(projected_z);
    for (int dv = -1; dv <= 1; ++dv)
    {
        const int pixel_y = v + dv;
        if (pixel_y < 0 || pixel_y >= height)
            continue;
        for (int du = -1; du <= 1; ++du)
        {
            const int pixel_x = u + du;
            if (pixel_x >= 0 && pixel_x < width)
                atomicMin(depth + pixel_y * width + pixel_x, depth_bits);
        }
    }
}

__device__ float scaledDepthAt(
    const std::uint32_t *depth,
    int scaled_width,
    int scaled_height,
    int target_width,
    int target_height,
    int x,
    int y)
{
    if (target_width > 1)
    {
        if (x < 0) x = -x;
        if (x >= target_width) x = 2 * target_width - x - 2;
    }
    else
    {
        x = 0;
    }
    if (target_height > 1)
    {
        if (y < 0) y = -y;
        if (y >= target_height) y = 2 * target_height - y - 2;
    }
    else
    {
        y = 0;
    }
    const int source_x = min(scaled_width - 1, static_cast<int>(x * (scaled_width / static_cast<float>(target_width))));
    const int source_y = min(scaled_height - 1, static_cast<int>(y * (scaled_height / static_cast<float>(target_height))));
    const std::uint32_t bits = depth[source_y * scaled_width + source_x];
    return bits == 0xffffffffu ? 0.0f : __uint_as_float(bits);
}

__global__ void resizeAndFilterDepth(
    const std::uint32_t *scaled_depth,
    int scaled_width,
    int scaled_height,
    float *output,
    int width,
    int height)
{
    const int index = blockIdx.x * blockDim.x + threadIdx.x;
    const int count = width * height;
    if (index >= count)
        return;
    const int x = index % width;
    const int y = index / width;

    const float tl = scaledDepthAt(scaled_depth, scaled_width, scaled_height, width, height, x - 1, y - 1);
    const float tc = scaledDepthAt(scaled_depth, scaled_width, scaled_height, width, height, x, y - 1);
    const float tr = scaledDepthAt(scaled_depth, scaled_width, scaled_height, width, height, x + 1, y - 1);
    const float ml = scaledDepthAt(scaled_depth, scaled_width, scaled_height, width, height, x - 1, y);
    const float mr = scaledDepthAt(scaled_depth, scaled_width, scaled_height, width, height, x + 1, y);
    const float bl = scaledDepthAt(scaled_depth, scaled_width, scaled_height, width, height, x - 1, y + 1);
    const float bc = scaledDepthAt(scaled_depth, scaled_width, scaled_height, width, height, x, y + 1);
    const float br = scaledDepthAt(scaled_depth, scaled_width, scaled_height, width, height, x + 1, y + 1);

    const float gradient_x = (tr + 2.0f * mr + br) - (tl + 2.0f * ml + bl);
    const float gradient_y = (bl + 2.0f * bc + br) - (tl + 2.0f * tc + tr);
    const float magnitude = sqrtf(gradient_x * gradient_x + gradient_y * gradient_y);
    const float center = scaledDepthAt(scaled_depth, scaled_width, scaled_height, width, height, x, y);
    output[index] = magnitude > 0.75f ? 0.0f : center;
}

__device__ std::uint8_t bilinearChannel(
    const std::uint8_t *source,
    int width,
    int height,
    float x,
    float y,
    int channel)
{
    if (!isfinite(x) || !isfinite(y) || x < 0.0f || y < 0.0f ||
        x > width - 1.0f || y > height - 1.0f)
        return 0;
    const int x0 = static_cast<int>(floorf(x));
    const int y0 = static_cast<int>(floorf(y));
    const float dx = x - x0;
    const float dy = y - y0;
    const int row_stride = width * 3;
    const int x1 = min(width - 1, x0 + 1);
    const int y1 = min(height - 1, y0 + 1);
    const float top = source[y0 * row_stride + x0 * 3 + channel] * (1.0f - dx) +
                      source[y0 * row_stride + x1 * 3 + channel] * dx;
    const float bottom = source[y1 * row_stride + x0 * 3 + channel] * (1.0f - dx) +
                         source[y1 * row_stride + x1 * 3 + channel] * dx;
    return static_cast<std::uint8_t>(top * (1.0f - dy) + bottom * dy + 0.5f);
}

__global__ void remapBgrKernel(
    const std::uint8_t *source,
    const float *map_x,
    const float *map_y,
    std::uint8_t *destination,
    int width,
    int height)
{
    const int index = blockIdx.x * blockDim.x + threadIdx.x;
    const int count = width * height;
    if (index >= count)
        return;
    const float source_x = map_x[index];
    const float source_y = map_y[index];
    destination[index * 3] = bilinearChannel(source, width, height, source_x, source_y, 0);
    destination[index * 3 + 1] = bilinearChannel(source, width, height, source_x, source_y, 1);
    destination[index * 3 + 2] = bilinearChannel(source, width, height, source_x, source_y, 2);
}

__global__ void buildColoredCloud(
    const float *depth,
    const std::uint8_t *color,
    int width,
    int height,
    int sampling,
    int samples_x,
    int sample_count,
    float A11,
    float A12,
    float A22,
    float u0,
    float v0,
    const float *Tlc,
    DevicePoint *output)
{
    const int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index >= sample_count)
        return;
    DevicePoint result{};
    result.x = nanf("");
    const int u = (index % samples_x) * sampling;
    const int v = (index / samples_x) * sampling;
    if (u >= width || v >= height)
    {
        output[index] = result;
        return;
    }

    const float z = depth[v * width + u];
    if (!(z > 0.1f && z < 100.0f))
    {
        output[index] = result;
        return;
    }
    const float y = (v - v0) * z / A22;
    const float x = ((u - u0) * z - A12 * y) / A11;
    result.x = matrixTransform(Tlc, 0, x, y, z);
    result.y = matrixTransform(Tlc, 1, x, y, z);
    result.z = matrixTransform(Tlc, 2, x, y, z);
    const std::uint8_t *pixel = color + (v * width + u) * 3;
    const std::uint32_t packed = (static_cast<std::uint32_t>(pixel[2]) << 16) |
                                 (static_cast<std::uint32_t>(pixel[1]) << 8) |
                                 static_cast<std::uint32_t>(pixel[0]);
    result.rgb = __uint_as_float(packed);
    output[index] = result;
}

__global__ void renderColoredCloudKernel(
    const std::uint8_t *cloud,
    int point_count,
    int point_step,
    int x_offset,
    int y_offset,
    int z_offset,
    const std::uint8_t *bgr,
    int image_width,
    int image_height,
    RawRenderParams params,
    DevicePoint *output,
    std::uint32_t *output_count)
{
    const int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index >= point_count)
        return;
    const std::uint8_t *raw = cloud + static_cast<std::size_t>(index) * point_step;
    const float x = loadUnalignedFloat(raw + x_offset);
    const float y = loadUnalignedFloat(raw + y_offset);
    const float z = loadUnalignedFloat(raw + z_offset);
    if (!isfinite(x) || !isfinite(y) || !isfinite(z) ||
        (fabsf(x) < 1e-8f && fabsf(y) < 1e-8f && fabsf(z) < 1e-8f))
        return;

    const float camera_x = matrixTransform(params.camera_from_lidar, 0, x, y, z);
    const float camera_y = matrixTransform(params.camera_from_lidar, 1, x, y, z);
    const float camera_z = matrixTransform(params.camera_from_lidar, 2, x, y, z);
    if (!(camera_z > 0.0f))
        return;

    const float radius = sqrtf(camera_x * camera_x + camera_y * camera_y);
    const float norm = sqrtf(radius * radius + camera_z * camera_z);
    if (!(radius > 1e-7f && norm > 1e-7f))
        return;
    const float theta = acosf(fminf(1.0f, fmaxf(-1.0f, camera_z / norm)));
    const float distorted_theta = theta *
        (1.0f + theta * (params.k2 + theta * (params.k3 + theta *
        (params.k4 + theta * (params.k5 + theta * (params.k6 + theta * params.k7))))));
    const float scale = distorted_theta / radius;
    const float distorted_x = camera_x * scale;
    const float distorted_y = camera_y * scale;
    const int u = static_cast<int>(distorted_x * params.fx + distorted_y * params.skew + params.cx);
    const int v = static_cast<int>(distorted_y * params.fy + params.cy);
    if (u < 0 || u >= image_width || v < 0 || v >= image_height)
        return;

    const std::uint8_t *pixel = bgr + (v * image_width + u) * 3;
    const std::uint32_t packed = (static_cast<std::uint32_t>(pixel[2]) << 16) |
                                 (static_cast<std::uint32_t>(pixel[1]) << 8) |
                                 static_cast<std::uint32_t>(pixel[0]);
    const std::uint32_t output_index = atomicAdd(output_count, 1u);
    output[output_index] = DevicePoint{x, y, z, __uint_as_float(packed)};
}

bool uploadMaps(
    DeviceBuffer<float> &device_x,
    DeviceBuffer<float> &device_y,
    const float *host_x,
    const float *host_y,
    std::size_t host_step_floats,
    int width,
    int height,
    std::string &error)
{
    const std::size_t count = static_cast<std::size_t>(width) * height;
    if (!device_x.ensure(count) || !device_y.ensure(count))
    {
        error = "CUDA map allocation failed";
        return false;
    }
    if (!checkCuda(cudaMemcpy2D(device_x.get(), width * sizeof(float), host_x,
                                host_step_floats * sizeof(float), width * sizeof(float), height,
                                cudaMemcpyHostToDevice), "upload map_x", error))
        return false;
    return checkCuda(cudaMemcpy2D(device_y.get(), width * sizeof(float), host_y,
                                  host_step_floats * sizeof(float), width * sizeof(float), height,
                                  cudaMemcpyHostToDevice), "upload map_y", error);
}

} // namespace

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
    bool generate_colored_cloud,
    float *depth,
    std::size_t depth_capacity,
    std::vector<float> &colored_cloud_xyzw,
    std::string &error)
{
    if (cloud == nullptr || point_count == 0)
    {
        error = "invalid CUDA depth input";
        return false;
    }
    if (generate_colored_cloud &&
        (bgr == nullptr || inverse_map_x == nullptr || inverse_map_y == nullptr ||
         color_width != params.image_width || color_height != params.image_height))
    {
        error = "invalid CUDA colored-depth input";
        return false;
    }

    DepthContext &context = depthContext();
    std::lock_guard<std::mutex> guard(context.mutex);
    const std::size_t cloud_bytes = point_count * point_stride_floats * sizeof(float);
    const std::size_t image_bytes = static_cast<std::size_t>(params.image_width) * params.image_height * 3;
    const std::size_t scaled_count = static_cast<std::size_t>(params.scaled_width) * params.scaled_height;
    const std::size_t pixel_count = static_cast<std::size_t>(params.image_width) * params.image_height;
    if (depth == nullptr || depth_capacity < pixel_count)
    {
        error = "CUDA depth output buffer is too small";
        return false;
    }
    const int sampling = std::max(1, params.point_sampling_rate);
    const int samples_x = (params.image_width + sampling - 1) / sampling;
    const int samples_y = (params.image_height + sampling - 1) / sampling;
    const std::size_t sample_count = static_cast<std::size_t>(samples_x) * samples_y;

    bool buffers_ready = context.cloud.ensure(cloud_bytes) &&
                         context.scaled_depth.ensure(scaled_count) &&
                         context.depth.ensure(pixel_count) &&
                         context.matrices.ensure(32);
    if (generate_colored_cloud)
    {
        buffers_ready = buffers_ready && context.image.ensure(image_bytes) &&
                        context.remapped.ensure(image_bytes) &&
                        context.colored.ensure(sample_count);
    }
    if (!buffers_ready)
    {
        error = "CUDA depth buffer allocation failed";
        return false;
    }
    if (generate_colored_cloud &&
        (context.last_map_x != inverse_map_x || context.last_map_y != inverse_map_y ||
        context.last_map_width != params.image_width || context.last_map_height != params.image_height)
       )
    {
        if (!uploadMaps(context.map_x, context.map_y, inverse_map_x, inverse_map_y,
                        map_step_floats, params.image_width, params.image_height, error))
            return false;
        context.last_map_x = inverse_map_x;
        context.last_map_y = inverse_map_y;
        context.last_map_width = params.image_width;
        context.last_map_height = params.image_height;
    }

    if (!checkCuda(cudaMemcpy(context.cloud.get(), cloud, cloud_bytes, cudaMemcpyHostToDevice),
                   "upload point cloud", error))
        return false;
    if (generate_colored_cloud &&
        !checkCuda(cudaMemcpy2D(context.image.get(), params.image_width * 3, bgr, color_step_bytes,
                               params.image_width * 3, params.image_height, cudaMemcpyHostToDevice),
                   "upload color image", error))
        return false;

    initializeDepth<<<(scaled_count + kThreads - 1) / kThreads, kThreads>>>(
        context.scaled_depth.get(), static_cast<int>(scaled_count));

    float *device_matrix = context.matrices.get();
    if (!checkCuda(cudaMemcpy(device_matrix, params.Kcl, sizeof(params.Kcl), cudaMemcpyHostToDevice),
                   "upload Kcl", error))
        return false;
    if (generate_colored_cloud &&
        !checkCuda(cudaMemcpy(device_matrix + 16, params.Tlc, sizeof(params.Tlc), cudaMemcpyHostToDevice),
                   "upload Tlc", error))
        return false;

    projectDepth<<<(point_count + kThreads - 1) / kThreads, kThreads>>>(
        context.cloud.get(), static_cast<int>(point_count),
        static_cast<int>(point_stride_floats * sizeof(float)), device_matrix,
        params.scaled_width, params.scaled_height, context.scaled_depth.get());
    resizeAndFilterDepth<<<(pixel_count + kThreads - 1) / kThreads, kThreads>>>(
        context.scaled_depth.get(), params.scaled_width, params.scaled_height,
        context.depth.get(), params.image_width, params.image_height);
    if (generate_colored_cloud)
    {
        remapBgrKernel<<<(pixel_count + kThreads - 1) / kThreads, kThreads>>>(
            context.image.get(), context.map_x.get(), context.map_y.get(), context.remapped.get(),
            params.image_width, params.image_height);
        buildColoredCloud<<<(sample_count + kThreads - 1) / kThreads, kThreads>>>(
            context.depth.get(), context.remapped.get(), params.image_width, params.image_height,
            sampling, samples_x, static_cast<int>(sample_count), params.A11, params.A12,
            params.A22, params.u0, params.v0, device_matrix + 16, context.colored.get());
    }

    if (!checkCuda(cudaGetLastError(), "launch CUDA depth pipeline", error))
        return false;

    if (!checkCuda(cudaMemcpy(depth, context.depth.get(), pixel_count * sizeof(float),
                              cudaMemcpyDeviceToHost), "download depth image", error))
        return false;

    colored_cloud_xyzw.clear();
    if (!generate_colored_cloud)
        return true;

    std::vector<DevicePoint> samples(sample_count);
    if (!checkCuda(cudaMemcpy(samples.data(), context.colored.get(), sample_count * sizeof(DevicePoint),
                              cudaMemcpyDeviceToHost), "download colored cloud", error))
        return false;

    colored_cloud_xyzw.reserve(sample_count * 4);
    for (const DevicePoint &point : samples)
    {
        if (!std::isfinite(point.x))
            continue;
        colored_cloud_xyzw.push_back(point.x);
        colored_cloud_xyzw.push_back(point.y);
        colored_cloud_xyzw.push_back(point.z);
        colored_cloud_xyzw.push_back(point.rgb);
    }
    return true;
}

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
    std::string &error)
{
    if (cloud_data == nullptr || bgr == nullptr || point_count == 0 || point_step_bytes == 0 ||
        x_offset + sizeof(float) > point_step_bytes ||
        y_offset + sizeof(float) > point_step_bytes ||
        z_offset + sizeof(float) > point_step_bytes)
    {
        error = "invalid CUDA colored-cloud input";
        return false;
    }
    RenderContext &context = renderContext();
    std::lock_guard<std::mutex> guard(context.mutex);
    const std::size_t cloud_bytes = point_count * point_step_bytes;
    const std::size_t image_bytes = static_cast<std::size_t>(image_width) * image_height * 3;
    if (!context.cloud.ensure(cloud_bytes) || !context.image.ensure(image_bytes) ||
        !context.output.ensure(point_count) || !context.output_count.ensure(1))
    {
        error = "CUDA colored-cloud buffer allocation failed";
        return false;
    }
    if (!checkCuda(cudaMemcpy(context.cloud.get(), cloud_data, cloud_bytes, cudaMemcpyHostToDevice),
                   "upload raw cloud", error) ||
        !checkCuda(cudaMemcpy2D(context.image.get(), image_width * 3, bgr, image_step_bytes,
                               image_width * 3, image_height, cudaMemcpyHostToDevice),
                   "upload BGR image", error) ||
        !checkCuda(cudaMemset(context.output_count.get(), 0, sizeof(std::uint32_t)),
                   "reset colored-cloud counter", error))
        return false;

    renderColoredCloudKernel<<<(point_count + kThreads - 1) / kThreads, kThreads>>>(
        context.cloud.get(), static_cast<int>(point_count), static_cast<int>(point_step_bytes),
        static_cast<int>(x_offset), static_cast<int>(y_offset), static_cast<int>(z_offset),
        context.image.get(), image_width, image_height, params,
        context.output.get(), context.output_count.get());
    if (!checkCuda(cudaGetLastError(), "launch CUDA colored-cloud renderer", error))
        return false;

    std::uint32_t output_count = 0;
    if (!checkCuda(cudaMemcpy(&output_count, context.output_count.get(), sizeof(output_count),
                              cudaMemcpyDeviceToHost), "download colored-cloud count", error))
        return false;
    output_count = std::min<std::uint32_t>(output_count, static_cast<std::uint32_t>(point_count));
    colored_cloud_xyzw.resize(static_cast<std::size_t>(output_count) * 4);
    return checkCuda(cudaMemcpy(colored_cloud_xyzw.data(), context.output.get(),
                                static_cast<std::size_t>(output_count) * sizeof(DevicePoint),
                                cudaMemcpyDeviceToHost), "download colored cloud", error);
}

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
    std::string &error)
{
    if (source == nullptr || destination == nullptr || map_x == nullptr || map_y == nullptr ||
        width <= 0 || height <= 0)
    {
        error = "invalid CUDA remap input";
        return false;
    }
    RemapContext &context = remapContext();
    std::lock_guard<std::mutex> guard(context.mutex);
    const std::size_t image_bytes = static_cast<std::size_t>(width) * height * 3;
    if (!context.source.ensure(image_bytes) || !context.destination.ensure(image_bytes))
    {
        error = "CUDA remap buffer allocation failed";
        return false;
    }
    if (context.last_map_x != map_x || context.last_map_y != map_y ||
        context.last_width != width || context.last_height != height)
    {
        if (!uploadMaps(context.map_x, context.map_y, map_x, map_y, map_step_floats,
                        width, height, error))
            return false;
        context.last_map_x = map_x;
        context.last_map_y = map_y;
        context.last_width = width;
        context.last_height = height;
    }
    if (!checkCuda(cudaMemcpy2D(context.source.get(), width * 3, source, source_step_bytes,
                               width * 3, height, cudaMemcpyHostToDevice), "upload remap image", error))
        return false;
    const std::size_t pixel_count = static_cast<std::size_t>(width) * height;
    remapBgrKernel<<<(pixel_count + kThreads - 1) / kThreads, kThreads>>>(
        context.source.get(), context.map_x.get(), context.map_y.get(), context.destination.get(),
        width, height);
    if (!checkCuda(cudaGetLastError(), "launch CUDA remap", error))
        return false;
    return checkCuda(cudaMemcpy2D(destination, destination_step_bytes, context.destination.get(),
                                  width * 3, width * 3, height, cudaMemcpyDeviceToHost),
                     "download remapped image", error);
}

} // namespace odin_cuda
