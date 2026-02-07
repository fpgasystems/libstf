cmake_minimum_required(VERSION 3.16)
project(libstf VERSION 0.1.0)

option(LIBSTF_WITH_PROFILING "Enable profiling to measure runtime of call groups with Caliper" OFF)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Collect source files
file(GLOB_RECURSE SOURCES libstf/*.cpp)

# Create the library
add_library(libstf SHARED ${SOURCES})

# Find dependencies

# Only add Coyote as a subdirectory if we are installing it standalone
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR) 
    add_subdirectory(../coyote/sw coyote)
else()
    if(NOT TARGET Coyote)
        message(FATAL_ERROR "When libstf is a subproject, parent must provide Coyote")
    endif()
endif()

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
find_package(Jemalloc REQUIRED)

# Specify include directories
target_include_directories(libstf
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
        $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}/libstf>
)
target_include_directories(libstf
    PUBLIC ${COYOTE_INCLUDE_DIRS} ${JEMALLOC_INCLUDE_DIRS}
)

target_link_libraries(libstf PRIVATE Coyote ${JEMALLOC_LIBRARIES})

if (LIBSTF_WITH_PROFILING)
    find_package(caliper REQUIRED)
    target_compile_definitions(libstf PRIVATE LIBSTF_WITH_PROFILING)

    target_link_libraries(libstf PRIVATE caliper)
    target_include_directories(libstf PRIVATE ${CALIPER_INCLUDE_DIR})
endif()

include(GNUInstallDirs)

# Install the library
install(TARGETS libstf
    EXPORT libstfTargets
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    INCLUDES DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)

# Install headers
install(DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/libstf
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/libstf
    FILES_MATCHING PATTERN "*.hpp"
)

# Export package configuration
install(EXPORT libstfTargets
    FILE libstfTargets.cmake
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/libstf
)

# Generate CMake package configuration files
include(CMakePackageConfigHelpers)
write_basic_package_version_file(
    ${CMAKE_CURRENT_BINARY_DIR}/libstfConfigVersion.cmake
    VERSION ${PROJECT_VERSION}
    COMPATIBILITY AnyNewerVersion
)
