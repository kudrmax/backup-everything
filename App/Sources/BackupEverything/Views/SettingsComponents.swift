import BackupCore
import SwiftUI

struct EditorLayout<Item: Identifiable, Label: View, AddMenu: View, Detail: View>: View where Item.ID == UUID {
    let items: [Item]
    @Binding var selection: UUID?
    var reorder: (([UUID]) -> Void)? = nil
    @ViewBuilder let label: (Item) -> Label
    @ViewBuilder let addMenu: AddMenu
    @ViewBuilder let detail: Detail

    @State private var dragged: UUID?
    @State private var target: DropTarget?

    private enum DropTarget: Equatable {
        case item(UUID)
        case end
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        row(item)
                    }
                    addButton
                        .overlay(alignment: .top) { dropLine(visible: target == .end && dragged != items.last?.id) }
                        .dropDestination(for: String.self) { payload, _ in
                            drop(payload) { ListOrder.movingToEnd($0, in: ids) }
                        } isTargeted: { track(.end, $0) }
                }
                .padding(10)
            }
            .frame(width: 200)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var ids: [UUID] { items.map(\.id) }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        let listItem = EditorListItem(isSelected: selection == item.id) { selection = item.id } label: { label(item) }
        if reorder == nil {
            listItem
        } else {
            listItem
                .opacity(dragged == item.id && target != nil ? 0.4 : 1)
                .overlay(alignment: lineEdge(for: item.id)) { dropLine(visible: target == .item(item.id) && dragged != item.id) }
                .onDrag {
                    dragged = item.id
                    return NSItemProvider(object: item.id.uuidString as NSString)
                }
                .dropDestination(for: String.self) { payload, _ in
                    drop(payload) { ListOrder.moving($0, onto: item.id, in: ids) }
                } isTargeted: { track(.item(item.id), $0) }
        }
    }

    private var addButton: some View {
        Menu {
            addMenu
        } label: {
            SwiftUI.Label("Добавить", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .pointing()
        .menuIndicator(.hidden)
        .foregroundStyle(.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    /// Элемент встаёт на место того, на который его бросили: снизу — над ним, сверху — под ним.
    private func lineEdge(for id: UUID) -> Alignment {
        guard let dragged, let from = ids.firstIndex(of: dragged), let to = ids.firstIndex(of: id) else { return .top }
        return from < to ? .bottom : .top
    }

    private func dropLine(visible: Bool) -> some View {
        Capsule()
            .fill(.tint)
            .frame(height: 2)
            .opacity(visible ? 1 : 0)
    }

    private func track(_ place: DropTarget, _ isTargeted: Bool) {
        if isTargeted {
            target = place
        } else if target == place {
            target = nil
        }
    }

    private func drop(_ payload: [String], order: (UUID) -> [UUID]?) -> Bool {
        defer {
            dragged = nil
            target = nil
        }
        guard let reorder, let id = payload.first.flatMap(UUID.init(uuidString:)), let newOrder = order(id) else { return false }
        withAnimation(.snappy) { reorder(newOrder) }
        return true
    }
}

struct EditorListItem<Label: View>: View {
    let isSelected: Bool
    let select: () -> Void
    @ViewBuilder let label: Label

    @State private var isHovered = false

    var body: some View {
        // Не кнопка: кнопка на macOS не даёт начать перетаскивание строки.
        label
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, select)
            .pointing()
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
    var isNameEditable = true
    @ViewBuilder let icon: Icon
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            icon
                .font(.title3)
                .frame(width: 30)
            if isNameEditable {
                TextField("", text: $name, prompt: Text(prompt))
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
            } else {
                Text(name)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hoverTip("Название задаётся при добавлении и не меняется: по нему названа папка с копиями")
            }
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
            .buttonStyle(.plainPointing)
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
        .buttonStyle(.plainPointing)
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
    /// Без меток в углу: состояние видно только по цвету — для строки назначений, где рядом есть текст.
    var showsMarks = true

    var body: some View {
        let condition = model.condition(of: destination)
        Image(systemName: StatusStyle.symbol(for: destination.kind))
            .foregroundStyle(color(condition))
            .overlay(alignment: .bottomTrailing) {
                if showsMarks, let mark = mark(condition) {
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
        case .available: showsMarks ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary)
        case .offline: AnyShapeStyle(.tertiary)
        case .needsConnection, .unreachable: AnyShapeStyle(.orange)
        }
    }

    private func mark(_ condition: DestinationCondition) -> String? {
        switch condition {
        case .available: "checkmark.circle.fill"
        case .offline: "minus.circle.fill"
        case .needsConnection: "clock.fill"
        case .unreachable: "exclamationmark.circle.fill"
        }
    }
}
