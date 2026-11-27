cmake_minimum_required(VERSION 3.5.0)
project(xray_harmony CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT DEFINED OHOS_ARCH)
  set(OHOS_ARCH "arm64-v8a")
endif()

set(XRAY_STATIC_LIB "${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${OHOS_ARCH}/libxray_ffi.a")
if(NOT EXISTS "${XRAY_STATIC_LIB}")
  message(FATAL_ERROR "Missing ${XRAY_STATIC_LIB}. Run build.ps1 so the Rust core is built first.")
endif()

add_library(entry SHARED xray_napi.cpp)

target_include_directories(entry PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include")

# libace_napi.z.so is the ArkTS N-API runtime; the Rust archive needs libc/libm
# and dlopen support from the OHOS sysroot.
target_link_libraries(entry PUBLIC
  libace_napi.z.so
  "${XRAY_STATIC_LIB}"
  dl
  m
)

# Reclaim dead Rust sections and keep internal libxray_ffi.a symbols unexported
# while preserving standard NAPI exports and libunwind symbols.
set_target_properties(entry PROPERTIES LINK_FLAGS "-Wl,--gc-sections -Wl,--exclude-libs,libxray_ffi.a -Wl,-O2 -Wl,--strip-all")
