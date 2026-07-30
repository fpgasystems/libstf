cmake_minimum_required(VERSION 3.14)
project(libstf_typed_dictionary VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

option(EN_SIMULATION "Link against Coyote simulation library (no FPGA required)" OFF)
if(EN_SIMULATION)
    add_compile_definitions(EN_SIMULATION)
endif()

add_executable(typed_dictionary src/main.cpp)

if(NOT TARGET Coyote)
    if(EN_SIMULATION)
        find_package(CoyoteSimulation QUIET)
    else()
        find_package(Coyote QUIET)
    endif()
endif()

if(NOT TARGET libstf)
    find_package(libstf QUIET)
    if(NOT libstf_FOUND)
        add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../software libstf)
    endif()
endif()

target_link_libraries(typed_dictionary PRIVATE Coyote libstf)
