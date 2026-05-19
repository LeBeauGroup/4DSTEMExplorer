//
//  ImageViewerController.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 12/28/17.
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//


import Cocoa

class ImageViewerController:NSViewController{
    
    @IBOutlet weak var imageViewer:ImageViewer!
    
    @IBAction func changeBrightness(_ sender:Any){
        // Ensure we have a valid slider
        guard let slider = sender as? NSSlider else { return }
        
        // Ensure the imageViewer has a matrix to work with
        guard let matrix = imageViewer.matrix else { return }
        
        // Obtain an image representation from the matrix. Adjust the call to use labeled parameters if needed.
        // Assuming signature like: imageRepresentation(part: String, format: MatrixOutput, min: Any?, max: Any?)
        guard let imageRep = matrix.imageRepresentation(part: "real", format: MatrixOutput.uint16, nil, nil) else { return }
        
        // Get CGImage from NSImageRep
        guard let cg = imageRep.cgImage(forProposedRect: nil, context: NSGraphicsContext.current, hints: nil) else { return }
        
        // Create and configure CIFilter
        guard let filter = CIFilter(name: "CIColorControls") else { return }
        filter.setValue(slider.floatValue, forKey: kCIInputBrightnessKey)
        
        let rawimgData = CIImage(cgImage: cg)
        filter.setValue(rawimgData, forKey: kCIInputImageKey)
        
        // Extract output image
        guard let outputImage = filter.value(forKey: kCIOutputImageKey) as? CIImage else { return }
        
        // Create NSImage from CIImage
        let rep = NSCIImageRep(ciImage: outputImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        
        imageViewer.image = nsImage
    }
    
}

