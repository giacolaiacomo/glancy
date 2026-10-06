// Removes the preference files the tests create (one UserDefaults suite per test, with a UUID in
// its name) when the test process exits, so ~/Library/Preferences doesn't fill up run after run.
int glancy_prefs_sweeper_installed(void);
