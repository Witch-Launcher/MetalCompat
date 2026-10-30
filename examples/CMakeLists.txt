# Examples: CapabilityReport (CPU chain) and BasicRender (GPU vertical slice)
add_executable(MC_CapabilityReport CapabilityReport/main.cpp)
target_link_libraries(MC_CapabilityReport PRIVATE MetalCompat)
target_compile_options(MC_CapabilityReport PRIVATE -Wall -Wextra)

add_executable(MC_BasicRender BasicRender/main.mm)
target_include_directories(MC_BasicRender PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(MC_BasicRender PRIVATE MetalCompat)
target_compile_options(MC_BasicRender PRIVATE -Wall -Wextra)

# Registry files staged next to each executable (their resolver also checks
# cwd / MC_REGISTRY_DIR).
foreach(tgt MC_CapabilityReport MC_BasicRender)
    add_custom_command(TARGET ${tgt} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
                ${CMAKE_SOURCE_DIR}/registry
                $<TARGET_FILE_DIR:${tgt}>/registry)
endforeach()
