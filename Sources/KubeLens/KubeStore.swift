import Foundation
import Combine

/// Файл kubeconfig на диске плюс результат его разбора.
struct ConfigFile: Identifiable, Equatable {
    let url: URL
    var config: Kubeconfig?
    var error: String?
    /// Входит в цепочку kubectl: `$KUBECONFIG` или `~/.kube/config`, когда переменная не задана.
    var inChain: Bool
    var modified: Date?

    var id: String { url.path }
    var displayName: String {
        let home = NSHomeDirectory()
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
    var shortName: String { url.lastPathComponent }
    var contexts: [KContext] { config?.contexts ?? [] }
}

/// Все файлы, которые видит приложение: цепочка kubectl + добавленные вручную.
/// Правки идут через `update`: бэкап → атомарная запись с правами 0600 → перечитывание.
@MainActor
final class KubeStore: ObservableObject {
    @Published private(set) var files: [ConfigFile] = []
    @Published private(set) var chainPaths: [String] = []
    @Published var namespaces: [String: [String]] = [:]   // ключ — имя контекста
    @Published var lastError: String?
    @Published var notice: String?

    private var extraPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "extraFiles") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "extraFiles") }
    }
    private var watchers: [String: FileWatcher] = [:]
    private var suppressReloadUntil = Date.distantPast

    static let defaultPath = NSHomeDirectory() + "/.kube/config"
    let backupsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("KubeLens/backups", isDirectory: true)
    }()

    init() {
        chainPaths = [Self.defaultPath]
        reloadAll()
        // KUBECONFIG из логин-шелла: GUI-приложения его не наследуют.
        Task {
            let env = await ShellEnv.load()
            applyEnvironment(env)
        }
    }

    func applyEnvironment(_ env: ShellEnv) {
        Kubectl.shared.searchPath = env.path
        let paths = env.kubeconfig.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        chainPaths = paths.isEmpty ? [Self.defaultPath] : paths.map { NSString(string: $0).expandingTildeInPath }
        reloadAll()
    }

    // MARK: Вычисляемые представления

    var primary: ConfigFile? { files.first { $0.inChain } }

    /// Что kubectl считает текущим контекстом: первый файл цепочки с непустым current-context.
    var currentContext: (file: ConfigFile, context: KContext)? {
        for f in files where f.inChain {
            if let name = f.config?.currentContext {
                // Контекст может быть определён в другом файле цепочки.
                if let ctx = f.config?.context(name) { return (f, ctx) }
                for g in files where g.inChain { if let ctx = g.config?.context(name) { return (g, ctx) } }
                return (f, KContext(name: name, cluster: "?", user: "?"))
            }
        }
        return nil
    }

    var allContexts: [(file: ConfigFile, context: KContext)] {
        files.flatMap { f in f.contexts.map { (f, $0) } }
    }

    func file(_ id: String?) -> ConfigFile? { files.first { $0.id == id } }

    /// Значение `KUBECONFIG`, при котором kubectl увидит этот файл.
    func kubeconfigEnv(for file: ConfigFile) -> String {
        var paths = chainPaths.filter { FileManager.default.fileExists(atPath: $0) }
        if !paths.contains(file.url.path) { paths.append(file.url.path) }
        return paths.joined(separator: ":")
    }

    // MARK: Загрузка

    func reloadAll() {
        var seen = Set<String>()
        var result: [ConfigFile] = []
        for p in chainPaths + extraPaths where !seen.contains(p) {
            seen.insert(p)
            result.append(load(URL(fileURLWithPath: p), inChain: chainPaths.contains(p)))
        }
        files = result
        syncWatchers()
    }

    private func load(_ url: URL, inChain: Bool) -> ConfigFile {
        var f = ConfigFile(url: url, inChain: inChain)
        f.modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let text = try String(contentsOf: url, encoding: .utf8)
                f.config = try Kubeconfig(yaml: text)
            } else if inChain && url.path == Self.defaultPath {
                f.config = Kubeconfig()   // ~/.kube/config ещё нет — покажем пустой, создадим при первой правке
            } else {
                f.error = "Файл не найден"
            }
        } catch {
            f.error = error.localizedDescription
        }
        return f
    }

    func reload(_ url: URL) {
        guard let i = files.firstIndex(where: { $0.url == url }) else { return }
        files[i] = load(url, inChain: files[i].inChain)
    }

    private func syncWatchers() {
        let wanted = Set(files.map(\.id))
        for k in watchers.keys where !wanted.contains(k) { watchers[k] = nil }
        for f in files where watchers[f.id] == nil {
            watchers[f.id] = FileWatcher(path: f.url.path) { [weak self] in
                guard let self, Date() > self.suppressReloadUntil else { return }
                self.reload(f.url)
            }
        }
    }

    // MARK: Правки

    /// Единая точка записи. Бэкап делается только если содержимое действительно меняется.
    func update(_ file: ConfigFile, _ mutate: (inout Kubeconfig) throws -> Void) {
        do {
            var cfg = file.config ?? Kubeconfig()
            let before = cfg
            try mutate(&cfg)
            guard cfg != before else { return }
            try write(cfg, to: file.url)
            reload(file.url)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func write(_ cfg: Kubeconfig, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) { try backup(url) }
        suppressReloadUntil = Date().addingTimeInterval(0.5)
        try cfg.yaml().data(using: .utf8)!.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func backup(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = url.lastPathComponent + "." + stamp + ".bak"
        try fm.copyItem(at: url, to: backupsDirectory.appendingPathComponent(name))
        pruneBackups(prefix: url.lastPathComponent + ".")
    }

    private func pruneBackups(prefix: String) {
        let configured = UserDefaults.standard.integer(forKey: "maxBackups")
        let keep = configured == 0 ? 20 : max(configured, 1)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: backupsDirectory.path) else { return }
        let mine = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".bak") }.sorted()
        for old in mine.dropLast(keep) { try? FileManager.default.removeItem(at: backupsDirectory.appendingPathComponent(old)) }
    }

    var backups: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "bak" }.sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
    }

    /// Переключение контекста так, как его увидит kubectl: current-context пишется в первый
    /// файл цепочки. Контекст из файла вне `$KUBECONFIG` kubectl не видит, поэтому его вместе
    /// с кластером и пользователем копируем в основной файл (сертификаты-файлы встраиваем)
    /// и делаем текущим уже там.
    func useContext(_ name: String, in file: ConfigFile) {
        guard let primary else { lastError = "Нет основного kubeconfig (~/.kube/config или $KUBECONFIG)"; return }
        if file.inChain {
            update(primary) { $0.currentContext = name }
            notice = nil
            return
        }
        guard let cfg = file.config, var mini = cfg.minified(context: name) else { return }
        mini = (try? mini.flattened(baseDirectory: file.url.deletingLastPathComponent())) ?? mini
        var target = name
        var report = Kubeconfig.MergeReport()
        update(primary) { p in
            let before = Set(p.contexts.map(\.name))
            report = p.merge(mini, conflict: .rename)
            let added = p.contexts.map(\.name).filter { !before.contains($0) }
            target = added.first { $0 == name || $0.hasPrefix(name + "-") } ?? name
            p.currentContext = target
        }
        if lastError == nil {
            notice = report.added > 0 || report.renamed > 0
                ? "Контекст «\(target)» скопирован в \(primary.displayName) и сделан текущим."
                : "Контекст «\(target)» уже был в \(primary.displayName) — сделан текущим."
        }
    }

    func setNamespace(_ ns: String?, context: String, in file: ConfigFile) {
        update(file) { $0.setNamespace(ns?.isEmpty == true ? nil : ns, context: context) }
    }

    // MARK: Файлы

    func addFile(_ url: URL) {
        var extra = extraPaths
        if !extra.contains(url.path) && !chainPaths.contains(url.path) { extra.append(url.path); extraPaths = extra }
        reloadAll()
    }

    func removeFile(_ file: ConfigFile) {
        extraPaths = extraPaths.filter { $0 != file.url.path }
        reloadAll()
    }

    func createFile(_ url: URL) {
        do {
            try write(Kubeconfig(), to: url)
            addFile(url)
        } catch { lastError = error.localizedDescription }
    }

    // MARK: kubectl

    func loadNamespaces(for ctx: KContext, in file: ConfigFile) async {
        do {
            let list = try await Kubectl.shared.namespaces(context: ctx.name, kubeconfig: kubeconfigEnv(for: file))
            namespaces[ctx.name] = list
        } catch {
            lastError = "Не удалось получить namespaces: \(error.localizedDescription)"
        }
    }
}

/// Следит за файлом через DispatchSource; после атомарной перезаписи (новый inode) переоткрывает.
final class FileWatcher {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var retry: DispatchWorkItem?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        arm()
    }

    deinit { cancel() }

    private func arm() {
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else { scheduleRetry(); return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            self.onChange()
            if flags.contains(.delete) || flags.contains(.rename) {
                self.cancel()
                self.scheduleRetry()
            }
        }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        source = src
    }

    private func scheduleRetry() {
        let item = DispatchWorkItem { [weak self] in self?.arm(); self?.onChange() }
        retry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func cancel() {
        retry?.cancel()
        source?.cancel()
        source = nil
        fd = -1
    }
}
