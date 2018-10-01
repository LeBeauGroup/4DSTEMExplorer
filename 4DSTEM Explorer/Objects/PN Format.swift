//
//  PN Format.swift
//  4DSTEM Explorer
//
//  Created by James LeBeau on 9/26/18.
//  Copyright © 2018 The LeBeau Group. All rights reserved.
//

import Foundation


func pnHeader(_ url: URL)throws ->[String:Any] {

    var properties = [String:Any]()
    
    var fh:FileHandle?
    
    do{
        try fh =  FileHandle.init(forReadingFrom: url)
        
    }catch{
        
    }
    
    // Read the first 2 bytes, should == UInt16(1024)
    
    var sizeHeader = UInt16(0)
    
    fh?.readData(ofLength: 2).withUnsafeBytes{(ptr: UnsafePointer<UInt16>) in
        sizeHeader = ptr.pointee
        
    }
    
    if(sizeHeader != 1024){
       throw FileReadError.invalidFrms6
    }
    
    var sizeFrameHeader = UInt16(0)
    
    fh?.readData(ofLength: 2).withUnsafeBytes{(ptr: UnsafePointer<UInt16>) in
        sizeFrameHeader = ptr.pointee
        
    }
    
    // skip two btyes
    
    fh?.readData(ofLength: 2)
    
    var fileVersion = UInt8(0)
    
    fh?.readData(ofLength: 2).withUnsafeBytes{(ptr: UnsafePointer<UInt8>) in
        fileVersion = ptr.pointee
        
    }
    
    var comment1:String
    
    fh?.readData(ofLength: 80).withUnsafeBytes{(ptr: UnsafePointer<CChar>) in
        
        let chars:CChar = ptr.pointee
        
    }

    var columns = UInt16(0)
    fh?.readData(ofLength: 2).withUnsafeBytes{(ptr: UnsafePointer<UInt16>) in
        columns = ptr.pointee
        
    }
    
    var rows = UInt16(0)
    fh?.readData(ofLength: 2).withUnsafeBytes{(ptr: UnsafePointer<UInt16>) in
        rows = ptr.pointee
        
    }
    
    var commen2:String
    fh?.readData(ofLength: 928).withUnsafeBytes{(ptr: UnsafePointer<CChar>) in
        let chars:CChar = ptr.pointee

    }
    
    var frameCount = UInt32(0)
    fh?.readData(ofLength: 2).withUnsafeBytes{(ptr: UnsafePointer<UInt32>) in
        frameCount = ptr.pointee
        
    }
    
    let frameHeaderSkip = 64
    
    
    
    
    return properties
}
