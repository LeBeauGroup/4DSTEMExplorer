//
//  AppDelegate.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 12/21/17.
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {


    @IBAction func open(_ sender:Any){
//        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        
        
        if NSApp.mainWindow == nil{
            self.restoreMainWindow(self)
        }
        
        
        let viewController =  NSApp.mainWindow?.contentViewController as! ViewController
       viewController.openPanel()
        
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Insert code here to initialize your application
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        
        let viewController =  NSApp.mainWindow?.contentViewController as! ViewController
//        viewController.openPanel()
        viewController.dataController.filePath = urls[0]
        viewController.displayProbePositionsSelection(urls[0])
    }
    
    
    
    func applicationWillUnhide(_ notification: Notification) {
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)

    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if (flag) {
            return false
        }
        else
        {
            let windows = NSApp.windows
            
            windows[0].makeKeyAndOrderFront(self)
            return true
        }
    }
    
    @IBAction func restoreMainWindow(_ sender:Any){
        let windows = NSApp.windows
        windows[0].makeKeyAndOrderFront(self)
    }
    
    

    
    



}

