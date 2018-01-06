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
        
        let viewController =  NSApp.mainWindow?.contentViewController as! ViewController
       viewController.openPanel()
        
        print("open")
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Insert code here to initialize your application
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
//        NSApp.mainWindow?.makeKeyAndOrderFront(nil)

    }
    
    



}

