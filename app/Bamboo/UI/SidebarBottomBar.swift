import SwiftUI

/// Downloads, the space switcher and the Claude button along the sidebar's foot.
struct SidebarBottomBar: View {
    let model: BrowserWindowModel
    @State private var editorTarget: SpaceEditorTarget?

    var body: some View {
        HStack(spacing: 2) {
            DownloadsButton(model: model)
            Spacer(minLength: 4)
            ForEach(Array(model.spaces.enumerated()), id: \.element.id) { index, space in
                SpaceButton(model: model, space: space, index: index, editorTarget: $editorTarget)
            }
            if !model.isPrivate {
                Button { editorTarget = .new } label: {
                    Image(systemName: "plus").font(.system(size: 11.5, weight: .semibold))
                }
                .help("New Space")
            }
            Spacer(minLength: 4)
            AssistantButton(model: model)
        }
        .buttonStyle(.chrome)
        .frame(height: 30)
        .sheet(item: $editorTarget) { target in
            SpaceEditor(model: model, target: target)
        }
    }
}

private struct SpaceButton: View {
    let model: BrowserWindowModel
    let space: Space
    let index: Int
    @Binding var editorTarget: SpaceEditorTarget?

    var body: some View {
        let isSelected = space.id == model.selectedSpaceID
        Button {
            withAnimation(Theme.Motion.standard) { model.selectSpace(space) }
        } label: {
            Image(systemName: space.symbol)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(Theme.palette(space.tint).accent) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.Colors.selectedRow)
                            .shadow(color: .black.opacity(0.07), radius: 1, y: 0.5)
                    }
                }
        }
        .help(index < 9 ? "\(space.name) (⌃\(index + 1))" : space.name)
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if !model.isPrivate {
                Button("Edit Space…") { editorTarget = .edit(space) }
            }
        }
    }
}

struct DownloadsButton: View {
    let model: BrowserWindowModel
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        let active = AppServices.shared.downloads.items.filter { $0.state == .downloading }
        let progress = active.isEmpty ? 0 : active.map(\.fractionCompleted).reduce(0, +) / Double(active.count)
        Button {
            model.libraryPanel = .downloads
        } label: {
            ZStack {
                if active.isEmpty {
                    Image(systemName: "arrow.down.circle")
                } else {
                    Circle().stroke(Theme.Colors.pressedRow, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(progress, 0.03))
                        .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(Theme.Motion.standard, value: progress)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(accent)
                }
            }
            .frame(width: 16, height: 16)
        }
        .help(active.isEmpty ? "Downloads" : "Downloading \(active.count) \(active.count == 1 ? "file" : "files")")
    }
}

private struct AssistantButton: View {
    let model: BrowserWindowModel
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        Button {
            withAnimation(Theme.Motion.spring) { model.isAssistantVisible.toggle() }
        } label: {
            Image(systemName: "sparkle")
                .foregroundStyle(model.isAssistantVisible ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
        }
        .help(model.isAssistantVisible ? "Hide Claude (⌘J)" : "Ask Claude (⌘J)")
    }
}

// MARK: - Space editor

enum SpaceEditorTarget: Identifiable {
    case new
    case edit(Space)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let space): space.id.uuidString
        }
    }
}

struct SpaceEditor: View {
    let model: BrowserWindowModel
    let target: SpaceEditorTarget
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbol: String
    @State private var tint: SpaceTint
    @State private var profileID: Profile.ID
    @State private var isConfirmingDelete = false

    private static let symbols = [
        "leaf", "house", "briefcase", "book", "graduationcap", "hammer",
        "paintbrush", "music.note", "gamecontroller", "airplane", "cart", "heart",
        "star", "flame", "bolt", "globe", "chevron.left.forwardslash.chevron.right", "camera",
        "film", "newspaper", "dollarsign.circle", "figure.run", "pawprint", "cup.and.saucer",
    ]

    /// The form starts from the edited space's values (or a fresh space's) once;
    /// changes apply only on Save.
    init(model: BrowserWindowModel, target: SpaceEditorTarget) {
        self.model = model
        self.target = target
        let space: Space? = if case .edit(let space) = target { space } else { nil }
        _name = State(initialValue: space?.name ?? "")
        _symbol = State(initialValue: space?.symbol ?? "star")
        _tint = State(initialValue: space?.tint ?? Self.unusedTint(in: model))
        _profileID = State(initialValue: space?.profile.id ?? model.selectedSpace.profile.id)
    }

    private var editedSpace: Space? {
        if case .edit(let space) = target { space } else { nil }
    }

    var body: some View {
        let palette = Theme.palette(tint)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        LinearGradient(colors: palette.gradient, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .animation(Theme.Motion.quick, value: tint)
                TextField("Space name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Icon").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 8), spacing: 6) {
                    ForEach(Self.symbols, id: \.self) { candidate in
                        Button { symbol = candidate } label: {
                            Image(systemName: candidate)
                                .font(.system(size: 14))
                                .foregroundStyle(candidate == symbol ? AnyShapeStyle(palette.accent) : AnyShapeStyle(.secondary))
                                .frame(width: 34, height: 30)
                                .background {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(candidate == symbol ? palette.accent.opacity(0.15) : .clear)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(candidate)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(SpaceTint.allCases, id: \.self) { candidate in
                        Button { tint = candidate } label: {
                            Circle()
                                .fill(LinearGradient(colors: Theme.palette(candidate).gradient,
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 22, height: 22)
                                .padding(3)
                                .overlay {
                                    Circle().strokeBorder(Theme.palette(candidate).accent, lineWidth: 2)
                                        .opacity(candidate == tint ? 1 : 0)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(candidate.rawValue.capitalized)
                        .accessibilityAddTraits(candidate == tint ? .isSelected : [])
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Profile", selection: $profileID) {
                    ForEach(AppServices.shared.profiles.profiles) { profile in
                        Label(profile.name, systemImage: profile.symbol).tag(profile.id)
                    }
                }
                .disabled(editedSpace != nil)
                Text(editedSpace == nil
                     ? "Tabs in this space use the profile's cookies, history and bookmarks."
                     : "A space keeps the profile it was created with.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            HStack {
                if editedSpace != nil, model.spaces.count > 1 {
                    Button("Delete Space…", role: .destructive) { isConfirmingDelete = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editedSpace == nil ? "Create Space" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 400)
        .tint(palette.accent)
        .confirmationDialog("Delete “\(editedSpace?.name ?? "")”?", isPresented: $isConfirmingDelete) {
            Button("Delete Space and Close Its Tabs", role: .destructive) {
                if let editedSpace { model.removeSpace(editedSpace) }
                dismiss()
            }
        } message: {
            let count = editedSpace?.allTabs.count ?? 0
            Text(count == 1 ? "Its tab will be closed." : "Its \(count) tabs will be closed.")
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let editedSpace {
            model.update(editedSpace, name: trimmed, symbol: symbol, tint: tint)
        } else {
            guard let profile = AppServices.shared.profiles.profile(id: profileID) else {
                preconditionFailure("The picked profile \(profileID) is gone")
            }
            withAnimation(Theme.Motion.standard) {
                _ = model.addSpace(name: trimmed, symbol: symbol, tint: tint, profile: profile)
            }
        }
        dismiss()
    }

    private static func unusedTint(in model: BrowserWindowModel) -> SpaceTint {
        let used = Set(model.spaces.map(\.tint))
        return SpaceTint.allCases.first { !used.contains($0) } ?? .bamboo
    }
}
