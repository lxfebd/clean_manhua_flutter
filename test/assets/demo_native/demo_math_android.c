#include <stdint.h>

#if defined(__ANDROID__) && defined(__arm__)
// Android armeabi-v7a 默认 FPU/调用约定差异最小化：纯整数运算无影响，仅占位注释。
#endif

/* Android .so 导出：__attribute__((visibility("default"))) 保证导出符号可见 */
__attribute__((visibility("default"))) int64_t demo_sum(int64_t a, int64_t b) {
    return a + b;
}

__attribute__((visibility("default"))) int64_t demo_version(void) {
    return 0x20260911LL;
}
