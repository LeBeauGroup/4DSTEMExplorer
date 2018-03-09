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
    

    
    
    

}
