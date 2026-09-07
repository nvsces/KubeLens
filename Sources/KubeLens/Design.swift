import SwiftUI
import AppKit

/// Единые токены оформления. Цвета берутся системные там, где это возможно:
/// так интерфейс сам подстраивается под тёмную тему и акцентный цвет пользователя.
enum Theme {
    // Отступы: 4-я сетка, чтобы поля страницы и карточек совпадали.
    static let gap: CGFloat = 8
    static let pad: CGFloat = 12
    static let pagePad: CGFloat = 20
    static let radius: CGFloat = 10

    /// Карточка светлее подложки страницы в обеих темах: `windowBackgroundColor` — фон окна,
    /// `controlBackgroundColor` — фон полей и таблиц, он же светлее в светлой теме.
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let pageBackground = Color(nsColor: .windowBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)

    /// Цвет состояния объекта. Один источник правды для бейджей, таблиц и полос.
    static func stateColor(_ s: String) -> Color {
        let l = s.lowercased()
        if l.hasPrefix("init:") { return .orange }
        for (needles, color) in [
            (["running", "active", "ready", "bound", "complete", "succeeded", "available", "normal", "healthy"], Color.green),
            (["pending", "creating", "initializing", "terminating", "updating", "released", "warning", "suspended", "progressing"], Color.orange),
            (["fail", "error", "crashloop", "imagepull", "errimage", "oomkilled", "notready", "evicted", "unknown", "lost", "backoff", "unschedulable"], Color.red),
        ] where needles.contains(where: { l.contains($0) }) {
            return color
        }
        if l == "scaled down" || l.isEmpty { return .secondary }
        return .secondary
    }
}

/// Бейдж состояния: точка и подпись на мягкой подложке — как в Rancher.
struct StateBadge: View {
    let text: String
    var color: Color?
    var compact = false

    var body: some View {
        let c = color ?? Theme.stateColor(text)
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(text).font(compact ? .caption : .callout).fontWeight(.medium).foregroundStyle(c == .secondary ? Color.secondary : c)
        }
        .padding(.horizontal, compact ? 7 : 9)
        .padding(.vertical, compact ? 2 : 3)
        .background((c == .secondary ? Color.secondary : c).opacity(0.13), in: Capsule())
        .fixedSize()
    }
}

/// Карточка: подложка, скругление, тонкая рамка. Заголовок опционален.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: () -> Content
    var accessory: AnyView?

    init(_ title: String? = nil, systemImage: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary) }
                    Text(title).font(.headline)
                    Spacer()
                    accessory
                }
            }
            content()
        }
        .padding(Theme.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.hairline, lineWidth: 1))
    }
}

extension Card {
    func accessory<A: View>(@ViewBuilder _ view: () -> A) -> Card {
        var copy = self
        copy.accessory = AnyView(view())
        return copy
    }
}

/// Строка «ключ — значение» с фиксированной колонкой ключа: колонки не пляшут между карточками.
struct KeyValue: View {
    let key: String
    let value: String
    var keyWidth: CGFloat = 150
    var mono = false

    var body: some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(key).foregroundStyle(.secondary).frame(width: keyWidth, alignment: .leading)
                Text(value)
                    .font(mono ? .system(.callout, design: .monospaced) : .callout)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .font(.callout)
        }
    }
}

/// Чип для label/annotation: моноширинный, обрезается по длине, полный текст в подсказке.
struct Chip: View {
    let key: String
    let value: String
    var maxValue = 44

    var body: some View {
        let short = value.count > maxValue ? String(value.prefix(maxValue)) + "…" : value
        HStack(spacing: 0) {
            Text(key).foregroundStyle(.secondary)
            Text("=").foregroundStyle(.tertiary)
            Text(short)
        }
        .font(.system(.caption, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        .help("\(key)=\(value)")
    }
}

/// Заголовок секции внутри страницы.
struct SectionTitle: View {
    let text: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.headline)
            if let count { Text("\(count)").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 1).background(Color.secondary.opacity(0.14), in: Capsule()) }
        }
    }
}

/// Вкладки-подчёркивания.
struct TabBar: View {
    let tabs: [(String, String)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.0) { key, title in
                let active = selection == key
                Button { selection = key } label: {
                    Text(title)
                        .font(.callout).fontWeight(active ? .semibold : .regular)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                        .background(active ? Color.secondary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

/// Кнопка-ссылка на объект: акцентный цвет, курсор-рука.
struct LinkText: View {
    let text: String
    var bold = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .fontWeight(bold ? .medium : .regular)
                .foregroundStyle(Color.accentColor)
                .lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}
