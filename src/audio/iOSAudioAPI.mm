//
//  iOSAudioAPI.m
//  cemuMain
//
//  Created by Stossy11 on 5/3/2026.
//

#include <TargetConditionals.h>

#if defined(__APPLE__) && TARGET_OS_IOS

#include "iOSAudioAPI.h"
#include "iOSDeviceDescription.h"
#include "config/CemuConfig.h"
#include "Common/BiiUTelemetry.h"
#include "Cemu/Logging/CemuLogging.h"
#include <algorithm>
#include <cstring>
#import <AVFoundation/AVFoundation.h>

IOSAudioAPI::IOSAudioAPI(uint32 samplerate,
                         uint32 channels,
                         uint32 samples_per_block,
                         uint32 bits_per_sample)
    : IAudioAPI(samplerate, channels, samples_per_block, bits_per_sample),
      m_buffer((size_t)samples_per_block * channels * (bits_per_sample / 8) * kBlockCount)
{
    NSError* error = nil;
    AVAudioSession* session = [AVAudioSession sharedInstance];
    
    if (GetConfig().microphone_enabled) {
        [session setCategory:AVAudioSessionCategoryPlayAndRecord
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDefaultToSpeaker
                       error:&error];
    }
    else {
        [session setCategory:AVAudioSessionCategoryPlayback
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers
                       error:&error];
    }
    [session setPreferredSampleRate:samplerate error:&error];
    [session setPreferredIOBufferDuration:(double)samples_per_block / samplerate error:&error];
    [session setActive:YES error:&error];
    {
        auto& biiu = BiiUTelemetry::Get();
        biiu.audioSampleRate.store(samplerate, std::memory_order_relaxed);
        biiu.audioHwSampleRate.store((uint32)session.sampleRate, std::memory_order_relaxed);
        biiu.audioHwBufferMs.store((float)(session.IOBufferDuration * 1000.0), std::memory_order_relaxed);
        biiu.audioHwLatencyMs.store((float)(session.outputLatency * 1000.0), std::memory_order_relaxed);
        cemuLog_log(LogType::Force, "[audio] output: guest {} Hz {} ch {} samples/block | device {:.0f} Hz, IO buffer {:.1f} ms, output latency {:.1f} ms, target queue {} blocks",
            samplerate, channels, samples_per_block, session.sampleRate, session.IOBufferDuration * 1000.0, session.outputLatency * 1000.0, GetTargetQueuedBlocks());
    }
    
    AudioComponentDescription desc{};
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
    if (!comp || AudioComponentInstanceNew(comp, &m_audioUnit) != noErr)
        throw std::runtime_error("can't initialize iOS audio unit");
    
    auto disposeAudioUnitOnError = [this]() {
        AudioComponentInstanceDispose(m_audioUnit);
        m_audioUnit = nullptr;
    };
    
    const uint32 bytesPerSample = bits_per_sample / 8;
    
    AudioStreamBasicDescription format{};
    format.mSampleRate       = samplerate;
    format.mFormatID         = kAudioFormatLinearPCM;
    format.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    format.mChannelsPerFrame = m_channels;
    format.mBitsPerChannel   = bits_per_sample;
    format.mFramesPerPacket  = 1;
    format.mBytesPerFrame    = m_channels * bytesPerSample;
    format.mBytesPerPacket   = format.mBytesPerFrame * format.mFramesPerPacket;
    
    if (AudioUnitSetProperty(m_audioUnit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 0, &format, sizeof(format)) != noErr) {
        disposeAudioUnitOnError();
        throw std::runtime_error("can't set iOS audio stream format");
    }
    
    AURenderCallbackStruct callback{};
    callback.inputProc       = RenderCallback;
    callback.inputProcRefCon = this;
    
    if (AudioUnitSetProperty(m_audioUnit, kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input, 0, &callback, sizeof(callback)) != noErr) {
        disposeAudioUnitOnError();
        throw std::runtime_error("can't set iOS audio render callback");
    }
    
    if (AudioUnitInitialize(m_audioUnit) != noErr) {
        disposeAudioUnitOnError();
        throw std::runtime_error("can't initialize iOS audio unit");
    }
}

IOSAudioAPI::~IOSAudioAPI()
{
    if (m_audioUnit) {
        m_isPlaying = false;
        AudioOutputUnitStop(m_audioUnit);
        AudioUnitUninitialize(m_audioUnit);
        AudioComponentInstanceDispose(m_audioUnit);
        m_audioUnit = nullptr;
    }
}

bool IOSAudioAPI::Play()
{
    if (!m_audioUnit) return false;
    if (m_isPlaying) return true;
    
    OSStatus status = AudioOutputUnitStart(m_audioUnit);
    if (status != noErr) {
        return false;
    }
    
    m_isPlaying = true;
    return true;
}

bool IOSAudioAPI::Stop()
{
    if (!m_audioUnit) return false;
    if (!m_isPlaying) return true;
    
    if (AudioOutputUnitStop(m_audioUnit) != noErr)
        return false;
    
    m_isPlaying = false;
    return true;
}

bool IOSAudioAPI::NeedAdditionalBlocks() const
{
    return m_buffer.size() < (size_t)GetTargetQueuedBlocks() * m_bytesPerBlock;
}

bool IOSAudioAPI::FeedBlock(sint16* data)
{
    auto& biiu = BiiUTelemetry::Get();
    const bool ok = m_buffer.write(reinterpret_cast<const std::uint8_t*>(data), m_bytesPerBlock);
    const bool isTV = g_tvAudio.get() == this; // FeedBlock runs on the thread that owns g_tvAudio
    m_isTV.store(isTV, std::memory_order_relaxed);
    if (!isTV)
    {
        biiu.audioPadActive.store(1, std::memory_order_relaxed);
        return ok;
    }
    biiu.audioBlocksFed.fetch_add(1, std::memory_order_relaxed);
    biiu.audioBytesPerSec.store(m_samplerate * m_channels * (m_bitsPerSample / 8), std::memory_order_relaxed);
    biiu.audioCapacityBytes.store(m_bytesPerBlock * kBlockCount, std::memory_order_relaxed);
    if (!ok)
        biiu.audioOverflows.fetch_add(1, std::memory_order_relaxed);
    biiu.audioBufferedBytes.store((uint32)m_buffer.size(), std::memory_order_relaxed);
    biiu.audioTargetBytes.store(GetTargetQueuedBlocks() * m_bytesPerBlock, std::memory_order_relaxed);
    return ok;
}

OSStatus IOSAudioAPI::RenderCallback(
    void* inRefCon,
    AudioUnitRenderActionFlags* ioActionFlags,
    const AudioTimeStamp* inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList* ioData)
{
    auto* self = reinterpret_cast<IOSAudioAPI*>(inRefCon);
    if (!self || !ioData)
        return noErr;
    
    if (ioData->mNumberBuffers == 0)
        return noErr;

    for (UInt32 i = 0; i < ioData->mNumberBuffers; ++i)
        std::memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
    
    if (!self->m_isPlaying)
        return noErr;
    
    auto& outputBuffer = ioData->mBuffers[0];
    const auto bytesNeeded = std::min<size_t>((size_t)inNumberFrames * self->m_channels * (self->m_bitsPerSample / 8), outputBuffer.mDataByteSize);
    const auto copied = self->m_buffer.read(static_cast<std::uint8_t*>(outputBuffer.mData), bytesNeeded);
    auto& biiu = BiiUTelemetry::Get();
    if (copied < bytesNeeded)
        std::memset(static_cast<std::uint8_t*>(outputBuffer.mData) + copied, 0, bytesNeeded - copied);
    if (!self->m_isTV.load(std::memory_order_relaxed))
        return noErr;
    biiu.audioCallbacks.fetch_add(1, std::memory_order_relaxed);
    if (copied < bytesNeeded)
    {
        biiu.audioUnderruns.fetch_add(1, std::memory_order_relaxed);
        const size_t frameBytes = (size_t)self->m_channels * (self->m_bitsPerSample / 8);
        if (frameBytes)
            biiu.audioUnderrunFrames.fetch_add((bytesNeeded - copied) / frameBytes, std::memory_order_relaxed);
    }
    biiu.audioBufferedBytes.store((uint32)self->m_buffer.size(), std::memory_order_relaxed);
    
    return noErr;
}

std::vector<IAudioAPI::DeviceDescriptionPtr> IOSAudioAPI::GetDevices()
{
    std::vector<DeviceDescriptionPtr> devs;
    devs.push_back(std::make_shared<IOSDeviceDescription>());
    return devs;
}

#endif
