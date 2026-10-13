#include "Common/BiiUTelemetry.h"

#include <algorithm>
#include <cstring>
#include <cstdio>
#include <mutex>
#include <string>
#if !defined(_WIN32)
#include <fcntl.h>
#include <unistd.h>
#endif

namespace BiiUTelemetry
{
	void OnGuestFrame()
	{
		auto& c = Get();
		const uint64_t now = NowNs();
		const uint64_t prev = c.lastFrameNs.exchange(now, std::memory_order_relaxed);
		if (prev == 0)
			return;
		const float ms = (float)((double)(now - prev) / 1e6);
		const uint32_t idx = c.frameCount.fetch_add(1, std::memory_order_relaxed);
		c.frameMs[idx & (kFrameRingSize - 1)].store(ms, std::memory_order_relaxed);
		if (ms > 50.0f && ms < 5000.0f)
			c.hitches.fetch_add(1, std::memory_order_relaxed);
		float worst = c.worstFrameMs.load(std::memory_order_relaxed);
		while (ms > worst && ms < 5000.0f && !c.worstFrameMs.compare_exchange_weak(worst, ms, std::memory_order_relaxed)) {}
	}

	// breadcrumb file: path is set once by the diagnostics module at startup
	static char s_breadcrumbPath[1024] = {};
	static std::mutex s_breadcrumbMutex;

	void SetBreadcrumbPath(const char* path)
	{
		std::lock_guard lock(s_breadcrumbMutex);
		std::strncpy(s_breadcrumbPath, path ? path : "", sizeof(s_breadcrumbPath) - 1);
	}

	void Breadcrumb(const char* text)
	{
#if !defined(_WIN32)
		std::lock_guard lock(s_breadcrumbMutex);
		if (!s_breadcrumbPath[0])
			return;
		int fd = open(s_breadcrumbPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
		if (fd < 0)
			return;
		char line[512];
		int n = std::snprintf(line, sizeof(line), "[%.3f] %s\n", (double)NowNs() / 1e9, text);
		if (n > 0)
			(void)!write(fd, line, (size_t)std::min<int>(n, (int)sizeof(line) - 1));
		close(fd);
#else
		(void)text;
#endif
	}
}
