//
//  ProbeSelectViewController.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 12/25/17.
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Cocoa
import Foundation

class ProbeSelectViewController: NSViewController {
    
    
    @IBOutlet weak var sizeCombo: NSComboBox!
    weak var dataController:STEMDataController!
    weak var parentController:ViewController!
    
    @IBOutlet weak var progressIndicator: NSProgressIndicator!
    
    @IBOutlet weak var loadButton:NSButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.view.window?.initialFirstResponder = loadButton

        
        //        progressIndicator.usesThreadedAnimation = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateProgressIndicator(notification:)), name: Notification.Name("updateProgress"), object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(didFinishLoadingData(notification:)), name: Notification.Name("finishedLoadingData"), object: nil)

    
    }
    
    func selectSizeFromURL(_ url:URL) {
        
        let fileName = url.lastPathComponent
        let wh = self.decomposeFilenameString(fileName)
        
        sizeCombo.stringValue = wh.0 + " x " + wh.1
    }
    
    @IBAction func acceptSize(_ sender: Any) {

        
        sizeCombo.isHidden = true
        loadButton.isEnabled = false
        progressIndicator.isHidden = false

        
        let wh = self.decomposeComboxString()
        
        
        dataController.width = Int(wh.0)!
        dataController.height = Int(wh.1)!
        
        
        
        parentController.loadAndFormatData(self)
//        self.dismiss(self)
        
    }
    
    func decomposeFilenameString(_ string:String) -> (String, String){
        
        let pat = "(?<=[xy])[0-9]+"
        let regex = try! NSRegularExpression(pattern: pat, options: [])
        let matches = regex.matches(in: string, options: [], range: NSRange(location: 0, length: string.count))
        
        var width:String = ""
        var height:String = ""
        
        if let match = matches.first {
            let range = match.range(at:0)
            
            if let swiftRange = Range(range, in: string) {
                width = String(string[swiftRange])
            }
        }
        
        if matches.count > 1{
            
            if let match = matches.last{
                let range = match.range(at:0)
                
                if let swiftRange = Range(range, in: string) {
                    height = String(string[swiftRange])
                    
                }
            }
        }else{
            height = "1"
        }
        
        return (width, height)
    }
    
    func decomposeComboxString() -> (String, String){
        
        
        let string = sizeCombo.stringValue
        let pat = "[0-9]+"
        let regex = try! NSRegularExpression(pattern: pat, options: [])
        let matches = regex.matches(in: string, options: [], range: NSRange(location: 0, length: string.count))
        
        var width:String = ""
        var height:String = ""
        
        if let match = matches.first {
            let range = match.range(at:0)
            
            if let swiftRange = Range(range, in: string) {
                width = String(string[swiftRange])
            }
        }
        
        if matches.count > 1{
            
            if let match = matches.last{
                let range = match.range(at:0)
                
                if let swiftRange = Range(range, in: string) {
                    height = String(string[swiftRange])
                    
                }
            }
        }else{
            height = "1"
        }
        
        return (width, height)
    }

    @objc func willStartLoadingData(notification:Notification){
        sizeCombo.isHidden = true
        loadButton.isEnabled = false
        progressIndicator.isHidden = false

    }
    
    @objc func didFinishLoadingData(notification:Notification){
    
        self.dismiss(nil)
    }


    
    @objc func updateProgressIndicator(notification:Notification){
        
        let incre = notification.object as! Double / Double(dataController.width*dataController.height) * 100

        progressIndicator.doubleValue = incre


    }
    
    override func viewWillDisappear() {
        
        // Need to cancel the async function
        
        super.viewWillDisappear()
    }
    
}
