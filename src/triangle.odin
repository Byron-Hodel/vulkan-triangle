package main

import "core:log"
import "core:math/linalg/glsl"
import "core:mem"
import "core:reflect"
import "vendor:glfw"
import vk "vendor:vulkan"

VALIDATION_LAYERS: []cstring = {
    "VK_LAYER_KHRONOS_validation",
}

DEVICE_EXTENSIONS: []cstring = {
    "VK_KHR_swapchain",
}

Vulkan_Context :: struct {
    instance:        vk.Instance,
    physical_device: vk.PhysicalDevice,
    device:          vk.Device,
    surface_format:  vk.SurfaceFormatKHR,
    indices:  struct {
        graphics:             u32,
        compute:              u32,
        transfer:             u32,
        present:              u32,
        specialized_compute:  b8,
        specialized_transfer: b8,
    }
}

Vulkan_Window_Data :: struct {
    window:    glfw.WindowHandle,
    surface:   vk.SurfaceKHR,
    swapchain: vk.SwapchainKHR,
    img_views: []vk.ImageView,
}

@(private="file")
check_result :: #force_inline proc(r: vk.Result, err_msg: string, location := #caller_location) -> (ok: bool) {
    if r != .SUCCESS {
        log.error(err_msg, "err =", reflect.enum_string(r))
        return false
    }
    return true
}

vulkan_data_init :: proc(vk_ctx: ^Vulkan_Context) -> (ok: bool) {
    get_proc_address :: proc(p: rawptr, name: cstring) {
		(cast(^rawptr)p)^ = glfw.GetInstanceProcAddress((^vk.Instance)(context.user_ptr)^, name)
	}
    arena_buffer: [4098]u8 = ---
    arena: mem.Arena
    mem.arena_init(&arena, arena_buffer[:])
    arena_allocator := mem.arena_allocator(&arena)
    // sets arena offset to some value

    // create vulkan instance
    instance: vk.Instance
    {
        context.user_ptr = &instance
        vk.load_proc_addresses(get_proc_address)
        app_info := vk.ApplicationInfo {
            sType = .APPLICATION_INFO,
            pApplicationName = "vulkan triangle",
            applicationVersion = vk.MAKE_VERSION(0, 1, 0),
            pEngineName = "not an engine",
            engineVersion = vk.MAKE_VERSION(0, 0, 0),
            apiVersion = vk.API_VERSION_1_1,
        }

        glfw_required_extensions := glfw.GetRequiredInstanceExtensions()

        instance_info := vk.InstanceCreateInfo {
            sType = .INSTANCE_CREATE_INFO,
            pApplicationInfo = &app_info,
            enabledExtensionCount = cast(u32)len(glfw_required_extensions),
            ppEnabledExtensionNames = raw_data(glfw_required_extensions),
            enabledLayerCount = cast(u32)len(VALIDATION_LAYERS),
            ppEnabledLayerNames = raw_data(VALIDATION_LAYERS),
        }

        result := vk.CreateInstance(&instance_info, nil, &instance)
        check_result(result, "failed to create instance") or_return
	    vk.load_proc_addresses(instance)
    }
    defer if !ok {
        vk.DestroyInstance(instance, nil)
    }
    log.debug("created instance")

    // create dummy window for surface creation
    dummy_window := glfw.CreateWindow(1, 1, "", nil, nil)
    if dummy_window == nil {
        log.error("failed to create dummy window")
        return false
    }
    defer glfw.DestroyWindow(dummy_window)

    // create vulkan surface
    surface: vk.SurfaceKHR
    {
        result := glfw.CreateWindowSurface(instance, dummy_window, nil, &surface)
        check_result(result, "failed to create dummy window surface") or_return
    }
    defer vk.DestroySurfaceKHR(instance, surface, nil)

    // select physical device
    physical_device: vk.PhysicalDevice
    {
        is_device_suitable :: proc(d: vk.PhysicalDevice, arena: ^mem.Arena) -> b32 {
            arena_allocator := mem.arena_allocator(arena)

            indexing_features := vk.PhysicalDeviceDescriptorIndexingFeatures {
                sType = .PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES,
            }
            features := vk.PhysicalDeviceFeatures2 {
                sType = .PHYSICAL_DEVICE_FEATURES_2,
                pNext = &indexing_features,
            }
            vk.GetPhysicalDeviceFeatures2(d, &features)

            bindless_supported: b32 = indexing_features.descriptorBindingPartiallyBound && indexing_features.runtimeDescriptorArray
            
            // check extensions
            extension_count: u32
            result := vk.EnumerateDeviceExtensionProperties(d, nil, &extension_count, nil)
            check_result(result, "failed to enumerate device extension properties") or_return
            extensions := make([]vk.ExtensionProperties, extension_count, arena_allocator)
            if extensions == nil {
                log.error("failed to allocate extensions array")
                return false
            }
            defer delete(extensions, arena_allocator)
            result = vk.EnumerateDeviceExtensionProperties(d, nil, &extension_count, raw_data(extensions))
            check_result(result, "failed to enumerate device extension properties") or_return
            
            loop: for re in DEVICE_EXTENSIONS {
                for &e in extensions {
                    if cast(cstring)cast(rawptr)&e.extensionName == re {
                        continue loop
                    }
                    return false
                }

            }

            return bindless_supported
        }

        device_count: u32
        vk.EnumeratePhysicalDevices(instance, &device_count, nil)
        physical_device_list := make([]vk.PhysicalDevice, device_count, arena_allocator)
        if physical_device_list == nil {
            log.error("failed to allocate memory for physical devices")
            return false
        }
        vk.EnumeratePhysicalDevices(instance, &device_count, raw_data(physical_device_list))
        
        has_selected_device: bool = false
        selected_device: vk.PhysicalDevice
        selected_properties: vk.PhysicalDeviceProperties
        for d in physical_device_list {
            properties: vk.PhysicalDeviceProperties
            vk.GetPhysicalDeviceProperties(d, &properties)

            if is_device_suitable(d, &arena) || properties.deviceType == .DISCRETE_GPU || properties.deviceType == .INTEGRATED_GPU {
                if !has_selected_device {
                    has_selected_device = true
                    selected_device = d
                    selected_properties = properties
                    continue
                }
                
                if properties.deviceType == .DISCRETE_GPU && selected_properties.deviceType != .DISCRETE_GPU {
                    selected_device = d
                    selected_properties = properties
                }
            }
        }
        if !has_selected_device {
            log.error("failed to find suitable physical device")
            return false
        }
        physical_device = selected_device

        log.debug("selected physical device:", cast(cstring)cast(rawptr)&selected_properties.deviceName)
    }

    // select surface format from supported format
    surface_format: vk.SurfaceFormatKHR
    {
        format_count: u32
        result := vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, nil)
        check_result(result, "failed to get device surface formats") or_return
        formats := make([]vk.SurfaceFormatKHR, format_count, arena_allocator)
        defer delete(formats, arena_allocator)
        if formats == nil {
            log.error("failed to create surface formats array")
            return false
        }
        result = vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, raw_data(formats))
        check_result(result, "failed to get device surface formats") or_return

        surface_format = formats[0]
        for fmt in formats {
            if fmt.format == .B8G8R8A8_SRGB && fmt.colorSpace == .COLORSPACE_SRGB_NONLINEAR {
                surface_format = fmt
                break
            }
        }
    }

    // get queue families and select queue family indices
    graphics_index, compute_index, transfer_index, present_index: i32 = -1, -1, -1, -1
    specialized_transfer, specialized_compute: b8
    {
        queue_family_properties: []vk.QueueFamilyProperties
        queue_family_count: u32
        vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, nil)
        queue_family_properties = make([]vk.QueueFamilyProperties, queue_family_count, arena_allocator)
        defer delete(queue_family_properties, arena_allocator)
        vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, raw_data(queue_family_properties))

        for f, i in queue_family_properties {
            present_support: b32
            vk.GetPhysicalDeviceSurfaceSupportKHR(physical_device, cast(u32)i, surface, &present_support)
            if graphics_index == -1 && .GRAPHICS in f.queueFlags do graphics_index = cast(i32)i
            if compute_index  == -1 && .COMPUTE  in f.queueFlags do compute_index  = cast(i32)i
            if transfer_index == -1 && .TRANSFER in f.queueFlags do transfer_index = cast(i32)i
            if present_index  == -1 && present_support == true   do present_index  = cast(i32)i
            
            if .TRANSFER in f.queueFlags && transmute(i32)f.queueFlags < transmute(i32)queue_family_properties[transfer_index].queueFlags {
                transfer_index = cast(i32)i
            }

            if .COMPUTE in f.queueFlags && transmute(i32)f.queueFlags < transmute(i32)queue_family_properties[compute_index].queueFlags {
                compute_index = cast(i32)i
            }
        }

        specialized_compute  = compute_index  != graphics_index && compute_index  != transfer_index
        specialized_transfer = transfer_index != graphics_index && transfer_index != compute_index

        for p, i in queue_family_properties {
            present_support: b32
            vk.GetPhysicalDeviceSurfaceSupportKHR(physical_device, cast(u32)i, surface, &present_support)

            log.debug("queue family:", i)
            if .GRAPHICS in p.queueFlags         do log.debug("  Graphics: ----- Y")
            else                                 do log.debug("  Graphics: ----- N")
            if .COMPUTE in p.queueFlags          do log.debug("  Compute: ------ Y")
            else                                 do log.debug("  Compute: ------ N")
            if .TRANSFER in p.queueFlags         do log.debug("  Transfer: ----- Y")
            else                                 do log.debug("  Compute: ------ N")
            if .SPARSE_BINDING in p.queueFlags   do log.debug("  Sparse Binding: Y")
            else                                 do log.debug("  Sparse Binding: N")
            if present_support                   do log.debug("  Present: ------ Y")
            else                                 do log.debug("  Present: ------ N")
            if .PROTECTED in p.queueFlags        do log.debug("  Protected: ---- Y")
            else                                 do log.debug("  Protected: ---- N")
            if .VIDEO_DECODE_KHR in p.queueFlags do log.debug("  Vidio Decode: - Y")
            else                                 do log.debug("  Vidio Decode: - N")
            if .OPTICAL_FLOW_NV in p.queueFlags  do log.debug("  Optical Flow: - Y")
            else                                 do log.debug("  Optical Flow: - N")
            log.debug("  max queues", p.queueCount)
        }

        log.debug("Selected Graphics Family Index:", graphics_index)
        log.debug("Selected Compute Family Index: ", compute_index)
        log.debug("Selected Transfer Family Index:", transfer_index)
    }

    // create logical device
    device: vk.Device
    {
        queue_info_count: u32 = 1
        queue_infos: [3]vk.DeviceQueueCreateInfo
        queue_priority: f32 = 1.0
        queue_infos[0] = vk.DeviceQueueCreateInfo {
            sType = .DEVICE_QUEUE_CREATE_INFO,
            queueFamilyIndex = transmute(u32)graphics_index,
            queueCount = 1,
            pQueuePriorities = &queue_priority,
        }
        if specialized_compute {
            defer queue_info_count += 1
            queue_infos[queue_info_count] = vk.DeviceQueueCreateInfo {
                sType = .DEVICE_QUEUE_CREATE_INFO,
                queueFamilyIndex = transmute(u32)compute_index,
                queueCount = 1,
                pQueuePriorities = &queue_priority,
            }
        }
        if specialized_transfer {
            defer queue_info_count += 1
            queue_infos[queue_info_count] = vk.DeviceQueueCreateInfo {
                sType = .DEVICE_QUEUE_CREATE_INFO,
                queueFamilyIndex = transmute(u32)transfer_index,
                queueCount = 1,
                pQueuePriorities = &queue_priority,
            }
        }

        device_features: vk.PhysicalDeviceFeatures
        vk.GetPhysicalDeviceFeatures(physical_device, &device_features)

        device_info := vk.DeviceCreateInfo {
            sType = .DEVICE_CREATE_INFO,
            queueCreateInfoCount = queue_info_count,
            pQueueCreateInfos = raw_data(queue_infos[:queue_info_count]),
            enabledExtensionCount = cast(u32)len(DEVICE_EXTENSIONS),
            ppEnabledExtensionNames = raw_data(DEVICE_EXTENSIONS),
            pEnabledFeatures = &device_features,
        }

        result := vk.CreateDevice(physical_device, &device_info, nil, &device)
        check_result(result, "failed to create vulkan device") or_return
    }
    defer if !ok {
        vk.DestroyDevice(device, nil)
    }
    log.debug("created logical device")

    vk_ctx.instance         = instance
    vk_ctx.physical_device   = physical_device
    vk_ctx.device           = device
    vk_ctx.surface_format   = surface_format
    vk_ctx.indices.graphics = transmute(u32)graphics_index
    vk_ctx.indices.compute  = transmute(u32)compute_index
    vk_ctx.indices.transfer = transmute(u32)transfer_index
    vk_ctx.indices.specialized_compute  = specialized_compute
    vk_ctx.indices.specialized_transfer = specialized_transfer
    return true
}

vulkan_data_destroy :: proc(data: ^Vulkan_Context) {
    defer data^ = {}
    vk.DestroyDevice(data.device, nil)
    vk.DestroyInstance(data.instance, nil)
}

create_swapchain :: proc(vk_ctx: ^Vulkan_Context, window: glfw.WindowHandle, surface: vk.SurfaceKHR, old: vk.SwapchainKHR = 0) -> (swapchain: vk.SwapchainKHR, ok: bool) {
    surface_capabilities: vk.SurfaceCapabilitiesKHR
    {

        result := vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(vk_ctx.physical_device, surface, &surface_capabilities)
        check_result(result, "failed to get device surface capabilites") or_return
    }

    image_count: u32
    extent: vk.Extent2D
    queue_indices := []u32 { vk_ctx.indices.graphics, vk_ctx.indices.present }

    image_count = surface_capabilities.minImageCount + 1
    if surface_capabilities.maxImageCount > 0 do image_count = min(image_count, surface_capabilities.maxImageCount)

    min_extent_width  := surface_capabilities.minImageExtent.width
    min_extent_height := surface_capabilities.minImageExtent.height
    max_extent_width  := surface_capabilities.maxImageExtent.width
    max_extent_height := surface_capabilities.maxImageExtent.height

    framebuffer_x, framebuffer_y := glfw.GetFramebufferSize(window)
    extent.width  = clamp(transmute(u32)framebuffer_x, min_extent_width, max_extent_width)
    extent.height = clamp(transmute(u32)framebuffer_y, min_extent_height, max_extent_height)

    is_concurrent := vk_ctx.indices.graphics != vk_ctx.indices.present
    swapchain_info := vk.SwapchainCreateInfoKHR {
        sType                 = .SWAPCHAIN_CREATE_INFO_KHR,
        surface               = surface,
        minImageCount         = image_count,
        imageFormat           = vk_ctx.surface_format.format,
        imageColorSpace       = vk_ctx.surface_format.colorSpace,
        imageExtent           = extent,
        imageArrayLayers      = 1,
        imageUsage            = { .COLOR_ATTACHMENT },
        imageSharingMode      = .CONCURRENT if is_concurrent else .EXCLUSIVE,
        queueFamilyIndexCount = cast(u32)len(queue_indices) if is_concurrent else 0,
        pQueueFamilyIndices   = raw_data(queue_indices),
        preTransform          = surface_capabilities.currentTransform,
        compositeAlpha        = { .OPAQUE },
        presentMode           = .FIFO,
        clipped               = true,
    }

    result := vk.CreateSwapchainKHR(vk_ctx.device, &swapchain_info, nil, &swapchain)
    check_result(result, "failed to create swapchain") or_return
    
    log.debug("created swapchain")
    return swapchain, true
}

vulkan_window_data_init :: proc(data: ^Vulkan_Window_Data, vk_ctx: ^Vulkan_Context, window: glfw.WindowHandle) -> (ok: bool) {
    arena_buffer: [2048]u8 = ---
    arena: mem.Arena
    mem.arena_init(&arena, arena_buffer[:])
    arena_allocator := mem.arena_allocator(&arena)

    // create surface
    surface: vk.SurfaceKHR
    {
        result := glfw.CreateWindowSurface(vk_ctx.instance, window, nil, &surface)
        check_result(result, "failed to create window surfacd") or_return
    }

    // make sure surface supports the format specified in vk_ctx
    {
        format_count: u32
        result := vk.GetPhysicalDeviceSurfaceFormatsKHR(vk_ctx.physical_device, surface, &format_count, nil)
        check_result(result, "failed to get device surface formats") or_return
        formats := make([]vk.SurfaceFormatKHR, format_count, arena_allocator)
        defer delete(formats, arena_allocator)
        if formats == nil {
            log.error("failed to create surface formats array")
            return false
        }
        result = vk.GetPhysicalDeviceSurfaceFormatsKHR(vk_ctx.physical_device, surface, &format_count, raw_data(formats))
        check_result(result, "failed to get device surface formats") or_return

        format_found: bool = false
        for fmt in formats {
            if fmt == vk_ctx.surface_format {
                format_found = true
                break
            }
        }
        if !format_found {
            log.error("no suitable surface format found")
            return false
        }
    }

    swapchain := create_swapchain(vk_ctx, window, surface) or_return

    // create swapchain image views
    {
    }
    // create synchronization objects
    {
    }

    data.window    = window
    data.surface   = surface
    data.swapchain = swapchain
    return true
}

vulkan_window_data_destroy :: proc(data: ^Vulkan_Window_Data, vk_ctx: ^Vulkan_Context) {
    assert(data != nil && vk_ctx != nil)
    defer data^ = {}

    vk.DestroySwapchainKHR(vk_ctx.device, data.swapchain, nil)
    vk.DestroySurfaceKHR(vk_ctx.instance, data.surface, nil)
}

vulkan_window_data_update :: proc(data: ^Vulkan_Window_Data, vk_ctx: ^Vulkan_Context) -> (ok: bool) {
    // todo: Check if swapchain needs to be recreated
    swapchain := create_swapchain(vk_ctx, data.window, data.surface, data.swapchain) or_return
    return true
}
