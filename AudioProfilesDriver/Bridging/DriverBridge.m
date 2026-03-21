// DriverBridge.m — AudioProfilesDriver
//
// Creates the COM-style AudioServerPlugInDriverInterface vtable and hands
// a pointer to it back to coreaudiod via the factory function.
//
// Every function slot points to a @_cdecl Swift function in DriverMain.swift.
// The Swift symbols are declared as extern C here so the linker can find them.

#import <CoreAudio/AudioServerPlugIn.h>
#import <os/log.h>

static os_log_t sLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.audioprofiles.driver", "bridge"); });
    return log;
}

// ---------------------------------------------------------------------------
// Forward declarations — implemented in DriverMain.swift via @_cdecl
// ---------------------------------------------------------------------------

extern OSStatus AP_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);

extern OSStatus AP_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef,
                                const AudioServerPlugInClientInfo*, AudioObjectID*);
extern OSStatus AP_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);

extern OSStatus AP_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID,
                                   const AudioServerPlugInClientInfo*);
extern OSStatus AP_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID,
                                     const AudioServerPlugInClientInfo*);

extern OSStatus AP_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef,
                                                    AudioObjectID, UInt64, void*);
extern OSStatus AP_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef,
                                                  AudioObjectID, UInt64, void*);

extern Boolean  AP_HasProperty(AudioServerPlugInDriverRef, AudioObjectID,
                               pid_t, const AudioObjectPropertyAddress*);
extern OSStatus AP_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID,
                                      pid_t, const AudioObjectPropertyAddress*,
                                      Boolean*);
extern OSStatus AP_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID,
                                       pid_t, const AudioObjectPropertyAddress*,
                                       UInt32, const void*, UInt32*);
extern OSStatus AP_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID,
                                   pid_t, const AudioObjectPropertyAddress*,
                                   UInt32, const void*, UInt32, UInt32*, void*);
extern OSStatus AP_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID,
                                   pid_t, const AudioObjectPropertyAddress*,
                                   UInt32, const void*, UInt32, const void*);

extern OSStatus AP_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
extern OSStatus AP_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);

extern OSStatus AP_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID,
                                    UInt32, Float64*, UInt64*, UInt64*);

extern OSStatus AP_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID,
                                     UInt32, UInt32, Boolean*, Boolean*);
extern OSStatus AP_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID,
                                    UInt32, UInt32, UInt32,
                                    const AudioServerPlugInIOCycleInfo*);
extern OSStatus AP_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID,
                                 AudioObjectID, UInt32, UInt32, UInt32,
                                 const AudioServerPlugInIOCycleInfo*,
                                 void*, void*);
extern OSStatus AP_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID,
                                  UInt32, UInt32, UInt32,
                                  const AudioServerPlugInIOCycleInfo*);

// ---------------------------------------------------------------------------
// COM IUnknown — QueryInterface / AddRef / Release
// Core Audio calls QueryInterface immediately after the factory returns.
// Leaving these NULL causes an instruction-abort crash at PC=0.
// ---------------------------------------------------------------------------

static ULONG AP_AddRef(void* __unused inDriver)
{
    return 1;
}

static ULONG AP_Release(void* __unused inDriver)
{
    return 1;
}

static HRESULT AP_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    os_log_info(sLog(), "AP_QueryInterface called, inDriver=%p", inDriver);
    CFUUIDRef requestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    CFStringRef uuidStr = CFUUIDCreateString(NULL, requestedUUID);
    os_log_info(sLog(), "AP_QueryInterface UUID=%{public}@", uuidStr);
    CFRelease(uuidStr);
    if (CFEqual(requestedUUID, IUnknownUUID) ||
        CFEqual(requestedUUID, kAudioServerPlugInDriverInterfaceUUID))
    {
        CFRelease(requestedUUID);
        *outInterface = inDriver;
        os_log_info(sLog(), "AP_QueryInterface -> S_OK");
        return S_OK;
    }
    CFRelease(requestedUUID);
    *outInterface = NULL;
    os_log_info(sLog(), "AP_QueryInterface -> E_NOINTERFACE");
    return (HRESULT)E_NOINTERFACE;
}

// ---------------------------------------------------------------------------
// vtable — one global instance, never freed
// ---------------------------------------------------------------------------

static AudioServerPlugInDriverInterface gDriverInterface = {
    /* _reserved       */ NULL,
    /* QueryInterface  */ AP_QueryInterface,
    /* AddRef          */ AP_AddRef,
    /* Release         */ AP_Release,

    AP_Initialize,
    AP_CreateDevice,
    AP_DestroyDevice,
    AP_AddDeviceClient,
    AP_RemoveDeviceClient,
    AP_PerformDeviceConfigurationChange,
    AP_AbortDeviceConfigurationChange,
    AP_HasProperty,
    AP_IsPropertySettable,
    AP_GetPropertyDataSize,
    AP_GetPropertyData,
    AP_SetPropertyData,
    AP_StartIO,
    AP_StopIO,
    AP_GetZeroTimeStamp,
    AP_WillDoIOOperation,
    AP_BeginIOOperation,
    AP_DoIOOperation,
    AP_EndIOOperation
};

static AudioServerPlugInDriverInterface* gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverRef        gDriverRef           = &gDriverInterfacePtr;

// ---------------------------------------------------------------------------
// Factory — the only symbol coreaudiod looks for by name (CFPlugIn)
// ---------------------------------------------------------------------------

void* AudioProfilesDriver_Create(CFAllocatorRef  inAllocator __unused,
                                  CFUUIDRef        inRequestedTypeUUID)
{
    os_log_info(sLog(), "AudioProfilesDriver_Create called");
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        os_log_error(sLog(), "AudioProfilesDriver_Create: wrong UUID, returning NULL");
        return NULL;
    }
    os_log_info(sLog(), "AudioProfilesDriver_Create -> gDriverRef=%p (vtable=%p)", gDriverRef, *gDriverRef);
    return gDriverRef;
}
