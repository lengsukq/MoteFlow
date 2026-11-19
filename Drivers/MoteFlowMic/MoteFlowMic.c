// MoteFlowMic.c
// Input-Only CoreAudio AudioServerPlugIn virtual microphone for MoteFlow.
//
// Architecture:
// - Exposes a single virtual audio device ("MoteFlow Mic") with 1 Input stream
//   (48 kHz, 2ch Float32) and ZERO Output streams.
// - Because MoteFlow pushes decoded ATVV PCM directly via CoreAudio custom
//   property 'MFPC' instead of playing through AudioQueueNewOutput, macOS
//   Screen Sharing has NO output audio stream to capture -> 100% zero echo.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

// MARK: - Constants & Identifiers

#define kPlugIn_BundleID            "app.google-remote.mac.MoteFlowMic"
#define kDevice_UID                 "MoteFlowMic_Device_UID_v1"
#define kDevice_ModelUID            "MoteFlowMic_Model_UID_v1"
#define kDevice_Name                "MoteFlow Mic"
#define kDevice_Manufacturer        "MoteFlow"

// Custom CoreAudio property selectors marshaled across coreaudiod IPC.
// Both use kAudioServerPlugInCustomPropertyDataTypeCFPropertyList.
// - 'MFPC': CFDataRef of interleaved Int16 stereo 48kHz PCM frames (4 bytes/frame)
// - 'MFRS': Any CFPropertyListRef (e.g. kCFBooleanTrue) to clear the ring buffer
enum {
    kMoteFlowMicPropertyPushPCM     = 'MFPC',
    kMoteFlowMicPropertyResetBuffer = 'MFRS'
};

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject, // 1
    kObjectID_Device        = 2,
    kObjectID_Stream_Input  = 3
};

#define kSampleRate                 48000.0
#define kNumChannels                2
#define kZeroTimeStampPeriod        16384U
#define kRingBufferFrames           (48000U * 2U) // 2.0 seconds capacity

// MARK: - Lock-Free SPSC Ring Buffer (Stereo Float32)

static float gRingBuffer[kRingBufferFrames * kNumChannels];
static _Atomic uint64_t gWriteFrame = 0;
static _Atomic uint64_t gReadFrame  = 0;

static void RingBuffer_Reset(void) {
    uint64_t w = atomic_load_explicit(&gWriteFrame, memory_order_acquire);
    atomic_store_explicit(&gReadFrame, w, memory_order_release);
}

static void RingBuffer_PushInt16Stereo(const int16_t *samples, uint32_t frameCount) {
    if (samples == NULL || frameCount == 0) {
        return;
    }
    uint64_t writePos = atomic_load_explicit(&gWriteFrame, memory_order_relaxed);
    uint64_t readPos  = atomic_load_explicit(&gReadFrame, memory_order_acquire);

    // Prevent unbounded lag: if queued audio exceeds 1.5s, advance read pointer.
    uint64_t maxQueued = (kRingBufferFrames * 3U) / 4U;
    if (writePos >= readPos && (writePos - readPos) + frameCount > maxQueued) {
        uint64_t newRead = (writePos + frameCount > maxQueued) ? (writePos + frameCount - maxQueued) : 0;
        atomic_store_explicit(&gReadFrame, newRead, memory_order_release);
    }

    const float scale = 1.0f / 32768.0f;
    for (uint32_t i = 0; i < frameCount; ++i) {
        uint32_t slot = (uint32_t)((writePos + i) % kRingBufferFrames) * kNumChannels;
        gRingBuffer[slot]     = (float)samples[i * 2]     * scale;
        gRingBuffer[slot + 1] = (float)samples[i * 2 + 1] * scale;
    }
    atomic_store_explicit(&gWriteFrame, writePos + frameCount, memory_order_release);
}

static void RingBuffer_ReadFloat32Stereo(float *outBuffer, uint32_t frameCount) {
    if (outBuffer == NULL || frameCount == 0) {
        return;
    }
    uint64_t readPos  = atomic_load_explicit(&gReadFrame, memory_order_relaxed);
    uint64_t writePos = atomic_load_explicit(&gWriteFrame, memory_order_acquire);

    uint64_t available = (writePos > readPos) ? (writePos - readPos) : 0;
    uint32_t toRead = (available < frameCount) ? (uint32_t)available : frameCount;

    for (uint32_t i = 0; i < toRead; ++i) {
        uint32_t slot = (uint32_t)((readPos + i) % kRingBufferFrames) * kNumChannels;
        outBuffer[i * 2]     = gRingBuffer[slot];
        outBuffer[i * 2 + 1] = gRingBuffer[slot + 1];
    }
    if (toRead > 0) {
        atomic_store_explicit(&gReadFrame, readPos + toRead, memory_order_release);
    }
    if (toRead < frameCount) {
        memset(outBuffer + (size_t)toRead * kNumChannels,
               0,
               (size_t)(frameCount - toRead) * kNumChannels * sizeof(float));
    }
}

// MARK: - PlugIn State

static os_unfair_lock               gStateLock = OS_UNFAIR_LOCK_INIT;
static AudioServerPlugInHostRef     gPlugInHost = NULL;
static UInt32                       gPlugInRefCount = 0;
static UInt32                       gIOClientCount = 0;
static UInt64                       gAnchorHostTime = 0;
static Float64                      gHostTicksPerFrame = 0.0;

static AudioStreamBasicDescription MakeCanonicalASBD(void) {
    AudioStreamBasicDescription desc;
    memset(&desc, 0, sizeof(desc));
    desc.mSampleRate       = kSampleRate;
    desc.mFormatID         = kAudioFormatLinearPCM;
    desc.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    desc.mBytesPerPacket   = kNumChannels * sizeof(Float32);
    desc.mFramesPerPacket  = 1;
    desc.mBytesPerFrame    = kNumChannels * sizeof(Float32);
    desc.mChannelsPerFrame = kNumChannels;
    desc.mBitsPerChannel   = 32;
    return desc;
}

static AudioStreamRangedDescription MakeCanonicalRangedASBD(void) {
    AudioStreamRangedDescription desc;
    desc.mFormat = MakeCanonicalASBD();
    desc.mSampleRateRange.mMinimum = kSampleRate;
    desc.mSampleRateRange.mMaximum = kSampleRate;
    return desc;
}

// MARK: - Forward Declarations

static HRESULT  MF_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG    MF_AddRef(void *inDriver);
static ULONG    MF_Release(void *inDriver);
static OSStatus MF_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus MF_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus MF_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus MF_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus MF_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus MF_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static OSStatus MF_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static Boolean  MF_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus MF_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus MF_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus MF_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus MF_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus MF_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus MF_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus MF_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus MF_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus MF_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus MF_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus MF_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,
    MF_QueryInterface,
    MF_AddRef,
    MF_Release,
    MF_Initialize,
    MF_CreateDevice,
    MF_DestroyDevice,
    MF_AddDeviceClient,
    MF_RemoveDeviceClient,
    MF_PerformDeviceConfigurationChange,
    MF_AbortDeviceConfigurationChange,
    MF_HasProperty,
    MF_IsPropertySettable,
    MF_GetPropertyDataSize,
    MF_GetPropertyData,
    MF_SetPropertyData,
    MF_StartIO,
    MF_StopIO,
    MF_GetZeroTimeStamp,
    MF_WillDoIOOperation,
    MF_BeginIOOperation,
    MF_DoIOOperation,
    MF_EndIOOperation
};

static AudioServerPlugInDriverInterface *gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverRef        gDriverRef          = &gDriverInterfacePtr;

// MARK: - Factory Entry Point

void *MoteFlowMic_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return NULL;
}

// MARK: - COM / Lifecycle

static HRESULT MF_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    (void)inDriver;
    if (outInterface == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) {
        *outInterface = NULL;
        return E_NOINTERFACE;
    }
    Boolean matched = CFEqual(requested, IUnknownUUID) ||
                      CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (matched) {
        MF_AddRef(inDriver);
        *outInterface = gDriverRef;
        return S_OK;
    }
    *outInterface = NULL;
    return E_NOINTERFACE;
}

static ULONG MF_AddRef(void *inDriver) {
    (void)inDriver;
    os_unfair_lock_lock(&gStateLock);
    UInt32 count = ++gPlugInRefCount;
    os_unfair_lock_unlock(&gStateLock);
    return count;
}

static ULONG MF_Release(void *inDriver) {
    (void)inDriver;
    os_unfair_lock_lock(&gStateLock);
    UInt32 count = (gPlugInRefCount > 0) ? --gPlugInRefCount : 0;
    os_unfair_lock_unlock(&gStateLock);
    return count;
}

static OSStatus MF_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    (void)inDriver;
    os_unfair_lock_lock(&gStateLock);
    gPlugInHost = inHost;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    Float64 ticksPerSecond = 1000000000.0 * ((Float64)tb.denom / (Float64)tb.numer);
    gHostTicksPerFrame = ticksPerSecond / kSampleRate;
    gAnchorHostTime = mach_absolute_time();
    os_unfair_lock_unlock(&gStateLock);
    RingBuffer_Reset();
    return kAudioHardwareNoError;
}

static OSStatus MF_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus MF_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus MF_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return kAudioHardwareNoError;
}

static OSStatus MF_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return kAudioHardwareNoError;
}

static OSStatus MF_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

static OSStatus MF_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

// MARK: - Property Dispatch Helpers

static Boolean HasPlugInProperty(const AudioObjectPropertyAddress *addr) {
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default:
            return false;
    }
}

static Boolean HasDeviceProperty(const AudioObjectPropertyAddress *addr) {
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kMoteFlowMicPropertyPushPCM:
        case kMoteFlowMicPropertyResetBuffer:
            return true;
        default:
            return false;
    }
}

static Boolean HasStreamProperty(const AudioObjectPropertyAddress *addr) {
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

static Boolean MF_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress) {
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL) return false;
    switch (inObjectID) {
        case kObjectID_PlugIn:       return HasPlugInProperty(inAddress);
        case kObjectID_Device:       return HasDeviceProperty(inAddress);
        case kObjectID_Stream_Input: return HasStreamProperty(inAddress);
        default:                     return false;
    }
}

static OSStatus MF_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    *outIsSettable = false;
    if (inObjectID == kObjectID_Device) {
        switch (inAddress->mSelector) {
            case kMoteFlowMicPropertyPushPCM:
            case kMoteFlowMicPropertyResetBuffer:
                *outIsSettable = true;
                return kAudioHardwareNoError;
            default:
                return HasDeviceProperty(inAddress) ? kAudioHardwareNoError : kAudioHardwareUnknownPropertyError;
        }
    }
    if (inObjectID == kObjectID_PlugIn) {
        return HasPlugInProperty(inAddress) ? kAudioHardwareNoError : kAudioHardwareUnknownPropertyError;
    }
    if (inObjectID == kObjectID_Stream_Input) {
        return HasStreamProperty(inAddress) ? kAudioHardwareNoError : kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareBadObjectError;
}

static OSStatus MF_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;

    if (inObjectID == kObjectID_PlugIn) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
                *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
            case kAudioPlugInPropertyTranslateUIDToDevice:
                *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioObjectPropertyManufacturer:
            case kAudioPlugInPropertyResourceBundle:
                *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kObjectID_Device) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
                *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
            case kAudioDevicePropertyRelatedDevices:
                *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
                *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyStreams:
                if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                    *outDataSize = 0; // ZERO output streams!
                } else {
                    *outDataSize = sizeof(AudioObjectID);
                }
                return kAudioHardwareNoError;
            case kAudioObjectPropertyControlList:
                *outDataSize = 0; return kAudioHardwareNoError;
            case kAudioObjectPropertyCustomPropertyInfoList:
                *outDataSize = 2 * sizeof(AudioServerPlugInCustomPropertyInfo); return kAudioHardwareNoError;
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod:
                *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyNominalSampleRate:
                *outDataSize = sizeof(Float64); return kAudioHardwareNoError;
            case kAudioDevicePropertyAvailableNominalSampleRates:
                *outDataSize = sizeof(AudioValueRange); return kAudioHardwareNoError;
            case kAudioDevicePropertyPreferredChannelsForStereo:
                *outDataSize = 2 * sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyPreferredChannelLayout:
                *outDataSize = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kNumChannels * sizeof(AudioChannelDescription));
                return kAudioHardwareNoError;
            case kMoteFlowMicPropertyPushPCM:
            case kMoteFlowMicPropertyResetBuffer:
                *outDataSize = sizeof(CFPropertyListRef); return kAudioHardwareNoError;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kObjectID_Stream_Input) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
                *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioObjectPropertyName:
                *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:
                *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                *outDataSize = sizeof(AudioStreamBasicDescription); return kAudioHardwareNoError;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                *outDataSize = sizeof(AudioStreamRangedDescription); return kAudioHardwareNoError;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    return kAudioHardwareBadObjectError;
}

static OSStatus MF_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;

    if (inObjectID == kObjectID_PlugIn) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                *(AudioClassID *)outData = kAudioObjectClassID;
                *outDataSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyClass:
                if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                *(AudioClassID *)outData = kAudioPlugInClassID;
                *outDataSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                *(AudioObjectID *)outData = kAudioObjectUnknown;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyManufacturer:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *(CFStringRef *)outData = CFSTR(kDevice_Manufacturer);
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                *(AudioObjectID *)outData = kObjectID_Device;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioPlugInPropertyTranslateUIDToDevice:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                if (inQualifierDataSize == sizeof(CFStringRef) && inQualifierData != NULL) {
                    CFStringRef uid = *(const CFStringRef *)inQualifierData;
                    if (uid != NULL && CFEqual(uid, CFSTR(kDevice_UID))) {
                        *(AudioObjectID *)outData = kObjectID_Device;
                    } else {
                        *(AudioObjectID *)outData = kAudioObjectUnknown;
                    }
                } else {
                    *(AudioObjectID *)outData = kAudioObjectUnknown;
                }
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioPlugInPropertyResourceBundle:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *(CFStringRef *)outData = CFSTR("");
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kObjectID_Device) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                *(AudioClassID *)outData = kAudioObjectClassID;
                *outDataSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyClass:
                if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                *(AudioClassID *)outData = kAudioDeviceClassID;
                *outDataSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                *(AudioObjectID *)outData = kObjectID_PlugIn;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyName:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *(CFStringRef *)outData = CFSTR(kDevice_Name);
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyManufacturer:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *(CFStringRef *)outData = CFSTR(kDevice_Manufacturer);
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceUID:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *(CFStringRef *)outData = CFSTR(kDevice_UID);
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyModelUID:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *(CFStringRef *)outData = CFSTR(kDevice_ModelUID);
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyStreams:
                if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                }
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                *(AudioObjectID *)outData = kObjectID_Stream_Input;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyControlList:
                *outDataSize = 0;
                return kAudioHardwareNoError;
            case kAudioObjectPropertyCustomPropertyInfoList: {
                UInt32 needed = 2 * sizeof(AudioServerPlugInCustomPropertyInfo);
                if (inDataSize < needed) return kAudioHardwareBadPropertySizeError;
                AudioServerPlugInCustomPropertyInfo *info = (AudioServerPlugInCustomPropertyInfo *)outData;
                info[0].mSelector          = kMoteFlowMicPropertyPushPCM;
                info[0].mPropertyDataType  = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
                info[0].mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
                info[1].mSelector          = kMoteFlowMicPropertyResetBuffer;
                info[1].mPropertyDataType  = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
                info[1].mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
                *outDataSize = needed;
                return kAudioHardwareNoError;
            }
            case kAudioDevicePropertyTransportType:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = kAudioDeviceTransportTypeVirtual;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyRelatedDevices:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                *(AudioObjectID *)outData = kObjectID_Device;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 0;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceIsAlive:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 1;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceIsRunning:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                os_unfair_lock_lock(&gStateLock);
                *(UInt32 *)outData = (gIOClientCount > 0) ? 1 : 0;
                os_unfair_lock_unlock(&gStateLock);
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = (inAddress->mScope == kAudioObjectPropertyScopeOutput) ? 0 : 1;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyZeroTimeStampPeriod:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = kZeroTimeStampPeriod;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyNominalSampleRate:
                if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
                *(Float64 *)outData = kSampleRate;
                *outDataSize = sizeof(Float64);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                if (inDataSize < sizeof(AudioValueRange)) return kAudioHardwareBadPropertySizeError;
                AudioValueRange range = { kSampleRate, kSampleRate };
                *(AudioValueRange *)outData = range;
                *outDataSize = sizeof(AudioValueRange);
                return kAudioHardwareNoError;
            }
            case kAudioDevicePropertyPreferredChannelsForStereo: {
                if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                UInt32 *channels = (UInt32 *)outData;
                channels[0] = 1;
                channels[1] = 2;
                *outDataSize = 2 * sizeof(UInt32);
                return kAudioHardwareNoError;
            }
            case kAudioDevicePropertyPreferredChannelLayout: {
                UInt32 needed = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kNumChannels * sizeof(AudioChannelDescription));
                if (inDataSize < needed) return kAudioHardwareBadPropertySizeError;
                AudioChannelLayout *layout = (AudioChannelLayout *)outData;
                memset(layout, 0, needed);
                layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                layout->mNumberChannelDescriptions = kNumChannels;
                layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
                *outDataSize = needed;
                return kAudioHardwareNoError;
            }
            case kMoteFlowMicPropertyPushPCM:
            case kMoteFlowMicPropertyResetBuffer:
                if (inDataSize < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
                *(CFPropertyListRef *)outData = kCFBooleanTrue;
                *outDataSize = sizeof(CFPropertyListRef);
                return kAudioHardwareNoError;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kObjectID_Stream_Input) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                *(AudioClassID *)outData = kAudioObjectClassID;
                *outDataSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyClass:
                if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                *(AudioClassID *)outData = kAudioStreamClassID;
                *outDataSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                *(AudioObjectID *)outData = kObjectID_Device;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyName:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *(CFStringRef *)outData = CFSTR("MoteFlow Mic Input");
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection: // 1 = Input
            case kAudioStreamPropertyStartingChannel:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 1;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyTerminalType:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = kAudioStreamTerminalTypeMicrophone;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyLatency:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 0;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
                *(AudioStreamBasicDescription *)outData = MakeCanonicalASBD();
                *outDataSize = sizeof(AudioStreamBasicDescription);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                if (inDataSize < sizeof(AudioStreamRangedDescription)) return kAudioHardwareBadPropertySizeError;
                *(AudioStreamRangedDescription *)outData = MakeCanonicalRangedASBD();
                *outDataSize = sizeof(AudioStreamRangedDescription);
                return kAudioHardwareNoError;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    return kAudioHardwareBadObjectError;
}

static OSStatus MF_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inAddress == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;

    if (inObjectID == kObjectID_Device) {
        switch (inAddress->mSelector) {
            case kMoteFlowMicPropertyPushPCM: {
                if (inDataSize < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
                CFPropertyListRef plist = *(const CFPropertyListRef *)inData;
                if (plist == NULL || CFGetTypeID(plist) != CFDataGetTypeID()) {
                    return kAudioHardwareIllegalOperationError;
                }
                CFDataRef data = (CFDataRef)plist;
                CFIndex byteCount = CFDataGetLength(data);
                if (byteCount >= 4) {
                    const int16_t *samples = (const int16_t *)CFDataGetBytePtr(data);
                    uint32_t frameCount = (uint32_t)(byteCount / (CFIndex)(sizeof(int16_t) * kNumChannels));
                    RingBuffer_PushInt16Stereo(samples, frameCount);
                }
                return kAudioHardwareNoError;
            }
            case kMoteFlowMicPropertyResetBuffer: {
                RingBuffer_Reset();
                return kAudioHardwareNoError;
            }
            default:
                return kAudioHardwareUnsupportedOperationError;
        }
    }

    return kAudioHardwareUnsupportedOperationError;
}

// MARK: - IO Operations

static OSStatus MF_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inDriver; (void)inClientID;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    os_unfair_lock_lock(&gStateLock);
    if (gIOClientCount == 0) {
        gAnchorHostTime = mach_absolute_time();
    }
    ++gIOClientCount;
    os_unfair_lock_unlock(&gStateLock);
    return kAudioHardwareNoError;
}

static OSStatus MF_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inDriver; (void)inClientID;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    os_unfair_lock_lock(&gStateLock);
    if (gIOClientCount > 0) {
        --gIOClientCount;
    }
    os_unfair_lock_unlock(&gStateLock);
    return kAudioHardwareNoError;
}

static OSStatus MF_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)inDriver; (void)inClientID;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) return kAudioHardwareIllegalOperationError;

    UInt64 now = mach_absolute_time();
    UInt64 anchor = gAnchorHostTime;
    Float64 ticksPerRing = gHostTicksPerFrame * (Float64)kZeroTimeStampPeriod;
    UInt64 elapsed = (now >= anchor) ? (now - anchor) : 0;
    UInt64 cycleCount = (ticksPerRing > 0.0) ? (UInt64)((Float64)elapsed / ticksPerRing) : 0;

    *outSampleTime = (Float64)(cycleCount * kZeroTimeStampPeriod);
    *outHostTime   = anchor + (UInt64)((Float64)cycleCount * ticksPerRing);
    *outSeed       = 1;
    return kAudioHardwareNoError;
}

static OSStatus MF_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    if (outWillDo == NULL || outWillDoInPlace == NULL) return kAudioHardwareIllegalOperationError;

    if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        *outWillDo = true;
        *outWillDoInPlace = true;
    } else {
        *outWillDo = false;
        *outWillDoInPlace = true;
    }
    return kAudioHardwareNoError;
}

static OSStatus MF_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

static OSStatus MF_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)inDriver; (void)inClientID; (void)inIOCycleInfo; (void)ioSecondaryBuffer;
    if (inDeviceObjectID != kObjectID_Device || inStreamObjectID != kObjectID_Stream_Input) {
        return kAudioHardwareBadObjectError;
    }
    if (inOperationID == kAudioServerPlugInIOOperationReadInput && ioMainBuffer != NULL) {
        RingBuffer_ReadFloat32Stereo((float *)ioMainBuffer, inIOBufferFrameSize);
    }
    return kAudioHardwareNoError;
}

static OSStatus MF_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}
