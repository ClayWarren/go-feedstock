#include <windows.h>
#include <stdio.h>

#if !defined(_M_ARM64) && !defined(__aarch64__)
#error This consumer must be compiled for ARM64.
#endif

int main(int argc, char **argv) {
    if (argc != 3) return 1;
    for (int i = 1; i <= 2; ++i) {
        HMODULE module = LoadLibraryA(argv[i]);
        if (!module) {
            printf("LoadLibrary failed: %lu\n", GetLastError());
            return 2;
        }
        int *value = (int *)GetProcAddress(module, "demo_value");
        int (__cdecl *answer)(void) =
            (int (__cdecl *)(void))GetProcAddress(module, "demo_answer");
        int valid = i == 1 ? value == NULL && answer == NULL
                           : value != NULL && answer != NULL &&
                             *value == 73 && answer() == 42;
        FreeLibrary(module);
        if (!valid) return 3;
        printf("PASS native ARM64 load: %s (%s exports)\n",
               argv[i], i == 1 ? "no" : "explicit");
    }
    return 0;
}
