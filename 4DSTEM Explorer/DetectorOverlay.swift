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
    let patternWidth: Int
    let patternHeight: Int
    @State private var centerViewPoint: CGPoint? = nil
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
            let defaultCenter = CGPoint(x: drawRect.midX, y: drawRect.midY)
            let center = centerViewPoint ?? defaultCenter
            let scale = min(drawRect.width / imgW, drawRect.height / imgH)
            let innerR = max(0, inner) * scale
            let outerR = max(0, outer) * scale
            
            if showDetector{
                ZStack {
                    switch shape {
                    case .bf, .adf:
                        let r = shape == .bf ? outerR : innerR
                        Circle().stroke(style: StrokeStyle(lineWidth: 2)).foregroundStyle(Color.accentColor.opacity(0.9)).frame(width: r * 2, height: r * 2).position(center)
                    case .af:
                        Circle().stroke(style: StrokeStyle(lineWidth: 2)).foregroundStyle(Color.accentColor.opacity(0.9)).frame(width: innerR * 2, height: innerR * 2).position(center)
                        Circle().stroke(style: StrokeStyle(lineWidth: 2)).foregroundStyle(Color.accentColor.opacity(0.9)).frame(width: outerR * 2, height: outerR * 2).position(center)
                    default: EmptyView()
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
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
                        .onEnded { _ in
                            // Final notification on end
                            let x = min(max((centerViewPoint ?? defaultCenter).x, drawRect.minX), drawRect.maxX)
                            let y = min(max((centerViewPoint ?? defaultCenter).y, drawRect.minY), drawRect.maxY)
                            let normX = (x - drawRect.minX) / max(drawRect.width, 1)
                            let normY = (y - drawRect.minY) / max(drawRect.height, 1)
                            let imgW = max(patternWidth, 1)
                            let imgH = max(patternHeight, 1)
                            let j = Int(round(normX * CGFloat(max(imgW - 1, 0))))
                            let i = Int(round((1 - normY) * CGFloat(max(imgH - 1, 0))))
                            onCenterChange(CGPoint(x: j, y: i), false)
                        }
                )
            }}
    }
}
