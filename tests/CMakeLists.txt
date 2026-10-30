# Tests: unit suite + GPU vertical-slice test (reuses the BasicRender binary)
add_executable(MC_UnitTests Unit/UnitTests.cpp)
target_include_directories(MC_UnitTests PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(MC_UnitTests PRIVATE MetalCompat)
target_compile_options(MC_UnitTests PRIVATE -Wall -Wextra)

# M4 integration suite: real Metal ops (buffers/textures/compute/hazards).
# Name that BOTH tests share so it also builds the registry staging target.
add_executable(MC_IntegrationTests Rendering/IntegrationTests.mm)
target_include_directories(MC_IntegrationTests PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(MC_IntegrationTests PRIVATE MetalCompat)
target_compile_options(MC_IntegrationTests PRIVATE -Wall -Wextra)
add_dependencies(MC_IntegrationTests stage_registry)

add_test(NAME integration COMMAND MC_IntegrationTests)

# Stage the real registry next to the unit test binary. A dedicated target
# keeps the copy independent of incidental relinks (fresh runs always current).
add_custom_target(stage_registry
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            ${CMAKE_SOURCE_DIR}/registry
            $<TARGET_FILE_DIR:MC_UnitTests>/registry
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            ${CMAKE_SOURCE_DIR}/registry
            $<TARGET_FILE_DIR:MC_IntegrationTests>/registry)
add_dependencies(MC_UnitTests stage_registry)

set(MC_UNIT_ENV "MC_REGISTRY_DIR=$<TARGET_FILE_DIR:MC_UnitTests>/registry")
add_test(NAME unit COMMAND MC_UnitTests)
set_tests_properties(unit PROPERTIES ENVIRONMENT "${MC_UNIT_ENV}")

# M8 perf harness (manual; NOT a ctest default — GPU timing is non-hermetic).
add_executable(MC_PerfHarness Performance/PerfHarness.mm)
target_include_directories(MC_PerfHarness PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(MC_PerfHarness PRIVATE MetalCompat)

if(MC_BUILD_EXAMPLES)
    add_test(NAME render_vertical_slice COMMAND MC_BasicRender)
endif()
