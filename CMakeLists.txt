cmake_minimum_required(VERSION 3.12)
project(watchsim C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Point LVGL at our headless configuration.
set(LV_CONF_PATH
    ${CMAKE_CURRENT_SOURCE_DIR}/config/lv_conf.h
    CACHE STRING "Path to lv_conf.h" FORCE)

add_subdirectory(deps/lvgl)

# System libraries per platform: dl is POSIX-only, pthread comes from
# winpthreads on MinGW.
if(UNIX)
    set(SIM_SYS_LIBS pthread m dl)
else()
    set(SIM_SYS_LIBS pthread)
endif()

# Stage 1 smoke test: offscreen render of a real .bin resource.
add_executable(test_headless
    core/sim_display.c
    core/test_headless.c)
target_link_libraries(test_headless PRIVATE lvgl ${SIM_SYS_LIBS})

add_executable(diag_pos
    core/sim_display.c
    core/diag_pos.c)
target_link_libraries(diag_pos PRIVATE lvgl ${SIM_SYS_LIBS})

# Stage 4: confirm real lv_anim advances with pumped ticks.
add_executable(test_anim
    core/sim_display.c
    core/test_anim.c)
target_link_libraries(test_anim PRIVATE lvgl ${SIM_SYS_LIBS})

# Stage 2: run an unmodified Lua watch face under real LVGL.
add_executable(run_face
    core/sim_display.c
    core/run_face.c
    bridge/sim_bridge.c)
target_include_directories(run_face PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/deps/lua/src)
target_compile_definitions(run_face PRIVATE
    WATCHSIM_LUA_DIR="${CMAKE_CURRENT_SOURCE_DIR}/lua")
target_link_libraries(run_face PRIVATE
    lvgl
    ${CMAKE_CURRENT_SOURCE_DIR}/deps/lua/liblua.a
    ${SIM_SYS_LIBS})

# Stage 5: long-running headless core driven over a stdio line protocol.
add_executable(sim_server
    core/sim_display.c
    core/sim_server.c
    bridge/sim_bridge.c)
target_include_directories(sim_server PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/deps/lua/src
    ${CMAKE_CURRENT_SOURCE_DIR}/bridge)
target_compile_definitions(sim_server PRIVATE
    WATCHSIM_LUA_DIR="${CMAKE_CURRENT_SOURCE_DIR}/lua")
target_link_libraries(sim_server PRIVATE
    lvgl
    ${CMAKE_CURRENT_SOURCE_DIR}/deps/lua/liblua.a
    ${SIM_SYS_LIBS})
