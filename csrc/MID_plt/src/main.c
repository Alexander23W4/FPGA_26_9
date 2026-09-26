/******************************************************************************
* main.c —— 启动 + 命令分发骨架
*
*   串口上同时跑两套协议，靠【第一个字节】区分：
*
*       1) test 名：一整行，以 '-' 开头，'\n' 结尾
*              例如  -pl_ctrl_test
*          -> 查下面 tests[] 表，跑对应的 test
*
*       2) 单字母命令：老的那套
*              例如  A / I / E / D / N / ?
*          -> 交给 app.c 的 app_exec()，和以前完全一样
*              （'D' 后面还会跟 4 字节索引，那些字节不给 main 看）
*
*   ★ 加一个新 test 只要两步，main() 本身一个字都不用改：
*       1. 写一个 void xxx_test_run(void)，里面自己 while(1)
*       2. 在下面 tests[] 注册表里加一行
*
*   ★ 为什么先收【一个字节】再决定，而不是一上来就收整行：
*       老命令是"一个字节 + 后面可能跟二进制参数"，如果死等 '\n'
*       就会和 PC 脚本互相等死（脚本只发 1 个字节就不发了）。
******************************************************************************/

#include "platform.h"
#include "app/app.h"
#include "common/uartln.h"
#include "xil_printf.h"
#include "xil_types.h"

/* --------------------------------------------------------------------------
 *  test 注册表
 *
 *  name 不带 '-'；run 函数自己负责循环，一般跑起来就不返回。
 * ---------------------------------------------------------------------- */
extern void pl_ctrl_test_run(void);     /* pl_ctrl_test.c */

typedef struct {
    const char *name;
    const char *desc;
    void      (*run)(void);
} test_entry_t;

static const test_entry_t tests[] = {
    { "pl_ctrl_test", "PL control, single-image mode: eMMC -> DDR -> analyse, 3 images loop",
      pl_ctrl_test_run },
};
#define TEST_COUNT  (sizeof(tests) / sizeof(tests[0]))

/* app.c 提供的单字母命令分发（和 app_run() 用的是同一张表） */
extern int app_exec(char c);

/* -------------------------------------------------------------------------- */
static void test_help(void)
{
    u32 i;

    xil_printf("\r\ntests (send the whole line, starting with '-'):\r\n");
    for (i = 0u; i < TEST_COUNT; i++) {
        xil_printf("  -%-16s  %s\r\n", tests[i].name, tests[i].desc);
    }
    xil_printf("\r\nsingle-letter commands: send the letter (see the table above)\r\n");
}

/* 收 test 名字剩下的部分（'-' 之后的），到 '\n' 为止。返回长度 */
static u32 read_line_rest(char *buf, u32 cap)
{
    u32 n = 0u;

    for (;;) {
        char c = (char)uartln_getc();

        if (c == '\n') {
            break;
        }
        if (c == '\r') {
            continue;
        }
        if (n < (cap - 1u)) {
            buf[n] = c;
            n++;
        }
    }
    buf[n] = '\0';
    return n;
}

/* --------------------------------------------------------------------------
 *  check_args —— 自动识别这一行要执行哪个 test
 *
 *    line : 串口收到的一整行（已含开头的 '-'，已去掉结尾的 \n）
 *    认出来就跑，认不出来就打印提示。函数不返回"没处理"这种状态：
 *    只要是以 '-' 开头的，就都是 test 通道的事。
 * ---------------------------------------------------------------------- */
static void check_args(const char *line)
{
    const char *name = line;
    u32 i;

    if (name[0] == '-') {
        name++;
    }

    if (name[0] == '\0') {
        test_help();
        return;
    }

    for (i = 0u; i < TEST_COUNT; i++) {
        const char *a = name;
        const char *b = tests[i].name;

        while ((*a != '\0') && (*a == *b)) {
            a++;
            b++;
        }
        if ((*a == '\0') && (*b == '\0')) {
            xil_printf("\r\n[test] %s\r\n", name);
            tests[i].run();
            /* test 正常是死循环；能回到这里说明它自己跑完了 */
            xil_printf("\r\n===== END =====\r\n");
            return;
        }
    }

    xil_printf("unknown test '%s'\r\n", name);
    test_help();
}

/* -------------------------------------------------------------------------- */
int main(void)
{
    char line[64];

    init_platform();

    xil_printf("\r\n");
    xil_printf("===== FPGA_26 medical imaging : PS side =====\r\n");
    xil_printf("built : %s %s\r\n", __DATE__, __TIME__);

    app_init();     /* 探测 eMMC / VDMA，打印单字母命令表 */
    test_help();    /* 再把 -test 这一套列出来 */

    for (;;) {
        int c;

        xil_printf("\r\n> ");
        c = (int)uartln_getc();

        /* 串口终端敲回车会多送一个 \r 或 \n，静默吃掉 */
        if ((c == '\r') || (c == '\n')) {
            continue;
        }

        if (c == '-') {
            /* test 名：收完整行 */
            line[0] = '-';
            (void)read_line_rest(&line[1], (u32)sizeof(line) - 1u);
            check_args(line);
        } else {
            /* 老的单字母命令。后面的二进制参数由对应 feature 自己收 */
            (void)app_exec((char)c);
        }
    }

    cleanup_platform();     /* 上面的循环不会返回，留着保持形式完整 */
    return 0;
}
