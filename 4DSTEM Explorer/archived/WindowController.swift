//
//  WindowController.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 12/28/17.
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Cocoa

class WindowController : NSWindowController, NSWindowDelegate {
    
    @IBOutlet  weak var scaleField:NSTextField?
    var lastSelectionTag:Int?
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    override func windowWillLoad() {

    }
    
    override func windowDidLoad() {
        
        self.window?.isReleasedWhenClosed = false
        
        super.windowDidLoad()
        self.window?.delegate = self
//        window?.appearance = NSAppearance(named: NSAppearance.Name.vibrantDark)
//        window?.titlebarAppearsTransparent = true

        
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        
        self.window?.orderOut(self)
        return false
    }
    
    func updateScale(_ zoom: CGFloat){
        
        scaleField?.takeFloatValueFrom(Float(zoom))
        
    }
    
    @IBAction func export(_ sender:Any){
        
        if sender is NSPopUpButton{
            
            let popup = sender as! NSPopUpButton
            
            let cvc = self.contentViewController as! ViewController
                        
                cvc.export(popup)
        }
    }
    
    @IBAction func changeSelectionMode(_ sender:Any){
        
        if sender is NSSegmentedControl{
            
            let segmented = sender as! NSSegmentedControl
            
            let cvc = self.contentViewController as! ViewController
            
            switch segmented.selectedSegment{
            case 0:
                 cvc.imageView.selectMode  = .point
            case 1:
                 cvc.imageView.selectMode  = .marquee
//            case 2:
//                 cvc.imageView.selectMode  = .marquee
            default:
                 cvc.imageView.selectMode  = .point
            }
            
            
        }
    }
    

    
    
    

}
