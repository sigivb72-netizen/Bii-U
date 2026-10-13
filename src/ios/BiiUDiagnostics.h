// Bii-U diagnostics: plain C interface for the Swift app (overlay, Share log, crash logs).
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BiiUSnapshot {
    // frame pacing (guest frames, last second)
    float fps;
    float frameMsAvg;
    float frameMsMax;
    uint32_t hitchesTotal;     // frames slower than 50 ms since launch
    uint32_t hitchesLastSec;

    // shaders / pipelines
    uint32_t shaderCompilesTotal;
    uint32_t shaderCompilesLastSec;
    float shaderMsLastSec;
    uint32_t pipelineCompilesTotal;
    uint32_t pipelineCompilesLastSec;
    uint32_t pipelineSyncLastSec;   // compiled on the render thread (stalls the frame)
    float pipelineSyncMsLastSec;

    // JIT
    int32_t jitMode;                // 0 interpreter, 1 recompiler W^X, 2 dual-mapped, 3 dual-mapped TXM
    bool processDebugged;           // CS_DEBUGGED (JIT enabler attached at some point)
    uint32_t jitBlocksTotal;
    uint32_t jitBlocksLastSec;
    float jitMsLastSec;
    uint32_t jitFailedTotal;
    uint32_t jitInvalidationsTotal;
    float jitArenaMB;
    float jitArenaUsedMB;

    // audio (TV output)
    float audioBufferedMs;
    float audioTargetMs;
    float audioFillPct;             // of the ring buffer capacity
    uint32_t audioUnderrunsTotal;
    uint32_t audioUnderrunsLastSec;
    uint32_t audioOverflowsTotal;
    uint32_t audioOverflowsLastSec;
    uint32_t audioGuestRate;
    uint32_t audioDeviceRate;
    float audioDeviceBufferMs;
    float audioDeviceLatencyMs;
    bool audioPadActive;

    // H.264 cutscene video
    uint32_t h264FramesTotal;
    float h264FpsLastSec;
    float h264AvgMsLastSec;
    float h264MaxMs;

    // system
    float memFootprintMB;
    float memAvailableMB;           // before iOS kills the app (os_proc_available_memory)
    float memGuestMB;               // resident emulated Wii U RAM
    float memGpuMB;                 // Metal device allocations
    int32_t thermalState;           // 0 nominal, 1 fair, 2 serious, 3 critical
    bool gameRunning;
    uint64_t titleId;
} BiiUSnapshot;

// Call once after CemuInitialize(). docsDir is the app's Documents directory.
// appInfo is a free-form line (version, build, commit) written at the top of logs/reports.
void BiiU_DiagnosticsInit(const char* docsDir, const char* appInfo);

// Latest values (updated once per second by a background thread).
void BiiU_GetSnapshot(BiiUSnapshot* out);

// Copies up to maxCount most recent guest frame times in ms (oldest first). Returns the count.
int32_t BiiU_CopyFrameTimes(float* out, int32_t maxCount);

// Writes a single text report (device info, JIT state, snapshot, crash logs, breadcrumbs,
// previous and current log) and returns its path in outPath. Returns false on failure.
bool BiiU_CreateReport(char* outPath, int32_t outPathSize);

// Free-form line from the app into log.txt and the breadcrumb file.
void BiiU_Log(const char* text);

// Number of crash logs written by previous sessions that were not yet shared.
int32_t BiiU_PendingCrashCount(void);

// Non-zero if the previous session did not shut down cleanly (crash, jetsam or SIGKILL).
bool BiiU_PreviousSessionEndedUnexpectedly(void);

// Mark a clean exit (call when the app goes to background without a running game, etc.).
void BiiU_MarkCleanExit(void);

#ifdef __cplusplus
}
#endif
