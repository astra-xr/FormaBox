cmake_minimum_required(VERSION 3.21)
project(Omnora VERSION 0.9.0 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(WIN32)
    enable_language(RC)
    # The Windows loader looks beside Omnora.exe for the deployed Qt DLLs.
    set(CMAKE_INSTALL_BINDIR ".")
    add_executable(OmnoraLauncher WIN32 desktop/launcher_win.cpp)
    set_target_properties(OmnoraLauncher PROPERTIES
        OUTPUT_NAME Omnora
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/launcher/$<CONFIG>")
    target_link_libraries(OmnoraLauncher PRIVATE user32)
    if(MSVC)
        target_compile_options(OmnoraLauncher PRIVATE /utf-8)
        set_property(TARGET OmnoraLauncher PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    elseif(MINGW)
        target_link_options(OmnoraLauncher PRIVATE -municode -static)
    endif()
endif()
find_package(Qt6 6.5 REQUIRED COMPONENTS Quick QuickControls2 Sql)
qt_standard_project_setup(REQUIRES 6.5)
qt_add_executable(Omnora WIN32
    desktop/main.cpp
    desktop/controller.cpp desktop/controller.h
    desktop/engineregistry.cpp desktop/engineregistry.h
    desktop/inspectionrunner.cpp desktop/inspectionrunner.h
    desktop/previewservice.cpp desktop/previewservice.h desktop/outputpath.h
    desktop/taskstore.cpp desktop/taskstore.h
    desktop/toolregistry.cpp desktop/toolregistry.h)
set(branding_dir "${CMAKE_CURRENT_SOURCE_DIR}/desktop/assets")
qt_add_resources(Omnora "branding"
    PREFIX "/branding"
    BASE "${branding_dir}"
    FILES "${branding_dir}/formabox.png")
if(WIN32)
    target_sources(Omnora PRIVATE desktop/windowframe_win.cpp desktop/windowframe_win.h)
    target_link_libraries(Omnora PRIVATE dwmapi comctl32)
    set(icon_resource "${branding_dir}/formabox.rc")
    set_source_files_properties("${icon_resource}" PROPERTIES
        OBJECT_DEPENDS "${branding_dir}/formabox.ico")
    foreach(target Omnora OmnoraLauncher)
        target_sources(${target} PRIVATE "${icon_resource}")
        target_include_directories(${target} PRIVATE "$<$<COMPILE_LANGUAGE:RC>:${branding_dir}>")
    endforeach()
endif()
set(omnora_qml Main.qml GlowButton.qml PdfWorkbench.qml EngineSettings.qml TaskResults.qml TaskHistory.qml RenamePreview.qml StudioPreview.qml Favorites.qml)
foreach(qml IN LISTS omnora_qml)
    set_source_files_properties("desktop/qml/${qml}" PROPERTIES QT_RESOURCE_ALIAS "${qml}")
endforeach()
list(TRANSFORM omnora_qml PREPEND "desktop/qml/")
qt_add_qml_module(Omnora URI Omnora VERSION 1.0 QML_FILES ${omnora_qml})
target_link_libraries(Omnora PRIVATE Qt6::Quick Qt6::QuickControls2 Qt6::Sql)
target_compile_definitions(Omnora PRIVATE OMNORA_VERSION="${PROJECT_VERSION}")
if(MSVC)
    target_compile_options(Omnora PRIVATE /utf-8)
endif()
install(TARGETS Omnora RUNTIME DESTINATION . BUNDLE DESTINATION .)
install(DIRECTORY worker/formabox DESTINATION worker PATTERN "__pycache__" EXCLUDE)
if(WIN32 AND Qt6_VERSION VERSION_GREATER_EQUAL 6.8)
    set(deploy_options DEPLOY_TOOL_OPTIONS --no-opengl-sw --no-system-d3d-compiler
        --no-system-dxc-compiler --no-compiler-runtime)
endif()
qt_generate_deploy_qml_app_script(TARGET Omnora OUTPUT_SCRIPT deploy_script
    NO_UNSUPPORTED_PLATFORM_ERROR ${deploy_options})
install(SCRIPT ${deploy_script})
