# FindJemalloc.cmake
# Locate Jemalloc library

# Convert CMAKE_PREFIX_PATH into a list
list(APPEND SEARCH_PATHS ${CMAKE_PREFIX_PATH})

set(JEMALLOC_LIB_NAME jemalloc)

# Check if Jemalloc library exists in the install prefix directories
find_library(JEMALLOC_LIBRARIES
        NAMES ${JEMALLOC_LIB_NAME}
        PATHS ${SEARCH_PATHS}
        PATH_SUFFIXES jemalloc/lib jemalloc/lib64
)

# If Jemalloc library is found, set appropriate variables
if(JEMALLOC_LIB_NAME)
    set(JEMALLOC_FOUND TRUE)
    find_path(JEMALLOC_INCLUDE_DIRS
            NAMES jemalloc
            PATHS ${SEARCH_PATHS}
            PATH_SUFFIXES jemalloc/include
    )
endif()

# Provide interface for other CMake files
include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(Jemalloc DEFAULT_MSG JEMALLOC_LIBRARIES JEMALLOC_INCLUDE_DIRS)

# If JEMALLOC is not found, clear variables
if(NOT JEMALLOC_FOUND)
    unset(JEMALLOC_LIBRARIES CACHE)
    unset(JEMALLOC_INCLUDE_DIRS CACHE)
endif()
