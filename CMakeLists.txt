cmake_minimum_required(VERSION 3.24)
project(MetalCompat C CXX)

if(NOT APPLE)
    message(FATAL_ERROR "MetalCompat core targets Apple platforms (iOS/macOS) only.")
endif()

# Objective-C++ backend sources are Apple-only.
enable_language(OBJCXX)

# ARC for every ObjC++ target (bridge casts in the backend rely on it —
# no-ARC compiles leave __bridge_retained no-ops and leak/dangle resources).
# Set via CMAKE_OBJCXX_FLAGS so both Ninja and the Xcode generator honor it.
set(CMAKE_OBJCXX_FLAGS "-fobjc-arc")

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(MC_BUILD_TESTS "Build MetalCompat tests" ON)
option(MC_BUILD_EXAMPLES "Build MetalCompat examples" ON)

# Deployment floors: iOS 14 per SPEC baseline; macOS 10.15 for host builds
# (supportsFamily: era, dept floors verified in docs/RESEARCH.md).
if(NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(CMAKE_OSX_DEPLOYMENT_TARGET "10.15")
endif()

add_subdirectory(src)
add_subdirectory(tools/APIRegistryValidator)
# iOS-only on-device test app (no-ops on other toolchains).
add_subdirectory(apps)
if(MC_BUILD_EXAMPLES)
    add_subdirectory(examples)
endif()
if(MC_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
