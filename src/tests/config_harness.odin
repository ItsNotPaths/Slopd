package tests

import app "../slopd"
import "core:sync"

// Pointing the config file at a scratch file, for the tests that write settings back.

// ONE TEST AT A TIME MAY REDIRECT IT, for the reason only one may hold Clay:
// app.config_path_override is a single string and `odin test` runs on several threads. In
// parallel the tests clear each OTHER's override, and the loser falls through to the real
// config file — the developer's own, so the test then asserts against their settings, and a
// developer whose config matches the fixture sees a pass where CI does not.
//
// The lock also protects the shipped file: config_set WRITES, so a test with its override
// cleared would edit the developer's config rather than merely misread it.
//
//     config_override(path)
//     defer config_override_release()
@(private = "file")
config_override_lock: sync.Mutex

config_override :: proc(path: string) {
    sync.lock(&config_override_lock)
    app.config_path_override = path
}

config_override_release :: proc() {
    app.config_path_override = ""
    sync.unlock(&config_override_lock)
}
