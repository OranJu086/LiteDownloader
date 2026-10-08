import SwiftUI
import AppKit

// MARK: - 格式化工具

func formatBytes(_ n: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(max(0, n))
    var idx = 0
    while value >= 1024 && idx < units.count - 1 {
        value /= 1024
        idx += 1
    }
    if idx == 0 { return "\(Int(value)) \(units[idx])" }
    return String(format: "%.1f %@", value, units[idx])
}

func formatSpeed(_ bps: Double) -> String {
    if bps <= 0 { return "—" }
    return formatBytes(Int64(bps)) + "/s"
}

func formatDuration(_ seconds: Int) -> String {
    if seconds < 0 { return "—" }
    if seconds < 60 { return "\(seconds) 秒" }
    let m = seconds / 60
    let s = seconds % 60
    if m < 60 { return String(format: "%d 分 %02d 秒", m, s) }
    let h = m / 60
    let mm = m % 60
    return String(format: "%d 时 %02d 分 %02d 秒", h, mm, s)
}

func fileNameFromURL(_ raw: String) -> String? {
    guard let u = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    guard let last = u.pathComponents.last, !last.isEmpty, last != "/" else { return nil }
    return last.removingPercentEncoding ?? last
}

// MARK: - ViewModel

@MainActor
final class DownloadViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case merging
        case finished
        case failed(String)
        case cancelled
    }

    struct AlertInfo: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published var url: String = ""
    @Published var folder: String = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? ""
    @Published var fileName: String = ""
    @Published var phase: Phase = .idle
    @Published var progress: Double = 0
    @Published var progressText: String = ""
    @Published var speedText: String = "—"
    @Published var etaText: String = "—"
    @Published var alert: AlertInfo?

    private var engine: DownloadEngine?
    private var task: Task<Void, Never>?
    private var lastBytes: Int64 = 0
    private var lastTime: Date?
    private var currentSpeed: Double = 0

    var isBusy: Bool { phase == .running || phase == .merging }

    var canStart: Bool {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, !n.isEmpty, !f.isEmpty, let parsed = URL(string: u) else { return false }
        return parsed.scheme == "http" || parsed.scheme == "https"
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let u = panel.url {
            folder = u.path
        }
    }

    func toggle() {
        if isBusy { cancel() } else { start() }
    }

    func start() {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: u), parsed.scheme == "http" || parsed.scheme == "https" else { return }
        guard !n.isEmpty else { return }
        var dir = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        dir = (dir as NSString).expandingTildeInPath
        let dest = URL(fileURLWithPath: dir).appendingPathComponent(n)

        let eng = DownloadEngine(url: parsed, destination: dest)
        engine = eng
        eng.onProgress = { [weak self] downloaded, total in
            DispatchQueue.main.async { self?.applyProgress(downloaded: downloaded, total: total) }
        }
        eng.onPhase = { [weak self] text in
            DispatchQueue.main.async { self?.progressText = text }
        }

        phase = .running
        progress = 0
        progressText = "准备下载…"
        speedText = "—"
        etaText = "—"
        lastBytes = 0
        lastTime = Date()
        currentSpeed = 0

        task = Task { [weak self] in
            await self?.runDownload()
        }
    }

    func cancel() {
        engine?.cancel()
        task?.cancel()
    }

    private func runDownload() async {
        guard let eng = engine else { return }
        do {
            try await eng.download()
            phase = .finished
            progress = 1
            progressText = "下载完成"
            speedText = "—"
            etaText = "—"
            alert = AlertInfo(title: "下载完成", message: "文件已保存到：\(eng.destination.path)")
        } catch is CancellationError {
            phase = .cancelled
            progressText = "已取消"
            alert = AlertInfo(title: "已取消", message: "下载已取消，临时文件已清理。")
        } catch let e as URLError where e.code == .cancelled {
            phase = .cancelled
            progressText = "已取消"
            alert = AlertInfo(title: "已取消", message: "下载已取消，临时文件已清理。")
        } catch {
            phase = .failed(error.localizedDescription)
            progressText = "下载失败"
            alert = AlertInfo(title: "下载失败", message: error.localizedDescription)
        }
    }

    private func applyProgress(downloaded: Int64, total: Int64?) {
        if let total = total, total > 0 {
            progress = min(1, max(0, Double(downloaded) / Double(total)))
            progressText = "已下载 \(formatBytes(downloaded)) / \(formatBytes(total))（\(Int(progress * 100))%）"
            updateSpeedAndEta(downloaded: downloaded, total: total)
        } else {
            progress = -1
            progressText = "已下载 \(formatBytes(downloaded))"
            updateSpeedAndEta(downloaded: downloaded, total: nil)
        }
    }

    private func updateSpeedAndEta(downloaded: Int64, total: Int64?) {
        let now = Date()
        guard let lt = lastTime else {
            lastTime = now
            lastBytes = downloaded
            return
        }
        let dt = now.timeIntervalSince(lt)
        if dt < 0.5 { return }
        let inst = Double(downloaded - lastBytes) / max(dt, 0.01)
        currentSpeed = currentSpeed * 0.5 + inst * 0.5
        lastBytes = downloaded
        lastTime = now
        speedText = formatSpeed(max(0, currentSpeed))
        if let total = total, currentSpeed > 0 {
            let remaining = total - downloaded
            etaText = formatDuration(Int(Double(remaining) / currentSpeed))
        } else {
            etaText = "—"
        }
    }
}

// MARK: - 界面

struct ContentView: View {
    @StateObject private var vm = DownloadViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("简洁下载器").font(.title2.bold())
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("下载地址").font(.caption).foregroundColor(.secondary)
                TextField("https://example.com/file.zip", text: $vm.url)
                    .textFieldStyle(.roundedBorder)
                    .disabled(vm.isBusy)
                    .onChange(of: vm.url, perform: { newValue in
                        if vm.fileName.trimmingCharacters(in: .whitespaces).isEmpty {
                            if let name = fileNameFromURL(newValue) {
                                vm.fileName = name
                            }
                        }
                    })
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("保存到").font(.caption).foregroundColor(.secondary)
                HStack {
                    TextField("~/Downloads", text: $vm.folder)
                        .textFieldStyle(.roundedBorder)
                        .disabled(vm.isBusy)
                    Button("浏览") { vm.chooseFolder() }
                        .disabled(vm.isBusy)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("文件名").font(.caption).foregroundColor(.secondary)
                TextField("file.zip", text: $vm.fileName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(vm.isBusy)
            }

            Divider()

            if vm.phase == .idle {
                Text("填写以上信息后，点击「开始下载」。")
                    .font(.callout).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if vm.progress < 0 {
                        ProgressView().progressViewStyle(.linear)
                    } else {
                        ProgressView(value: vm.progress).progressViewStyle(.linear)
                    }
                    Text(vm.progressText).font(.callout).monospacedDigit()
                    HStack {
                        Text("速度 \(vm.speedText)").font(.callout).monospacedDigit()
                        Spacer()
                        Text("剩余时间 \(vm.etaText)").font(.callout).monospacedDigit()
                    }
                }
                .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button(vm.isBusy ? "取消" : "开始下载") {
                    vm.toggle()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!vm.isBusy && !vm.canStart)
                .controlSize(.large)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .alert(item: $vm.alert) { info in
            Alert(title: Text(info.title), message: Text(info.message), dismissButton: .default(Text("好")))
        }
    }
}
