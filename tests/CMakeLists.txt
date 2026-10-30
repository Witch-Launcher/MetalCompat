# Tests: unit suite + GPU vertical-slice test (reuses the BasicRender binary)
add_executable(MC_UnitTests Unit/UnitTests.cpp)
target_include_directories(MC_UnitTests PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(MC_UnitTests PRIVATE MetalCompat)
target_compile_options(MC_UnitTests PRIVATE -Wall -Wextra)

# Stage the real registry next to the unit test binary.
add_custom_command(TARGET MC_UnitTests POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            ${CMAKE_SOURCE_DIR}/registry
            $<TARGET_FILE_DIR:MC_UnitTests>/registry)

set(MC_UNIT_ENV "MC_REGISTRY_DIR=$<TARGET_FILE_DIR:MC_UnitTests>/registry")
add_test(NAME unit COMMAND MC_UnitTests)
set_tests_properties(unit PROPERTIES ENVIRONMENT "${MC_UNIT_ENV}")

if(MC_BUILD_EXAMPLES)
    add_test(NAME render_vertical_slice COMMAND MC_BasicRender)
endif()
