// A11: what the host Vulkan (MoltenVK) offers Venus. Usage: vkprobe /path/to/libMoltenVK.dylib
// SPDX-License-Identifier: GPL-2.0-or-later
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

static const char *want[] = {
    "VK_EXT_external_memory_host", "VK_EXT_external_memory_metal", "VK_EXT_metal_objects", "VK_KHR_external_memory",
    "VK_KHR_external_memory_fd", "VK_KHR_timeline_semaphore", "VK_EXT_image_drm_format_modifier", "VK_EXT_queue_family_foreign",
    "VK_KHR_dedicated_allocation", "VK_KHR_maintenance4", "VK_KHR_portability_subset",
};

int main(int argc, char **argv) {
    void *h = dlopen(argc > 1 ? argv[1] : "libMoltenVK.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }
    PFN_vkGetInstanceProcAddr gipa = (PFN_vkGetInstanceProcAddr)dlsym(h, "vkGetInstanceProcAddr");
    PFN_vkCreateInstance ci = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
    PFN_vkEnumerateInstanceVersion ev = (PFN_vkEnumerateInstanceVersion)gipa(NULL, "vkEnumerateInstanceVersion");
    uint32_t iv = 0;
    ev(&iv);
    printf("instance version %u.%u.%u\n", VK_VERSION_MAJOR(iv), VK_VERSION_MINOR(iv), VK_VERSION_PATCH(iv));
    const char *iexts[] = {"VK_KHR_portability_enumeration", "VK_KHR_get_physical_device_properties2"};
    VkApplicationInfo ai = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3};
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
                                .pApplicationInfo = &ai, .enabledExtensionCount = 2, .ppEnabledExtensionNames = iexts};
    VkInstance inst;
    VkResult r = ci(&ici, NULL, &inst);
    if (r) { ici.flags = 0; ici.enabledExtensionCount = 1; ici.ppEnabledExtensionNames = iexts + 1; r = ci(&ici, NULL, &inst); }
    if (r) { printf("vkCreateInstance %d\n", r); return 1; }
#define IP(n) PFN_##n n = (PFN_##n)gipa(inst, #n)
    IP(vkEnumeratePhysicalDevices); IP(vkGetPhysicalDeviceProperties2); IP(vkEnumerateDeviceExtensionProperties);
    IP(vkGetPhysicalDeviceMemoryProperties); IP(vkGetPhysicalDeviceFeatures2);
    uint32_t n = 1;
    VkPhysicalDevice pd;
    vkEnumeratePhysicalDevices(inst, &n, &pd);
    VkPhysicalDeviceExternalMemoryHostPropertiesEXT emh = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_MEMORY_HOST_PROPERTIES_EXT};
    VkPhysicalDeviceProperties2 p2 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &emh};
    vkGetPhysicalDeviceProperties2(pd, &p2);
    printf("device %s, api %u.%u.%u, driver %u\n", p2.properties.deviceName, VK_VERSION_MAJOR(p2.properties.apiVersion),
           VK_VERSION_MINOR(p2.properties.apiVersion), VK_VERSION_PATCH(p2.properties.apiVersion), p2.properties.driverVersion);
    printf("minImportedHostPointerAlignment %llu\n", (unsigned long long)emh.minImportedHostPointerAlignment);
    uint32_t ne = 0;
    vkEnumerateDeviceExtensionProperties(pd, NULL, &ne, NULL);
    VkExtensionProperties *e = calloc(ne, sizeof *e);
    vkEnumerateDeviceExtensionProperties(pd, NULL, &ne, e);
    printf("%u device extensions\n", ne);
    for (size_t i = 0; i < sizeof want / sizeof *want; i++) {
        int has = 0;
        for (uint32_t k = 0; k < ne; k++) has |= !strcmp(e[k].extensionName, want[i]);
        printf("  %-36s %s\n", want[i], has ? "yes" : "no");
    }
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++) printf("  memtype %u flags 0x%x heap %u\n", i, mp.memoryTypes[i].propertyFlags, mp.memoryTypes[i].heapIndex);
    for (uint32_t i = 0; i < mp.memoryHeapCount; i++) printf("  heap %u size %llu MB\n", i, (unsigned long long)(mp.memoryHeaps[i].size >> 20));
    VkPhysicalDeviceVulkan12Features f12 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};
    VkPhysicalDeviceFeatures2 f2 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &f12};
    vkGetPhysicalDeviceFeatures2(pd, &f2);
    printf("timelineSemaphore %u bufferDeviceAddress %u geometryShader %u\n", f12.timelineSemaphore, f12.bufferDeviceAddress, f2.features.geometryShader);
    return 0;
}
