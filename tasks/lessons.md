# Lessons

Rules from user corrections. Review at session start.

- Every deep link (`x-apple.systempreferences:...`) must have a test that checks the scheme has a handler (`NSWorkspace.urlForApplication(toOpen:)`). A typo in the scheme (hyphen in place of the dot) shipped because only the button was screenshotted, not clicked.
- A button that leaves the app (System Settings, Finder) is not verified by a screenshot. Run the URL with `open` or a test before the batch is reported as done.
- For a clone of a known app, list its presets first (Macs Fan Control has "Full blast") and check each one against the plan.
