#ifndef C_TRACKPAD_H
#define C_TRACKPAD_H
#include <stdbool.h>
#include <stdint.h>

typedef struct { int32_t identifier; float x, y; } TPTouch;
// Valid only for the duration of the callback; callbacks run on a framework thread.
typedef void (*TPCallback)(const TPTouch *touches, int32_t count, double timestamp, void *context);
typedef void (*TPDeviceCallback)(uint64_t deviceID, const TPTouch *touches, int32_t count, double timestamp, void *context);
typedef struct {
    uint64_t identifier, registryID;
    bool builtIn;
    char name[128];
    char persistentID[256];
} TPDeviceInfo;
// Refresh only while stopped. Info and selection are main-thread only.
int32_t TPRefreshDevices(void);
int32_t TPDeviceCount(void);
bool TPGetDeviceInfo(int32_t index, TPDeviceInfo *info);
bool TPDevicesChanged(void);
bool TPStartDevices(const uint64_t *identifiers, int32_t count, TPDeviceCallback callback, void *context);
uint64_t TPDeviceIDForSender(uint64_t senderID);
bool TPHapticForDevice(uint64_t identifier, bool strong);
bool TPInitialize(void);
bool TPStart(TPCallback callback, void *context);
void TPStop(void);
// Main-thread only. Uses a short, weak trackpad actuation at confirmed input.
bool TPHapticClick(void);
// Stronger predefined pulse for entering/leaving the 5 center.
bool TPHapticCenter(void);
void TPHapticShutdown(void);
const char *TPError(void);
#endif
