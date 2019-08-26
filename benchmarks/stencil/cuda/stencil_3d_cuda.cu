/*
//@HEADER
// ************************************************************************
//
//                        Kokkos v. 2.0
//              Copyright (2019) Sandia Corporation
//
// Under the terms of Contract DE-AC04-94AL85000 with Sandia Corporation,
// the U.S. Government retains certain rights in this software.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
// 1. Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright
// notice, this list of conditions and the following disclaimer in the
// documentation and/or other materials provided with the distribution.
//
// 3. Neither the name of the Corporation nor the names of the
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY SANDIA CORPORATION "AS IS" AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL SANDIA CORPORATION OR THE
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
// LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
// NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// Questions? Contact Christian R. Trott (crtrott@sandia.gov)
//
// ************************************************************************
//@HEADER
*/

#include "fill.hpp"

#include <experimental/mdspan>

#include <memory>
#include <random>
#include <sstream>
#include <stdexcept>
#include <iostream>

//================================================================================

static constexpr int warpsPerBlock = 4;
static constexpr int global_delta = 1;
static constexpr int global_repeat = 16;

//================================================================================

template <class T, ptrdiff_t... Es>
using lmdspan = stdex::basic_mdspan<T, stdex::extents<Es...>, stdex::layout_left>;

void throw_runtime_exception(const std::string &msg) {
  std::ostringstream o;
  o << msg;
  throw std::runtime_error(o.str());
}

void cuda_internal_error_throw(cudaError e, const char* name,
  const char* file = NULL, const int line = 0) {
  std::ostringstream out;
  out << name << " error( " << cudaGetErrorName(e)
      << "): " << cudaGetErrorString(e);
  if (file) {
    out << " " << file << ":" << line;
  }
  throw_runtime_exception(out.str());
}

inline void cuda_internal_safe_call(cudaError e, const char* name,
       const char* file = NULL,
       const int line   = 0) {
  if (cudaSuccess != e) {
    cuda_internal_error_throw(e, name, file, line);
  }
}

#define CUDA_SAFE_CALL(call) \
  cuda_internal_safe_call(call, #call, __FILE__, __LINE__)

//================================================================================

dim3 get_bench_thread_block(ptrdiff_t y,ptrdiff_t z) {
  cudaDeviceProp cudaProp;
  int dim_z = 1;
  while(dim_z*3<z && dim_z<32) dim_z*=2;
  CUDA_SAFE_CALL(cudaGetDeviceProperties(&cudaProp, 1));
  int dim_y = 16;
  while(dim_y*3<y && dim_y<32) dim_y*=2;

  return dim3(1, dim_y, dim_z);
}

template <class F, class... Args>
__global__
void do_run_kernel(F f, Args... args) {
  f(args...);
}

template <class F, class... Args>
float run_kernel_timed(ptrdiff_t N, ptrdiff_t M, ptrdiff_t K, F&& f, Args&&... args) {
  cudaEvent_t start, stop;
  CUDA_SAFE_CALL(cudaEventCreate(&start));
  CUDA_SAFE_CALL(cudaEventCreate(&stop));

  CUDA_SAFE_CALL(cudaEventRecord(start));
  do_run_kernel<<<N, get_bench_thread_block(M,K)>>>(
    (F&&)f, ((Args&&) args)...
  );
  CUDA_SAFE_CALL(cudaEventRecord(stop));
  CUDA_SAFE_CALL(cudaEventSynchronize(stop));
  float milliseconds = 0;
  CUDA_SAFE_CALL(cudaEventElapsedTime(&milliseconds, start, stop));
  return milliseconds;
}

template <class MDSpan, class... DynSizes>
MDSpan fill_device_mdspan(MDSpan, DynSizes... dyn) {

  using value_type = typename MDSpan::value_type;
  auto buffer_size = MDSpan{nullptr, dyn...}.mapping().required_span_size();
  auto host_buffer = std::make_unique<value_type[]>(
    MDSpan{nullptr, dyn...}.mapping().required_span_size()
  );
  auto host_mdspan = MDSpan{host_buffer.get(), dyn...};
  mdspan_benchmark::fill_random(host_mdspan);
  
  value_type* device_buffer = nullptr;
  CUDA_SAFE_CALL(cudaMalloc(&device_buffer, buffer_size * sizeof(value_type)));
  CUDA_SAFE_CALL(cudaMemcpy(
    device_buffer, host_buffer.get(), buffer_size * sizeof(value_type), cudaMemcpyHostToDevice
  ));
  return MDSpan{device_buffer, dyn...};
}

//================================================================================

template <class MDSpan, class... DynSizes>
void BM_MDSpan_Cuda_Stencil_3D(benchmark::State& state, MDSpan, DynSizes... dyn) {

  using value_type = typename MDSpan::value_type;
  auto s = fill_device_mdspan(MDSpan{}, dyn...);
  auto o = fill_device_mdspan(MDSpan{}, dyn...);
  
  int d = global_delta;
  int repeats = global_repeat==0? (s.extent(0)*s.extent(1)*s.extent(2) > (100*100*100) ? 50 : 1000) : global_repeat;
  int count = 0;

  auto lambda =  
      [=] __device__ {
        for(int r = 0; r < repeats; ++r) {
          for(ptrdiff_t i = blockIdx.x+d; i < s.extent(0)-d; i += gridDim.x) {
            for(ptrdiff_t j = threadIdx.z+d; j < s.extent(1)-d; j += blockDim.z) {
              for(ptrdiff_t k = threadIdx.y+d; k < s.extent(2)-d; k += blockDim.y) {
                value_type sum_local = 0;
                for(ptrdiff_t di = i-d; di < i+d+1; di++) { 
                for(ptrdiff_t dj = j-d; dj < j+d+1; dj++) { 
                for(ptrdiff_t dk = k-d; dk < k+d+1; dk++) { 
                  sum_local += s(di, dj, dk);
                }}}
                o(i,j,k) = sum_local;
              }
            }
          }
        }
      };
  run_kernel_timed(s.extent(0),s.extent(1),s.extent(2),lambda);

  for (auto _ : state) {
    count++;
    auto timed = run_kernel_timed(s.extent(0),s.extent(1),s.extent(2),lambda);
    // units of cuda timer is milliseconds, units of iteration timer is seconds
    state.SetIterationTime(timed * 1e-3);
  }
  ptrdiff_t num_inner_elements = (s.extent(0)-d) * (s.extent(1)-d) * (s.extent(2)-d);
  ptrdiff_t stencil_num = (2*d+1) * (2*d+1) * (2*d+1);
  state.SetBytesProcessed( num_inner_elements * stencil_num * sizeof(value_type) * state.iterations() * repeats);
  state.counters["repeats"] = repeats; 
  
  CUDA_SAFE_CALL(cudaDeviceSynchronize());
  CUDA_SAFE_CALL(cudaFree(s.data()));
}
MDSPAN_BENCHMARK_ALL_3D_MANUAL(BM_MDSpan_Cuda_Stencil_3D, right_, stdex::mdspan, 80, 80, 80);
MDSPAN_BENCHMARK_ALL_3D_MANUAL(BM_MDSpan_Cuda_Stencil_3D, left_, lmdspan, 80, 80, 80);
MDSPAN_BENCHMARK_ALL_3D_MANUAL(BM_MDSpan_Cuda_Stencil_3D, right_, stdex::mdspan, 400, 400, 400);
MDSPAN_BENCHMARK_ALL_3D_MANUAL(BM_MDSpan_Cuda_Stencil_3D, left_, lmdspan, 400, 400, 400);

//================================================================================

template <class T, class SizeX, class SizeY, class SizeZ>
void BM_Raw_Cuda_Stencil_3D_right(benchmark::State& state, T, SizeX x, SizeY y, SizeZ z) {

  using value_type = T;
  value_type* data = nullptr;
  value_type* data_o = nullptr;
  {
    // just for setup...
    auto wrapped = stdex::mdspan<T, stdex::dynamic_extent>{};
    auto s = fill_device_mdspan(wrapped, x*y*z);
    data = s.data();
    auto o = fill_device_mdspan(wrapped, x*y*z);
    data_o = o.data();
  }

  int d = global_delta;
  int repeats = global_repeat==0? (x*y*z > (100*100*100) ? 50 : 1000) : global_repeat;

  auto lambda = 
      [=] __device__ {
        for(int r = 0; r < repeats; ++r) {
          for(ptrdiff_t i = blockIdx.x+d; i < x-d; i += gridDim.x) {
            for(ptrdiff_t j = threadIdx.z+d; j < y-d; j += blockDim.z) {
              for(ptrdiff_t k = threadIdx.y+d; k < z-d; k += blockDim.y) {
                value_type sum_local = 0;
                for(ptrdiff_t di = i-d; di < i+d+1; di++) { 
                for(ptrdiff_t dj = j-d; dj < j+d+1; dj++) { 
                for(ptrdiff_t dk = k-d; dk < k+d+1; dk++) { 
                  sum_local += data[dk + dj*z + di*z*y];
                }}}
                data_o[k + j*z + i*z*y] = sum_local;
              }
            }
          }
        }
      };
  run_kernel_timed(x,y,z,lambda);

  for (auto _ : state) {
    auto timed = run_kernel_timed(x,y,z,lambda);
    // units of cuda timer is milliseconds, units of iteration timer is seconds
    state.SetIterationTime(timed * 1e-3);
  }
  ptrdiff_t num_inner_elements = (x-d) * (y-d) * (z-d);
  ptrdiff_t stencil_num = (2*d+1) * (2*d+1) * (2*d+1);
  state.SetBytesProcessed( num_inner_elements * stencil_num * sizeof(value_type) * state.iterations() * repeats);
  state.counters["repeats"] = repeats;

  CUDA_SAFE_CALL(cudaDeviceSynchronize());
  CUDA_SAFE_CALL(cudaFree(data));
}
BENCHMARK_CAPTURE(BM_Raw_Cuda_Stencil_3D_right, size_80_80_80, int(), 80, 80, 80);
BENCHMARK_CAPTURE(BM_Raw_Cuda_Stencil_3D_right, size_400_400_400, int(), 400, 400, 400);

//================================================================================

template <class T, class SizeX, class SizeY, class SizeZ>
void BM_Raw_Cuda_Stencil_3D_left(benchmark::State& state, T, SizeX x, SizeY y, SizeZ z) {

  using value_type = T;
  value_type* data = nullptr;
  value_type* data_o = nullptr;
  {
    // just for setup...
    auto wrapped = stdex::mdspan<T, stdex::dynamic_extent>{};
    auto s = fill_device_mdspan(wrapped, x*y*z);
    data = s.data();
    auto o = fill_device_mdspan(wrapped, x*y*z);
    data_o = o.data();
  }

  int d = global_delta;
  int repeats = global_repeat==0? (x*y*z > (100*100*100) ? 50 : 1000) : global_repeat;
  auto lambda =
    [=] __device__ {
      for(int r = 0; r < repeats; ++r) {
        value_type sum_local = 0;
        for(ptrdiff_t i = blockIdx.x+d; i < x-d; i += gridDim.x) {
          for(ptrdiff_t j = threadIdx.z+d; j < y-d; j += blockDim.z) {
            for(ptrdiff_t k = threadIdx.y+d; k < z-d; k += blockDim.y) {
                value_type sum_local = 0;
                for(ptrdiff_t di = i-d; di < i+d+1; di++) { 
                for(ptrdiff_t dj = j-d; dj < j+d+1; dj++) { 
                for(ptrdiff_t dk = k-d; dk < k+d+1; dk++) { 
                  sum_local += data[dk*x*y + dj*x + di];
                }}}
                data_o[k*x*y + j*x + i] = sum_local;
            }
          }
        }
      }
    };

  run_kernel_timed(x,y,z,lambda);

  for (auto _ : state) {
    auto timed = run_kernel_timed(x,y,z,lambda);
    // units of cuda timer is milliseconds, units of iteration timer is seconds
    state.SetIterationTime(timed * 1e-3);
  }
  ptrdiff_t num_inner_elements = (x-d) * (y-d) * (z-d);
  ptrdiff_t stencil_num = (2*d+1) * (2*d+1) * (2*d+1);
  state.SetBytesProcessed( num_inner_elements * stencil_num * sizeof(value_type) * state.iterations() * repeats);
  state.counters["repeats"] = repeats;

  CUDA_SAFE_CALL(cudaDeviceSynchronize());
  CUDA_SAFE_CALL(cudaFree(data));
}
BENCHMARK_CAPTURE(BM_Raw_Cuda_Stencil_3D_left, size_80_80_80, int(), 80, 80, 80);
BENCHMARK_CAPTURE(BM_Raw_Cuda_Stencil_3D_left, size_400_400_400, int(), 400, 400, 400);

//================================================================================

BENCHMARK_MAIN();
