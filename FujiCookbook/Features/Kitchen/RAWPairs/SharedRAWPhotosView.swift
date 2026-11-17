import SwiftUI

/// The photos shared with the app that carry a RAF, newest first, and Apple's screen to share
/// more. Apple's screen reports only photos newly added in it, so photos shared earlier are chosen
/// here (iPhone 14 Pro, iOS 27.0.1, 2026-11-13).
struct SharedRAWPhotosView: View {
    let model: RAWPairPickerModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.photoLibrary) private var library
    @State private var selectingMore = false
    /// What Apple's screen last reported, chosen in a task the view owns.
    @State private var newlyShared: NewlyShared?

    private struct NewlyShared: Equatable {
        let id = UUID()
        let ids: [String]
    }

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 4)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.hasLoaded, model.shared.photos.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(model.shared.photos) { photo in
                            SharedRAWPhotoCell(photo: photo, position: model.selection.position(of: photo.id),
                                               library: library) { model.toggle(photo.id) }
                        }
                    }
                }
                footnotes
            }
            .padding(16)
        }
        .background(Theme.paper)
        .navigationTitle("RAW+JPEG Photos")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(model.chosenCount > 1 ? "Add (\(model.chosenCount))" : "Add") { model.add() }
                    .disabled(model.chosenCount == 0)
            }
        }
        .sensoryFeedback(.selection, trigger: model.selection)
        .background {
            LimitedSelectionPresenter(isPresented: $selectingMore, library: library) { ids in
                newlyShared = NewlyShared(ids: ids)
            }
        }
        .task(id: newlyShared?.id) {
            guard let newlyShared else { return }
            await model.choose(newlyShared: newlyShared.ids)
        }
        .task { await model.load() }
        .task { await model.followChanges() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Photos you've shared with Fuji Cookbook. Choose the ones to develop.")
                .font(.subheadline)
                .foregroundStyle(Theme.ink2)
            if !model.shared.photos.isEmpty {
                Button { selectingMore = true } label: {
                    Label("Select More Photos…", systemImage: "plus.circle")
                }
                .buttonStyle(.outline)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No RAW+JPEG Photos Yet", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Select the RAW+JPEG photos you want to develop. Fuji Cookbook sees only the ones you select.")
        } actions: {
            Button { selectingMore = true } label: {
                Label("Select Photos…", systemImage: "plus.circle")
            }
            .buttonStyle(.outline)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    @ViewBuilder
    private var footnotes: some View {
        if case .limitReached(let limit) = model.refusal {
            Label("You can add up to \(limit) file\(limit == 1 ? "" : "s").", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(Theme.warning)
                .transition(.opacity)
        }
        if model.shared.invalid > 0 {
            let count = model.shared.invalid
            Text("\(count) photo\(count == 1 ? "" : "s") you've shared \(count == 1 ? "holds" : "hold") two RAW files or two JPEG files, so \(count == 1 ? "it isn't" : "they aren't") shown: the app can't tell which one to develop.")
                .font(.footnote)
                .foregroundStyle(Theme.ink3)
        }
        if model.shared.withoutRAW > 0 {
            let count = model.shared.withoutRAW
            Text("\(count) photo\(count == 1 ? "" : "s") you've shared \(count == 1 ? "has" : "have") no Fujifilm RAW and \(count == 1 ? "isn't" : "aren't") shown.")
                .font(.footnote)
                .foregroundStyle(Theme.ink3)
        }
    }
}

/// One shared photo: its thumbnail, what it holds, when it was taken, and its place in the choice.
private struct SharedRAWPhotoCell: View {
    let photo: SharedRAWPhoto
    /// 1-based place in the choice; nil when not chosen.
    let position: Int?
    let library: any PhotoLibraryAccessing
    let onTap: () -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var thumbnail: UIImage?

    private static let side: CGFloat = 120

    var body: some View {
        Button(action: onTap) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Theme.paper2
                    }
                }
                .clipped()
                .overlay(alignment: .bottomLeading) { kindBadge }
                .overlay(alignment: .topTrailing) { selectionMark }
                .overlay {
                    if position != nil {
                        Rectangle().strokeBorder(Theme.accent, lineWidth: 3)
                    }
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: position)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(position.map { "Chosen, number \($0)" } ?? "")
        .accessibilityAddTraits(position != nil ? .isSelected : [])
        .task(id: photo.id) {
            thumbnail = await library.thumbnail(for: photo.id, side: Self.side * displayScale)
        }
    }

    private var kindBadge: some View {
        Text(photo.kind == .pair ? "RAW+JPEG" : "RAW")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(5)
            .accessibilityHidden(true)
    }

    private var selectionMark: some View {
        ZStack {
            if let position {
                Circle().fill(Theme.accent)
                Text("\(position)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.onAccent)
            } else {
                Circle().strokeBorder(.white, lineWidth: 1.5)
                    .background(Circle().fill(.black.opacity(0.15)))
            }
        }
        .frame(width: 24, height: 24)
        .padding(6)
        .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        let kind = photo.kind == .pair ? "RAW+JPEG photo" : "RAW photo"
        guard let date = photo.creationDate else { return kind }
        return "\(kind), \(date.formatted(date: .long, time: .shortened))"
    }
}

/// Presents Apple's limited-library selection screen, which needs a view controller in the
/// hierarchy, and hands back the identifiers of the photos newly selected in it.
struct LimitedSelectionPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let library: any PhotoLibraryAccessing
    let onSelect: ([String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard isPresented, !context.coordinator.isPresenting else { return }
        context.coordinator.isPresenting = true
        let coordinator = context.coordinator
        let presented = $isPresented
        let onSelect = onSelect
        library.presentSelection(from: controller) { identifiers in
            coordinator.isPresenting = false
            presented.wrappedValue = false
            onSelect(identifiers)
        }
    }

    final class Coordinator {
        var isPresenting = false
    }
}
