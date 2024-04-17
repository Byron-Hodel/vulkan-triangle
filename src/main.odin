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
    log.debug("initialized glfw")
    defer glfw.Terminate()

    window := glfw.CreateWindow(512, 512, "vulkan triangle", nil, nil)
    if window == nil {
        log.fatal("failed to create window")
        return
    }
    log.debug("created window")
    defer glfw.DestroyWindow(window)

    vk_data: Vulkan_Data
    if !vulkan_data_init(&vk_data) {
        log.fatal("failed to init vulkan data")
        return
    }
    defer vulkan_data_destroy(&vk_data)

    log.debug("initialized vulkan data")

    log.info("initialization complete")

    for !glfw.WindowShouldClose(window) {
        glfw.PollEvents()
    }

    log.info("program exiting normally")
}
