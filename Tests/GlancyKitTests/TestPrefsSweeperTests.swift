import Testing
import TestPrefsSweeper

// The sweeper's constructor runs only if its object is linked into the test bundle; referencing
// it here keeps it linked and checks it installed its exit handler.
@Test func testPreferencesAreSweptAtExit() {
    #expect(glancy_prefs_sweeper_installed() == 1)
}
