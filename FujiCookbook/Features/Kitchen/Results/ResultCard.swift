import SwiftUI
import UIKit

/// One developed photo in Recent Results. A single version is a large photo under its recipe's
/// name; several are a contact sheet, the same frame once per recipe, each named beneath, because
/// the recipe is what was being judged and the file name is only where it came from.
struct ResultCard: View {
    let entry: ResultsGallery.Entry
    let loader: DevelopedImageLoader?

    var body: some View {
        Group {
            if entry.versions.count == 1, let version = entry.versions.first {
                single(version)
            } else {
                contactSheet
            }
        }
        .themedCard(cornerRadius: 18)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func single(_ version: ResultVersion) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DevelopedImage(version: version, loader: loader, maxLongEdge: 1200)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18,
                                                  style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(version.recipeName)
                        .font(Theme.serif(17))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if version.isComparisonPreview { BadgeTag(text: "Preview") }
                }
                Text(detail(film: version.filmSimulation))
                    .font(.caption)
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var contactSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(entry.versions) { version in
                    VStack(alignment: .leading, spacing: 5) {
                        DevelopedImage(version: version, loader: loader, maxLongEdge: 600)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text(version.recipeName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let film = version.filmSimulation {
                            Text(film)
                                .font(.caption2)
                                .foregroundStyle(Theme.ink2)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(entry.photo.sourceFilename)
                    .font(.caption)
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if entry.versions.contains(where: \.isComparisonPreview) { BadgeTag(text: "Preview") }
            }
        }
        .padding(10)
    }

    private func detail(film: String?) -> String {
        [film, entry.photo.sourceFilename].compactMap { $0 }.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        let recipes = entry.versions.map(\.recipeName).formatted(.list(type: .and))
        let preview = entry.versions.contains(where: \.isComparisonPreview) ? ", preview" : ""
        return entry.versions.count == 1
            ? "\(recipes), \(entry.photo.sourceFilename)\(preview)"
            : "\(entry.photo.sourceFilename) in \(recipes)\(preview)"
    }
}

/// A developed version at display size: the inline thumbnail at once, then a sharp copy from
/// `DevelopedImageLoader` when one decodes. Landscape frames show at 3:2 and portrait at 4:5,
/// cropped to fill, so a run of cards keeps an even rhythm; the viewer shows the whole frame.
struct DevelopedImage: View {
    let version: ResultVersion
    let loader: DevelopedImageLoader?
    let maxLongEdge: CGFloat

    @State private var sharp: UIImage?

    private var thumbnail: UIImage? { ThumbnailCache.thumbnail(uuid: version.id, data: version.thumbnailData) }

    private var aspectRatio: CGFloat {
        guard let size = (sharp ?? thumbnail)?.size, size.height > 0 else { return 3 / 2 }
        return size.width >= size.height ? 3 / 2 : 4 / 5
    }

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                if let image = sharp ?? thumbnail {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Theme.paper2.overlay { Image(systemName: "photo").foregroundStyle(Theme.ink3) }
                }
            }
            .clipped()
            .task(id: version.id) {
                guard sharp == nil, let loader else { return }
                sharp = await loader.image(for: version.id, maxLongEdge: maxLongEdge)
            }
    }
}
