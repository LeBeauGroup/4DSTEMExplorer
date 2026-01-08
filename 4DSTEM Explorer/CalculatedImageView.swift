import SwiftUI

/// Cross-platform convenience type to hold platform images
#if canImport(UIKit)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif



struct CalculatedImageView: View {
    
    /// The platform image used for sizing and creating the SwiftUI Image
    let platformImage: PlatformImage
    
    let imageWidth: Int
    let imageHeight: Int
    let selectionRectImageSpace: CGRect?
    let onUpdateRectImageSpace: (CGRect) -> Void
    
    @Binding var zoomScale: CGFloat
    @Binding var contentOffset: CGSize
    
    @State private var lastScale: CGFloat = 1.0

    // The scale used to make the image initially fit the container (computed)
    @State private var initialFitScale: CGFloat = 1.0

    private let minScale: CGFloat = 0.25
    private let maxScale: CGFloat = 250.0
    private let zoomStep: CGFloat = 1.8
    

    // intrinsic image size in points (from platform image)
    private var intrinsicSize: CGSize {
        #if canImport(UIKit)
        return platformImage.size
        #else
        // NSImage.size is in points already
        return platformImage.size
        #endif
    }
    

    var body: some View {
            GeometryReader { geo in
                
                let containerSize = geo.size
                let imageSize = CGSize(width: intrinsicSize.width * initialFitScale * zoomScale,
                                                  height: intrinsicSize.height * initialFitScale * zoomScale)

                        // Outer scrollview that scrolls once content is larger than viewport
                        ScrollView([.horizontal, .vertical]) {
                            // center the content horizontally/vertically when smaller than viewport
                            HStack {
                                Spacer(minLength: 0)
                                VStack {
                                    Spacer(minLength: 0)

                                    ZStack {
                                        image
                                            .resizable()
                                            // Use the intrinsic size multiplied by the **combined scale**:
                                            // - initialFitScale makes the image fit the container at start
                                            // - zoomScale multiplies that for user zooming (pinch/keyboard)
                                            .frame(
                                                width: intrinsicSize.width * initialFitScale * zoomScale,
                                                height: intrinsicSize.height * initialFitScale * zoomScale
                                            )
                                            .animation(.easeInOut(duration: 0.12), value: zoomScale)
                                            .gesture(
                                                MagnificationGesture()
                                                    .onChanged { value in
                                                        // value is multiplicative relative to gesture start
                                                        let candidate = lastScale * value
                                                        zoomScale = clampedScale(candidate)
                                                    }
                                                    .onEnded { _ in
                                                        lastScale = zoomScale
                                                    }
                                            )
                                            .onAppear {
                                                // compute initialFitScale to fit the image inside the available container while preserving aspect ratio
                                                let containerSize = geo.size
                                                let wRatio = containerSize.width / intrinsicSize.width
                                                let hRatio = containerSize.height / intrinsicSize.height
                                                // choose the smaller ratio so the whole image fits inside; don't upscale initially
                                                let fit = min(wRatio, hRatio, 1.0)
                                                initialFitScale = fit
                                                // set zoomScale and gesture baseline
                                                zoomScale = 1.0
                                                lastScale = 1.0
                                            }

                                        SelectionOverlay(
                                            imageWidth: imageWidth,
                                            imageHeight: imageHeight,
                                            selectionRectImageSpace: selectionRectImageSpace,
                                            onUpdateRectImageSpace: onUpdateRectImageSpace,
                                            viewSize: CGSize(
                                                width: intrinsicSize.width * initialFitScale * zoomScale,
                                                height: intrinsicSize.height * initialFitScale * zoomScale
                                            ),
                                            zoomScale: zoomScale
                                        )
                                    }
                                    .frame(
                                        width: intrinsicSize.width * initialFitScale * zoomScale,
                                        height: intrinsicSize.height * initialFitScale * zoomScale
                                    )
                                    .allowsHitTesting(true)

                                    Spacer(minLength: 0)
                                }
                                Spacer(minLength: 0)
                            }
                            // make ScrollView content take the whole container initially, so centering works
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                        }
                        .background(Color.black.opacity(0.02))
                        .onReceive(NotificationCenter.default.publisher(for: .zoomIn)) { _ in
                            zoomBy(factor: zoomStep, containerSize: containerSize)
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .zoomOut)) { _ in
                            zoomBy(factor: 1.0 / zoomStep, containerSize: containerSize)
                        }
                    }
    }
    
    private var image: Image {
        #if canImport(UIKit)
        Image(uiImage: platformImage)
        #else
        Image(nsImage: platformImage)
        #endif
    }

        private func clampedScale(_ s: CGFloat) -> CGFloat {
            min(max(s, minScale), maxScale)
        }

    private func zoomBy(factor: CGFloat, containerSize: CGSize) {
        let oldScale = zoomScale
        let newScale = clampedScale(zoomScale * factor)

        guard abs(newScale - oldScale) > 0.0001 else { return }

        let scaleFactor = newScale / oldScale

        zoomScale = newScale
        lastScale = newScale
    }
    

}

extension Notification.Name {
    static let zoomIn  = Notification.Name("SwiftUIZoomIn")
    static let zoomOut = Notification.Name("SwiftUIZoomOut")
}

// Copied SelectionOverlay from RootView.swift and made it non-private for use here
struct SelectionOverlay: View {
    let imageWidth: Int
    let imageHeight: Int
    let selectionRectImageSpace: CGRect?
    let onUpdateRectImageSpace: (CGRect) -> Void
    let viewSize: CGSize
    let zoomScale: CGFloat

    @State private var dragOffset = CGSize.zero
    @State private var dragStartRect: CGRect? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let selectionRectImageSpace = selectionRectImageSpace {
                    let scaleX = viewSize.width / CGFloat(imageWidth)
                    let scaleY = viewSize.height / CGFloat(imageHeight)

                    let rectViewSpace = CGRect(
                        x: selectionRectImageSpace.origin.x * scaleX,
                        y: selectionRectImageSpace.origin.y * scaleY,
                        width: selectionRectImageSpace.size.width * scaleX,
                        height: selectionRectImageSpace.size.height * scaleY
                    )

                    Rectangle()
                        .path(in: rectViewSpace)
                        .stroke(Color.blue, lineWidth: 2)
                        .background(Color.blue.opacity(0.2).mask(Rectangle().path(in: rectViewSpace)))
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    var newOrigin = CGPoint(
                                        x: (dragStartRect?.origin.x ?? rectViewSpace.origin.x) + value.translation.width,
                                        y: (dragStartRect?.origin.y ?? rectViewSpace.origin.y) + value.translation.height
                                    )

                                    // Clamp newOrigin so rectangle stays inside the image bounds
                                    newOrigin.x = max(0, min(newOrigin.x, viewSize.width - rectViewSpace.width))
                                    newOrigin.y = max(0, min(newOrigin.y, viewSize.height - rectViewSpace.height))

                                    let newRectViewSpace = CGRect(origin: newOrigin, size: rectViewSpace.size)

                                    // Convert back to image space
                                    let newRectImageSpace = CGRect(
                                        x: newRectViewSpace.origin.x / scaleX,
                                        y: newRectViewSpace.origin.y / scaleY,
                                        width: newRectViewSpace.size.width / scaleX,
                                        height: newRectViewSpace.size.height / scaleY
                                    )

                                    onUpdateRectImageSpace(newRectImageSpace)
                                }
                                .onEnded { _ in
                                    dragStartRect = nil
                                }
                                .onChanged { _ in
                                    if dragStartRect == nil {
                                        dragStartRect = rectViewSpace
                                    }
                                }
                        )
                }
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .allowsHitTesting(true)
    }
}

