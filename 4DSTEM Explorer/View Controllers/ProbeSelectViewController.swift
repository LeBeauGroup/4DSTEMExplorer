//
//  ProbeSelectViewController.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 12/25/17.
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Cocoa
import Foundation

class ProbeSelectViewController: NSViewController, STEMDataControllerProgressDelegate,NSComboBoxDelegate, NSTextFieldDelegate {
    
    
    @IBOutlet weak var sizeCombo: NSComboBox!
    weak var dataController:STEMDataController!
    weak var parentController:ViewController!
    
    @IBOutlet weak var progressIndicator: NSProgressIndicator!
    
    @IBOutlet weak var loadButton:NSButton!
    @IBOutlet weak var cancelButton:NSButton!

    override func viewDidLoad() {
        super.viewDidLoad()
        
        sizeCombo.delegate = self
        


        
        //        progressIndicator.usesThreadedAnimation = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateProgressIndicator(notification:)), name: Notification.Name("updateProgress"), object: nil)
        
    }
    
    func selectSizeFromURL(_ url:URL) {
        
        let fileName = url.lastPathComponent
        
        let wh = self.decomposeFilenameString(fileName)
        
        if wh != nil{
            sizeCombo.stringValue = wh!.0 + " x " + wh!.1
        }else{
            sizeCombo.placeholderString = "width x height (pixels)"
        }
    }
    
    func loadTiff(_ sender: Any) {
        
        sizeCombo.isHidden = true
        loadButton.isEnabled = false
        
        progressIndicator.isHidden = false
        
        self.title = "Data loading..."
        
        self.view.needsDisplay = true
        
        
        do{
            try dataController.openFile(url: dataController.filePath!)
        }catch FileReadError.invalidTiff{
            
            let alert = NSAlert.init()
            alert.messageText = "Selected image is incompatible.  Please select an EMPAD tiff stack."
            alert.runModal()
            self.dismiss(nil)
            
        }catch{
            let alert = NSAlert.init()
            alert.messageText = "Something went wrong with the selected file, please try again."
            alert.runModal()
            self.dismiss(nil)
        }
    }
    @IBAction func acceptSize(_ sender: Any) {

        
        if sizeCombo.stringValue == ""{
            let alert = NSAlert.init()
            alert.messageText = "You must enter the width and height of the acquired dataset (final image size) to continue."
            
            alert.runModal()
            
            return
        }
        
        sizeCombo.isHidden = true
        loadButton.isEnabled = false
        progressIndicator.isHidden = false
    
        self.title = "Data loading..."
        

        let wh = self.decomposeComboxString()
        
        if wh != nil{
        
            dataController.imageSize.width = Int(wh!.0)!
            dataController.imageSize.height = Int(wh!.1)!
        }
        
        do{
            try dataController.openFile(url: dataController.filePath!)
        }catch FileReadError.invalidDimensions{
            sizeCombo.isHidden = false
            loadButton.isEnabled = true
            progressIndicator.isHidden = true
            let alert = NSAlert.init()
            alert.messageText = "Incorrect dimensions for the file, try again."
            alert.runModal()
            
        }catch{
            let alert = NSAlert.init()
            alert.messageText = "Something went wrong with the selected file, please try again."
            alert.runModal()
            self.dismiss(nil)
        }
    
    }
    
    func decomposeFilenameString(_ string:String) -> (String, String)?{
        
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
        
        if matches.count == 0{
            return nil
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
    
    func decomposeComboxString() -> (String, String)?{
        
        let string = sizeCombo.stringValue
        let pat = "[0-9]+"
        let regex = try! NSRegularExpression(pattern: pat, options: [])
        let matches = regex.matches(in: string, options: [], range: NSRange(location: 0, length: string.count))
        
        
        if matches.count == 0 || matches.count > 2{
            return nil
        }
        
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
    
    func didFinishLoadingData(){
        
        parentController.view.window?.title = (dataController.filePath?.deletingPathExtension().lastPathComponent)!

        self.dismiss(nil)
    }
    
    
//    func cancelLoadingData() {
//        self.dismiss(nil)
//    }
//
    @IBAction func cancel(_ sender:Any){
        
        dataController.dwi?.cancel()
        
        self.dismiss(nil)

    }


    
    @objc func updateProgressIndicator(notification:Notification){
        
        let incre = notification.object as! Double / Double(dataController.imagePixels) * 100

        progressIndicator.doubleValue = incre


    }
    


    override func controlTextDidEndEditing(_ obj: Notification) {
        
        if let combobox = obj.object as! NSComboBox?{
            
            let wh = self.decomposeComboxString()
            
            if wh == nil{
                
                let alert = NSAlert.init()
                alert.messageText = "The width and height were entered incorrectly.  Please try again in the proper format."
                
                alert.runModal()
            }
            
        }
    }
    
    func comboBoxSelectionDidChange(_ notification: Notification) {
        
        if let combobox = notification.object as! NSComboBox?{
         
            let wh = self.decomposeComboxString()
            
            if wh == nil{
                
                let alert = NSAlert.init()
                alert.messageText = "Selected image is incompatible.  Please select an EMPAD tiff stack."
                
                alert.runModal()
            }

            
        }
        
    }
    override func viewDidDisappear() {
        

        super.viewDidDisappear()
    }
    
}
