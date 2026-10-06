#include "TestPrefsSweeper.h"
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int installed;
static time_t started;

// Only test-owned names: never the app's own domain (ai.glancy.app).
static const char *prefixes[] = {
    "glancy.test", "ai.glancy.test", "ai.glancy.isolated.", "lunetta.test", "ai.lunetta.test",
};

static int isTestPrefs(const char *name) {
    size_t n = strlen(name);
    if (n < 7 || strcmp(name + n - 6, ".plist") != 0) return 0;
    for (size_t i = 0; i < sizeof prefixes / sizeof *prefixes; i++)
        if (strncmp(name, prefixes[i], strlen(prefixes[i])) == 0) return 1;
    return 0;
}

// This run's files, and any left over by runs more than an hour ago (a crashed or killed run).
// Files of another run still going (a second worktree) are younger than that and stay.
static void sweep(void) {
    const char *home = getenv("HOME");
    if (!home) return;
    char dir[1024];
    snprintf(dir, sizeof dir, "%s/Library/Preferences", home);
    DIR *d = opendir(dir);
    if (!d) return;
    time_t now = time(NULL);
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!isTestPrefs(e->d_name)) continue;
        char path[2048];
        snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        struct stat st;
        if (stat(path, &st) != 0) continue;
        if (st.st_mtime >= started - 1 || st.st_mtime < now - 3600) unlink(path);
    }
    closedir(d);
}

__attribute__((constructor)) static void install(void) {
    started = time(NULL);
    installed = 1;
    atexit(sweep);
}

int glancy_prefs_sweeper_installed(void) { return installed; }
