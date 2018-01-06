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

    @IBOutlet weak var viewHeightConstraint: NSLayoutConstraint!
    @IBOutlet weak var viewWidthConstraint: NSLayoutConstraint!
    
    @IBOutlet weak var clipView: CenteringClipView!
    @IBOutlet weak var displayLogCheckbox: NSButtonCell!

    var dataController = STEMDataController()
    var patternIndex  = 0
    var selectedDetector:Detector?
    @IBOutlet weak var patternSelectionLabel:NSTextField?
    
    var zoomFactor:CGFloat = 1.0 {
        
        didSet {
            
            guard imageView.image != nil else {
                
                return
                
            }
            
            viewHeightConstraint.constant = imageView.image!.size.height * zoomFactor
            viewWidthConstraint.constant = imageView.image!.size.width * zoomFactor
            
        }
        
    }
        
    override func awakeFromNib() {
        super.awakeFromNib()
    
        imageView.delegate = self
        dataController.delegate = self
        
        DispatchQueue.main.async{
            
            self.zoomToFit(nil)
            
        }

    }
    
    override func viewDidLoad() {
        
        patternViewer.imageScaling = NSImageScaling.scaleProportionallyUpOrDown
        patternViewer.bounds = NSRect(x: 0, y: 0, width: 256, height: 256)
        
        let nc = NotificationCenter.default
        
//        nc.addObserver(self, selector: #selector(didFinishLoadingData(note:)), name: Notification.Name("finishedLoadingData"), object: nil)
        
        nc.addObserver(self, selector: #selector(detectorIsMoving(note:)), name: Notification.Name("detectorIsMoving"), object: nil)
        nc.addObserver(self, selector: #selector(detectorFinishedMoving(note:)), name: Notification.Name("detectorFinishedMoving"), object: nil)
        
                
    }
    
    @IBAction func open(_sender: Any){
        
        self.openPanel()
        
    }
        

    func loadAndFormatData(_ sender: Any) {
        
        dataController.formatMatrixData()

    }
    
    @IBAction func changeLrup_xy(_ sender: Any) {
        self.detectImage()
        

        
    }
    
    @IBAction func changeLog(_ sender: Any){
        
        
        selectPatternAt(-1,-1)
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

        self.zoomToFit(nil)
            
        //detectedImage!.imageRepresentation(part: "real", format: MatrixOutput.uint16, nil, nil)

            //            print("retain count:\(CFGetRetainCount(detectedImage! as CFTypeRef))")

    }
    
    @objc func detectorIsMoving(note:Notification) {
        
//        selectedDetector = patternViewer.detectorView!.detector
        
        patternViewer.detectorView?.needsDisplay = true
        
        let stride:Int?
        
        
        if dataController.imageSize.width % 2 == 0{
         
            print(dataController.imageSize.width)
            var dividor = dataController.imageSize.width

            
            while(dividor > 80){
                dividor /= 2
                
            }
            
             stride = dataController.imageSize.width/dividor
            
        }else{
            stride = 1
        }
        

        
        
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
        var avgMatrix = dataController.averagePattern(rect: rect!)
        
        let starti = Int(rect!.origin.y)
        let startj = Int(rect!.origin.x)
        
        let endi = starti + Int(rect!.size.height)
        let endj = startj + Int(rect!.size.width)

        
        patternSelectionLabel?.stringValue = "(\(startj):\(endj), \(starti):\(endi))"

    
        if(displayLogCheckbox.state == NSButtonCell.StateValue.on){
            avgMatrix = avgMatrix.log()
            
        }
        
        patternViewer.matrix = avgMatrix
//        patternViewer.needsDisplay = true
        
        
    }
    
    // Input tuple for (i,j)
    func selectPatternAt(_ i: Int, _ j:Int) {
        
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
        
        if let segControl = sender as? NSSegmentedControl{
            
            let newType:DetectorType
                       
            switch segControl.selectedSegment{
            case 0:
                newType = DetectorType.integrating
                lrud_xySegmented.isEnabled = false


            case 1:
                newType = DetectorType.dpc
                lrud_xySegmented.setLabel("lr", forSegment: 0)
                lrud_xySegmented.setLabel("ud", forSegment: 1)
                lrud_xySegmented.isEnabled = true

            case 2:
                newType = DetectorType.com
                
                lrud_xySegmented.setLabel("x", forSegment: 0)
                lrud_xySegmented.setLabel("y", forSegment: 1)

                 lrud_xySegmented.isEnabled = true

            default:
                newType = DetectorType.integrating
                lrud_xySegmented.isEnabled = false
            }
            

        
            
            patternViewer.detectorView?.detectorType = newType
            patternViewer.detectorView?.needsDisplay = true
            
            selectedDetector = patternViewer.detectorView!.detector
            self.detectImage(stride: 1)
            
        }else{
            print("detector not sent by segmented control")
        }
    }
    
    @IBAction func selectDetectorShape(_ sender:Any){
    
        if let segControl = sender as? NSSegmentedControl{
            
            let newShape:DetectorShape
            
            switch segControl.selectedSegment{
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
            
        }else{
            print("detector not sent by segmented control")
        }
    }
    
    func openPanel(){
    
        let openPanel = NSOpenPanel()
        openPanel.allowedFileTypes = ["raw", "public.tiff", ]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = true
        
        if (openPanel.runModal() == NSApplication.ModalResponse.OK){
            
            let selectedURL = openPanel.url
            
            if selectedURL != nil{
            dataController.filePath = selectedURL
            

                self.view.window?.title = selectedURL!.deletingPathExtension().lastPathComponent
                
            self.displayProbePositionsSelection(openPanel.url)
            }
        }

    }
    
    @objc func didFinishLoadingData() {
        
        if patternViewer.detectorView?.isHidden == true{
        patternViewer.detectorView!.detector = Detector(shape: DetectorShape.bf, type: DetectorType.integrating, center: NSPoint.init(x: 63, y:63), radii: DetectorRadii(inner: CGFloat(innerAngleTextField.floatValue), outer: CGFloat(outerAngleTextField.floatValue)))
        }
        
        
        patternViewer.detectorView?.isHidden = false
        
        imageView.isHidden = false
        imageView.selectionRect = nil
        
        self.detectImage()
        self.selectPatternAt(dataController.imageSize.height/2, dataController.imageSize.width/2)

    }
    
    @IBAction func displayProbePositionsSelection(_ sender: Any){
       
        let probeController = storyboard?.instantiateController(withIdentifier: NSStoryboard.SceneIdentifier(rawValue: "ProbeSelectViewController")) as! ProbeSelectViewController

        
        self.presentViewControllerAsModalWindow(probeController as! ProbeSelectViewController)
        
        probeController.dataController = dataController
        probeController.parentController = self
        probeController.selectSizeFromURL(sender as! URL)
        
        let ext = (sender as! URL).pathExtension
        
        let uti = UTTypeCreatePreferredIdentifierForTag(
            kUTTagClassFilenameExtension,
            ext as CFString,
            nil)
        
        if UTTypeConformsTo((uti?.takeRetainedValue())!, kUTTypeTIFF) {
            probeController.acceptSize(self)
        }

        


    }
    

    @IBAction func export(_ sender:Any){
        
        
        let menuItem = sender as! NSMenuItem
        
        let savePanel = NSSavePanel()
        
        savePanel.canCreateDirectories = true
        savePanel.showsTagField = false
        savePanel.isExtensionHidden = false
        savePanel.allowedFileTypes = ["tif"]
        
        if menuItem.tag == 0{
            var lrud_xyLabel = ""
            
            let detector =  self.patternViewer.detectorView?.detector

            
            if detector?.type == DetectorType.com || detector?.type == DetectorType.dpc{
                lrud_xyLabel = "_" + lrud_xySegmented.label(forSegment: lrud_xySegmented.selectedSegment)!

            }
            let detectorTypeLabel = detectorTypeSegmented.label(forSegment: detectorTypeSegmented.selectedSegment)!
            
                savePanel.nameFieldStringValue = (self.view.window?.title)! + "_" + detectorTypeLabel  + lrud_xyLabel
            
        }else if menuItem.tag == 1{
            savePanel.nameFieldStringValue = (self.view.window?.title)!+"_"+(patternSelectionLabel?.stringValue)!

        }
        
        
        

        savePanel.begin( completionHandler:{(result) in
            
            if result == NSApplication.ModalResponse.OK {
                let filename = savePanel.url
                
                
                var bitmapRep:NSBitmapImageRep?
               
          
                if(menuItem.tag == 0){
                    bitmapRep = self.imageView.matrix.floatImageRep()
                    
                }else if menuItem.tag == 1{
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
    
    @IBAction func zoomIn(_ sender: NSMenuItem?) {
        
        if zoomFactor + 0.1 > 10 {
            
            zoomFactor = 10
            
        } else if zoomFactor == 0.05 {
            
            zoomFactor = 0.1
            
        } else {
            
            zoomFactor += 0.1
            
        }
        
    }
    
    @IBAction func zoomOut(_ sender: NSMenuItem?) {
        
        if zoomFactor - 0.1 < 0.05 {
            
            zoomFactor = 0.05
            
        } else {
            
            zoomFactor -= 0.1
            
        }
        
    }
    
    @IBAction func zoomToActual(_ sender: NSMenuItem?) {
        
        zoomFactor = 1.0
        
    }
    
    @IBAction func zoomToFit(_ sender: NSMenuItem?) {
        
        guard imageView!.image != nil else {
            
            return
            
        }
        
        let imSize = imageView!.image!.size
        
        var clipSize = clipView.bounds.size
        
        guard imSize.width > 0 && imSize.height > 0 && clipSize.width > 0 && clipSize.height > 0 else {
            
            return
            
        }
        
        //We want a 20 pixel gutter. To make the calculations easier, adjust the clipbounds down to account for the gutter. Use 2 * the pixel gutter, since we are adjusting only the height and width (this accounts for the left and right margin combined, and the top and bottom margin combined).
        let imageMargin:CGFloat = 40
        
        clipSize.width -= imageMargin
        clipSize.height -= imageMargin
        
        let clipAspectRatio = clipSize.width / clipSize.height
        let imAspectRatio = imSize.width / imSize.height
        
        if clipAspectRatio > imAspectRatio {
            
            zoomFactor = clipSize.height / imSize.height
            
        } else {
            
            zoomFactor = clipSize.width / imSize.width
            
        }
        
    }



}

