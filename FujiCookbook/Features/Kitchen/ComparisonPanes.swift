import SwiftUI
import UIKit

// The side-by-side machinery behind `ComparisonViewer`.
//
// Judging one recipe against another means looking at the *same* part of the *same* frame in each
// version, so every pane on screen shares one zoom and one pan: pinch into the shadows of one and
// all of them follow. That rules out `ZoomableImage` (`UIKitBridges.swift`), which is a
// `UIViewRepresentable` around a `UIScrollView` that owns its zoom state privately — two of them
// cannot be kept in step. So the transform lives here, in SwiftUI, as a value the panes share.

/// The zoom and pan every pane on screen applies. One value, many panes — that's the whole point.
struct SyncedTransform: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    static let maxScale: CGFloat = 6
    /// What a double-tap zooms to — enough to judge grain without hunting for the frame edge.
    static let doubleTapScale: CGFloat = 2.5

    var isZoomed: Bool { scale > 1.01 }

    mutating func reset() {
        scale = 1
        offset = .zero
    }
}

/// One version rendered under the shared transform.
///
/// Zoom state has to live here rather than in a modifier: `@GestureState` projects a
/// `GestureState`, not a `Binding`, so it can't be handed across a view boundary — and the pane
/// needs the in-flight values to draw with anyway.
struct ComparisonPane: View {
    let image: UIImage?
    @Binding var transform: SyncedTransform
    /// Caption drawn over the bottom-left corner. Omitted in Swipe, where the caption bar names the
    /// version, and in A|B, which tags its own top corners.
    var label: String?
    /// Tiled mode uses this to jump to the tapped version full-screen.
    var onTap: (() -> Void)?
    /// What VoiceOver calls the pane, where `label` isn't drawn or doesn't say enough.
    var accessibilityName: String?

    @GestureState private var liveZoom: CGFloat = 1
    @GestureState private var liveDrag: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let scale = transform.scale * liveZoom
            let offset = CGSize(width: transform.offset.width + liveDrag.width,
                                height: transform.offset.height + liveDrag.height)
            gestured(
                content
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .clipped()
                    .contentShape(Rectangle()),
                paneSize: size
            )
            .overlay { labelOverlay(in: size) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName ?? label ?? "Developed photo")
        .accessibilityAddTraits(onTap == nil ? .isImage : [.isImage, .isButton])
        .accessibilityAction { onTap?() }
        // Pinch and double-tap have no VoiceOver equivalent of their own.
        .accessibilityAction(named: transform.isZoomed ? "Zoom to Fit" : "Zoom In") { doubleTap() }
    }

    /// The pan is attached only while zoomed in. At fit scale a horizontal drag has to reach the
    /// paged TabView underneath, or swiping between versions stops working — the same conflict
    /// `ZoomableImage` settles by turning off its scroll view's bounce.
    @ViewBuilder
    private func gestured(_ view: some View, paneSize: CGSize) -> some View {
        Group {
            if transform.isZoomed {
                view.gesture(drag(paneSize)).gesture(magnify(paneSize))
            } else {
                view.gesture(magnify(paneSize))
            }
        }
        .onTapGesture(count: 2) { doubleTap() }
        .onTapGesture { onTap?() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundStyle(Theme.ink3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Anchored to the photo, not to the pane. `scaledToFit` letterboxes a 3:2 frame inside a
    /// full-width pane, so a plain bottom-leading overlay would leave the name floating in the black
    /// bar beside the image rather than sitting on it.
    @ViewBuilder
    private func labelOverlay(in paneSize: CGSize) -> some View {
        if let label {
            let fitted = fittedSize(in: paneSize)
            Color.clear
                .frame(width: fitted.width, height: fitted.height)
                .overlay(alignment: .bottomLeading) {
                    PaneTag(text: label)
                        .padding(8)
                }
                .allowsHitTesting(false)
        }
    }

    // MARK: Gestures

    private func magnify(_ paneSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($liveZoom) { value, state, _ in state = value.magnification }
            .onEnded { value in
                transform.scale = min(max(transform.scale * value.magnification, 1), SyncedTransform.maxScale)
                if !transform.isZoomed { transform.offset = .zero }
                transform.offset = clampOffset(transform.offset, scale: transform.scale, paneSize: paneSize)
            }
    }

    private func drag(_ paneSize: CGSize) -> some Gesture {
        DragGesture()
            .updating($liveDrag) { value, state, _ in state = value.translation }
            .onEnded { value in
                let moved = CGSize(width: transform.offset.width + value.translation.width,
                                   height: transform.offset.height + value.translation.height)
                transform.offset = clampOffset(moved, scale: transform.scale, paneSize: paneSize)
            }
    }

    private func doubleTap() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if transform.isZoomed {
                transform.reset()
            } else {
                transform.scale = SyncedTransform.doubleTapScale
                transform.offset = .zero
            }
        }
    }

    /// Keep the frame from being dragged off its own pane: travel is limited to the overhang the
    /// zoom actually created.
    private func clampOffset(_ offset: CGSize, scale: CGFloat, paneSize: CGSize) -> CGSize {
        let fitted = fittedSize(in: paneSize)
        let overhangX = max(0, (fitted.width * scale - paneSize.width) / 2)
        let overhangY = max(0, (fitted.height * scale - paneSize.height) / 2)
        return CGSize(width: min(max(offset.width, -overhangX), overhangX),
                      height: min(max(offset.height, -overhangY), overhangY))
    }

    /// The image's size once `scaledToFit` has letterboxed it into the pane.
    private func fittedSize(in paneSize: CGSize) -> CGSize {
        guard let imageSize = image?.size,
              imageSize.width > 0, imageSize.height > 0,
              paneSize.width > 0, paneSize.height > 0 else { return paneSize }
        let ratio = min(paneSize.width / imageSize.width, paneSize.height / imageSize.height)
        return CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
    }
}

// MARK: - Curtain

/// Two versions in one frame, split by a draggable divider. Both are pixel-aligned and identically
/// transformed, so the seam is what makes a small shift in colour or tone obvious — the difference
/// lands as an edge rather than as something you have to hold in memory between two swipes.
struct CurtainComparison: View {
    let leading: ComparisonItem
    let trailing: ComparisonItem
    @Binding var transform: SyncedTransform
    /// Divider position as a fraction of the width.
    @Binding var position: CGFloat

    /// Drags report their location in this space, so the maths is container-relative no matter which
    /// subview the gesture is attached to.
    private static let space = "curtain"

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = width * position
            ZStack(alignment: .topLeading) {
                ComparisonPane(image: trailing.image, transform: $transform,
                               accessibilityName: "\(trailing.label), right of the divider")
                ComparisonPane(image: leading.image, transform: $transform,
                               accessibilityName: "\(leading.label), left of the divider")
                    .mask(alignment: .leading) {
                        HStack(spacing: 0) {
                            Rectangle().frame(width: x)
                            Color.clear
                        }
                    }
                handle(height: geo.size.height, width: width)
                    .position(x: x, y: geo.size.height / 2)
            }
            .coordinateSpace(.named(Self.space))
            // Away from the handle, dragging the photo itself moves the divider too — the way every
            // before/after slider behaves. It has to be *simultaneous*: a plain `.gesture` here sits
            // below the panes' own tap and magnify gestures and never fires. Masked off once zoomed
            // in, where a drag has to pan the photo instead.
            .simultaneousGesture(sweep(width: width),
                                 including: transform.isZoomed ? .subviews : .all)
            .overlay(alignment: .topLeading) { tag(leading.label) }
            .overlay(alignment: .topTrailing) { tag(trailing.label) }
        }
    }

    /// The grab target. Drawn as a hairline and a puck, but hit-tested as a full-height 44pt strip:
    /// a 1.5pt line and a 34pt circle are all but impossible to catch with a thumb.
    private func handle(height: CGFloat, width: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(.white)
                .frame(width: 1.5)
                .shadow(color: .black.opacity(0.5), radius: 2)
            Image(systemName: "arrow.left.and.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(.white, in: Circle())
                .shadow(color: .black.opacity(0.35), radius: 3)
        }
        .frame(width: 44, height: height)
        .contentShape(Rectangle())
        .gesture(drag(width: width, minimumDistance: 0))
        .accessibilityLabel("Comparison divider")
        .accessibilityValue("\(Int(position * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: position = min(position + Self.adjustStep, 1)
            case .decrement: position = max(position - Self.adjustStep, 0)
            @unknown default: break
            }
        }
    }

    /// How far one VoiceOver swipe moves the divider, as a fraction of the width.
    private static let adjustStep: CGFloat = 0.1

    private func sweep(width: CGFloat) -> some Gesture {
        // A little slack so a double-tap to zoom still reads as a tap rather than a drag.
        drag(width: width, minimumDistance: 12)
    }

    private func drag(width: CGFloat, minimumDistance: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: minimumDistance, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard width > 0 else { return }
                position = min(max(value.location.x / width, 0), 1)
            }
    }

    private func tag(_ text: String) -> some View {
        PaneTag(text: text)
            .padding(10)
            .allowsHitTesting(false)
    }
}

/// The recipe name on a comparison pane: white on a dark pill, so it reads over any photo. Where it
/// sits is the pane's call.
private struct PaneTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
    }
}

// MARK: - Tiled

/// Every version at once. Orientation-aware because a phone has no room for three landscape frames
/// in a row: landscape photos stack so each one keeps the full width, portrait photos sit in columns.
struct TiledComparison: View {
    let items: [ComparisonItem]
    @Binding var transform: SyncedTransform
    let stacked: Bool
    let onSelect: (Int) -> Void

    var body: some View {
        Group {
            if stacked {
                VStack(spacing: 2) { panes }
            } else {
                HStack(spacing: 2) { panes }
            }
        }
    }

    private var panes: some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            ComparisonPane(image: item.image,
                           transform: $transform,
                           label: item.label) { onSelect(index) }
        }
    }
}

/// One developed version, prepared for display.
struct ComparisonItem: Identifiable {
    let id: UUID
    let image: UIImage?
    let label: String
}
