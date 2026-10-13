#pragma once

// Bii-U diagnostics: lock-free counters that the core bumps from its hot paths and the
// on-screen overlay / periodic perf log read. Everything is relaxed atomics, so the cost
// in the emulator threads is a handful of uncontended increments per frame.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>

namespace BiiUTelemetry
{
	inline uint64_t NowNs()
	{
		return (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(
			std::chrono::steady_clock::now().time_since_epoch()).count();
	}

	constexpr uint32_t kFrameRingSize = 256; // power of two

	struct Counters
	{
		// guest frames (one per GX2 flip, i.e. what the game shows)
		std::atomic<uint64_t> lastFrameNs{0};
		std::atomic<uint32_t> frameCount{0};
		std::atomic<float> frameMs[kFrameRingSize]{};
		std::atomic<uint32_t> hitches{0};      // frames slower than 50 ms
		std::atomic<float> worstFrameMs{0};    // slowest frame since the sampler last read it
		std::atomic<uint32_t> hostPresents{0}; // drawables presented to the TV layer

		// shaders / pipelines
		std::atomic<uint32_t> shaderCompiles{0};
		std::atomic<uint64_t> shaderCompileNs{0};
		std::atomic<uint32_t> pipelineCompiles{0};
		std::atomic<uint64_t> pipelineCompileNs{0};
		std::atomic<uint32_t> pipelineSyncCompiles{0}; // compiled on the render thread (stall)
		std::atomic<uint64_t> pipelineSyncNs{0};

		// JIT
		std::atomic<uint32_t> jitBlocks{0};
		std::atomic<uint64_t> jitCompileNs{0};
		std::atomic<uint32_t> jitFailed{0};
		std::atomic<uint32_t> jitInvalidations{0};
		std::atomic<uint64_t> jitArenaBytes{0};
		std::atomic<uint64_t> jitArenaUsed{0};
		std::atomic<int32_t> jitMode{0}; // 0 interpreter, 1 recompiler W^X, 2 dual-mapped, 3 dual-mapped TXM

		// host audio output (iOS AudioUnit)
		std::atomic<uint32_t> audioCallbacks{0};
		std::atomic<uint32_t> audioUnderruns{0};      // callbacks that ran out of samples
		std::atomic<uint64_t> audioUnderrunFrames{0}; // silent frames inserted
		std::atomic<uint32_t> audioOverflows{0};      // blocks dropped because the buffer was full
		std::atomic<uint32_t> audioBlocksFed{0};
		std::atomic<uint32_t> audioBufferedBytes{0};
		std::atomic<uint32_t> audioCapacityBytes{0};
		std::atomic<uint32_t> audioTargetBytes{0};
		std::atomic<uint32_t> audioSampleRate{0};
		std::atomic<uint32_t> audioBytesPerSec{0};
		std::atomic<uint32_t> audioHwSampleRate{0};
		std::atomic<float> audioHwBufferMs{0};
		std::atomic<float> audioHwLatencyMs{0};
		std::atomic<uint32_t> audioPadActive{0}; // GamePad audio also playing (second output unit)

		// H.264 (cutscene video)
		std::atomic<uint32_t> h264Frames{0};
		std::atomic<uint64_t> h264DecodeNs{0};
		std::atomic<uint64_t> h264MaxDecodeNs{0};
		std::atomic<uint32_t> h264Active{0};

		// misc
		std::atomic<uint32_t> gameRunning{0};
		std::atomic<uint64_t> titleId{0};
	};

	inline Counters& Get()
	{
		static Counters s_counters;
		return s_counters;
	}

	inline void AddMax(std::atomic<uint64_t>& target, uint64_t value)
	{
		uint64_t cur = target.load(std::memory_order_relaxed);
		while (value > cur && !target.compare_exchange_weak(cur, value, std::memory_order_relaxed)) {}
	}

	// called once per guest frame (LattePerformanceMonitor_frameEnd)
	void OnGuestFrame();

	class ScopedTimer
	{
	public:
		ScopedTimer(std::atomic<uint64_t>& sink) : m_sink(sink), m_start(NowNs()) {}
		~ScopedTimer() { m_sink.fetch_add(NowNs() - m_start, std::memory_order_relaxed); }
		ScopedTimer(const ScopedTimer&) = delete;
		ScopedTimer& operator=(const ScopedTimer&) = delete;
	private:
		std::atomic<uint64_t>& m_sink;
		uint64_t m_start;
	};

	// Breadcrumbs: the last few milestones, written synchronously to disk so they survive
	// even a SIGKILL (e.g. a code-signing kill when JIT memory is not executable).
	void Breadcrumb(const char* text);
	void SetBreadcrumbPath(const char* path);
}
