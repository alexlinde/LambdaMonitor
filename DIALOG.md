# Dialogs in a Menu Bar App

This app's menu lives in a `MenuBarExtra` with `.menuBarExtraStyle(.window)`.
That style hosts the menu content in a **transient `NSPanel`** that dismisses
itself the moment it resigns key. This single fact dictates how every dialog in
this app must be built. This document is the canonical reference — follow it for
any new dialog.

## The problem

A `MenuBarExtra(.window)` panel collapses as soon as focus leaves it. Clicking a
button inside a presented `.sheet` / `.confirmationDialog` / `NSAlert` moves
focus, so the panel resigns key and tears down **before** the button's action
runs. The symptoms we kept hitting:

- **Launch region dialog**: clicking "Launch" in the sheet just closed the
  dialog. The popover collapsed, the row view that owned the sheet's `@State`
  binding was destroyed mid-flight, and the action was dropped. The sheet's
  `isPresented` got stuck at `true`, so the dialog appeared to "come back" the
  next time the popover opened.
- **Progress spinner**: the click that *started* a launch/terminate collapsed
  the popover, so the spinner sheet never became visible. Reopening the menu
  showed the spinner that had been there all along.

These are not bugs in our SwiftUI code — they are a structural property of
presenting anything *inside* the menu-bar panel.

## The rule

**Any dialog that requires user input or shows operation progress MUST be a
dedicated top-level `Window` scene — never a `.sheet` or `.confirmationDialog`
inside the popover.**

A real window is key-able and independent of the popover, so popover dismissal
can't touch it. This is exactly why the Settings window has always worked, and
it is the reference implementation for every other dialog.

### The pattern (Settings is the model)

1. Declare a `Window` scene in the app's `body: some Scene`, with a stable `id`:

   ```swift
   Window("Launch Instance", id: "launch") {
       LaunchWindowView(apiService: apiService)
   }
   .windowResizability(.contentSize)
   .defaultPosition(.center)
   ```

2. Trigger it from the popover by setting `@Observable` service state, then
   activating the app and opening the window:

   ```swift
   apiService.pendingLaunch = instance
   NSApp.activate(ignoringOtherApps: true)   // bring the window to the front
   openWindow(id: "launch")                  // @Environment(\.openWindow)
   ```

3. Render the window purely from service state, and self-dismiss when the
   operation finishes:

   ```swift
   // activeLaunchProgress != nil -> spinner
   // pendingLaunch != nil        -> configuration form
   // both nil                    -> finished, dismiss()
   .onChange(of: isFinished) { _, finished in
       if finished { dismiss() }
   }
   ```

This keeps a single window for the whole operation: it shows the input form,
swaps **in place** to the progress spinner once the request starts, then
dismisses itself when the service clears the state. Because the dialog never
lives inside the popover, the click that confirms the action can't destroy it.

### Keeping the progress spinner perceptible

A window that opens and self-dismisses the instant the API returns just
flashes — against the real (fast) API the user never registers it. Two things
keep the spinner meaningful:

- The launch/terminate flows `await` the follow-up refresh (`performFetch()`)
  before clearing the progress state, so the spinner stays up until the
  running-instance list actually reflects the change (new row appears / old row
  disappears).
- `LambdaAPIService.minimumSpinnerDuration` (default 800ms) enforces a floor on
  how long the progress state is held, so even an instant response shows a
  perceptible spinner. Tests set this to `.zero`.

Note this is also why the UI-test mock uses a long `operationDelay` — XCUITest's
first snapshot of the window lands ~1.5s after the confirming click, so the
spinner has to stay on screen well beyond that to be observable.

### Why drive it from service state instead of a `@Binding`?

The popover row that launches the dialog can be (and is) torn down when the
popover closes. If the dialog's lifetime were owned by the row's `@State`, it
would die with the row. Storing `pendingLaunch` / `pendingTerminate` /
`activeLaunchProgress` / `activeTerminateProgress` on the long-lived
`LambdaAPIService` decouples the dialog's lifetime from the popover entirely.
The snapshots (`pendingLaunch: OfferedInstanceType?`) also ensure a background
refresh can't yank the dialog's subject out from under it.

## Allowed exception: fire-and-forget `NSAlert`

`NSAlert.runModal()` is acceptable **only** for simple, self-contained
informational or confirmation alerts that don't depend on popover-owned state,
and only after `NSApp.activate(ignoringOtherApps: true)`. Examples in this app:

- The "Clear API Key?" confirmation in `SettingsView` — it runs from the
  Settings window, which is already a real key window.
- `pendingAlert` errors in `InstanceListView` — surfaced via `NSAlert` after
  activating; these are terminal "it failed" messages, not multi-step flows.

Never tie an `NSAlert` (or any modal) to a `@State`/`@Binding` owned by a view
inside the popover.

## Testing caveat (important)

The XCUITest harness (`presentUITestWindow` in `LambdaMonitorApp`) hosts
`InstanceListView` in a **plain `NSWindow`**, not in the `MenuBarExtra` panel.
A normal window does not resign-key-collapse, so **sheet-based dialogs can pass
the UI tests while still failing in the real menu-bar build**. Do not trust a
green UI-test run as proof a dialog works in production.

When changing dialog behavior:

- Update the UI tests to drive the dialog's `Window` (e.g.
  `app.windows["Launch Instance"]`), not `app.sheets`.
- Always verify manually in the real menu-bar build (`./build.sh`), especially
  a watched type with multiple regions (forces the configuration form) and a
  terminate from the popover.

## Checklist for a new dialog

- [ ] Needs input or shows progress? -> it's a `Window`, not a sheet.
- [ ] State lives on `LambdaAPIService`, not on a popover-owned `@State`.
- [ ] Triggered via `set state -> NSApp.activate -> openWindow(id:)`.
- [ ] Window renders from state and `dismiss()`es itself when state clears.
- [ ] UI test targets the window by title; manual check in `./build.sh`.
