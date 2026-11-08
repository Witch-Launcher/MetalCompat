# MetalCompatCore — C++20 core + Objective-C++ LegacyMetal backend
add_library(MetalCompat STATIC
    Capability/Capabilities.cpp
    Core/Device.cpp
    Registry/JsonParse.cpp
    Registry/FeatureRegistry.cpp
    Planner/ExecutionPlanner.cpp
    CPU/Diagnostics/Diag.cpp
    GPU/Shaders/ShaderVariants.cpp
    Backends/LegacyMetal/metal_bridge.mm
    Backends/LegacyMetal/legacy_ops.mm
    Backends/LegacyMetal/raytrace_emul.mm
    Backends/LegacyMetal/render_layered.mm
    Backends/LegacyMetal/arg_table_t1.mm
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

# The Xcode generator ignored CMAKE_OBJCXX_FLAGS (-fobjc-arc): the .mm backend
# is ARC-clean and mixing generators must not change refcounting semantics.
set_target_properties(MetalCompat PROPERTIES XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC "YES")

# Backend requires Metal + Foundation. Static lib exports link requirements.
target_link_libraries(MetalCompat PUBLIC
    "-framework Metal"
    "-framework Foundation"
)

# iOS/iOS-style targets need CoreFoundation via Foundation only; done above.
target_compile_definitions(MetalCompat PRIVATE $<$<CONFIG:Debug>:MC_DEBUG=1>)
