import SwiftUI
import AppKit

/// Правая колонка: контекст и его кластер/пользователь. Правки копятся в @State
/// и пишутся в файл по кнопке «Сохранить», чтобы не плодить бэкапы на каждое нажатие.
struct ContextDetail: View {
    @EnvironmentObject var store: KubeStore
    let file: ConfigFile
    let config: Kubeconfig
    let context: KContext
    let onRename: () -> Void

    @State private var tab = 0
    @State private var probe: Kubectl.Probe?
    @State private var probeError: String?
    @State private var probing = false
    @Environment(\.openWindow) private var openWindow

    private var isCurrent: Bool { store.currentContext?.context.name == context.name && store.currentContext?.file.id == file.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                Text("Контекст").tag(0)
                Text("Кластер").tag(1)
                Text("Пользователь").tag(2)
                Text("YAML").tag(3)
            }
            .pickerStyle(.segmented).labelsHidden().padding(12)
            switch tab {
            case 0: ContextTab(file: file, config: config, context: context)
            case 1:
                if let cl = config.cluster(context.cluster) {
                    ClusterTab(file: file, cluster: cl, usedBy: config.contexts(usingCluster: cl.name)).id(cl.name)
                } else {
                    missing("Кластер «\(context.cluster)» не описан в этом файле") {
                        store.update(file) { var c = KCluster(name: context.cluster); c.server = "https://"; $0.upsertCluster(c) }
                    }
                }
            case 2:
                if let u = config.user(context.user) {
                    UserTab(file: file, user: u, usedBy: config.contexts(usingUser: u.name)).id(u.name)
                } else {
                    missing("Пользователь «\(context.user)» не описан в этом файле") {
                        store.update(file) { $0.upsertUser(KUser(name: context.user)) }
                    }
                }
            default: YAMLTab(file: file, config: config, context: context)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "helm")
                .font(.system(size: 28)).foregroundStyle(isCurrent ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(context.name).font(.title2).fontWeight(.semibold).textSelection(.enabled)
                    Button { onRename() } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Переименовать")
                }
                Text(config.cluster(context.cluster)?.server ?? "адрес неизвестен")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(file.displayName).font(.caption).foregroundStyle(.secondary)
                    if !file.inChain {
                        Text("вне KUBECONFIG").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2), in: Capsule()).help("kubectl не видит этот файл, пока он не в $KUBECONFIG. «Использовать» скопирует контекст в основной файл.")
                    }
                    probeView
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button { store.useContext(context.name, in: file) } label: {
                    Label(isCurrent ? "Текущий" : "Использовать", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent).disabled(isCurrent)
                Button {
                    openWindow(id: "cluster", value: ClusterTarget(context: context.name, kubeconfig: store.kubeconfigEnv(for: file), namespace: context.namespace))
                } label: { Label("Ресурсы кластера", systemImage: "cube.transparent") }
                    .disabled(Kubectl.shared.executable == nil)
                    .help(Kubectl.shared.executable == nil ? "kubectl не найден" : "Поды, деплойменты, сервисы, конфиги… (⌘K)")
                    .keyboardShortcut("k")
                Button { Task { await runProbe() } } label: { Label("Проверить связь", systemImage: "dot.radiowaves.left.and.right") }
                    .disabled(probing || Kubectl.shared.executable == nil)
                    .help(Kubectl.shared.executable == nil ? "kubectl не найден" : "kubectl version через этот контекст")
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var probeView: some View {
        if probing { ProgressView().controlSize(.mini) }
        else if let probe {
            Label("\(probe.serverVersion) · \(Int(probe.elapsed * 1000)) мс", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        } else if let probeError {
            Label(probeError, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red).lineLimit(2).help(probeError)
        }
    }

    private func runProbe() async {
        probing = true; probe = nil; probeError = nil
        defer { probing = false }
        do { probe = try await Kubectl.shared.probe(context: context.name, kubeconfig: store.kubeconfigEnv(for: file)) }
        catch { probeError = error.localizedDescription }
    }

    private func missing(_ text: String, create: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label(text, systemImage: "exclamationmark.triangle")
        } description: {
            Text("kubectl с таким контекстом работать не сможет.")
        } actions: {
            Button("Создать запись", action: create)
        }
    }
}

// MARK: - Контекст

struct ContextTab: View {
    @EnvironmentObject var store: KubeStore
    let file: ConfigFile
    let config: Kubeconfig
    let context: KContext

    @State private var cluster = ""
    @State private var user = ""
    @State private var namespace = ""
    @State private var loadingNS = false

    private var dirty: Bool { cluster != context.cluster || user != context.user || namespace != (context.namespace ?? "") }

    var body: some View {
        Form {
            Section {
                Picker("Кластер", selection: $cluster) {
                    ForEach(config.clusters) { Text($0.name).tag($0.name) }
                    if config.cluster(cluster) == nil { Text("\(cluster) (нет в файле)").tag(cluster) }
                }
                Picker("Пользователь", selection: $user) {
                    ForEach(config.users) { Text("\($0.name) · \($0.summary)").tag($0.name) }
                    if config.user(user) == nil { Text("\(user) (нет в файле)").tag(user) }
                }
                HStack {
                    TextField("Namespace", text: $namespace, prompt: Text("default"))
                    Menu {
                        let list = store.namespaces[context.name] ?? []
                        if list.isEmpty { Text("Список не загружен") }
                        ForEach(list, id: \.self) { ns in Button(ns) { namespace = ns } }
                        Divider()
                        Button("Загрузить из кластера") { Task { await loadNS() } }.disabled(Kubectl.shared.executable == nil)
                    } label: {
                        if loadingNS { ProgressView().controlSize(.small) } else { Image(systemName: "list.bullet") }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Выбрать из namespaces кластера (kubectl get ns)")
                }
            }
            Section {
                HStack {
                    Button("Отменить") { reset() }.disabled(!dirty)
                    Button("Сохранить") { save() }.keyboardShortcut("s").buttonStyle(.borderedProminent).disabled(!dirty)
                    Spacer()
                    Text("⌘S").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Команды") {
                CopyRow(title: "Переключиться в терминале", text: "kubectl config use-context \(shellQuote(context.name))")
                CopyRow(title: "Одноразово", text: "kubectl --context=\(shellQuote(context.name)) -n \(shellQuote(namespace.isEmpty ? "default" : namespace)) get pods")
                if !file.inChain { CopyRow(title: "KUBECONFIG для этого файла", text: "export KUBECONFIG=\(store.kubeconfigEnv(for: file))") }
            }
            if !config.problems.isEmpty {
                Section("Предупреждения") {
                    ForEach(config.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reset)
        .onChange(of: context) { _, _ in reset() }
    }

    private func reset() { cluster = context.cluster; user = context.user; namespace = context.namespace ?? "" }

    private func save() {
        var c = context
        c.cluster = cluster; c.user = user; c.namespace = namespace.isEmpty ? nil : namespace
        store.update(file) { $0.upsertContext(c) }
    }

    private func loadNS() async {
        loadingNS = true
        await store.loadNamespaces(for: context, in: file)
        loadingNS = false
    }
}

struct CopyRow: View {
    let title: String
    let text: String
    @State private var copied = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button {
                copy(text); copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }.buttonStyle(.borderless)
        }
    }
}

// MARK: - Кластер

struct ClusterTab: View {
    @EnvironmentObject var store: KubeStore
    let file: ConfigFile
    let cluster: KCluster
    let usedBy: [String]

    @State private var draft: KCluster
    @State private var caMode = 0   // 0 — data, 1 — file, 2 — нет
    @State private var caText = ""
    @State private var showCA = false
    @State private var renameTo = ""

    init(file: ConfigFile, cluster: KCluster, usedBy: [String]) {
        self.file = file; self.cluster = cluster; self.usedBy = usedBy
        _draft = State(initialValue: cluster)
    }

    private var composed: KCluster {
        var d = draft
        switch caMode {
        case 0: d.certificateAuthorityData = normalizeBase64(caText); d.certificateAuthority = nil
        case 1: d.certificateAuthority = caText.isEmpty ? nil : caText; d.certificateAuthorityData = nil
        default: d.certificateAuthority = nil; d.certificateAuthorityData = nil
        }
        return d
    }
    private var dirty: Bool { composed != cluster }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Имя", text: $renameTo)
                    if renameTo != cluster.name && !renameTo.isEmpty {
                        Button("Переименовать") {
                            store.update(file) { try $0.renameCluster(cluster.name, to: renameTo) }
                        }
                    }
                }
                TextField("Адрес API-сервера", text: $draft.server, prompt: Text("https://host:6443"))
                    .font(.system(.body, design: .monospaced))
                Toggle("insecure-skip-tls-verify", isOn: $draft.insecureSkipTLSVerify)
                    .help("Не проверять сертификат сервера. Только для локальных/тестовых кластеров.")
            }
            Section("Сертификат центра (CA)") {
                Picker("", selection: $caMode) {
                    Text("Встроенный (base64)").tag(0); Text("Файл").tag(1); Text("Нет").tag(2)
                }.pickerStyle(.segmented).labelsHidden()
                if caMode == 0 {
                    HStack(alignment: .top) {
                        if showCA {
                            TextField("base64 или PEM", text: $caText, axis: .vertical).lineLimit(3...8).font(.system(.caption, design: .monospaced))
                        } else {
                            Text(caText.isEmpty ? "не задан" : certSummary(caText)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        Button(showCA ? "Скрыть" : "Показать") { showCA.toggle() }
                        Button("Из файла…") { pickCAFile() }
                    }
                } else if caMode == 1 {
                    HStack {
                        TextField("Путь к PEM-файлу", text: $caText).font(.system(.body, design: .monospaced))
                        Button("Выбрать…") {
                            let p = NSOpenPanel(); p.showsHiddenFiles = true
                            if p.runModal() == .OK, let u = p.url { caText = u.path }
                        }
                    }
                    Text("Относительный путь считается от каталога kubeconfig. При экспорте файл встраивается.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Дополнительно") {
                TextField("proxy-url", text: Binding(get: { draft.proxyURL ?? "" }, set: { draft.proxyURL = $0.isEmpty ? nil : $0 }), prompt: Text("socks5://localhost:1080"))
                TextField("tls-server-name", text: Binding(get: { draft.tlsServerName ?? "" }, set: { draft.tlsServerName = $0.isEmpty ? nil : $0 }))
                Toggle("disable-compression", isOn: $draft.disableCompression)
            }
            Section {
                HStack {
                    Button("Отменить") { reset() }.disabled(!dirty)
                    Button("Сохранить") { store.update(file) { $0.upsertCluster(composed) } }.keyboardShortcut("s").buttonStyle(.borderedProminent).disabled(!dirty)
                    Spacer()
                    Text(usedBy.count == 1 ? "Используется только этим контекстом" : "Используется контекстами: \(usedBy.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reset)
    }

    private func reset() {
        draft = cluster
        renameTo = cluster.name
        if let d = cluster.certificateAuthorityData { caMode = 0; caText = d }
        else if let f = cluster.certificateAuthority { caMode = 1; caText = f }
        else { caMode = 2; caText = "" }
    }

    private func pickCAFile() {
        let p = NSOpenPanel(); p.showsHiddenFiles = true
        guard p.runModal() == .OK, let u = p.url, let data = try? Data(contentsOf: u) else { return }
        caText = data.base64EncodedString()
    }
}

/// «PEM, 1 сертификат, 1.2 КБ» — чтобы отличать пустышку от настоящего CA, не показывая его.
func certSummary(_ base64: String) -> String {
    guard let data = Data(base64Encoded: base64.components(separatedBy: .whitespacesAndNewlines).joined()) else { return "не base64 (\(base64.count) символов)" }
    let text = String(decoding: data, as: UTF8.self)
    let n = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").count - 1
    let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    return n > 0 ? "PEM, сертификатов: \(n), \(size)" : "\(size), не PEM"
}

// MARK: - Пользователь

struct UserTab: View {
    @EnvironmentObject var store: KubeStore
    let file: ConfigFile
    let user: KUser
    let usedBy: [String]

    @State private var draft: KUser
    @State private var renameTo = ""
    @State private var reveal = false
    @State private var argsText = ""
    @State private var envText = ""
    @State private var apConfigText = ""

    init(file: ConfigFile, user: KUser, usedBy: [String]) {
        self.file = file; self.user = user; self.usedBy = usedBy
        _draft = State(initialValue: user)
    }

    private var composed: KUser {
        var d = draft
        d.execArgs = argsText.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        d.execEnv = envText.split(separator: "\n").compactMap { line in
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard let eq = s.firstIndex(of: "=") else { return s.isEmpty ? nil : (s, "") }
            return (String(s[..<eq]), String(s[s.index(after: eq)...]))
        }
        d.authProviderConfig = apConfigText.split(separator: "\n").compactMap { line in
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard let c = s.firstIndex(of: ":") else { return nil }
            return (String(s[..<c]).trimmingCharacters(in: .whitespaces), String(s[s.index(after: c)...]).trimmingCharacters(in: .whitespaces))
        }
        return d
    }

    private var dirty: Bool {
        var a = YAMLNode.emptyMapping, b = YAMLNode.emptyMapping
        composed.apply(to: &a); user.apply(to: &b)
        return a != b
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Имя", text: $renameTo)
                    if renameTo != user.name && !renameTo.isEmpty {
                        Button("Переименовать") { store.update(file) { try $0.renameUser(user.name, to: renameTo) } }
                    }
                }
                Picker("Аутентификация", selection: $draft.kind) {
                    ForEach(AuthKind.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                switch draft.kind {
                case .token:
                    secret("Токен", $draft.token)
                case .tokenFile:
                    TextField("Путь к файлу с токеном", text: $draft.tokenFile).font(.system(.body, design: .monospaced))
                case .clientCertificate:
                    secret("client-certificate-data (base64)", $draft.clientCertificateData, summary: true)
                    secret("client-key-data (base64)", $draft.clientKeyData, summary: true)
                    TextField("client-certificate (файл)", text: $draft.clientCertificate).font(.system(.caption, design: .monospaced))
                    TextField("client-key (файл)", text: $draft.clientKey).font(.system(.caption, design: .monospaced))
                    Text("Заполните либо *-data, либо пути к файлам.").font(.caption).foregroundStyle(.secondary)
                case .basic:
                    TextField("Логин", text: $draft.username)
                    secret("Пароль", $draft.password)
                case .exec:
                    TextField("apiVersion", text: $draft.execAPIVersion).font(.system(.caption, design: .monospaced))
                    TextField("Команда", text: $draft.execCommand, prompt: Text("aws / gke-gcloud-auth-plugin / kubelogin"))
                    TextField("Аргументы, по одному на строку", text: $argsText, axis: .vertical).lineLimit(3...8).font(.system(.callout, design: .monospaced))
                    TextField("Переменные окружения, KEY=VALUE на строку", text: $envText, axis: .vertical).lineLimit(1...4).font(.system(.callout, design: .monospaced))
                    Picker("interactiveMode", selection: $draft.execInteractive) {
                        Text("не задан").tag(""); Text("Never").tag("Never"); Text("IfAvailable").tag("IfAvailable"); Text("Always").tag("Always")
                    }
                    Toggle("provideClusterInfo", isOn: $draft.execProvideClusterInfo)
                    TextField("installHint", text: $draft.execInstallHint, axis: .vertical).lineLimit(1...3)
                case .authProvider:
                    TextField("name", text: $draft.authProviderName, prompt: Text("oidc / azure / gcp"))
                    TextField("config, key: value на строку", text: $apConfigText, axis: .vertical).lineLimit(3...10).font(.system(.callout, design: .monospaced))
                    Text("Auth provider устарел в client-go; для новых кластеров используйте exec.").font(.caption).foregroundStyle(.secondary)
                case .none:
                    Text("Запросы пойдут анонимно.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Дополнительно") {
                TextField("Impersonate (as)", text: $draft.impersonate)
            }
            Section {
                HStack {
                    Button("Отменить") { reset() }.disabled(!dirty)
                    Button("Сохранить") { store.update(file) { $0.upsertUser(composed) } }.keyboardShortcut("s").buttonStyle(.borderedProminent).disabled(!dirty)
                    Spacer()
                    Toggle("Показывать секреты", isOn: $reveal).toggleStyle(.switch).controlSize(.small)
                }
                Text(usedBy.count == 1 ? "Используется только этим контекстом" : "Используется контекстами: \(usedBy.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reset)
    }

    @ViewBuilder
    private func secret(_ title: String, _ value: Binding<String>, summary: Bool = false) -> some View {
        if reveal {
            TextField(title, text: value, axis: .vertical).lineLimit(1...4).font(.system(.caption, design: .monospaced))
        } else {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(value.wrappedValue.isEmpty ? "не задан" : (summary ? certSummary(value.wrappedValue) : "••••••••  (\(value.wrappedValue.count) символов)"))
                    .font(.caption).foregroundStyle(.secondary)
                if summary {
                    Button("Из файла…") {
                        let p = NSOpenPanel(); p.showsHiddenFiles = true
                        if p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u) { value.wrappedValue = d.base64EncodedString() }
                    }
                }
            }
        }
    }

    private func reset() {
        draft = user
        renameTo = user.name
        argsText = user.execArgs.joined(separator: "\n")
        envText = user.execEnv.map { "\($0.0)=\($0.1)" }.joined(separator: "\n")
        apConfigText = user.authProviderConfig.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }
}

// MARK: - YAML

struct YAMLTab: View {
    @EnvironmentObject var store: KubeStore
    let file: ConfigFile
    let config: Kubeconfig
    let context: KContext

    @State private var wholeFile = false
    @State private var raw = false

    private var text: String {
        var cfg = wholeFile ? config : (config.minified(context: context.name) ?? config)
        if !raw { cfg = cfg.redacted() }
        return cfg.yaml()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $wholeFile) { Text("Этот контекст").tag(false); Text("Весь файл").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Toggle("Секреты", isOn: $raw).toggleStyle(.switch).controlSize(.small)
                    .help("Показывать токены и ключи (kubectl config view --raw)")
                Spacer()
                Button { copy(text) } label: { Label("Скопировать", systemImage: "doc.on.doc") }
                Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Label("В Finder", systemImage: "folder") }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}
