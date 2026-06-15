/*
 * acbypass v1.1 - Universal Anti-Cheat Bypass Tool
 *
 * 自动检测并patch安卓游戏中的反作弊SDK
 * 支持TP2/TSS, ACE, Anchor等反作弊系统
 *
 * 功能:
 *   - 自动检测目标进程和反作弊SO
 *   - 全动态PLT发现和patch
 *   - 线程检测和冻结 (ptrace PC→safe_loop)
 *   - syscall filter安装
 *   - SVC扫描和patch
 *   - 安全线程白名单 (Android框架线程)
 *
 * 用法:
 *   acbypass <包名>                  # 自动检测反作弊
 *   acbypass <包名> -s <so名>        # 指定反作弊SO
 *   acbypass <包名> -n               # 不冻结线程
 *   acbypass <包名> -l               # 仅扫描不patch
 *
 * 编译:
 *   aarch64-linux-gnu-gcc -O2 -static -o acbypass acbypass_v1.c
 *
 * 运行:
 *   su -c ./acbypass com.wyhd.shipx.gw
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <ctype.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <sys/uio.h>
#include <dirent.h>
#include <elf.h>

#ifndef NT_PRSTATUS
#define NT_PRSTATUS 1
#endif

/* ====== ANSI颜色 ====== */
#define C_RED     "\033[31m"
#define C_GREEN   "\033[32m"
#define C_YELLOW  "\033[33m"
#define C_CYAN    "\033[36m"
#define C_BOLD    "\033[1m"
#define C_RESET   "\033[0m"

/* ====== 已知反作弊SO名 ====== */
static const char *ac_so_names[] = {
    /* TP2/TSS (腾讯) */
    "libtersafe2.so", "libtersafe.so", "libtp2.so", "libTssSdk.so",
    /* ACE (网易) */
    "libace.so", "libtprt.so",
    /* Anchor/Anti-cheat */
    "libanchore.so", "libanchor.so",
    /* 其他 */
    "librisk.so", "libsecexe.so", "libsecmain.so",
    "libweipai.so", "libxiniu.so", "libsxsecurity.so",
    "libsecsafe.so", "libmsaoaidsec.so",
    /* AGSDK */
    "libagprotobuf.so", "libagssl.so",
    NULL
};

/* ====== 危险函数分类 ====== */
typedef struct {
    const char *name;
    int strategy;  /* 0=ret-1, 1=ret0, 2=safe_loop, 3=syscall_filter */
} DangerFunc;

static const DangerFunc danger_funcs[] = {
    /* ret-1: 应该失败的反作弊检测/保护函数 */
    {"kill",               0},
    {"tgkill",             0},
    {"tkill",              0},
    {"pthread_kill",       0},
    {"raise",              0},
    {"ptrace",             0},
    {"fork",               0},
    {"vfork",              0},
    {"inotify_add_watch",  0},
    {"inotify_init",       0},
    {"inotify_init1",      0},
    {"prctl",              0},
    {"alarm",              0},

    /* ret-1: 阻止新反作弊线程 */
    {"pthread_create",     0},
    {"clone",              0},
    {"__clone",            0},

    /* safe_loop: noreturn函数(必须不返回) */
    {"exit",               2},
    {"_exit",              2},
    {"_Exit",              2},
    {"abort",              2},
    {"exit_group",         2},
    {"__exit_group",       2},

    /* ret0: 应该静默成功 */
    {"signal",             1},
    {"sigaction",          1},
    {"__sigaction",        1},
    {"sigprocmask",        1},
    {"mprotect",           1},

    /* syscall filter */
    {"syscall",            3},
};
#define DANGER_FUNC_COUNT (sizeof(danger_funcs)/sizeof(danger_funcs[0]))

/* ====== ARM64指令 ====== */
static const unsigned char stub_ret0[] = {
    0x00,0x00,0x80,0xD2,  /* mov x0, #0 */
    0xC0,0x03,0x5F,0xD6,  /* ret */
    0x1F,0x20,0x03,0xD5,  /* nop */
    0x1F,0x20,0x03,0xD5,  /* nop */
};
static const unsigned char stub_retm1[] = {
    0x00,0x00,0x80,0x92,  /* movn x0, #0 (x0=-1) */
    0xC0,0x03,0x5F,0xD6,  /* ret */
    0x1F,0x20,0x03,0xD5,  /* nop */
    0x1F,0x20,0x03,0xD5,  /* nop */
};
/* safe_loop: wfe + b 循环 (低功耗卡住线程) */
static const unsigned int safe_loop_code[] = {
    0xD503205F,  /* wfe */
    0x17FFFFFF,  /* b -4 (跳回wfe) */
};
/* syscall filter: 所有syscall返回-1 */
static const unsigned int syscall_filter_code[] = {
    0x92800000,  /* movn x0, #0  (x0 = -1) */
    0xD65F03C0,  /* ret */
};

/* ====== PLT条目(动态发现) ====== */
typedef struct {
    unsigned long long plt_addr;   /* PLT stub地址 */
    int strategy;                   /* patch策略 */
    char name[64];                 /* 函数名 */
    int rela_index;                /* JMPREL索引 */
} DiscoveredPlt;

/* ====== 全局变量 ====== */
static char pkg_name[256] = {0};
static char so_name[256] = {0};
static int pid = 0;
static unsigned long long base = 0;
static unsigned long long so_start = 0, so_end = 0;
static unsigned long long so_rx_start = 0, so_rx_end = 0;
static int mem_fd = -1;
static volatile sig_atomic_t stopped = 0;

static unsigned long long safe_loop_addr = 0;
static unsigned long long syscall_filter_addr = 0;
static unsigned long long code_cave_addr = 0;

static DiscoveredPlt *discovered_plts = NULL;
static int n_discovered = 0;

static int flag_no_freeze = 0;
static int flag_list_only = 0;
static int total_bl_covered = 0;

/* ====== 信号处理 ====== */
void cleanup_handler(int sig) {
    if (pid > 0 && stopped) kill(pid, SIGCONT);
    if (mem_fd >= 0) close(mem_fd);
    _exit(1);
}

/* ====== 内存读写 ====== */
int read_mem(unsigned long long addr, void *buf, size_t sz) {
    if (pread64(mem_fd, buf, sz, addr) != (ssize_t)sz) return -1;
    return 0;
}

int write_mem(unsigned long long addr, const void *buf, size_t sz) {
    if (pwrite64(mem_fd, buf, sz, addr) != (ssize_t)sz) return -1;
    return 0;
}

unsigned int make_branch(unsigned long long src, unsigned long long dst) {
    long long offset = (long long)(dst - src);
    int imm26 = (int)(offset / 4);
    return 0x14000000 | (imm26 & 0x3FFFFFF);
}

/* ====== 进程查找 ====== */
int find_pid_by_pkg(const char *pkg) {
    /* 方法1: pidof */
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "pidof %s 2>/dev/null", pkg);
    FILE *f = popen(cmd, "r");
    if (f) {
        int p = 0;
        if (fscanf(f, "%d", &p) == 1 && p > 0) { pclose(f); return p; }
        pclose(f);
    }
    /* 方法2: 遍历/proc */
    for (int i = 1; i < 65536; i++) {
        char path[64], cmdline[256];
        snprintf(path, sizeof(path), "/proc/%d/cmdline", i);
        f = fopen(path, "r");
        if (!f) continue;
        if (fgets(cmdline, sizeof(cmdline), f) && strcmp(cmdline, pkg) == 0) {
            fclose(f); return i;
        }
        fclose(f);
    }
    return 0;
}

/* ====== 自动检测反作弊SO ====== */
int detect_anticheat_so() {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/maps", pid);
    FILE *f = fopen(path, "r");
    if (!f) return -1;

    char line[512];
    while (fgets(line, sizeof(line), f)) {
        for (int i = 0; ac_so_names[i]; i++) {
            if (strstr(line, ac_so_names[i])) {
                strncpy(so_name, ac_so_names[i], sizeof(so_name) - 1);
                fclose(f);
                return 0;
            }
        }
    }
    fclose(f);
    return -1;
}

/* ====== 查找SO基址和段 ====== */
unsigned long long find_so_base() {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/maps", pid);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char line[512];
    while (fgets(line, sizeof(line), f)) {
        if (strstr(line, so_name)) {
            unsigned long long addr, offset;
            char perms[8];
            if (sscanf(line, "%llx-%*x %4s %llx", &addr, perms, &offset) == 3) {
                if (offset == 0) { fclose(f); return addr; }
            }
        }
    }
    fclose(f);
    return 0;
}

int find_so_regions() {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/maps", pid);
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    so_start = so_end = so_rx_start = so_rx_end = 0;
    char line[512];
    while (fgets(line, sizeof(line), f)) {
        if (strstr(line, so_name)) {
            unsigned long long start, end, offset;
            char perms[8];
            if (sscanf(line, "%llx-%llx %4s %llx", &start, &end, perms, &offset) == 4) {
                if (so_start == 0 || start < so_start) so_start = start;
                if (end > so_end) so_end = end;
                if (perms[2] == 'x' && so_rx_start == 0) {
                    so_rx_start = start; so_rx_end = end;
                }
            }
        }
    }
    fclose(f);
    return (so_start != 0 && so_rx_start != 0) ? 0 : -1;
}

/* ====== 全动态PLT发现 ====== */

/* 从ELF动态段解析所有PLT条目 */
int discover_all_plt() {
    Elf64_Ehdr ehdr;
    if (read_mem(base, &ehdr, sizeof(ehdr)) < 0) return 0;

    /* 找PT_DYNAMIC */
    Elf64_Phdr phdr;
    int found_dyn = 0;
    for (int i = 0; i < ehdr.e_phnum; i++) {
        if (read_mem(base + ehdr.e_phoff + i * ehdr.e_phentsize,
                     &phdr, sizeof(phdr)) < 0) continue;
        if (phdr.p_type == PT_DYNAMIC) { found_dyn = 1; break; }
    }
    if (!found_dyn) { printf(C_RED "[E] ELF无PT_DYNAMIC段\n" C_RESET); return 0; }

    /* 解析动态段 */
    unsigned long long jmprel = 0, symtab = 0, strtab = 0, pltgot = 0;
    size_t pltrelsz = 0;
    for (unsigned long long off = 0; off < phdr.p_memsz; off += sizeof(Elf64_Dyn)) {
        Elf64_Dyn dyn;
        if (read_mem(base + phdr.p_vaddr + off, &dyn, sizeof(dyn)) < 0) break;
        if (dyn.d_tag == DT_NULL) break;
        switch (dyn.d_tag) {
            case DT_JMPREL:   jmprel = dyn.d_un.d_ptr; break;
            case DT_SYMTAB:   symtab = dyn.d_un.d_ptr; break;
            case DT_STRTAB:   strtab = dyn.d_un.d_ptr; break;
            case DT_PLTRELSZ: pltrelsz = dyn.d_un.d_val; break;
            case DT_PLTGOT:   pltgot = dyn.d_un.d_ptr; break;
        }
    }
    if (!jmprel || !symtab || !strtab || !pltrelsz) {
        printf(C_RED "[E] ELF动态段不完整\n" C_RESET);
        return 0;
    }

    int nrels = pltrelsz / sizeof(Elf64_Rela);

    /* 收集所有JMPREL条目的符号名和GOT地址 */
    typedef struct {
        int rela_idx;
        char name[64];
        unsigned long long got_addr;
    } RelaInfo;

    RelaInfo *relas = calloc(nrels, sizeof(RelaInfo));
    if (!relas) return 0;

    for (int i = 0; i < nrels; i++) {
        Elf64_Rela rela;
        if (read_mem(base + jmprel + i * sizeof(Elf64_Rela), &rela, sizeof(rela)) < 0) continue;
        int sym_idx = ELF64_R_SYM(rela.r_info);
        Elf64_Sym sym;
        if (read_mem(base + symtab + sym_idx * sizeof(Elf64_Sym), &sym, sizeof(sym)) < 0) continue;
        relas[i].rela_idx = i;
        relas[i].got_addr = base + rela.r_offset;  /* GOT地址 (虚拟地址需要加base) */
        /* 修正: rela.r_offset对于SO是相对于0的虚拟地址，需要加base */
        /* 实际上对于PIE SO, r_offset已经是相对偏移 */
        if (read_mem(base + strtab + sym.st_name, relas[i].name, 63) < 0) continue;
        relas[i].name[63] = 0;
    }

    /* 找PLT基址: 扫描r-xp段中的PLT stub */
    /* ARM64 PLT stub: adrp x16, <page>; ldr x17, [x16, #off]; add x16, x16, #off; br x17; nop */
    /* 每个stub 16字节, 顺序排列 */
    /* 策略: 找第一个adrp x16 + ldr x17组合, 确定PLT起始地址 */

    size_t code_size = so_rx_end - so_rx_start;
    unsigned int *code = malloc(code_size);
    if (!code) { free(relas); return 0; }
    if (read_mem(so_rx_start, code, code_size) < 0) { free(code); free(relas); return 0; }

    size_t n_insns = code_size / 4;
    unsigned long long plt_base = 0;
    int first_plt_idx = -1;  /* 第一个PLT stub对应的rela索引 */

    /* 扫描PLT stub: 找连续的adrp x16 + ldr x17模式 */
    for (size_t i = 0; i + 4 <= n_insns; i++) {
        unsigned int insn0 = code[i];      /* adrp x16, ... */
        unsigned int insn1 = code[i + 1];  /* ldr x17, [x16, ...] */

        /* 检查adrp x16 */
        if ((insn0 & 0x9F00001F) != 0x90000010) continue;
        /* 检查ldr x17, [x16, #offset] */
        if ((insn1 & 0xFFC003FF) != 0xF9400211) continue;
        /* 检查add x16, x16, #offset */
        unsigned int insn2 = code[i + 2];
        if ((insn2 & 0xFFC003FF) != 0x91000210) continue;
        /* 检查br x17 */
        unsigned int insn3 = code[i + 3];
        if (insn3 != 0xD61F0220) continue;

        /* 找到一个PLT stub! 解码它引用的GOT地址 */
        /* 解码adrp x16 */
        int immhi = (insn0 >> 5) & 0x7FFFF;
        int immlo = (insn0 >> 29) & 0x3;
        int imm21 = (immhi << 2) | immlo;
        if (imm21 & 0x100000) imm21 -= 0x200000;  /* 符号扩展 */
        unsigned long long pc = so_rx_start + i * 4;
        unsigned long long adrp_result = (pc & ~0xFFFULL) + ((long long)imm21 << 12);

        /* 解码ldr x17, [x16, #imm12] */
        int imm12 = (insn1 >> 10) & 0xFFF;
        unsigned long long got_addr = adrp_result + (imm12 * 8);

        /* 在relas中找匹配的GOT地址 */
        for (int r = 0; r < nrels; r++) {
            if (relas[r].got_addr == got_addr || relas[r].got_addr == (got_addr - base)) {
                /* 匹配! 这个PLT stub对应rela[r] */
                /* PLT[n] = PLT_base + n * 16, 其中PLT[0]是resolver */
                /* 但实际上: PLT[1]对应rela[0], PLT[2]对应rela[1], ... */
                /* 所以: stub_addr = PLT_base + (r + 1) * 16 */
                /* => PLT_base = stub_addr - (r + 1) * 16 */
                plt_base = pc - (unsigned long long)(r + 1) * 16;
                first_plt_idx = r;

                printf(C_CYAN "PLT基址发现:\n" C_RESET);
                printf("  首个匹配: %s @ 0x%llx (rela[%d])\n",
                       relas[r].name, pc, r);
                printf("  PLT基址: 0x%llx\n", plt_base);
                goto plt_found;
            }
        }
    }

plt_found:
    free(code);

    if (plt_base == 0) {
        printf(C_RED "[E] 无法自动发现PLT基址!\n" C_RESET);
        free(relas);
        return 0;
    }

    /* 现在用PLT基址计算所有危险函数的PLT地址 */
    discovered_plts = calloc(nrels, sizeof(DiscoveredPlt));
    if (!discovered_plts) { free(relas); return 0; }
    n_discovered = 0;

    for (int i = 0; i < nrels; i++) {
        if (relas[i].name[0] == 0) continue;

        /* 查找是否为危险函数 */
        int strategy = -1;
        for (int d = 0; d < (int)DANGER_FUNC_COUNT; d++) {
            if (strcmp(relas[i].name, danger_funcs[d].name) == 0) {
                strategy = danger_funcs[d].strategy;
                break;
            }
        }
        if (strategy < 0) continue;

        unsigned long long plt_addr = plt_base + (unsigned long long)(i + 1) * 16;

        discovered_plts[n_discovered].plt_addr = plt_addr;
        discovered_plts[n_discovered].strategy = strategy;
        strncpy(discovered_plts[n_discovered].name, relas[i].name, 63);
        discovered_plts[n_discovered].name[63] = 0;
        discovered_plts[n_discovered].rela_index = i;
        n_discovered++;

        printf("  " C_GREEN "[%s]" C_RESET " @ 0x%llx → 策略%d (%s)\n",
               relas[i].name, plt_addr, strategy,
               strategy == 0 ? "ret-1" : strategy == 1 ? "ret0" :
               strategy == 2 ? "safe_loop" : "syscall_filter");
    }

    /* 同时记录PLT结束地址(用于代码洞定位) */
    unsigned long long plt_end = plt_base + (unsigned long long)(nrels + 1) * 16;
    code_cave_addr = (plt_end + 15) & ~0xFULL;  /* 16字节对齐 */

    free(relas);
    return n_discovered;
}

/* ====== 代码洞设置 ====== */
int setup_code_cave() {
    printf("\n--- 设置代码洞 ---\n");

    /* 验证代码洞在r-xp段内 */
    if (code_cave_addr < so_rx_start || code_cave_addr + 64 > so_rx_end) {
        /* PLT后面空间不够, 扫描r-xp段末尾找零填充区域 */
        printf("  PLT后空间不足, 扫描段末尾...\n");
        size_t scan_size = 4096;
        if (so_rx_end - so_rx_start < scan_size)
            scan_size = so_rx_end - so_rx_start;

        unsigned char *tail = malloc(scan_size);
        if (!tail) return -1;
        unsigned long long scan_start = so_rx_end - scan_size;
        if (read_mem(scan_start, tail, scan_size) < 0) { free(tail); return -1; }

        for (size_t i = scan_size - 64; i > 0; i -= 16) {
            int all_zero = 1;
            for (size_t j = 0; j < 64; j++) {
                if (tail[i + j] != 0) { all_zero = 0; break; }
            }
            if (all_zero) {
                code_cave_addr = scan_start + i;
                /* 16字节对齐 */
                code_cave_addr = (code_cave_addr + 15) & ~0xFULL;
                break;
            }
        }
        free(tail);
    }

    if (code_cave_addr < so_rx_start || code_cave_addr + 64 > so_rx_end) {
        printf(C_RED "[E] 找不到合适的代码洞空间!\n" C_RESET);
        return -1;
    }

    /* 写入safe_loop */
    safe_loop_addr = code_cave_addr;
    if (write_mem(safe_loop_addr, safe_loop_code, sizeof(safe_loop_code)) < 0) {
        printf(C_RED "[E] safe_loop写入失败\n" C_RESET); return -1;
    }
    /* 验证 */
    unsigned int check[2];
    if (read_mem(safe_loop_addr, check, sizeof(safe_loop_code)) < 0 ||
        check[0] != safe_loop_code[0] || check[1] != safe_loop_code[1]) {
        printf(C_RED "[E] safe_loop验证失败\n" C_RESET); return -1;
    }
    printf("  safe_loop @ 0x%llx: wfe+b (8字节)\n", safe_loop_addr);

    /* 写入syscall filter */
    syscall_filter_addr = code_cave_addr + 16;
    if (write_mem(syscall_filter_addr, syscall_filter_code, sizeof(syscall_filter_code)) < 0) {
        printf(C_RED "[E] syscall filter写入失败\n" C_RESET); return -1;
    }
    unsigned int fc[2];
    if (read_mem(syscall_filter_addr, fc, sizeof(syscall_filter_code)) < 0 ||
        memcmp(fc, syscall_filter_code, sizeof(syscall_filter_code)) != 0) {
        printf(C_RED "[E] syscall filter验证失败\n" C_RESET); return -1;
    }
    printf("  syscall filter @ 0x%llx: movn x0,#0; ret (8字节)\n", syscall_filter_addr);

    /* 测试写入权限 */
    unsigned char test_byte;
    if (read_mem(code_cave_addr + 32, &test_byte, 1) < 0 ||
        write_mem(code_cave_addr + 32, &test_byte, 1) < 0) {
        printf(C_RED "[E] 代码洞写入测试失败! setenforce 0?\n" C_RESET);
        return -1;
    }
    printf("  写入权限: OK\n");

    return 0;
}

/* ====== 线程工具 ====== */
int get_thread_comm(int tid, char *comm, size_t comm_size) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/task/%d/comm", pid, tid);
    FILE *f = fopen(path, "r");
    if (!f) { comm[0] = 0; return -1; }
    if (fgets(comm, (int)comm_size, f) == NULL) { comm[0] = 0; fclose(f); return -1; }
    fclose(f);
    comm[strcspn(comm, "\n")] = 0;
    return 0;
}

int is_safe_thread_name(const char *comm) {
    static const char *safe_patterns[] = {
        "HTTP", "Okio", "CCodec", "Binder", "Finalizer", "Reference",
        "AsyncTask", "Handler", "JVM", "JDWP", "Profile", "Signal",
        "main", "GLThread", "Render", "magpie", "Unity", "il2cpp",
        "Audio", "wifi", "Connectivity", "Process", "pool", "Worker",
        "hwui", "ventr", "BgHandler", "GC", "Daemon",
        "Surface", "Input", "Choreo", " EGL", "Trivial",
        "NioEvent", "OkHttp", "RxCached", "RxCompu",
        "FpsRegu", "Andro", "LeakCa", "Timer",
        NULL
    };
    for (int i = 0; safe_patterns[i]; i++) {
        if (strstr(comm, safe_patterns[i]) != NULL) return 1;
    }
    return 0;
}

int word_match(const char *comm, const char *pat) {
    int plen = strlen(pat);
    int clen = strlen(comm);
    const char *pos = comm;
    while ((pos = strstr(pos, pat)) != NULL) {
        int prev_ok = (pos == comm) || !isalnum((unsigned char)pos[-1]);
        int next_ok = (pos + plen >= comm + clen) || !isalnum((unsigned char)pos[plen]);
        if (prev_ok && next_ok) return 1;
        pos++;
    }
    return 0;
}

int is_suspicious_thread_name(const char *comm) {
    if (is_safe_thread_name(comm)) return 0;
    static const char *patterns[] = {
        "tp2", "TP2", "Tp2", "tersafe", "TERSAFE", "Tersafe",
        "tss_", "TSS_", "tp2_", "TP2_", "ace_", "ACE_",
        "anchor", "ANCHOR", "risk", "RISK",
        "watchdog", "Watchdog",  /* 注意: CCodec Watchdog等被安全名单覆盖 */
        NULL
    };
    for (int i = 0; patterns[i]; i++) {
        if (word_match(comm, patterns[i])) return 1;
    }
    return 0;
}

int get_thread_list(int *tids, int max_tids) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/task", pid);
    DIR *d = opendir(path);
    if (!d) return 0;
    int count = 0;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL && count < max_tids) {
        if (ent->d_name[0] == '.') continue;
        tids[count++] = atoi(ent->d_name);
    }
    closedir(d);
    return count;
}

#define STACK_SEARCH_SIZE 65536

int thread_has_so_in_stack(int tid) {
    if (ptrace(PTRACE_ATTACH, tid, NULL, NULL) < 0) return -1;
    int status;
    waitpid(tid, &status, 0);

    struct {
        unsigned long long regs[31];
        unsigned long long sp;
        unsigned long long pc;
        unsigned long long pstate;
    } regset;
    struct iovec iov = { &regset, sizeof(regset) };
    if (ptrace(PTRACE_GETREGSET, tid, (void*)NT_PRSTATUS, &iov) < 0) {
        ptrace(PTRACE_DETACH, tid, NULL, NULL);
        return -1;
    }

    unsigned long long pc = regset.pc;
    unsigned long long lr = regset.regs[30];
    unsigned long long sp = regset.sp;
    unsigned long long fp = regset.regs[29];
    int result = 0;

    /* 跳过已在safe_loop的线程 */
    if (safe_loop_addr != 0 && pc == safe_loop_addr) { result = -2; goto done; }
    if (pc >= so_start && pc < so_end) { result = 1; goto done; }
    if (lr >= so_start && lr < so_end) { result = 2; goto done; }

    /* FP链回溯 */
    {
        unsigned long long cur_fp = fp;
        for (int depth = 0; depth < 64 && cur_fp != 0 && cur_fp > sp; depth++) {
            unsigned long long saved_fp = 0, saved_lr = 0;
            if (read_mem(cur_fp, &saved_fp, 8) < 0) break;
            if (read_mem(cur_fp + 8, &saved_lr, 8) < 0) break;
            if (saved_lr >= so_start && saved_lr < so_end) { result = 3; goto done; }
            if (saved_fp <= cur_fp) break;
            cur_fp = saved_fp;
        }
    }

    /* 栈搜索 */
    {
        size_t ssize = STACK_SEARCH_SIZE;
        unsigned char *stack = malloc(ssize);
        if (!stack) goto done;
        size_t actual = 0;
        for (size_t off = 0; off < ssize; off += 4096) {
            size_t to_read = (off + 4096 <= ssize) ? 4096 : (ssize - off);
            if (read_mem(sp + off, stack + off, to_read) < 0) { actual = off; break; }
            actual = off + to_read;
        }
        for (size_t off = 0; off + 8 <= actual; off += 8) {
            unsigned long long val;
            memcpy(&val, stack + off, 8);
            if (val >= so_start && val < so_end) { result = 4; free(stack); goto done; }
        }
        free(stack);
    }

done:
    ptrace(PTRACE_DETACH, tid, NULL, NULL);
    return result;
}

/* ====== 冻结反作弊线程 ====== */
int freeze_anticheat_threads(int round) {
    int tids[512];
    int nthreads = get_thread_list(tids, 512);
    int frozen = 0, already_frozen = 0, skipped = 0, failed = 0;

    printf("\n--- 冻结反作弊线程 (第%d轮, PC→safe_loop) ---\n", round);
    printf("%s范围: 0x%llx - 0x%llx\n", so_name, so_start, so_end);

    for (int i = 0; i < nthreads; i++) {
        int tid = tids[i];
        char comm[256] = {0};
        get_thread_comm(tid, comm, sizeof(comm));

        if (is_safe_thread_name(comm)) { skipped++; continue; }

        int name_suspicious = is_suspicious_thread_name(comm);
        int reason = thread_has_so_in_stack(tid);

        if (reason == -2) { already_frozen++; continue; }
        if (reason <= 0 && !name_suspicious) {
            if (reason < 0) failed++;
            else skipped++;
            continue;
        }

        /* 跳过主线程 */
        if (tid == pid) {
            printf("  [SKIP] TID %d [%s]: 主线程\n", tid, comm[0]?comm:"?");
            skipped++; continue;
        }

        const char *reason_str = "";
        if (reason > 0) {
            const char *rs[] = {"", "PC在SO", "LR在SO", "FP链", "栈搜索"};
            reason_str = rs[reason];
        } else if (name_suspicious) {
            reason_str = "线程名";
        }

        if (ptrace(PTRACE_ATTACH, tid, NULL, NULL) < 0) {
            printf("  " C_RED "[F]" C_RESET " TID %d [%s]: attach失败\n", tid, comm[0]?comm:"?");
            failed++; continue;
        }
        int status;
        waitpid(tid, &status, 0);

        struct {
            unsigned long long regs[31];
            unsigned long long sp;
            unsigned long long pc;
            unsigned long long pstate;
        } regset;
        struct iovec iov = { &regset, sizeof(regset) };

        if (ptrace(PTRACE_GETREGSET, tid, (void*)NT_PRSTATUS, &iov) < 0) {
            ptrace(PTRACE_DETACH, tid, NULL, NULL);
            failed++; continue;
        }

        unsigned long long old_pc = regset.pc;

        regset.pc = safe_loop_addr;
        iov.iov_base = &regset;
        iov.iov_len = sizeof(regset);

        if (ptrace(PTRACE_SETREGSET, tid, (void*)NT_PRSTATUS, &iov) < 0) {
            ptrace(PTRACE_DETACH, tid, NULL, NULL);
            failed++; continue;
        }

        ptrace(PTRACE_DETACH, tid, NULL, NULL);

        printf("  " C_CYAN "[FREEZE]" C_RESET " TID %d [%s]: %s (PC:0x%llx→safe_loop)\n",
               tid, comm[0]?comm:"?", reason_str, old_pc);
        frozen++;
    }

    printf("冻结: %d, 已冻结: %d, 失败: %d, 跳过: %d\n",
           frozen, already_frozen, failed, skipped);
    return frozen;
}

/* ====== SVC扫描 ====== */
#define __NR_exit        93
#define __NR_exit_group   94
#define __NR_kill        129
#define __NR_tkill       130
#define __NR_tgkill      131

#define MOV_X8(n) ((unsigned int)(0xD2800000 | ((n) << 5)))
#define MOV_W8(n) ((unsigned int)(0x52800000 | ((n) << 5)))
#define SVC_0     ((unsigned int)0xD4000001)

int scan_so_syscalls() {
    printf("\n--- 扫描%s内svc ---\n", so_name);
    if (so_rx_start == 0 || so_rx_end == 0) return 0;
    size_t size = so_rx_end - so_rx_start;
    unsigned char *buf = malloc(size);
    if (!buf) return 0;
    if (read_mem(so_rx_start, buf, size) < 0) { free(buf); return 0; }

    struct { unsigned int nr; const char *name; } syscalls[] = {
        { __NR_exit_group, "exit_group" },
        { __NR_kill,       "kill" },
        { __NR_tkill,      "tkill" },
        { __NR_tgkill,     "tgkill" },
    };
    int count = 0;
    for (size_t i = 0; i + 20 <= size && count < 64; i += 4) {
        unsigned int insn;
        memcpy(&insn, buf + i, 4);
        for (int s = 0; s < 4; s++) {
            if (insn != MOV_X8(syscalls[s].nr) && insn != MOV_W8(syscalls[s].nr)) continue;
            for (int j = 1; j <= 5 && count < 64; j++) {
                if (i + (j + 1) * 4 > size) break;
                unsigned int next;
                memcpy(&next, buf + i + j * 4, 4);
                if (next != SVC_0) continue;
                unsigned long long addr = so_rx_start + i;
                unsigned int new_insn = MOV_X8(__NR_exit);
                if (write_mem(addr, &new_insn, 4) < 0)
                    printf("  " C_RED "[F]" C_RESET " 0x%llx: 写入失败\n", addr);
                else {
                    printf("  " C_GREEN "[OK]" C_RESET " 0x%llx: %s -> exit\n", addr, syscalls[s].name);
                    count++;
                }
                break;
            }
            break;
        }
    }
    free(buf);
    if (count == 0) printf("  发现0处危险svc\n");
    return count;
}

int scan_all_exec_syscalls() {
    printf("\n--- 扫描全进程可执行段svc ---\n");
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/maps", pid);
    FILE *f = fopen(path, "r");
    if (!f) return 0;

    typedef struct { unsigned long long start; unsigned long long end; } ExecRegion;
    ExecRegion regions[128];
    int nregions = 0;
    char line[512];
    while (fgets(line, sizeof(line), f) && nregions < 128) {
        unsigned long long start, end;
        char perms[8];
        if (sscanf(line, "%llx-%llx %4s", &start, &end, perms) == 3) {
            if (perms[2] == 'x') {
                regions[nregions].start = start;
                regions[nregions].end = end;
                nregions++;
            }
        }
    }
    fclose(f);
    printf("找到%d个可执行段\n", nregions);

    struct { unsigned int nr; const char *name; } dangerous_nrs[] = {
        { __NR_exit_group, "exit_group" },
        { __NR_kill,       "kill" },
        { __NR_tgkill,     "tgkill" },
        { __NR_tkill,      "tkill" },
    };

    int total = 0;
    for (int r = 0; r < nregions; r++) {
        unsigned long long start = regions[r].start;
        size_t size = regions[r].end - start;
        if (size > 50 * 1024 * 1024 || start < 0xffffffff) continue;
        unsigned char *buf = malloc(size);
        if (!buf) continue;
        if (read_mem(start, buf, size) < 0) { free(buf); continue; }
        /* 简单代码检测 */
        int code_like = 0;
        for (size_t t = 0; t < size && t < 256; t += 4) {
            unsigned int insn; memcpy(&insn, buf + t, 4);
            if ((insn & 0xFF000000) == 0xD4000000 || (insn & 0xFF000000) == 0xD2800000 ||
                (insn & 0xFF000000) == 0x91000000 || (insn & 0xFF000000) == 0xA9000000 ||
                (insn & 0xFF000000) == 0xD1000000 || (insn & 0xFF000000) == 0x52800000 ||
                (insn & 0xFF000000) == 0x14000000 || (insn & 0xFF000000) == 0x94000000)
                code_like++;
        }
        if (code_like < 4) { free(buf); continue; }

        for (size_t i = 0; i + 20 <= size; i += 4) {
            unsigned int insn; memcpy(&insn, buf + i, 4);
            for (int s = 0; s < 4; s++) {
                if (insn != MOV_X8(dangerous_nrs[s].nr) && insn != MOV_W8(dangerous_nrs[s].nr)) continue;
                for (int j = 1; j <= 5; j++) {
                    if (i + (j + 1) * 4 > size) break;
                    unsigned int next; memcpy(&next, buf + i + j * 4, 4);
                    if (next != SVC_0) continue;
                    unsigned long long addr = start + i;
                    unsigned int new_insn = MOV_X8(__NR_exit);
                    if (write_mem(addr, &new_insn, 4) >= 0) {
                        printf("  " C_GREEN "[OK]" C_RESET " 0x%llx: %s -> exit\n",
                               addr, dangerous_nrs[s].name);
                        total++;
                    }
                    break;
                }
                break;
            }
        }
        free(buf);
    }
    return total;
}

/* ====== PLT Patch ====== */
int patch_all_plt() {
    printf("\n--- Patch PLT Stub ---\n");
    int ok = 0, fail = 0, safe_loop_count = 0;
    total_bl_covered = 0;

    for (int i = 0; i < n_discovered; i++) {
        DiscoveredPlt *e = &discovered_plts[i];
        unsigned long long addr = e->plt_addr;

        /* 统计BL调用数: 扫描r-xp段中跳转到此PLT的BL指令 */
        int bl_count = 0;
        {
            size_t code_size = so_rx_end - so_rx_start;
            unsigned int *code = malloc(code_size);
            if (code) {
                if (read_mem(so_rx_start, code, code_size) == 0) {
                    size_t n_insns = code_size / 4;
                    for (size_t j = 0; j < n_insns; j++) {
                        unsigned int insn = code[j];
                        if ((insn & 0xFC000000) == 0x94000000) { /* BL */
                            int imm26 = insn & 0x3FFFFFF;
                            if (imm26 & 0x2000000) imm26 -= 0x4000000;
                            unsigned long long target = so_rx_start + j * 4 + (long long)imm26 * 4;
                            if (target == addr) bl_count++;
                        }
                    }
                }
                free(code);
            }
        }

        if (flag_list_only) {
            printf("  [LIST] %s @ 0x%llx → %s (%d BL)\n",
                   e->name, addr,
                   e->strategy == 0 ? "ret-1" : e->strategy == 1 ? "ret0" :
                   e->strategy == 2 ? "safe_loop" : "syscall_filter",
                   bl_count);
            ok++;
            continue;
        }

        int result = -1;
        const char *mode_str = "";

        switch (e->strategy) {
        case 0:  /* ret-1 */
            {
                unsigned char orig[16];
                if (read_mem(addr, orig, 16) < 0) { fail++; continue; }
                if (memcmp(orig, stub_retm1, 16) == 0) { ok++; total_bl_covered += bl_count; continue; }
                if (write_mem(addr, stub_retm1, 16) < 0) { fail++; continue; }
                unsigned char check[16];
                if (read_mem(addr, check, 16) < 0 || memcmp(check, stub_retm1, 16) != 0) { fail++; continue; }
                result = 0; mode_str = "ret-1";
            }
            break;

        case 1:  /* ret0 */
            {
                unsigned char orig[16];
                if (read_mem(addr, orig, 16) < 0) { fail++; continue; }
                if (memcmp(orig, stub_ret0, 16) == 0) { ok++; total_bl_covered += bl_count; continue; }
                if (write_mem(addr, stub_ret0, 16) < 0) { fail++; continue; }
                unsigned char check[16];
                if (read_mem(addr, check, 16) < 0 || memcmp(check, stub_ret0, 16) != 0) { fail++; continue; }
                result = 0; mode_str = "ret0";
            }
            break;

        case 2:  /* safe_loop */
            {
                unsigned int b_insn = make_branch(addr, safe_loop_addr);
                unsigned int cur_insn;
                if (read_mem(addr, &cur_insn, 4) < 0) { fail++; continue; }
                if (cur_insn == b_insn) { ok++; total_bl_covered += bl_count; continue; }
                if (write_mem(addr, &b_insn, 4) < 0) { fail++; continue; }
                unsigned int check_insn;
                if (read_mem(addr, &check_insn, 4) < 0 || check_insn != b_insn) { fail++; continue; }
                result = 0; mode_str = "safe_loop"; safe_loop_count++;
            }
            break;

        case 3:  /* syscall filter */
            {
                unsigned int b_insn = make_branch(addr, syscall_filter_addr);
                unsigned int cur_insn;
                if (read_mem(addr, &cur_insn, 4) < 0) { fail++; continue; }
                if (cur_insn == b_insn) { ok++; total_bl_covered += bl_count; continue; }
                if (write_mem(addr, &b_insn, 4) < 0) {
                    /* 降级为ret-1 */
                    if (write_mem(addr, stub_retm1, 16) < 0) { fail++; continue; }
                    unsigned char check[16];
                    if (read_mem(addr, check, 16) < 0 || memcmp(check, stub_retm1, 16) != 0) { fail++; continue; }
                    result = 0; mode_str = "ret-1(降级)";
                    break;
                }
                unsigned int check_insn;
                if (read_mem(addr, &check_insn, 4) < 0 || check_insn != b_insn) { fail++; continue; }
                result = 0; mode_str = "syscall_filter";
            }
            break;
        }

        if (result == 0) {
            printf("  " C_GREEN "[OK]" C_RESET " %s -> %s (%d BL)\n", e->name, mode_str, bl_count);
            ok++; total_bl_covered += bl_count;
        } else {
            printf("  " C_RED "[F]" C_RESET " %s\n", e->name);
        }
    }

    printf("PLT结果: %d成功 %d失败\n", ok, fail);
    printf("safe_loop: %d个PLT跳转\n", safe_loop_count);
    return fail;
}

/* ====== 验证 ====== */
int verify_patches() {
    printf("\n--- 验证patch完整性 ---\n");
    int ok = 0, fail = 0;

    for (int i = 0; i < n_discovered; i++) {
        DiscoveredPlt *e = &discovered_plts[i];
        unsigned long long addr = e->plt_addr;

        switch (e->strategy) {
        case 0:  /* ret-1 */
            {
                unsigned char check[16];
                if (read_mem(addr, check, 16) < 0 || memcmp(check, stub_retm1, 16) != 0) {
                    printf("  " C_RED "[FAIL]" C_RESET " %s patch已恢复!\n", e->name); fail++;
                } else ok++;
            }
            break;
        case 1:  /* ret0 */
            {
                unsigned char check[16];
                if (read_mem(addr, check, 16) < 0 || memcmp(check, stub_ret0, 16) != 0) {
                    printf("  " C_RED "[FAIL]" C_RESET " %s patch已恢复!\n", e->name); fail++;
                } else ok++;
            }
            break;
        case 2:  /* safe_loop */
            {
                unsigned int insn;
                if (read_mem(addr, &insn, 4) < 0) { fail++; break; }
                unsigned int expected = make_branch(addr, safe_loop_addr);
                if (insn != expected) {
                    printf("  " C_RED "[FAIL]" C_RESET " %s safe_loop跳转不匹配\n", e->name); fail++;
                } else ok++;
            }
            break;
        case 3:  /* syscall filter */
            {
                unsigned int insn;
                if (read_mem(addr, &insn, 4) < 0) { fail++; break; }
                unsigned int expected = make_branch(addr, syscall_filter_addr);
                if (insn == expected) { ok++; break; }
                /* 可能降级为ret-1 */
                unsigned char check[16];
                if (read_mem(addr, check, 16) < 0 || memcmp(check, stub_retm1, 16) != 0) {
                    printf("  " C_RED "[FAIL]" C_RESET " %s\n", e->name); fail++;
                } else ok++;
            }
            break;
        }
    }

    /* 验证code cave */
    if (safe_loop_addr != 0) {
        unsigned int sl[2];
        if (read_mem(safe_loop_addr, sl, sizeof(safe_loop_code)) < 0 ||
            sl[0] != safe_loop_code[0] || sl[1] != safe_loop_code[1]) {
            printf("  " C_RED "[FAIL]" C_RESET " safe_loop已覆盖!\n"); fail++;
        } else ok++;
    }
    if (syscall_filter_addr != 0) {
        unsigned int fc[2];
        if (read_mem(syscall_filter_addr, fc, sizeof(syscall_filter_code)) < 0 ||
            memcmp(fc, syscall_filter_code, sizeof(syscall_filter_code)) != 0) {
            printf("  " C_RED "[FAIL]" C_RESET " syscall filter已覆盖!\n"); fail++;
        } else ok++;
    }

    printf("验证: %d OK, %d FAIL\n", ok, fail);
    return fail;
}

/* ====== 杀子进程 ====== */
int kill_child_processes() {
    printf("\n--- 清理子进程(watchdog) ---\n");
    int killed = 0;
    DIR *d = opendir("/proc");
    if (!d) return 0;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        int cpid = atoi(ent->d_name);
        if (cpid <= 0) continue;
        char stat_path[64];
        snprintf(stat_path, sizeof(stat_path), "/proc/%d/stat", cpid);
        FILE *f = fopen(stat_path, "r");
        if (!f) continue;
        int ppid = 0; char comm[256];
        if (fscanf(f, "%*d (%255[^)]) %*c %d", comm, &ppid) == 2) {
            if (ppid == pid) {
                printf("  [KILL] 子进程 PID %d (%s)\n", cpid, comm);
                kill(cpid, SIGKILL); killed++;
            }
        }
        fclose(f);
    }
    closedir(d);
    if (killed == 0) printf("  没有发现子进程\n");
    return killed;
}

/* ====== 主函数 ====== */

/* ====== 卡密验证前向声明 ====== */
static int cmd_device_code(void);
static int cmd_verify_key(const char *key);
static int cmd_check_sig(const char *apk_path);

int main(int argc, char *argv[]) {
    /* 内部命令: 卡密验证 (不显示在帮助中) */
    if (argc >= 2 && strcmp(argv[1], "--device-code") == 0)
        return cmd_device_code();
    if (argc >= 3 && strcmp(argv[1], "--verify-key") == 0)
        return cmd_verify_key(argv[2]);
    if (argc >= 3 && strcmp(argv[1], "--check-sig") == 0)
        return cmd_check_sig(argv[2]);

    if (argc < 2) {
        printf(C_BOLD "acbypass v1.1 - Universal Anti-Cheat Bypass\n" C_RESET);
        printf("\n用法: acbypass <包名> [选项]\n\n");
        printf("选项:\n");
        printf("  -s <so名>   指定反作弊SO名 (默认自动检测)\n");
        printf("  -n          不冻结线程 (仅PLT patch)\n");
        printf("  -l          仅扫描不patch\n");
        printf("\n示例:\n");
        printf("  acbypass com.wyhd.shipx.gw\n");
        printf("  acbypass com.game.xxx -s libace.so\n");
        printf("\n编译: aarch64-linux-gnu-gcc -O2 -static -o acbypass acbypass_v1.c\n");
        return 1;
    }

    /* 解析参数 */
    strncpy(pkg_name, argv[1], sizeof(pkg_name) - 1);
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "-s") == 0 && i + 1 < argc) {
            strncpy(so_name, argv[i + 1], sizeof(so_name) - 1);
            i++;
        } else if (strcmp(argv[i], "-n") == 0) {
            flag_no_freeze = 1;
        } else if (strcmp(argv[i], "-l") == 0) {
            flag_list_only = 1;
        }
    }

    signal(SIGINT, cleanup_handler);
    signal(SIGTERM, cleanup_handler);

    printf(C_BOLD "=== acbypass v1.1 - Universal Anti-Cheat Bypass ===\n\n" C_RESET);

    /* 1. 找进程 */
    printf(C_CYAN "[1/8]" C_RESET " 查找进程 %s...\n", pkg_name);
    pid = find_pid_by_pkg(pkg_name);
    if (pid <= 0) { printf(C_RED "[E] 进程未运行!\n" C_RESET); return 1; }
    printf("  PID: %d\n", pid);

    /* 2. 检测反作弊SO */
    printf(C_CYAN "[2/8]" C_RESET " 检测反作弊SO...\n");
    if (so_name[0] == 0) {
        if (detect_anticheat_so() < 0) {
            printf(C_RED "[E] 未检测到已知反作弊SO! 使用 -s <so名> 手动指定\n" C_RESET);
            return 1;
        }
        printf("  自动检测: " C_GREEN "%s" C_RESET "\n", so_name);
    } else {
        printf("  手动指定: %s\n", so_name);
    }

    /* 3. 打开mem + 找基址和段 */
    printf(C_CYAN "[3/8]" C_RESET " 定位SO内存区域...\n");
    char mem_path[64];
    snprintf(mem_path, sizeof(mem_path), "/proc/%d/mem", pid);
    mem_fd = open(mem_path, O_RDWR);
    if (mem_fd < 0) { printf(C_RED "[E] 打开mem失败: %s\n" C_RESET, strerror(errno)); return 1; }

    base = find_so_base();
    if (base == 0) { printf(C_RED "[E] 找不到 %s\n" C_RESET, so_name); close(mem_fd); return 1; }
    printf("  基址: 0x%llx\n", base);

    if (find_so_regions() < 0) { printf(C_RED "[E] 解析段信息失败\n" C_RESET); close(mem_fd); return 1; }
    printf("  r-xp段: 0x%llx - 0x%llx\n", so_rx_start, so_rx_end);

    /* 验证ELF */
    unsigned int magic;
    if (read_mem(base, &magic, 4) < 0 || magic != 0x464c457f) {
        printf(C_RED "[E] ELF头不匹配!\n" C_RESET); close(mem_fd); return 1;
    }
    printf("  ELF头: OK\n");

    /* 4. 发现PLT */
    printf(C_CYAN "[4/8]" C_RESET " 解析ELF动态段, 发现危险PLT...\n");
    n_discovered = discover_all_plt();
    if (n_discovered <= 0) {
        printf(C_RED "[E] 未发现任何危险PLT条目!\n" C_RESET); close(mem_fd); return 1;
    }
    printf("  发现 %d 个危险PLT条目\n", n_discovered);

    if (flag_list_only) {
        patch_all_plt();  /* 仅打印列表 */
        close(mem_fd);
        return 0;
    }

    /* 5. 设置代码洞 */
    printf(C_CYAN "[5/8]" C_RESET " 设置代码洞...\n");
    if (setup_code_cave() < 0) {
        close(mem_fd); return 1;
    }

    /* === 暂停进程 === */
    printf("\n" C_YELLOW "暂停进程...\n" C_RESET);
    kill(pid, SIGSTOP);
    stopped = 1;
    usleep(200000);

    /* Phase 1: 冻结反作弊线程(patch前冻结, 消除检测窗口) */
    int frozen1 = 0;
    if (!flag_no_freeze) {
        printf(C_CYAN "[6/8]" C_RESET " 冻结反作弊线程...\n");
        frozen1 = freeze_anticheat_threads(1);
    }

    /* Phase 2: SVC扫描 */
    printf(C_CYAN "[7/8]" C_RESET " Patch...\n");
    int svc_so = scan_so_syscalls();
    int svc_global = scan_all_exec_syscalls();

    /* Phase 3: PLT patch */
    int plt_fail = patch_all_plt();

    /* Phase 4: 第二轮冻结 */
    int frozen2 = 0;
    if (!flag_no_freeze) {
        frozen2 = freeze_anticheat_threads(2);
    }

    /* Phase 5: 子进程 */
    int children = kill_child_processes();

    /* Phase 6: 验证 */
    printf(C_CYAN "[8/8]" C_RESET " 验证...\n");
    int verify_fail = verify_patches();

    /* === 汇总 === */
    printf("\n" C_BOLD "===== 汇总 =====\n" C_RESET);
    printf("目标: %s (PID %d)\n", pkg_name, pid);
    printf("反作弊: %s @ 0x%llx\n", so_name, base);
    printf("svc patch: %d(SO内) + %d(全进程)\n", svc_so, svc_global);
    printf("PLT patch: %d成功, %d失败\n", n_discovered - plt_fail, plt_fail);
    printf("BL覆盖: %d\n", total_bl_covered);
    printf("冻结线程: %d + %d = %d\n", frozen1, frozen2, frozen1 + frozen2);
    printf("子进程清理: %d\n", children);
    printf("验证: %s\n", verify_fail == 0 ? C_GREEN "全部通过" C_RESET : C_RED "有失败!" C_RESET);

    /* 恢复进程 */
    if (plt_fail == 0) {
        printf("\n恢复进程...\n");
        kill(pid, SIGCONT);
        stopped = 0;

        printf("健康检查: 等待10秒...\n");
        int alive = 1;
        for (int i = 0; i < 10; i++) {
            sleep(1);
            char check_path[64];
            snprintf(check_path, sizeof(check_path), "/proc/%d/stat", pid);
            FILE *f = fopen(check_path, "r");
            if (!f) {
                printf("  " C_RED "[%d秒] 进程已死! (闪退)\n" C_RESET, i + 1);
                alive = 0; break;
            }
            char state = 0;
            if (fscanf(f, "%*d %*s %c", &state) == 1)
                printf("  [%d秒] 存活 (状态=%c)\n", i + 1, state);
            fclose(f);
        }
        if (alive)
            printf("\n" C_GREEN C_BOLD "✓ 进程存活! 可以使用修改器了!\n" C_RESET);
        else
            printf("\n" C_RED "✗ 闪退! 可能还有未覆盖的退出路径\n" C_RESET);
    } else {
        printf("\n有失败，保持STOP\n恢复: kill -CONT %d\n", pid);
    }

    if (discovered_plts) free(discovered_plts);
    close(mem_fd);
    return (plt_fail > 0 || verify_fail > 0) ? 1 : 0;
}
/* ====== 卡密验证系统 (native层 - 反编译保护) ====== */

/* XOR编码的密钥 — 运行时解码, 不在二进制中明文出现 */
/* "xy435116694754" XOR 0x5A */
static const unsigned char enc_master[] = {
    0x22,0x23,0x6E,0x69,0x6F,0x6B,0x6B,0x6C,0x6C,0x63,0x6E,0x6D,0x6F,0x6E
};
#define ENC_MASTER_LEN 14

/* "ACBypass2026XY" XOR 0x5A */
static const unsigned char enc_secret[] = {
    0x1B,0x19,0x18,0x23,0x2A,0x3B,0x29,0x29,0x68,0x6A,0x68,0x6C,0x02,0x03
};
#define ENC_SECRET_LEN 14

/* APK签名文件SHA-256前16字节 XOR 0xAB (5fb4c0decff669ae30722172f39f145d...) */
static const unsigned char enc_sig_first[] = {
    0x4B,0xF0,0xC1,0xCC,0xF0,0x71,0xD1,0x2A,0x58,0x71,0xEA,0xCF,0x32,0x28,0x0B,0x2B
};
#define ENC_SIG_LEN 16

static char dec_master[16];
static char dec_secret[16];
static int decoded = 0;

static void decode_strings(void) {
    if (decoded) return;
    int i;
    for (i = 0; i < ENC_MASTER_LEN; i++) dec_master[i] = enc_master[i] ^ 0x5A;
    dec_master[i] = 0;
    for (i = 0; i < ENC_SECRET_LEN; i++) dec_secret[i] = enc_secret[i] ^ 0x5A;
    dec_secret[i] = 0;
    decoded = 1;
}

/* FNV-1a 32-bit */
static unsigned int nv1a(const char *s, unsigned int seed) {
    unsigned int h = seed;
    while (*s) { h ^= (unsigned char)*s++; h *= 0x01000193; }
    return h;
}

/* XOR bytes */
static void xorb(unsigned char *d, int len, const char *k, int kl) {
    for (int i = 0; i < len; i++) d[i] ^= (unsigned char)k[i % kl];
}

/* Base32 encode */
static int b32enc(const unsigned char *data, int dlen, char *out, int olen) {
    static const char *A = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    int bits = 0, pos = 0; unsigned int val = 0;
    for (int i = 0; i < dlen && pos < olen-1; i++) {
        val = (val << 8) | data[i]; bits += 8;
        while (bits >= 5 && pos < olen-1) {
            bits -= 5; out[pos++] = A[(val >> bits) & 0x1F];
            val &= (1U << bits) - 1;
        }
    }
    if (bits > 0 && pos < olen-1) out[pos++] = A[(val & ((1U<<bits)-1)) << (5-bits)];
    out[pos] = 0; return pos;
}

/* Base32 decode */
static int b32dec(const char *s, unsigned char *out, int olen) {
    static const char *A = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    int bits = 0, pos = 0; unsigned int val = 0;
    for (int i = 0; s[i] && pos < olen; i++) {
        const char *p = strchr(A, toupper(s[i]));
        if (!p) continue;
        val = (val << 5) | (p - A); bits += 5;
        while (bits >= 8 && pos < olen) {
            bits -= 8; out[pos++] = (val >> bits) & 0xFF;
            val &= (1U << bits) - 1;
        }
    }
    return pos;
}

/* 读取设备指纹 */
static int read_fp(char *buf, int blen) {
    FILE *f; char line[512];
    f = fopen("/sys/devices/soc0/serial_number","r");
    if (f) { if (fgets(buf,blen,f)) { fclose(f); int l=strlen(buf); while(l>0&&(buf[l-1]=='\n'||buf[l-1]=='\r'||buf[l-1]==' ')) buf[--l]=0; if(l>0) return 1; } fclose(f); }
    f = fopen("/proc/cmdline","r");
    if (f) { if (fgets(line,sizeof(line),f)) { char *p=strstr(line,"androidboot.serialno="); if(p){p+=21;int i=0;while(*p&&*p!=' '&&*p!='\n'&&i<blen-1)buf[i++]=*p++;buf[i]=0;fclose(f);if(i>0)return 1;}} fclose(f); }
    f = fopen("/proc/cpuinfo","r");
    if (f) { while(fgets(line,sizeof(line),f)){if(strncasecmp(line,"hardware",8)==0){char*c=strchr(line,':');if(c){c++;while(*c==' ')c++;int i=0;while(*c&&*c!='\n'&&i<blen-1)buf[i++]=*c++;buf[i]=0;fclose(f);if(i>0)return 1;}}} fclose(f); }
    f = fopen("/proc/cpuinfo","r");
    if (f) { while(fgets(line,sizeof(line),f)){if(strncasecmp(line,"serial",6)==0){char*c=strchr(line,':');if(c){c++;while(*c==' ')c++;int i=0;while(*c&&*c!='\n'&&i<blen-1)buf[i++]=*c++;buf[i]=0;fclose(f);if(i>0)return 1;}}} fclose(f); }
    snprintf(buf,blen,"fallback_acbypass"); return 0;
}

/* 生成设备码 */
static int gen_device_code(char *out, int olen) {
    decode_strings();
    char fp[256]={0}; read_fp(fp,sizeof(fp));
    unsigned int h1=nv1a(fp,0x811c9dc5), h2=nv1a(fp,0x1234abcd);
    unsigned char fh[5]; fh[0]=h1&0xFF;fh[1]=(h1>>8)&0xFF;fh[2]=(h1>>16)&0xFF;fh[3]=(h1>>24)&0xFF;fh[4]=h2&0xFF;
    unsigned char enc[5]; memcpy(enc,fh,5); xorb(enc,5,dec_master,5);
    char raw[16]; b32enc(enc,5,raw,sizeof(raw));
    if(strlen(raw)>=8){ snprintf(out,olen,"%.4s-%.4s",raw,raw+4); return 1; }
    return 0;
}

/* 验证激活码 */
static int verify_key(const char *code) {
    decode_strings();
    char fp[256]={0}; read_fp(fp,sizeof(fp));
    unsigned int h1=nv1a(fp,0x811c9dc5), h2=nv1a(fp,0x1234abcd);
    unsigned char fh[5]; fh[0]=h1&0xFF;fh[1]=(h1>>8)&0xFF;fh[2]=(h1>>16)&0xFF;fh[3]=(h1>>24)&0xFF;fh[4]=h2&0xFF;
    char fph[11]; snprintf(fph,sizeof(fph),"%02x%02x%02x%02x%02x",fh[0],fh[1],fh[2],fh[3],fh[4]);

    char ai[128]; snprintf(ai,sizeof(ai),"%s%s",fph,dec_secret);
    unsigned int a1=nv1a(ai,0x5678ef01),a2=nv1a(ai,0x9abcdef0),a3=nv1a(ai,0x13579bdf);
    unsigned char exp[10];
    exp[0]=a1&0xFF;exp[1]=(a1>>8)&0xFF;exp[2]=(a1>>16)&0xFF;exp[3]=(a1>>24)&0xFF;
    exp[4]=a2&0xFF;exp[5]=(a2>>8)&0xFF;exp[6]=(a2>>16)&0xFF;exp[7]=(a2>>24)&0xFF;
    exp[8]=a3&0xFF;exp[9]=(a3>>8)&0xFF;

    char clean[20]; int j=0;
    for(int i=0;code[i]&&j<16;i++) if(code[i]!='-'&&code[i]!=' ') clean[j++]=toupper(code[i]);
    clean[j]=0; if(j!=16) return 0;

    unsigned char dec[20]; int dl=b32dec(clean,dec,sizeof(dec));
    if(dl<10) return 0;
    xorb(dec,10,dec_master,10);
    for(int i=0;i<10;i++) if(dec[i]!=exp[i]) return 0;
    return 1;
}

/* 验证APK签名SHA-256前16字节 */
static int verify_sig(const char *apk_path) {
    if (!apk_path || !apk_path[0]) return 0;
    decode_strings();

    /* 动态查找META-INF下的.RSA文件（避免硬编码别名导致文件名不匹配） */
    char cmd[768];
    snprintf(cmd,sizeof(cmd),
        "RSAF=$(unzip -l '%s' 2>/dev/null | grep -m1 'META-INF/.*\\.RSA' | awk '{print $NF}') && "
        "unzip -p '%s' \"$RSAF\" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1",
        apk_path, apk_path);
    FILE *p=popen(cmd,"r"); if(!p) return 0;
    char hash[65]={0}; fgets(hash,65,p); pclose(p);
    int l=strlen(hash); while(l>0&&hash[l-1]=='\n') hash[--l]=0;
    if(l<32) return 0;

    /* 解码期望签名 */
    unsigned char esig[17]; memcpy(esig,enc_sig_first,16);
    for(int i=0;i<16;i++) esig[i]^=0xAB;
    char exp[33];
    for(int i=0;i<16;i++) snprintf(exp+i*2,3,"%02x",esig[i]);

    return strncmp(hash,exp,32)==0;
}

/* 命令: 输出设备码 */
static int cmd_device_code(void) {
    char code[20];
    if(gen_device_code(code,sizeof(code))){printf("%s",code);return 0;}
    return 1;
}

/* 命令: 验证激活码 */
static int cmd_verify_key(const char *key) {
    return verify_key(key)?0:1;
}

/* 命令: 验证签名 */
static int cmd_check_sig(const char *apk_path) {
    return verify_sig(apk_path)?0:1;
}
