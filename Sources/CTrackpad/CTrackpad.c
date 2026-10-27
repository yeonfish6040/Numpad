#include "CTrackpad.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <stddef.h>
#include <pthread.h>
#include <stdio.h>

// ABI of MultitouchSupport's contact record. Kept in C to preserve alignment.
typedef struct { float x, y; } TPPoint;
typedef struct { TPPoint position, velocity; } TPVector;
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier, state, fingerID, handID;
    TPVector normalized;
    float size;
    int32_t reserved1;
    float angle, majorAxis, minorAxis;
    TPVector absolute;
    int32_t reserved2[2];
    float density;
} Contact;
_Static_assert(sizeof(Contact) == 96, "Unexpected contact ABI");
_Static_assert(offsetof(Contact, normalized) == 32, "Unexpected position offset");

typedef int (*FrameCallback)(void *, Contact *, int, double, int);
#define MAX_DEVICES 64
static void *library;
static CFArrayRef deviceList;
static void *devices[MAX_DEVICES];
static TPDeviceInfo infos[MAX_DEVICES];
static int deviceCount;
static bool selected[MAX_DEVICES];
static bool deviceStarted[MAX_DEVICES];
static CFArrayRef (*createList)(void);
static int (*getDeviceID)(void *, uint64_t *);
static bool (*isBuiltIn)(void *);
static void (*registerCallback)(void *, FrameCallback);
static void (*unregisterCallback)(void *, FrameCallback);
static void (*startDevice)(void *, int);
static void (*stopDevice)(void *);
static bool (*isRunning)(void *);
static TPDeviceCallback receiver;
static TPCallback legacyReceiver;
static void *receiverContext;
static bool running;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static const char *errorMessage = "";

static uint64_t numberProperty(io_registry_entry_t entry, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    int64_t result = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID())
        CFNumberGetValue(value, kCFNumberSInt64Type, &result);
    if (value) CFRelease(value);
    return (uint64_t)result;
}

static bool stringProperty(io_registry_entry_t entry, CFStringRef key, char *output, int size) {
    // Do not inherit a hub/computer serial number: two physical trackpads
    // must never collapse into one preference identity.
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    bool ok = value && CFGetTypeID(value) == CFStringGetTypeID() &&
        CFStringGetCString(value, output, size, kCFStringEncodingUTF8) && output[0];
    if (value) CFRelease(value);
    return ok;
}

static int receiveFrame(void *sender, Contact *contacts, int count, double timestamp, int frame) {
    (void)frame;
    if (count < 0 || count > 32 || (count && !contacts)) return 0;
    TPTouch touches[32];
    int active = 0;
    for (int i = 0; i < count; i++) {
        if (contacts[i].state == 3 || contacts[i].state == 4) {
            touches[active++] = (TPTouch){contacts[i].identifier,
                contacts[i].normalized.position.x, contacts[i].normalized.position.y};
        }
    }
    pthread_mutex_lock(&lock);
    for (int i = 0; i < deviceCount; i++) {
        if (devices[i] == sender && selected[i]) {
            if (receiver) receiver(infos[i].identifier, touches, active, timestamp, receiverContext);
            if (legacyReceiver) legacyReceiver(touches, active, timestamp, receiverContext);
            break;
        }
    }
    pthread_mutex_unlock(&lock);
    return 0;
}

static bool loadAPI(void) {
    if (createList) return true;
    if (!library) library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL);
    if (!library) { errorMessage = "app.ui.could_not_load_the_multitouchsupport_framework"; return false; }
    getDeviceID = dlsym(library, "MTDeviceGetDeviceID");
    isBuiltIn = dlsym(library, "MTDeviceIsBuiltIn");
    registerCallback = dlsym(library, "MTRegisterContactFrameCallback");
    unregisterCallback = dlsym(library, "MTUnregisterContactFrameCallback");
    startDevice = dlsym(library, "MTDeviceStart");
    stopDevice = dlsym(library, "MTDeviceStop");
    isRunning = dlsym(library, "MTDeviceIsRunning");
    CFArrayRef (*list)(void) = dlsym(library, "MTDeviceCreateList");
    if (!list || !getDeviceID || !isBuiltIn || !registerCallback || !unregisterCallback || !startDevice || !stopDevice || !isRunning) {
        errorMessage = "app.ui.the_required_trackpad_api_is_unavailable_on_this_version_of_macos"; return false;
    }
    createList = list;
    return true;
}

static bool isTrackpadDevice(uint64_t identifier) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator) != KERN_SUCCESS) return false;
    bool trackpad = false;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        if (numberProperty(service, CFSTR("Multitouch ID")) == identifier) {
            CFTypeRef acceleration = IORegistryEntryCreateCFProperty(service, CFSTR("HIDPointerAccelerationType"), kCFAllocatorDefault, 0);
            trackpad = acceleration && CFEqual(acceleration, CFSTR("HIDTrackpadAcceleration"));
            if (acceleration) CFRelease(acceleration);
            CFTypeRef pairs = IORegistryEntryCreateCFProperty(service, CFSTR("DeviceUsagePairs"), kCFAllocatorDefault, 0);
            if (pairs && CFGetTypeID(pairs) == CFArrayGetTypeID()) {
                for (CFIndex i = 0; i < CFArrayGetCount(pairs); i++) {
                    CFTypeRef pair = CFArrayGetValueAtIndex(pairs, i);
                    if (CFGetTypeID(pair) != CFDictionaryGetTypeID()) continue;
                    CFTypeRef page = CFDictionaryGetValue(pair, CFSTR("DeviceUsagePage"));
                    CFTypeRef usage = CFDictionaryGetValue(pair, CFSTR("DeviceUsage"));
                    int p = 0, u = 0;
                    if (page && CFGetTypeID(page) == CFNumberGetTypeID()) CFNumberGetValue(page, kCFNumberIntType, &p);
                    if (usage && CFGetTypeID(usage) == CFNumberGetTypeID()) CFNumberGetValue(usage, kCFNumberIntType, &u);
                    if (p == 13 && u == 5) trackpad = true; // HID digitizer / touch pad
                }
            }
            if (pairs) CFRelease(pairs);
            IOObjectRelease(service); break;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return trackpad;
}

int32_t TPRefreshDevices(void) {
    if (running) return deviceCount;
    if (!loadAPI()) return 0;
    TPHapticShutdown();
    if (deviceList) CFRelease(deviceList);
    deviceList = createList();
    deviceCount = 0;
    if (deviceList) for (CFIndex i = 0; i < CFArrayGetCount(deviceList) && deviceCount < MAX_DEVICES; i++) {
        void *device = (void *)CFArrayGetValueAtIndex(deviceList, i);
        uint64_t identifier = 0;
        // Match HID trackpad usage/acceleration, excluding Magic Mouse and Touch Bar.
        if (getDeviceID(device, &identifier) != 0 || !identifier || !isTrackpadDevice(identifier)) continue;
        TPDeviceInfo info = {0};
        info.identifier = identifier;
        info.builtIn = isBuiltIn(device);
        snprintf(info.name, sizeof(info.name), "%s", info.builtIn ? "app.ui.built_in_trackpad" : "app.ui.external_trackpad");
        snprintf(info.persistentID, sizeof(info.persistentID), "%s:%llu", info.builtIn ? "builtin" : "device", (unsigned long long)identifier);
        io_iterator_t iterator = IO_OBJECT_NULL;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator) == KERN_SUCCESS) {
            io_service_t service;
            while ((service = IOIteratorNext(iterator))) {
                if (numberProperty(service, CFSTR("Multitouch ID")) == identifier) {
                    info.registryID = 0;
                    IORegistryEntryGetRegistryEntryID(service, &info.registryID);
                    stringProperty(service, CFSTR("Product"), info.name, sizeof(info.name));
                    char serial[192] = {0};
                    if (info.builtIn) snprintf(info.persistentID, sizeof(info.persistentID), "builtin");
                    else if (stringProperty(service, CFSTR("SerialNumber"), serial, sizeof(serial)) ||
                             stringProperty(service, CFSTR("HIDSerialNumber"), serial, sizeof(serial)))
                        snprintf(info.persistentID, sizeof(info.persistentID), "serial:%s", serial);
                    IOObjectRelease(service);
                    break;
                }
                IOObjectRelease(service);
            }
            IOObjectRelease(iterator);
        }
        devices[deviceCount] = device; infos[deviceCount++] = info;
    }
    if (!deviceCount) errorMessage = "app.ui.no_trackpad_found_connect_a_trackpad_and_try_again";
    return deviceCount;
}

bool TPInitialize(void) { return deviceCount > 0 || TPRefreshDevices() > 0; }
int32_t TPDeviceCount(void) { return deviceCount; }
bool TPGetDeviceInfo(int32_t index, TPDeviceInfo *info) {
    if (!info || index < 0 || index >= deviceCount) return false;
    *info = infos[index]; return true;
}

bool TPDevicesChanged(void) {
    if (!loadAPI()) return false;
    CFArrayRef list = createList();
    int count = 0;
    bool changed = false;
    if (list) for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        void *device = (void *)CFArrayGetValueAtIndex(list, i);
        uint64_t identifier = 0;
        if (getDeviceID(device, &identifier) != 0 || !identifier || !isTrackpadDevice(identifier)) continue;
        count++;
        bool found = false;
        for (int j = 0; j < deviceCount; j++) if (infos[j].identifier == identifier) found = true;
        if (!found) changed = true;
    }
    if (list) CFRelease(list);
    return changed || count != deviceCount;
}

bool TPStartDevices(const uint64_t *identifiers, int32_t count, TPDeviceCallback callback, void *context) {
    if (running || !identifiers || count <= 0 || count > MAX_DEVICES || !TPInitialize()) return false;
    pthread_mutex_lock(&lock);
    receiver = callback; receiverContext = context;
    for (int i = 0; i < deviceCount; i++) {
        selected[i] = false;
        for (int j = 0; j < count; j++) if (identifiers[j] == infos[i].identifier) selected[i] = true;
    }
    pthread_mutex_unlock(&lock);
    running = true;
    int started = 0;
    for (int i = 0; i < deviceCount; i++) if (selected[i]) {
        registerCallback(devices[i], receiveFrame);
        deviceStarted[i] = true;
        startDevice(devices[i], 0);
        started++;
        if (!isRunning(devices[i])) {
            errorMessage = "app.ui.could_not_start_receiving_trackpad_touches_check_the_connection_and_restart_numpad";
            TPStop(); return false;
        }
    }
    if (!started) { TPStop(); return false; }
    return true;
}

bool TPStart(TPCallback callback, void *context) {
    if (!TPInitialize()) return false;
    uint64_t identifier = infos[0].identifier;
    if (!TPStartDevices(&identifier, 1, NULL, context)) return false;
    pthread_mutex_lock(&lock); legacyReceiver = callback; pthread_mutex_unlock(&lock);
    return true;
}

void TPStop(void) {
    if (!running) return;
    pthread_mutex_lock(&lock);
    receiver = NULL; legacyReceiver = NULL; receiverContext = NULL;
    pthread_mutex_unlock(&lock);
    for (int i = 0; i < deviceCount; i++) if (deviceStarted[i]) {
        stopDevice(devices[i]); unregisterCallback(devices[i], receiveFrame);
        deviceStarted[i] = false;
    }
    pthread_mutex_lock(&lock);
    for (int i = 0; i < deviceCount; i++) selected[i] = false;
    pthread_mutex_unlock(&lock);
    running = false;
}

// Quartz's undocumented field 87 contains an IORegistry sender ID (see Mac
// Mouse Fix's EventUtility.m). Never infer a sender from recent touches.
uint64_t TPDeviceIDForSender(uint64_t senderID) {
    if (!senderID) return 0;
    io_registry_entry_t entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(senderID));
    for (int depth = 0; entry && depth < 16; depth++) {
        uint64_t identifier = numberProperty(entry, CFSTR("Multitouch ID"));
        if (!identifier && IOObjectConformsTo(entry, "IOHIDDevice")) {
            CFTypeRef value = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, CFSTR("Multitouch ID"), kCFAllocatorDefault, kIORegistryIterateRecursively);
            int64_t number = 0;
            if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberSInt64Type, &number);
            if (value) CFRelease(value);
            identifier = (uint64_t)number;
        }
        if (identifier) { IOObjectRelease(entry); return identifier; }
        io_registry_entry_t parent = IO_OBJECT_NULL;
        IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent);
        IOObjectRelease(entry); entry = parent;
    }
    if (entry) IOObjectRelease(entry);
    return 0;
}
const char *TPError(void) { return errorMessage; }

// AppKit may omit feedback after lift-off. Drive the Force Touch actuator
// directly so release-confirmed taps still receive exactly one short pulse.
static CFTypeRef actuator;
static CFTypeRef (*createActuator)(uint64_t);
static IOReturn (*openActuator)(CFTypeRef);
static IOReturn (*closeActuator)(CFTypeRef);
static IOReturn (*actuate)(CFTypeRef, int32_t, uint32_t, float, float);

static uint64_t actuatorDeviceID;
static bool initializeActuator(uint64_t identifier) {
    if (actuator && actuatorDeviceID == identifier) return true;
    TPHapticShutdown();
    if (!TPInitialize()) return false;
    createActuator = dlsym(library, "MTActuatorCreateFromDeviceID");
    openActuator = dlsym(library, "MTActuatorOpen");
    closeActuator = dlsym(library, "MTActuatorClose");
    actuate = dlsym(library, "MTActuatorActuate");
    if (!createActuator || !openActuator || !closeActuator || !actuate) return false;
    actuator = createActuator(identifier);
    actuatorDeviceID = identifier;
    return actuator != NULL;
}

static bool performHaptic(uint64_t identifier, int32_t pattern) {
    if (!initializeActuator(identifier)) return false;
    if (openActuator(actuator) != kIOReturnSuccess) {
        TPHapticShutdown(); return false;
    }
    // Predefined pulse; no custom waveform or continuous vibration.
    IOReturn result = actuate(actuator, pattern, 0, 0.0f, 0.0f);
    IOReturn closed = closeActuator(actuator);
    if (result != kIOReturnSuccess || closed != kIOReturnSuccess) {
        TPHapticShutdown(); return false;
    }
    return true;
}

bool TPHapticForDevice(uint64_t identifier, bool strong) { return performHaptic(identifier, strong ? 6 : 3); }
bool TPHapticClick(void) { return TPInitialize() && performHaptic(infos[0].identifier, 3); }
bool TPHapticCenter(void) { return TPInitialize() && performHaptic(infos[0].identifier, 6); }

void TPHapticShutdown(void) {
    if (actuator) { CFRelease(actuator); actuator = NULL; }
}
