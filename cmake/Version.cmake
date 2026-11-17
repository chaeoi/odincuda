get_filename_component(ODINCUDA_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if(NOT DEFINED ODINCUDA_BINARY_DIR)
    set(ODINCUDA_BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}")
endif()

set(ODINCUDA_VERSION "${ODINCUDA_VERSION}" CACHE STRING "OdinCUDA build version")
if(NOT ODINCUDA_VERSION)
    file(STRINGS "${ODINCUDA_SOURCE_DIR}/VERSION" ODINCUDA_VERSION LIMIT_COUNT 1)
    if(ODINCUDA_VERSION STREQUAL "0.0.0-dev")
        execute_process(
            COMMAND git describe --tags --exact-match --match "[2-9][0-9][0-9][0-9].*.*"
            WORKING_DIRECTORY "${ODINCUDA_SOURCE_DIR}"
            OUTPUT_VARIABLE ODINCUDA_TAG OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
        if(ODINCUDA_TAG)
            set(ODINCUDA_VERSION "${ODINCUDA_TAG}")
        endif()
    endif()
endif()

set(ODINCUDA_PACKAGE_VERSION "0.0.0")
if(NOT ODINCUDA_VERSION STREQUAL "0.0.0-dev")
    if(NOT ODINCUDA_VERSION MATCHES "^[2-9][0-9][0-9][0-9]\\.([1-9]|1[0-2])\\.([1-9][0-9]*)$")
        message(FATAL_ERROR "ODINCUDA_VERSION must be year.month.sequence")
    endif()
    if(CMAKE_MATCH_2 GREATER 4294967295)
        message(FATAL_ERROR "OdinCUDA release sequence is out of range")
    endif()
    set(ODINCUDA_PACKAGE_VERSION "${ODINCUDA_VERSION}")
endif()

set(ODINCUDA_GENERATED_DIR "${ODINCUDA_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${ODINCUDA_GENERATED_DIR}")
configure_file("${ODINCUDA_SOURCE_DIR}/cmake/version.hpp.in"
    "${ODINCUDA_GENERATED_DIR}/odincuda_version.hpp" @ONLY)
foreach(manifest package.xml package_ros1.xml package_ros2.xml)
    file(READ "${ODINCUDA_SOURCE_DIR}/${manifest}" ODINCUDA_MANIFEST)
    string(REGEX REPLACE "<version>[^<]+</version>"
        "<version>${ODINCUDA_PACKAGE_VERSION}</version>" ODINCUDA_MANIFEST "${ODINCUDA_MANIFEST}")
    file(WRITE "${ODINCUDA_GENERATED_DIR}/${manifest}" "${ODINCUDA_MANIFEST}")
endforeach()
