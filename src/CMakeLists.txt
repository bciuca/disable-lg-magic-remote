# Copyright (c) 2026, BC (https://github.com/bciuca).
# SPDX-License-Identifier: MIT
# See LICENSE in the project root for the full license text.

cmake_minimum_required(VERSION 3.16)
project(magic_pointer C)
set(CMAKE_C_STANDARD 11)
set(ENV{PKG_CONFIG_SYSROOT_DIR} "${GUM_SYSROOT}")
set(ENV{PKG_CONFIG_LIBDIR} "${GUM_SYSROOT}/usr/lib/pkgconfig")
find_package(PkgConfig REQUIRED)
pkg_check_modules(GUM REQUIRED frida-gum-1.0)

file(GLOB_RECURSE CRT_OBJECTS "${EZINJECT_BUILD}/CMakeFiles/ezinject_crt.dir/*.o")
if(NOT CRT_OBJECTS)
    message(FATAL_ERROR "Build the matching ezinject_crt first")
endif()
add_library(magicpointer SHARED pointer.c module.c ${CRT_OBJECTS})
target_include_directories(magicpointer PRIVATE
    "${EZINJECT_SOURCE}" "${EZINJECT_BUILD}" "${EZINJECT_SOURCE}/crt/lh")
set(gum_includes ${GUM_STATIC_INCLUDE_DIRS})
# Keep the compiler SDK's libc headers, not the dependency SDK's older libc.
list(REMOVE_ITEM gum_includes "${GUM_SYSROOT}/usr/include")
target_include_directories(magicpointer SYSTEM PRIVATE ${gum_includes})
target_compile_options(magicpointer PRIVATE -Wall -Wextra -Werror -fPIC)
set(static_libraries "")
foreach(name IN LISTS GUM_STATIC_LIBRARIES)
    if(name STREQUAL "atomic")
        execute_process(COMMAND "${CMAKE_C_COMPILER}" -print-file-name=libatomic.a
            OUTPUT_VARIABLE atomic_archive OUTPUT_STRIP_TRAILING_WHITESPACE)
        if(NOT EXISTS "${atomic_archive}")
            message(FATAL_ERROR "Compiler has no static libatomic")
        endif()
        list(APPEND static_libraries "${atomic_archive}")
    elseif(name MATCHES "^(dl|pthread|rt|m|resolv)$")
        list(APPEND static_libraries "${name}")
    else()
        set(archive "${GUM_SYSROOT}/usr/lib/lib${name}.a")
        if(NOT EXISTS "${archive}")
            message(FATAL_ERROR "Missing static dependency: ${archive}")
        endif()
        list(APPEND static_libraries "${archive}")
    endif()
endforeach()
target_link_libraries(magicpointer PRIVATE
    "-Wl,--start-group" ${static_libraries} "-Wl,--end-group" dl pthread rt)
target_link_options(magicpointer PRIVATE
    -static-libgcc -Wl,--no-undefined -Wl,-Bsymbolic -Wl,--exclude-libs,ALL -Wl,--gc-sections)

add_executable(pointer-fixture ../tests/fixture.c)
target_link_libraries(pointer-fixture PRIVATE dl)
target_link_options(pointer-fixture PRIVATE -Wl,--export-dynamic)
target_compile_options(pointer-fixture PRIVATE -Wall -Wextra -Werror -fno-inline)
target_compile_options(pointer-fixture PRIVATE -UNDEBUG -O0)
add_executable(pointer-fixture-thumb ../tests/fixture.c)
target_link_libraries(pointer-fixture-thumb PRIVATE dl)
target_link_options(pointer-fixture-thumb PRIVATE -Wl,--export-dynamic)
target_compile_options(pointer-fixture-thumb PRIVATE -Wall -Wextra -Werror -fno-inline -UNDEBUG -O0 -mthumb)
