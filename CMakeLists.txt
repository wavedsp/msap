cmake_minimum_required(VERSION 3.20)

# The GUI is Objective-C++ and only exists on macOS. The analysis core is plain
# C++17, so it and the tests build anywhere, which keeps the core honest.
if(APPLE)
    project(msap VERSION 3.1.0 LANGUAGES CXX OBJCXX)
else()
    project(msap VERSION 3.1.0 LANGUAGES CXX)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_XCODE_SCHEME_DEBUG_DOCUMENT_VERSIONING OFF)

if(APPLE)
    set(CMAKE_OBJCXX_STANDARD 17)
    set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
    # Apple silicon and Intel. Drop to one architecture to halve build time.
    if(NOT CMAKE_OSX_ARCHITECTURES)
        set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
    endif()
    if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
        set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0")
    endif()
endif()

find_package(Threads REQUIRED)

# ---------------------------------------------------------------------------
# msap_core - portable analysis code shared with WinSap and XSap.
# No toolkit headers here. If this list ever needs a UI header, something has
# leaked into the wrong layer.
# ---------------------------------------------------------------------------
add_library(msap_core STATIC
    src/Model.cpp
    src/core/SapFft.cpp
    src/core/SapSpectrogram.cpp
    src/core/SapSpectrogramCache.cpp
    src/core/SapWaveFile.cpp
    src/core/SapParameterFile.cpp
)
target_include_directories(msap_core PUBLIC src)
target_link_libraries(msap_core PUBLIC Threads::Threads)
target_compile_options(msap_core PRIVATE
    $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<CXX_COMPILER_ID:MSVC>>:/W4>
    $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<NOT:$<CXX_COMPILER_ID:MSVC>>>:-Wall;-Wextra;-Wpedantic>
)

# ---------------------------------------------------------------------------
# msap - the AppKit application bundle.
# ---------------------------------------------------------------------------
if(APPLE)
    set(MSAP_APP_ICON_SOURCE "${CMAKE_SOURCE_DIR}/assets/icons/msap.png")
    set(MSAP_APP_ICONSET "${CMAKE_CURRENT_BINARY_DIR}/MSap.iconset")
    set(MSAP_APP_ICON "${CMAKE_CURRENT_BINARY_DIR}/MSap.icns")
    find_program(MSAP_SIPS_EXECUTABLE sips REQUIRED)
    find_program(MSAP_ICONUTIL_EXECUTABLE iconutil REQUIRED)

    add_custom_command(
        OUTPUT "${MSAP_APP_ICON}"
        COMMAND "${CMAKE_COMMAND}" -E rm -rf "${MSAP_APP_ICONSET}"
        COMMAND "${CMAKE_COMMAND}" -E make_directory "${MSAP_APP_ICONSET}"
        COMMAND "${MSAP_SIPS_EXECUTABLE}" -z 16 16 "${MSAP_APP_ICON_SOURCE}" --out "${MSAP_APP_ICONSET}/icon_16x16.png"
        COMMAND "${MSAP_SIPS_EXECUTABLE}" -z 32 32 "${MSAP_APP_ICON_SOURCE}" --out "${MSAP_APP_ICONSET}/icon_16x16@2x.png"
        COMMAND "${MSAP_SIPS_EXECUTABLE}" -z 32 32 "${MSAP_APP_ICON_SOURCE}" --out "${MSAP_APP_ICONSET}/icon_32x32.png"
        COMMAND "${MSAP_SIPS_EXECUTABLE}" -z 64 64 "${MSAP_APP_ICON_SOURCE}" --out "${MSAP_APP_ICONSET}/icon_32x32@2x.png"
        COMMAND "${MSAP_SIPS_EXECUTABLE}" -z 128 128 "${MSAP_APP_ICON_SOURCE}" --out "${MSAP_APP_ICONSET}/icon_128x128.png"
        COMMAND "${MSAP_SIPS_EXECUTABLE}" -z 256 256 "${MSAP_APP_ICON_SOURCE}" --out "${MSAP_APP_ICONSET}/icon_128x128@2x.png"
        COMMAND "${MSAP_SIPS_EXECUTABLE}" -z 256 256 "${MSAP_APP_ICON_SOURCE}" --out "${MSAP_APP_ICONSET}/icon_256x256.png"
        COMMAND "${MSAP_SIPS_EXECUTABLE}" -z 512 512 "${MSAP_APP_ICON_SOURCE}" --out "${MSAP_APP_ICONSET}/icon_256x256@2x.png"
        COMMAND "${MSAP_SIPS_EXECUTABLE}" -z 512 512 "${MSAP_APP_ICON_SOURCE}" --out "${MSAP_APP_ICONSET}/icon_512x512.png"
        COMMAND "${MSAP_SIPS_EXECUTABLE}" -z 1024 1024 "${MSAP_APP_ICON_SOURCE}" --out "${MSAP_APP_ICONSET}/icon_512x512@2x.png"
        COMMAND "${MSAP_ICONUTIL_EXECUTABLE}" -c icns "${MSAP_APP_ICONSET}" -o "${MSAP_APP_ICON}"
        DEPENDS "${MSAP_APP_ICON_SOURCE}"
        COMMENT "Generating MSap application icon"
        VERBATIM
    )

    add_executable(msap MACOSX_BUNDLE
        src/main.mm
        src/MsapApp.mm
        src/HelpWindow.mm
        src/AudioPlayer.mm
        "${MSAP_APP_ICON}"
    )
    target_link_libraries(msap PRIVATE msap_core)
    target_compile_options(msap PRIVATE
        $<$<COMPILE_LANGUAGE:OBJCXX>:-Wall;-Wextra;-fobjc-arc>
    )
    target_compile_definitions(msap PRIVATE MSAP_VERSION="${PROJECT_VERSION}")

    # Everything below ships with macOS; there are no third party dependencies.
    target_link_libraries(msap PRIVATE
        "-framework Cocoa"
        "-framework CoreGraphics"
        "-framework CoreText"
        "-framework AudioToolbox"
        "-framework UniformTypeIdentifiers"
    )

    # The COMPILE_LANGUAGE generator expression above is ignored by the Xcode
    # generator, which would then compile the ARC code under manual retain and
    # release. Set the build setting as well so msap.xcodeproj matches the
    # command line build.
    set_target_properties(msap PROPERTIES
        XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
        XCODE_GENERATE_SCHEME YES
        MACOSX_BUNDLE_BUNDLE_NAME "MSap"
        MACOSX_BUNDLE_GUI_IDENTIFIER "org.tianwang.msap"
        MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
        MACOSX_BUNDLE_COPYRIGHT "Copyright (c) Tian Wang"
        MACOSX_BUNDLE_ICON_FILE "MSap.icns"
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/src/Info.plist.in"
    )

    # Application and toolbar artwork are copied into Contents/Resources.
    set_source_files_properties("${MSAP_APP_ICON}" PROPERTIES
        GENERATED TRUE
        MACOSX_PACKAGE_LOCATION "Resources"
    )
    file(GLOB MSAP_ICONS "${CMAKE_SOURCE_DIR}/assets/icons/*.png")
    target_sources(msap PRIVATE ${MSAP_ICONS})
    set_source_files_properties(${MSAP_ICONS} PROPERTIES
        MACOSX_PACKAGE_LOCATION "Resources/icons"
    )
    # Finder shows the bundle directory's date, which a relink does not
    # change, so stamp the bundle whenever the app is rebuilt.
    add_custom_command(TARGET msap POST_BUILD
        COMMAND touch "$<TARGET_BUNDLE_DIR:msap>"
        VERBATIM
    )
endif()

# ---------------------------------------------------------------------------
# Tests - portable, so they run on the Mac and on Linux.
# ---------------------------------------------------------------------------
include(CTest)
if(BUILD_TESTING)
    add_executable(msap_model_tests tests/ModelTests.cpp)
    target_link_libraries(msap_model_tests PRIVATE msap_core)
    target_compile_options(msap_model_tests PRIVATE
        $<$<CXX_COMPILER_ID:MSVC>:/W4>
        $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wall;-Wextra;-Wpedantic>
    )
    add_test(NAME msap_model_tests COMMAND msap_model_tests)

    add_executable(msap_fft_bench tests/FftBench.cpp)
    target_link_libraries(msap_fft_bench PRIVATE msap_core)
    target_compile_options(msap_fft_bench PRIVATE
        $<$<CXX_COMPILER_ID:MSVC>:/W4>
        $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wall;-Wextra;-Wpedantic>
    )
endif()
