import Foundation

/// Типизированные представления записей kubeconfig. Все операции идут через YAML-дерево,
/// поэтому поля, о которых редактор не знает (extensions, as-groups, …), не теряются.
struct KContext: Identifiable, Hashable {
    var name: String
    var cluster: String
    var user: String
    var namespace: String?
    var id: String { name }
}

struct KCluster: Identifiable, Hashable {
    var name: String
    var server: String = ""
    var certificateAuthorityData: String?
    var certificateAuthority: String?
    var insecureSkipTLSVerify = false
    var proxyURL: String?
    var tlsServerName: String?
    var disableCompression = false
    var id: String { name }

    init(name: String) { self.name = name }

    init(name: String, body: YAMLNode) {
        self.name = name
        server = body.str("server") ?? ""
        certificateAuthorityData = body.str("certificate-authority-data")
        certificateAuthority = body.str("certificate-authority")
        insecureSkipTLSVerify = body["insecure-skip-tls-verify"]?.bool ?? false
        proxyURL = body.str("proxy-url")
        tlsServerName = body.str("tls-server-name")
        disableCompression = body["disable-compression"]?.bool ?? false
    }

    func apply(to body: inout YAMLNode) {
        if body.pairs == nil { body = .emptyMapping }
        body.setStr("server", server)
        body.setStr("certificate-authority-data", certificateAuthorityData)
        body.setStr("certificate-authority", certificateAuthority)
        body.setBool("insecure-skip-tls-verify", insecureSkipTLSVerify)
        body.setStr("proxy-url", proxyURL)
        body.setStr("tls-server-name", tlsServerName)
        body.setBool("disable-compression", disableCompression)
    }
}

/// Способ аутентификации пользователя — ровно те варианты, которые понимает client-go.
enum AuthKind: String, CaseIterable, Identifiable {
    case token, tokenFile, clientCertificate, basic, exec, authProvider, none
    var id: String { rawValue }

    var title: String {
        switch self {
        case .token: return "Токен"
        case .tokenFile: return "Файл с токеном"
        case .clientCertificate: return "Клиентский сертификат"
        case .basic: return "Логин и пароль"
        case .exec: return "Внешняя команда (exec)"
        case .authProvider: return "Auth provider"
        case .none: return "Без аутентификации"
        }
    }
}

struct KUser: Identifiable, Hashable {
    var name: String
    var kind: AuthKind = .none
    var token = ""
    var tokenFile = ""
    var clientCertificateData = ""
    var clientCertificate = ""
    var clientKeyData = ""
    var clientKey = ""
    var username = ""
    var password = ""
    var execAPIVersion = "client.authentication.k8s.io/v1beta1"
    var execCommand = ""
    var execArgs: [String] = []
    var execEnv: [(String, String)] = []
    var execInteractive = ""
    var execProvideClusterInfo = false
    var execInstallHint = ""
    var authProviderName = ""
    var authProviderConfig: [(String, String)] = []
    var impersonate = ""
    var id: String { name }

    static func == (l: KUser, r: KUser) -> Bool { l.name == r.name && l.kind == r.kind && l.summary == r.summary }
    func hash(into h: inout Hasher) { h.combine(name) }

    init(name: String) { self.name = name }

    init(name: String, body: YAMLNode) {
        self.name = name
        token = body.str("token") ?? ""
        tokenFile = body.str("tokenFile") ?? ""
        clientCertificateData = body.str("client-certificate-data") ?? ""
        clientCertificate = body.str("client-certificate") ?? ""
        clientKeyData = body.str("client-key-data") ?? ""
        clientKey = body.str("client-key") ?? ""
        username = body.str("username") ?? ""
        password = body.str("password") ?? ""
        impersonate = body.str("as") ?? ""
        if let exec = body["exec"], exec.pairs != nil {
            kind = .exec
            execAPIVersion = exec.str("apiVersion") ?? execAPIVersion
            execCommand = exec.str("command") ?? ""
            execArgs = exec["args"]?.items?.compactMap(\.string) ?? []
            execEnv = exec["env"]?.items?.compactMap { e in e.str("name").map { ($0, e.str("value") ?? "") } } ?? []
            execInteractive = exec.str("interactiveMode") ?? ""
            execProvideClusterInfo = exec["provideClusterInfo"]?.bool ?? false
            execInstallHint = exec.str("installHint") ?? ""
        } else if let ap = body["auth-provider"], ap.pairs != nil {
            kind = .authProvider
            authProviderName = ap.str("name") ?? ""
            authProviderConfig = ap["config"]?.pairs?.map { ($0.key, $0.value.string ?? "") } ?? []
        } else if !token.isEmpty { kind = .token }
        else if !tokenFile.isEmpty { kind = .tokenFile }
        else if !clientCertificateData.isEmpty || !clientCertificate.isEmpty || !clientKeyData.isEmpty || !clientKey.isEmpty { kind = .clientCertificate }
        else if !username.isEmpty || !password.isEmpty { kind = .basic }
        else { kind = .none }
    }

    /// Короткое описание для списка: «токен», «сертификат», «exec: aws»…
    var summary: String {
        switch kind {
        case .token: return "токен"
        case .tokenFile: return "токен из файла"
        case .clientCertificate: return clientCertificate.isEmpty ? "сертификат" : "сертификат (файл)"
        case .basic: return "basic: \(username)"
        case .exec: return "exec: \(execCommand)"
        case .authProvider: return "provider: \(authProviderName)"
        case .none: return "без auth"
        }
    }

    /// Записывает поля выбранного способа и убирает поля остальных — как явный редактор,
    /// а не `set-credentials`, который молча смешивает несколько способов сразу.
    func apply(to body: inout YAMLNode) {
        if body.pairs == nil { body = .emptyMapping }
        let authKeys = ["token", "tokenFile", "client-certificate-data", "client-certificate", "client-key-data",
                        "client-key", "username", "password", "exec", "auth-provider"]
        for k in authKeys { body[k] = nil }
        switch kind {
        case .token: body.setStr("token", token)
        case .tokenFile: body.setStr("tokenFile", tokenFile)
        case .clientCertificate:
            body.setStr("client-certificate-data", clientCertificateData)
            body.setStr("client-certificate", clientCertificate)
            body.setStr("client-key-data", clientKeyData)
            body.setStr("client-key", clientKey)
        case .basic:
            body.setStr("username", username)
            body.setStr("password", password)
        case .exec:
            var exec = YAMLNode.emptyMapping
            exec.setStr("apiVersion", execAPIVersion)
            exec.setStr("command", execCommand)
            exec["args"] = .sequence(execArgs.map { .string($0) })
            if !execEnv.isEmpty {
                exec["env"] = .sequence(execEnv.map { .mapping([YAMLPair(key: "name", value: .string($0.0)), YAMLPair(key: "value", value: .string($0.1))]) })
            } else {
                exec["env"] = .null
            }
            exec.setStr("interactiveMode", execInteractive)
            exec.setBool("provideClusterInfo", execProvideClusterInfo)
            exec.setStr("installHint", execInstallHint)
            body["exec"] = exec
        case .authProvider:
            var ap = YAMLNode.emptyMapping
            ap.setStr("name", authProviderName)
            ap["config"] = .mapping(authProviderConfig.map { YAMLPair(key: $0.0, value: .string($0.1)) })
            body["auth-provider"] = ap
        case .none: break
        }
        body.setStr("as", impersonate)
    }
}

enum KubeconfigError: LocalizedError {
    case notMapping
    case exists(String)
    case missing(String)
    case fileRead(String)

    var errorDescription: String? {
        switch self {
        case .notMapping: return "Файл не похож на kubeconfig: на верхнем уровне ожидалась мапа"
        case .exists(let n): return "«\(n)» уже существует"
        case .missing(let n): return "«\(n)» не найден"
        case .fileRead(let p): return "Не удалось прочитать \(p)"
        }
    }
}

/// Один kubeconfig-файл. Значение-тип: правки делаются на копии, а сохранение — отдельный шаг,
/// поэтому «Отмена» в редакторе ничего не стоит.
struct Kubeconfig: Equatable {
    var root: YAMLNode

    init() {
        root = .mapping([
            YAMLPair(key: "apiVersion", value: .string("v1")),
            YAMLPair(key: "kind", value: .string("Config")),
            YAMLPair(key: "preferences", value: .emptyMapping),
            YAMLPair(key: "clusters", value: .sequence([])),
            YAMLPair(key: "contexts", value: .sequence([])),
            YAMLPair(key: "users", value: .sequence([])),
            YAMLPair(key: "current-context", value: .scalar("", quoted: true)),
        ])
    }

    init(yaml: String) throws {
        let node = try YAML.parse(yaml)
        if node.isNull { root = Kubeconfig().root; return }
        guard node.pairs != nil else { throw KubeconfigError.notMapping }
        root = node
    }

    func yaml() -> String { YAML.emit(root) }

    // MARK: Списки

    private func entries(_ list: String, body: String) -> [(name: String, body: YAMLNode)] {
        (root[list]?.items ?? []).compactMap { e in
            guard let n = e.str("name") else { return nil }
            return (n, e[body] ?? .emptyMapping)
        }
    }

    var contexts: [KContext] {
        entries("contexts", body: "context").map {
            KContext(name: $0.name, cluster: $0.body.str("cluster") ?? "", user: $0.body.str("user") ?? "", namespace: $0.body.str("namespace"))
        }
    }
    var clusters: [KCluster] { entries("clusters", body: "cluster").map { KCluster(name: $0.name, body: $0.body) } }
    var users: [KUser] { entries("users", body: "user").map { KUser(name: $0.name, body: $0.body) } }

    func context(_ name: String) -> KContext? { contexts.first { $0.name == name } }
    func cluster(_ name: String) -> KCluster? { clusters.first { $0.name == name } }
    func user(_ name: String) -> KUser? { users.first { $0.name == name } }

    var currentContext: String? {
        get { let s = root.str("current-context"); return (s?.isEmpty ?? true) ? nil : s }
        set { root["current-context"] = .scalar(newValue ?? "", quoted: newValue?.isEmpty ?? true) }
    }

    // MARK: Низкоуровневые правки списков

    private mutating func upsert(list: String, bodyKey: String, name: String, mutate: (inout YAMLNode) -> Void) {
        var items = root[list]?.items ?? []
        if let i = items.firstIndex(where: { $0.str("name") == name }) {
            var body = items[i][bodyKey] ?? .emptyMapping
            mutate(&body)
            items[i][bodyKey] = body
        } else {
            var body = YAMLNode.emptyMapping
            mutate(&body)
            // Порядок как у kubectl: сначала тело, потом name.
            items.append(.mapping([YAMLPair(key: bodyKey, value: body), YAMLPair(key: "name", value: .string(name))]))
        }
        root[list] = .sequence(items)
    }

    private mutating func remove(list: String, name: String) {
        root[list] = .sequence((root[list]?.items ?? []).filter { $0.str("name") != name })
    }

    private mutating func rename(list: String, from: String, to: String) throws {
        var items = root[list]?.items ?? []
        guard let i = items.firstIndex(where: { $0.str("name") == from }) else { throw KubeconfigError.missing(from) }
        if from != to, items.contains(where: { $0.str("name") == to }) { throw KubeconfigError.exists(to) }
        items[i]["name"] = .string(to)
        root[list] = .sequence(items)
    }

    // MARK: Контексты

    mutating func upsertContext(_ c: KContext) {
        upsert(list: "contexts", bodyKey: "context", name: c.name) { body in
            body.setStr("cluster", c.cluster)
            body.setStr("user", c.user)
            body.setStr("namespace", c.namespace)
        }
    }

    mutating func setNamespace(_ ns: String?, context name: String) {
        upsert(list: "contexts", bodyKey: "context", name: name) { $0.setStr("namespace", ns) }
    }

    mutating func renameContext(_ from: String, to: String) throws {
        try rename(list: "contexts", from: from, to: to)
        if currentContext == from { currentContext = to }
    }

    mutating func deleteContext(_ name: String) {
        remove(list: "contexts", name: name)
        if currentContext == name { currentContext = nil }
    }

    /// Копия контекста с уникальным именем — общие cluster/user не дублируются.
    mutating func duplicateContext(_ name: String) -> String? {
        guard var c = context(name) else { return nil }
        c.name = uniqueName(c.name, taken: Set(contexts.map(\.name)))
        upsertContext(c)
        return c.name
    }

    // MARK: Кластеры и пользователи

    mutating func upsertCluster(_ c: KCluster) {
        upsert(list: "clusters", bodyKey: "cluster", name: c.name) { c.apply(to: &$0) }
    }
    mutating func renameCluster(_ from: String, to: String) throws {
        try rename(list: "clusters", from: from, to: to)
        for ctx in contexts where ctx.cluster == from { var c = ctx; c.cluster = to; upsertContext(c) }
    }
    mutating func deleteCluster(_ name: String) { remove(list: "clusters", name: name) }

    mutating func upsertUser(_ u: KUser) {
        upsert(list: "users", bodyKey: "user", name: u.name) { u.apply(to: &$0) }
    }
    mutating func renameUser(_ from: String, to: String) throws {
        try rename(list: "users", from: from, to: to)
        for ctx in contexts where ctx.user == from { var c = ctx; c.user = to; upsertContext(c) }
    }
    mutating func deleteUser(_ name: String) { remove(list: "users", name: name) }

    func contexts(usingCluster name: String) -> [String] { contexts.filter { $0.cluster == name }.map(\.name) }
    func contexts(usingUser name: String) -> [String] { contexts.filter { $0.user == name }.map(\.name) }
    var orphanClusters: [String] { clusters.map(\.name).filter { contexts(usingCluster: $0).isEmpty } }
    var orphanUsers: [String] { users.map(\.name).filter { contexts(usingUser: $0).isEmpty } }

    /// Предупреждения о несогласованности — то, на что kubectl ругается уже при вызове.
    var problems: [String] {
        var out: [String] = []
        let cl = Set(clusters.map(\.name)), us = Set(users.map(\.name))
        for c in contexts {
            if !cl.contains(c.cluster) { out.append("Контекст «\(c.name)» ссылается на несуществующий кластер «\(c.cluster)»") }
            if !us.contains(c.user) { out.append("Контекст «\(c.name)» ссылается на несуществующего пользователя «\(c.user)»") }
        }
        if let cur = currentContext, context(cur) == nil { out.append("current-context «\(cur)» не найден в этом файле") }
        return out
    }

    // MARK: Операции над файлами целиком

    /// Аналог `kubectl config view --minify`: один контекст с его кластером и пользователем.
    func minified(context name: String) -> Kubeconfig? {
        guard let ctx = context(name) else { return nil }
        var out = Kubeconfig()
        if let p = root["preferences"] { out.root["preferences"] = p }
        out.root["contexts"] = .sequence((root["contexts"]?.items ?? []).filter { $0.str("name") == name })
        out.root["clusters"] = .sequence((root["clusters"]?.items ?? []).filter { $0.str("name") == ctx.cluster })
        out.root["users"] = .sequence((root["users"]?.items ?? []).filter { $0.str("name") == ctx.user })
        out.currentContext = name
        return out
    }

    /// Аналог `--flatten`: файлы сертификатов/ключей встраиваются как base64 `*-data`,
    /// чтобы файл можно было отдать на другую машину. Пути считаются от каталога kubeconfig.
    func flattened(baseDirectory: URL) throws -> Kubeconfig {
        var out = self
        func embed(_ list: String, _ bodyKey: String, _ fileKey: String, _ dataKey: String) throws {
            var items = out.root[list]?.items ?? []
            for i in items.indices {
                guard var body = items[i][bodyKey], let path = body.str(fileKey), !path.isEmpty else { continue }
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : baseDirectory.appendingPathComponent(path)
                guard let data = try? Data(contentsOf: url) else { throw KubeconfigError.fileRead(path) }
                body[dataKey] = .string(data.base64EncodedString())
                body[fileKey] = nil
                items[i][bodyKey] = body
            }
            out.root[list] = .sequence(items)
        }
        try embed("clusters", "cluster", "certificate-authority", "certificate-authority-data")
        try embed("users", "user", "client-certificate", "client-certificate-data")
        try embed("users", "user", "client-key", "client-key-data")
        return out
    }

    enum MergeConflict { case keepExisting, replace, rename }
    struct MergeReport { var added = 0, replaced = 0, renamed = 0, skipped = 0 }

    /// Импорт другого файла. При совпадении имён — по правилу `conflict`; при переименовании
    /// ссылки контекстов на кластер/пользователя обновляются, чтобы импорт не развалился.
    mutating func merge(_ other: Kubeconfig, conflict: MergeConflict) -> MergeReport {
        var report = MergeReport()
        var clusterMap: [String: String] = [:], userMap: [String: String] = [:]

        func mergeList(_ list: String, _ bodyKey: String, from source: Kubeconfig, existing: Set<String>, map: inout [String: String], same: (String, YAMLNode) -> Bool) {
            var items = root[list]?.items ?? []
            var taken = existing
            for item in source.root[list]?.items ?? [] {
                guard let name = item.str("name") else { continue }
                if !taken.contains(name) {
                    items.append(item); taken.insert(name); report.added += 1; continue
                }
                if same(name, item) { report.skipped += 1; continue }
                switch conflict {
                case .keepExisting: report.skipped += 1
                case .replace:
                    if let i = items.firstIndex(where: { $0.str("name") == name }) { items[i] = item }
                    report.replaced += 1
                case .rename:
                    let newName = uniqueName(name, taken: taken)
                    var renamed = item
                    renamed["name"] = .string(newName)
                    items.append(renamed); taken.insert(newName)
                    map[name] = newName
                    report.renamed += 1
                }
            }
            root[list] = .sequence(items)
        }

        let myClusters = root["clusters"]?.items ?? [], myUsers = root["users"]?.items ?? [], myContexts = root["contexts"]?.items ?? []
        mergeList("clusters", "cluster", from: other, existing: Set(clusters.map(\.name)), map: &clusterMap) { n, item in
            myClusters.first { $0.str("name") == n }?["cluster"] == item["cluster"]
        }
        mergeList("users", "user", from: other, existing: Set(users.map(\.name)), map: &userMap) { n, item in
            myUsers.first { $0.str("name") == n }?["user"] == item["user"]
        }

        // Контексты импортируем с учётом переименованных кластеров/пользователей.
        var incoming = other
        if !clusterMap.isEmpty || !userMap.isEmpty {
            for ctx in incoming.contexts {
                var c = ctx
                c.cluster = clusterMap[c.cluster] ?? c.cluster
                c.user = userMap[c.user] ?? c.user
                incoming.upsertContext(c)
            }
        }
        var unused: [String: String] = [:]
        mergeList("contexts", "context", from: incoming, existing: Set(contexts.map(\.name)), map: &unused) { n, item in
            myContexts.first { $0.str("name") == n }?["context"] == item["context"]
        }
        if currentContext == nil, let cur = other.currentContext, context(cur) != nil { currentContext = cur }
        return report
    }

    /// Копия с замаскированными секретами — для вкладки YAML и буфера обмена.
    func redacted() -> Kubeconfig {
        var out = self
        func mask(_ list: String, _ bodyKey: String, _ rules: [(String, String)]) {
            var items = out.root[list]?.items ?? []
            for i in items.indices {
                guard var body = items[i][bodyKey] else { continue }
                for (k, r) in rules where body[k] != nil { body[k] = .string(r) }
                if var ap = body["auth-provider"], var cfg = ap["config"], let pairs = cfg.pairs {
                    for p in pairs where ["access-token", "refresh-token", "id-token", "client-secret"].contains(p.key) { cfg[p.key] = .string("REDACTED") }
                    ap["config"] = cfg; body["auth-provider"] = ap
                }
                items[i][bodyKey] = body
            }
            out.root[list] = .sequence(items)
        }
        mask("clusters", "cluster", [("certificate-authority-data", "DATA+OMITTED")])
        mask("users", "user", [("client-certificate-data", "DATA+OMITTED"), ("client-key-data", "DATA+OMITTED"),
                               ("token", "REDACTED"), ("password", "REDACTED")])
        return out
    }
}

/// `name`, `name-2`, `name-3`… — первое свободное.
func uniqueName(_ base: String, taken: Set<String>) -> String {
    if !taken.contains(base) { return base }
    var n = 2
    while taken.contains("\(base)-\(n)") { n += 1 }
    return "\(base)-\(n)"
}
