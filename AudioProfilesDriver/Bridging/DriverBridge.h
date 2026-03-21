// DriverBridge.h — AudioProfilesDriver
//
// C header exposing the factory function that CoreAudio calls to create
// the plugin driver instance. This is the only C symbol the driver exports.

#pragma once
#import <CoreAudio/AudioServerPlugIn.h>

/// Entry point called by coreaudiod when it loads the .driver bundle.
/// Declared in DriverBridge.m; all C function pointer slots in the vtable
/// point to @_cdecl Swift functions defined in DriverMain.swift.
extern void* AudioProfilesDriver_Create(CFAllocatorRef inAllocator,
                                        CFUUIDRef       inRequestedTypeUUID);
