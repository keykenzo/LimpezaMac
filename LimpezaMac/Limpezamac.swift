//
//  Limpezamac.swift
//  LimpezaMac
//
//  Created by Mario Duarte da Silveira on 01/11/26.
//

import SwiftUI
import AppKit
import Combine
import Darwin

// MARK: - Modelos

struct Item: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let size: Int64
    let category: String
}

struct AppInfo: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let bundleID: String
    let size: Int64
}

struct LaunchEntry: Identifiable {
    let id = UUID()
    let url: URL
    let scope: String
}

// MARK: - Utilitários

/// Pasta pessoal REAL (ex.: /Users/mario), mesmo que o app esteja no sandbox.
func realHome() -> URL {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}

/// True se o App Sandbox ainda estiver ligado (aí o app NÃO enxerga ~/Library).
let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

struct ScanResult {
    var items: [Item]
    var notes: [String]
}

func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

func folderSize(_ url: URL) -> Int64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
    if !isDir.boolValue {
        return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }
    guard let en = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                 options: [], errorHandler: { _, _ in true }) else { return 0 }
    var total: Int64 = 0
    for case let f as URL in en {
        if let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
    }
    return total
}

/// Remove itens com travas de segurança: só mexe na pasta do usuário e em /Applications.
func removeItems(_ items: [Item], permanent: Bool) -> (freed: Int64, fails: Int, done: Set<UUID>) {
    let fm = FileManager.default
    let home = realHome().path
    let trash = realHome().appendingPathComponent(".Trash").path
    var freed: Int64 = 0
    var fails = 0
    var done = Set<UUID>()
    for it in items {
        let p = it.url.path
        guard p.hasPrefix(home + "/") || p.hasPrefix("/Applications/") else { fails += 1; continue }
        do {
            if permanent || p.hasPrefix(trash) {
                try fm.removeItem(at: it.url)
            } else {
                try fm.trashItem(at: it.url, resultingItemURL: nil)
            }
            freed += it.size
            done.insert(it.id)
        } catch {
            fails += 1
        }
    }
    return (freed, fails, done)
}

// MARK: - Scanners

func scanCleanTargets() -> ScanResult {
    let fm = FileManager.default
    let home = realHome()
    var out: [Item] = []
    var notes: [String] = []

    func addChildren(of dir: URL, category: String, minSize: Int64 = 100_000) {
        guard fm.fileExists(atPath: dir.path) else { return }
        let kids: [URL]
        do {
            kids = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])
        } catch {
            notes.append("Sem permissão para ler: \(category)")
            return
        }
        for k in kids {
            let s = folderSize(k)
            if s >= minSize {
                out.append(Item(url: k, name: k.lastPathComponent, size: s, category: category))
            }
        }
    }

    if isSandboxed {
        notes.append("O App Sandbox está LIGADO: remova em Signing & Capabilities.")
    }

    let lib = home.appendingPathComponent("Library")
    addChildren(of: lib.appendingPathComponent("Caches"), category: "Cache de apps")
    addChildren(of: lib.appendingPathComponent("Logs"), category: "Logs")
    addChildren(of: lib.appendingPathComponent("Developer/Xcode/DerivedData"), category: "Xcode: DerivedData")
    addChildren(of: lib.appendingPathComponent("Developer/Xcode/iOS DeviceSupport"), category: "Xcode: DeviceSupport")
    addChildren(of: lib.appendingPathComponent("Developer/Xcode/watchOS DeviceSupport"), category: "Xcode: DeviceSupport")
    addChildren(of: lib.appendingPathComponent("Developer/CoreSimulator/Caches"), category: "Xcode: Simulador")
    addChildren(of: lib.appendingPathComponent("Containers/com.apple.mail/Data/Library/Mail Downloads"), category: "Mail: anexos baixados")
    addChildren(of: home.appendingPathComponent(".npm/_cacache"), category: "Cache do npm")
    addChildren(of: home.appendingPathComponent(".Trash"), category: "Lixeira", minSize: 0)
    return ScanResult(items: out, notes: notes)
}

func scanLargeFiles(minBytes: Int64 = 500_000_000) -> ScanResult {
    let fm = FileManager.default
    let home = realHome()
    let library = home.appendingPathComponent("Library").path
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
    guard let en = fm.enumerator(at: home, includingPropertiesForKeys: keys,
                                 options: [.skipsPackageDescendants],
                                 errorHandler: { _, _ in true }) else { return ScanResult(items: [], notes: ["Sem permissão para ler a pasta pessoal."]) }
    var out: [Item] = []
    for case let f as URL in en {
        if f.path == library { en.skipDescendants(); continue }
        guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
        let s = Int64(v.totalFileAllocatedSize ?? 0)
        if s >= minBytes {
            out.append(Item(url: f, name: f.lastPathComponent, size: s,
                            category: f.deletingLastPathComponent().path))
        }
    }
    return ScanResult(items: out, notes: isSandboxed ? ["O App Sandbox está LIGADO: remova em Signing & Capabilities."] : [])
}

func scanApps() -> [AppInfo] {
    let fm = FileManager.default
    let dirs = [URL(fileURLWithPath: "/Applications"),
                realHome().appendingPathComponent("Applications")]
    var out: [AppInfo] = []
    for d in dirs {
        guard let kids = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) else { continue }
        for k in kids where k.pathExtension == "app" {
            guard let b = Bundle(url: k), let id = b.bundleIdentifier else { continue }
            if id.hasPrefix("com.apple.") { continue }
            out.append(AppInfo(url: k, name: k.deletingPathExtension().lastPathComponent,
                               bundleID: id, size: folderSize(k)))
        }
    }
    return out.sorted { $0.size > $1.size }
}

func findLeftovers(for app: AppInfo) -> [Item] {
    let fm = FileManager.default
    let lib = realHome().appendingPathComponent("Library")
    let subs = ["Application Support", "Caches", "Preferences", "Containers", "Group Containers",
                "Saved Application State", "Logs", "HTTPStorages", "WebKit",
                "Application Scripts", "LaunchAgents"]
    var out = [Item(url: app.url, name: app.name + ".app", size: app.size, category: "Aplicativo")]
    for s in subs {
        let dir = lib.appendingPathComponent(s)
        guard let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
        for k in kids {
            let n = k.lastPathComponent
            if n.contains(app.bundleID) || (s == "Application Support" && n == app.name) {
                out.append(Item(url: k, name: n, size: folderSize(k), category: "Library/" + s))
            }
        }
    }
    return out
}

func scanLaunchEntries() -> [LaunchEntry] {
    let fm = FileManager.default
    let places: [(String, URL)] = [
        ("Usuário (inicia com o seu login)", realHome().appendingPathComponent("Library/LaunchAgents")),
        ("Sistema (todos os usuários)", URL(fileURLWithPath: "/Library/LaunchAgents")),
        ("Daemons (segundo plano, root)", URL(fileURLWithPath: "/Library/LaunchDaemons"))
    ]
    var out: [LaunchEntry] = []
    for (scope, dir) in places {
        guard let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
        for k in kids where k.pathExtension == "plist" {
            out.append(LaunchEntry(url: k, scope: scope))
        }
    }
    return out.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
}

// MARK: - Desempenho (CPU / memória)

func cpuTicks() -> host_cpu_load_info? {
    var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
    var info = host_cpu_load_info()
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
        }
    }
    return r == KERN_SUCCESS ? info : nil
}

func memoryUsedBytes() -> Int64 {
    var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    var stats = vm_statistics64_data_t()
    let r = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
        }
    }
    guard r == KERN_SUCCESS else { return 0 }
    let page = Int64(getpagesize())
    return (Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
}

func diskInfo() -> (free: Int64, total: Int64) {
    let url = URL(fileURLWithPath: "/")
    let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
    return (v?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v?.volumeTotalCapacity ?? 0))
}

final class PerfModel: ObservableObject {
    @Published var cpu: Double = 0
    @Published var memUsed: Int64 = 0
    let memTotal = Int64(ProcessInfo.processInfo.physicalMemory)
    private var timer: Timer?
    private var prev: host_cpu_load_info?

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        if let now = cpuTicks() {
            if let p = prev {
                let user = Double(now.cpu_ticks.0 &- p.cpu_ticks.0)
                let sys  = Double(now.cpu_ticks.1 &- p.cpu_ticks.1)
                let idle = Double(now.cpu_ticks.2 &- p.cpu_ticks.2)
                let nice = Double(now.cpu_ticks.3 &- p.cpu_ticks.3)
                let total = user + sys + idle + nice
                if total > 0 { cpu = (user + sys + nice) / total }
            }
            prev = now
        }
        memUsed = memoryUsedBytes()
    }
}

// MARK: - Modelo genérico de lista escaneável

final class ItemsModel: ObservableObject {
    @Published var items: [Item] = []
    @Published var selected = Set<UUID>()
    @Published var busy = false
    @Published var message = ""
    private let scanner: () -> ScanResult
    private let selectAllByDefault: Bool

    init(selectAllByDefault: Bool, scanner: @escaping () -> ScanResult) {
        self.scanner = scanner
        self.selectAllByDefault = selectAllByDefault
    }

    var selectedSize: Int64 {
        items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func scan() {
        busy = true
        message = ""
        let s = scanner
        let all = selectAllByDefault
        DispatchQueue.global(qos: .userInitiated).async {
            let result = s()
            let found = result.items.sorted { $0.size > $1.size }
            DispatchQueue.main.async {
                self.items = found
                self.selected = all ? Set(found.map { $0.id }) : []
                self.busy = false
                var msg = found.isEmpty ? "Nada encontrado." : "Total encontrado: " + formatBytes(found.reduce(0) { $0 + $1.size })
                if !result.notes.isEmpty { msg += " · " + result.notes.joined(separator: " · ") }
                self.message = msg
            }
        }
    }

    func removeSelected(permanent: Bool) {
        let chosen = items.filter { selected.contains($0.id) }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = removeItems(chosen, permanent: permanent)
            DispatchQueue.main.async {
                self.items.removeAll { r.done.contains($0.id) }
                self.selected.subtract(r.done)
                self.busy = false
                var msg = (permanent ? "Apagado: " : "Movido pra Lixeira: ") + formatBytes(r.freed)
                if !permanent { msg += " (o espaço só volta quando a Lixeira for esvaziada)" }
                if r.fails > 0 { msg += " · \(r.fails) item(ns) falharam (permissão)" }
                self.message = msg
            }
        }
    }
}

final class AppsModel: ObservableObject {
    @Published var apps: [AppInfo] = []
    @Published var current: AppInfo?
    @Published var leftovers: [Item] = []
    @Published var selected = Set<UUID>()
    @Published var busy = false
    @Published var message = ""

    var selectedSize: Int64 {
        leftovers.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func load() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let a = scanApps()
            DispatchQueue.main.async { self.apps = a; self.busy = false }
        }
    }

    func choose(_ app: AppInfo?) {
        current = app
        leftovers = []
        selected = []
        message = ""
        guard let app = app else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let l = findLeftovers(for: app)
            DispatchQueue.main.async {
                guard self.current?.id == app.id else { return }
                self.leftovers = l
                self.selected = Set(l.map { $0.id })
            }
        }
    }

    func uninstall() {
        let chosen = leftovers.filter { selected.contains($0.id) }
        let appID = current?.id
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = removeItems(chosen, permanent: false)
            DispatchQueue.main.async {
                self.leftovers.removeAll { r.done.contains($0.id) }
                self.selected.subtract(r.done)
                if self.leftovers.isEmpty || !self.leftovers.contains(where: { $0.category == "Aplicativo" }) {
                    self.apps.removeAll { $0.id == appID }
                }
                self.busy = false
                var msg = "Movido pra Lixeira: " + formatBytes(r.freed)
                if r.fails > 0 { msg += " · \(r.fails) item(ns) falharam (permissão)" }
                self.message = msg
            }
        }
    }
}

// MARK: - Views reutilizáveis

struct ItemListView: View {
    let items: [Item]
    @Binding var selected: Set<UUID>

    var body: some View {
        List {
            ForEach(items) { it in
                HStack {
                    Toggle("", isOn: Binding(
                        get: { selected.contains(it.id) },
                        set: { on in
                            if on { selected.insert(it.id) } else { selected.remove(it.id) }
                        })
                    ).labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(it.name).lineLimit(1)
                        Text(it.category).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(formatBytes(it.size)).monospacedDigit().foregroundStyle(.secondary)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([it.url])
                    } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Mostrar no Finder")
                }
            }
        }
    }
}

struct ScanPane: View {
    let title: String
    let subtitle: String
    @ObservedObject var model: ItemsModel
    @State private var permanent = false
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).foregroundStyle(.secondary)
            if isSandboxed {
                Text("⚠️ O App Sandbox está ligado, então o app não enxerga suas pastas. No Xcode: Signing & Capabilities → clique no x do App Sandbox → compile de novo.")
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Escanear") { model.scan() }.disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Toggle("Apagar definitivamente (sem Lixeira)", isOn: $permanent)
            }
            if model.items.isEmpty {
                Spacer()
                Text(model.busy ? "Trabalhando…" : (model.message.isEmpty ? "Clique em Escanear." : model.message))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ItemListView(items: model.items, selected: $model.selected)
            }
            HStack {
                Text("Selecionado: \(formatBytes(model.selectedSize))").bold()
                Text(model.message).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Limpar selecionados") { confirm = true }
                    .disabled(model.selected.isEmpty || model.busy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .alert("Remover \(model.selected.count) item(ns)?", isPresented: $confirm) {
            Button("Cancelar", role: .cancel) {}
            Button(permanent ? "Apagar definitivamente" : "Mover pra Lixeira", role: .destructive) {
                model.removeSelected(permanent: permanent)
            }
        } message: {
            Text("Total: \(formatBytes(model.selectedSize)). " +
                 (permanent ? "Isso NÃO pode ser desfeito." : "Dá pra recuperar pela Lixeira."))
        }
    }
}

// MARK: - Telas

struct AppsView: View {
    @ObservedObject var model: AppsModel
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Aplicativos").font(.largeTitle.bold())
            Text("Escolha um app. Ele e os arquivos que ele espalhou pela Library vão pra Lixeira.")
                .foregroundStyle(.secondary)
            HSplitView {
                List(model.apps, selection: Binding(
                    get: { model.current?.id },
                    set: { id in model.choose(model.apps.first { $0.id == id }) })
                ) { app in
                    HStack {
                        Text(app.name).lineLimit(1)
                        Spacer()
                        Text(formatBytes(app.size)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(app.id)
                }
                .frame(minWidth: 260)

                VStack(alignment: .leading) {
                    if model.current == nil {
                        Text("Selecione um app à esquerda.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ItemListView(items: model.leftovers, selected: $model.selected)
                        HStack {
                            Text("Selecionado: \(formatBytes(model.selectedSize))").bold()
                            Text(model.message).foregroundStyle(.secondary).lineLimit(2)
                            Spacer()
                            Button("Desinstalar") { confirm = true }
                                .disabled(model.selected.isEmpty || model.busy)
                        }
                    }
                }
                .frame(minWidth: 320)
            }
        }
        .padding()
        .onAppear { if model.apps.isEmpty { model.load() } }
        .alert("Desinstalar \(model.current?.name ?? "")?", isPresented: $confirm) {
            Button("Cancelar", role: .cancel) {}
            Button("Mover pra Lixeira", role: .destructive) { model.uninstall() }
        } message: {
            Text("\(model.selected.count) item(ns), \(formatBytes(model.selectedSize)).")
        }
    }
}

struct OptimizeView: View {
    @State private var entries: [LaunchEntry] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Otimização").font(.largeTitle.bold())
            Text("Itens que iniciam sozinhos com o Mac. Só liste e revise: se não reconhece um item, deixe como está.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Abrir Itens de Início do macOS") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(u)
                    }
                }
                Button("Recarregar") { load() }
            }
            List(entries) { e in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.url.deletingPathExtension().lastPathComponent).lineLimit(1)
                        Text(e.scope).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Mostrar no Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([e.url])
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding()
        .onAppear { if !loaded { load() } }
    }

    private func load() {
        loaded = true
        DispatchQueue.global(qos: .userInitiated).async {
            let e = scanLaunchEntries()
            DispatchQueue.main.async { entries = e }
        }
    }
}

struct SpaceView: View {
    @ObservedObject var model: ItemsModel
    @State private var disk = diskInfo()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let used = max(disk.total - disk.free, 0)
            VStack(alignment: .leading, spacing: 4) {
                Text("Disco: \(formatBytes(disk.free)) livres de \(formatBytes(disk.total))")
                ProgressView(value: disk.total > 0 ? Double(used) / Double(disk.total) : 0)
            }
            .padding([.horizontal, .top])
            ScanPane(title: "Espaço",
                     subtitle: "Arquivos com mais de 500 MB na sua pasta pessoal (a pasta Library fica de fora). Nada vem marcado.",
                     model: model)
        }
        .onAppear { disk = diskInfo() }
    }
}

struct PerformanceView: View {
    @ObservedObject var perf: PerfModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Desempenho").font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text("CPU: \(Int(perf.cpu * 100))%")
                ProgressView(value: perf.cpu)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Memória: \(formatBytes(perf.memUsed)) de \(formatBytes(perf.memTotal))")
                ProgressView(value: perf.memTotal > 0 ? Double(perf.memUsed) / Double(perf.memTotal) : 0)
            }
            Button("Abrir Monitor de Atividade") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            Spacer()
        }
        .padding()
        .onAppear { perf.start() }
        .onDisappear { perf.stop() }
    }
}

// MARK: - Raiz do app

enum Pane: String, CaseIterable, Identifiable {
    case limpeza = "Limpeza"
    case apps = "Aplicativos"
    case otimizacao = "Otimização"
    case espaco = "Espaço"
    case desempenho = "Desempenho"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .limpeza: return "trash"
        case .apps: return "square.grid.2x2"
        case .otimizacao: return "bolt"
        case .espaco: return "internaldrive"
        case .desempenho: return "gauge"
        }
    }
}

struct RootView: View {
    @State private var pane: Pane? = .limpeza
    @StateObject private var cleanModel = ItemsModel(selectAllByDefault: true, scanner: scanCleanTargets)
    @StateObject private var largeModel = ItemsModel(selectAllByDefault: false, scanner: { scanLargeFiles() })
    @StateObject private var appsModel = AppsModel()
    @StateObject private var perf = PerfModel()

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.allCases) { p in
                    Label(p.rawValue, systemImage: p.icon).tag(p)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch pane ?? .limpeza {
            case .limpeza:
                ScanPane(title: "Limpeza",
                         subtitle: "Caches, logs, lixo do Xcode e Lixeira. Tudo isso o macOS e os apps recriam quando precisam.",
                         model: cleanModel)
            case .apps: AppsView(model: appsModel)
            case .otimizacao: OptimizeView()
            case .espaco: SpaceView(model: largeModel)
            case .desempenho: PerformanceView(perf: perf)
            }
        }
    }
}

@main
struct LimpezaMacApp: App {
    var body: some Scene {
        WindowGroup {
            RootView().frame(minWidth: 860, minHeight: 560)
        }
    }
}
