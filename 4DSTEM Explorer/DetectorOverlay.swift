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
    let isActive: Bool
    @State private var centerViewPoint: CGPoint? = nil
    @State private var isDraggingFromDetector: Bool = false
    @State private var isDraggingOuterHandle: Bool = false
    @State private var isDraggingInnerHandle: Bool = false
    @FocusState private var isFocused: Bool
    @Binding var showDetector: Bool
    let onActivate: (CGPoint) -> Void  // view-space tap/drag-start location
    let onCenterChange: (CGPoint, Bool) -> Void
    let onRadiusChange: (CGFloat, CGFloat, Bool) -> Void  // (inner, outer, interactive)
    let imageSizeProvider: () -> (width: Int, height: Int)

    private let handleRadius: CGFloat = 6
    private let handleHitSlop: CGFloat = 6

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

            // Handle positions (view space)
            let outerHandlePos = CGPoint(x: displayCenter.x + outerR, y: displayCenter.y)
            let innerHandlePos = CGPoint(x: displayCenter.x, y: displayCenter.y - innerR)

            let showOuterHandle = shape == .bf || shape == .af
            let showInnerHandle = shape == .adf || shape == .af

            // Hit-test helpers
            let hitTestCircle: (CGPoint, CGPoint, CGFloat) -> Bool = { point, pos, tolerance in
                let dx = point.x - pos.x
                let dy = point.y - pos.y
                return sqrt(dx * dx + dy * dy) <= tolerance
            }
            let hitTestHandle: (CGPoint, CGPoint) -> Bool = { point, pos in
                hitTestCircle(point, pos, handleRadius + handleHitSlop)
            }
            let hitTestBody: (CGPoint) -> Bool = { point in
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

            if showDetector {
                ZStack {
                    // Detector circles — drawn twice (black outline, then colored) for visibility
                    switch shape {
                    case .bf, .adf:
                        let r = shape == .bf ? outerR : innerR
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 4))
                            .foregroundStyle(Color.black.opacity(0.7))
                            .frame(width: r * 2, height: r * 2)
                            .position(displayCenter)
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 2))
                            .foregroundStyle(tintColor.opacity(0.9))
                            .frame(width: r * 2, height: r * 2)
                            .position(displayCenter)
                    case .af:
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 4))
                            .foregroundStyle(Color.black.opacity(0.7))
                            .frame(width: innerR * 2, height: innerR * 2)
                            .position(displayCenter)
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 2))
                            .foregroundStyle(tintColor.opacity(0.9))
                            .frame(width: innerR * 2, height: innerR * 2)
                            .position(displayCenter)
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 4))
                            .foregroundStyle(Color.black.opacity(0.7))
                            .frame(width: outerR * 2, height: outerR * 2)
                            .position(displayCenter)
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 2))
                            .foregroundStyle(tintColor.opacity(0.9))
                            .frame(width: outerR * 2, height: outerR * 2)
                            .position(displayCenter)
                    default:
                        EmptyView()
                    }

                    // Center crosshair — drawn twice for visibility
                    let crossSize: CGFloat = 4
                    Path { path in
                        path.move(to: CGPoint(x: displayCenter.x - crossSize, y: displayCenter.y))
                        path.addLine(to: CGPoint(x: displayCenter.x + crossSize, y: displayCenter.y))
                        path.move(to: CGPoint(x: displayCenter.x, y: displayCenter.y - crossSize))
                        path.addLine(to: CGPoint(x: displayCenter.x, y: displayCenter.y + crossSize))
                    }
                    .stroke(Color.black.opacity(0.7), lineWidth: 4)
                    Path { path in
                        path.move(to: CGPoint(x: displayCenter.x - crossSize, y: displayCenter.y))
                        path.addLine(to: CGPoint(x: displayCenter.x + crossSize, y: displayCenter.y))
                        path.move(to: CGPoint(x: displayCenter.x, y: displayCenter.y - crossSize))
                        path.addLine(to: CGPoint(x: displayCenter.x, y: displayCenter.y + crossSize))
                    }
                    .stroke(tintColor.opacity(0.9), lineWidth: 2)

                    // Outer radius handle (3 o'clock)
                    if showOuterHandle {
                        Circle()
                            .fill(Color.white)
                            .overlay(Circle().stroke(tintColor.opacity(0.9), lineWidth: 2))
                            .frame(width: handleRadius * 2, height: handleRadius * 2)
                            .position(outerHandlePos)
                    }

                    // Inner radius handle (12 o'clock)
                    if showInnerHandle {
                        Circle()
                            .fill(Color.white)
                            .overlay(Circle().stroke(tintColor.opacity(0.9), lineWidth: 2))
                            .frame(width: handleRadius * 2, height: handleRadius * 2)
                            .position(innerHandlePos)
                    }
                }
                .contentShape(Path { path in
                    // Restrict hit area to the circle and handle regions so clicks outside
                    // fall through to overlays below in Z order.
                    let tol: CGFloat = 10
                    let h = handleRadius + handleHitSlop
                    switch shape {
                    case .bf:
                        path.addEllipse(in: CGRect(x: displayCenter.x - outerR - tol,
                                                   y: displayCenter.y - outerR - tol,
                                                   width: (outerR + tol) * 2,
                                                   height: (outerR + tol) * 2))
                    case .adf:
                        path.addEllipse(in: CGRect(x: displayCenter.x - innerR - tol,
                                                   y: displayCenter.y - innerR - tol,
                                                   width: (innerR + tol) * 2,
                                                   height: (innerR + tol) * 2))
                    case .af:
                        path.addEllipse(in: CGRect(x: displayCenter.x - outerR - tol,
                                                   y: displayCenter.y - outerR - tol,
                                                   width: (outerR + tol) * 2,
                                                   height: (outerR + tol) * 2))
                    default: break
                    }
                    if showOuterHandle {
                        path.addEllipse(in: CGRect(x: outerHandlePos.x - h, y: outerHandlePos.y - h,
                                                   width: h * 2, height: h * 2))
                    }
                    if showInnerHandle {
                        path.addEllipse(in: CGRect(x: innerHandlePos.x - h, y: innerHandlePos.y - h,
                                                   width: h * 2, height: h * 2))
                    }
                })
                .focusable()
                .focused($isFocused)
                .focusEffectDisabled()
                .onChange(of: isActive) { _, active in
                    if active { isFocused = true }
                }
                .simultaneousGesture(
                    SpatialTapGesture(count: 1)
                        .onEnded { value in
                            isFocused = true
                            onActivate(value.location)
                        }
                )
                .simultaneousGesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { value in
                            let loc = value.location
                            // Ignore double-tap if it landed on a handle
                            if showOuterHandle && hitTestHandle(loc, outerHandlePos) { return }
                            if showInnerHandle && hitTestHandle(loc, innerHandlePos) { return }
                            isFocused = true
                            let x = min(max(loc.x, drawRect.minX), drawRect.maxX)
                            let y = min(max(loc.y, drawRect.minY), drawRect.maxY)
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
                            // Classify drag on first movement
                            if !isDraggingFromDetector && !isDraggingOuterHandle && !isDraggingInnerHandle {
                                let start = value.startLocation
                                if showOuterHandle && hitTestHandle(start, outerHandlePos) {
                                    isDraggingOuterHandle = true
                                } else if showInnerHandle && hitTestHandle(start, innerHandlePos) {
                                    isDraggingInnerHandle = true
                                } else if hitTestBody(start) {
                                    isDraggingFromDetector = true
                                } else {
                                    return
                                }
                                onActivate(value.startLocation)
                            }

                            isFocused = true

                            if isDraggingOuterHandle {
                                let dx = abs(value.location.x - displayCenter.x)
                                let minViewR = innerR + scale
                                let maxViewR = min(drawRect.width, drawRect.height) / 2
                                let newViewR = max(minViewR, min(dx, maxViewR))
                                onRadiusChange(inner, newViewR / scale, true)

                            } else if isDraggingInnerHandle {
                                let dy = abs(value.location.y - displayCenter.y)
                                let maxViewR = max(0, outerR - scale)
                                let newViewR = max(scale, min(dy, maxViewR))
                                onRadiusChange(newViewR / scale, outer, true)

                            } else if isDraggingFromDetector {
                                let x = min(max(value.location.x, drawRect.minX), drawRect.maxX)
                                let y = min(max(value.location.y, drawRect.minY), drawRect.maxY)
                                centerViewPoint = CGPoint(x: x, y: y)
                                let imgW = max(patternWidth, 1)
                                let imgH = max(patternHeight, 1)
                                let normX = (x - drawRect.minX) / max(drawRect.width, 1)
                                let normY = (y - drawRect.minY) / max(drawRect.height, 1)
                                let j = Int(round(normX * CGFloat(max(imgW - 1, 0))))
                                let i = Int(round((1 - normY) * CGFloat(max(imgH - 1, 0))))
                                onCenterChange(CGPoint(x: j, y: i), true)
                            }
                        }
                        .onEnded { value in
                            defer {
                                isDraggingFromDetector = false
                                isDraggingOuterHandle = false
                                isDraggingInnerHandle = false
                            }

                            if isDraggingOuterHandle {
                                let dx = abs(value.location.x - displayCenter.x)
                                let minViewR = innerR + scale
                                let maxViewR = min(drawRect.width, drawRect.height) / 2
                                let newViewR = max(minViewR, min(dx, maxViewR))
                                onRadiusChange(inner, newViewR / scale, false)

                            } else if isDraggingInnerHandle {
                                let dy = abs(value.location.y - displayCenter.y)
                                let maxViewR = max(0, outerR - scale)
                                let newViewR = max(scale, min(dy, maxViewR))
                                onRadiusChange(newViewR / scale, outer, false)

                            } else if isDraggingFromDetector {
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
            }
        }
    }
}
