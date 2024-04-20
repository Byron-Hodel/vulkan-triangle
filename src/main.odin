package main

import "core:log"
import "core:math/linalg/glsl"
import vk "vendor:vulkan"
import "vendor:glfw"

main :: proc() {
    context.logger = log.create_console_logger()
    defer log.destroy_console_logger(context.logger)

    if !glfw.Init() {
        log.fatal("failed to init glfw")
        return
    }
    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
    log.debug("initialized glfw")
    defer glfw.Terminate()

    vk_ctx: Vulkan_Context
    if !vulkan_data_init(&vk_ctx) {
        log.fatal("failed to init vulkan data")
        return
    }
    defer vulkan_data_destroy(&vk_ctx)
    log.debug("initialized vulkan data")

    window := glfw.CreateWindow(512, 512, "vulkan triangle", nil, nil)
    if window == nil {
        log.fatal("failed to create window")
        return
    }
    log.debug("created window")
    defer glfw.DestroyWindow(window)

    window_data: Vulkan_Window_Data
    if !vulkan_window_data_init(&window_data, &vk_ctx, window) {
        log.fatal("failed to init vulkan window data")
        return
    }
    defer vulkan_window_data_destroy(&window_data, &vk_ctx)

    log.info("initialization complete")

    for !glfw.WindowShouldClose(window) {
        glfw.PollEvents()
    }

    log.info("program exiting normally")
}
