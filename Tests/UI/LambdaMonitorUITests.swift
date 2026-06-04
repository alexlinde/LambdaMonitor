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

        // The launch dialog is a dedicated Window (see DIALOG.md), not an
        // in-popover sheet. The H100 fixture has two regions and two SSH keys,
        // so the configuration form is shown.
        let launchWindow = app.windows["Launch Instance"]
        XCTAssertTrue(
            launchWindow.waitForExistence(timeout: 5),
            "Launch window should open from the row's Launch button"
        )

        let confirm = launchWindow.buttons["launch-sheet-confirm"]
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 5),
            "Launch window should present a confirm button"
        )
        XCTAssertTrue(launchWindow.buttons["launch-sheet-cancel"].exists)
        confirm.click()

        // The window swaps the form for the progress spinner in place while
        // the request runs (mock returns in ~800ms).
        let progressTitle = launchWindow.staticTexts["launch-progress-title"]
        XCTAssertTrue(
            progressTitle.waitForExistence(timeout: 3),
            "Launch progress should show in the launch window while the API request runs"
        )

        // The window dismisses itself once the launch completes.
        XCTAssertTrue(
            self.waitFor({ !launchWindow.exists }, timeout: 8),
            "Launch window should close after the launch completes"
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

    func testLaunchWithDifferentSSHKeyAndImagePassesThemThrough() {
        let launch = window.buttons["launch-button-gpu_1x_h100_sxm5"]
        XCTAssertTrue(launch.waitForExistence(timeout: 5))
        launch.click()

        let launchWindow = app.windows["Launch Instance"]
        XCTAssertTrue(launchWindow.waitForExistence(timeout: 5))

        // Pick a non-default SSH key. The mock seeds two keys and the app
        // preselects "my-laptop", so choosing "work-desktop" is a real change.
        let sshPicker = launchWindow.popUpButtons["launch-sheet-ssh-key"]
        XCTAssertTrue(sshPicker.waitForExistence(timeout: 5), "SSH key dropdown should be present")
        sshPicker.click()
        let workDesktop = app.menuItems["work-desktop"]
        XCTAssertTrue(workDesktop.waitForExistence(timeout: 3))
        workDesktop.click()

        // Pick a non-default image family (default is "Lambda Stack (latest)").
        let imagePicker = launchWindow.popUpButtons["launch-sheet-image"]
        XCTAssertTrue(imagePicker.waitForExistence(timeout: 3), "Image dropdown should be present")
        imagePicker.click()
        let ubuntu = app.menuItems["ubuntu-lts"]
        XCTAssertTrue(ubuntu.waitForExistence(timeout: 3))
        ubuntu.click()

        launchWindow.buttons["launch-sheet-confirm"].click()
        XCTAssertTrue(
            waitFor({ !launchWindow.exists }, timeout: 8),
            "Launch window should close after the launch completes"
        )
        window.buttons["refresh-button"].click()

        // The deterministic mock encodes the SSH key + image family it actually
        // received into the synthesized running instance's identifier, so a row
        // containing both proves the dialog's selection reached the API.
        let newRow = window.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier CONTAINS 'work-desktop' AND identifier CONTAINS 'ubuntu-lts'"
            ))
            .firstMatch
        XCTAssertTrue(
            newRow.waitForExistence(timeout: 5),
            "Launched row should encode the selected SSH key and image, proving they were sent to the API"
        )
    }

    func testLaunchSheetCancelDoesNotLaunch() {
        let launch = window.buttons["launch-button-gpu_1x_h100_sxm5"]
        XCTAssertTrue(launch.waitForExistence(timeout: 5))
        launch.click()

        let launchWindow = app.windows["Launch Instance"]
        let cancel = launchWindow.buttons["launch-sheet-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()

        XCTAssertTrue(
            waitFor({ !launchWindow.exists }, timeout: 3),
            "Launch window should close on Cancel"
        )

        let synthetic = window.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'running-row-i-uitest'"))
        XCTAssertEqual(
            synthetic.count, 0,
            "Cancelling the launch window should not produce a launched instance"
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

        // The terminate confirmation is a dedicated Window (see DIALOG.md),
        // not an in-popover sheet/confirmationDialog. Scope to the window so we
        // don't match the row's own Terminate button.
        let terminateWindow = app.windows["Terminate Instance"]
        XCTAssertTrue(
            terminateWindow.waitForExistence(timeout: 5),
            "Terminate confirmation should present as a dedicated window"
        )
        terminateWindow.buttons["terminate-sheet-confirm"].click()

        let progressTitle = terminateWindow.staticTexts["terminate-progress-title"]
        XCTAssertTrue(
            progressTitle.waitForExistence(timeout: 3),
            "Terminate progress should show in the terminate window while the API request runs"
        )

        // Mock client removes the instance from its running list on terminate.
        // The fetch triggered by the service drops the row, and the window
        // dismisses itself when the operation completes.
        XCTAssertTrue(
            waitFor({ !row.exists && !terminateWindow.exists }, timeout: 8),
            "Running row should disappear and the terminate window should close after terminate completes"
        )
    }

    func testTerminateCancelKeepsRunningRow() {
        let row = window.groups["running-row-i-abc123def456"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        window.buttons["terminate-button-i-abc123def456"].click()

        let terminateWindow = app.windows["Terminate Instance"]
        XCTAssertTrue(
            terminateWindow.waitForExistence(timeout: 5),
            "Terminate confirmation should present as a dedicated window"
        )
        terminateWindow.buttons["terminate-sheet-cancel"].click()

        XCTAssertTrue(
            waitFor({ !terminateWindow.exists }, timeout: 3),
            "Terminate window should close on Cancel"
        )

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
