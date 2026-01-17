cmake_minimum_required(VERSION 3.16)
project(libstf)

# NOTE: This CMakeLists.txt is only here because of VSCode

# Find dependencies
add_subdirectory(coyote/sw coyote)

add_subdirectory(software)
