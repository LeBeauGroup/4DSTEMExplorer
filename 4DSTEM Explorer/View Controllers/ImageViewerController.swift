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
    
    /*
    @IBAction func changeBrightness(_ sender:Any){
        
        
        let imageRep = imageViewer.matrix.imageRepresentation(part: "real", format: MatrixOutput.uint16, nil, nil)
        
        let cg = imageRep?.cgImage(forProposedRect: nil, context: NSGraphicsContext.current, hints: nil)
        
        let filter = CIFilter(name: "CIColorControls");
        
        let slider = sender as! NSSlider
        
        filter?.setValue(slider.floatValue, forKey: "inputBrightness")
        
        let rawimgData =  CIImage.init(cgImage: cg!)
        filter?.setValue(rawimgData, forKey: "inputImage")
        let outpuImage = filter?.value(forKey: "outputImage")
        
        let rep = NSCIImageRep.init(ciImage: outpuImage as! CIImage)
        let nsImage = NSImage.init(size: rep.size)
        
        nsImage.addRepresentation(rep)
            

        
        imageViewer.image =  nsImage
    }
     */
    
}
