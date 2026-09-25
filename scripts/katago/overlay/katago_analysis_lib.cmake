# MasterGo in-process analysis library for iOS (no executable spawning; App Store compliant).
# Included from cpp/CMakeLists.txt after the katago target is fully configured.
# KATAGO_ANALYSIS_STATIC=ON: build static lib (.a) for single-binary signing; OFF: shared.

set(BUILD_ANALYSIS_LIB OFF CACHE BOOL "Build in-process analysis library (for iOS embedding)")
set(KATAGO_ANALYSIS_STATIC OFF CACHE BOOL "Build analysis lib as static (iOS: only sign Runner.app)")

if(BUILD_ANALYSIS_LIB AND USE_BACKEND STREQUAL "EIGEN")
  get_target_property(_KATAGO_ANALYSIS_SOURCES katago SOURCES)
  if(NOT _KATAGO_ANALYSIS_SOURCES)
    message(FATAL_ERROR "BUILD_ANALYSIS_LIB=ON but katago target has no SOURCES")
  endif()
  list(FILTER _KATAGO_ANALYSIS_SOURCES EXCLUDE REGEX "main\\.cpp$")
  list(FILTER _KATAGO_ANALYSIS_SOURCES EXCLUDE REGEX "^$")

  if(KATAGO_ANALYSIS_STATIC)
    add_library(katago_analysis STATIC
      ${_KATAGO_ANALYSIS_SOURCES}
      katago_analysis_lib.cpp
      katago_analysis_version_stub.cpp)
    message(STATUS "Building KataGo in-process analysis library as STATIC (iOS)")
  else()
    add_library(katago_analysis SHARED
      ${_KATAGO_ANALYSIS_SOURCES}
      katago_analysis_lib.cpp
      katago_analysis_version_stub.cpp)
    message(STATUS "Building KataGo in-process analysis library as SHARED (iOS)")
  endif()

  set_target_properties(katago_analysis PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON)

  target_include_directories(katago_analysis PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_BINARY_DIR})

  get_target_property(_kg_inc katago INCLUDE_DIRECTORIES)
  if(_kg_inc)
    target_include_directories(katago_analysis PRIVATE ${_kg_inc})
  endif()

  get_target_property(_kg_defs katago COMPILE_DEFINITIONS)
  if(_kg_defs)
    target_compile_definitions(katago_analysis PRIVATE ${_kg_defs})
  endif()
  target_compile_definitions(katago_analysis PRIVATE USE_EIGEN_BACKEND)
  if(NO_GIT_REVISION)
    target_compile_definitions(katago_analysis PRIVATE NO_GIT_REVISION)
  endif()
  if((NOT LIBZIP_LIBRARY) OR (NOT LIBZIP_INCLUDE_DIR_ZIP) OR (NOT LIBZIP_INCLUDE_DIR_ZIPCONF))
    target_compile_definitions(katago_analysis PRIVATE NO_LIBZIP)
  endif()

  get_target_property(_kg_libs katago LINK_LIBRARIES)
  if(_kg_libs)
    target_link_libraries(katago_analysis PRIVATE ${_kg_libs})
  endif()

  if(NOT MSVC)
    find_package(Eigen3 REQUIRED)
    if(EIGEN3_INCLUDE_DIRS)
      target_include_directories(katago_analysis PRIVATE SYSTEM ${EIGEN3_INCLUDE_DIRS})
    endif()
  endif()

  find_package(Threads REQUIRED)
  target_link_libraries(katago_analysis PRIVATE Threads::Threads)
  if(ZLIB_FOUND)
    target_link_libraries(katago_analysis PRIVATE ${ZLIB_LIBRARIES})
  endif()
endif()
