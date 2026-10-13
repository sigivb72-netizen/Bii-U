//
//  Diagnostics.swift
//  Bii-U
//
//  On-screen performance overlay, "Share log" and crash notices.
//  The numbers come from the core (src/ios/BiiUDiagnostics.mm), sampled once per second;
//  the frame-time graph reads the core's per-frame ring buffer directly.
//

import Combine
import SwiftUI
import UIKit

enum Diagnostics {
    static var appInfo: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = (info["BiiUCommit"] as? String).map { String($0.prefix(7)) } ?? "local"
        return "Bii-U \(version) (build \(build), \(commit))"
    }

    static func start() {
        let docs = URL.documentsDirectory.path
        docs.withCString { d in
            appInfo.withCString { a in
                BiiU_DiagnosticsInit(d, a)
            }
        }
    }

    static func log(_ text: String) {
        text.withCString { BiiU_Log($0) }
    }

    /// Builds the report file and opens the iOS share sheet (Files, Mail, Discord, ...).
    static func shareReport() {
        var buffer = [CChar](repeating: 0, count: 2048)
        guard BiiU_CreateReport(&buffer, Int32(buffer.count)) else { return }
        let path = String(cString: buffer)
        let url = URL(fileURLWithPath: path)
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let presenter = topViewController() else { return }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(activity, animated: true)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    static func snapshot() -> BiiUSnapshot {
        var s = BiiUSnapshot()
        BiiU_GetSnapshot(&s)
        return s
    }

    static func frameTimes(max: Int = 180) -> [Float] {
        var buffer = [Float](repeating: 0, count: max)
        let n = Int(BiiU_CopyFrameTimes(&buffer, Int32(max)))
        return Array(buffer.prefix(n))
    }

    /// Copies Cemu's data files (shared fonts, game profiles) from the app bundle into
    /// Documents the first time, or when the bundled set changes with an update.
    static func installBundledData() {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("CemuData") else { return }
        let fm = FileManager.default
        let docs = URL.documentsDirectory
        for sub in ["resources/sharedFonts", "gameProfiles/default"] {
            let from = src.appendingPathComponent(sub)
            let to = docs.appendingPathComponent(sub)
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.createDirectory(at: to, withIntermediateDirectories: true)
            let files = (try? fm.contentsOfDirectory(atPath: from.path)) ?? []
            for file in files {
                let target = to.appendingPathComponent(file)
                let source = from.appendingPathComponent(file)
                // game profiles shipped with the app are always refreshed; fonts are only copied once
                if fm.fileExists(atPath: target.path) {
                    if sub.hasPrefix("resources") { continue }
                    try? fm.removeItem(at: target)
                }
                try? fm.copyItem(at: source, to: target)
            }
        }
    }
}

// MARK: - Overlay

final class DiagnosticsModel: ObservableObject {
    @Published var snap = BiiUSnapshot()
    @Published var frames: [Float] = []

    func refresh() {
        snap = Diagnostics.snapshot()
        frames = Diagnostics.frameTimes()
    }
}

struct DiagnosticsOverlay: View {
    @StateObject private var model = DiagnosticsModel()
    @AppStorage("biiu.overlayExpanded") private var expanded = true
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        let s = model.snap
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(String(format: "%.1f FPS", s.fps))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(fpsColor(s.fps))
                Text(String(format: "%.1f/%.0f ms", s.frameMsAvg, s.frameMsMax))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 4)
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                Button { Diagnostics.shareReport() } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share log")
            }
            FrameGraph(frames: model.frames)
                .frame(height: expanded ? 46 : 26)
            if expanded {
                line("Hitch", "\(s.hitchesLastSec)/s  total \(s.hitchesTotal)", s.hitchesLastSec > 0 ? .orange : nil)
                line("Shader", "+\(s.shaderCompilesLastSec) (\(ms(s.shaderMsLastSec)))  pipe +\(s.pipelineCompilesLastSec) sync \(s.pipelineSyncLastSec) (\(ms(s.pipelineSyncMsLastSec)))",
                     s.pipelineSyncLastSec > 0 ? .orange : nil)
                line("JIT", jitText(s), s.jitMode == 0 ? .red : nil)
                line("Audio", audioText(s), (s.audioUnderrunsLastSec > 0 || s.audioOverflowsLastSec > 0) ? .orange : nil)
                if s.h264FpsLastSec > 0 {
                    line("Video", String(format: "%.0f fps  %.1f ms/frame  max %.1f", s.h264FpsLastSec, s.h264AvgMsLastSec, s.h264MaxMs),
                         s.h264AvgMsLastSec > 25 ? .orange : nil)
                }
                line("Mem", String(format: "%.0f MB used  %.0f MB left", s.memFootprintMB, s.memAvailableMB),
                     s.memAvailableMB > 0 && s.memAvailableMB < 400 ? .red : nil)
                line("Heat", thermalText(s.thermalState), s.thermalState >= 2 ? .red : (s.thermalState == 1 ? .yellow : nil))
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(6)
        .frame(width: 270)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .onReceive(timer) { _ in model.refresh() }
        .onAppear { model.refresh() }
    }

    private func line(_ label: String, _ value: String, _ color: Color?) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label).foregroundStyle(.white.opacity(0.6)).frame(width: 40, alignment: .leading)
            Text(value).foregroundStyle(color ?? .white).lineLimit(2)
        }
    }

    private func ms(_ v: Float) -> String { String(format: "%.0fms", v) }

    private func fpsColor(_ fps: Float) -> Color {
        fps >= 55 ? .green : (fps >= 28 ? .yellow : .red)
    }

    private func jitText(_ s: BiiUSnapshot) -> String {
        let mode: String
        switch s.jitMode {
        case 0: mode = s.processDebugged ? "OFF (interp.)" : "OFF (no debugger)"
        case 1: mode = "on W^X"
        case 2: mode = "on dual-map"
        case 3: mode = "on TXM"
        default: mode = "?"
        }
        if s.jitMode == 0 { return mode }
        return String(format: "%@ +%u blk (%.0fms) %.0f/%.0fMB%@", mode, s.jitBlocksLastSec, s.jitMsLastSec, s.jitArenaUsedMB, s.jitArenaMB,
                      s.jitFailedTotal > 0 ? " fail \(s.jitFailedTotal)" : "")
    }

    private func audioText(_ s: BiiUSnapshot) -> String {
        var t = String(format: "%.0f/%.0fms %.0f%%  under +%u (%u)", s.audioBufferedMs, s.audioTargetMs, s.audioFillPct, s.audioUnderrunsLastSec, s.audioUnderrunsTotal)
        if s.audioOverflowsLastSec > 0 { t += " over +\(s.audioOverflowsLastSec)" }
        if s.audioDeviceRate > 0 && s.audioDeviceRate != s.audioGuestRate { t += " \(s.audioDeviceRate)Hz!" }
        if s.audioPadActive { t += " +pad" }
        return t
    }

    private func thermalText(_ t: Int32) -> String {
        switch t {
        case 0: return "nominal"
        case 1: return "fair"
        case 2: return "serious (throttling)"
        case 3: return "critical (throttling)"
        default: return "?"
        }
    }
}

/// Frame-time bars, newest on the right. Guide lines at 16.7 ms (60 fps) and 33.3 ms (30 fps).
struct FrameGraph: View {
    let frames: [Float]

    var body: some View {
        Canvas { ctx, size in
            let maxMs: CGFloat = 66.7
            let y = { (ms: CGFloat) in size.height - min(ms, maxMs) / maxMs * size.height }
            for guide in [16.7, 33.3] as [CGFloat] {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y(guide)))
                p.addLine(to: CGPoint(x: size.width, y: y(guide)))
                ctx.stroke(p, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
            }
            guard !frames.isEmpty else { return }
            let count = 180
            let barWidth = size.width / CGFloat(count)
            let start = count - frames.count
            for (i, f) in frames.enumerated() {
                let ms = CGFloat(f)
                let color: Color = ms > 50 ? .red : (ms > 20 ? .yellow : .green)
                let x = CGFloat(start + i) * barWidth
                let rect = CGRect(x: x, y: y(ms), width: max(barWidth, 1), height: size.height - y(ms))
                ctx.fill(Path(rect), with: .color(color.opacity(0.85)))
            }
        }
    }
}

// MARK: - Settings section

struct DiagnosticsSettingsSection: View {
    @AppStorage("biiu.showOverlay") private var showOverlay = true
    @State private var crashCount = Int(BiiU_PendingCrashCount())

    var body: some View {
        Section {
            Toggle("Performance overlay", isOn: $showOverlay)
            Button {
                Diagnostics.shareReport()
                crashCount = Int(BiiU_PendingCrashCount())
            } label: {
                Label("Share log", systemImage: "square.and.arrow.up")
            }
            if crashCount > 0 {
                Text("\(crashCount) new crash log(s) will be included.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Text(Diagnostics.appInfo)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Share log creates one text file with device info, JIT state, performance counters, crash logs and the emulator log of this and the previous session. It contains no game files or keys.")
        }
    }
}

// MARK: - Crash notice on launch

struct CrashNoticeModifier: ViewModifier {
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                if BiiU_PreviousSessionEndedUnexpectedly() || BiiU_PendingCrashCount() > 0 {
                    show = true
                }
            }
            .alert("The last session ended unexpectedly", isPresented: $show) {
                Button("Share log") { Diagnostics.shareReport() }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("Bii-U stopped while a game was running (a crash, or iOS closed it for using too much memory). The log explains what happened.")
            }
    }
}
