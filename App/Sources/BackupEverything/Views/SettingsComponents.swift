import BackupCore
import SwiftUI

struct EditorLayout<Item: Identifiable, Label: View, AddMenu: View, Detail: View>: View where Item.ID == UUID {
    let items: [Item]
    @Binding var selection: UUID?
    @ViewBuilder let label: (Item) -> Label
    @ViewBuilder let addMenu: AddMenu
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        EditorListItem(isSelected: selection == item.id) { selection = item.id } label: { label(item) }
                    }
                    Menu {
                        addMenu
                    } label: {
                        SwiftUI.Label("Добавить", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }
                .padding(10)
            }
            .frame(width: 200)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct EditorListItem<Label: View>: View {
    let isSelected: Bool
    let select: () -> Void
    @ViewBuilder let label: Label

    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            label
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(background, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.quaternary) }
        return isHovered ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear)
    }
}

struct EditorPage<Header: View, Content: View, SaveBar: View>: View {
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @ViewBuilder let saveBar: SaveBar

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                content
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
    }
}

struct EditorHeader<Icon: View, Accessory: View>: View {
    @Binding var name: String
    let prompt: String
    @ViewBuilder let icon: Icon
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            icon
                .font(.title3)
                .frame(width: 22)
            TextField("", text: $name, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
            accessory
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    var isProminent = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(isProminent ? .headline : .callout)
                .foregroundStyle(isProminent ? .primary : .secondary)
                .padding(.horizontal, 14)
            SettingsCard(isProminent: isProminent) { content }
        }
    }
}

struct SettingsCard<Content: View>: View {
    var isProminent = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    if index > 0 { Divider() }
                    subview
                }
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .background(isProminent ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isProminent ? AnyShapeStyle(.tint.opacity(0.55)) : AnyShapeStyle(.separator)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    var tip: String?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            if let tip {
                Image(systemName: "info.circle")
                    .foregroundStyle(.tertiary)
                    .hoverTip(tip)
            }
            Spacer(minLength: 12)
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
    }
}

struct DisclosureRow<Content: View>: View {
    let title: String
    let summary: String
    @ViewBuilder let content: Content

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Text(title)
                    Spacer(minLength: 12)
                    if !isExpanded {
                        Text(summary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) { content }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct PathField: View {
    @Binding var path: String
    var allowsFiles = false

    var body: some View {
        TextField("", text: $path, prompt: Text("не выбрано"))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
        Button("Выбрать…") {
            if let chosen = FolderPicker.choose(allowsFiles: allowsFiles) { path = chosen }
        }
        .controlSize(.small)
    }
}

struct CodeEditor: View {
    @Binding var text: String
    let minHeight: CGFloat

    var body: some View {
        TextEditor(text: $text)
            .font(.callout.monospaced())
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct Chip: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Label(title, systemImage: symbol)
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .background(isOn ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear), in: Capsule())
                .overlay(Capsule().strokeBorder(isOn ? AnyShapeStyle(.clear) : AnyShapeStyle(.separator)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct TrailingFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(of: subviews, width: proposal.width ?? .infinity)
        let height = lines.map(\.height).reduce(0, +) + spacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(of: subviews, width: bounds.width) {
            var x = bounds.maxX - line.width
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(of subviews: Subviews, width: CGFloat) -> [Line] {
        var lines = [Line()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let gap = lines[lines.count - 1].indices.isEmpty ? 0 : spacing
            if lines[lines.count - 1].width + gap + size.width > width, !lines[lines.count - 1].indices.isEmpty {
                lines.append(Line())
            }
            let lead = lines[lines.count - 1].indices.isEmpty ? 0 : spacing
            lines[lines.count - 1].indices.append(index)
            lines[lines.count - 1].width += lead + size.width
            lines[lines.count - 1].height = max(lines[lines.count - 1].height, size.height)
        }
        return lines
    }
}

struct SaveBar: View {
    let isNew: Bool
    let problem: String?
    var warning: String?
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let problem { Text(problem).foregroundStyle(.red) }
                if let warning { Text(warning).foregroundStyle(.orange) }
            }
            .font(.callout)
            Spacer()
            Button("Отменить", action: cancel)
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Добавить" : "Сохранить", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct DestinationIcon: View {
    @Environment(AppModel.self) private var model
    let destination: Destination
    var marksAvailable = true

    var body: some View {
        let condition = model.condition(of: destination)
        Image(systemName: StatusStyle.symbol(for: destination.kind))
            .foregroundStyle(color(condition))
            .overlay(alignment: .bottomTrailing) {
                if let mark = mark(condition) {
                    Image(systemName: mark)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(color(condition))
                        .background(Circle().fill(.background).padding(-1))
                        .offset(x: 5, y: 4)
                }
            }
    }

    private func color(_ condition: DestinationCondition) -> AnyShapeStyle {
        switch condition {
        case .available: marksAvailable ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary)
        case .offline: AnyShapeStyle(.tertiary)
        case .needsConnection, .unreachable: AnyShapeStyle(.orange)
        }
    }

    private func mark(_ condition: DestinationCondition) -> String? {
        switch condition {
        case .available: marksAvailable ? "checkmark.circle.fill" : nil
        case .offline: "minus.circle.fill"
        case .needsConnection: "clock.fill"
        case .unreachable: "exclamationmark.circle.fill"
        }
    }
}
