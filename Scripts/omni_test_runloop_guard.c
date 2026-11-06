#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Swift 6.2+ can exit a still-running async test main when AppKit stops its
// run loop (swiftlang/swift#91716). Only resume that exact worker/runtime path.
// Testing's own success/failure exit and all other processes remain untouched.
__attribute__((noreturn)) static void keep_async_test_main_alive(int status) {
    Dl_info caller = {0};
    dladdr(__builtin_return_address(0), &caller);
    if (status == 0 && strcmp(getprogname(), "swiftpm-testing-helper") == 0 &&
        caller.dli_fname && strstr(caller.dli_fname, "libswift_Concurrency.dylib")) {
        fprintf(stderr, "Omni test worker: resume stopped async main run loop (swift#91716)\n");
        for (;;) CFRunLoopRun();
    }
    exit(status);
    __builtin_unreachable();
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *original;
} interposer = {(const void *)keep_async_test_main_alive, (const void *)exit};
