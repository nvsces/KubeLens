import Foundation

/// Объект Kubernetes как есть — JSON от `kubectl get -o json`. Типизировать все виды
/// бессмысленно: колонки таблицы и обзор берут поля по путям вроде `status.phase`.
struct KResource: Identifiable, Hashable {
    let json: [String: Any]
    let kind: String
    let name: String
    let namespace: String?
    let uid: String
    let resourceVersion: String
    let created: Date?

    var id: String { uid }

    init?(json: [String: Any], kind: String) {
        guard let meta = json["metadata"] as? [String: Any], let name = meta["name"] as? String else { return nil }
        self.json = json
        self.kind = (json["kind"] as? String) ?? kind
        self.name = name
        namespace = meta["namespace"] as? String
        uid = (meta["uid"] as? String) ?? "\(meta["namespace"] as? String ?? "")/\(name)"
        resourceVersion = (meta["resourceVersion"] as? String) ?? ""
        created = (meta["creationTimestamp"] as? String).flatMap { KResource.iso.date(from: $0) }
    }

    static func == (l: KResource, r: KResource) -> Bool { l.uid == r.uid && l.resourceVersion == r.resourceVersion }
    func hash(into h: inout Hasher) { h.combine(uid) }

    static let iso = ISO8601DateFormatter()

    /// `a.b.c` по вложенным словарям; индексы массивов — `a.0.b`.
    func get(_ path: String) -> Any? {
        var cur: Any? = json
        for part in path.split(separator: ".") {
            if let d = cur as? [String: Any] { cur = d[String(part)] }
            else if let a = cur as? [Any], let i = Int(part), i < a.count { cur = a[i] }
            else { return nil }
        }
        return cur
    }
    func str(_ path: String) -> String {
        guard let v = get(path) else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            // NSNumber(1) охотно приводится к Bool — различаем настоящие булевы по CF-типу.
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        }
        return ""
    }
    func int(_ path: String) -> Int? { (get(path) as? NSNumber)?.intValue }
    func dict(_ path: String) -> [String: Any] { get(path) as? [String: Any] ?? [:] }
    func list(_ path: String) -> [[String: Any]] { get(path) as? [[String: Any]] ?? [] }

    var labels: [String: String] { (get("metadata.labels") as? [String: String]) ?? [:] }
    var annotations: [String: String] { (get("metadata.annotations") as? [String: String]) ?? [:] }
    var age: String { created.map { ageString(since: $0) } ?? "" }

    /// Условие из `status.conditions` по типу.
    func condition(_ type: String) -> [String: Any]? { list("status.conditions").first { $0["type"] as? String == type } }
}

/// «5d», «3h», «12m», «40s» — как в выводе kubectl.
func ageString(since date: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(date))
    if s < 0 { return "0s" }
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    if s < 86400 * 365 { return "\(s / 86400)d" }
    return "\(s / (86400 * 365))y"
}

struct ResourceColumn: Identifiable {
    let title: String
    let width: CGFloat?
    let value: (KResource) -> String
    var id: String { title }

    init(_ title: String, width: CGFloat? = nil, _ value: @escaping (KResource) -> String) {
        self.title = title; self.width = width; self.value = value
    }
}

/// Вид ресурса: имя для kubectl, раздел в сайдбаре, колонки таблицы.
struct ResourceKind: Identifiable, Hashable {
    let id: String          // имя ресурса для kubectl: pods, deployments.apps …
    let title: String
    let kind: String        // Kind в манифесте
    let group: String
    let namespaced: Bool
    let icon: String
    let columns: [ResourceColumn]

    static func == (l: ResourceKind, r: ResourceKind) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    static func find(_ id: String) -> ResourceKind? { all.first { $0.id == id } }
    static var groups: [String] { var seen: [String] = []; for k in all where !seen.contains(k.group) { seen.append(k.group) }; return seen }

    private static let name = ResourceColumn("Имя", width: 260) { $0.name }
    private static let age = ResourceColumn("Возраст", width: 70) { $0.age }
    private static let ns = ResourceColumn("Namespace", width: 140) { $0.namespace ?? "" }

    static let all: [ResourceKind] = [
        ResourceKind(id: "pods", title: "Pods", kind: "Pod", group: "Нагрузки", namespaced: true, icon: "cube", columns: [
            name, ns,
            ResourceColumn("Ready", width: 60) { r in
                let cs = r.list("status.containerStatuses")
                return "\(cs.filter { $0["ready"] as? Bool == true }.count)/\(r.list("spec.containers").count)"
            },
            ResourceColumn("Статус", width: 140) { podStatus($0) },
            ResourceColumn("Рестарты", width: 70) { r in "\(r.list("status.containerStatuses").reduce(0) { $0 + (($1["restartCount"] as? NSNumber)?.intValue ?? 0) })" },
            ResourceColumn("IP", width: 110) { $0.str("status.podIP") },
            ResourceColumn("Узел", width: 160) { $0.str("spec.nodeName") },
            age,
        ]),
        ResourceKind(id: "deployments.apps", title: "Deployments", kind: "Deployment", group: "Нагрузки", namespaced: true, icon: "square.stack.3d.up", columns: [
            name, ns,
            ResourceColumn("Ready", width: 70) { "\($0.int("status.readyReplicas") ?? 0)/\($0.int("spec.replicas") ?? 0)" },
            ResourceColumn("Up-to-date", width: 80) { $0.str("status.updatedReplicas") },
            ResourceColumn("Available", width: 80) { $0.str("status.availableReplicas") },
            ResourceColumn("Образы", width: 300) { images($0, "spec.template.spec.containers") },
            age,
        ]),
        ResourceKind(id: "statefulsets.apps", title: "StatefulSets", kind: "StatefulSet", group: "Нагрузки", namespaced: true, icon: "square.stack", columns: [
            name, ns,
            ResourceColumn("Ready", width: 70) { "\($0.int("status.readyReplicas") ?? 0)/\($0.int("spec.replicas") ?? 0)" },
            ResourceColumn("Образы", width: 300) { images($0, "spec.template.spec.containers") },
            age,
        ]),
        ResourceKind(id: "daemonsets.apps", title: "DaemonSets", kind: "DaemonSet", group: "Нагрузки", namespaced: true, icon: "square.grid.3x3", columns: [
            name, ns,
            ResourceColumn("Desired", width: 70) { $0.str("status.desiredNumberScheduled") },
            ResourceColumn("Current", width: 70) { $0.str("status.currentNumberScheduled") },
            ResourceColumn("Ready", width: 70) { $0.str("status.numberReady") },
            ResourceColumn("Образы", width: 300) { images($0, "spec.template.spec.containers") },
            age,
        ]),
        ResourceKind(id: "replicasets.apps", title: "ReplicaSets", kind: "ReplicaSet", group: "Нагрузки", namespaced: true, icon: "square.on.square", columns: [
            name, ns,
            ResourceColumn("Desired", width: 70) { $0.str("spec.replicas") },
            ResourceColumn("Current", width: 70) { $0.str("status.replicas") },
            ResourceColumn("Ready", width: 70) { $0.str("status.readyReplicas") },
            age,
        ]),
        ResourceKind(id: "jobs.batch", title: "Jobs", kind: "Job", group: "Нагрузки", namespaced: true, icon: "checkmark.rectangle.stack", columns: [
            name, ns,
            ResourceColumn("Completions", width: 90) { "\($0.int("status.succeeded") ?? 0)/\($0.int("spec.completions") ?? 1)" },
            ResourceColumn("Статус", width: 100) { r in
                if r.condition("Complete")?["status"] as? String == "True" { return "Complete" }
                if r.condition("Failed")?["status"] as? String == "True" { return "Failed" }
                return (r.int("status.active") ?? 0) > 0 ? "Running" : "Pending"
            },
            age,
        ]),
        ResourceKind(id: "cronjobs.batch", title: "CronJobs", kind: "CronJob", group: "Нагрузки", namespaced: true, icon: "clock.arrow.2.circlepath", columns: [
            name, ns,
            ResourceColumn("Расписание", width: 120) { $0.str("spec.schedule") },
            ResourceColumn("Suspend", width: 70) { $0.str("spec.suspend").isEmpty ? "false" : $0.str("spec.suspend") },
            ResourceColumn("Active", width: 60) { "\($0.list("status.active").count)" },
            ResourceColumn("Last schedule", width: 100) { r in (r.get("status.lastScheduleTime") as? String).flatMap(KResource.iso.date).map { ageString(since: $0) } ?? "" },
            age,
        ]),
        ResourceKind(id: "horizontalpodautoscalers.autoscaling", title: "HPA", kind: "HorizontalPodAutoscaler", group: "Нагрузки", namespaced: true, icon: "arrow.up.and.down", columns: [
            name, ns,
            ResourceColumn("Цель", width: 200) { "\($0.str("spec.scaleTargetRef.kind"))/\($0.str("spec.scaleTargetRef.name"))" },
            ResourceColumn("Min", width: 50) { $0.str("spec.minReplicas") },
            ResourceColumn("Max", width: 50) { $0.str("spec.maxReplicas") },
            ResourceColumn("Реплик", width: 60) { $0.str("status.currentReplicas") },
            age,
        ]),

        ResourceKind(id: "services", title: "Services", kind: "Service", group: "Сеть", namespaced: true, icon: "network", columns: [
            name, ns,
            ResourceColumn("Тип", width: 100) { $0.str("spec.type") },
            ResourceColumn("Cluster IP", width: 120) { $0.str("spec.clusterIP") },
            ResourceColumn("External IP", width: 140) { r in
                let ing = r.list("status.loadBalancer.ingress").compactMap { ($0["ip"] ?? $0["hostname"]) as? String }
                let ext = (r.get("spec.externalIPs") as? [String]) ?? []
                return (ing + ext).joined(separator: ", ")
            },
            ResourceColumn("Порты", width: 200) { r in
                r.list("spec.ports").map { p in
                    var s = "\((p["port"] as? NSNumber)?.stringValue ?? "")"
                    if let np = p["nodePort"] as? NSNumber { s += ":\(np)" }
                    return s + "/\(p["protocol"] as? String ?? "TCP")"
                }.joined(separator: ", ")
            },
            age,
        ]),
        ResourceKind(id: "ingresses.networking.k8s.io", title: "Ingresses", kind: "Ingress", group: "Сеть", namespaced: true, icon: "arrow.triangle.branch", columns: [
            name, ns,
            ResourceColumn("Класс", width: 100) { r in r.str("spec.ingressClassName").isEmpty ? (r.annotations["kubernetes.io/ingress.class"] ?? "") : r.str("spec.ingressClassName") },
            ResourceColumn("Хосты", width: 260) { r in r.list("spec.rules").compactMap { $0["host"] as? String }.joined(separator: ", ") },
            ResourceColumn("Адрес", width: 140) { r in r.list("status.loadBalancer.ingress").compactMap { ($0["ip"] ?? $0["hostname"]) as? String }.joined(separator: ", ") },
            ResourceColumn("TLS", width: 50) { $0.list("spec.tls").isEmpty ? "" : "да" },
            age,
        ]),
        ResourceKind(id: "endpoints", title: "Endpoints", kind: "Endpoints", group: "Сеть", namespaced: true, icon: "point.3.connected.trianglepath.dotted", columns: [
            name, ns,
            ResourceColumn("Адреса", width: 400) { r in
                r.list("subsets").flatMap { s in
                    let addrs = (s["addresses"] as? [[String: Any]] ?? []).compactMap { $0["ip"] as? String }
                    let ports = (s["ports"] as? [[String: Any]] ?? []).compactMap { ($0["port"] as? NSNumber)?.stringValue }
                    return addrs.flatMap { a in ports.isEmpty ? [a] : ports.map { "\(a):\($0)" } }
                }.joined(separator: ", ")
            },
            age,
        ]),
        ResourceKind(id: "networkpolicies.networking.k8s.io", title: "NetworkPolicies", kind: "NetworkPolicy", group: "Сеть", namespaced: true, icon: "shield.lefthalf.filled", columns: [
            name, ns,
            ResourceColumn("Селектор", width: 300) { r in (r.get("spec.podSelector.matchLabels") as? [String: String])?.map { "\($0)=\($1)" }.sorted().joined(separator: ",") ?? "" },
            age,
        ]),

        ResourceKind(id: "configmaps", title: "ConfigMaps", kind: "ConfigMap", group: "Конфигурация", namespaced: true, icon: "doc.text", columns: [
            name, ns,
            ResourceColumn("Ключей", width: 60) { "\($0.dict("data").count + $0.dict("binaryData").count)" },
            ResourceColumn("Ключи", width: 300) { $0.dict("data").keys.sorted().joined(separator: ", ") },
            age,
        ]),
        ResourceKind(id: "secrets", title: "Secrets", kind: "Secret", group: "Конфигурация", namespaced: true, icon: "key", columns: [
            name, ns,
            ResourceColumn("Тип", width: 200) { $0.str("type") },
            ResourceColumn("Ключей", width: 60) { "\($0.dict("data").count)" },
            ResourceColumn("Ключи", width: 260) { $0.dict("data").keys.sorted().joined(separator: ", ") },
            age,
        ]),
        ResourceKind(id: "serviceaccounts", title: "ServiceAccounts", kind: "ServiceAccount", group: "Конфигурация", namespaced: true, icon: "person.badge.key", columns: [
            name, ns,
            ResourceColumn("Secrets", width: 60) { "\(($0.get("secrets") as? [Any])?.count ?? 0)" },
            age,
        ]),
        ResourceKind(id: "resourcequotas", title: "ResourceQuotas", kind: "ResourceQuota", group: "Конфигурация", namespaced: true, icon: "gauge.with.dots.needle.33percent", columns: [name, ns, age]),
        ResourceKind(id: "limitranges", title: "LimitRanges", kind: "LimitRange", group: "Конфигурация", namespaced: true, icon: "ruler", columns: [name, ns, age]),

        ResourceKind(id: "persistentvolumeclaims", title: "PersistentVolumeClaims", kind: "PersistentVolumeClaim", group: "Хранилище", namespaced: true, icon: "externaldrive", columns: [
            name, ns,
            ResourceColumn("Статус", width: 80) { $0.str("status.phase") },
            ResourceColumn("Volume", width: 240) { $0.str("spec.volumeName") },
            ResourceColumn("Размер", width: 70) { $0.str("status.capacity.storage") },
            ResourceColumn("Access", width: 80) { r in ((r.get("spec.accessModes") as? [String]) ?? []).map(accessModeShort).joined(separator: ",") },
            ResourceColumn("StorageClass", width: 120) { $0.str("spec.storageClassName") },
            age,
        ]),
        ResourceKind(id: "persistentvolumes", title: "PersistentVolumes", kind: "PersistentVolume", group: "Хранилище", namespaced: false, icon: "internaldrive", columns: [
            name,
            ResourceColumn("Размер", width: 70) { $0.str("spec.capacity.storage") },
            ResourceColumn("Access", width: 80) { r in ((r.get("spec.accessModes") as? [String]) ?? []).map(accessModeShort).joined(separator: ",") },
            ResourceColumn("Reclaim", width: 80) { $0.str("spec.persistentVolumeReclaimPolicy") },
            ResourceColumn("Статус", width: 80) { $0.str("status.phase") },
            ResourceColumn("Claim", width: 220) { r in r.str("spec.claimRef.name").isEmpty ? "" : "\(r.str("spec.claimRef.namespace"))/\(r.str("spec.claimRef.name"))" },
            ResourceColumn("StorageClass", width: 120) { $0.str("spec.storageClassName") },
            age,
        ]),
        ResourceKind(id: "storageclasses.storage.k8s.io", title: "StorageClasses", kind: "StorageClass", group: "Хранилище", namespaced: false, icon: "tray.full", columns: [
            name,
            ResourceColumn("Provisioner", width: 260) { $0.str("provisioner") },
            ResourceColumn("Reclaim", width: 80) { $0.str("reclaimPolicy") },
            ResourceColumn("Binding", width: 160) { $0.str("volumeBindingMode") },
            ResourceColumn("По умолчанию", width: 90) { $0.annotations["storageclass.kubernetes.io/is-default-class"] == "true" ? "да" : "" },
            age,
        ]),

        ResourceKind(id: "roles.rbac.authorization.k8s.io", title: "Roles", kind: "Role", group: "Доступ", namespaced: true, icon: "person.text.rectangle", columns: [name, ns, age]),
        ResourceKind(id: "rolebindings.rbac.authorization.k8s.io", title: "RoleBindings", kind: "RoleBinding", group: "Доступ", namespaced: true, icon: "link", columns: [
            name, ns,
            ResourceColumn("Роль", width: 200) { "\($0.str("roleRef.kind"))/\($0.str("roleRef.name"))" },
            ResourceColumn("Субъекты", width: 300) { r in r.list("subjects").map { "\($0["kind"] as? String ?? "")/\($0["name"] as? String ?? "")" }.joined(separator: ", ") },
            age,
        ]),
        ResourceKind(id: "clusterroles.rbac.authorization.k8s.io", title: "ClusterRoles", kind: "ClusterRole", group: "Доступ", namespaced: false, icon: "person.text.rectangle.fill", columns: [name, age]),
        ResourceKind(id: "clusterrolebindings.rbac.authorization.k8s.io", title: "ClusterRoleBindings", kind: "ClusterRoleBinding", group: "Доступ", namespaced: false, icon: "link.circle", columns: [
            name,
            ResourceColumn("Роль", width: 200) { $0.str("roleRef.name") },
            ResourceColumn("Субъекты", width: 300) { r in r.list("subjects").map { "\($0["kind"] as? String ?? "")/\($0["name"] as? String ?? "")" }.joined(separator: ", ") },
            age,
        ]),

        ResourceKind(id: "nodes", title: "Nodes", kind: "Node", group: "Кластер", namespaced: false, icon: "server.rack", columns: [
            name,
            ResourceColumn("Статус", width: 130) { r in
                let ready = r.condition("Ready")?["status"] as? String == "True" ? "Ready" : "NotReady"
                return r.get("spec.unschedulable") as? Bool == true ? ready + ",SchedulingDisabled" : ready
            },
            ResourceColumn("Роли", width: 140) { r in
                let roles = r.labels.keys.filter { $0.hasPrefix("node-role.kubernetes.io/") }.map { String($0.dropFirst("node-role.kubernetes.io/".count)) }.sorted()
                return roles.isEmpty ? "<none>" : roles.joined(separator: ",")
            },
            ResourceColumn("Версия", width: 100) { $0.str("status.nodeInfo.kubeletVersion") },
            ResourceColumn("Internal IP", width: 120) { r in r.list("status.addresses").first { $0["type"] as? String == "InternalIP" }?["address"] as? String ?? "" },
            ResourceColumn("ОС", width: 200) { $0.str("status.nodeInfo.osImage") },
            age,
        ]),
        ResourceKind(id: "namespaces", title: "Namespaces", kind: "Namespace", group: "Кластер", namespaced: false, icon: "square.grid.2x2", columns: [
            name,
            ResourceColumn("Статус", width: 100) { $0.str("status.phase") },
            age,
        ]),
        ResourceKind(id: "events", title: "Events", kind: "Event", group: "Кластер", namespaced: true, icon: "bell", columns: [
            ResourceColumn("Когда", width: 70) { r in eventTime(r).map { ageString(since: $0) } ?? "" },
            ns,
            ResourceColumn("Тип", width: 70) { $0.str("type") },
            ResourceColumn("Причина", width: 140) { $0.str("reason") },
            ResourceColumn("Объект", width: 240) { "\($0.str("involvedObject.kind").lowercased())/\($0.str("involvedObject.name"))" },
            ResourceColumn("Сообщение", width: 500) { $0.str("message") },
        ]),
        ResourceKind(id: "customresourcedefinitions.apiextensions.k8s.io", title: "CRDs", kind: "CustomResourceDefinition", group: "Кластер", namespaced: false, icon: "puzzlepiece.extension", columns: [
            name,
            ResourceColumn("Группа", width: 200) { $0.str("spec.group") },
            ResourceColumn("Kind", width: 160) { $0.str("spec.names.kind") },
            ResourceColumn("Scope", width: 90) { $0.str("spec.scope") },
            age,
        ]),
    ]

    /// Статус пода как у `kubectl get pods`: причина ожидания/завершения контейнера важнее фазы.
    static func podStatus(_ r: KResource) -> String {
        if let del = r.get("metadata.deletionTimestamp") as? String, !del.isEmpty { return "Terminating" }
        if let reason = r.get("status.reason") as? String, !reason.isEmpty { return reason }
        for c in r.list("status.initContainerStatuses") {
            if let w = (c["state"] as? [String: Any])?["waiting"] as? [String: Any], let reason = w["reason"] as? String { return "Init:" + reason }
            if let t = (c["state"] as? [String: Any])?["terminated"] as? [String: Any], (t["exitCode"] as? NSNumber)?.intValue != 0 {
                return "Init:" + ((t["reason"] as? String) ?? "Error")
            }
        }
        for c in r.list("status.containerStatuses") {
            if let w = (c["state"] as? [String: Any])?["waiting"] as? [String: Any], let reason = w["reason"] as? String { return reason }
            if let t = (c["state"] as? [String: Any])?["terminated"] as? [String: Any], let reason = t["reason"] as? String, r.str("status.phase") != "Succeeded" { return reason }
        }
        return r.str("status.phase")
    }

    static func images(_ r: KResource, _ path: String) -> String {
        r.list(path).compactMap { $0["image"] as? String }.joined(separator: ", ")
    }

    static func eventTime(_ r: KResource) -> Date? {
        for k in ["lastTimestamp", "eventTime", "series.lastObservedTime", "firstTimestamp", "metadata.creationTimestamp"] {
            if let s = r.get(k) as? String, let d = KResource.iso.date(from: s) ?? isoFrac.date(from: s) { return d }
        }
        return nil
    }
    private static let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
}

func accessModeShort(_ m: String) -> String {
    switch m {
    case "ReadWriteOnce": return "RWO"
    case "ReadOnlyMany": return "ROX"
    case "ReadWriteMany": return "RWX"
    case "ReadWriteOncePod": return "RWOP"
    default: return m
    }
}

// MARK: - JSON ↔ YAML

/// Объекты от API приходят JSON-ом; показываем YAML своим эмиттером, а правки пользователя
/// разбираем своим парсером и отдаём kubectl уже JSON-ом — сервер-сайд YAML нам читать не надо.
enum JSONYAML {
    static func node(from any: Any?) -> YAMLNode {
        guard let any, !(any is NSNull) else { return .null }
        if let d = any as? [String: Any] {
            // Порядок ключей как у kubectl: apiVersion, kind, metadata, spec, status, остальное по алфавиту.
            let order = ["apiVersion", "kind", "metadata", "spec", "data", "stringData", "binaryData", "status"]
            let keys = d.keys.sorted { a, b in
                let ia = order.firstIndex(of: a) ?? order.count, ib = order.firstIndex(of: b) ?? order.count
                return ia != ib ? ia < ib : a < b
            }
            return .mapping(keys.map { YAMLPair(key: $0, value: node(from: d[$0])) })
        }
        if let a = any as? [Any] { return .sequence(a.map { node(from: $0) }) }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .scalar(n.stringValue, quoted: false)
        }
        if let s = any as? String { return .string(s) }
        return .string(String(describing: any))
    }

    static func json(from node: YAMLNode) -> Any {
        switch node {
        case .null: return NSNull()
        case .mapping(let pairs):
            var d: [String: Any] = [:]
            for p in pairs { d[p.key] = json(from: p.value) }
            return d
        case .sequence(let items): return items.map { json(from: $0) }
        case .scalar(let s, let quoted):
            if quoted { return s }
            switch s.lowercased() {
            case "true", "yes", "on": return true
            case "false", "no", "off": return false
            case "null", "~": return NSNull()
            default: break
            }
            if let i = Int(s) { return i }
            if let d = Double(s), s.rangeOfCharacter(from: CharacterSet(charactersIn: ".eE")) != nil { return d }
            return s
        }
    }

    static func yaml(from json: [String: Any], stripManagedFields: Bool = true) -> String {
        var j = json
        if stripManagedFields, var meta = j["metadata"] as? [String: Any] {
            meta["managedFields"] = nil
            j["metadata"] = meta
        }
        return YAML.emit(node(from: j))
    }
}
