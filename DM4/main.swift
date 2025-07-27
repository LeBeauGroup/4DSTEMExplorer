//
//  main.swift
//  DM4
//
//  Created by James LeBeau on 7/22/25.
//  Copyright © 2025 The LeBeau Group. All rights reserved.
//

import Foundation

public extension String {

    var expandingTildeInPath: String {
            return NSString(string: self).expandingTildeInPath
        }

}

let fileURL = "~/Desktop/test_data/Diffraction SI-2.dm4".expandingTildeInPath

let url = URL(fileURLWithPath: fileURL)
print(url.absoluteString)
let dm4 = try DigitalMicrographReader(fileURL: url)

print(dm4.tagsDict)






