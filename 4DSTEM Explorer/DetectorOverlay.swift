//
//  DetectorOverlay 2.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 2/18/26.
//  Copyright © 2026 The LeBeau Group. All rights reserved.
//

import SwiftUI


struct DetectorOverlay: View {
    let shape: DetectorShape
    let inner: CGFloat
    let outer: CGFloat
    let center: CGPoint  // image-space coordinates (column, row-from-bottom)
    let tintColor: Color
    let patternWidth: Int
    let patternHeight: Int
    @State private var centerViewPoint: CGPoint? = nil
    @State private var isDraggingFromDetector: Bool = false
    @FocusState private var isFocused: Bool
    @Binding  var showDetector:Bool
    let onCenterChange: (CGPoint, Bool) -> Void
    let imageSizeProvider: () -> (width: Int, height: Int)

    var body: some View {
        GeometryReader { geo in
            let viewSize = geo.size
            let imgW = CGFloat(max(patternWidth, 1))
            let imgH = CGFloat(max(patternHeight, 1))
            let imageAspect = imgW / imgH
            let viewAspect = viewSize.width / max(viewSize.height, 1)
            let drawRect: CGRect = {
                if imageAspect > viewAspect {
                    let drawHeight = viewSize.width / imageAspect
                    let yOffset = (viewSize.height - drawHeight) / 2.0
                    return CGRect(x: 0, y: yOffset, width: viewSize.width, height: drawHeight)
                } else {
                    let drawWidth = viewSize.height * imageAspect
                    let xOffset = (viewSize.width - drawWidth) / 2.0
                    return CGRect(x: xOffset, y: 0, width: drawWidth, height: viewSize.height)
                }
            }()
            // Convert saved image-space center to view space
            let savedViewCenter: CGPoint = {
                let normX = center.x / CGFloat(max(patternWidth - 1, 1))
                let normY = 1 - center.y / CGFloat(max(patternHeight - 1, 1))
                return CGPoint(
                    x: drawRect.minX + normX * drawRect.width,
                    y: drawRect.minY + normY * drawRect.height
                )
            }()
            let displayCenter = centerViewPoint ?? savedViewCenter
            let scale = min(drawRect.width / imgW, drawRect.height / imgH)
            let innerR = max(0, inner) * scale
            let outerR = max(0, outer) * scale

            // Returns true if a view-space point is on or inside the detector circle(s)
            let hitTest: (CGPoint) -> Bool = { point in
                let dx = point.x - displayCenter.x
                let dy = point.y - displayCenter.y
                let dist = sqrt(dx * dx + dy * dy)
                let tolerance: CGFloat = 10
                switch shape {
                case .bf:  return dist <= outerR + tolerance
                case .adf: return dist <= innerR + tolerance
                case .af:  return dist <= outerR + tolerance
                default:   return false
                }
            }
            
            if showDetector{
                ZStack {
                    switch shape {
                    case .bf, .adf:
                        let r = shape == .bf ? outerR : innerR
                        Circle().stroke(style: StrokeStyle(lineWidth: 2)).foregroundStyle(tintColor.opacity(0.9)).frame(width: r * 2, height: r * 2).position(displayCenter)
                    case .af:
                        Circle().stroke(style: StrokeStyle(lineWidth: 2)).foregroundStyle(tintColor.opacity(0.9)).frame(width: innerR * 2, height: innerR * 2).position(displayCenter)
                        Circle().stroke(style: StrokeStyle(lineWidth: 2)).foregroundStyle(tintColor.opacity(0.9)).frame(width: outerR * 2, height: outerR * 2).position(displayCenter)
                    default: EmptyView()
                    }

                    let crossSize: CGFloat = 4
                    Path { path in
                        path.move(to: CGPoint(x: displayCenter.x - crossSize, y: displayCenter.y))
                        path.addLine(to: CGPoint(x: displayCenter.x + crossSize, y: displayCenter.y))
                        path.move(to: CGPoint(x: displayCenter.x, y: displayCenter.y - crossSize))
                        path.addLine(to: CGPoint(x: displayCenter.x, y: displayCenter.y + crossSize))
                    }
                    .stroke(tintColor.opacity(0.9), lineWidth: 2)
                }
                .contentShape(Rectangle())
                .focusable()
                .focused($isFocused)
                .focusEffectDisabled()
                .onTapGesture {
                    isFocused = true
                }
                .simultaneousGesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { value in
                            isFocused = true
                            let x = min(max(value.location.x, drawRect.minX), drawRect.maxX)
                            let y = min(max(value.location.y, drawRect.minY), drawRect.maxY)
                            centerViewPoint = CGPoint(x: x, y: y)
                            let normX = (x - drawRect.minX) / max(drawRect.width, 1)
                            let normY = (y - drawRect.minY) / max(drawRect.height, 1)
                            let j = Int(round(normX * CGFloat(max(patternWidth - 1, 0))))
                            let i = Int(round((1 - normY) * CGFloat(max(patternHeight - 1, 0))))
                            onCenterChange(CGPoint(x: j, y: i), false)
                        }
                )
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            if !isDraggingFromDetector {
                                guard hitTest(value.startLocation) else { return }
                                isDraggingFromDetector = true
                            }
                            isFocused = true
                            // Clamp to drawRect
                            let x = min(max(value.location.x, drawRect.minX), drawRect.maxX)
                            let y = min(max(value.location.y, drawRect.minY), drawRect.maxY)
                            centerViewPoint = CGPoint(x: x, y: y)
                            // Map to image indices and notify
                            let imgW = max(patternWidth, 1)
                            let imgH = max(patternHeight, 1)
                            let normX = (x - drawRect.minX) / max(drawRect.width, 1)
                            let normY = (y - drawRect.minY) / max(drawRect.height, 1)
                            let j = Int(round(normX * CGFloat(max(imgW - 1, 0))))
                            let i = Int(round((1 - normY) * CGFloat(max(imgH - 1, 0))))
                            onCenterChange(CGPoint(x: j, y: i), true)
                        }
                        .onEnded { value in
                            defer { isDraggingFromDetector = false }
                            guard isDraggingFromDetector else { return }
                            // Final notification on end
                            let x = min(max((centerViewPoint ?? savedViewCenter).x, drawRect.minX), drawRect.maxX)
                            let y = min(max((centerViewPoint ?? savedViewCenter).y, drawRect.minY), drawRect.maxY)
                            let normX = (x - drawRect.minX) / max(drawRect.width, 1)
                            let normY = (y - drawRect.minY) / max(drawRect.height, 1)
                            let imgW = max(patternWidth, 1)
                            let imgH = max(patternHeight, 1)
                            let j = Int(round(normX * CGFloat(max(imgW - 1, 0))))
                            let i = Int(round((1 - normY) * CGFloat(max(imgH - 1, 0))))
                            onCenterChange(CGPoint(x: j, y: i), false)
                        }
                )
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { keyPress in
                    let pixelW = drawRect.width / imgW
                    let pixelH = drawRect.height / imgH
                    var pt = centerViewPoint ?? savedViewCenter

                    switch keyPress.key {
                    case .leftArrow:  pt.x -= pixelW
                    case .rightArrow: pt.x += pixelW
                    case .upArrow:    pt.y -= pixelH
                    case .downArrow:  pt.y += pixelH
                    default:          return .ignored
                    }

                    pt.x = min(max(pt.x, drawRect.minX), drawRect.maxX)
                    pt.y = min(max(pt.y, drawRect.minY), drawRect.maxY)
                    centerViewPoint = pt

                    let normX = (pt.x - drawRect.minX) / max(drawRect.width, 1)
                    let normY = (pt.y - drawRect.minY) / max(drawRect.height, 1)
                    let j = Int(round(normX * CGFloat(max(patternWidth - 1, 0))))
                    let i = Int(round((1 - normY) * CGFloat(max(patternHeight - 1, 0))))
                    onCenterChange(CGPoint(x: j, y: i), false)
                    return .handled
                }
            }}
    }
}
