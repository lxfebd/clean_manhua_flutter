#include <stdint.h>

__declspec(dllexport) int64_t demo_sum(int64_t a, int64_t b) {
    return a + b;
}

__declspec(dllexport) int64_t demo_version(void) {
    return 0x20260911LL;
}
