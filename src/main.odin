package main

import "core:fmt"
import "core:math/linalg/glsl"
import vk "vendor:vulkan"
import "vendor:glfw"

main :: proc() {
    if !glfw.Init() {
        fmt.eprintln("failed to init glfw")
        return
    }
    fmt.println("initialized glfw")
    defer glfw.Terminate()

    window := glfw.CreateWindow(512, 512, "vulkan triangle", nil, nil)
    if window == nil {
        fmt.eprintln("failed to create window")
        return
    }
    fmt.println("created window")
    defer glfw.DestroyWindow(window)

    vk_data: Vulkan_Data
    if !vulkan_data_init(&vk_data) {
        fmt.eprintln("failed to init vulkan data")
        return
    }
    defer vulkan_data_destroy(&vk_data)

    fmt.println("initialized vulkan data")

    for !glfw.WindowShouldClose(window) {
        glfw.PollEvents()
    }
}
