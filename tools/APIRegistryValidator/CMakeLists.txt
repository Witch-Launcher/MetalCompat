# APIRegistryValidator tool target
add_executable(MC_RegistryValidator main.cpp)
target_link_libraries(MC_RegistryValidator PRIVATE MetalCompat)
target_compile_options(MC_RegistryValidator PRIVATE -Wall -Wextra)
