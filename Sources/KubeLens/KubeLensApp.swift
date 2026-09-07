import SwiftUI
import AppKit
import ServiceManagement

@main
struct KubeLensApp: App {
    @StateObject private var store = KubeStore()
    @AppStorage("showContextInMenuBar") private var showContextInMenuBar = true
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @Environment(\.openWindow) private var openWindow

    init() { AppAppearance.apply(.current) }

    var body: some Scene {
        Window("KubeLens", id: "main") {
            MainView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 520)
                .onChange(of: appearance) { _, v in AppAppearance.apply(AppAppearance(rawValue: v) ?? .system) }
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть KubeLens") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                    .keyboardShortcut("o")
            }
        }

        WindowGroup("Кластер", id: "cluster", for: ClusterTarget.self) { $target in
            if let target { ClusterWindow(target: target).frame(minWidth: 1000, minHeight: 560) }
        }
        .defaultSize(width: 1280, height: 760)

        MenuBarExtra {
            MenuBarContent().environmentObject(store)
        } label: {
            menuBarLabel
        }

        Settings { SettingsView().environmentObject(store) }
    }

    private var menuBarLabel: some View {
        let name = store.currentContext?.context.name
        return HStack(spacing: 4) {
            Image(systemName: "helm")
            if showContextInMenuBar, let name {
                Text(name.count > 28 ? String(name.prefix(27)) + "…" : name)
            }
        }
    }
}

/// Меню в строке меню: переключение контекста и namespace в два клика, остальное — в окне.
struct MenuBarContent: View {
    @EnvironmentObject var store: KubeStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let current = store.currentContext
        let chainFiles = store.files.filter { $0.inChain && !$0.contexts.isEmpty }
        let extraFiles = store.files.filter { !$0.inChain && !$0.contexts.isEmpty }

        if let current {
            Text("Текущий: \(current.context.name)")
            if let ns = current.context.namespace { Text("Namespace: \(ns)") }
        } else {
            Text("Контекст не выбран")
        }
        Divider()

        if chainFiles.isEmpty && extraFiles.isEmpty {
            Text("Нет контекстов").foregroundStyle(.secondary)
        }
        ForEach(chainFiles) { f in
            if chainFiles.count > 1 { Text(f.displayName).font(.caption) }
            contextItems(f, current: current?.context.name)
        }
        if !extraFiles.isEmpty {
            Divider()
            ForEach(extraFiles) { f in
                Menu(f.displayName) { contextItems(f, current: nil) }
            }
        }

        if let current {
            Divider()
            Menu("Namespace") {
                namespaceItems(current)
            }
        }

        Divider()
        Menu("Тема") {
            ForEach(AppAppearance.allCases) { a in
                Button {
                    UserDefaults.standard.set(a.rawValue, forKey: "appearance")
                    AppAppearance.apply(a)
                } label: {
                    if a == AppAppearance.current { Label(a.title, systemImage: "checkmark") } else { Text(a.title) }
                }
            }
        }
        if let current, Kubectl.shared.executable != nil {
            Button("Ресурсы кластера…") {
                openWindow(id: "cluster", value: ClusterTarget(context: current.context.name, kubeconfig: store.kubeconfigEnv(for: current.file), namespace: current.context.namespace))
                NSApp.activate(ignoringOtherApps: true)
            }.keyboardShortcut("k")
        }
        Button("Открыть KubeLens…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut("o")
        SettingsLink { Text("Настройки…") }.keyboardShortcut(",")
        Button("Выйти") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    @ViewBuilder
    private func contextItems(_ f: ConfigFile, current: String?) -> some View {
        ForEach(f.contexts) { c in
            Button {
                store.useContext(c.name, in: f)
            } label: {
                if c.name == current {
                    Label(c.name, systemImage: "checkmark")
                } else {
                    Text(c.name)
                }
            }
        }
    }

    @ViewBuilder
    private func namespaceItems(_ current: (file: ConfigFile, context: KContext)) -> some View {
        let list = store.namespaces[current.context.name] ?? []
        if list.isEmpty {
            Text("Список ещё не загружен").foregroundStyle(.secondary)
        }
        ForEach(list, id: \.self) { ns in
            Button {
                store.setNamespace(ns, context: current.context.name, in: current.file)
            } label: {
                if ns == (current.context.namespace ?? "default") { Label(ns, systemImage: "checkmark") } else { Text(ns) }
            }
        }
        Divider()
        Button("Обновить список") {
            Task { await store.loadNamespaces(for: current.context, in: current.file) }
        }
        Button("Сбросить (default)") {
            store.setNamespace(nil, context: current.context.name, in: current.file)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: KubeStore
    @AppStorage("showContextInMenuBar") private var showContextInMenuBar = true
    @AppStorage("maxBackups") private var maxBackups = 20
    @AppStorage("kubectlPath") private var kubectlPath = ""
    @AppStorage("refreshInterval") private var refreshInterval = 5.0
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Оформление") {
                Picker("Тема", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { a in
                        Label(a.title, systemImage: a.icon).tag(a.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, v in AppAppearance.apply(AppAppearance(rawValue: v) ?? .system) }
                Text("«Как в системе» следует переключателю в Системных настройках → Внешний вид.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Строка меню") {
                Toggle("Показывать имя текущего контекста", isOn: $showContextInMenuBar)
                Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch { loginError = error.localizedDescription; launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
            }
            Section("kubectl") {
                TextField("Путь к kubectl (пусто — искать в PATH)", text: $kubectlPath)
                Stepper("Автообновление ресурсов: \(Int(refreshInterval)) с", value: $refreshInterval, in: 2...60, step: 1)
                Text(Kubectl.shared.executable.map { "Найден: \($0)" } ?? "kubectl не найден — список namespaces и проверка связи недоступны")
                    .font(.caption).foregroundStyle(.secondary)
                Text("kubectl нужен для окна «Ресурсы кластера», списка namespaces и проверки подключения. Файлы kubeconfig KubeLens читает и пишет сам.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Резервные копии") {
                Stepper("Хранить копий на файл: \(maxBackups)", value: $maxBackups, in: 1...200)
                HStack {
                    Text(store.backupsDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Показать в Finder") {
                        try? FileManager.default.createDirectory(at: store.backupsDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(store.backupsDirectory)
                    }
                }
                Text("Перед каждой записью файла сохраняется его копия. Правки вне KubeLens подхватываются автоматически.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Файлы") {
                ForEach(store.chainPaths, id: \.self) { p in
                    Label(p.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "link")
                        .font(.caption)
                }
                Text(store.chainPaths == [KubeStore.defaultPath]
                     ? "KUBECONFIG не задан — kubectl читает ~/.kube/config."
                     : "Цепочка из $KUBECONFIG вашего шелла. Переключение контекста пишется в первый файл.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
    }
}
