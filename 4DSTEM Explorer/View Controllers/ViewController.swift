//
//  ViewController.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 12/21/17.
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Cocoa
import Quartz

protocol ViewControllerDelegate: class {
    func averagePatternInRect(_ rect:NSRect?)
}

class ViewController: NSViewController,NSWindowDelegate, ImageViewerDelegate, STEMDataControllerDelegate{

    @IBOutlet weak var patternViewer: PatternViewer!
    @IBOutlet weak var imageView: ImageViewer!
    @IBOutlet weak var innerAngleTextField: NSTextField!
    @IBOutlet weak var outerAngleTextField: NSTextField!
    @IBOutlet weak var lrud_xySegmented:NSSegmentedControl!
    @IBOutlet weak var detectorTypeSegmented:NSSegmentedControl!
    @IBOutlet weak var detectorShapeSegmented:NSSegmentedControl!

    @IBOutlet weak var viewHeightConstraint: NSLayoutConstraint!
    @IBOutlet weak var viewWidthConstraint: NSLayoutConstraint!
    
    @IBOutlet weak var scrollView: NSScrollView!
    @IBOutlet weak var clipView: CenteringClipView!
    @IBOutlet weak var displayLogCheckbox: NSButtonCell!

    var dataController = STEMDataController()
    var patternRect:NSRect? //= NSRect(x: 0, y: 0, width: 0, height: 0)
    
    var selectedDetector:Detector?
    
    let zoomTable = [0.05, 0.10, 0.15, 0.20, 0.30, 0.40, 0.50, 0.75, 1.00, 1.50, 2.00, 3.00, 4.00, 6.00, 8.00, 10.00, 15.00, 20.00, 30.00 ];
    
    
    @IBOutlet weak var patternSelectionLabel:NSTextField?

    var zoomFactor:CGFloat = 1.0 {
        
        didSet {
            
            guard imageView.image != nil else {
                
                return
                
            }
            
            scrollView.magnification = zoomFactor
            
            let winController = self.view.window?.windowController as! WindowController
            winController.updateScale(zoomFactor)
            
            
        }
        
    }

    override func viewDidLoad() {
        
        imageView.delegate = self
        dataController.delegate = self
        self.view.window?.makeFirstResponder(patternViewer.detectorView)
        
        selectDetectorType(0)
        
        //patternViewer.imageScaling = NSImageScaling.scaleProportionallyUpOrDown
        //patternViewer.bounds = NSRect(x: 0, y: 0, width: 256, height: 256)
        
        let nc = NotificationCenter.default
        
//        nc.addObserver(self, selector: #selector(didFinishLoadingData(note:)), name: Notification.Name("finishedLoadingData"), object: nil)
        
        nc.addObserver(self, selector: #selector(detectorIsMoving(note:)), name: Notification.Name("detectorIsMoving"), object: nil)
        nc.addObserver(self, selector: #selector(detectorFinishedMoving(note:)), name: Notification.Name("detectorFinishedMoving"), object: nil)
        
        nc.addObserver(self, selector: #selector(self.pinchZoom(note:)), name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)

        
                
    }
    
    @IBAction func open(_sender: Any){
        
        self.openPanel()
        
    }
        

    func loadAndFormatData(_ sender: Any) throws {
       
        let ext = dataController.filePath!.pathExtension
        
        let uti = UTTypeCreatePreferredIdentifierForTag(
            kUTTagClassFilenameExtension,
            ext as CFString,
            nil)
        
        if UTTypeConformsTo((uti?.takeRetainedValue())!, kUTTypeTIFF) {
            do{
                try dataController.openFile(url: dataController.filePath!)
                return
            }catch{
                throw FileReadError.invalidTiff
                
            }
        }
        
        do{
            try dataController.openFile(url: dataController.filePath!)
        }catch{
            
            throw FileReadError.invalidTiff
        }
        

    }
    
    @IBAction func changeLrup_xy(_ sender: Any) {
        self.detectImage()
        

        
    }
    
    @IBAction func changeLog(_ sender: Any){
        
        // need to make sure that a rect has been selected to prevent crash
        if patternRect != nil{
            averagePatternInRect(patternRect)
        }
    }

    @IBAction func changeImageViewSelectionMode(_ sender: Any){
        
        if let segmented = sender as? NSSegmentedControl{
            
            switch segmented.tag(forSegment: segmented.selectedSegment){
            case 0:
                imageView.selectMode = .point

            case 1:
                imageView.selectMode = .marquee

            default:
                imageView.selectMode = .none
            }
                
        }
        

    }

    func detectImage(stride:Int = 1){
        
        let lrud_xy = lrud_xySegmented.tag(forSegment: lrud_xySegmented.selectedSegment)
        
        var detectedImage:Matrix?  = nil
        
        selectedDetector = patternViewer.detectorView!.detector
        
        switch detectorTypeSegmented.selectedSegment{
        case 0:
            detectedImage = dataController.integrating(selectedDetector!, strideLength:stride)
        case 1:
            detectedImage = dataController.dpc(selectedDetector!, strideLength:stride, lrud: lrud_xy )
        case 2:
            detectedImage = dataController.com(selectedDetector!, strideLength:stride, xy: lrud_xy)
        default:
            detectedImage = dataController.integrating(selectedDetector!, strideLength:stride)
        }
        
        if detectedImage != nil{
            self.imageView!.matrix = detectedImage!
        }
        

//        self.zoomToFit(nil)
        
        //detectedImage!.imageRepresentation(part: "real", format: MatrixOutput.uint16, nil, nil)

            //            print("retain count:\(CFGetRetainCount(detectedImage! as CFTypeRef))")

    }
    
    @objc func detectorIsMoving(note:Notification) {
        
//        selectedDetector = patternViewer.detectorView!.detector
        
        patternViewer.detectorView?.needsDisplay = true
        
        let stride:Int?
        
        
//        if dataController.imageSize.width % 2 == 0{
         
            var dividor = dataController.imageSize.width

            
            while(dividor > 100){
                dividor /= 2
                
            }
            
             stride = dataController.imageSize.width/dividor
            
//        }else{
//            stride = 1
//        }
//        

        
        
        self.detectImage(stride: stride!)
        
        innerAngleTextField.floatValue = Float(patternViewer.detectorView!.detector.radii!.inner)
        
        outerAngleTextField.floatValue = Float(patternViewer.detectorView!.detector.radii!.outer)


//        let indices = Matrix.init(meshIndicesAlong: 1, empadSize.height-2, empadSize.width)
        
//        let tempMatrix = indices < Float(selectedDetector!.center.x) //.* selectedDetector!.detectorMask()
        
// patternViewer.detectorView!.detector.detectorMask() .* curPatternMatrix!
//        
//        patternViewer.image = tempMatrix.imageRepresentation(part: "real", format: MatrixOutput.uint8, nil, nil )
        
    }
    @objc func detectorFinishedMoving(note:Notification) {
//        selectedDetector = patternViewer.detectorView!.detector

        innerAngleTextField.floatValue = Float(patternViewer.detectorView!.detector.radii!.inner)
        
        outerAngleTextField.floatValue = Float(patternViewer.detectorView!.detector.radii!.outer)

        self.detectImage()
    }
    

    
//     func selectPatternAt(note:Notification){
//
//        let patternPoint = note.object as! NSPoint
//
//        let patternIndices = (Int(patternPoint.y), Int(patternPoint.x))
//
//        self.selectPatternAt(patternIndices)
//
//
//    }
    
    @IBAction func detectorRadiusChanged(_ sender:Any){
    
        
        if let textField = sender as? NSTextField
        {
            
            switch textField.tag{
            case 0:
                patternViewer.detectorView!.radii!.outer = CGFloat(textField.doubleValue)
            case 1:
                patternViewer.detectorView!.radii!.inner = CGFloat(textField.doubleValue)
            default:
                print("radius not changed")
            }
        
            patternViewer.detectorView!.needsDisplay = true
            
            self.detectImage()
        }else{
        }
        
    
    }
    
    func averagePatternInRect(_ rect:NSRect?){
//        print(rect)
        
        patternRect = rect
        
        var avgMatrix = dataController.averagePattern(rect: rect!)
        
        let starti = Int(rect!.origin.y)
        let startj = Int(rect!.origin.x)
        
        let endi = starti + Int(rect!.size.height)
        let endj = startj + Int(rect!.size.width)

        var stringi = String(starti)
        var stringj = String(startj)
        
        if starti != endi{
            stringi += ":\(endi)"
        }
        
        if startj != endj{
            stringj += ":\(endj)"
        }
        
        let labelString = "(" + stringi + "," + stringj + ")"
        
        
        patternSelectionLabel?.stringValue = labelString

        if(displayLogCheckbox.state == NSButtonCell.StateValue.on){
            avgMatrix = avgMatrix.log()
            
        }
        
        patternViewer.matrix = avgMatrix
//        patternViewer.matrix = patternViewer.detectorView!.detector.detectorMask()

//        patternViewer.needsDisplay = true
        
        
    }
    
    // Input tuple for (i,j)
    func selectPatternAt(_ i: Int, _ j:Int) {
        
        
        
//        patternRect = NSRect(x: j, y: i, width: 1, height: 1)
        var patternMatrix:Matrix? = dataController.pattern(i, j)
        patternSelectionLabel?.stringValue = "(\(j), \(i))"
        
        if patternMatrix != nil{
            if(displayLogCheckbox.state == NSButtonCell.StateValue.on){
                    patternMatrix = patternMatrix!.log()
            }
            
            patternViewer.matrix = patternMatrix!
            
        }
    }
    
    
    @IBAction func selectDetectorType(_ sender:Any){
        
        // Update detector type after selecting with keyboard shortcut
        var selectedTag:Int = 0
        
        if let menuItem = sender as? NSMenuItem{
            selectedTag =  menuItem.tag
            detectorTypeSegmented.selectSegment(withTag: selectedTag)
            
            
        } else if let segControl = sender as? NSSegmentedControl{
            
            selectedTag = segControl.selectedSegment

            
        }else{
            print("detector not sent by segmented control")
//            return
        }
        
        let newType:DetectorType
        
        switch selectedTag{
        case 0:
            newType = DetectorType.integrating
            lrud_xySegmented.isEnabled = false
            lrud_xySegmented.isHidden = true
            
            
        case 1:
            newType = DetectorType.dpc
            lrud_xySegmented.setLabel("L-R", forSegment: 0)
            lrud_xySegmented.setLabel("U-D", forSegment: 1)
            lrud_xySegmented.isEnabled = true
            lrud_xySegmented.isHidden = false
            
        case 2:
            newType = DetectorType.com
            
            lrud_xySegmented.setLabel("X", forSegment: 0)
            lrud_xySegmented.setLabel("Y", forSegment: 1)
            
            lrud_xySegmented.isEnabled = true
            lrud_xySegmented.isHidden = false
            
        default:
            newType = DetectorType.integrating
            lrud_xySegmented.isEnabled = false
            lrud_xySegmented.isHidden = true
        }
        
        
        patternViewer.detectorView?.detectorType = newType
        patternViewer.detectorView?.needsDisplay = true
        
        selectedDetector = patternViewer.detectorView!.detector
        self.detectImage(stride: 1)
        
    }
    
    @IBAction func showHideDetector(_ sender:Any){
        patternViewer.detectorView?.selectionIsHidden = !(patternViewer.detectorView?.selectionIsHidden)!
        patternViewer.detectorView?.needsDisplay = true
    }
    
    @IBAction func showHideImageSelection(_ sender:Any){
        imageView.selectionIsHidden  = !(imageView.selectionIsHidden)
        imageView.needsDisplay = true
        
    }
    
    @IBAction func selectDetectorShape(_ sender:Any){
    
        var selectedTag:Int
        
        if let menuItem = sender as? NSMenuItem{
            selectedTag =  menuItem.tag
            detectorShapeSegmented.selectSegment(withTag: selectedTag)
            
            
        } else if let segControl = sender as? NSSegmentedControl{
            
            selectedTag = segControl.selectedSegment
            
        }
        else{
            print("detector not sent by segmented control")
            return
        }
        
            
            let newShape:DetectorShape
            
            switch selectedTag{
            case 0:
                newShape = DetectorShape.bf
                innerAngleTextField.isEnabled = false
                outerAngleTextField.isEnabled = true
            case 1:
                newShape = DetectorShape.adf
                innerAngleTextField.isEnabled = true
                outerAngleTextField.isEnabled = false
            case 2:
                newShape = DetectorShape.af
                innerAngleTextField.isEnabled = true
                outerAngleTextField.isEnabled = true
            default:
                newShape = DetectorShape.bf
                innerAngleTextField.isEnabled = false
                outerAngleTextField.isEnabled = true
            }
            
            patternViewer.detectorView?.radii = DetectorRadii(inner: CGFloat(innerAngleTextField.floatValue), outer:CGFloat(outerAngleTextField.floatValue))
            
            patternViewer.detectorView?.detectorShape = newShape
            patternViewer.detectorView?.needsDisplay = true

            selectedDetector = patternViewer.detectorView!.detector
            self.detectImage(stride: 1)
            
        }
    func openPanel(){
    
        let openPanel = NSOpenPanel()
        openPanel.allowedFileTypes = ["raw", "public.tiff", "mrc", "dm4"]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = true
        
        if (openPanel.runModal() == NSApplication.ModalResponse.OK){
            
            let selectedURL = openPanel.url
            
            if selectedURL != nil{
                dataController.filePath = selectedURL
                
                
                // add to recents menu
                let dc = NSDocumentController.shared
                dc.noteNewRecentDocumentURL(selectedURL!)
                

                    self.displayProbePositionsSelection(openPanel.url!)
                
                
            }
        }

    }
    
    @objc func didFinishLoadingData() {
        
        self.view.window?.title = dataController.filePath!.deletingPathExtension().lastPathComponent

        
        
        if patternViewer.detectorView?.isHidden == true{
            
            patternViewer.detectorView?.isHidden = false
        }
        
    
        let size = NSSize(width: dataController.patternSize.height, height: dataController.patternSize.width)
        
        let centerPoint  = NSPoint(x: dataController.patternSize.width/2, y: dataController.patternSize.height/2)
        
        patternViewer.detectorView!.detector = Detector(shape: DetectorShape.bf, type: DetectorType.integrating, center: centerPoint, radii: DetectorRadii(inner: CGFloat(innerAngleTextField.floatValue), outer: CGFloat(outerAngleTextField.floatValue)),size:size)
            
        
        
        imageView.isHidden = false
        imageView.selectionRect = nil
        
        patternRect = NSRect(x: dataController.imageSize.width/2, y: dataController.imageSize.height/2, width: 0, height: 0)
        
        self.averagePatternInRect(patternRect)
        
        self.detectImage()

        imageView.setFrameSize(imageView.image!.size)
        
        viewHeightConstraint.constant = imageView.image!.size.height //* zoomFactor
        viewWidthConstraint.constant = imageView.image!.size.width //* zoomFactor
        
//        zoomToActual(nil)
        zoomToFit(nil)

    }
    
    @IBAction func displayProbePositionsSelection(_ sender: Any){
        
       
        let sizeSelectionController:ProbeSelectViewController = storyboard?.instantiateController(withIdentifier: NSStoryboard.SceneIdentifier(rawValue: "ProbeSelectViewController")) as! ProbeSelectViewController
        
        self.presentViewControllerAsSheet(sizeSelectionController)
        
        sizeSelectionController.view.window?.makeFirstResponder(sizeSelectionController.loadButton)

        
        sizeSelectionController.dataController = dataController
        sizeSelectionController.parentController = self
        sizeSelectionController.selectSizeFromURL(sender as! URL)
        
        dataController.progressdelegate =  sizeSelectionController
        
        
        let ext = (sender as! URL).pathExtension
        
        if ext == "mrc" || ext == "dm4"{
            sizeSelectionController.loadTiff(self)
            return
        }
        

        
        let uti = UTTypeCreatePreferredIdentifierForTag(
            kUTTagClassFilenameExtension,
            ext as CFString,
            nil)
        
        if UTTypeConformsTo((uti?.takeRetainedValue())!, kUTTypeTIFF) {
            sizeSelectionController.loadTiff(self)
        }

    }
    

    @IBAction func export(_ sender:Any){
        
        var tag = 0
        if sender is NSMenuItem{
            let menuItem = sender as! NSMenuItem
            tag = menuItem.tag

        }else if sender is NSPopUpButton{
            let popup = sender as! NSPopUpButton
            
            tag = popup.indexOfSelectedItem - 1
        }
        
        
        
        
        let savePanel = NSSavePanel()
        
        savePanel.canCreateDirectories = true
        savePanel.showsTagField = false
        savePanel.isExtensionHidden = false
        savePanel.allowedFileTypes = ["tif"]
        
        if tag == 0{
            var lrud_xyLabel = ""
            
            let detector =  self.patternViewer.detectorView?.detector

            
            if detector?.type == DetectorType.com || detector?.type == DetectorType.dpc{
                lrud_xyLabel = "_" + lrud_xySegmented.label(forSegment: lrud_xySegmented.selectedSegment)!

            }
            let detectorTypeLabel = detectorTypeSegmented.label(forSegment: detectorTypeSegmented.selectedSegment)!
            
                savePanel.nameFieldStringValue = (self.view.window?.title)! + "_" + detectorTypeLabel  + lrud_xyLabel
            
        }else if tag == 1{
            savePanel.nameFieldStringValue = (self.view.window?.title)!+"_"+(patternSelectionLabel?.stringValue)!

        }
        
        
        

        savePanel.begin( completionHandler:{(result) in
            
            if result == NSApplication.ModalResponse.OK {
                let filename = savePanel.url
                
                
                var bitmapRep:NSBitmapImageRep?
               
          
                if(tag == 0){
                    bitmapRep = self.imageView.matrix.floatImageRep()
                    
                }else if tag == 1{
                    bitmapRep = self.patternViewer.matrix.floatImageRep()

                }
                
                    
                // To add metadata, will need to switch to cgimagedestination
                
                var data:Data = Data.init()
                
                let props = [NSBitmapImageRep.PropertyKey:Any]()
                
                //        props[NSBitmapImageRep.PropertyKey.compressionFactor] = 1.0
                //        props[NSBitmapImageRep.PropertyKey.gamma]  = 0.5
                
                if bitmapRep != nil{
                    
                    data = bitmapRep!.representation(using: NSBitmapImageRep.FileType.tiff, properties: props)!
                }

                
                var cgProps = [CFString:Any]()
                
                let dest =  CGImageDestinationCreateWithURL(filename! as CFURL, "public.tiff" as CFString, 1, nil)
                
                
                 cgProps["{TIFF}" as CFString] = ["ImageDescription" as CFString:"A description" as CFString]
                
                CGImageDestinationAddImage(dest!, bitmapRep!.cgImage!, cgProps as CFDictionary)
                
                CGImageDestinationFinalize(dest!)
                
                    
            } else {
              print("save failed")
            }
        })
    
    
    }
    
    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }
    
    func nearestZoom() -> Int{
        
        var minIndex = 0
        
        var zoomDiff = fabs(Double(zoomFactor)-zoomTable[0])
        
        for (i,_) in zoomTable.enumerated(){
            
            let tempDiff = fabs(Double(zoomFactor)-zoomTable[i])
            
            if zoomDiff > tempDiff {
                minIndex += 1
            }else if zoomDiff < tempDiff{
                break
            }

            zoomDiff = tempDiff

        }
        
        return minIndex
        
        
        
    }
    
    @IBAction func zoomIn(_ sender: NSMenuItem?) {
        
        let newZoomIndex = nearestZoom()+1;
        
        if newZoomIndex <= zoomTable.count - 1{
            zoomFactor = CGFloat(zoomTable[newZoomIndex])
        }
        
        
    }
    
    @objc func pinchZoom(note:Notification){
       
        zoomFactor = scrollView.magnification

    }
    
    @IBAction func zoomInOut(_ sender: Any) {
        
        
        if sender is NSSegmentedControl{
            
            let zoomButton = sender as! NSSegmentedControl
            
            if zoomButton.selectedSegment == 0{
                self.zoomOut(nil)
            }else if zoomButton.selectedSegment == 1{
                self.zoomIn(nil)
            }
        } else if sender is NSTextField{
            
            let scaleField = sender as! NSTextField
            
            zoomFactor = CGFloat(scaleField.floatValue)
        }
        

    }

    
    @IBAction func zoomOut(_ sender: NSMenuItem?) {
        
        
        let newZoomIndex = nearestZoom()-1;
        
        if newZoomIndex >= 0{
            zoomFactor = CGFloat(zoomTable[newZoomIndex])
        }
        

        
    }
    
    @IBAction func zoomToActual(_ sender: NSMenuItem?) {
        
        zoomFactor = 1.0
        
    }
    
    @IBAction func zoomToFit(_ sender: NSMenuItem?) {
        
        guard imageView!.image != nil else {
            
            return
            
        }
        
//        let imSize = imageView!.image!.size
//
//        var clipSize = clipView.bounds.size
//
//
//        guard imSize.width > 0 && imSize.height > 0 && clipSize.width > 0 && clipSize.height > 0 else {
//
//            return
//
//        }
//
//        // 20 pixel gutter
//
//        let imageMargin:CGFloat = 40
//
//        clipSize.width -= imageMargin
//        clipSize.height -= imageMargin
//
//        let clipAspectRatio = clipSize.width / clipSize.height
//        let imAspectRatio = imSize.width / imSize.height
//
//        if clipAspectRatio > imAspectRatio {
//
//            zoomFactor = clipSize.height / imSize.height
//
//        } else {
//
//            zoomFactor = clipSize.width / imSize.width
//
//        }
        
        
        scrollView.magnify(toFit: imageView.frame)
        
        zoomFactor = scrollView.magnification
        
    }
    
    



}

