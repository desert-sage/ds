/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * replay_main.c -- a main() that runs a fuzz target's REPLAY without
 * libFuzzer, for fuzz-dsc's MemorySanitizer pass. MSan reports every
 * byte that crosses code it did not instrument, and libFuzzer's driver is not
 * built with it, so the MSan targets link this in place of
 * `-fsanitize=fuzzer`. It does what `-runs=0` does and nothing more: the
 * target's own LLVMFuzzerInitialize, if it has one, then
 * LLVMFuzzerTestOneInput once per input, each in a buffer of exactly its size.
 *
 * Each argument is a file, run as one input, or a directory, whose regular
 * files are run in name order, so one commit gives one order. At the end it
 * prints `replay: ran N input(s)` on stderr, which the gate reads: a replay
 * that ran nothing exits 0 as well. Any unreadable argument is exit 2.
 */

#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);
int LLVMFuzzerInitialize(int *argc, char ***argv) __attribute__((weak));

static unsigned long ran;

static void die(const char *what, const char *path)
{
    fprintf(stderr, "replay: %s: %s\n", what, path);
    exit(2);
}

static void run_file(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (f == NULL) die("cannot open", path);
    if (fseek(f, 0, SEEK_END) != 0) die("cannot seek", path);
    long n = ftell(f);
    if (n < 0 || fseek(f, 0, SEEK_SET) != 0) die("cannot seek", path);
    uint8_t *buf = malloc(n > 0 ? (size_t) n : 1u);
    if (buf == NULL) die("out of memory reading", path);
    if (fread(buf, 1, (size_t) n, f) != (size_t) n) die("cannot read", path);
    fclose(f);
    LLVMFuzzerTestOneInput(buf, (size_t) n);
    free(buf);
    ran++;
}

static int by_name(const void *a, const void *b)
{
    return strcmp(*(char *const *) a, *(char *const *) b);
}

static void run_dir(const char *dir)
{
    DIR *d = opendir(dir);
    if (d == NULL) die("cannot open directory", dir);
    char  **names = NULL;
    size_t  n = 0, cap = 0;
    for (struct dirent *e; (e = readdir(d)) != NULL;) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        if (n == cap) {
            cap = cap ? cap * 2 : 64;
            names = realloc(names, cap * sizeof *names);
            if (names == NULL) die("out of memory listing", dir);
        }
        names[n] = strdup(e->d_name);
        if (names[n] == NULL) die("out of memory listing", dir);
        n++;
    }
    closedir(d);
    qsort(names, n, sizeof *names, by_name);
    for (size_t i = 0; i < n; i++) {
        size_t len = strlen(dir) + 1 + strlen(names[i]) + 1;
        char  *path = malloc(len);
        if (path == NULL) die("out of memory listing", dir);
        snprintf(path, len, "%s/%s", dir, names[i]);
        struct stat st;
        if (stat(path, &st) != 0) die("cannot stat", path);
        if (S_ISREG(st.st_mode)) run_file(path);
        free(path);
        free(names[i]);
    }
    free(names);
}

int main(int argc, char **argv)
{
    if (LLVMFuzzerInitialize != NULL && LLVMFuzzerInitialize(&argc, &argv) != 0) {
        fprintf(stderr, "replay: LLVMFuzzerInitialize failed\n");
        return 2;
    }
    for (int i = 1; i < argc; i++) {
        struct stat st;
        if (stat(argv[i], &st) != 0) die("cannot stat", argv[i]);
        if (S_ISDIR(st.st_mode)) run_dir(argv[i]);
        else run_file(argv[i]);
    }
    fprintf(stderr, "replay: ran %lu input(s)\n", ran);
    return 0;
}
