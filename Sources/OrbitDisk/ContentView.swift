import AppKit
import SwiftUI

private enum InterfaceColors {
    static let window = Color(red: 0.145, green: 0.16, blue: 0.19)
    static let header = Color(red: 0.16, green: 0.175, blue: 0.205)
    static let rowA = Color(red: 0.135, green: 0.15, blue: 0.18)
    static let rowB = Color(red: 0.16, green: 0.175, blue: 0.205)
    static let muted = Color(red: 0.39, green: 0.43, blue: 0.49)
    static let orange = Color(red: 1.0, green: 0.29, blue: 0.035)
}

struct ContentView: View {
    @EnvironmentObject private var model: ScanViewModel

    private var isAnalysis: Bool {
        if case .ready = model.state { return true }
        return false
    }

    var body: some View {
        Group {
            if isAnalysis, let focus = model.focus {
                AnalysisView(focus: focus)
            } else {
                VolumeBrowserView()
            }
        }
        .background(InterfaceColors.window)
        .foregroundStyle(.white)
        .alert("OrbitDisk", isPresented: Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.notice = nil } }
        )) {
            Button("OK") { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }

}

private struct WindowHeader: View {
    var body: some View {
        ZStack {
            InterfaceColors.header
            Text("OrbitDisk")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(height: 52)
    }
}

private struct VolumeBrowserView: View {
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        VStack(spacing: 0) {
            WindowHeader()
            ForEach(Array(model.volumes.enumerated()), id: \.element.id) { index, volume in
                VolumeRow(
                    volume: volume,
                    isScanning: model.isScanning && model.scanTargetURL?.path == volume.url.standardizedFileURL.path,
                    progress: model.progress,
                    scan: { model.startScan(volume.url) },
                    cancel: model.cancelScan
                )
                .background(index.isMultiple(of: 2) ? InterfaceColors.rowA : InterfaceColors.rowB)
            }

            HStack {
                Button("Scan Folder…", action: model.chooseFolder)
                    .buttonStyle(DarkButtonStyle())
                if model.isScanning,
                   !model.volumes.contains(where: { $0.url.standardizedFileURL.path == model.scanTargetURL?.path }) {
                    FolderScanProgress(progress: model.progress)
                    Button("Cancel", action: model.cancelScan)
                        .buttonStyle(DarkButtonStyle())
                }
                if case .failed(let message) = model.state {
                    Text(message).font(.caption).foregroundStyle(.red.opacity(0.85)).lineLimit(1)
                }
                Spacer()
                Menu("Scan Cloud") {
                    Button("Cloud scanning is not configured") { }
                        .disabled(true)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .frame(height: 48)
            .background(InterfaceColors.header)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.17), lineWidth: 1))
        .padding(1)
    }
}

private struct VolumeRow: View {
    let volume: VolumeInfo
    let isScanning: Bool
    let progress: ScanProgress
    let scan: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(volume.isInternal
                          ? Color(white: 0.72)
                          : (volume.isTimeMachine
                             ? Color(red: 0.24, green: 0.72, blue: 0.69)
                             : Color(red: 0.98, green: 0.63, blue: 0.03)))
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(.white.opacity(0.65)).frame(height: 3)
                    }
                Image(systemName: volume.isInternal
                      ? "apple.logo"
                      : (volume.isTimeMachine ? "clock.arrow.circlepath" : "externaldrive.fill"))
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(volume.isInternal
                                     ? .gray
                                     : (volume.isTimeMachine ? .teal.opacity(0.72) : .orange.opacity(0.72)))
            }
            .frame(width: 38, height: 44)

            VStack(alignment: .leading, spacing: 5) {
                Text(volume.name)
                    .font(.system(size: 16, weight: .regular))
                Text("\(ByteText.string(volume.total))  \(volume.isInternal ? "encrypted startup disk" : (volume.isTimeMachine ? "Time Machine volume" : "USB disk"))")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(InterfaceColors.muted)
            }

            Spacer(minLength: 28)

            VStack(alignment: .leading, spacing: 6) {
                if isScanning {
                    let fraction = progress.fraction(of: volume.used)
                    AnimatedStripeBar(progress: fraction)
                    HStack(spacing: 6) {
                        Text(fraction >= 1
                             ? "100%"
                             : "≈\(Int(fraction * 100))%")
                            .foregroundStyle(.white.opacity(0.78))
                        Spacer(minLength: 4)
                        if progress.items > 0 {
                            Text("\(progress.items.formatted()) items · \(ByteText.string(progress.bytes))")
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .help(progress.path)
                } else {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.black.opacity(0.36))
                            Capsule().fill(InterfaceColors.orange)
                                .frame(width: proxy.size.width * volume.fractionUsed)
                        }
                    }
                    .frame(height: 6)
                    Text(ByteText.string(volume.available))
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundStyle(InterfaceColors.orange)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: 230)

            Button(isScanning ? "Cancel" : "Scan", action: isScanning ? cancel : scan)
                .buttonStyle(PillButtonStyle())
                .focusEffectDisabled()
        }
        .padding(.horizontal, 30)
        .frame(height: 80)
    }
}

private struct AnimatedStripeBar: View {
    let progress: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { timeline in
            let period = 14.0
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1) * period
            Canvas { context, size in
                let capsule = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
                context.fill(capsule, with: .color(.black.opacity(0.36)))
                let visibleProgress = progress > 0 ? max(progress, 0.015) : 0
                let fillWidth = size.width * visibleProgress
                guard fillWidth > 0 else { return }

                context.clip(to: capsule)
                context.clip(to: Path(CGRect(x: 0, y: 0, width: fillWidth, height: size.height)))
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.blue.opacity(0.58)))

                for x in stride(from: -period + phase, through: fillWidth + period, by: period) {
                    var stripe = Path()
                    stripe.move(to: CGPoint(x: x, y: size.height))
                    stripe.addLine(to: CGPoint(x: x + 6, y: 0))
                    stripe.addLine(to: CGPoint(x: x + 11, y: 0))
                    stripe.addLine(to: CGPoint(x: x + 5, y: size.height))
                    stripe.closeSubpath()
                    context.fill(stripe, with: .color(.white.opacity(0.58)))
                }
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Progression de l’analyse")
        .accessibilityValue("\(Int(progress * 100)) pour cent")
    }
}

private struct FolderScanProgress: View {
    let progress: ScanProgress

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(progress.items == 0 ? "Preparing folder…" : "Scanning \(progress.items.formatted()) items")
                if progress.items > 0 {
                    Text(ByteText.string(progress.bytes))
                        .font(.system(size: 10, design: .rounded))
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .help(progress.path)
    }
}

private struct AnalysisView: View {
    @EnvironmentObject private var model: ScanViewModel
    let focus: DiskNode

    var body: some View {
        VStack(spacing: 0) {
            AnalysisToolbar(focus: focus)
            HStack(spacing: 0) {
                SunburstView(
                    root: focus,
                    selection: model.selected,
                    onSelect: { model.selected = $0 },
                    onOpen: model.navigate
                )
                .padding(.leading, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                LegendView(focus: focus)
                    .frame(width: 280)
                    .padding(.top, 38)
                    .padding(.trailing, 20)
            }

            CollectorBar()
                .frame(height: 58)
        }
        .background(InterfaceColors.window)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.17), lineWidth: 1))
    }
}

private struct AnalysisToolbar: View {
    @EnvironmentObject private var model: ScanViewModel
    let focus: DiskNode

    var body: some View {
        HStack(spacing: 12) {
            Button(action: model.navigateBack) { Image(systemName: "chevron.left") }
                .buttonStyle(PlainToolbarButtonStyle())
                .disabled(model.navigation.isEmpty)
            Button(action: model.navigateForward) { Image(systemName: "chevron.right") }
                .buttonStyle(PlainToolbarButtonStyle())
                .disabled(!model.canNavigateForward)

            HStack(spacing: 0) {
                Button("Disks and Folders", action: model.returnToVolumes)
                    .buttonStyle(BreadcrumbButtonStyle(accented: true))
                Button(focus.name) { model.navigateHome() }
                    .buttonStyle(BreadcrumbButtonStyle(accented: false))
            }
            Spacer()
        }
        .padding(.leading, 78)
        .frame(height: 50)
        .background(InterfaceColors.header)
    }
}

private struct LegendView: View {
    @EnvironmentObject private var model: ScanViewModel
    let focus: DiskNode

    private var visibleChildren: [DiskNode] { Array(focus.children.prefix(7)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(focus.name).font(.system(size: 18, weight: .light))
                Spacer()
                Text(ByteText.string(focus.size)).font(.system(size: 18, weight: .light))
            }
            .padding(.bottom, 10)

            ForEach(Array(visibleChildren.enumerated()), id: \.element.id) { index, node in
                Button {
                    model.selected = node
                    if node.isDirectory { model.navigate(to: node) }
                } label: {
                    HStack(spacing: 10) {
                        Circle().fill(branchColor(index: index, count: max(focus.children.count, 1))).frame(width: 7, height: 7)
                        Text(node.name).lineLimit(1)
                        Spacer()
                        Text(ByteText.string(node.size)).monospacedDigit()
                    }
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(model.selected?.id == node.id ? .white : .white.opacity(0.82))
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(model.collected.contains(where: { $0.id == node.id }) ? "Remove from Collector" : "Add to Collector") {
                        model.toggleCollected(node)
                    }
                    Button("Show in Finder") { model.reveal(node) }
                }
            }

            if focus.children.count > visibleChildren.count {
                HStack(spacing: 10) {
                    Circle().fill(.gray.opacity(0.4)).frame(width: 7, height: 7)
                    Text("smaller objects…")
                    Spacer()
                    Text(ByteText.string(focus.children.dropFirst(visibleChildren.count).reduce(Int64(0)) { $0 + $1.size }))
                        .monospacedDigit()
                }
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }

            Divider().overlay(.white.opacity(0.09)).padding(.vertical, 10)

            if let volume = model.volumes.first(where: { $0.url.standardizedFileURL.path == model.root?.url?.standardizedFileURL.path }) {
                HStack {
                    Text("•  free space")
                    Spacer()
                    Text(ByteText.string(volume.available))
                }
                HStack {
                    Text("~  free + purgeable")
                    Spacer()
                    Text(ByteText.string(volume.availableIncludingPurgeable))
                }
                .padding(.top, 7)
                .foregroundStyle(.secondary)
                .font(.system(size: 13, weight: .light))
            }

            Spacer()
        }
    }

    private func branchColor(index: Int, count: Int) -> Color {
        let hue = (0.20 + Double(index) / Double(count) * 0.86).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: 0.82, brightness: 0.94)
    }
}

private struct CollectorBar: View {
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(.blue.opacity(0.25), lineWidth: 3)
                Circle().stroke(.blue.opacity(0.25), lineWidth: 3).padding(7)
                Circle().fill(.blue.opacity(0.18)).padding(13)
            }
            .frame(width: 40, height: 40)

            if model.collected.isEmpty {
                Text("Right-click items to collect them")
                    .foregroundStyle(InterfaceColors.muted)
            } else {
                Text("\(model.collected.count) item\(model.collected.count == 1 ? "" : "s") collected • \(ByteText.string(model.collectedSize))")
                Button("Clear", action: model.clearCollector)
                    .buttonStyle(DarkButtonStyle())
            }
            Spacer()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .background(InterfaceColors.window)
    }
}

private struct DarkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.58))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(configuration.isPressed ? 0.36 : 0.22)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.04)))
    }
}

private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color(red: 0.16, green: 0.19, blue: 0.22))
            .frame(width: 96, height: 31)
            .background(LinearGradient(colors: [.white.opacity(0.73), .gray.opacity(0.58)], startPoint: .top, endPoint: .bottom))
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct PlainToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white.opacity(enabled ? (configuration.isPressed ? 0.92 : 0.48) : 0.17))
            .frame(width: 24, height: 30)
    }
}

private struct BreadcrumbButtonStyle: ButtonStyle {
    let accented: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 12).frame(height: 28)
            .background(accented ? Color.blue.opacity(configuration.isPressed ? 0.65 : 0.78) : Color.black.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.07)))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
