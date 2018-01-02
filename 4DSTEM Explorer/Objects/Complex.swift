//
//  Complex.swift
//  Ronchigram
//
//  Created by James LeBeau on 5/19/17.
//  Copyright © 2017 The Handsome Microscopist. All rights reserved.
//

import Foundation


struct Complex:CustomStringConvertible{

    // a+ib
    
    var a: Float = 0.0
    var b: Float = 0.0
    
    init(_ a:Float, _ b:Float) {
        self.a = a
        self.b = b
    }
    
    init(_ a:Int, _ b:Int) {
        self.a = Float(a)
        self.b = Float(b)
    }
    
    init(_ a:Int) {
        self.a = Float(a)
    }
    
    init(_ a:Float) {
        self.a = a
    }


    var description: String{
        
        var sign:String;
        
        if(b < 0){
            sign = "-"
        }else{
            sign = "+"
        }
        
        return String(a) + sign + String(Swift.abs(b)) + "i"
    }
    
    func abs() -> Float {
        return sqrt(a*a+b*b)
    }
    
    func conj() -> Complex{
        return Complex(a, -b)
    }
    
    func real() -> Float {
        return a
    }
    
    func imag() -> Float {
        return b
    }

    
}

func -(lhs:Complex,rhs:Complex) -> Complex {
    return Complex(lhs.a-rhs.a, lhs.b-rhs.b)
}

func +(lhs:Complex,rhs:Complex) -> Complex {
    return Complex(lhs.a+rhs.a, lhs.b+rhs.b)
}

func *(lhs:Complex,rhs:Complex) -> Complex {
    
    let prodA = lhs.a*rhs.a-lhs.b*rhs.b;
    let prodB = lhs.a*rhs.b+lhs.b*rhs.a;
    
    return Complex(prodA, prodB)
}

func /(lhs:Complex,rhs:Complex) -> Complex {
    
    
    let numer = lhs*rhs.conj()
    let denom = rhs*rhs.conj()
    
    return numer/denom.a
}

func /(lhs:Complex,rhs:Float) -> Complex {
    
    let divA = lhs.a/rhs
    let divB = lhs.b/rhs
    
    return Complex(divA, divB)
}

