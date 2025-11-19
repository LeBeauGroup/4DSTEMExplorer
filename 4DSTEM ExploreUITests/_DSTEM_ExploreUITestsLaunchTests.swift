//
//  _DSTEM_ExploreUITestsLaunchTests.swift
//  4DSTEM ExploreUITests
//
//  Created by James LeBeau on 11/19/25.
//  Copyright © 2025 The LeBeau Group. All rights reserved.
//

import XCTest

final class _DSTEM_ExploreUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
