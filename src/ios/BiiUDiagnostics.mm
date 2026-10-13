// Bii-U diagnostics: sampler thread, periodic perf log, hitch reports, crash writer and
// the "Share log" report. See BiiUDiagnostics.h for the C interface used by the app.

#include "ios/BiiUDiagnostics.h"
#include "Common/BiiUTelemetry.h"
#include "Cafe/CafeSystem.h"
#include "config/ActiveSettings.h"
#include "Cemu/Logging/CemuLogging.h"
#include "Cafe/HW/MMU/MMU.h"
#include "Cafe/HW/Latte/Renderer/Renderer.h"
#include <dispatch/dispatch.h>
#include <sys/mman.h>

#import <Foundation/Foundation.h>

#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

void PPCRecompiler_GetDiagnostics(int* mode, uint64* arenaBytes, uint64* arenaUsed);
bool PPCRecompiler_IsJitCodeAddress(const void* p);
extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

namespace
{
	std::string s_docsDir;
	std::string s_logsDir;
	std::string s_appInfo;
	char s_crashDir[1024] = {};
	char s_breadcrumbPath[1024] = {};
	bool s_prevSessionUnexpected = false;
	std::string s_prevSessionInfo;

	std::mutex s_snapMutex;
	BiiUSnapshot s_snap{};
	std::atomic<bool> s_started{false};

	// ---------- helpers ----------

	bool ProcessIsDebugged()
	{
		uint32_t flags = 0;
		return csops(getpid(), 0, &flags, sizeof(flags)) == 0 && (flags & 0x10000000u) != 0;
	}

	uint32_t CsFlags()
	{
		uint32_t flags = 0;
		csops(getpid(), 0, &flags, sizeof(flags));
		return flags;
	}

	float MemFootprintMB()
	{
		task_vm_info_data_t info{};
		mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
		if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
			return 0.0f;
		return (float)((double)info.phys_footprint / (1024.0 * 1024.0));
	}

	float MemAvailableMB()
	{
		if (@available(iOS 13.0, *))
			return (float)((double)os_proc_available_memory() / (1024.0 * 1024.0));
		return 0.0f;
	}

	// resident (touched) pages of the emulated Wii U memory, in MB
	float GuestResidentMB()
	{
		if (!memory_base)
			return 0.0f;
		MMURange* ranges[] = { &mmuRange_LOW0, &mmuRange_TRAMPOLINE_AREA, &mmuRange_CODECAVE, &mmuRange_TEXT_AREA, &mmuRange_CEMU_AREA,
			&mmuRange_MEM2, &mmuRange_OVERLAY_AREA, &mmuRange_FGBUCKET, &mmuRange_TILINGAPERTURE, &mmuRange_MEM1, &mmuRange_RPLLOADER, &mmuRange_SHARED_AREA };
		const size_t page = (size_t)getpagesize();
		static std::vector<char> vec;
		uint64_t residentPages = 0;
		for (MMURange* r : ranges)
		{
			if (!r->isMapped() || r->getSize() == 0)
				continue;
			uint8* start = memory_base + r->getBase();
			const size_t len = r->getSize();
			const size_t pages = (len + page - 1) / page;
			vec.resize(pages);
			if (mincore((caddr_t)start, len, vec.data()) != 0)
				continue;
			for (size_t i = 0; i < pages; i++)
				if (vec[i] & MINCORE_INCORE)
					residentPages++;
		}
		return (float)((double)residentPages * page / (1024.0 * 1024.0));
	}

	// Metal/Vulkan device allocations (textures, buffers) in MB
	float GpuAllocatedMB()
	{
		if (!g_renderer)
			return 0.0f;
		int used = 0, total = 0;
		if (!g_renderer->GetVRAMInfo(used, total))
			return 0.0f;
		return (float)used;
	}

	int ThermalState()
	{
		return (int)[[NSProcessInfo processInfo] thermalState];
	}

	const char* ThermalName(int t)
	{
		switch (t)
		{
		case 0: return "nominal";
		case 1: return "fair";
		case 2: return "SERIOUS";
		case 3: return "CRITICAL";
		default: return "?";
		}
	}

	const char* JitModeName(int m)
	{
		switch (m)
		{
		case 0: return "interpreter";
		case 1: return "recompiler (W^X)";
		case 2: return "recompiler (dual-mapped)";
		case 3: return "recompiler (dual-mapped, TXM)";
		default: return "?";
		}
	}

	std::string Sysctl(const char* name)
	{
		char buf[256] = {};
		size_t len = sizeof(buf) - 1;
		if (sysctlbyname(name, buf, &len, nullptr, 0) != 0)
			return "?";
		return std::string(buf);
	}

	std::string TimeStamp(const char* fmtStr)
	{
		char buf[64];
		time_t t = time(nullptr);
		struct tm tmv;
		localtime_r(&t, &tmv);
		strftime(buf, sizeof(buf), fmtStr, &tmv);
		return buf;
	}

	std::string ReadFile(const std::string& path, size_t maxTailBytes = 0)
	{
		std::ifstream f(path, std::ios::binary);
		if (!f)
			return {};
		std::stringstream ss;
		ss << f.rdbuf();
		std::string s = ss.str();
		if (maxTailBytes && s.size() > maxTailBytes)
			s = "[... earlier part cut ...]\n" + s.substr(s.size() - maxTailBytes);
		return s;
	}

	bool FileExists(const std::string& path)
	{
		struct stat st;
		return stat(path.c_str(), &st) == 0;
	}

	std::vector<std::string> ListDir(const std::string& dir, const char* prefix)
	{
		std::vector<std::string> out;
		NSArray<NSString*>* items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[NSString stringWithUTF8String:dir.c_str()] error:nil];
		for (NSString* item in items)
		{
			if ([item hasPrefix:[NSString stringWithUTF8String:prefix]])
				out.emplace_back(dir + "/" + item.UTF8String);
		}
		std::sort(out.begin(), out.end());
		return out;
	}

	void LogLine(const std::string& s)
	{
		cemuLog_log(LogType::Force, s);
	}

	// ---------- frame stats ----------

	void FrameStatsLastSecond(float& fps, float& avg, float& mx)
	{
		auto& c = BiiUTelemetry::Get();
		const uint32_t count = c.frameCount.load(std::memory_order_relaxed);
		const uint32_t n = std::min<uint32_t>(count, BiiUTelemetry::kFrameRingSize);
		float sum = 0.0f;
		mx = 0.0f;
		uint32_t used = 0;
		const uint64_t sinceLast = BiiUTelemetry::NowNs() - c.lastFrameNs.load(std::memory_order_relaxed);
		// walk back from the newest frame until one second of frame time is covered
		for (uint32_t i = 0; i < n; i++)
		{
			const float ms = c.frameMs[(count - 1 - i) & (BiiUTelemetry::kFrameRingSize - 1)].load(std::memory_order_relaxed);
			if (sum + ms > 1000.0f && used > 0)
				break;
			sum += ms;
			mx = std::max(mx, ms);
			used++;
		}
		if (used == 0 || sinceLast > 2000000000ull)
		{
			fps = 0.0f;
			avg = 0.0f;
			return;
		}
		avg = sum / (float)used;
		fps = sum > 0.0f ? (float)used * 1000.0f / sum : 0.0f;
	}

	// ---------- sampler ----------

	struct Prev
	{
		uint32_t hitches = 0, shaders = 0, pipelines = 0, pipelineSync = 0, jitBlocks = 0, underruns = 0, overflows = 0, h264 = 0;
		uint64_t shaderNs = 0, pipelineSyncNs = 0, jitNs = 0, h264Ns = 0;
	};

	void SessionMarker(bool running, const std::string& info)
	{
		const std::string path = s_logsDir + "/session.running";
		if (running)
		{
			std::ofstream f(path, std::ios::trunc);
			f << info << "\n";
		}
		else
			unlink(path.c_str());
	}

	void SamplerThread()
	{
		pthread_setname_np("BiiU.Diagnostics");
		Prev prev{};
		bool wasRunning = false;
		int tick = 0;
		uint32_t perfPrevUnderruns = 0, perfPrevShaders = 0, perfPrevPipelines = 0, perfPrevJit = 0, perfPrevHitches = 0, perfPrevOverflows = 0;
		while (true)
		{
			std::this_thread::sleep_for(std::chrono::seconds(1));
			tick++;
			auto& c = BiiUTelemetry::Get();
			BiiUSnapshot s{};

			FrameStatsLastSecond(s.fps, s.frameMsAvg, s.frameMsMax);
			// the real worst frame since the last sample (a long frame can fall outside the 1 s window)
			s.frameMsMax = std::max(s.frameMsMax, c.worstFrameMs.exchange(0.0f, std::memory_order_relaxed));
			s.hitchesTotal = c.hitches.load(std::memory_order_relaxed);
			s.hitchesLastSec = s.hitchesTotal - prev.hitches;

			s.shaderCompilesTotal = c.shaderCompiles.load(std::memory_order_relaxed);
			s.shaderCompilesLastSec = s.shaderCompilesTotal - prev.shaders;
			const uint64_t shaderNs = c.shaderCompileNs.load(std::memory_order_relaxed);
			s.shaderMsLastSec = (float)((shaderNs - prev.shaderNs) / 1e6);
			s.pipelineCompilesTotal = c.pipelineCompiles.load(std::memory_order_relaxed);
			s.pipelineCompilesLastSec = s.pipelineCompilesTotal - prev.pipelines;
			const uint32_t pipelineSync = c.pipelineSyncCompiles.load(std::memory_order_relaxed);
			s.pipelineSyncLastSec = pipelineSync - prev.pipelineSync;
			const uint64_t pipelineSyncNs = c.pipelineSyncNs.load(std::memory_order_relaxed);
			s.pipelineSyncMsLastSec = (float)((pipelineSyncNs - prev.pipelineSyncNs) / 1e6);

			int jitMode = 0;
			uint64 arenaBytes = 0, arenaUsed = 0;
			PPCRecompiler_GetDiagnostics(&jitMode, &arenaBytes, &arenaUsed);
			s.jitMode = jitMode;
			s.processDebugged = ProcessIsDebugged();
			s.jitBlocksTotal = c.jitBlocks.load(std::memory_order_relaxed);
			s.jitBlocksLastSec = s.jitBlocksTotal - prev.jitBlocks;
			const uint64_t jitNs = c.jitCompileNs.load(std::memory_order_relaxed);
			s.jitMsLastSec = (float)((jitNs - prev.jitNs) / 1e6);
			s.jitFailedTotal = c.jitFailed.load(std::memory_order_relaxed);
			s.jitInvalidationsTotal = c.jitInvalidations.load(std::memory_order_relaxed);
			s.jitArenaMB = (float)(arenaBytes / (1024.0 * 1024.0));
			s.jitArenaUsedMB = (float)(arenaUsed / (1024.0 * 1024.0));

			const uint32_t bps = c.audioBytesPerSec.load(std::memory_order_relaxed);
			const uint32_t buffered = c.audioBufferedBytes.load(std::memory_order_relaxed);
			const uint32_t capacity = c.audioCapacityBytes.load(std::memory_order_relaxed);
			s.audioBufferedMs = bps ? (float)buffered * 1000.0f / (float)bps : 0.0f;
			s.audioTargetMs = bps ? (float)c.audioTargetBytes.load(std::memory_order_relaxed) * 1000.0f / (float)bps : 0.0f;
			s.audioFillPct = capacity ? (float)buffered * 100.0f / (float)capacity : 0.0f;
			s.audioUnderrunsTotal = c.audioUnderruns.load(std::memory_order_relaxed);
			s.audioUnderrunsLastSec = s.audioUnderrunsTotal - prev.underruns;
			s.audioOverflowsTotal = c.audioOverflows.load(std::memory_order_relaxed);
			s.audioOverflowsLastSec = s.audioOverflowsTotal - prev.overflows;
			s.audioGuestRate = c.audioSampleRate.load(std::memory_order_relaxed);
			s.audioDeviceRate = c.audioHwSampleRate.load(std::memory_order_relaxed);
			s.audioDeviceBufferMs = c.audioHwBufferMs.load(std::memory_order_relaxed);
			s.audioDeviceLatencyMs = c.audioHwLatencyMs.load(std::memory_order_relaxed);
			s.audioPadActive = c.audioPadActive.load(std::memory_order_relaxed) != 0;

			s.h264FramesTotal = c.h264Frames.load(std::memory_order_relaxed);
			const uint32_t h264Delta = s.h264FramesTotal - prev.h264;
			const uint64_t h264Ns = c.h264DecodeNs.load(std::memory_order_relaxed);
			s.h264FpsLastSec = (float)h264Delta;
			s.h264AvgMsLastSec = h264Delta ? (float)((h264Ns - prev.h264Ns) / 1e6 / h264Delta) : 0.0f;
			s.h264MaxMs = (float)(c.h264MaxDecodeNs.load(std::memory_order_relaxed) / 1e6);

			s.memFootprintMB = MemFootprintMB();
			s.memAvailableMB = MemAvailableMB();
			s.memGuestMB = GuestResidentMB();
			s.memGpuMB = CafeSystem::IsTitleRunning() ? GpuAllocatedMB() : 0.0f;
			s.thermalState = ThermalState();
			s.gameRunning = CafeSystem::IsTitleRunning();
			s.titleId = s.gameRunning ? (uint64_t)CafeSystem::GetForegroundTitleId() : 0;

			prev.hitches = s.hitchesTotal;
			prev.shaders = s.shaderCompilesTotal;
			prev.shaderNs = shaderNs;
			prev.pipelines = s.pipelineCompilesTotal;
			prev.pipelineSync = pipelineSync;
			prev.pipelineSyncNs = pipelineSyncNs;
			prev.jitBlocks = s.jitBlocksTotal;
			prev.jitNs = jitNs;
			prev.underruns = s.audioUnderrunsTotal;
			prev.overflows = s.audioOverflowsTotal;
			prev.h264 = s.h264FramesTotal;
			prev.h264Ns = h264Ns;

			{
				std::lock_guard lock(s_snapMutex);
				s_snap = s;
			}

			// game start / stop
			if (s.gameRunning && !wasRunning)
			{
				std::string name = CafeSystem::GetForegroundTitleName();
				std::string info = fmt::format("game {:016x} \"{}\" v{} started {} | jit: {} | debugged: {}",
					s.titleId, name, CafeSystem::GetForegroundTitleVersion(), TimeStamp("%Y-%m-%d %H:%M:%S"), JitModeName(s.jitMode), s.processDebugged ? "yes" : "no");
				LogLine("[biiu] " + info);
				BiiUTelemetry::Breadcrumb(info.c_str());
				SessionMarker(true, info);
			}
			else if (!s.gameRunning && wasRunning)
			{
				BiiUTelemetry::Breadcrumb("game stopped");
				SessionMarker(false, {});
			}
			wasRunning = s.gameRunning;
			if (!s.gameRunning)
				continue;

			// immediate hitch report: what else happened in the same second
			if (s.hitchesLastSec > 0)
			{
				LogLine(fmt::format("[hitch] {} frame(s) > 50 ms, worst {:.0f} ms | shaders +{} ({:.0f} ms) pipelines +{} (render-thread {} / {:.0f} ms) | jit +{} ({:.0f} ms) | audio underruns +{} | h264 {:.0f} fps | thermal {}",
					s.hitchesLastSec, s.frameMsMax, s.shaderCompilesLastSec, s.shaderMsLastSec, s.pipelineCompilesLastSec, s.pipelineSyncLastSec, s.pipelineSyncMsLastSec,
					s.jitBlocksLastSec, s.jitMsLastSec, s.audioUnderrunsLastSec, s.h264FpsLastSec, ThermalName(s.thermalState)));
			}
			// audio trouble outside of hitches
			else if (s.audioUnderrunsLastSec > 0 || s.audioOverflowsLastSec > 0)
			{
				LogLine(fmt::format("[audio] underruns +{} overflows +{} | buffered {:.0f} ms (target {:.0f} ms) | fps {:.1f} | h264 {:.0f} fps avg {:.1f} ms",
					s.audioUnderrunsLastSec, s.audioOverflowsLastSec, s.audioBufferedMs, s.audioTargetMs, s.fps, s.h264FpsLastSec, s.h264AvgMsLastSec));
			}

			// periodic summary every 5 seconds
			if (tick % 5 == 0)
			{
				LogLine(fmt::format("[perf] fps {:.1f} frame avg {:.1f} max {:.1f} ms hitches +{} | shaders +{} pipelines +{} | jit {} +{} blocks, arena {:.0f}/{:.0f} MB, failed {} | audio {:.0f}/{:.0f} ms ({:.0f}%) underruns +{} overflows +{}{} | h264 {:.0f} fps {:.1f} ms (max {:.1f}) | mem {:.0f} MB used (guest {:.0f}, gpu {:.0f}, other {:.0f}), {:.0f} MB left | thermal {}",
					s.fps, s.frameMsAvg, s.frameMsMax, s.hitchesTotal - perfPrevHitches,
					s.shaderCompilesTotal - perfPrevShaders, s.pipelineCompilesTotal - perfPrevPipelines,
					JitModeName(s.jitMode), s.jitBlocksTotal - perfPrevJit, s.jitArenaUsedMB, s.jitArenaMB, s.jitFailedTotal,
					s.audioBufferedMs, s.audioTargetMs, s.audioFillPct, s.audioUnderrunsTotal - perfPrevUnderruns, s.audioOverflowsTotal - perfPrevOverflows,
					s.audioPadActive ? " (+gamepad audio)" : "",
					s.h264FpsLastSec, s.h264AvgMsLastSec, s.h264MaxMs,
					s.memFootprintMB, s.memGuestMB, s.memGpuMB, std::max(0.0f, s.memFootprintMB - s.memGuestMB - s.memGpuMB), s.memAvailableMB, ThermalName(s.thermalState)));
				perfPrevHitches = s.hitchesTotal;
				perfPrevShaders = s.shaderCompilesTotal;
				perfPrevPipelines = s.pipelineCompilesTotal;
				perfPrevJit = s.jitBlocksTotal;
				perfPrevUnderruns = s.audioUnderrunsTotal;
				perfPrevOverflows = s.audioOverflowsTotal;
			}
		}
	}

	// ---------- crash writer (async-signal context: raw write(2) only, best effort) ----------

	struct sigaction s_oldActions[32];

	void WriteStr(int fd, const char* s)
	{
		(void)!write(fd, s, strlen(s));
	}

	void WriteFmt(int fd, const char* fmtStr, ...) __attribute__((format(printf, 2, 3)));
	void WriteFmt(int fd, const char* fmtStr, ...)
	{
		char buf[512];
		va_list ap;
		va_start(ap, fmtStr);
		int n = vsnprintf(buf, sizeof(buf), fmtStr, ap);
		va_end(ap);
		if (n > 0)
			(void)!write(fd, buf, (size_t)std::min<int>(n, (int)sizeof(buf) - 1));
	}

	void WriteAddr(int fd, const char* label, void* addr)
	{
		Dl_info di{};
		if (addr && dladdr(addr, &di) && di.dli_fname)
		{
			const char* image = strrchr(di.dli_fname, '/');
			image = image ? image + 1 : di.dli_fname;
			WriteFmt(fd, "%s %p %s+0x%lx %s\n", label, addr, image, (unsigned long)((uintptr_t)addr - (uintptr_t)di.dli_fbase), di.dli_sname ? di.dli_sname : "");
		}
		else if (addr && PPCRecompiler_IsJitCodeAddress(addr))
			WriteFmt(fd, "%s %p [JIT code]\n", label, addr);
		else
			WriteFmt(fd, "%s %p\n", label, addr);
	}

	void CrashHandler(int sig, siginfo_t* info, void* context)
	{
		static std::atomic<bool> s_inHandler{false};
		if (!s_inHandler.exchange(true))
		{
			char path[1200];
			time_t t = time(nullptr);
			snprintf(path, sizeof(path), "%s/crash-%ld.txt", s_crashDir, (long)t);
			int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
			if (fd >= 0)
			{
				WriteFmt(fd, "Bii-U crash report\n%s\n", s_appInfo.c_str());
				WriteFmt(fd, "signal %d (%s) si_code %d si_addr %p\n", sig, strsignal(sig), info ? info->si_code : 0, info ? info->si_addr : nullptr);
				WriteFmt(fd, "thread: ");
				char tname[64] = {};
				pthread_getname_np(pthread_self(), tname, sizeof(tname));
				WriteFmt(fd, "%s\n", tname);
				WriteFmt(fd, "cs_flags 0x%08x\n", CsFlags());
				{
					BiiUSnapshot s;
					{
						// try_lock: never deadlock in a signal handler
						if (s_snapMutex.try_lock())
						{
							s = s_snap;
							s_snapMutex.unlock();
						}
						else
							s = BiiUSnapshot{};
					}
					WriteFmt(fd, "jit mode %d arena %.0f/%.0f MB blocks %u failed %u | mem %.0f MB used %.0f MB left | thermal %d | title %016llx\n",
						s.jitMode, s.jitArenaUsedMB, s.jitArenaMB, s.jitBlocksTotal, s.jitFailedTotal, s.memFootprintMB, s.memAvailableMB, s.thermalState, (unsigned long long)s.titleId);
				}
				ucontext_t* uc = (ucontext_t*)context;
				if (uc && uc->uc_mcontext)
				{
					auto* ss = &uc->uc_mcontext->__ss;
					WriteAddr(fd, "pc", (void*)ss->__pc);
					WriteAddr(fd, "lr", (void*)ss->__lr);
					WriteFmt(fd, "sp %p fp %p\n", (void*)ss->__sp, (void*)ss->__fp);
					for (int i = 0; i < 29; i++)
						WriteFmt(fd, "x%d %p\n", i, (void*)ss->__x[i]);
				}
				void* bt[64];
				int n = backtrace(bt, 64);
				WriteStr(fd, "backtrace:\n");
				for (int i = 0; i < n; i++)
				{
					char label[16];
					snprintf(label, sizeof(label), "  #%02d", i);
					WriteAddr(fd, label, bt[i]);
				}
				WriteStr(fd, "breadcrumbs:\n");
				int bfd = open(s_breadcrumbPath, O_RDONLY);
				if (bfd >= 0)
				{
					off_t size = lseek(bfd, 0, SEEK_END);
					lseek(bfd, size > 4096 ? size - 4096 : 0, SEEK_SET);
					char buf[4096];
					ssize_t r = read(bfd, buf, sizeof(buf));
					if (r > 0)
						(void)!write(fd, buf, (size_t)r);
					close(bfd);
				}
				close(fd);
			}
		}
		// chain to the previous handler (Cemu's writes log.txt and exits)
		if (sig > 0 && sig < 32)
		{
			struct sigaction& old = s_oldActions[sig];
			if ((old.sa_flags & SA_SIGINFO) && old.sa_sigaction)
			{
				old.sa_sigaction(sig, info, context);
				return;
			}
			if (old.sa_handler != SIG_DFL && old.sa_handler != SIG_IGN && old.sa_handler)
			{
				old.sa_handler(sig);
				return;
			}
		}
		signal(sig, SIG_DFL);
		raise(sig);
	}

	// brk #0xf00d (StikDebug TXM protocol) and brk #0x69 (older JIT-enabler protocol). When no
	// debugger script handles them they arrive here as SIGTRAP: skip the instruction and return 0.
	constexpr uint32_t kBrkF00D = 0xD4200000u | (0xF00Du << 5);
	constexpr uint32_t kBrk69 = 0xD4200000u | (0x69u << 5);
	std::atomic<uint32_t> s_unhandledJitTraps{0};

	void TrapHandler(int sig, siginfo_t* info, void* context)
	{
		ucontext_t* uc = (ucontext_t*)context;
		if (uc && uc->uc_mcontext)
		{
			auto* ss = &uc->uc_mcontext->__ss;
			const uint32_t insn = *(const uint32_t*)ss->__pc;
			if (insn == kBrkF00D || insn == kBrk69)
			{
				ss->__pc += 4;
				ss->__x[0] = 0;
				s_unhandledJitTraps.fetch_add(1, std::memory_order_relaxed);
				return;
			}
		}
		// a real trap (assertion, __builtin_trap): report it like any other crash
		CrashHandler(sig, info, context);
	}

	void InstallCrashHandler()
	{
		const int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGSYS };
		for (int sig : sigs)
		{
			struct sigaction sa{};
			sa.sa_sigaction = CrashHandler;
			sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
			sigfillset(&sa.sa_mask);
			sigaction(sig, &sa, &s_oldActions[sig]);
		}
		{
			struct sigaction sa{};
			sa.sa_sigaction = TrapHandler;
			sa.sa_flags = SA_SIGINFO;
			sigemptyset(&sa.sa_mask);
			sigaction(SIGTRAP, &sa, &s_oldActions[SIGTRAP]);
		}
		// an alternate stack so stack overflows can still be reported
		static uint8_t* altStack = (uint8_t*)malloc(256 * 1024);
		stack_t ss{};
		ss.ss_sp = altStack;
		ss.ss_size = 256 * 1024;
		sigaltstack(&ss, nullptr);
	}
}

extern "C" void BiiU_DiagnosticsInit(const char* docsDir, const char* appInfo)
{
	if (s_started.exchange(true))
		return;
	s_docsDir = docsDir ? docsDir : "";
	s_appInfo = appInfo ? appInfo : "";
	s_logsDir = s_docsDir + "/logs";
	mkdir(s_logsDir.c_str(), 0755);
	mkdir((s_logsDir + "/crashes").c_str(), 0755);
	strncpy(s_crashDir, (s_logsDir + "/crashes").c_str(), sizeof(s_crashDir) - 1);

	// keep the previous session's breadcrumbs, start a new file
	const std::string crumbs = s_logsDir + "/breadcrumbs.txt";
	rename(crumbs.c_str(), (s_logsDir + "/breadcrumbs_prev.txt").c_str());
	strncpy(s_breadcrumbPath, crumbs.c_str(), sizeof(s_breadcrumbPath) - 1);
	BiiUTelemetry::SetBreadcrumbPath(s_breadcrumbPath);

	// a marker left behind means the last session died while a game was running
	const std::string marker = s_logsDir + "/session.running";
	if (FileExists(marker))
	{
		s_prevSessionUnexpected = true;
		s_prevSessionInfo = ReadFile(marker);
		unlink(marker.c_str());
	}

	uint32_t flags = CsFlags();
	std::string header = fmt::format("{} | device {} ({}) | iOS {} | cs_flags 0x{:08x} (debugged: {}) | DUAL_MAPPED_JIT={} HAS_TXM={} | memory available at launch {:.0f} MB",
		s_appInfo, Sysctl("hw.machine"), Sysctl("hw.model"), [[[NSProcessInfo processInfo] operatingSystemVersionString] UTF8String],
		flags, (flags & 0x10000000u) ? "yes" : "no",
		getenv("DUAL_MAPPED_JIT") ? getenv("DUAL_MAPPED_JIT") : "unset", getenv("HAS_TXM") ? getenv("HAS_TXM") : "unset",
		MemAvailableMB());
	LogLine("[biiu] " + header);
	BiiUTelemetry::Breadcrumb(header.c_str());
	if (s_prevSessionUnexpected)
		LogLine("[biiu] previous session ended unexpectedly while running: " + s_prevSessionInfo);

	InstallCrashHandler();

	// log iOS memory pressure events: they come right before a jetsam kill
	static dispatch_source_t s_memPressure = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
		DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
	if (s_memPressure)
	{
		dispatch_source_set_event_handler(s_memPressure, ^{
			const unsigned long level = dispatch_source_get_data(s_memPressure);
			std::string text = fmt::format("[memory] iOS memory pressure {}: {:.0f} MB used, {:.0f} MB left",
				(level & DISPATCH_MEMORYPRESSURE_CRITICAL) ? "CRITICAL" : "warning", MemFootprintMB(), MemAvailableMB());
			LogLine(text);
			BiiUTelemetry::Breadcrumb(text.c_str());
		});
		dispatch_resume(s_memPressure);
	}
	std::thread(SamplerThread).detach();
}

extern "C" void BiiU_GetSnapshot(BiiUSnapshot* out)
{
	if (!out)
		return;
	std::lock_guard lock(s_snapMutex);
	*out = s_snap;
}

extern "C" int32_t BiiU_CopyFrameTimes(float* out, int32_t maxCount)
{
	if (!out || maxCount <= 0)
		return 0;
	auto& c = BiiUTelemetry::Get();
	const uint32_t count = c.frameCount.load(std::memory_order_relaxed);
	const uint32_t n = std::min<uint32_t>({count, BiiUTelemetry::kFrameRingSize, (uint32_t)maxCount});
	for (uint32_t i = 0; i < n; i++)
		out[i] = c.frameMs[(count - n + i) & (BiiUTelemetry::kFrameRingSize - 1)].load(std::memory_order_relaxed);
	return (int32_t)n;
}

extern "C" void BiiU_Log(const char* text)
{
	if (!text)
		return;
	LogLine(std::string("[app] ") + text);
	BiiUTelemetry::Breadcrumb(text);
}

extern "C" int32_t BiiU_PendingCrashCount(void)
{
	return (int32_t)ListDir(s_logsDir + "/crashes", "crash-").size();
}

extern "C" bool BiiU_PreviousSessionEndedUnexpectedly(void)
{
	return s_prevSessionUnexpected;
}

extern "C" void BiiU_MarkCleanExit(void)
{
	SessionMarker(false, {});
	BiiUTelemetry::Breadcrumb("clean exit");
}

extern "C" bool BiiU_CreateReport(char* outPath, int32_t outPathSize)
{
	if (!outPath || outPathSize <= 0 || s_logsDir.empty())
		return false;
	const std::string path = s_logsDir + "/BiiU-report-" + TimeStamp("%Y%m%d-%H%M%S") + ".txt";
	std::ofstream f(path, std::ios::trunc);
	if (!f)
		return false;

	BiiUSnapshot s;
	BiiU_GetSnapshot(&s);
	uint32_t flags = CsFlags();

	f << "==================== Bii-U diagnostic report ====================\n";
	f << s_appInfo << "\n";
	f << "created: " << TimeStamp("%Y-%m-%d %H:%M:%S") << "\n";
	f << "device: " << Sysctl("hw.machine") << " (" << Sysctl("hw.model") << "), " << [[[NSProcessInfo processInfo] operatingSystemVersionString] UTF8String] << "\n";
	f << "cpu cores: " << std::thread::hardware_concurrency() << ", physical memory: " << ([NSProcessInfo processInfo].physicalMemory / (1024 * 1024)) << " MB\n";
	f << fmt::format("cs_flags: 0x{:08x} (CS_DEBUGGED: {})\n", flags, (flags & 0x10000000u) ? "yes" : "no");
	f << "env: DUAL_MAPPED_JIT=" << (getenv("DUAL_MAPPED_JIT") ? getenv("DUAL_MAPPED_JIT") : "unset")
	  << " HAS_TXM=" << (getenv("HAS_TXM") ? getenv("HAS_TXM") : "unset")
	  << " LC_HOME_PATH=" << (getenv("LC_HOME_PATH") ? "set (LiveContainer)" : "unset") << "\n";
	f << "executable: " << [[[NSBundle mainBundle] executablePath] UTF8String] << "\n";
	f << "\n---------- current state ----------\n";
	f << fmt::format("game running: {} title {:016x}\n", s.gameRunning, s.titleId);
	f << fmt::format("fps {:.1f}, frame avg {:.1f} ms, max {:.1f} ms, hitches (>50 ms) total {}\n", s.fps, s.frameMsAvg, s.frameMsMax, s.hitchesTotal);
	f << fmt::format("shaders compiled {}, pipelines {}\n", s.shaderCompilesTotal, s.pipelineCompilesTotal);
	f << fmt::format("jit: {} | blocks {} failed {} invalidations {} | arena {:.0f}/{:.0f} MB\n", JitModeName(s.jitMode), s.jitBlocksTotal, s.jitFailedTotal, s.jitInvalidationsTotal, s.jitArenaUsedMB, s.jitArenaMB);
	f << fmt::format("audio: guest {} Hz, device {} Hz, device buffer {:.1f} ms, output latency {:.1f} ms | buffered {:.0f} ms target {:.0f} ms | underruns {} overflows {} | gamepad audio {}\n",
		s.audioGuestRate, s.audioDeviceRate, s.audioDeviceBufferMs, s.audioDeviceLatencyMs, s.audioBufferedMs, s.audioTargetMs, s.audioUnderrunsTotal, s.audioOverflowsTotal, s.audioPadActive ? "on" : "off");
	f << fmt::format("h264: {} frames, max decode {:.1f} ms\n", s.h264FramesTotal, s.h264MaxMs);
	f << fmt::format("memory: {:.0f} MB used (guest RAM {:.0f}, GPU {:.0f}), {:.0f} MB left before iOS kills the app | thermal {}\n", s.memFootprintMB, s.memGuestMB, s.memGpuMB, s.memAvailableMB, ThermalName(s.thermalState));

	f << "\n---------- previous session ----------\n";
	f << (s_prevSessionUnexpected ? "ENDED UNEXPECTEDLY while running: " + s_prevSessionInfo : std::string("ended normally (or no game was running)\n"));
	f << "breadcrumbs:\n" << ReadFile(s_logsDir + "/breadcrumbs_prev.txt", 16 * 1024) << "\n";

	f << "\n---------- crash logs ----------\n";
	auto crashes = ListDir(s_logsDir + "/crashes", "crash-");
	{
		// newest five, new and already shared ones together (names sort by time)
		auto all = ListDir(s_logsDir + "/crashes/shared", "crash-");
		all.insert(all.end(), crashes.begin(), crashes.end());
		std::sort(all.begin(), all.end(), [](const std::string& a, const std::string& b) {
			return a.substr(a.rfind('/')) < b.substr(b.rfind('/'));
		});
		if (all.empty())
			f << "none\n";
		const size_t firstCrash = all.size() > 5 ? all.size() - 5 : 0;
		for (size_t i = firstCrash; i < all.size(); i++)
			f << "=== " << all[i].substr(all[i].rfind('/') + 1) << "\n" << ReadFile(all[i], 32 * 1024) << "\n";
	}

	f << "\n---------- config.xml ----------\n";
	f << ReadFile(ActiveSettings::GetConfigPath("config.xml").string(), 32 * 1024) << "\n";

	f << "\n---------- breadcrumbs (this session) ----------\n";
	f << ReadFile(s_breadcrumbPath, 16 * 1024) << "\n";

	f << "\n---------- previous log (log_prev.txt) ----------\n";
	f << ReadFile(ActiveSettings::GetUserDataPath("log_prev.txt").string(), 256 * 1024) << "\n";

	f << "\n---------- current log (log.txt) ----------\n";
	f << ReadFile(ActiveSettings::GetUserDataPath("log.txt").string(), 512 * 1024) << "\n";
	f.close();

	// crash logs are now part of a report; move them so the "new crash" badge clears
	mkdir((s_logsDir + "/crashes/shared").c_str(), 0755);
	for (const auto& c : crashes)
	{
		const std::string name = c.substr(c.rfind('/') + 1);
		rename(c.c_str(), (s_logsDir + "/crashes/shared/" + name).c_str());
	}

	strncpy(outPath, path.c_str(), (size_t)outPathSize - 1);
	outPath[outPathSize - 1] = '\0';
	return true;
}
