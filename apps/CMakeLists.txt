# RenderTestApp — MetalCompat on-device Metal smoke-test bundle.
# iOS .ipa packaging + user steps: docs/RENDER_TEST_APP.md.

if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
  message(STATUS "Apps skipped: RenderTestApp requires an iOS toolchain (-DCMAKE_SYSTEM_NAME=iOS)")
  return()
endif()

set(MC_IOS_DEPLOY_TARGET "${CMAKE_OSX_DEPLOYMENT_TARGET}")

add_executable(MCRenderTest MACOSX_BUNDLE RenderTestApp/main.mm)

target_include_directories(MCRenderTest PRIVATE ${CMAKE_SOURCE_DIR}/include ${CMAKE_SOURCE_DIR}/src)
target_compile_features(MCRenderTest PRIVATE cxx_std_17)
target_compile_options(MCRenderTest PRIVATE -fobjc-arc)
# Xcode generator honors this build setting (the Ninja path uses -fobjc-arc
# from CMAKE_OBJCXX_FLAGS; the .mm code is ARC-clean under both generators).
set_target_properties(MCRenderTest PROPERTIES
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC "YES")

target_link_libraries(MCRenderTest PRIVATE
  MetalCompat
  "-framework UIKit"
  "-framework Metal"
  "-framework Foundation"
  "-framework QuartzCore"
)

set_target_properties(MCRenderTest PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/RenderTestApp/Info.plist.in"
  MACOSX_BUNDLE_GUI_IDENTIFIER "com.metalcompat.rendertest"
  MACOSX_BUNDLE_BUNDLE_NAME "MCRenderTest"
  MACOSX_BUNDLE_BUNDLE_VERSION "1.0.0"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0"
  MACOSX_BUNDLE_EXECUTABLE_NAME "MCRenderTest"
  XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
  XCODE_ATTRIBUTE_GENERATE_INFOPLIST_FILE "NO"
  XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
  XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "$ENV{MC_IOS_DEV_TEAM}"
  XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "Apple Development"
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.metalcompat.rendertest"
)
