cmake_minimum_required(VERSION 3.16)
project(libstf)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# NOTE: This CMakeLists.txt exists to make VSCode aware of the software library and examples

# Dependencies
if(NOT TARGET Coyote)
    find_package(Coyote QUIET)
    if(NOT Coyote_FOUND)
        add_subdirectory(coyote/sw coyote)
    endif()
endif()

# libSTF
add_subdirectory(software)

# Examples
add_subdirectory(examples/01_output_buffer_manager)
add_subdirectory(examples/02_typed_dictionary)
