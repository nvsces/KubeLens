import SwiftUI
import AppKit

/// Страница объекта: держит актуальную копию (из списка или отдельным `get`), пока открыта.
struct ResourcePage: View {
    @EnvironmentObject var store: ClusterStore
    let initial: KResource
    var onOpen: (KResource) -> Void
    @State private var current: KResource?
    @State private var gone = false

    var body: some View {
        Group {
            if gone {
                ContentUnavailableView("Объект удалён", systemImage: "trash", description: Text("\(initial.kind) «\(initial.name)» больше не существует."))
            } else {
                ResourceDetail(resource: current ?? initial, onOpen: onOpen)
            }
        }
        .navigationTitle("")
        .task(id: initial.uid) {
            current = initial
            while !Task.isCancelled {
                if let fresh = store.items.first(where: { $0.uid == initial.uid }) {
                    current = fresh
                } else {
                    do {
                        if let json = try? await store.client.get(initial), let r = KResource(json: json, kind: initial.kind) { current = r }
                        else if (try? await store.client.get(initial)) == nil { gone = true }
                    }
                }
                try? await Task.sleep(for: .seconds(store.refreshInterval))
            }
        }
    }
}

/// Связанные с нагрузкой объекты: поды по селектору, сервисы, ингрессы, события.
@MainActor
final class WorkloadData: ObservableObject {
    @Published var pods: [KResource] = []
    @Published var services: [KResource] = []
    @Published var ingresses: [KResource] = []
    @Published var events: [KResource] = []
    @Published var loaded = false
    @Published var error: String?

    func load(_ w: KResource, client: ClusterClient) async {
        let selector = (w.get("spec.selector.matchLabels") as? [String: String]) ?? [:]
        let templateLabels = (w.get("spec.template.metadata.labels") as? [String: String]) ?? [:]
        do {
            let allPods = try await client.list(ResourceKind.find("pods")!, namespace: w.namespace)
            pods = selector.isEmpty ? [] : allPods.filter { p in selector.allSatisfy { p.labels[$0.key] == $0.value } }
            if let svcs = try? await client.list(ResourceKind.find("services")!, namespace: w.namespace) {
                services = svcs.filter { s in
                    guard let sel = s.get("spec.selector") as? [String: String], !sel.isEmpty else { return false }
                    return sel.allSatisfy { templateLabels[$0.key] == $0.value }
                }
                let names = Set(services.map(\.name))
                if !names.isEmpty, let ings = try? await client.list(ResourceKind.find("ingresses.networking.k8s.io")!, namespace: w.namespace) {
                    ingresses = ings.filter { ing in
                        ing.list("spec.rules").contains { rule in
                            (((rule["http"] as? [String: Any])?["paths"] as? [[String: Any]]) ?? []).contains { p in
                                names.contains((((p["backend"] as? [String: Any])?["service"] as? [String: Any])?["name"] as? String) ?? "")
                            }
                        } || names.contains((((ing.get("spec.defaultBackend") as? [String: Any])?["service"] as? [String: Any])?["name"] as? String) ?? "")
                    }
                } else { ingresses = [] }
            }
            events = (try? await client.events(for: w)) ?? []
            error = nil
        } catch { self.error = error.localizedDescription }
        loaded = true
    }
}

/// Карточка объекта в стиле Rancher: заголовок с состоянием, сводка, карточки, вкладки со счётчиками.
struct ResourceDetail: View {
    @EnvironmentObject var store: ClusterStore
    let resource: KResource
    var onOpen: (KResource) -> Void = { _ in }

    @State private var tab = ""
    @State private var confirmDelete: KResource?
    @State private var showScale = false
    @State private var showForward = false
    @StateObject private var data = WorkloadData()

    private var isWorkload: Bool { ["Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"].contains(resource.kind) }
    private var kindInfo: ResourceKind? { ResourceKind.all.first { $0.kind == resource.kind } }

    private var tabs: [(String, String)] {
        var t: [(String, String)] = []
        if isWorkload {
            t.append(("pods", "Поды (\(data.pods.count))"))
            t.append(("services", "Services (\(data.services.count))"))
            t.append(("ingresses", "Ingresses (\(data.ingresses.count))"))
            t.append(("conditions", "Conditions (\(resource.list("status.conditions").count))"))
            t.append(("events", "События (\(data.events.count))"))
            t.append(("config", "Конфигурация"))
        } else {
            t.append(("overview", "Обзор"))
            if resource.kind == "Pod" { t.append(("logs", "Логи")) }
        }
        t += [("yaml", "YAML"), ("describe", "Describe")]
        if !isWorkload { t.append(("events", "События")) }
        return t
    }

    /// Активная вкладка: пока пользователь не выбрал, первая (или из отладочного `--tab`).
    private var currentTab: String {
        if !tab.isEmpty { return tab }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--tab"), i + 1 < args.count, tabs.contains(where: { $0.0 == args[i + 1] }) { return args[i + 1] }
        return tabs[0].0
    }

    private var tabBinding: Binding<String> { Binding(get: { currentTab }, set: { tab = $0 }) }

    /// Вкладки с собственной прокруткой занимают всё окно; остальные — в общем скролле страницы.
    private var fullHeightTab: Bool { ["logs", "yaml", "describe", "events"].contains(currentTab) }

    var body: some View {
        Group {
            if fullHeightTab {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        TabBar(tabs: tabs, selection: tabBinding)
                    }
                    .padding(.horizontal, Theme.pagePad).padding(.top, Theme.pagePad).padding(.bottom, 10)
                    .background(Theme.pageBackground)
                    Divider()
                    content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        if isWorkload { summaryCards }
                        VStack(alignment: .leading, spacing: 12) {
                            TabBar(tabs: tabs, selection: tabBinding)
                            content.frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    .padding(.horizontal, Theme.pagePad).padding(.top, Theme.pagePad).padding(.bottom, 28)
                }
                .background(Theme.pageBackground)
            }
        }
        .task(id: resource.uid) {
            guard isWorkload else { return }
            await data.load(resource, client: store.client)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(store.refreshInterval))
                if !Task.isCancelled { await data.load(resource, client: store.client) }
            }
        }
        .sheet(isPresented: $showScale) { ScaleSheet(resource: resource) }
        .sheet(isPresented: $showForward) { PortForwardSheet(resource: resource) }
        .confirmationDialog("Удалить \(resource.kind) «\(resource.name)»?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Удалить", role: .destructive) { store.perform("Удаление \(resource.name)") { try await store.client.delete(resource) } }
            Button("Удалить принудительно (--force)", role: .destructive) { store.perform("Удаление \(resource.name)") { try await store.client.delete(resource, force: true) } }
            Button("Отмена", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var content: some View {
        switch currentTab {
        case "pods": WorkloadPods(pods: data.pods, loaded: data.loaded, error: data.error, onOpen: onOpen)
        case "services": RelatedTable(items: data.services, kind: "Service", onOpen: onOpen)
        case "ingresses": RelatedTable(items: data.ingresses, kind: "Ingress", onOpen: onOpen)
        case "conditions": ConditionsList(conditions: resource.list("status.conditions"))
        case "config", "overview": OverviewTab(resource: resource)
        case "yaml": YAMLEditorTab(resource: resource)
        case "describe": DescribeTab(resource: resource)
        case "events": EventsTab(resource: resource)
        case "logs": LogsTab(pod: resource)
        default: EmptyView()
        }
    }

    /// Состояние в духе Rancher: Active / Updating / Running / причина ошибки.
    private var state: (String, Color) {
        let r = resource
        switch r.kind {
        case "Pod":
            let s = ResourceKind.podStatus(r)
            return (s, ["Running", "Succeeded"].contains(s) ? .green : (["Pending", "ContainerCreating", "PodInitializing", "Terminating"].contains(s) ? .orange : .red))
        case "Deployment", "StatefulSet", "ReplicaSet":
            let want = r.int("spec.replicas") ?? 0, ready = r.int("status.readyReplicas") ?? 0, updated = r.int("status.updatedReplicas") ?? ready
            if want == 0 { return ("Scaled down", .secondary) }
            if ready == want && updated == want { return ("Active", .green) }
            if r.condition("Progressing")?["reason"] as? String == "ProgressDeadlineExceeded" { return ("Failed", .red) }
            return ("Updating \(ready)/\(want)", .orange)
        case "DaemonSet":
            let want = r.int("status.desiredNumberScheduled") ?? 0, ready = r.int("status.numberReady") ?? 0
            return ready == want ? ("Active", .green) : ("Updating \(ready)/\(want)", .orange)
        case "Job":
            if r.condition("Complete")?["status"] as? String == "True" { return ("Succeeded", .green) }
            if r.condition("Failed")?["status"] as? String == "True" { return ("Failed", .red) }
            return ("Running", .orange)
        case "Node":
            return r.condition("Ready")?["status"] as? String == "True" ? ("Active", .green) : ("NotReady", .red)
        case "PersistentVolumeClaim", "PersistentVolume", "Namespace":
            let p = r.str("status.phase")
            return (p, ["Bound", "Active", "Available"].contains(p) ? .green : .orange)
        case "CronJob":
            return r.get("spec.suspend") as? Bool == true ? ("Suspended", .orange) : ("Active", .green)
        default:
            return ("Active", .green)
        }
    }

    // MARK: Заголовок и сводка

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: kindInfo?.icon ?? "cube")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(kindInfo?.title ?? resource.kind).font(.caption).fontWeight(.medium)
                        .foregroundStyle(.secondary).textCase(.uppercase)
                    HStack(spacing: 10) {
                        Text(resource.name).font(.title2).fontWeight(.semibold)
                            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        StateBadge(text: state.0, color: state.1)
                    }
                }
                Spacer(minLength: 12)
                actions
            }
            summaryGrid
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if isWorkload {
                Button { tab = "config" } label: { Label("Конфигурация", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.borderedProminent)
                if resource.kind != "Job" && resource.kind != "ReplicaSet" {
                    Button { store.perform("Перезапуск \(resource.name)") { try await store.client.rolloutRestart(resource) } } label: {
                        Label("Redeploy", systemImage: "arrow.clockwise")
                    }
                }
            }
            if resource.kind == "Pod" {
                Menu {
                    ForEach(resource.list("spec.containers").compactMap { $0["name"] as? String }, id: \.self) { c in
                        Button(c) { do { try store.client.openExecTerminal(pod: resource, container: c) } catch { store.error = error.localizedDescription } }
                    }
                } label: { Label("Shell", systemImage: "terminal") }.fixedSize()
                Button { tab = "logs" } label: { Label("Логи", systemImage: "text.alignleft") }
            }
            Button { tab = "yaml" } label: { Label("YAML", systemImage: "curlybraces") }
            Menu {
                ResourceActions(resource: resource, confirmDelete: $confirmDelete, onScale: { showScale = true }, onForward: { showForward = true })
            } label: { Image(systemName: "ellipsis") }.fixedSize()
        }
    }

    private var summaryGrid: some View {
        let r = resource
        return HStack(alignment: .top, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 7) {
                    if let ns = r.namespace {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("Namespace").foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                            LinkText(text: ns, bold: false) { store.namespace = ns }
                            Spacer(minLength: 0)
                        }.font(.callout)
                    }
                    KeyValue(key: "Возраст", value: r.age.isEmpty ? "—" : r.age, keyWidth: 130)
                    if isWorkload {
                        KeyValue(key: "Образ", value: r.list("spec.template.spec.containers").compactMap { $0["image"] as? String }.joined(separator: ", "), keyWidth: 130, mono: true)
                        KeyValue(key: "Рестарты подов", value: "\(data.pods.reduce(0) { $0 + $1.list("status.containerStatuses").reduce(0) { $0 + (($1["restartCount"] as? NSNumber)?.intValue ?? 0) } })", keyWidth: 130)
                        if r.kind == "DaemonSet" {
                            KeyValue(key: "Ready", value: "\(r.int("status.numberReady") ?? 0)/\(r.int("status.desiredNumberScheduled") ?? 0)", keyWidth: 130)
                        } else if r.kind != "Job" {
                            KeyValue(key: "Ready", value: "\(r.int("status.readyReplicas") ?? 0)/\(r.int("spec.replicas") ?? 0)", keyWidth: 130)
                            KeyValue(key: "Up-to-date", value: r.str("status.updatedReplicas").isEmpty ? "0" : r.str("status.updatedReplicas"), keyWidth: 130)
                            KeyValue(key: "Available", value: r.str("status.availableReplicas").isEmpty ? "0" : r.str("status.availableReplicas"), keyWidth: 130)
                        }
                    }
                    if r.kind == "Pod" {
                        KeyValue(key: "IP", value: r.str("status.podIP"), keyWidth: 130, mono: true)
                        KeyValue(key: "Узел", value: r.str("spec.nodeName"), keyWidth: 130)
                        KeyValue(key: "Образ", value: r.list("spec.containers").compactMap { $0["image"] as? String }.joined(separator: ", "), keyWidth: 130, mono: true)
                    }
                    if r.kind == "Service" {
                        KeyValue(key: "Тип", value: r.str("spec.type"), keyWidth: 130)
                        KeyValue(key: "Cluster IP", value: r.str("spec.clusterIP"), keyWidth: 130, mono: true)
                    }
                }
            }
            Card("Labels") {
                if r.labels.isEmpty { Text("Нет labels").font(.callout).foregroundStyle(.tertiary) }
                else { FlowLayout(spacing: 5) { ForEach(r.labels.keys.sorted().prefix(10), id: \.self) { Chip(key: $0, value: r.labels[$0] ?? "") } } }
            }
            .accessory { Text("\(r.labels.count)").font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: 340)
            Card("Annotations") {
                if r.annotations.isEmpty { Text("Нет annotations").font(.callout).foregroundStyle(.tertiary) }
                else { FlowLayout(spacing: 5) { ForEach(r.annotations.keys.sorted().prefix(6), id: \.self) { Chip(key: $0, value: r.annotations[$0] ?? "", maxValue: 30) } } }
            }
            .accessory { Text("\(r.annotations.count)").font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: 380)
        }
    }

    private var summaryCards: some View {
        HStack(alignment: .top, spacing: 12) {
            podsCard
            resourcesCard
            insightsCard
        }
    }

    private var podsCard: some View {
        let r = resource
        let want = r.int("spec.replicas")
        let groups = Dictionary(grouping: data.pods, by: { ResourceKind.podStatus($0) })
        return Card("Поды", systemImage: "cube") {
            if data.pods.isEmpty {
                Text(data.loaded ? "Подов нет" : "Загрузка…").font(.callout).foregroundStyle(.tertiary)
            } else {
                GeometryReader { g in
                    HStack(spacing: 2) {
                        ForEach(groups.keys.sorted(), id: \.self) { k in
                            Rectangle().fill(podColor(k)).frame(width: max(g.size.width * CGFloat(groups[k]!.count) / CGFloat(data.pods.count) - 2, 2))
                        }
                    }
                }
                .frame(height: 7).clipShape(Capsule())
                ForEach(groups.keys.sorted(), id: \.self) { k in
                    HStack(spacing: 8) {
                        Circle().fill(podColor(k)).frame(width: 7, height: 7)
                        Text(k).font(.callout)
                        Spacer()
                        Text("\(groups[k]!.count)").font(.callout).fontWeight(.medium).monospacedDigit()
                        Text(String(format: "%.0f%%", Double(groups[k]!.count) / Double(data.pods.count) * 100))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .accessory {
            if let want, r.kind != "ReplicaSet" {
                HStack(spacing: 2) {
                    Button { store.perform("Масштаб \(r.name) → \(want - 1)") { try await store.client.scale(r, replicas: max(want - 1, 0)) } } label: { Image(systemName: "minus") }.disabled(want == 0)
                    Text("\(want)").font(.callout).fontWeight(.semibold).monospacedDigit().frame(minWidth: 26)
                    Button { store.perform("Масштаб \(r.name) → \(want + 1)") { try await store.client.scale(r, replicas: want + 1) } } label: { Image(systemName: "plus") }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private func podColor(_ s: String) -> Color {
        if ["Running", "Succeeded"].contains(s) { return .green }
        if ["Pending", "ContainerCreating", "PodInitializing", "Terminating"].contains(s) { return .orange }
        return .red
    }

    private var resourcesCard: some View {
        let r = resource
        let spec = r.dict("spec.template.spec")
        var refs: [(String, String)] = []
        for v in spec["volumes"] as? [[String: Any]] ?? [] {
            if let cm = (v["configMap"] as? [String: Any])?["name"] as? String { refs.append(("ConfigMap", cm)) }
            if let sec = (v["secret"] as? [String: Any])?["secretName"] as? String { refs.append(("Secret", sec)) }
            if let pvc = (v["persistentVolumeClaim"] as? [String: Any])?["claimName"] as? String { refs.append(("PVC", pvc)) }
        }
        for c in (spec["containers"] as? [[String: Any]] ?? []) + (spec["initContainers"] as? [[String: Any]] ?? []) {
            for e in c["envFrom"] as? [[String: Any]] ?? [] {
                if let cm = (e["configMapRef"] as? [String: Any])?["name"] as? String { refs.append(("ConfigMap", cm)) }
                if let sec = (e["secretRef"] as? [String: Any])?["name"] as? String { refs.append(("Secret", sec)) }
            }
            for e in c["env"] as? [[String: Any]] ?? [] {
                let from = e["valueFrom"] as? [String: Any]
                if let cm = (from?["configMapKeyRef"] as? [String: Any])?["name"] as? String { refs.append(("ConfigMap", cm)) }
                if let sec = (from?["secretKeyRef"] as? [String: Any])?["name"] as? String { refs.append(("Secret", sec)) }
            }
        }
        var seen = Set<String>()
        let unique = refs.filter { seen.insert("\($0.0)/\($0.1)").inserted }
        if let sa = spec["serviceAccountName"] as? String, sa != "default" { seen.insert("sa"); }
        return Card("Ресурсы", systemImage: "link") {
            if unique.isEmpty {
                Text("Не ссылается на ConfigMap, Secret или PVC").font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(unique.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(unique[i].0).font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                    LinkText(text: unique[i].1, bold: false) {
                        let (kind, name) = unique[i]
                        let kid = kind == "ConfigMap" ? "configmaps" : (kind == "Secret" ? "secrets" : "persistentvolumeclaims")
                        store.kind = ResourceKind.find(kid)!
                        store.search = name
                    }
                    Spacer(minLength: 0)
                }
            }
            if let sa = spec["serviceAccountName"] as? String {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Account").font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                    Text(sa).font(.callout)
                    Spacer(minLength: 0)
                }
            }
        }
        .accessory { Text("\(unique.count)").font(.caption).foregroundStyle(.secondary) }
    }

    private var insightsCard: some View {
        let conds = resource.list("status.conditions")
        let warn = data.events.filter { $0.str("type") == "Warning" }.count
        let ok = conds.filter { $0["status"] as? String == "True" }.count
        return Card("Состояние", systemImage: "waveform.path.ecg") {
            HStack {
                LinkText(text: "Conditions", bold: false) { tab = "conditions" }
                Spacer()
                Text(conds.isEmpty ? "—" : "\(ok) из \(conds.count)")
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(conds.isEmpty || ok == conds.count ? Color.secondary : Color.orange)
            }
            HStack {
                LinkText(text: "События", bold: false) { tab = "events" }
                Spacer()
                if warn > 0 { StateBadge(text: "\(warn) warning", color: .orange, compact: true) }
                else { Text("\(data.events.count)").font(.callout).monospacedDigit().foregroundStyle(.secondary) }
            }
            let strategy = resource.str("spec.strategy.type")
            if !strategy.isEmpty {
                HStack { Text("Стратегия").font(.callout).foregroundStyle(.secondary); Spacer(); Text(strategy).font(.callout) }
            }
            if let img = resource.list("spec.template.spec.containers").first?["image"] as? String, !img.contains(":") || img.hasSuffix(":latest") {
                Label("Образ без фиксированного тега", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
    }

}

struct NamespaceLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon.font(.system(size: 7)).foregroundStyle(.green); configuration.title }
    }
}

struct ConditionsList: View {
    let conditions: [[String: Any]]
    var body: some View {
        if conditions.isEmpty { Text("Conditions нет").foregroundStyle(.secondary) }
        Table(conditions.indices.map { Row(i: $0, c: conditions[$0]) }) {
            TableColumn("Type") { Text($0.c["type"] as? String ?? "") }.width(ideal: 140)
            TableColumn("Status") { r in
                let ok = r.c["status"] as? String == "True"
                Label(r.c["status"] as? String ?? "", systemImage: ok ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(ok ? Color.green : Color.secondary)
            }.width(ideal: 90)
            TableColumn("Reason") { Text($0.c["reason"] as? String ?? "") }.width(ideal: 200)
            TableColumn("Message") { Text($0.c["message"] as? String ?? "").lineLimit(2) }
            TableColumn("Updated") { r in Text(((r.c["lastUpdateTime"] ?? r.c["lastTransitionTime"]) as? String).flatMap(KResource.iso.date).map { ageString(since: $0) } ?? "") }.width(ideal: 70)
        }
        .alternatingRowBackgrounds(.enabled)
        .frame(height: CGFloat(conditions.count) * 30 + 42)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.hairline))
    }
    struct Row: Identifiable { let i: Int; let c: [String: Any]; var id: Int { i } }
}

/// Таблица связанных объектов (сервисы, ингрессы) с переходом по клику.
struct RelatedTable: View {
    @EnvironmentObject var store: ClusterStore
    let items: [KResource]
    let kind: String
    var onOpen: (KResource) -> Void
    @State private var selection: KResource.ID?

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView("Нет связанных \(kind == "Service" ? "сервисов" : "ингрессов")", systemImage: kind == "Service" ? "network" : "arrow.triangle.branch")
                .frame(height: 200)
        } else {
            let cols = ResourceKind.all.first { $0.kind == kind }?.columns.filter { $0.title != "Namespace" } ?? []
            Table(items, selection: $selection) {
                TableColumnForEach(cols) { col in
                    TableColumn(col.title) { (r: KResource) in
                        if col.title == "Имя" {
                            Button { onOpen(r) } label: { Text(col.value(r)).fontWeight(.medium).foregroundStyle(Color.accentColor) }.buttonStyle(.plain)
                        } else { Text(col.value(r)) }
                    }.width(min: 40, ideal: col.width ?? 120)
                }
            }
            .alternatingRowBackgrounds(.enabled)
            .frame(height: CGFloat(items.count) * 30 + 44)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.hairline))
            .contextMenu(forSelectionType: KResource.ID.self) { ids in
                if let r = items.first(where: { $0.id == ids.first }) { Button("Открыть") { onOpen(r) } }
            } primaryAction: { ids in if let r = items.first(where: { $0.id == ids.first }) { onOpen(r) } }
        }
    }
}

/// Вкладка «Поды» нагрузки — как в Rancher: поды по селектору, клик открывает под.
struct WorkloadPods: View {
    @EnvironmentObject var store: ClusterStore
    let pods: [KResource]
    let loaded: Bool
    let error: String?
    var onOpen: (KResource) -> Void
    @State private var selection: KResource.ID?
    @State private var confirmDelete: KResource?

    var body: some View {
        if !loaded && pods.isEmpty { ProgressView().frame(height: 200) }
        else if let error { Text(error).foregroundStyle(.red).padding() }
        else if pods.isEmpty { ContentUnavailableView("Подов нет", systemImage: "cube", description: Text("Ни один под не подходит под селектор нагрузки.")).frame(height: 200) }
        else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if let p = pods.first(where: { $0.id == selection }) {
                        Button { onOpen(p) } label: { Label("Открыть", systemImage: "arrow.right.circle") }
                        Button(role: .destructive) { confirmDelete = p } label: { Label("Удалить под", systemImage: "trash") }
                            .help("Под пересоздастся контроллером")
                    } else {
                        Text("Выберите под для действий").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .controlSize(.small)
                Table(pods, selection: $selection) {
                    TableColumn("Статус") { p in
                        StateBadge(text: ResourceKind.podStatus(p), compact: true).padding(.vertical, 5)
                    }.width(ideal: 150)
                    TableColumn("Имя") { p in
                        LinkText(text: p.name) { onOpen(p) }
                    }.width(min: 200, ideal: 320)
                    TableColumn("Образ") { p in Text(p.list("spec.containers").compactMap { $0["image"] as? String }.joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1) }.width(ideal: 260)
                    TableColumn("Ready") { p in
                        Text("\(p.list("status.containerStatuses").filter { $0["ready"] as? Bool == true }.count)/\(p.list("spec.containers").count)")
                    }.width(ideal: 60)
                    TableColumn("Рестарты") { p in
                        let n = p.list("status.containerStatuses").reduce(0) { $0 + (($1["restartCount"] as? NSNumber)?.intValue ?? 0) }
                        let last = p.list("status.containerStatuses").compactMap { (($0["lastState"] as? [String: Any])?["terminated"] as? [String: Any])?["finishedAt"] as? String }.compactMap(KResource.iso.date).max()
                        Text(n == 0 ? "0" : "\(n)" + (last.map { " (\(ageString(since: $0)) назад)" } ?? "")).foregroundStyle(n > 0 ? Color.orange : Color.primary)
                    }.width(ideal: 120)
                    TableColumn("IP") { p in Text(p.str("status.podIP")).foregroundStyle(.secondary) }.width(ideal: 110)
                    TableColumn("Узел") { p in Text(p.str("spec.nodeName")).foregroundStyle(.secondary) }.width(ideal: 160)
                    TableColumn("Возраст") { p in Text(p.age).foregroundStyle(.secondary) }.width(ideal: 70)
                }
                .alternatingRowBackgrounds(.enabled)
                .frame(height: CGFloat(pods.count) * 32 + 44)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.hairline))
                .contextMenu(forSelectionType: KResource.ID.self) { ids in
                    if let p = pods.first(where: { $0.id == ids.first }) {
                        Button("Открыть") { onOpen(p) }
                        Menu("Shell") {
                            ForEach(p.list("spec.containers").compactMap { $0["name"] as? String }, id: \.self) { c in
                                Button(c) { do { try store.client.openExecTerminal(pod: p, container: c) } catch { store.error = error.localizedDescription } }
                            }
                        }
                        Button("Удалить под (пересоздастся)", role: .destructive) { confirmDelete = p }
                    }
                } primaryAction: { ids in if let p = pods.first(where: { $0.id == ids.first }) { onOpen(p) } }
            }
            .confirmationDialog("Удалить под «\(confirmDelete?.name ?? "")»?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { p in
                Button("Удалить", role: .destructive) { store.perform("Удаление \(p.name)", refreshAfter: false) { try await store.client.delete(p) } }
                Button("Отмена", role: .cancel) {}
            } message: { _ in Text("Контроллер создаст новый под.") }
        }
    }
}

// MARK: - Обзор

struct OverviewTab: View {
    @EnvironmentObject var store: ClusterStore
    let resource: KResource
    @State private var revealSecrets = false
    @State private var showAnnotations = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                kindSpecific
                if !resource.labels.isEmpty {
                    section("Labels") { chips(resource.labels) }
                }
                if !resource.annotations.isEmpty {
                    section("Annotations (\(resource.annotations.count))", toggle: $showAnnotations) {
                        if showAnnotations { keyValues(resource.annotations, mono: true) }
                    }
                }
                let conds = resource.list("status.conditions")
                if !conds.isEmpty && resource.kind != "Pod" {
                    section("Conditions") { conditions(conds) }
                }
                let owners = resource.list("metadata.ownerReferences")
                if !owners.isEmpty {
                    section("Владелец") {
                        ForEach(owners.indices, id: \.self) { i in
                            Text("\(owners[i]["kind"] as? String ?? "")/\(owners[i]["name"] as? String ?? "")").font(.callout).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var kindSpecific: some View {
        let r = resource
        switch r.kind {
        case "Pod":
            section("Контейнеры") { PodContainers(pod: r) }
            section("Размещение") {
                row("Узел", r.str("spec.nodeName"))
                row("Pod IP", r.str("status.podIP"))
                row("Service account", r.str("spec.serviceAccountName"))
                row("QoS", r.str("status.qosClass"))
                row("Restart policy", r.str("spec.restartPolicy"))
            }
            let conds = r.list("status.conditions")
            if !conds.isEmpty { section("Conditions") { conditions(conds) } }
        case "Deployment", "StatefulSet", "ReplicaSet", "DaemonSet":
            section("Реплики") {
                row("Желаемых", r.str("spec.replicas").isEmpty ? r.str("status.desiredNumberScheduled") : r.str("spec.replicas"))
                row("Готовых", r.str("status.readyReplicas").isEmpty ? r.str("status.numberReady") : r.str("status.readyReplicas"))
                row("Обновлённых", r.str("status.updatedReplicas").isEmpty ? r.str("status.updatedNumberScheduled") : r.str("status.updatedReplicas"))
                row("Стратегия", r.str("spec.strategy.type").isEmpty ? r.str("spec.updateStrategy.type") : r.str("spec.strategy.type"))
                if let sel = r.get("spec.selector.matchLabels") as? [String: String] {
                    row("Селектор", sel.map { "\($0)=\($1)" }.sorted().joined(separator: ", "))
                }
            }
            section("Контейнеры шаблона") { WorkloadEditor(resource: r) }
        case "Job":
            section("Выполнение") {
                row("Успешно", r.str("status.succeeded"))
                row("Неудачно", r.str("status.failed"))
                row("Активно", r.str("status.active"))
                row("Completions", r.str("spec.completions"))
                row("Parallelism", r.str("spec.parallelism"))
                row("Backoff limit", r.str("spec.backoffLimit"))
            }
            section("Контейнеры") { ContainerSpecs(specs: r.list("spec.template.spec.containers")) }
        case "CronJob":
            section("Расписание") {
                row("Schedule", r.str("spec.schedule"))
                row("Timezone", r.str("spec.timeZone"))
                row("Suspend", r.str("spec.suspend"))
                row("Concurrency", r.str("spec.concurrencyPolicy"))
                row("Последний запуск", r.str("status.lastScheduleTime"))
                row("Активных job", "\(r.list("status.active").count)")
            }
            section("Контейнеры") { ContainerSpecs(specs: r.list("spec.jobTemplate.spec.template.spec.containers")) }
        case "Service":
            section("Сеть") {
                row("Тип", r.str("spec.type"))
                row("Cluster IP", r.str("spec.clusterIP"))
                if let sel = r.get("spec.selector") as? [String: String] { row("Селектор", sel.map { "\($0)=\($1)" }.sorted().joined(separator: ", ")) }
                row("Session affinity", r.str("spec.sessionAffinity"))
            }
            section("Порты") {
                ForEach(r.list("spec.ports").indices, id: \.self) { i in
                    let p = r.list("spec.ports")[i]
                    HStack {
                        Text(p["name"] as? String ?? "—").frame(width: 120, alignment: .leading).foregroundStyle(.secondary)
                        Text("\((p["port"] as? NSNumber)?.stringValue ?? "") → \(targetPort(p["targetPort"]))\((p["nodePort"] as? NSNumber).map { "  (nodePort \($0))" } ?? "")  \(p["protocol"] as? String ?? "TCP")")
                    }.font(.system(.callout, design: .monospaced))
                }
            }
        case "Ingress":
            section("Правила") {
                ForEach(r.list("spec.rules").indices, id: \.self) { i in
                    let rule = r.list("spec.rules")[i]
                    let host = rule["host"] as? String ?? "*"
                    Text(host).fontWeight(.medium)
                    ForEach((((rule["http"] as? [String: Any])?["paths"] as? [[String: Any]]) ?? []).indices, id: \.self) { j in
                        let p = (((rule["http"] as? [String: Any])?["paths"] as? [[String: Any]]) ?? [])[j]
                        let svc = (p["backend"] as? [String: Any])?["service"] as? [String: Any]
                        let port = (svc?["port"] as? [String: Any])
                        Text("  \(p["path"] as? String ?? "/")  →  \(svc?["name"] as? String ?? "?"):\((port?["number"] as? NSNumber)?.stringValue ?? (port?["name"] as? String) ?? "")")
                            .font(.system(.callout, design: .monospaced))
                    }
                }
                let tls = r.list("spec.tls")
                if !tls.isEmpty { row("TLS", tls.map { "\((($0["hosts"] as? [String]) ?? []).joined(separator: ",")) (\($0["secretName"] as? String ?? ""))" }.joined(separator: "; ")) }
            }
            let urls = ingressURLs(r)
            if !urls.isEmpty {
                HStack { ForEach(urls, id: \.self) { u in Button(u) { if let url = URL(string: u) { NSWorkspace.shared.open(url) } }.buttonStyle(.link) } }
            }
        case "ConfigMap":
            section("Данные") { DataEditor(resource: r, entries: r.dict("data").compactMapValues { $0 as? String }, base64: false) }
            if !r.dict("binaryData").isEmpty { row("binaryData", r.dict("binaryData").keys.sorted().joined(separator: ", ")) }
            section("Кто использует") { UsedByView(resource: r) }
        case "Secret":
            section("Данные", toggle: $revealSecrets, toggleTitle: "Расшифровать") {
                if revealSecrets {
                    DataEditor(resource: r, entries: r.dict("data").compactMapValues { $0 as? String }, base64: true)
                } else {
                    DataEntries(entries: r.dict("data").compactMapValues { $0 as? String }, decode: false, hidden: true)
                }
            }
            row("Тип", r.str("type"))
            section("Кто использует") { UsedByView(resource: r) }
        case "Node":
            section("Узел") {
                row("Kubelet", r.str("status.nodeInfo.kubeletVersion"))
                row("Container runtime", r.str("status.nodeInfo.containerRuntimeVersion"))
                row("ОС", "\(r.str("status.nodeInfo.osImage")) · \(r.str("status.nodeInfo.kernelVersion"))")
                row("Архитектура", r.str("status.nodeInfo.architecture"))
                row("Адреса", r.list("status.addresses").map { "\($0["type"] as? String ?? ""): \($0["address"] as? String ?? "")" }.joined(separator: ", "))
                row("Unschedulable", r.str("spec.unschedulable"))
                if let taints = r.get("spec.taints") as? [[String: Any]], !taints.isEmpty {
                    row("Taints", taints.map { "\($0["key"] as? String ?? "")=\($0["value"] as? String ?? ""):\($0["effect"] as? String ?? "")" }.joined(separator: ", "))
                }
            }
            section("Ресурсы") {
                let cap = r.dict("status.capacity"), alloc = r.dict("status.allocatable")
                ForEach(["cpu", "memory", "pods", "ephemeral-storage"], id: \.self) { k in
                    row(k, "\(alloc[k].map { "\($0)" } ?? "") из \(cap[k].map { "\($0)" } ?? "")")
                }
            }
        case "PersistentVolumeClaim", "PersistentVolume":
            section("Хранилище") {
                row("Статус", r.str("status.phase"))
                row("Размер", r.str("status.capacity.storage").isEmpty ? r.str("spec.capacity.storage") : r.str("status.capacity.storage"))
                row("Access modes", ((r.get("spec.accessModes") as? [String]) ?? []).joined(separator: ", "))
                row("StorageClass", r.str("spec.storageClassName"))
                row("Volume", r.str("spec.volumeName"))
                if r.kind == "PersistentVolume" { row("Claim", "\(r.str("spec.claimRef.namespace"))/\(r.str("spec.claimRef.name"))"); row("Reclaim", r.str("spec.persistentVolumeReclaimPolicy")) }
            }
        case "Event":
            section("Событие") {
                row("Тип", r.str("type"))
                row("Причина", r.str("reason"))
                row("Объект", "\(r.str("involvedObject.kind"))/\(r.str("involvedObject.name"))")
                row("Источник", r.str("source.component").isEmpty ? r.str("reportingComponent") : r.str("source.component"))
                row("Количество", r.str("count"))
                Text(r.str("message")).font(.callout).textSelection(.enabled)
            }
        case "Namespace":
            row("Статус", r.str("status.phase"))
            Button { store.namespace = r.name; store.kind = ResourceKind.find("pods")! } label: { Label("Показать поды namespace", systemImage: "cube") }
        default:
            EmptyView()
        }
    }

    private func targetPort(_ v: Any?) -> String {
        if let n = v as? NSNumber { return n.stringValue }
        return v as? String ?? ""
    }

    // MARK: Кирпичики

    @ViewBuilder
    private func section<C: View>(_ title: String, toggle: Binding<Bool>? = nil, toggleTitle: String? = nil, @ViewBuilder _ content: @escaping () -> C) -> some View {
        Card(title) {
            VStack(alignment: .leading, spacing: 7) { content() }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessory {
            if let toggle {
                Toggle(toggleTitle ?? "Показать", isOn: toggle).toggleStyle(.switch).controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private func row(_ k: String, _ v: String) -> some View {
        KeyValue(key: k, value: v)
    }

    private func chips(_ d: [String: String]) -> some View {
        FlowLayout(spacing: 5) {
            ForEach(d.keys.sorted(), id: \.self) { k in Chip(key: k, value: d[k] ?? "", maxValue: 60) }
        }
    }

    private func keyValues(_ d: [String: String], mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(d.keys.sorted(), id: \.self) { k in
                HStack(alignment: .top) {
                    Text(k).foregroundStyle(.secondary).frame(width: 260, alignment: .leading).lineLimit(1).truncationMode(.middle)
                    Text(d[k] ?? "").lineLimit(3).textSelection(.enabled)
                }.font(.system(.caption, design: mono ? .monospaced : .default))
            }
        }
    }

    private func conditions(_ conds: [[String: Any]]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(conds.indices, id: \.self) { i in
                let c = conds[i]
                let ok = c["status"] as? String == "True"
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(ok ? Color.green : Color.secondary).font(.caption)
                    Text(c["type"] as? String ?? "").frame(width: 142, alignment: .leading)
                    Text([c["reason"] as? String, c["message"] as? String].compactMap { $0 }.joined(separator: ": "))
                        .foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                }.font(.callout)
            }
        }
    }
}

struct PodContainers: View {
    let pod: KResource

    var body: some View {
        let statuses = pod.list("status.containerStatuses") + pod.list("status.initContainerStatuses")
        let specs = pod.list("spec.initContainers").map { ($0, true) } + pod.list("spec.containers").map { ($0, false) }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(specs.indices, id: \.self) { i in
                let (spec, isInit) = specs[i]
                let name = spec["name"] as? String ?? ""
                let st = statuses.first { $0["name"] as? String == name }
                let state = (st?["state"] as? [String: Any]) ?? [:]
                let (stateText, color) = containerState(state)
                HStack(alignment: .top, spacing: 9) {
                    Circle().fill(color).frame(width: 8, height: 8).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(name).fontWeight(.medium)
                            if isInit { Text("init").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 1).background(Color.secondary.opacity(0.14), in: Capsule()) }
                            Text(stateText).font(.caption).foregroundStyle(color)
                            if let rc = (st?["restartCount"] as? NSNumber)?.intValue, rc > 0 { Text("рестартов: \(rc)").font(.caption).foregroundStyle(.orange) }
                        }
                        Text(spec["image"] as? String ?? "").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        if let ports = spec["ports"] as? [[String: Any]], !ports.isEmpty {
                            Text("порты: " + ports.map { "\(($0["containerPort"] as? NSNumber)?.stringValue ?? "")/\($0["protocol"] as? String ?? "TCP")" }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }
                        if let res = spec["resources"] as? [String: Any] {
                            let req = res["requests"] as? [String: Any] ?? [:], lim = res["limits"] as? [String: Any] ?? [:]
                            if !req.isEmpty || !lim.isEmpty {
                                Text("requests: \(fmt(req))  limits: \(fmt(lim))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let msg = ((state["waiting"] ?? state["terminated"]) as? [String: Any])?["message"] as? String, !msg.isEmpty {
                            Text(msg).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private func fmt(_ d: [String: Any]) -> String { d.isEmpty ? "—" : d.keys.sorted().map { "\($0)=\(d[$0]!)" }.joined(separator: " ") }

    private func containerState(_ state: [String: Any]) -> (String, Color) {
        if let r = state["running"] as? [String: Any] {
            let since = (r["startedAt"] as? String).flatMap { KResource.iso.date(from: $0) }.map { " · \(ageString(since: $0))" } ?? ""
            return ("Running\(since)", .green)
        }
        if let w = state["waiting"] as? [String: Any] { return (w["reason"] as? String ?? "Waiting", .orange) }
        if let t = state["terminated"] as? [String: Any] {
            let code = (t["exitCode"] as? NSNumber)?.intValue ?? 0
            return ("\(t["reason"] as? String ?? "Terminated") (\(code))", code == 0 ? .secondary : .red)
        }
        return ("—", .secondary)
    }
}

struct ContainerSpecs: View {
    let specs: [[String: Any]]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(specs.indices, id: \.self) { i in
                let c = specs[i]
                VStack(alignment: .leading, spacing: 1) {
                    Text(c["name"] as? String ?? "").fontWeight(.medium)
                    Text(c["image"] as? String ?? "").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    if let env = c["env"] as? [[String: Any]], !env.isEmpty {
                        Text("env: " + env.compactMap { $0["name"] as? String }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
    }
}

/// Форма правки pod-шаблона: реплики, образ, imagePullPolicy, env и ресурсы каждого контейнера.
/// Изменения уходят одним strategic-патчем; Kubernetes сам делает rolling update.
struct WorkloadEditor: View {
    @EnvironmentObject var store: ClusterStore
    let resource: KResource

    struct ContainerDraft: Equatable {
        var name: String
        var image: String
        var pullPolicy: String
        var env: String              // KEY=VALUE по строке — только переменные с явным value
        var envRefs: [String]        // переменные с valueFrom — показываем, не трогаем
        var cpuReq: String, memReq: String, cpuLim: String, memLim: String
    }

    @State private var replicas = 0
    @State private var containers: [ContainerDraft] = []
    @State private var original: [ContainerDraft] = []
    @State private var originalReplicas = 0
    @State private var saving = false
    @State private var message: String?

    private var hasReplicas: Bool { resource.kind != "DaemonSet" }
    private var dirty: Bool { containers != original || (hasReplicas && replicas != originalReplicas) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasReplicas {
                HStack {
                    Stepper("Реплик: \(replicas)", value: $replicas, in: 0...500)
                    if replicas != originalReplicas { Text("было \(originalReplicas)").font(.caption).foregroundStyle(.orange) }
                }
            }
            ForEach($containers, id: \.name) { $c in
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Образ").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            TextField("registry/image:tag", text: $c.image).font(.system(.callout, design: .monospaced)).textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("Pull policy").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            Picker("", selection: $c.pullPolicy) {
                                Text("по умолчанию").tag(""); Text("IfNotPresent").tag("IfNotPresent"); Text("Always").tag("Always"); Text("Never").tag("Never")
                            }.labelsHidden().fixedSize()
                        }
                        HStack(alignment: .top) {
                            Text("Переменные").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("KEY=VALUE, по одной на строку", text: $c.env, axis: .vertical)
                                    .lineLimit(2...12).font(.system(.caption, design: .monospaced)).textFieldStyle(.roundedBorder)
                                ForEach(c.envRefs, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                            }
                        }
                        HStack {
                            Text("Ресурсы").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                                GridRow { Text("").font(.caption); Text("CPU").font(.caption).foregroundStyle(.secondary); Text("Память").font(.caption).foregroundStyle(.secondary) }
                                GridRow {
                                    Text("requests").font(.caption)
                                    TextField("100m", text: $c.cpuReq).frame(width: 90)
                                    TextField("128Mi", text: $c.memReq).frame(width: 90)
                                }
                                GridRow {
                                    Text("limits").font(.caption)
                                    TextField("500m", text: $c.cpuLim).frame(width: 90)
                                    TextField("512Mi", text: $c.memLim).frame(width: 90)
                                }
                            }.textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
                        }
                    }.font(.callout)
                } label: {
                    HStack {
                        Text(c.name).fontWeight(.medium)
                        if let o = original.first(where: { $0.name == c.name }), o != c { Text("изменён").font(.caption2).padding(.horizontal, 4).background(Color.orange.opacity(0.2), in: Capsule()) }
                    }
                }
            }
            HStack {
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Spacer()
                Button("Отменить") { reset() }.disabled(!dirty)
                Button(saving ? "Применяю…" : "Применить") { save() }.buttonStyle(.borderedProminent).disabled(!dirty || saving)
            }
            Text("Смена образа, переменных или ресурсов запускает rolling update автоматически.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: reset)
        .onChange(of: resource) { _, _ in if !dirty { reset() } }
    }

    private func reset() {
        replicas = resource.int("spec.replicas") ?? 0
        originalReplicas = replicas
        containers = resource.list("spec.template.spec.containers").map { c in
            let env = c["env"] as? [[String: Any]] ?? []
            let plain = env.filter { $0["valueFrom"] == nil }.map { "\($0["name"] as? String ?? "")=\($0["value"] as? String ?? "")" }
            let refs = env.compactMap { e -> String? in
                guard let from = e["valueFrom"] as? [String: Any], let name = e["name"] as? String else { return nil }
                if let cm = from["configMapKeyRef"] as? [String: Any] { return "\(name) ← configMap \(cm["name"] as? String ?? "")/\(cm["key"] as? String ?? "")" }
                if let sec = from["secretKeyRef"] as? [String: Any] { return "\(name) ← secret \(sec["name"] as? String ?? "")/\(sec["key"] as? String ?? "")" }
                if let f = from["fieldRef"] as? [String: Any] { return "\(name) ← field \(f["fieldPath"] as? String ?? "")" }
                return "\(name) ← valueFrom"
            }
            let res = c["resources"] as? [String: Any] ?? [:]
            let req = res["requests"] as? [String: Any] ?? [:], lim = res["limits"] as? [String: Any] ?? [:]
            func q(_ v: Any?) -> String { (v as? String) ?? (v as? NSNumber)?.stringValue ?? "" }
            return ContainerDraft(name: c["name"] as? String ?? "", image: c["image"] as? String ?? "", pullPolicy: c["imagePullPolicy"] as? String ?? "",
                                  env: plain.joined(separator: "\n"), envRefs: refs,
                                  cpuReq: q(req["cpu"]), memReq: q(req["memory"]), cpuLim: q(lim["cpu"]), memLim: q(lim["memory"]))
        }
        original = containers
    }

    private func parseEnv(_ s: String) -> [(String, String)] {
        s.split(separator: "\n").compactMap { line in
            let t = String(line).trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            guard let eq = t.firstIndex(of: "=") else { return (t, "") }
            return (String(t[..<eq]).trimmingCharacters(in: .whitespaces), String(t[t.index(after: eq)...]))
        }
    }

    private func save() {
        var spec: [String: Any] = [:]
        if hasReplicas && replicas != originalReplicas { spec["replicas"] = replicas }
        var patched: [[String: Any]] = []
        for c in containers {
            guard let o = original.first(where: { $0.name == c.name }), o != c else { continue }
            var pc: [String: Any] = ["name": c.name]
            if c.image != o.image { pc["image"] = c.image.trimmingCharacters(in: .whitespaces) }
            if c.pullPolicy != o.pullPolicy { pc["imagePullPolicy"] = c.pullPolicy.isEmpty ? NSNull() : c.pullPolicy }
            if c.env != o.env {
                let new = parseEnv(c.env), old = parseEnv(o.env)
                var env: [[String: Any]] = new.map { ["name": $0.0, "value": $0.1] }
                for (k, _) in old where !new.contains(where: { $0.0 == k }) { env.append(["name": k, "$patch": "delete"]) }
                pc["env"] = env
            }
            if (c.cpuReq, c.memReq, c.cpuLim, c.memLim) != (o.cpuReq, o.memReq, o.cpuLim, o.memLim) {
                func m(_ cpu: String, _ mem: String) -> [String: Any] {
                    ["cpu": cpu.isEmpty ? NSNull() : cpu, "memory": mem.isEmpty ? NSNull() : mem]
                }
                pc["resources"] = ["requests": m(c.cpuReq, c.memReq), "limits": m(c.cpuLim, c.memLim)]
            }
            patched.append(pc)
        }
        if !patched.isEmpty { spec["template"] = ["spec": ["containers": patched]] }
        guard !spec.isEmpty else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await store.client.strategicPatch(resource, ["spec": spec])
                message = "Применено"
                original = containers; originalReplicas = replicas
                await store.refresh()
            } catch { store.error = "Правка \(resource.name): \(error.localizedDescription)" }
        }
    }
}

/// Нагрузки в том же namespace, которые ссылаются на ConfigMap/Secret (env, envFrom, volumes,
/// imagePullSecrets), с кнопкой rollout restart — чтобы новые значения подтянулись.
struct UsedByView: View {
    @EnvironmentObject var store: ClusterStore
    let resource: KResource
    @State private var users: [KResource] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        if loading { ProgressView().controlSize(.small).task { await load() } }
        else if let error { Text(error).font(.caption).foregroundStyle(.red) }
        else if users.isEmpty { Text("Ни один Deployment, StatefulSet или DaemonSet в этом namespace не ссылается на объект.").font(.caption).foregroundStyle(.secondary) }
        else {
            ForEach(users) { u in
                HStack {
                    Text("\(u.kind)/\(u.name)").font(.callout).textSelection(.enabled)
                    Text("\(u.int("status.readyReplicas") ?? u.int("status.numberReady") ?? 0)/\(u.int("spec.replicas") ?? u.int("status.desiredNumberScheduled") ?? 0)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Rollout restart") { store.perform("Перезапуск \(u.name)") { try await store.client.rolloutRestart(u) } }
                        .controlSize(.small)
                }
            }
            if users.count > 1 {
                Button("Перезапустить все (\(users.count))") {
                    let list = users
                    store.perform("Перезапуск \(list.count) нагрузок") { for u in list { try await store.client.rolloutRestart(u) } }
                }.controlSize(.small)
            }
        }
    }

    private func load() async {
        defer { loading = false }
        do {
            var found: [KResource] = []
            for kid in ["deployments.apps", "statefulsets.apps", "daemonsets.apps"] {
                let items = try await store.client.list(ResourceKind.find(kid)!, namespace: resource.namespace)
                found += items.filter { references($0) }
            }
            users = found
        } catch { self.error = error.localizedDescription }
    }

    /// Ищем имя объекта во всех местах pod-шаблона, где на него можно сослаться.
    private func references(_ w: KResource) -> Bool {
        let isSecret = resource.kind == "Secret"
        let spec = w.dict("spec.template.spec")
        let name = resource.name
        func hit(_ d: [String: Any]?) -> Bool { d?["name"] as? String == name }
        for v in spec["volumes"] as? [[String: Any]] ?? [] {
            if isSecret, (v["secret"] as? [String: Any])?["secretName"] as? String == name { return true }
            if !isSecret, hit(v["configMap"] as? [String: Any]) { return true }
            for src in ((v["projected"] as? [String: Any])?["sources"] as? [[String: Any]]) ?? [] {
                if isSecret ? hit(src["secret"] as? [String: Any]) : hit(src["configMap"] as? [String: Any]) { return true }
            }
        }
        if isSecret, (spec["imagePullSecrets"] as? [[String: Any]] ?? []).contains(where: hit) { return true }
        let containers = (spec["containers"] as? [[String: Any]] ?? []) + (spec["initContainers"] as? [[String: Any]] ?? [])
        for c in containers {
            for e in c["envFrom"] as? [[String: Any]] ?? [] {
                if isSecret ? hit(e["secretRef"] as? [String: Any]) : hit(e["configMapRef"] as? [String: Any]) { return true }
            }
            for e in c["env"] as? [[String: Any]] ?? [] {
                let from = e["valueFrom"] as? [String: Any]
                if isSecret ? hit(from?["secretKeyRef"] as? [String: Any]) : hit(from?["configMapKeyRef"] as? [String: Any]) { return true }
            }
        }
        return false
    }
}

/// Редактор данных ConfigMap/Secret по ключам: правка значений, новые ключи, удаление.
/// Сохраняется одним merge-патчем; удалённые ключи уходят как null.
struct DataEditor: View {
    @EnvironmentObject var store: ClusterStore
    let resource: KResource
    let entries: [String: String]
    let base64: Bool

    struct Entry: Identifiable, Equatable {
        var key: String
        var value: String
        var binary = false     // не UTF-8: показываем, но не редактируем
        var id: String { key }
    }

    @State private var rows: [Entry] = []
    @State private var original: [Entry] = []
    @State private var newKey = ""
    @State private var saving = false
    @State private var message: String?

    private var dirty: Bool { rows != original }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty { Text("пусто").foregroundStyle(.secondary).font(.callout) }
            ForEach($rows) { $e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(e.key).font(.system(.callout, design: .monospaced)).fontWeight(.medium)
                        if original.first(where: { $0.key == e.key }) == nil {
                            Text("новый").font(.caption2).padding(.horizontal, 4).background(Color.green.opacity(0.2), in: Capsule())
                        } else if original.first(where: { $0.key == e.key })?.value != e.value {
                            Text("изменён").font(.caption2).padding(.horizontal, 4).background(Color.orange.opacity(0.2), in: Capsule())
                        }
                        Spacer()
                        Text("\(e.value.count) симв.").font(.caption2).foregroundStyle(.tertiary)
                        Button { copy(e.value) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Скопировать значение")
                        Button { rows.removeAll { $0.key == e.key } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Удалить ключ")
                    }
                    if e.binary {
                        Text("бинарные данные, редактирование недоступно").font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextEditor(text: $e.value)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: e.value.contains("\n") || e.value.count > 120 ? 90 : 26, maxHeight: 260)
                            .scrollContentBackground(.hidden)
                            .padding(4).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    }
                }
            }
            Divider()
            HStack {
                TextField("Новый ключ", text: $newKey).textFieldStyle(.roundedBorder).frame(maxWidth: 220).onSubmit(addKey)
                Button("Добавить", action: addKey).disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty || rows.contains { $0.key == newKey })
                Spacer()
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Button("Отменить") { rows = original }.disabled(!dirty)
                Button(saving ? "Сохраняю…" : "Сохранить") { save() }.buttonStyle(.borderedProminent).disabled(!dirty || saving)
            }
        }
        .onAppear(perform: reset)
        .onChange(of: entries) { _, _ in if !dirty { reset() } }
    }

    private func reset() {
        rows = entries.keys.sorted().map { k in
            let raw = entries[k] ?? ""
            if base64 {
                if let d = Data(base64Encoded: raw), let s = String(data: d, encoding: .utf8) { return Entry(key: k, value: s) }
                return Entry(key: k, value: raw, binary: true)
            }
            return Entry(key: k, value: raw)
        }
        original = rows
    }

    private func addKey() {
        let k = newKey.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty, !rows.contains(where: { $0.key == k }) else { return }
        rows.append(Entry(key: k, value: ""))
        newKey = ""
    }

    private func save() {
        var data: [String: Any] = [:]
        for e in rows where original.first(where: { $0.key == e.key }) != e {
            if e.binary { continue }
            data[e.key] = base64 ? Data(e.value.utf8).base64EncodedString() : e.value
        }
        for o in original where !rows.contains(where: { $0.key == o.key }) { data[o.key] = NSNull() }
        guard !data.isEmpty else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await store.client.patch(resource, merge: ["data": data])
                message = "Сохранено \(data.count) ключ(ей)"
                original = rows
                await store.refresh()
            } catch { store.error = "Сохранение \(resource.name): \(error.localizedDescription)" }
        }
    }
}

/// Пары ключ → значение ConfigMap/Secret с раскрытием длинных значений.
struct DataEntries: View {
    let entries: [String: String]
    let decode: Bool
    var hidden = false
    @State private var expanded: Set<String> = []

    var body: some View {
        if entries.isEmpty { Text("пусто").foregroundStyle(.secondary).font(.callout) }
        ForEach(entries.keys.sorted(), id: \.self) { k in
            let raw = entries[k] ?? ""
            let value = decode ? (Data(base64Encoded: raw).map { String(decoding: $0, as: UTF8.self) } ?? "<binary>") : raw
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(k).font(.system(.callout, design: .monospaced)).fontWeight(.medium)
                    Spacer()
                    if !hidden {
                        Text("\(value.count) симв.").font(.caption2).foregroundStyle(.tertiary)
                        Button { copy(value) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Скопировать значение")
                        if value.count > 300 || value.contains("\n") {
                            Button { if expanded.contains(k) { expanded.remove(k) } else { expanded.insert(k) } } label: { Image(systemName: expanded.contains(k) ? "chevron.up" : "chevron.down") }.buttonStyle(.borderless)
                        }
                    }
                }
                if hidden {
                    Text("••••••••").foregroundStyle(.secondary)
                } else {
                    Text(value)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(expanded.contains(k) ? nil : 6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }
}

/// Простейший перенос строк для чипов.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - YAML

struct YAMLEditorTab: View {
    @EnvironmentObject var store: ClusterStore
    let resource: KResource
    @State private var text = ""
    @State private var original = ""
    @State private var loading = true
    @State private var saving = false
    @State private var message: String?
    @State private var isError = false
    @State private var showStatus = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("status и managedFields", isOn: $showStatus).toggleStyle(.checkbox).controlSize(.small)
                    .onChange(of: showStatus) { _, _ in Task { await load() } }
                Spacer()
                if let message { Text(message).font(.caption).foregroundStyle(isError ? .red : .green).lineLimit(2).textSelection(.enabled) }
                Button("Перечитать") { Task { await load() } }.disabled(loading)
                Button { copy(text) } label: { Image(systemName: "doc.on.doc") }.help("Скопировать")
                Button(saving ? "Применяю…" : "Применить") { save() }.keyboardShortcut("s").buttonStyle(.borderedProminent).disabled(saving || text == original || loading)
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            if loading && text.isEmpty {
                ProgressView().frame(maxHeight: .infinity)
            } else {
                TextEditor(text: $text)
                    .font(.system(.callout, design: .monospaced))
                    .autocorrectionDisabled()
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            var json = try await store.client.get(resource)
            if !showStatus {
                json["status"] = nil
                if var meta = json["metadata"] as? [String: Any] { meta["managedFields"] = nil; json["metadata"] = meta }
            }
            let y = JSONYAML.yaml(from: json, stripManagedFields: !showStatus)
            text = y; original = y
            message = nil
        } catch { message = error.localizedDescription; isError = true }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                let out = try await store.client.apply(yaml: text)
                message = out.trimmingCharacters(in: .whitespacesAndNewlines); isError = false
                original = text
                await store.refresh()
            } catch { message = error.localizedDescription; isError = true }
        }
    }
}

// MARK: - Describe

struct DescribeTab: View {
    @EnvironmentObject var store: ClusterStore
    let resource: KResource
    @State private var text = ""
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Обновить") { Task { await load() } }.disabled(loading)
                Button { copy(text) } label: { Image(systemName: "doc.on.doc") }
            }.padding(.horizontal, 12).padding(.bottom, 8)
            if loading && text.isEmpty { ProgressView().frame(maxHeight: .infinity) }
            else {
                GeometryReader { geo in
                    ScrollView([.vertical, .horizontal]) {
                        Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                            .padding(12)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { text = try await store.client.describe(resource) } catch { text = error.localizedDescription }
    }
}

// MARK: - События

struct EventsTab: View {
    @EnvironmentObject var store: ClusterStore
    let resource: KResource
    @State private var events: [KResource] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if loading && events.isEmpty { ProgressView().frame(maxHeight: .infinity) }
            else if let error { Text(error).foregroundStyle(.red).padding() }
            else if events.isEmpty { ContentUnavailableView("Событий нет", systemImage: "bell.slash", description: Text("Kubernetes хранит события около часа.")) }
            else {
                List(events) { e in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: e.str("type") == "Warning" ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(e.str("type") == "Warning" ? Color.orange : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(e.str("reason")).fontWeight(.medium)
                                Text(ResourceKind.eventTime(e).map { ageString(since: $0) } ?? "").foregroundStyle(.secondary)
                                if let c = e.int("count"), c > 1 { Text("×\(c)").foregroundStyle(.secondary) }
                                Spacer()
                                Text(e.str("source.component")).font(.caption).foregroundStyle(.tertiary)
                            }.font(.callout)
                            Text(e.str("message")).font(.callout).textSelection(.enabled)
                        }
                    }.padding(.vertical, 2)
                }
            }
        }
        .task { await load() }
        .toolbar { ToolbarItem { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.disabled(loading) } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { events = try await store.client.events(for: resource); error = nil } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Логи

struct LogsTab: View {
    @EnvironmentObject var store: ClusterStore
    let pod: KResource
    @StateObject private var stream = LogStream()
    @State private var container = ""
    @State private var previous = false
    @State private var follow = true
    @State private var timestamps = false
    @State private var tail = 500
    @State private var filter = ""
    @State private var wrap = true

    private var containers: [String] { (pod.list("spec.initContainers") + pod.list("spec.containers")).compactMap { $0["name"] as? String } }
    private var visible: [String] {
        let q = filter.lowercased()
        return q.isEmpty ? stream.lines : stream.lines.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if containers.count > 1 {
                    Picker("", selection: $container) { ForEach(containers, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(maxWidth: 200)
                }
                Toggle("Следить", isOn: $follow).toggleStyle(.checkbox)
                Toggle("Предыдущий", isOn: $previous).toggleStyle(.checkbox).help("Логи предыдущего запуска контейнера (--previous)")
                Toggle("Время", isOn: $timestamps).toggleStyle(.checkbox)
                Toggle("Перенос", isOn: $wrap).toggleStyle(.checkbox)
                Picker("", selection: $tail) { Text("100").tag(100); Text("500").tag(500); Text("2000").tag(2000); Text("все").tag(-1) }.labelsHidden().fixedSize()
                TextField("Фильтр", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                Spacer()
                if stream.running { ProgressView().controlSize(.small) }
                Text("\(visible.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button { copy(visible.joined(separator: "\n")) } label: { Image(systemName: "doc.on.doc") }.help("Скопировать")
                Button { restart() } label: { Image(systemName: "arrow.clockwise") }.help("Перезапустить")
                Button { stream.stop() } label: { Image(systemName: "stop.fill") }.disabled(!stream.running)
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.bottom, 8)
            .onChange(of: container) { _, _ in restart() }
            .onChange(of: previous) { _, _ in restart() }
            .onChange(of: follow) { _, _ in restart() }
            .onChange(of: timestamps) { _, _ in restart() }
            .onChange(of: tail) { _, _ in restart() }

            if let err = stream.error { Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal, 12).padding(.bottom, 4) }

            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView(wrap ? [.vertical] : [.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if visible.isEmpty && !stream.running {
                                Text(stream.lines.isEmpty ? "Логов нет" : "Ничего не найдено по фильтру").foregroundStyle(.secondary).padding()
                            }
                            ForEach(visible.indices, id: \.self) { i in
                                Text(visible[i])
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(lineColor(visible[i]))
                                    .lineLimit(wrap ? nil : 1)
                                    .fixedSize(horizontal: !wrap, vertical: false)
                                    .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                                    .textSelection(.enabled)
                                    .id(i)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(10)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: stream.lines.count) { _, _ in if follow { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
            }
        }
        .onAppear { container = containers.last ?? ""; restart() }
        .onDisappear { stream.stop() }
    }

    private func restart() {
        stream.start(client: store.client, pod: pod, container: containers.count > 1 ? container : nil, previous: previous, tail: tail, follow: follow, timestamps: timestamps)
    }

    private func lineColor(_ s: String) -> Color {
        let l = s.lowercased()
        if l.contains("error") || l.contains("fatal") || l.contains("panic") || l.contains(" err ") || l.contains("[crit]") || l.contains("[emerg]") { return .red }
        if l.contains("warn") { return .orange }
        if l.contains("[notice]") || l.contains(" info ") || l.contains("[info]") { return Color(nsColor: .labelColor).opacity(0.75) }
        return Color(nsColor: .labelColor)
    }
}

// MARK: - Листы

struct ScaleSheet: View {
    @EnvironmentObject var store: ClusterStore
    @Environment(\.dismiss) private var dismiss
    let resource: KResource
    @State private var replicas = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Масштабировать \(resource.kind) «\(resource.name)»").font(.headline)
            HStack {
                Stepper("Реплик: \(replicas)", value: $replicas, in: 0...500)
                Spacer()
                ForEach([0, 1, 2, 3, 5], id: \.self) { n in Button("\(n)") { replicas = n }.controlSize(.small) }
            }
            if replicas == 0 { Text("0 реплик остановит все поды, объект останется.").font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Применить") {
                    store.perform("Масштабирование \(resource.name) → \(replicas)") { try await store.client.scale(resource, replicas: replicas) }
                    dismiss()
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 440)
        .onAppear { replicas = resource.int("spec.replicas") ?? 1 }
    }
}

struct PortForwardSheet: View {
    @EnvironmentObject var store: ClusterStore
    @Environment(\.dismiss) private var dismiss
    let resource: KResource
    @State private var remote = 0
    @State private var local = 0

    private var ports: [Int] {
        if resource.kind == "Service" { return resource.list("spec.ports").compactMap { ($0["port"] as? NSNumber)?.intValue } }
        return resource.list("spec.containers").flatMap { ($0["ports"] as? [[String: Any]]) ?? [] }.compactMap { ($0["containerPort"] as? NSNumber)?.intValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Port-forward → \(resource.kind.lowercased())/\(resource.name)").font(.headline)
            HStack {
                TextField("Локальный порт", value: $local, format: .number).frame(width: 120)
                Image(systemName: "arrow.right")
                TextField("Порт в кластере", value: $remote, format: .number).frame(width: 120)
                if !ports.isEmpty {
                    Menu("Порты объекта") { ForEach(ports, id: \.self) { p in Button("\(p)") { remote = p; if local == 0 { local = p < 1024 ? p + 8000 : p } } } }.fixedSize()
                }
            }
            Text("kubectl port-forward работает, пока открыто окно кластера. Локальные порты ниже 1024 требуют root.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Запустить") {
                    store.addForward(resource, localPort: local, remotePort: remote)
                    dismiss()
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(remote <= 0 || local <= 0)
            }
        }
        .padding(20).frame(width: 480)
        .onAppear { if let p = ports.first { remote = p; local = p < 1024 ? p + 8000 : p } }
    }
}
