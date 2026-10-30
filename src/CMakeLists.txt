# MetalCompatCore — C++20 core + Objective-C++ LegacyMetal backend
add_library(MetalCompat STATIC
    Capability/Capabilities.cpp
    Core/Device.cpp
    Registry/JsonParse.cpp
    Registry/FeatureRegistry.cpp
    Planner/ExecutionPlanner.cpp
    CPU/Diagnostics/Diag.cpp
    Backends/LegacyMetal/metal_bridge.mm
)

target_include_directories(MetalCompat
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/../include
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/..
)

# Warnings: treat new fundamentals loudly, avoid platform noise.
target_compile_options(MetalCompat PRIVATE
    -Wall -Wextra -Wpedantic
    $<$<COMPILE_LANG_AND_ID:CXX,AppleClang>:-Wno-deprecated-declarations>
)

# Backend requires Metal + Foundation. Static lib exports link requirements.
target_link_libraries(MetalCompat PUBLIC
    "-framework Metal"
    "-framework Foundation"
)

# iOS/iOS-style targets need CoreFoundation via Foundation only; done above.
target_compile_definitions(MetalCompat PRIVATE $<$<CONFIG:Debug>:MC_DEBUG=1>)
