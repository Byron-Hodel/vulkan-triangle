package main

import "core:fmt"
import "core:math/linalg/glsl"
import "core:mem"
import "core:reflect"
import "vendor:glfw"
import vk "vendor:vulkan"

VALIDATION_LAYERS: []cstring = {
    //"VK_LAYER_KHRONOS_validation",
}

DEVICE_EXTENSIONS :: 1

Vulkan_Data :: struct {
    instance: vk.Instance,
    device:   vk.Device,
}

vulkan_data_init :: proc(vk_data: ^Vulkan_Data) -> (ok: bool) {
    get_proc_address :: proc(p: rawptr, name: cstring) {
		(cast(^rawptr)p)^ = glfw.GetInstanceProcAddress((^vk.Instance)(context.user_ptr)^, name);
	}
    arena_buffer: [4098]u8 = ---
    arena: mem.Arena
    mem.arena_init(&arena, arena_buffer[:])
    arena_allocator := mem.arena_allocator(&arena)
    // sets arena offset to some value
    restore_arena :: proc(a: ^mem.Arena, offset: int) {
        a.offset = offset
    }

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

        //glfw_required_extensions := glfw.GetRequiredInstanceExtensions()

        instance_info := vk.InstanceCreateInfo {
            sType = .INSTANCE_CREATE_INFO,
            pApplicationInfo = &app_info,
            //enabledExtensionCount = cast(u32)len(glfw_required_extensions),
            //ppEnabledExtensionNames = raw_data(glfw_required_extensions),
            enabledLayerCount = cast(u32)len(VALIDATION_LAYERS),
            ppEnabledLayerNames = raw_data(VALIDATION_LAYERS),
        }

        result := vk.CreateInstance(&instance_info, nil, &instance)
        if result != .SUCCESS {
            fmt.eprintln("failed to create vulkan instance:", reflect.enum_string(result))
            return false
        }
	    vk.load_proc_addresses(instance)
    }
    defer if !ok {
        vk.DestroyInstance(instance, nil)
    }
    fmt.println("created instance")

    // select physical device
    physical_device: vk.PhysicalDevice
    {
        is_physical_device_valid :: proc(d: vk.PhysicalDevice) -> b32 {
            indexing_features := vk.PhysicalDeviceDescriptorIndexingFeatures {
                sType = .PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES,
            }
            features := vk.PhysicalDeviceFeatures2 {
                sType = .PHYSICAL_DEVICE_FEATURES_2,
                pNext = &indexing_features,
            }
            vk.GetPhysicalDeviceFeatures2(d, &features)

            bindless_supported: b32 = indexing_features.descriptorBindingPartiallyBound && indexing_features.runtimeDescriptorArray
            
            return bindless_supported
        }
        defer restore_arena(&arena, arena.offset)

        device_count: u32
        vk.EnumeratePhysicalDevices(instance, &device_count, nil)
        physical_device_list := make([]vk.PhysicalDevice, device_count, arena_allocator)
        if physical_device_list == nil {
            fmt.eprintln()
        }
        vk.EnumeratePhysicalDevices(instance, &device_count, raw_data(physical_device_list))
        
        has_selected_device: bool = false
        selected_device: vk.PhysicalDevice
        selected_properties: vk.PhysicalDeviceProperties
        for d in physical_device_list {
            properties: vk.PhysicalDeviceProperties
            vk.GetPhysicalDeviceProperties(d, &properties)

            if is_physical_device_valid(d) || properties.deviceType == .DISCRETE_GPU || properties.deviceType == .INTEGRATED_GPU {
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
            ok = false
            fmt.eprintln("failed to find suitable physical device")
            return
        }
        physical_device = selected_device
    }
    fmt.println("selected physical device")

    // get queue families
    queue_family_properties: []vk.QueueFamilyProperties
    {
        queue_family_count: u32
        vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, nil)
        queue_family_properties = make([]vk.QueueFamilyProperties, queue_family_count, arena_allocator)
        vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, raw_data(queue_family_properties))

        for p, i in queue_family_properties {
            fmt.println("queue family:", i)
            if .GRAPHICS in p.queueFlags         do fmt.println("  Graphics: ----- Y")
            else                                 do fmt.println("  Graphics: ----- N")
            if .COMPUTE in p.queueFlags          do fmt.println("  Compute: ------ Y")
            else                                 do fmt.println("  Compute: ------ N")
            if .TRANSFER in p.queueFlags         do fmt.println("  Transfer: ----- Y")
            else                                 do fmt.println("  Compute: ------ N")
            if .SPARSE_BINDING in p.queueFlags   do fmt.println("  Sparse Binding: Y")
            else                                 do fmt.println("  Sparse Binding: N")
            if .PROTECTED in p.queueFlags        do fmt.println("  Protected: ---- Y")
            else                                 do fmt.println("  Protected: ---- N")
            if .VIDEO_DECODE_KHR in p.queueFlags do fmt.println("  Vidio Decode: - Y")
            else                                 do fmt.println("  Vidio Decode: - N")
            if .OPTICAL_FLOW_NV in p.queueFlags  do fmt.println("  Optical Flow: - Y")
            else                                 do fmt.println("  Optical Flow: - N")
            fmt.println("  max queues", p.queueCount)
        }
    }

    // select queue family indices
    graphics_index, compute_index, transfer_index: i32 = -1, -1, -1
    graphics_unique, compute_unique, transfer_unique: b8
    {
        for f, i in queue_family_properties {
            if graphics_index == -1 && .GRAPHICS in f.queueFlags do graphics_index = cast(i32)i
            if compute_index  == -1 && .COMPUTE  in f.queueFlags do compute_index  = cast(i32)i
            if transfer_index == -1 && .TRANSFER in f.queueFlags do transfer_index = cast(i32)i
            
            if .TRANSFER in f.queueFlags && transmute(i32)f.queueFlags < transmute(i32)queue_family_properties[transfer_index].queueFlags {
                transfer_index = cast(i32)i
            }

            if .COMPUTE in f.queueFlags && transmute(i32)f.queueFlags < transmute(i32)queue_family_properties[compute_index].queueFlags {
                compute_index = cast(i32)i
            }
        }

        graphics_unique = graphics_index != compute_index  && graphics_index != transfer_index
        compute_unique  = compute_index  != graphics_index && compute_index  != transfer_index
        transfer_unique = transfer_index != graphics_index && transfer_index != compute_index

        fmt.println("Graphics Family Index:", graphics_index, "is unique =", graphics_unique)
        fmt.println("Compute Family Index: ", compute_index, "is unique =", compute_unique)
        fmt.println("Transfer Family Index:", transfer_index, "is unique =", transfer_unique)
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
        if compute_unique {
            defer queue_info_count += 1
            queue_infos[queue_info_count] = vk.DeviceQueueCreateInfo {
                sType = .DEVICE_QUEUE_CREATE_INFO,
                queueFamilyIndex = transmute(u32)compute_index,
                queueCount = 1,
                pQueuePriorities = &queue_priority,
            }
        }

        if transfer_unique {
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
            pEnabledFeatures = &device_features,
        }

        result := vk.CreateDevice(physical_device, &device_info, nil, &device)
        if result != .SUCCESS {
            fmt.eprintln("failed to create vulkan device:", reflect.enum_string(result))
            return
        }
    }
    defer if !ok {
        vk.DestroyDevice(device, nil)
    }

    vk_data.instance = instance
    vk_data.device   = device
    return false 
}
