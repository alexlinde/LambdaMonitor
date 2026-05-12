import XCTest

/// Shared base providing a launched `XCUIApplication` configured with the
/// `--ui-test` deterministic mock backend. Each test launches a fresh app
/// instance and tears it down on completion so flows don't leak state.
@MainActor
class LambdaMonitorUITestCase: XCTestCase {
    var app: XCUIApplication!
    var window: XCUIElement { app.windows["Lambda Monitor (UI Test)"] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launch()
        XCTAssertTrue(
            window.waitForExistence(timeout: 10),
            "UI-test window should appear within 10s of launch"
        )
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        try super.tearDownWithError()
    }
}

// MARK: - Smoke

final class LambdaMonitorSmokeTests: LambdaMonitorUITestCase {
    func testWindowAndToolbar() {
        XCTAssertTrue(window.buttons["refresh-button"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.buttons["settings-button"].exists)
        XCTAssertTrue(window.buttons["quit-button"].exists)
    }

    func testRefreshButtonClickKeepsWindowAlive() {
        let refresh = window.buttons["refresh-button"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        refresh.click()
        // Mock client returns the same data on every fetch, so the only
        // observable signal is that the window keeps responding.
        XCTAssertTrue(window.exists)
        XCTAssertTrue(window.buttons["refresh-button"].exists)
    }
}

// MARK: - Watch toggle

final class LambdaMonitorWatchTests: LambdaMonitorUITestCase {
    func testToggleWatchOnA100MovesItUnderWatchedSection() {
        // A100 starts unavailable; toggling its bell should add the row to the
        // "Watched" section and update the bell's accessibility label.
        let bell = window.buttons["watch-toggle-gpu_1x_a100_sxm4"]
        XCTAssertTrue(bell.waitForExistence(timeout: 5))
        XCTAssertEqual(bell.label, "Watch for availability")
        bell.click()

        // After toggling, the same identifier should now expose the "Stop
        // watching" label.
        let watchingBell = window.buttons["watch-toggle-gpu_1x_a100_sxm4"]
        XCTAssertTrue(
            waitForLabel("Stop watching", on: watchingBell, timeout: 3),
            "Bell label should flip to Stop watching after toggling"
        )

        // The watched section header should now exist.
        XCTAssertTrue(
            window.staticTexts["section-header-watched"].waitForExistence(timeout: 3),
            "Watched section header should appear after toggling a row"
        )
    }

    /// Polls the element's label until it equals `expected` or `timeout`
    /// expires. XCUIElement.label isn't a key-value observable property, so
    /// `waitForExistence` doesn't help here.
    private func waitForLabel(
        _ expected: String, on element: XCUIElement, timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label == expected { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}

// MARK: - Settings

final class LambdaMonitorSettingsTests: LambdaMonitorUITestCase {
    func testOpenSettingsAndCloseIt() {
        window.buttons["settings-button"].click()

        let settingsWindow = app.windows["Lambda Monitor Settings"]
        XCTAssertTrue(
            settingsWindow.waitForExistence(timeout: 5),
            "Settings window should open from toolbar button"
        )

        // The API key field is exposed; we don't type into it (the --ui-test
        // override already supplies a key) but its presence confirms the
        // SwiftUI form is hooked up.
        XCTAssertTrue(
            settingsWindow.secureTextFields["settings-api-key-field"]
                .waitForExistence(timeout: 3),
            "Settings API key field should be reachable by identifier"
        )

        XCTAssertTrue(settingsWindow.buttons["settings-done-button"].exists)
        settingsWindow.buttons["settings-done-button"].click()
        XCTAssertTrue(
            waitFor({ !settingsWindow.exists }, timeout: 3),
            "Settings window should close after pressing Done"
        )
    }

    private func waitFor(_ predicate: @escaping () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return predicate()
    }
}

// MARK: - Launch flow

final class LambdaMonitorLaunchTests: LambdaMonitorUITestCase {
    func testLaunchH100PresentsSheetAndAddsRunningRow() {
        let launch = window.buttons["launch-button-gpu_1x_h100_sxm5"]
        XCTAssertTrue(launch.waitForExistence(timeout: 5))
        launch.click()

        let confirm = app.buttons["launch-sheet-confirm"]
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 5),
            "Launch sheet should present with a confirm button"
        )
        XCTAssertTrue(app.buttons["launch-sheet-cancel"].exists)
        confirm.click()

        let confirmButton = app.buttons["launch-sheet-confirm"]
        XCTAssertTrue(
            waitFor({ !confirmButton.exists }, timeout: 3),
            "Launch sheet should dismiss after confirming"
        )
        window.buttons["refresh-button"].click()

        // The deterministic mock's `onLaunchInstance` hook appends an
        // `i-uitest...` running instance.
        let newRow = window.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'running-row-i-uitest'"))
            .firstMatch
        XCTAssertTrue(
            newRow.waitForExistence(timeout: 5),
            "A newly launched H100 should appear as a running row"
        )
    }

    func testLaunchSheetCancelDoesNotLaunch() {
        let launch = window.buttons["launch-button-gpu_1x_h100_sxm5"]
        XCTAssertTrue(launch.waitForExistence(timeout: 5))
        launch.click()

        let cancel = app.buttons["launch-sheet-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()

        let confirmButton = app.buttons["launch-sheet-confirm"]
        XCTAssertTrue(
            waitFor({ !confirmButton.exists }, timeout: 3),
            "Launch sheet should dismiss on Cancel"
        )

        let synthetic = window.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'running-row-i-uitest'"))
        XCTAssertEqual(
            synthetic.count, 0,
            "Cancelling the sheet should not produce a launched instance"
        )
    }

    private func waitFor(_ predicate: @escaping () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return predicate()
    }
}

// MARK: - Terminate flow

final class LambdaMonitorTerminateTests: LambdaMonitorUITestCase {
    func testTerminateConfirmRemovesRunningRow() {
        let row = window.groups["running-row-i-abc123def456"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        let terminate = window.buttons["terminate-button-i-abc123def456"]
        XCTAssertTrue(terminate.exists)
        terminate.click()

        // SwiftUI `.confirmationDialog` presents as a sheet with a destructive
        // `Terminate` button. Scope to the sheet so we don't match the row's
        // own Terminate button as well.
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(
            dialog.waitForExistence(timeout: 5),
            "Terminate confirmation dialog should present as a sheet"
        )
        dialog.buttons["Terminate"].click()

        // Mock client removes the instance from its running list on terminate.
        // The next fetch (auto-refresh triggered by the service) drops the row.
        XCTAssertTrue(
            waitFor({ !row.exists }, timeout: 5),
            "Running row should disappear after terminate is confirmed"
        )
    }

    func testTerminateCancelKeepsRunningRow() {
        let row = window.groups["running-row-i-abc123def456"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        window.buttons["terminate-button-i-abc123def456"].click()

        let dialog = app.sheets.firstMatch
        XCTAssertTrue(
            dialog.waitForExistence(timeout: 5),
            "Terminate confirmation dialog should present as a sheet"
        )
        dialog.buttons["Cancel"].click()

        // Row should still exist; the row identifier doesn't change.
        XCTAssertTrue(
            row.exists,
            "Running row should remain after cancelling the terminate dialog"
        )
    }

    private func waitFor(_ predicate: @escaping () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return predicate()
    }
}
