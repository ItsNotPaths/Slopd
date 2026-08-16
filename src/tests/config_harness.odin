package tests

import app ".."
import "core:sync"

// Pointing the config file at a scratch file, for the tests that write settings back.

// ONE TEST AT A TIME MAY REDIRECT THE CONFIG, for the same reason only one may hold Clay
// (see clay_harness.odin): app.config_path_override is a single string for the whole
// process and `odin test` runs tests on several threads inside it. Thirteen tests point it
// at a scratch file of their own and clear it again on the way out — in parallel they clear
// each OTHER's, and the loser of that race falls through to the real config file.
//
// That file is the slopd.config sitting in the working directory, so the test then asserts
// against the settings of whoever ran it: test_config_writeback wanted indent width 2 and
// read the 4 this repo ships. Worse than the wrong answer is the right one — a developer
// whose config happens to match the fixture sees the suite pass, and CI does not.
//
// The lock also protects the shipped file itself. config_set WRITES, so a test that ran
// with the override cleared out from under it would not merely misread the developer's
// config, it would edit it.
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
