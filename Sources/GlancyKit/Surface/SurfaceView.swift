import SwiftUI

/// The root of one surface window: the black shape, flush with the top edge. The view is laid out
/// centred on the notch (see `SurfaceLayout.hostFrame`); the shape sits `layout.shift` off it when
/// one wing is narrower than the other.
/// Collapsed it holds only the wings / peek content; the expanded panel exists only while open.
public struct SurfaceView: View {
    let model: SurfaceModel
    let context: SurfaceContext

    public init(model: SurfaceModel, context: SurfaceContext) {
        self.model = model; self.context = context
    }

    public var body: some View {
        let layout = model.layout
        NotchBody(model: model, context: context, layout: layout)
            .offset(x: layout.shift)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
    }
}

private struct NotchBody: View {
    let model: SurfaceModel
    let context: SurfaceContext
    let layout: SurfaceLayout

    var body: some View {
        let shape = NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius,
                               bandInsetLeft: layout.bandInsetLeft, bandInsetRight: layout.bandInsetRight, bandHeight: layout.bandHeight)
        ZStack(alignment: .top) {
            if model.expanded {
                ExpandedPanel(model: model, context: context)
                    .frame(width: layout.size.width, height: layout.size.height)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.9, anchor: .top).combined(with: .opacity),
                        removal: .opacity.animation(.easeOut(duration: 0.12))))
            } else {
                CollapsedContent(model: model, hub: context.hub, layout: layout)
                    .transition(.opacity)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
        .clipShape(shape)
        .background {
            // The black body, with its shadow (expanded only) on the shape alone, never on content.
            shape.fill(Color.black)
                .shadow(color: .black.opacity(layout.shadow ? 0.5 : 0), radius: layout.shadow ? 16 : 0, y: layout.shadow ? 8 : 0)
        }
        // 1 pt black cap over the top edge: no hairline seam against the bezel.
        .overlay(alignment: .top) {
            Rectangle().fill(Color.black).frame(width: max(0, layout.size.width - 2 * layout.topRadius - layout.bandInsetLeft - layout.bandInsetRight), height: 1)
                .offset(x: (layout.bandInsetLeft - layout.bandInsetRight) / 2)
        }
    }
}

// MARK: - Collapsed

private struct CollapsedContent: View {
    let model: SurfaceModel
    let hub: ActivityHub
    let layout: SurfaceLayout

    var body: some View {
        let notch = model.geometry.notchRect.size
        let state = model.state
        ZStack(alignment: .top) {
            Wings(model: model, hub: hub, layout: layout, notch: notch,
                  visible: state == .activity || ((state == .peek || state == .peekEvent) && layout.wing > 0))
            if state == .peek {
                // A hint of what's below: a small grabber, nothing else.
                Capsule().fill(Theme.tertiary)
                    .frame(width: 18, height: 3)
                    .padding(.top, notch.height + 1)
                    .transition(.opacity)
            }
            PeekDrop(model: model, hub: hub, notch: notch, visible: state == .peekEvent)
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
    }
}

/// Left and right wings beside the notch. The content is measured at its ideal size; the model
/// turns that into a wing width (capped) and the shape grows to it.
private struct Wings: View {
    let model: SurfaceModel
    let hub: ActivityHub
    let layout: SurfaceLayout
    let notch: CGSize
    let visible: Bool

    @State private var left: CGFloat = 0
    @State private var right: CGFloat = 0

    var body: some View {
        let top = hub.top
        let slot = layout.slots(notchWidth: notch.width)
        HStack(spacing: 0) {
            // A side kept clear of the menu bar still measures its content, but shows none.
            wingSlot(top?.left, width: slot.left, outerLeading: true)
                .opacity(layout.wingLeft > 0 ? 1 : 0)
            Color.clear.frame(width: notch.width)
            wingSlot(top?.right, width: slot.right, outerLeading: false)
                .opacity(layout.wingRight > 0 ? 1 : 0)
        }
        .frame(height: notch.height)
        .opacity(visible ? 1 : 0)
        // Nothing to show: retract now. Something new: wait for its measurement (below).
        .onChange(of: top?.id, initial: true) { if top == nil { report(nil) } }
    }

    @ViewBuilder
    private func wingSlot(_ content: AnyView?, width: CGFloat, outerLeading: Bool) -> some View {
        ZStack {
            if let content {
                content
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                        if outerLeading { left = w } else { right = w }
                        report(hub.top)
                    }
                    .id(hub.top?.id)
                    .padding(outerLeading ? .leading : .trailing, SurfaceLayout.wingOuterPad - 4)
                    .padding(outerLeading ? .trailing : .leading, SurfaceLayout.wingInnerGap - 4)
                    .transition(.blurFade)
            }
        }
        .frame(width: width, height: notch.height)
        .clipped()
    }

    private func report(_ top: LiveActivity?) {
        model.setActivity(present: top != nil, left: left, right: right)
    }
}

/// The event drop-down: content measured first, then the shape drops ~32 pt to show it.
private struct PeekDrop: View {
    let model: SurfaceModel
    let hub: ActivityHub
    let notch: CGSize
    let visible: Bool

    var body: some View {
        let peek = hub.peek
        ZStack {
            if let peek {
                peek.content
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                        model.showPeek(peek.id, contentWidth: w)
                    }
                    .id(peek.id)
                    .transition(.blurFade)
            }
        }
        .frame(height: Theme.peekEventDrop)
        .padding(.top, notch.height - 2)
        .opacity(visible ? 1 : 0)
        .onChange(of: peek?.id, initial: true) { if peek == nil { model.showPeek(nil, contentWidth: 0) } }
    }
}
