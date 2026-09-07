import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Ссылка на контекст: файл + имя. Имена уникальны только внутри файла.
struct ContextRef: Hashable {
    var fileID: String
    var name: String
}

struct MainView: View {
    @EnvironmentObject var store: KubeStore
    @State private var sidebar: String? = "all"
    @State private var selected: ContextRef?
    @State private var search = ""
    @State private var sheet: Sheet?
    @State private var confirmDelete: ContextRef?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @Environment(\.openWindow) private var openWindow

    enum Sheet: Identifiable {
        case newContext(ConfigFile)
        case importInto(ConfigFile, URL)
        case rename(ContextRef)
        var id: String {
            switch self {
            case .newContext(let f): return "new:\(f.id)"
            case .importInto(let f, let u): return "import:\(f.id):\(u.path)"
            case .rename(let r): return "rename:\(r.fileID):\(r.name)"
            }
        }
    }

    private var visibleFiles: [ConfigFile] {
        sidebar == "all" ? store.files : store.files.filter { $0.id == sidebar }
    }

    private var rows: [(file: ConfigFile, context: KContext)] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return visibleFiles.flatMap { f in f.contexts.map { (f, $0) } }.filter { row in
            q.isEmpty || [row.context.name, row.context.cluster, row.context.user, row.context.namespace ?? ""].contains { $0.lowercased().contains(q) }
        }
    }

    /// Файл, в который добавляем/импортируем: выбранный в сайдбаре или основной.
    private var targetFile: ConfigFile? {
        if let f = store.file(sidebar) { return f }
        if let sel = selected, let f = store.file(sel.fileID) { return f }
        return store.primary ?? store.files.first
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarView
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            contextList
                .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        } detail: {
            if let sel = selected, let f = store.file(sel.fileID), let cfg = f.config, let ctx = cfg.context(sel.name) {
                ContextDetail(file: f, config: cfg, context: ctx, onRename: { sheet = .rename(sel) })
                    .id(sel)
            } else {
                ContentUnavailableView("Выберите контекст", systemImage: "helm",
                                       description: Text("Слева — файлы kubeconfig, в середине — их контексты."))
            }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .newContext(let f): NewContextSheet(file: f) { name in selected = ContextRef(fileID: f.id, name: name) }
            case .importInto(let f, let url): ImportSheet(target: f, source: url)
            case .rename(let ref): RenameSheet(ref: ref) { newName in selected = ContextRef(fileID: ref.fileID, name: newName) }
            }
        }
        .confirmationDialog("Удалить контекст?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { ref in
            deleteButtons(ref)
        } message: { ref in
            Text(deleteMessage(ref))
        }
        .alert("Ошибка", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK") { store.lastError = nil }
        } message: { Text(store.lastError ?? "") }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let target = targetFile else { return false }
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { sheet = .importInto(target, url) }
                }
            }
            return true
        }
        .onChange(of: store.files) { _, files in
            // Файл или контекст исчезли (удалили, переименовали снаружи) — снимаем выделение.
            if let sel = selected, files.first(where: { $0.id == sel.fileID })?.config?.context(sel.name) == nil { selected = nil }
        }
        .onAppear {
            if selected == nil, let cur = store.currentContext { selected = ContextRef(fileID: cur.file.id, name: cur.context.name) }
            // Отладка: `KubeLens --cluster` сразу открывает окно ресурсов текущего контекста.
            // `--cluster [контекст]`; `--open <вид> <namespace> <имя>` — сразу страница объекта.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--cluster") {
                let wanted = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : store.currentContext?.context.name
                if let wanted, let row = store.allContexts.first(where: { $0.context.name == wanted }) {
                    openWindow(id: "cluster", value: ClusterTarget(context: row.context.name, kubeconfig: store.kubeconfigEnv(for: row.file), namespace: row.context.namespace))
                }
            }
        }
    }

    // MARK: Сайдбар

    private var sidebarView: some View {
        List(selection: $sidebar) {
            Label("Все контексты", systemImage: "square.stack.3d.up")
                .badge(store.allContexts.count)
                .tag("all")
            Section("Файлы") {
                ForEach(store.files) { f in
                    fileRow(f).tag(f.id)
                }
            }
            if let notice = store.notice {
                Section {
                    Text(notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("Добавить существующий…") { addExisting() }
                    Button("Создать новый…") { createNew() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton).fixedSize()
                if let f = store.file(sidebar), !f.inChain {
                    Button { store.removeFile(f); sidebar = "all" } label: { Image(systemName: "minus") }.buttonStyle(.borderless)
                }
                Spacer()
                Button { store.reloadAll() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                    .help("Перечитать файлы")
            }
            .padding(8)
            .background(.bar)
        }
    }

    private func fileRow(_ f: ConfigFile) -> some View {
        HStack {
            Image(systemName: f.error == nil ? (f.inChain ? "doc.text.fill" : "doc.text") : "exclamationmark.triangle.fill")
                .foregroundStyle(f.error == nil ? Color.accentColor : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(f.shortName)
                Text(f.error ?? f.displayName).font(.caption).foregroundStyle(f.error == nil ? Color.secondary : Color.orange)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if f.inChain { Text("kubectl").font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule()) }
        }
        .badge(f.contexts.count)
        .contextMenu {
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([f.url]) }
            Button("Скопировать export KUBECONFIG=…") { copy("export KUBECONFIG=\(store.kubeconfigEnv(for: f))") }
            Button("Импортировать в этот файл…") { importInto(f) }
            if !f.inChain { Divider(); Button("Убрать из списка") { store.removeFile(f); if sidebar == f.id { sidebar = "all" } } }
        }
        .help(f.displayName)
    }

    // MARK: Список контекстов

    private var contextList: some View {
        let current = store.currentContext
        return List(selection: $selected) {
            // Идентификатор — файл + имя: одно и то же имя может быть в нескольких файлах.
            ForEach(rows.map { (ref: ContextRef(fileID: $0.file.id, name: $0.context.name), file: $0.file, context: $0.context) }, id: \.ref) { row in
                let isCurrent = current?.context.name == row.context.name && current?.file.id == row.file.id
                let ref = row.ref
                HStack(spacing: 8) {
                    Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isCurrent ? Color.green : Color.secondary.opacity(0.4))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.context.name).fontWeight(isCurrent ? .semibold : .regular)
                        HStack(spacing: 6) {
                            Label(row.context.cluster, systemImage: "server.rack")
                            Label(row.context.user, systemImage: "person")
                            if let ns = row.context.namespace { Label(ns, systemImage: "square.grid.2x2") }
                        }
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if sidebar == "all" && store.files.count > 1 {
                        Text(row.file.shortName).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .tag(ref)
                .contextMenu { contextMenu(ref, row.file, isCurrent: isCurrent) }
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(search.isEmpty ? "Нет контекстов" : "Ничего не найдено", systemImage: "magnifyingglass",
                                       description: Text(search.isEmpty ? "Добавьте контекст кнопкой + или перетащите kubeconfig в окно." : ""))
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Контекст, кластер, пользователь…")
        .navigationTitle(store.file(sidebar)?.shortName ?? "Контексты")
        .toolbar {
            ToolbarItemGroup {
                Button { if let f = targetFile { sheet = .newContext(f) } } label: { Label("Новый контекст", systemImage: "plus") }
                    .help("Новый контекст (с кластером и пользователем)")
                Button { if let f = targetFile { importInto(f) } } label: { Label("Импорт", systemImage: "square.and.arrow.down") }
                    .help("Слить другой kubeconfig в \(targetFile?.shortName ?? "файл")")
                if let sel = selected, let f = store.file(sel.fileID) {
                    Button { store.useContext(sel.name, in: f) } label: { Label("Использовать", systemImage: "checkmark.circle") }
                        .help("Сделать текущим контекстом")
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .onDeleteCommand { if let sel = selected { confirmDelete = sel } }
    }

    @ViewBuilder
    private func contextMenu(_ ref: ContextRef, _ f: ConfigFile, isCurrent: Bool) -> some View {
        Button("Использовать") { store.useContext(ref.name, in: f) }.disabled(isCurrent)
        Button("Переименовать…") { selected = ref; sheet = .rename(ref) }
        Button("Дублировать") {
            var newName: String?
            store.update(f) { newName = $0.duplicateContext(ref.name) }
            if let newName { selected = ContextRef(fileID: f.id, name: newName) }
        }
        Divider()
        Button("Экспортировать в отдельный файл…") { exportContext(ref, f) }
        Button("Скопировать kubectl --context=…") { copy("kubectl --context=\(shellQuote(ref.name)) ") }
        if store.files.count > 1 {
            Menu("Скопировать в файл") {
                ForEach(store.files.filter { $0.id != f.id }) { other in
                    Button(other.shortName) { copyContext(ref, from: f, to: other) }
                }
            }
        }
        Divider()
        Button("Удалить…", role: .destructive) { confirmDelete = ref }
    }

    // MARK: Действия

    private func addExisting() {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        p.allowsMultipleSelection = true
        p.showsHiddenFiles = true
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.kube")
        p.message = "Выберите kubeconfig-файлы"
        if p.runModal() == .OK { for u in p.urls { store.addFile(u) }; if let u = p.urls.first { sidebar = u.path } }
    }

    private func createNew() {
        let p = NSSavePanel()
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.kube")
        p.nameFieldStringValue = "config-new.yaml"
        p.showsHiddenFiles = true
        p.message = "Куда сохранить новый kubeconfig"
        if p.runModal() == .OK, let u = p.url { store.createFile(u); sidebar = u.path }
    }

    private func importInto(_ f: ConfigFile) {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        p.showsHiddenFiles = true
        p.message = "Какой kubeconfig слить в \(f.shortName)"
        if p.runModal() == .OK, let u = p.url { sheet = .importInto(f, u) }
    }

    private func exportContext(_ ref: ContextRef, _ f: ConfigFile) {
        guard let cfg = f.config, let mini = cfg.minified(context: ref.name) else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = ref.name.replacingOccurrences(of: "/", with: "_") + ".yaml"
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.kube")
        p.showsHiddenFiles = true
        p.message = "Один контекст с его кластером и пользователем. Файлы сертификатов встраиваются (--flatten)."
        guard p.runModal() == .OK, let u = p.url else { return }
        do {
            let flat = try mini.flattened(baseDirectory: f.url.deletingLastPathComponent())
            try flat.yaml().data(using: .utf8)!.write(to: u, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
        } catch { store.lastError = error.localizedDescription }
    }

    private func copyContext(_ ref: ContextRef, from: ConfigFile, to: ConfigFile) {
        guard let mini = from.config?.minified(context: ref.name) else { return }
        var report = Kubeconfig.MergeReport()
        store.update(to) { report = $0.merge(mini, conflict: .rename) }
        if report.renamed > 0 { store.notice = "Имена в «\(to.shortName)» уже были заняты — скопировано с суффиксом." }
    }

    @ViewBuilder
    private func deleteButtons(_ ref: ContextRef) -> some View {
        let f = store.file(ref.fileID)
        let cfg = f?.config
        let ctx = cfg?.context(ref.name)
        let clusterOrphan = ctx.map { cfg?.contexts(usingCluster: $0.cluster) == [$0.name] } ?? false
        let userOrphan = ctx.map { cfg?.contexts(usingUser: $0.user) == [$0.name] } ?? false
        Button("Удалить только контекст", role: .destructive) {
            if let f { store.update(f) { $0.deleteContext(ref.name) } }
        }
        if clusterOrphan || userOrphan {
            Button("Удалить вместе с кластером и пользователем", role: .destructive) {
                if let f, let ctx {
                    store.update(f) {
                        $0.deleteContext(ref.name)
                        if clusterOrphan { $0.deleteCluster(ctx.cluster) }
                        if userOrphan { $0.deleteUser(ctx.user) }
                    }
                }
            }
        }
        Button("Отмена", role: .cancel) {}
    }

    private func deleteMessage(_ ref: ContextRef) -> String {
        guard let cfg = store.file(ref.fileID)?.config, let ctx = cfg.context(ref.name) else { return "" }
        var parts = ["Контекст «\(ref.name)» будет удалён из \(store.file(ref.fileID)?.shortName ?? "файла"). Копия файла сохранится в резервных копиях."]
        let clusterOrphan = cfg.contexts(usingCluster: ctx.cluster) == [ctx.name]
        let userOrphan = cfg.contexts(usingUser: ctx.user) == [ctx.name]
        if clusterOrphan || userOrphan {
            var orphans: [String] = []
            if clusterOrphan { orphans.append("кластер «\(ctx.cluster)»") }
            if userOrphan { orphans.append("пользователь «\(ctx.user)»") }
            parts.append("Больше никем не используется: " + orphans.joined(separator: ", ") + ".")
        }
        return parts.joined(separator: " ")
    }
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

func shellQuote(_ s: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.@:/"))
    return s.unicodeScalars.allSatisfy { safe.contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Листы

struct RenameSheet: View {
    @EnvironmentObject var store: KubeStore
    @Environment(\.dismiss) private var dismiss
    let ref: ContextRef
    let onDone: (String) -> Void
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Переименовать контекст").font(.headline)
            TextField("Новое имя", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Переименовать", action: save).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 420)
        .onAppear { name = ref.name }
    }

    private func save() {
        let new = name.trimmingCharacters(in: .whitespaces)
        guard let f = store.file(ref.fileID), !new.isEmpty else { return }
        if new == ref.name { dismiss(); return }
        if f.config?.context(new) != nil { error = "Контекст «\(new)» уже есть"; return }
        store.update(f) { try $0.renameContext(ref.name, to: new) }
        onDone(new)
        dismiss()
    }
}

struct NewContextSheet: View {
    @EnvironmentObject var store: KubeStore
    @Environment(\.dismiss) private var dismiss
    let file: ConfigFile
    let onDone: (String) -> Void

    @State private var name = ""
    @State private var namespace = ""
    @State private var clusterMode = 0     // 0 — новый, 1 — существующий
    @State private var clusterName = ""
    @State private var existingCluster = ""
    @State private var server = "https://"
    @State private var caData = ""
    @State private var insecure = false
    @State private var userMode = 0
    @State private var userName = ""
    @State private var existingUser = ""
    @State private var token = ""
    @State private var error: String?

    private var cfg: Kubeconfig { file.config ?? Kubeconfig() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Новый контекст в \(file.shortName)").font(.headline).padding(.bottom, 8)
            Form {
                Section("Контекст") {
                    TextField("Имя контекста", text: $name)
                    TextField("Namespace (необязательно)", text: $namespace)
                }
                Section("Кластер") {
                    if !cfg.clusters.isEmpty {
                        Picker("", selection: $clusterMode) { Text("Новый").tag(0); Text("Существующий").tag(1) }.pickerStyle(.segmented).labelsHidden()
                    }
                    if clusterMode == 1 {
                        Picker("Кластер", selection: $existingCluster) { ForEach(cfg.clusters) { Text($0.name).tag($0.name) } }
                    } else {
                        TextField("Имя кластера", text: $clusterName, prompt: Text(name.isEmpty ? "по имени контекста" : name))
                        TextField("Адрес API-сервера", text: $server)
                        TextField("certificate-authority-data (base64) или PEM", text: $caData, axis: .vertical).lineLimit(2...4).font(.system(.caption, design: .monospaced))
                        Toggle("insecure-skip-tls-verify", isOn: $insecure)
                    }
                }
                Section("Пользователь") {
                    if !cfg.users.isEmpty {
                        Picker("", selection: $userMode) { Text("Новый").tag(0); Text("Существующий").tag(1) }.pickerStyle(.segmented).labelsHidden()
                    }
                    if userMode == 1 {
                        Picker("Пользователь", selection: $existingUser) { ForEach(cfg.users) { Text($0.name).tag($0.name) } }
                    } else {
                        TextField("Имя пользователя", text: $userName, prompt: Text(name.isEmpty ? "по имени контекста" : name))
                        SecureField("Токен (можно оставить пустым и настроить позже)", text: $token)
                    }
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Создать", action: create).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(.top, 8)
        }
        .padding(20).frame(width: 560, height: 620)
        .onAppear { existingCluster = cfg.clusters.first?.name ?? ""; existingUser = cfg.users.first?.name ?? "" }
    }

    private func create() {
        let ctxName = name.trimmingCharacters(in: .whitespaces)
        if cfg.context(ctxName) != nil { error = "Контекст «\(ctxName)» уже есть"; return }
        let cName = clusterMode == 1 ? existingCluster : (clusterName.isEmpty ? ctxName : clusterName)
        let uName = userMode == 1 ? existingUser : (userName.isEmpty ? ctxName : userName)
        if clusterMode == 0 && cfg.cluster(cName) != nil { error = "Кластер «\(cName)» уже есть — выберите «Существующий»"; return }
        if userMode == 0 && cfg.user(uName) != nil { error = "Пользователь «\(uName)» уже есть — выберите «Существующий»"; return }
        store.update(file) { c in
            if clusterMode == 0 {
                var cl = KCluster(name: cName)
                cl.server = server.trimmingCharacters(in: .whitespaces)
                cl.certificateAuthorityData = normalizeBase64(caData)
                cl.insecureSkipTLSVerify = insecure
                c.upsertCluster(cl)
            }
            if userMode == 0 {
                var u = KUser(name: uName)
                if !token.isEmpty { u.kind = .token; u.token = token }
                c.upsertUser(u)
            }
            c.upsertContext(KContext(name: ctxName, cluster: cName, user: uName, namespace: namespace.isEmpty ? nil : namespace))
            if c.currentContext == nil { c.currentContext = ctxName }
        }
        onDone(ctxName)
        dismiss()
    }
}

/// PEM → base64 одной строкой; base64 с переносами — склеить. Пусто → nil.
func normalizeBase64(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return nil }
    if t.contains("-----BEGIN") { return Data(t.utf8).base64EncodedString() }
    return t.components(separatedBy: .whitespacesAndNewlines).joined()
}

struct ImportSheet: View {
    @EnvironmentObject var store: KubeStore
    @Environment(\.dismiss) private var dismiss
    let target: ConfigFile
    let source: URL
    @State private var incoming: Kubeconfig?
    @State private var loadError: String?
    @State private var conflict: Kubeconfig.MergeConflict = .rename
    @State private var flatten = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Импорт в \(target.shortName)").font(.headline)
            Text(source.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if let incoming {
                let existingCtx = Set(target.contexts.map(\.name))
                let conflicts = incoming.contexts.filter { existingCtx.contains($0.name) }.count
                List {
                    Section("Контексты (\(incoming.contexts.count))") {
                        ForEach(incoming.contexts) { c in
                            HStack {
                                Text(c.name)
                                Spacer()
                                if existingCtx.contains(c.name) { Text("уже есть").font(.caption).foregroundStyle(.orange) }
                            }
                        }
                    }
                    Section { Text("Кластеров: \(incoming.clusters.count), пользователей: \(incoming.users.count)").font(.caption).foregroundStyle(.secondary) }
                }
                .frame(height: 220)
                if conflicts > 0 || !incoming.clusters.isEmpty {
                    Picker("При совпадении имён", selection: $conflict) {
                        Text("Добавить с суффиксом -2").tag(Kubeconfig.MergeConflict.rename)
                        Text("Оставить существующие").tag(Kubeconfig.MergeConflict.keepExisting)
                        Text("Заменить существующие").tag(Kubeconfig.MergeConflict.replace)
                    }
                }
                Toggle("Встроить файлы сертификатов (--flatten)", isOn: $flatten)
                    .help("Пути к сертификатам в импортируемом файле относительны его каталога; после слияния они бы сломались.")
            } else {
                ProgressView()
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Импортировать", action: doImport).keyboardShortcut(.defaultAction).disabled(incoming == nil)
            }
        }
        .padding(20).frame(width: 520)
        .onAppear(perform: load)
    }

    private func load() {
        do {
            let text = try String(contentsOf: source, encoding: .utf8)
            incoming = try Kubeconfig(yaml: text)
        } catch { loadError = error.localizedDescription }
    }

    private func doImport() {
        guard var inc = incoming else { return }
        if flatten { do { inc = try inc.flattened(baseDirectory: source.deletingLastPathComponent()) } catch { store.lastError = error.localizedDescription; return } }
        var report = Kubeconfig.MergeReport()
        store.update(target) { report = $0.merge(inc, conflict: conflict) }
        store.notice = "Импорт: добавлено \(report.added), переименовано \(report.renamed), заменено \(report.replaced), пропущено \(report.skipped)."
        dismiss()
    }
}
