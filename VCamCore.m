//
//  VCamCore.m
//  VCamPlus
//
//  对标 vcameracrack.dylib 的 VCamCore 实现
//  核心职责：
//    1. 从 LocalVideoPlayer 获取当前帧
//    2. 用 GPUImageProcessor 处理（旋转/镜像/格式转换）
//    3. 写入目标 pixelBuffer（hook 函数传入的相机帧）
//    4. 缓存最后渲染的帧（双格式：BGRA + YUV）
//    5. 状态控制（loadState 转换）
//    6. plist 轮询（mediaserverd 安全通道）
//

#import "VCamCore.h"
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <mach/mach.h>
#include <libproc.h>
#include <dlfcn.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <mach-o/loader.h>
#include <mach-o/dyld.h>
#include <objc/runtime.h>
#import "VCamTextSig.h"

// 日志令牌桶(定义见下方 vcam_log_budget_take, 全进程共享磁盘写入预算)
BOOL vcam_log_budget_take(void);

// 车道记忆全量重置(定义在 GPUImageProcessor.m, 1.3.48 视频切换时调用:
// 新视频不继承旧视频的直转/stage/split/熔断失败记忆)
extern void vcamLaneResetAllMemos(void);

// ===== 资源自监控(2026-08-16 黑屏取证 v2: +CPU% +按流渲染统计) =====
// mediaserverd 周期性被杀(相机替换活跃 ~150s)但无 .ips 落盘, 系统侧无法判死因。
// v2 探针每 30s 记一行: 内存(已证平稳)/进程 CPU%(所有线程 user+system 累计差分)/
// 按流(w_h_fmt)渲染计数+像素量 —— 被杀前最后一行即可定位烧 CPU 配额的具体流
// 1.3.88 单调采样(hardTrip 振荡根修): 旧实现 task_threads 逐线程累加是瞬时
// 快照, 线程退出时其累计时间从总和凭空消失 → 总和非单调(遥测实测 cpu=-1%~
// -14% 负差分), "负差分只推进时间基线"的旧修法又让后续样本被还债式低估。
// 毛刺+低估双重噪声把 EMA 反复推过 110 线 → hardTrip 5 分钟 11 次开关
// (2026-08-30 日志实证) = 24↔20fps 周期横跳 = "打开一段时间后卡顿掉帧不稳定"
// 直接来源。改 proc_pidinfo(PROC_PIDTASKINFO) 进程级单调累计(pti_total_user
// +pti_total_system, 内核记账, 线程启停零影响), 差分即真实 CPU%。
static double vcam_process_cpu_seconds(void) {
    struct proc_taskinfo pti;
    if (proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &pti, sizeof(pti)) == (int)sizeof(pti)) {
        return (double)(pti.pti_total_user + pti.pti_total_system) / 1000000000.0;
    }
    return -1.0;  // 采样失败: 调用方按无效样本丢弃(不更新基线)
}

static void vcam_telemetry_sample(uint64_t renderedFrames, NSString *streamStats) {
    static CFAbsoluteTime lastTel = 0;
    static double lastCpu = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (lastTel > 0 && (now - lastTel) < 30.0) return;

    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t vmCount = TASK_VM_INFO_COUNT;
    uint64_t footprint = 0, resident = 0;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &vmCount) == KERN_SUCCESS) {
        footprint = vmInfo.phys_footprint;
        resident = vmInfo.resident_size;
    }

    double cpuSec = vcam_process_cpu_seconds();
    double cpuPct = (cpuSec >= 0 && lastCpu >= 0 && lastTel > 0 && now > lastTel)
                    ? ((cpuSec - lastCpu) / (now - lastTel) * 100.0) : 0;
    lastTel = now;
    if (cpuSec >= 0) lastCpu = cpuSec;

    @try {
        if (!vcam_log_budget_take()) return;  // 磁盘配额保护: 遥测也走令牌桶
        NSString *line = [NSString stringWithFormat:
            @"%.0f fp=%lluMB res=%lluMB cpu=%.0f%% renders=%llu | %@\n",
            now, footprint >> 20, resident >> 20, cpuPct, renderedFrames,
            streamStats.length ? streamStats : @"-"];
        NSString *path = @"/tmp/vcam_telemetry.txt";
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

// 日志总开关(2026-08-16, diskwrites 崩溃循环止血): mediaserverd 的 EXC_RESOURCE
// disk writes 配额极低(12.43KB/s 记账/每日 ~1GB, 每行日志按 4KB 脏页记账)。
// 默认全部静默; 诊断时 SSH 写 vc.plist "logEnabled=YES" + respring 打开
static BOOL vcam_log_enabled(void) {
    static int cached = -1;
    if (cached < 0) {
        @try {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/DCIM/vc.plist"];
            if (!d) d = [NSDictionary dictionaryWithContentsOfFile:@"/rootfs/private/var/mobile/Media/DCIM/vc.plist"];
            if (d) cached = d[@"logEnabled"] ? [d[@"logEnabled"] boolValue] : 0;
        } @catch (NSException *e) {}
    }
    return cached == 1;
}

// 日志全局限速令牌桶(2026-08-19 磁盘配额击杀循环根治): 设备实证 1.2.6 时代
// logEnabled=true 时, 每次开相机突发 40+ 行日志(emit#/write#/render#/init...)
// —— 每行按 4KB 脏页记账, 瞬时速率 >> 12.43KB/s 配额 → EXC_RESOURCE 击杀
// mediaserverd → 重启又写突发 → 再杀 = 自馈崩溃循环(runs 49→57/30s,
// launchctl "immediate reason = inefficient", 设备实证)。
// 令牌桶: 容量 24(短突发可过), 持续 3 行/s(=12KB/s, 恰在配额内)。
// 超限行直接丢弃 —— 诊断日志本就采样降频(%600), 丢行不影响取证大局。
// 全进程所有 vcam_*_log / telemetry 共用同一预算(定义于本文件, 其余编译单元 extern)。
BOOL vcam_log_budget_take(void) {
    static NSLock *lk = nil;
    static double tokens = 24.0;
    static double lastRefill = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lk = [[NSLock alloc] init];
        lastRefill = CFAbsoluteTimeGetCurrent();
    });
    [lk lock];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (lastRefill < now) {
        double refilled = tokens + (now - lastRefill) * 3.0;
        tokens = refilled > 24.0 ? 24.0 : refilled;
        lastRefill = now;
    }
    BOOL ok = NO;
    if (tokens >= 1.0) { tokens -= 1.0; ok = YES; }
    [lk unlock];
    return ok;
}

static void vcam_core_log(NSString *msg) {
    if (!vcam_log_enabled()) return;
    if (!vcam_log_budget_take()) return;
    @try {
        NSString *logPath = @"/tmp/vcam_core_log.txt";
        NSString *ts = [NSDate date].description;
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", ts, msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (!fh) {
            [entry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

// ==== 自身 IMP 范围自检(1.3.55, 防方法 swizzle) ====
// 本 dylib 的 __TEXT 段地址范围一次性算出(遍历 load commands);
// 每拍轮询校验三个关键方法的 IMP 是否落在范围内 —— 被 swizzle 到
// 别的镜像(IMP 指向第三方 dylib) → licMark 关门禁。开销: 一次 dladdr +
// 三次 method_getMethodImplementation, μs 级, 不碰渲染线程
static BOOL vcamSelfIntegrityOK(void) {
    static uintptr_t textStart = 0, textEnd = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Dl_info info;
        if (dladdr((void *)&vcamSelfIntegrityOK, &info) == 0 || !info.dli_fbase) return;
        struct mach_header_64 *hdr = (struct mach_header_64 *)info.dli_fbase;
        if (hdr->magic != MH_MAGIC_64) return;
        uint8_t *p = (uint8_t *)hdr + sizeof(struct mach_header_64);
        for (uint32_t c = 0; c < hdr->ncmds; c++) {
            struct load_command *lc = (struct load_command *)p;
            if (lc->cmd == LC_SEGMENT_64) {
                struct segment_command_64 *seg = (struct segment_command_64 *)p;
                if (strncmp(seg->segname, "__TEXT", 6) == 0) {
                    // __TEXT 段首就是 mach header: 实际起始 = fbase, 与 vmaddr/slide 无关
                    textStart = (uintptr_t)info.dli_fbase;
                    textEnd = textStart + (uintptr_t)seg->vmsize;
                    break;
                }
            }
            p += lc->cmdsize;
        }
    });
    if (textStart == 0 || textEnd == 0) return NO;  // 镜像解析失败 → fail-closed
    // arm64e 根因(1.3.62): class_getMethodImplementation 返回 PAC 签名指针,
    // 签名位占据 VA 位宽之上的全部高位(设备实测 bits 63:36, 真实地址在
    // 低 36 位) —— 原始值直接范围比较必然越界, vcamSelfIntegrityOK 自
    // 1.3.55 起恒 NO 的根因。剥离: 掩码位宽从本镜像 textEnd(无签名的真实
    // 运行时地址)动态推导 —— PAC 签名位全在 VA 位宽之上必被清零; 本镜像
    // 内 IMP 真实地址位宽与 textEnd 相同, 完整保留。arm64(无 PAC) 进程里
    // IMP 本身无签名位, 掩码不改变比较结果, 两架构通用
    uintptr_t vaMask = 1;
    while (vaMask <= textEnd) vaMask <<= 1;
    vaMask -= 1;
    // 关键方法 IMP 必须在本镜像内(被换到别的镜像 = swizzle)
    // 1.3.78 扩展: VCamCore 3 个渲染入口之外, 纳入 VCamNotify 两个激活
    // 判定方法 —— 直接 swizzle +vcamLicenseValid 恒 YES / +vcamCrossDeviceCodeOK
    // 恒 OK 是最省事的破解点(改一个方法换全家桶), 现在同样被范围自检覆盖
    Class clsA = [VCamCore class];
    SEL selsA[3] = {
        @selector(setEnabled:),
        @selector(renderReplacementToPixelBuffer:pts:),
        @selector(hasReplacementFrame),
    };
    // 1.3.78 修正: vcamLicenseValid/vcamCrossDeviceCodeOK 是 +(类方法),
    // 挂在元类上 —— class_getMethodImplementation 传【元类】才查到真实
    // IMP; 传类本身查的是实例方法表 → miss → 返回 _objc_msgForward
    // (libobjc 镜像, 恒在本镜像外) → 恒误报 res=0。1.3.78 首部署日志
    // 实锤(b0==b1==197a5a2c0 = msgForward 地址)
    Class clsB = object_getClass([VCamNotify class]);  // VCamNotify 元类
    SEL selsB[2] = {
        @selector(vcamLicenseValid),
        @selector(vcamCrossDeviceCodeOK),
    };
    BOOL res = YES;
    for (int i = 0; i < 3; i++) {
        IMP imp = class_getMethodImplementation(clsA, selsA[i]);
        uintptr_t a = ((uintptr_t)imp) & vaMask;
        if (a < textStart || a >= textEnd) res = NO;
    }
    for (int i = 0; i < 2; i++) {
        IMP imp = class_getMethodImplementation(clsB, selsB[i]);
        uintptr_t a = ((uintptr_t)imp) & vaMask;
        if (a < textStart || a >= textEnd) res = NO;
    }
    // 1.3.61 自检诊断(每进程一次): text 段范围 + 掩码 + 三 IMP 剥离后地址
    // + 首个原始值 + 结果(1.3.62 起 a0/a1/a2 应落在 text 范围内)
    static BOOL intDiagLogged = NO;
    if (!intDiagLogged) {
        intDiagLogged = YES;
        vcam_core_log([NSString stringWithFormat:
            @"[vcam] self int diag text=[%lx,%lx) mask=%lx a0=%lx a1=%lx a2=%lx b0=%lx b1=%lx raw0=%lx res=%d",
            (unsigned long)textStart, (unsigned long)textEnd,
            (unsigned long)vaMask,
            ((uintptr_t)class_getMethodImplementation(clsA, selsA[0])) & vaMask,
            ((uintptr_t)class_getMethodImplementation(clsA, selsA[1])) & vaMask,
            ((uintptr_t)class_getMethodImplementation(clsA, selsA[2])) & vaMask,
            ((uintptr_t)class_getMethodImplementation(clsB, selsB[0])) & vaMask,
            ((uintptr_t)class_getMethodImplementation(clsB, selsB[1])) & vaMask,
            (uintptr_t)class_getMethodImplementation(clsA, selsA[0]), res]);
    }
    return res;
}

// ===== __TEXT 哈希自校验(1.3.70 防破解加强, 磁盘口径) =====
// 原理: 构建期 inject_text_sig.py 对 fat dylib 的 arm64e slice __TEXT 段
// 跳 40B 签名洞计算 SHA256 写入洞内; 本函数运行时【直接读磁盘文件】用
// 完全相同口径重算比对(洞在 __TEXT,__vcsig, inject 与本函数同源)。
// 任何对 dylib __TEXT 的字节修改(改跳转/NOP 门禁/patch 常量)→ 磁盘
// 哈希失配 → licMark 关门禁 → 替换/打光静默失效。
//
// 为什么磁盘口径而非内存口径(设备实锤教训): 洞放 __DATA 被 dyld chained
// fixups 清零; 洞放 __TEXT 内存魔数在但哈希区仍被加载链路清零(ellekit
// 缓存副本处理) —— 内存侧洞不可信。磁盘侧: dylib 文件被 RootHide
// trustcache 锁定(CD hash 注册, 改文件=加载失败), 运行时磁盘校验与
// trustcache 形成双保险; 内存 patch(改 COW 页)属高门槛攻击(需调试器+
// root), 由 IMP 范围自检(vcamSelfIntegrityOK)另行覆盖。
// 开销: ~760KB 读 + SHA256 ≈ 8ms, 30s 节流, md/SB 双侧独立。
// 洞内哈希全 0(本地构建未注入)→ 跳过(开发语义)。
static BOOL vcamSelfTextOK(void) {
    static BOOL cached = NO;
    static BOOL hasCache = NO;
    static double cachedAt = 0;
    double now = CFAbsoluteTimeGetCurrent();
    if (hasCache && (now - cachedAt) < 30.0) return cached;
    cachedAt = now;
    hasCache = YES;
    cached = NO;

    // CommonCrypto 流式 API(显式加载)
    typedef int (*Sha256InitFn)(void *);
    typedef int (*Sha256UpdateFn)(void *, const void *, size_t);
    typedef int (*Sha256FinalFn)(void *, unsigned char *);
    static Sha256InitFn shaInit = NULL;
    static Sha256UpdateFn shaUpdate = NULL;
    static Sha256FinalFn shaFinal = NULL;
    static BOOL symProbed = NO;
    if (!symProbed) {
        symProbed = YES;
        void *cc = dlopen("/usr/lib/system/libcommonCrypto.dylib", RTLD_LAZY);
        if (cc) {
            shaInit = (Sha256InitFn)dlsym(cc, "CC_SHA256_Init");
            shaUpdate = (Sha256UpdateFn)dlsym(cc, "CC_SHA256_Update");
            shaFinal = (Sha256FinalFn)dlsym(cc, "CC_SHA256_Final");
        }
    }
    if (!shaInit || !shaUpdate || !shaFinal) {
        vcam_core_log(@"[vcam] text sig: commonCrypto unavailable, fail-closed");
        return NO;
    }

    // 本镜像文件路径(dladdr)
    Dl_info info;
    if (dladdr((void *)&vcamSelfTextOK, &info) == 0 || !info.dli_fname) return NO;
    const char *fname = info.dli_fname;

    // 读磁盘文件全文(763KB; 30s 节流一次可接受)
    int fd = open(fname, O_RDONLY, 0);
    if (fd < 0) return NO;
    off_t fsz = lseek(fd, 0, SEEK_END);
    if (fsz <= 0 || fsz > (64 << 20)) { close(fd); return NO; }
    NSMutableData *fileData = [NSMutableData dataWithLength:(NSUInteger)fsz];
    if (!fileData) { close(fd); return NO; }
    if (pread(fd, fileData.mutableBytes, (size_t)fsz, 0) != (ssize_t)fsz) {
        close(fd);
        return NO;
    }
    close(fd);
    const uint8_t *fb = (const uint8_t *)fileData.bytes;
    size_t flen = (size_t)fsz;

    // fat 定位 arm64e slice(fat 头大端: magic CAFEBABE/F, nfat, 20B/项)
    uint32_t sliceOff = 0, sliceSize = 0;
    uint32_t fmagic = (uint32_t)fb[0] << 24 | (uint32_t)fb[1] << 16 | (uint32_t)fb[2] << 8 | fb[3];
    if (fmagic == 0xCAFEBABEu || fmagic == 0xCAFEBABFu) {
        if (flen < 8) return NO;
        uint32_t nfat = (uint32_t)fb[4] << 24 | (uint32_t)fb[5] << 16 | (uint32_t)fb[6] << 8 | fb[7];
        for (uint32_t i = 0; i < nfat && 8 + 20 * (i + 1) <= flen; i++) {
            const uint8_t *e = fb + 8 + 20 * i;
            uint32_t cputype = (uint32_t)e[0] << 24 | (uint32_t)e[1] << 16 | (uint32_t)e[2] << 8 | e[3];
            uint32_t cpusub  = (uint32_t)e[4] << 24 | (uint32_t)e[5] << 16 | (uint32_t)e[6] << 8 | e[7];
            uint32_t off     = (uint32_t)e[8] << 24 | (uint32_t)e[9] << 16 | (uint32_t)e[10] << 8 | e[11];
            uint32_t size    = (uint32_t)e[12] << 24 | (uint32_t)e[13] << 16 | (uint32_t)e[14] << 8 | e[15];
            if (cputype == 0x0100000C && (cpusub & 0x00FFFFFF) == 2) {
                sliceOff = off;
                sliceSize = size;
                break;
            }
        }
        if (sliceOff == 0 || sliceOff + sliceSize > flen) return NO;
    } else {
        // thin: 整个文件
        sliceOff = 0;
        sliceSize = (uint32_t)flen;
    }
    const uint8_t *sl = fb + sliceOff;

    // slice 内: __TEXT 段长 + __vcsig section 洞定位(load commands 小端)。
    // 洞定位走 section 表(与 inject_text_sig.py 同口径: __TEXT nsects 个
    // section_64 里找 __vcsig)。哈希范围从 header+sizeofcmds 起(load
    // command 区排除: ldid -S 重签会改该区 11B —— CI before/after diff
    // 实锤; 代码区不变。load command 区由 trustcache CD hash 保护)
    uint32_t smagic = (uint32_t)sl[0] | (uint32_t)sl[1] << 8 | (uint32_t)sl[2] << 16 | (uint32_t)sl[3] << 24;
    if (smagic != 0xFEEDFACF) return NO;
    uint32_t ncmds = (uint32_t)sl[16] | (uint32_t)sl[17] << 8 | (uint32_t)sl[18] << 16 | (uint32_t)sl[19] << 24;
    size_t textLen = 0;
    long hole = -1;
    size_t skipLen = 0;  // 哈希起点 = __TEXT 第一个 section offset(内容区)
    size_t p = 32;
    for (uint32_t c = 0; c < ncmds && p + 72 <= (size_t)sliceSize; c++) {
        uint32_t cmd = (uint32_t)sl[p] | (uint32_t)sl[p + 1] << 8 | (uint32_t)sl[p + 2] << 16 | (uint32_t)sl[p + 3] << 24;
        uint32_t cmdsize = (uint32_t)sl[p + 4] | (uint32_t)sl[p + 5] << 8 | (uint32_t)sl[p + 6] << 16 | (uint32_t)sl[p + 7] << 24;
        if (cmd == 0x19) {  // LC_SEGMENT_64
            const char *segname = (const char *)(sl + p + 8);
            if (strncmp(segname, "__TEXT", 6) == 0) {
                // vmaddr(24) vmsize(32) fileoff(40) filesize(48) nsects(64) 小端
                uint64_t vmsize = 0, filesize = 0;
                for (int k = 0; k < 8; k++) {
                    vmsize |= (uint64_t)sl[p + 32 + k] << (8 * k);
                    filesize |= (uint64_t)sl[p + 48 + k] << (8 * k);
                }
                uint32_t nsects = (uint32_t)sl[p + 64] | (uint32_t)sl[p + 65] << 8 | (uint32_t)sl[p + 66] << 16 | (uint32_t)sl[p + 67] << 24;
                textLen = (size_t)(filesize < vmsize ? filesize : vmsize);
                // section_64 表(紧跟 segment 命令): 每项 80B
                // s=0 的 offset = 内容区物理起点(ldid 重签不改; sizeofcmds
                // 逻辑值含 padding 会差 16B —— CI before/after 实锤)
                size_t sp = p + 72;
                for (uint32_t s = 0; s < nsects && sp + 80 * (s + 1) <= (size_t)sliceSize; s++) {
                    const uint8_t *sect = sl + sp + 80 * (size_t)s;
                    uint32_t soff = (uint32_t)sect[48] | (uint32_t)sect[49] << 8 | (uint32_t)sect[50] << 16 | (uint32_t)sect[51] << 24;
                    if (s == 0) skipLen = (size_t)soff;
                    if (strncmp((const char *)sect, "__vcsig", 8) == 0) {
                        uint64_t ssize = 0;
                        for (int k = 0; k < 8; k++) ssize |= (uint64_t)sect[40 + k] << (8 * k);
                        if (ssize == 40) hole = (long)soff;
                        break;
                    }
                }
                break;
            }
        }
        p += cmdsize;
    }
    if (skipLen == 0 || skipLen >= (size_t)hole) return NO;  // 口径破坏
    if (textLen == 0 || textLen > (size_t)sliceSize) return NO;
    if (hole < 0) {
        vcam_core_log(@"[vcam] text sig: __vcsig section not found, fail-closed");
        return NO;
    }
    if ((size_t)hole + 40 > textLen) {
        vcam_core_log(@"[vcam] text sig: hole outside __TEXT on disk, fail-closed");
        return NO;
    }
    // 洞内魔数 sanity(非搜索, 单点验证)
    const uint8_t MAGIC[8] = {0x56, 0x43, 0x54, 0x58, 0x53, 0x49, 0x47, 0x31};
    if (memcmp(sl + hole, MAGIC, 8) != 0) {
        vcam_core_log(@"[vcam] text sig: hole magic mismatch, fail-closed");
        return NO;
    }
    // 洞内哈希(磁盘侧, 加载链路不碰)
    const uint8_t *expect = sl + hole + 8;
    BOOL allZero = YES;
    for (int i = 0; i < 32; i++) {
        if (expect[i] != 0) { allZero = NO; break; }
    }
    if (allZero) {
        cached = YES;  // 本地构建未注入 → 开发语义跳过
        static BOOL zeroDiag = NO;
        if (!zeroDiag) {
            zeroDiag = YES;
            vcam_core_log(@"[vcam] text sig: hole empty (dev build), skip");
        }
        return cached;
    }

    // 流式 SHA256: [skipLen, textLen) 跳洞(与 inject 口径严格一致)
    uint8_t digest[32];
    _Alignas(16) unsigned char ctxBuf[128];  // CC_SHA256_CTX(arm64 ~104B, 给足)
    if (shaInit(ctxBuf) != 1) return NO;
    if (shaUpdate(ctxBuf, sl + skipLen, (size_t)hole - skipLen) != 1) return NO;
    size_t tailLen = textLen - (size_t)hole - 40;
    if (tailLen > 0 && shaUpdate(ctxBuf, sl + hole + 40, tailLen) != 1) return NO;
    if (shaFinal(digest, ctxBuf) != 1) return NO;

    BOOL diskOK = (memcmp(digest, expect, 32) == 0);

    // 1.3.78 内存口径(补运行时 COW patch 的洞): 磁盘校验只见文件改动,
    // 进程内 patch 代码页(改运行中指令)磁盘不变 → 旧版看不见。同口径
    // (同 skip/同跳洞)哈希【内存镜像】__TEXT, 与磁盘哈希比对: 内存被
    // patch → 失配 → 关门禁。洞区本就被口径跳过, ellekit 清零洞区无感
    // (1.3.70 教训只影响洞内容, 不影响跳洞哈希); __TEXT 无 dyld fixup
    // (chained fixups 只动 __DATA/__DATA_CONST), 内存==磁盘是稳态。
    const uint8_t *mem = (const uint8_t *)info.dli_fbase;
    uint8_t mdigest[32];
    _Alignas(16) unsigned char mctx[128];
    BOOL memOK = NO;
    if (shaInit(mctx) == 1
        && shaUpdate(mctx, mem + skipLen, (size_t)hole - skipLen) == 1
        && (tailLen == 0 || shaUpdate(mctx, mem + hole + 40, tailLen) == 1)
        && shaFinal(mdigest, mctx) == 1) {
        memOK = (memcmp(mdigest, digest, 32) == 0);
    }
    cached = diskOK && memOK;
    static BOOL sigDiag = NO;
    if (!sigDiag || !cached) {
        if (!sigDiag) sigDiag = YES;
        vcam_core_log([NSString stringWithFormat:
            @"[vcam] text sig diag(disk=%d mem=%d) len=%zu hole=%ld d0=%02x%02x m0=%02x%02x e0=%02x%02x img=%s",
            diskOK, memOK, textLen, hole,
            digest[0], digest[1], mdigest[0], mdigest[1], expect[0], expect[1], fname]);
    }
    return cached;
}

// ===== 1.3.78 延迟注入检测(反 frida/二次 hook 框架注入) =====
// 原理: 首次调用(进程启动后首拍, ~0.15s)快照全部已加载 image 路径 ——
// 正常加载链路装载我们的 hook 框架(ellekit/libhooker 等)此时已在场,
// 全部进快照永不误报。此后每 30s 重枚举: 新出现且路径含注入框架特征词
// → 在我们【之后】被 dlopen 进来的 hook 框架(frida-agent 注入破解/
// 破解者的 interposer dylib) → 关门禁。系统框架/相机管线后续懒加载的
// 正常 dylib 不含特征词, 不受影响。
static BOOL vcamNoLateHookLibs(void) {
    static NSArray<NSString *> *snapshot = nil;
    static double lastScan = 0;
    static BOOL lastRes = YES;
    double now = CFAbsoluteTimeGetCurrent();
    if (snapshot && now - lastScan < 30.0) return lastRes;
    lastScan = now;

    uint32_t n = _dyld_image_count();
    if (!snapshot) {
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
        for (uint32_t i = 0; i < n; i++) {
            const char *nm = _dyld_get_image_name(i);
            if (nm) [a addObject:[NSString stringWithUTF8String:nm]];
        }
        snapshot = [a copy];
        vcam_core_log([NSString stringWithFormat:
            @"[vcam] hook watch: snapshot %u images", (unsigned)n]);
        return YES;
    }
    static NSArray<NSString *> *kw = nil;
    if (!kw) kw = @[@"frida", @"substrate", @"substitute", @"libhooker",
                    @"ellekit", @"elup", @"psunday", @"cynject", @"dobby",
                    @"stalker", @"flexdecrypt", @"dumpdecrypt"];
    BOOL res = YES;
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        NSString *s = [NSString stringWithUTF8String:nm];
        if ([snapshot containsObject:s]) continue;
        NSString *low = [s lowercaseString];
        for (NSString *k in kw) {
            if ([low containsString:k]) {
                res = NO;
                vcam_core_log([NSString stringWithFormat:
                    @"[vcam] hook watch: LATE hook lib detected: %@ — closing gate", s]);
                break;
            }
        }
    }
    lastRes = res;
    return res;
}

@interface VCamCore ()
@property (nonatomic, strong) dispatch_source_t pollingTimer;
@property (nonatomic, assign) BOOL pollingActive;
@property (nonatomic, assign) BOOL lastEnabledState;
// 密钥门禁(1.3.55): 双变量双路径 —— licGate(ECDSA 验签, VCamNotify)与
// licMark(跨进程互证+IMP 自检, 每拍重算)。render 入口与 hasReplacementFrame
// 分别检查不同组合: 单点补丁只能跳过一处, 另一处仍拦截(扩散校验)。
// 周期重算(0.15s)也意味着内存中强翻 BOOL 会在下一拍被纠正回真实值
@property (nonatomic, assign) BOOL licGate;
@property (nonatomic, assign) BOOL licMark;
// 帧缓存: 避免每次 render 都调用 processPixelBuffer（24fps 视频 vs 60fps 相机）
@property (nonatomic, assign) CVPixelBufferRef cachedProcessedFrame;
@property (nonatomic, assign) uint64_t lastProcessedFrameCount;
@property (nonatomic, assign) size_t lastProcessedWidth;
@property (nonatomic, assign) size_t lastProcessedHeight;
@property (nonatomic, assign) OSType lastProcessedFormat;
@property (nonatomic, assign) BOOL prerenderActive;
// writeFrame 专用锁: VT session/CIContext 非线程安全, 多 hook 线程(预览/照片/视频节点)并发调用会输出黑帧/崩溃
@property (nonatomic, strong) NSLock *renderLock;
// 无帧回退缓存(对齐千面 _0x150/_0x158/_0x160): 视频解码间隙用上一帧填充, 避免闪回相机画面
@property (nonatomic, assign) CVPixelBufferRef fallbackFrame;
@property (nonatomic, assign) size_t fallbackWidth;
@property (nonatomic, assign) size_t fallbackHeight;
// 同帧去重(对齐千面 _0x78/_0x70): 管线同一物理 buffer 连续经过多个消费者,
// 第一次已改写, 后续直接跳过(不 retain, 仅指针比较)
// 时间窗(2026-08-17 闪烁根治): 相机管线 IOSurface 池只有 3~6 个 buffer 循环
// 轮转, 帧 N 用 buffer A 替换后帧 N+2 又轮到同一地址 → 裸指针比较误判"已替换"
// 跳过 → 真实相机画面上屏 → 与替换帧稳定交替 = 用户看到的"替换/原画面闪烁"。
// 千面 0xaed4 判定的是"同一帧时间窗内多消费者"(间隔 <1ms), 不是跨帧轮转
// (≥16ms)。加 5ms 窗口区分两者。
@property (nonatomic, assign) CVPixelBufferRef dedupLastBuffer;
@property (nonatomic, assign) CFAbsoluteTime dedupLastTime;
// 去重 v2(2026-08-19 IOFence 死锁根治): 最近一次渲染的相机帧 PTS(与指针联合判定)
@property (nonatomic, assign) double dedupLastPts;
// 快照最近一次推进时的相机帧 PTS(2026-08-17 卡顿修复): 相机帧边界判定
@property (nonatomic, assign) double lastAdvancePts;

// ===== 性能优化(2026-08-15) =====
// 进程标记: 只有 mediaserverd 真正解码/预渲染; SpringBoard 的 VCamCore 只做状态记录,
// 否则 SB 进程白白解码整个视频(30fps 解码+转换) → 桌面卡顿/按钮迟钝
@property (nonatomic, assign) BOOL isMediaserverdProcess;
// 源帧代数(单调递增): 每存入新帧 +1。render 设置到 gpuProcessor.frameToken,
// 供私有格式两步法的 staging 缩放复用(同帧多流渲染时缩放只做一次, CPU 减半)
@property (nonatomic, assign) uint64_t liveFrameGen;
// 预渲染重复源跳过: 无新帧入队(解码计数未变)且旋转/镜像未变时, 跳过重复的旋转+格式转换
@property (nonatomic, assign) uint64_t lastPrerenderSrcGen;
@property (nonatomic, assign) int lastPrerenderRot;
// 1.3.49 打光快速响应: 光色/参数变化立即唤醒预渲染线程出拍 —— 早醒拍只
// 重产出当前帧(不消费解码队列), 绝对时间节拍器自愈, 帧率不受影响;
// sem 替代 NSThread sleep(超时等待=正常节拍, signal=光变化即时出拍)
@property (nonatomic, strong) dispatch_semaphore_t prerenderWakeSem;
@property (nonatomic, assign) BOOL prerenderWakeEarly;
@property (nonatomic, assign) BOOL lastPrerenderMirror;
// 用户画面变换(箭头/＋/−/复)也纳入跳过判定: 暂停/图片模式下 frameCount 不变,
// 但悬浮球改了 pan/zoom 时必须重新产出(把新 cleanAperture 附件烘焙进 live 帧)
@property (nonatomic, assign) double lastPrerenderPanX;
@property (nonatomic, assign) double lastPrerenderPanY;
@property (nonatomic, assign) double lastPrerenderZoom;
// 三色打光签名(1.3.37)也纳入跳过判定: 暂停状态下检测颜色跳变/滑块调节时
// 必须重新产出(注入新光斑)。签名打包: enabled(1) color(24) x/y/int/dia/fea(7×5)
@property (nonatomic, assign) uint64_t lastPrerenderLightSig;

// ===== 相机空闲门控(2026-08-16 发热优化) =====
// 根因: 替换开启期间解码+预渲染按视频帧率 30fps 常转, 而相机流只在 App 打开相机时
// 才到达 hook —— "开着替换但没用相机"的绝大部分时间(桌面/后台/非相机 App)全是空转,
// 这是常驻发热的主源。门控: render 心跳 >2s 无相机流 → 暂停解码(常驻线程空转睡眠,
// CPU≈0)+预渲染睡眠; 相机流恢复(render 被调)同步即时唤醒(先吃缓存帧, 解码 ~100ms 内跟上)
@property (nonatomic, assign) CFAbsoluteTime lastRenderActivity;
@property (nonatomic, assign) BOOL pipelineIdle;
// 空闲卸载标记(2026-08-18 云闪付崩溃循环): pipelineIdle 暂停时已卸载媒体管线,
// render 心跳恢复时按 _idleResumePath 异步重载(期间渲染冻结快照帧不黑屏)
@property (nonatomic, assign) BOOL idleUnloaded;
@property (nonatomic, copy) NSString *idleResumePath;
// 恢复保持(2026-08-19 卡顿修复): 恢复重载后 5s 内不许再次 idle 卸载 ——
// 扫码页帧间歇突发(2-3s 一拨)曾造成 4s 内 4 轮卸载/重载抖动, 每轮重建
// reader+预填都是 CPU 尖峰且画面反复冻在旧帧
@property (nonatomic, assign) CFAbsoluteTime lastIdleResumeTime;
// CPU 闭环降载(2026-08-16): 进程 CPU 接近 daemon 50% 红线时置 YES ——
// 解码/预渲染节拍降为 1/3(替换内容 ~10fps 更新, 连续无感), 冻结帧走 staging 复用
@property (nonatomic, assign) BOOL lowPowerDecode;
// 相机会话起点(2026-08-20 首开卡顿修复): render 心跳中断 >2s(watchdog 同款判定)
// 后恢复 = 新相机会话(热进程首开/空闲重开/切App)。会话起点后 8s 是 CPU 闭环
// 豁免窗 —— 相机启动风暴(管线init+媒体重载+预填+各流首帧建槽)是一次性成本,
// EMA>72 误触发降载把 24fps 压到 20fps(每秒丢4帧, 用户看到"开头掉帧卡顿"),
// 再熬 10s 保持期才退出 = "过一段时间才流畅"的直接来源
@property (nonatomic, assign) CFAbsoluteTime camSessionStart;
// 多流显示同步(2026-08-16 照片模式叠影修复): 照片模式预览流+照片缩放流同时活跃,
// 各流 render 时刻不同且缓存 key 不同(尺寸/格式各异), 仅量化代数不够 —— 窗口内
// 不同流仍会从 live buffer 取到不同时间的帧, App 融合两流 → 两个画面叠影。
// 快照方案: 每 1/视频fps 窗口推进时 retain 锁定当前 _liveYUVPixelBuffer 为
// syncDisplayFrame, 窗口内所有流统一渲染该快照 + 同一 gen → 内容强制一致。
// 快照生命周期 ≤1 帧 < 预渲染 3-slot 旋转池复用周期(3 帧), 不会被覆写
@property (nonatomic, assign) CVPixelBufferRef syncDisplayFrame;
@property (nonatomic, assign) uint64_t syncDisplayGen;
@property (nonatomic, assign) CFAbsoluteTime lastGenAdvanceTime;
@end

@implementation VCamCore

// msd 进程早期时刻(VCamCore init, dylib 加载即跑, 与进程启动几乎同步):
// 用于 boot grace 的冷热判定 —— 冷启动首帧(间隔<30s)有系统服务启动叠加,
// 需要 grace 压启动风暴; 热运行首开相机(间隔>30s)无叠加, 全速安全
static CFAbsoluteTime gVcamProcInitTime = 0;

+ (instancetype)sharedInstance {
    static VCamCore *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamCore alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _prerenderQueue = dispatch_queue_create("com.vcam.processing", DISPATCH_QUEUE_SERIAL);
        // 预渲染 Default 优先级(2026-08-16 卡顿修复): Utility 下预渲染被饿死 → 旋转转换
        // 跟不上解码 → _liveYUV 长时间不更新 → render 反复写旧帧 → 卡顿观感。
        // (8-15 降 Utility 时 render 是全局锁串行大负载; 现在 per-stream 并行 + 微型流
        //  跳过 + 相机空闲门控后我们负载已大降, Default 与服务同级竞争安全)
        _processingQueue = dispatch_queue_create("com.vcam.processing.bg", DISPATCH_QUEUE_SERIAL);
        _processLock = [[NSLock alloc] init];
        _renderLock = [[NSLock alloc] init];
        _isPixelBufferMode = YES;
        _preprocessEnabled = YES;
        _enabled = NO;
        _targetSizeKnown = NO;
        _targetWidth = 0;
        _targetHeight = 0;
        _targetFormat = 0;
        _liveBGRAPixelBuffer = NULL;
        _liveYUVPixelBuffer = NULL;
        _lastRenderedWidth = 0;
        _lastRenderedHeight = 0;
        _frameCount = 0;
        _pollingActive = NO;
        _lastEnabledState = NO;
        _cachedProcessedFrame = NULL;
        _lastProcessedFrameCount = 0;
        _lastProcessedWidth = 0;
        _lastProcessedHeight = 0;
        _lastProcessedFormat = 0;
        _prerenderActive = NO;
        _prerenderWakeSem = dispatch_semaphore_create(0);  // 1.3.49 打光早醒

        // 初始化组件 —— SpringBoard 轻量化(2026-08-15):
        // SB 只记录状态(悬浮球按钮全走 vc.plist, 替换渲染在 mediaserverd),
        // 不创建解码/渲染组件(LocalVideoPlayer+GPUImageProcessor+CIContext+VT sessions)。
        // 降 SB 常驻内存/句柄 → 整机 CPU 余量增大(前台 App 相机 watchdog 是 CPU 超时触发)。
        // 轮询回调对 nil 的访问全部是 nil-messaging no-op, 安全
        if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) {
            _gpuProcessor = nil;
            _videoPlayer = nil;
            _frameQueue = nil;
            vcam_core_log(@"[vcam] VCamCore initialized lean in SpringBoard (no decoder/renderer)");
        } else {
            _gpuProcessor = [[GPUImageProcessor alloc] init];
            _videoPlayer = [[LocalVideoPlayer alloc] initWithCapacity:10];
            _videoPlayer.gpuProcessor = _gpuProcessor;
            _frameQueue = _videoPlayer.frameQueue;
        }

        // CIContext（软件渲染）
        @try {
            _ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
        } @catch (NSException *e) {
            _ciContext = nil;
        }

        vcam_core_log(@"[vcam] VCamCore initialized with multi-format buffer pools (vcamplus style)");
        if (gVcamProcInitTime == 0) gVcamProcInitTime = CFAbsoluteTimeGetCurrent();
    }
    return self;
}

- (void)dealloc {
    [self stopStatePolling];
    [self clearReplacementFrame];
    vcam_core_log(@"[vcam] VCamCore deallocated");
}

#pragma mark - 初始化

- (void)initializeInMediaserverd {
    vcam_core_log(@"[vcam] Initializing in mediaserverd...");
    // 仅真 mediaserverd 解码/预渲染: Tweak 构造器对 lskdd 等其他进程也调本方法,
    // 那些进程没有相机 hook, 全功能解码纯属浪费(多进程 AVFoundation 队列压力)
    _isMediaserverdProcess = [[[NSProcessInfo processInfo] processName] isEqualToString:@"mediaserverd"];
    // mediaserverd 中用 plist 轮询（Darwin 通知不安全）
    [self startStatePolling];
    vcam_core_log([NSString stringWithFormat:@"[vcam] MediaServerd hooks initialized (decoder=%d)", _isMediaserverdProcess]);
}

- (void)initializeInSpringBoard {
    vcam_core_log(@"[vcam] SpringBoard hooks initialized");
    // SpringBoard 中也用 plist 轮询
    [self startStatePolling];
}

#pragma mark - 核心方法

- (void)renderReplacementToPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    [self renderReplacementToPixelBuffer:pixelBuffer pts:0];
}

- (void)renderReplacementToPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(double)pts {
    if (!pixelBuffer || !_enabled) return;
    // 密钥门禁(1.3.55): 双变量检查 —— 单点补丁只能跳过一处, 另一处仍拦截。
    // 轮询已按 effEnabled 停管线, 此处拦截竞态窗口(plist enabled=YES 而
    // 门禁尚未轮询到/被绕过 UI 直改 plist/内存强翻 BOOL 未到下一拍)
    if (!_licGate || !_licMark) return;

    // 同帧去重 v2(2026-08-19 IOFence GPU 死锁根治): 指针 + PTS 双重判定, 检查与
    // 登记同锁原子完成。旧"指针+5ms 窗"两个缺陷(设备实证 00:00:13 gpuEvent
    // "blocked by IOFence": 3 个同调用栈 GPU 等待者挤在同一 surface 上):
    //   1) 无锁竞态: emit/scaler/encoder 三个 hook 在不同 Apple 队列线程并发消费
    //      同一物理相机帧, 双双通过旧检查 → 同一相机 IOSurface 上并发排入多个
    //      VT GPU 写 + 下游节点同时持 fence → fence 互等死锁 → GPU 固件重启 →
    //      画面冻结后黑屏(msd 不死, 替/原无效, 只有重开相机/重启恢复)。
    //   2) 5ms 窗误放行: 慢消费者(>5ms 后到)对已被相机池回收的 surface 补写旧帧,
    //      与新帧的 ISP/GPU 处理撞车。
    // PTS 判定: 同一物理帧跨节点(emit/scaler/encoder)PTS 恒等 → 同指针+同 PTS =
    // 重复消费, 跳过; 池轮转回同指针但 PTS 已新 = 新帧, 渲染; 多流各自 buffer
    // 同 PTS = 各自渲染(指针不同, 不受影响)。PTS 不可用(=0 旧调用方)回退旧
    // 指针+5ms 窗。入口即占位登记: 并发第二个消费者必然看到 dup 跳过 ——
    // 同一 surface 任一时刻至多一个在飞的 VT GPU 写(fence 单向, 无环)。
    {
        static NSLock *dedupLock;
        static dispatch_once_t onceTok;
        dispatch_once(&onceTok, ^{ dedupLock = [[NSLock alloc] init]; });
        [dedupLock lock];
        CFAbsoluteTime nowDedup = CFAbsoluteTimeGetCurrent();
        BOOL samePtr = (self->_dedupLastBuffer == pixelBuffer);
        // 同指针 + (同 PTS 或 5ms 内) = 重复消费: PTS 抓慢消费者(同帧跨节点 PTS
        // 恒等, 无时间上限), 5ms 窗兜底同帧异 PTS 的节点实现; 池轮转新帧 PTS
        // 必新且距上次 ≥16ms → 两信号都放行, 必渲染
        BOOL dup = samePtr && ((pts > 0 && self->_dedupLastPts == pts) ||
                               (nowDedup - self->_dedupLastTime < 0.005));
        if (pts > 0) self->_dedupLastPts = pts;
        self->_dedupLastBuffer = pixelBuffer;  // 占位: 并发后来者必 dup
        self->_dedupLastTime = nowDedup;
        [dedupLock unlock];
        if (dup) return;
    }

    OSType origFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    size_t targetW = CVPixelBufferGetWidth(pixelBuffer);
    size_t targetH = CVPixelBufferGetHeight(pixelBuffer);

    // 微型流也替换(2026-08-17 闪烁根治): 撤掉旧 <640x480 硬跳过 —— 扫码/网页/
    // 社交 App 常用低分辨率档(如 480x360 Medium)做**可见**预览, 被跳过的流永远
    // 显示真实相机; App 在高流(替换)与低流(跳过)间切换显示 = "替换/原画面闪烁",
    // 且扫码页整个不被替换(用户实证反馈)。
    // 旧担忧('18f0' 328x184 分析流 wakeups 风暴)已被两级熔断根治: stage1 失败
    // 回退 BGRA 重试一次, stage1/stage2 连续失败 2 次永久熔断该流(不再有
    // "失败→重建 session→再失败"循环)。微型流像素量小(≤0.2MP), 替换成本可忽略;
    // CPU 兜底由 80/60 紧急档闭环降载负责。

    // 相机活跃心跳 + 空闲即时唤醒(2026-08-16 发热优化): 走到这里 = 有真实可见相机流,
    // 刷新心跳; 若管线处于空闲暂停态(相机关闭过)则同步恢复解码(常驻线程只翻标志, 零延迟),
    // 本帧先吃 _liveYUVPixelBuffer 缓存帧, 解码 ~100ms 内跟上 —— 用户无感知
    CFAbsoluteTime prevActivity = self->_lastRenderActivity;
    self->_lastRenderActivity = CFAbsoluteTimeGetCurrent();
    // 相机会话起点跟踪(2026-08-20 首开卡顿修复): 首帧 或 心跳中断>2s 后恢复
    // (watchdog 同款判定) = 新相机会话。会话起点供 CPU 闭环做启动风暴豁免
    if (prevActivity == 0 || self->_lastRenderActivity - prevActivity > 2.0) {
        self->_camSessionStart = self->_lastRenderActivity;
    }
    if (self->_pipelineIdle) {
        self->_pipelineIdle = NO;                 // 预渲染线程 ≤0.1s 内自行恢复
        [self->_videoPlayer startDecodingThread]; // 空转线程恢复解码标志
        self->_lastIdleResumeTime = CFAbsoluteTimeGetCurrent();  // 恢复保持窗口起算(2026-08-19): 每次"暂停→恢复"都刷新, 防止相机流 5-10s 周期静默时 pause/resume 抖动
        // 空闲卸载过媒体管线(2026-08-18): 异步重载 —— 期间本帧与后续帧渲染
        // _syncDisplayFrame 冻结快照(画面静止不黑), 加载完成后预渲染无缝跟上。
        // 必须后台队列(2026-08-18 watchdog 修复): loadVideoFile 内
        // tracksWithMediaType 是同步磁盘解析, 直接在 render(相机管线 hook 线程)
        // 执行会阻塞相机管线 0.5-2s → mediaserverd watchdog 杀进程(设备实证:
        // 恢复重载后 6s 被杀)。冻结帧机制保证加载期间画面连续
        if (self->_idleUnloaded) {
                self->_idleUnloaded = NO;
                NSString *resumePath = self->_idleResumePath;
            if (resumePath.length > 0) {
                VCamCore *core = self;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                    [core->_videoPlayer loadVideoAtPath:resumePath completion:nil];
                });
                vcam_core_log([NSString stringWithFormat:@"[vcam] camera resume after idle unload, reloading(async): %@", resumePath.lastPathComponent]);
            }
        }
    }

    // 1. 显示快照 + 帧代数(2026-08-16 照片模式叠影修复):
    // 每 1/视频fps 窗口推进一次, 推进时 retain 锁定当前 live 帧为快照;
    // 窗口内所有流(预览/照片缩放/录像)统一渲染同一快照 buffer + 同一 gen →
    // 内容强制一致, App 融合多流显示不再出现两个时间点的画面叠影。
    // 快照由本属性 retain, 预渲染替换 live 不影响内容(旋转 slot 池 3 帧复用周期 > 快照 1 帧寿命)
    [_processLock lock];
    {
        uint64_t liveGen = _liveFrameGen;
        CFAbsoluteTime nowQ = CFAbsoluteTimeGetCurrent();
        double vfps = MAX(_videoPlayer.effectiveFps, 1.0);
        // 相机帧边界驱动(2026-08-17 卡顿修复): 旧 1/vfps 时间窗在 30fps 相机流上
        // 被相机帧粒度采样 —— 33.3ms < 41.7ms 不推进, 66.7ms 才推进, 每次跨 2 个
        // 视频帧 → 内容实际 15fps 且隔帧跳 = "停-停-跳"节奏(肉眼可见卡顿)。
        // 改用相机帧 PTS 判定边界: 同一相机帧(emit/scaler/encoder 同帧共享 PTS)
        // 只有首个消费者可推进一次, 同帧其余消费者必然共享同一快照 —— 多流
        // 内容一致性(照片叠影防护)与旧整窗等价; 新相机帧到来即取最新 live:
        // 24fps 内容在 30/60fps 流上呈标准 pulldown 节奏(每帧 1~2 槽位),
        // 不丢帧不冻结。live 更新本身 ≤ 视频帧率, 天然限速无需时间窗。
        // PTS 不可用(0, 旧调用方)回退旧时间窗
        BOOL boundary;
        if (pts > 0) {
            boundary = (pts != self->_lastAdvancePts);
        } else {
            boundary = (nowQ - self->_lastGenAdvanceTime) >= (1.0 / vfps);
        }
        if (_liveYUVPixelBuffer &&
            (liveGen != self->_syncDisplayGen) && (liveGen < self->_syncDisplayGen || boundary)) {
            if (self->_syncDisplayFrame) CVPixelBufferRelease(self->_syncDisplayFrame);
            self->_syncDisplayFrame = CVPixelBufferRetain(_liveYUVPixelBuffer);
            self->_syncDisplayGen = liveGen;
            self->_lastGenAdvanceTime = nowQ;
            self->_lastAdvancePts = pts;
        }
    }
    CVPixelBufferRef yuv = self->_syncDisplayFrame;
    if (yuv) CVPixelBufferRetain(yuv);
    uint64_t gen = self->_syncDisplayGen;
    [_processLock unlock];
    // 帧代数经 writeFrame:toPixelBuffer:token: 参数传递(不写 gpuProcessor 全局属性,
    // 多 hook 线程并发 render 时全局赋值会互相覆盖导致 staging 误用别帧内容)
    CVPixelBufferRef bgra = NULL;

    // CPU 闭环降载(2026-08-16 扫码 CPU 配额被杀最终修复 v3, 取代所有"猜流"启发式):
    // 教训链: 方向判定误伤录像流(跳动)/照片流跳帧闪预览/低分辨率照片流判定误伤
    // 抖音美颜链(比例跳动)+漏掉扫码页可见流 —— 任何"猜哪条流不可见"都不可靠。
    // 物理约束: iOS daemon CPU 限 50% over 180s, 3 流全速替换 67% 必被杀。
    // 唯一两全: 全流全帧替换(永不闪) + CPU 接近红线时冻结内容源 ——
    // 两步法 staging(token) 机制天然支持: 传旧 token → 跳过昂贵缩放(stage1 ~4ms),
    // 只做格式转换(stage2 ~2ms) → 单帧成本降 ~60%, 画面=低帧率视频(连续无感)。
    // 解码/预渲染同步 15fps(降载期), CCW90 随冻结 token 自动复用。
    //
    // 采样(2026-09-01, 1.3.88 振荡根修): 旧 task_threads 逐线程累加是瞬时快照,
    // 线程退出让累计时间凭空消失(负差分), "负差分只推进时间基线"的旧修法让
    // 后续样本被还债式低估 —— 毛刺+低估双重噪声把 EMA 反复推过 110 线 →
    // hardTrip 5 分钟 11 次开关(2026-08-30 日志实证) = 24↔20fps 横跳卡顿。
    // 1.3.88: 采样改 proc_pidinfo 单调口径 + hardTrip 两级判定(>170 立即压;
    // 110-170 需连续越线 ≥8s 才压), 双保险根治振荡。
    // 滞回时间窗: 进入后 ≥5s 不许退出, 退出后 ≥8s 不许再进 —— 防高频振荡
        // 紧急档重构(2026-08-17 横跳根治): 旧 46/48 阈值在正常运行区(实测 45-58%)
        // 内部横跳 → 内容 24↔20fps 反复切换 = 卡顿本身。教训: 系统配额是
        // 180s 均值 50%, 短时 45-58% 峰值完全安全(telemetry 实测无 kill,
        // renders 持续累积)。降载只在真失控(>80%, 如多流突发+解码堆积)时介入,
        // <60% 退出 —— 正常使用永不触发, 内容恒定 24fps。
        {
            static CFAbsoluteTime lastCpuCheck = 0;
            static CFAbsoluteTime lastCpuSample = 0;
            static double lastCpuSec = 0;
            static double emaPct = 0;              // EMA 平滑后 CPU%
            static BOOL emaInit = NO;
            static BOOL lowPower = NO;
            static CFAbsoluteTime lastModeSwitch = 0;  // 上次 ON/OFF 切换时刻
            // 启动冷却(2026-08-18 6秒三连崩根因): mediaserverd 启动/重启后首帧,
            // 相机管线初始化 + 视频加载 + 帧队列预填全速叠加 → CPU 冲 195%
            // (telemetry 实证) → runningboardd 杀(EXC_RESOURCE CPU, 无 .ips) →
            // 重启又冲 → 6 秒三连崩循环。首帧起 10s 强制 lowPower(解码/预渲染
            // 20fps 上限), 系统稳住后转 CPU 闭环接管。static 生命周期 = 进程级,
            // mediaserverd 重启归零重新生效, 相机开关(App 切换)不误触发
            // 冷热判定(2026-08-20 首开卡顿修复): 旧版不分冷热 —— 热运行(msd 早已
            // 稳定)后的相机首开也被压 10s 20fps = 用户日常"第一次打开有摄像头的
            // App 开头掉帧卡顿"主因。首帧距 VCamCore init(进程启动) >30s = 热运行,
            // 无系统服务启动叠加, 跳过 grace 直接全速(CPU 闭环+会话豁免兜底);
            // <30s = 冷启动首开, 保留 10s 强制降载(三连崩实证必须压)
            static CFAbsoluteTime bootGraceUntil = 0;
            static BOOL bootGraceDone = NO;
            // 1.3.88 持续确认计时: EMA 首次越过 110 的时刻(回到 110 以下清零)。
            // 110-170 带需连续越线 ≥8s 才 hardTrip —— 取代旧"单拍越线立即压":
            // 瞬态尖峰(重载突发/残留噪声)自动免疫, 真持续过载 8s 兜底,
            // OFF 后重进天然带 8s 冷却, 24↔20fps 横跳根治
            static CFAbsoluteTime hardHighSince = 0;
            CFAbsoluteTime nowT = CFAbsoluteTimeGetCurrent();
            if (!bootGraceDone) {
                if (bootGraceUntil == 0) {
                    if (gVcamProcInitTime > 0 && nowT - gVcamProcInitTime > 30.0) {
                        bootGraceDone = YES;
                        lastModeSwitch = nowT;
                        vcam_core_log(@"[vcam] hot process camera open, boot grace skipped");
                    } else {
                        bootGraceUntil = nowT + 10.0;
                        lowPower = YES;
                        vcam_core_log(@"[vcam] boot grace: forced throttle 10s (cold start)");
                    }
                } else if (nowT >= bootGraceUntil) {
                    bootGraceDone = YES;
                    // 交接线 72→110(1.3.75 视频播放卡顿根修): 冷启动相机风暴
                    // (管线init+媒体重载+预填)是一次性成本, EMA 45-110 区间是
                    // 风暴尾/正常运行带 —— 旧 72 线让风暴尾(EMA 72-110)在 grace
                    // 结束后继续压 20fps, 叠加首采样毒化后 EMA 天文数字, 用户
                    // 整个观看期(实测 30s)全程 20fps = "视频播放后卡顿掉帧"。
                    // 110 = hardTrip 线: grace 结束时 EMA<110 立即 OFF 恢复源帧率
                    // (帧率稳定硬约束); ≥110(真失控, 逼近 2 核)保持降载, hardTrip
                    // 判定同线接续, 保命(进程被杀=相机全黑)优先。
                    if (emaInit && emaPct < 110.0 && lowPower) {
                        lowPower = NO;
                        lastModeSwitch = nowT - 11.0;  // 免保持, 允许闭环立即再评估
                        vcam_core_log([NSString stringWithFormat:@"[vcam] boot grace ended, EMA %.0f%% below hardTrip line, immediate OFF", emaPct]);
                    } else {
                        lastModeSwitch = nowT;
                        vcam_core_log(@"[vcam] boot grace ended, CPU loop takes over");
                    }
                }
            }
            BOOL graceOn = !bootGraceDone;  // 冷却期内强制低功率
            if (nowT - lastCpuCheck > 0.8) {  // 2s→0.8s(2026-08-18): 响应提速, 旧 2s+EMA 滞后 4-6s 挡不住启动风暴
                double cpuSec = vcam_process_cpu_seconds();
                double delta = (cpuSec >= 0 && lastCpuSec >= 0) ? (cpuSec - lastCpuSec) : -1.0;
                // ===== 自适应解码档位(2026-08-20 多流高压卡顿根治) =====
                // 设备实证(微信等多流 App): 全分辨率解码 + 3 条 720p 流并行 →
                // CPU 稳态 80-86% —— (1)远超 daemon 50% 红线有被杀风险;
                // (2)降载(20fps)进入后稳态远高于退出线 62 永远退不出 = 用户
                // "卡顿不流畅等很久也不恢复"。降载只压解码节拍, render 端
                // 逐流转换才是 CPU 大头, 压不动。唯一有效手段 = 降解码档位:
                // 720 档源端 s1/staging/CCW90 全变小, CPU 回 ~45-55%, 降载
                // 自然退出恢复 24fps(画质 720p, 视频通话/多流场景可接受)。
                // 防横跳: (a)降档快(>72 持续 3s)/升档慢(<55 持续 8s);
                // (b)最小间隔 20s; (c)升档失败(升后 15s 内又降)会话内不再升
                // —— 多流 App 本身就是高压, 反复试升只带来 rebuild 抖动
                //
                // 分辨率降档总开关(2026-08-21, 1.3.23): vc.plist
                // "adaptiveResolution" 默认 NO —— 用户明确要求不压缩替换视频
                // 分辨率(画质优先于 CPU/发热)。NO 时永不降档, CPU 高压由
                // 内容节流(降帧 20fps)兜底, 每帧保持原生清晰; YES 恢复 1.3.12
                // 行为(720 热保护)。开关实时生效(3s 刷新), 开→关时正在 720
                // 档则立即恢复原生。
                {
                    static size_t activeEdge = 0;        // 当前生效档(0=plist 原生)
                    static CFAbsoluteTime highSince = 0, lowSince = 0;
                    static CFAbsoluteTime lastEdgeSwitch = 0;
                    static CFAbsoluteTime upgradeAt = 0;  // 最近一次升档时刻
                    static CFAbsoluteTime stickySession = 0;  // 升档失败标记所属会话
                    static BOOL adaptiveResOn = NO;           // 降档开关(默认关)
                    static CFAbsoluteTime adpResCheckedAt = 0;
                    if (nowT - adpResCheckedAt > 3.0) {  // 低频刷新开关
                        adpResCheckedAt = nowT;
                        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
                        if (d) adaptiveResOn = [d[@"adaptiveResolution"] boolValue];  // 缺省 NO
                    }
                    // 新相机会话重置升档失败标记(场景换了值得再试)
                    if (self->_camSessionStart > 0 && stickySession > 0 &&
                        self->_camSessionStart != stickySession) {
                        stickySession = 0;
                    }
                    // 开关关闭: 永不降档; 若此前已在 720 档立即恢复原生
                    if (!adaptiveResOn) {
                        if (activeEdge != 0) {
                            activeEdge = 0;
                            highSince = 0; lowSince = 0;
                            self->_videoPlayer.dynamicMaxEdge = 0;
                            NSString *rp = self->_videoPlayer.currentVideoPath;
                            if (rp.length > 0) {
                                LocalVideoPlayer *vp = self->_videoPlayer;
                                dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                                    [vp loadVideoAtPath:rp completion:nil];
                                });
                            }
                            vcam_core_log(@"[vcam] adaptiveResolution OFF, decode restored to native (quality first)");
                        }
                    } else {
                    if (emaPct > 72.0) { if (highSince == 0) highSince = nowT; } else highSince = 0;
                    if (emaPct < 55.0) { if (lowSince == 0) lowSince = nowT; } else lowSince = 0;
                    // 降档: 高压持续 3s(降档越快越好, 红线保护优先)
                    if (activeEdge == 0 && highSince > 0 && (nowT - highSince) > 3.0 &&
                        (nowT - lastEdgeSwitch) > 20.0) {
                        activeEdge = 720;
                        lastEdgeSwitch = nowT;
                        // 升档后 15s 内又降 = 升档失败, 本会话粘滞 720 档
                        if (upgradeAt > 0 && (nowT - upgradeAt) < 15.0) {
                            stickySession = self->_camSessionStart;
                        }
                        self->_videoPlayer.dynamicMaxEdge = 720;
                        NSString *rp = self->_videoPlayer.currentVideoPath;
                        if (rp.length > 0) {
                            LocalVideoPlayer *vp = self->_videoPlayer;
                            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                                [vp loadVideoAtPath:rp completion:nil];
                            });
                        }
                        vcam_core_log([NSString stringWithFormat:@"[vcam] CPU %.0f%% sustained, decode downgraded to 720 (heat guard)", emaPct]);
                    }
                    // 升档: 低压持续 8s 且非粘滞 && 距上次切换 >20s
                    else if (activeEdge == 720 && lowSince > 0 && (nowT - lowSince) > 8.0 &&
                             (nowT - lastEdgeSwitch) > 20.0 && stickySession == 0) {
                        activeEdge = 0;
                        lastEdgeSwitch = nowT;
                        upgradeAt = nowT;
                        self->_videoPlayer.dynamicMaxEdge = 0;
                        NSString *rp = self->_videoPlayer.currentVideoPath;
                        if (rp.length > 0) {
                            LocalVideoPlayer *vp = self->_videoPlayer;
                            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                                [vp loadVideoAtPath:rp completion:nil];
                            });
                        }
                        vcam_core_log(@"[vcam] CPU low sustained, decode restored to native (quality)");
                    }
                    }
                }
                // 1.3.75 首采样修复: lastCpuSec==0 时 delta = 进程启动以来全部
                // 累计 CPU 秒 → pct = 累计/0.8s*100 = 天文数字(日志实证 923893%,
                // 11292399%) → EMA 被毒化 → hardTrip 误触发 SURVIVAL throttle +
                // grace 结束后 EMA 长期 >62 不退出 → 内容被压 20fps 十几秒 =
                // "视频播放后卡顿掉帧"直接来源。修: 首采样只建基线不算 pct;
                // 另 pct>400 视为采样异常(单进程真实上限 ~200-300%)丢弃不更新
                // EMA(下轮重算), 只推进时间基线。
                if (lastCpuSec > 0 && lastCpuSample > 0 && nowT > lastCpuSample && delta >= 0) {
                    double pct = delta / (nowT - lastCpuSample) * 100.0;
                    if (pct < 400.0) {
                    emaPct = emaInit ? (emaPct * 0.5 + pct * 0.5) : pct;  // 0.6/0.4→0.5/0.5 更灵敏
                    emaInit = YES;
                    }
                    // 进入快(2s)/退出 hold 5s(1.3.36 卡顿修复): 旧 10s 保持期让
                    // 短活跃窗口(切模式/速览, 实测 8s)整窗被压 20fps 从未退出;
                    // 退出后重进由 1.3.88 持续确认(8s)天然冷却防横跳
                    BOOL minHoldOk = (nowT - lastModeSwitch) > (lowPower ? 5.0 : 2.0);
                    // 会话豁免(2026-08-20 首开卡顿修复): 相机会话起点(render 心跳
                    // 中断>2s 后恢复 = 热进程首开/空闲重开/切App)后 8s 内, EMA>72
                    // 不进降载 —— 相机启动风暴(管线init+媒体重载+预填+各流首帧建槽)
                    // 是一次性成本, 压内容帧率对 CPU 峰值帮助有限, 却让用户看到
                    // "开头掉帧卡顿"(24fps 压 20fps 每秒丢4帧)再熬保持期才退出
                    // = "过一段时间才稳定流畅"。8s 后闭环正常接管(持续真过载仍会降载)
                    BOOL sessionExempt = (self->_camSessionStart > 0 &&
                                          (nowT - self->_camSessionStart) < 8.0);
                    // 1.3.88 两级硬闸(振荡根治): 设备实证(2026-08-30) EMA 110-119%
                    // 连续 5 分钟零 kill(195% 冷启动风暴才是秒杀区) —— 旧"单拍
                    // 越线立即压"被瞬态尖峰(重载突发/残留噪声)反复拉闸, 5 分钟
                    // 11 次 ON/OFF = 24↔20fps 周期横跳 = "一段时间后卡顿掉帧
                    // 不稳定"直接来源。两级: >170%(逼近 2 核, 实证秒杀区)立即压;
                    // 110-170 需连续越线 ≥8s 才压(瞬态尖峰自动免疫, 真持续过载
                    // 180s 配额红线仍兜底)。EMA 回到 110 以下即重置计时;
                    // 豁免期(sessionExempt)只认 170 立即线, 风暴豁免语义不变。
                    // 退出线 62 不变(hardTrip 压下 CPU 后自然退出)
                    if (emaPct > 110.0) { if (hardHighSince == 0) hardHighSince = nowT; }
                    else hardHighSince = 0;
                    BOOL hardTrip = (emaPct > 170.0)
                        || (!sessionExempt && hardHighSince > 0 && (nowT - hardHighSince) >= 8.0);
                    if (hardTrip && !lowPower) {
                        lowPower = YES;
                        lastModeSwitch = nowT;
                        vcam_core_log([NSString stringWithFormat:@"[vcam] CPU %.0f%% (ema) hardTrip, SURVIVAL throttle ON", emaPct]);
                    } else if (emaPct < 62.0 && lowPower && minHoldOk && !graceOn) {
                        lowPower = NO;
                        lastModeSwitch = nowT;
                        vcam_core_log([NSString stringWithFormat:@"[vcam] CPU %.0f%% (ema) <62%%, throttle OFF", emaPct]);
                    }
                }
            // 1.3.88: 单调采样下有效样本直接刷新双基线(差分恒 ≥0, 负差分分支
            // 随 task_threads 实现移除); 采样失败(cpuSec<0)双基线原地不动,
            // 下轮用原窗口重算
            if (cpuSec >= 0) {
                lastCpuSample = nowT;
                lastCpuSec = cpuSec;
            }
            lastCpuCheck = nowT;
            self.lowPowerDecode = lowPower;  // 解码/预渲染同步降速
        }
        // 按流尺寸的内容更新节流(2026-08-16 吞吐量治理 v2):
        // 物理约束: 多流全速替换像素吞吐 22GB/30s >> daemon CPU 配额(实测 CPU 51-157%,
        // mediaserverd 照片场景 30s 被杀 3 次 = 拍照黑屏崩溃)。
        // v1 教训: 把照片取景器(2304x1650=3.8MP)节流到 12fps → 用户盯着看的主画面
        // 内容只有 12fps = 肉眼明显卡顿。取景器就是可见流, 不能低于视频内容率!
        // 0.042 可见流强制复用窗撤除(2026-08-17 卡顿修复): 与旧快照整窗同源的
        // 帧粒度采样 bug —— 30fps 流 33.3ms < 42ms 被强制喂旧 token(旧内容),
        // 66.7ms 才放行 → 私有格式两步法流内容实际 15fps。且它本质冗余:
        // 同 gen 重复渲染时 staging token 比较已自动跳过 stage1, CCW90 缓存按
        // gen 自动复用 —— 新内容到达即渲染, 旧内容自动跳过, 无需时间窗。
        // 保留: 仅不可见的拍照编码流(≥10MP, 产物是静态照片, 12MP VT 转换昂贵)
        // 放宽到 1fps; lowPower 紧急档 20fps
        {
            // 卡顿优化(2026-08-19): window==0(普通流: 非 ≥10MP 照片流且非降载档)
            // 时整块跳过 —— 旧实现每帧每流无条件 NSString 分配 + @synchronized
            // 字典读写, 8 流 × 30fps = 每秒数百次分配, 纯诊断路径白付。
            uint64_t px = (uint64_t)targetW * targetH;
            double window = px > 10000000ull ? 1.0
                          : (lowPower ? 0.05 : 0.0);
            if (window > 0.0) {
            static NSMutableDictionary<NSString *, NSDictionary *> *freezeState = nil;
            if (!freezeState) freezeState = [NSMutableDictionary dictionary];
            NSString *fk = [NSString stringWithFormat:@"%zu_%zu_%u", targetW, targetH, (unsigned)origFormat];
            @synchronized(freezeState) {
                NSDictionary *st = freezeState[fk];
                CFAbsoluteTime lastFull = st ? [st[@"t"] doubleValue] : 0;
                uint64_t lastTok = st ? [st[@"tok"] unsignedLongLongValue] : 0;
                if (lastFull > 0 && (nowT - lastFull) < window && lastTok != 0) {
                    gen = lastTok;  // 窗口内: 跳过 stage1 缩放, CCW90 复用缓存
                    // 基准不滑动(2026-08-19 首开冻结根治): 旧版抑制帧把基准推进到
                    // nowT(滑动窗) —— 相机流 30/60fps 帧间隔 16-33ms 恒 < window(50ms)
                    // → 每帧都判"距上一帧 50ms 内" → 永久抑制 → 内容冻结整个降载期
                    // (boot grace 强制 lowPower 10s + 退出保持 10s ≈ 20s, 设备实证
                    // 11:34:21-42 全程冻结, 42s throttle OFF 后才开播; 1.3.0 时代
                    // "先开系统相机暖场才不冻"同根因 —— 暖场消耗掉了 boot grace)。
                    // 固定基准 = 全渲染每 window 一次, 内容率 1/window(20fps)。
                    // 抑制帧不写字典(零分配): 状态未变, 无需更新。
                } else {
                    freezeState[fk] = @{@"t": @(nowT), @"tok": @(gen)};
                }
            }
            }  // window > 0.0
        }
    }

    // 诊断: 降频至每 600 帧(30fps 相机流 ~20s 一条, disk writes 限额保护)
    static int vcamRenderCount = 0;
    vcamRenderCount++;
    BOOL diagThisFrame = (vcamRenderCount % 600 == 1);

    // 注: 曾尝试渲染缓存(gen 相同则 memcpy 上次输出, 省 VT 转换) —— 已移除:
    // 相机帧是 IOSurface-backed(GPU/ISP 并发持有), VT 内部有同步而裸 memcpy 没有,
    // 周期性撞数据竞争窗口导致 mediaserverd 崩溃(相机闪退)。写入相机帧一律走 VT。
    // 注2: 预渲染不再预产 BGRA(懒加载, 产能优化), BGRA 回退时现场转换。

    // ===== 渲染主体全局串行化(2026-08-24 视频模式黑屏/崩溃循环根治) =====
    // 根因(设备实证 6 次 malloc abort + 4 次 backboardd IOFence): CMCapture 多流
    // (预览/视频/照片)在不同 Apple 队列线程并发回调 hook → renderReplacement
    // 并发执行(2026-08-15 的 per-key 并行锁体系) → GPUImageProcessor 共享
    // NSMutableDictionary(_twoStepStagingPool/_twoStepTokenPool/_twoStepFailCountPool/
    // _twoStepDisabledPool)在并行 keyLock 段内被并发 mutate(NSMutableDictionary
    // 非线程安全, 不同 key 的并发写同样损坏内部哈希表) → 堆元数据损坏 → 任意线程
    // malloc abort(崩溃栈: convertFormat 的 VT 内部 malloc, 爆发点非损坏点);
    // 多 per-key VT session 并发提交 → GPU IOFence 互等 → backboardd
    // "blocked by IOFence" 崩溃 → mediaserverd 重启循环 = 视频模式持续黑屏。
    // 视频模式是触发窗口: 流多(3-4 条)且含失败流(p200 -12905 熔断), 失败/熔断
    // 路径每帧 mutate 字典, 并发窗口全开; 拍照模式流少且组合全支持, 极少触发。
    // 修复: 渲染主体回到全局 _renderLock 串行(当年弃全局锁是因 CI 软渲 12MP 照片
    // 帧 ~100ms 冻结预览; 现 CI 路径已废弃, VT 12MP ~17ms, 多流排队代价 <25ms,
    // 低于 41ms 帧预算, 无冻结感)。锁序单向无倒置: _renderLock →
    // (_rotationRenderLock / @synchronized(self) → keyLock → poolDictLock)。
    // 内层原有三处 _renderLock(无帧回退读/懒 BGRA/回退帧缓存)随外层持有一并移除
    // (NSLock 不可重入, 保留会自死锁)。
    [_renderLock lock];

    if (!yuv) {
        // 无帧回退(对齐千面 0xb018-0xb05c): 用上一帧缓存填充, 视频解码间隙不闪回相机画面。
        // 不再要求尺寸匹配 —— VT transfer 本身支持任意尺寸 crop fill,
        // 尺寸不匹配时跳过会导致间隙闪现真实相机画面(不稳定感)
        if (diagThisFrame) vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d NO frame, fallback", vcamRenderCount]);
        CVPixelBufferRef fb = _fallbackFrame;
        if (fb) CVPixelBufferRetain(fb);
        if (fb) {
            [_gpuProcessor transferPixelBuffer:fb toPixelBuffer:pixelBuffer];  // 内部自带格式锁
            CVPixelBufferRelease(fb);
        }
        [_renderLock unlock];
        return;
    }

    // 2. 选源(对齐千面架构: 解码原生 420f 单一源 —— readNextFrame 0xe0e4 直接把
    //    AVAssetReader 解码帧给 setReplacementPixelBuffer, 无 BGRA 中转)。
    //    YUV(420f) 源携带原生 range/矩阵 attachments: YUV→私有格式(-8f0/p420/|xv0)
    //    range 保持正确; BGRA 源转私有格式 VT 缺 range 信息 → 照片过曝(高光洗白)。
    //    420f→某私有格式若 VT 不支持(-12905), 下方自动回退 BGRA 源重试
    CVPixelBufferRef base = yuv;

    // 3. 自适应旋转(对齐千面 render_disas 0xaf7c-0xafe4): 源/目标宽高比正交(一横一竖)时
    // CCW90 旋转(宽高互换), 预览流(竖向 buffer)与拍照/录像流(横向 buffer)各自正确方向,
    // 否则拍照保存画面横躺(翻转根因)。方法内部自带 rotationRenderLock。
    // token=gen: 同一帧被相机多条流渲染时 CCW90 只做一次, 后续流直接复用缓存(每流省 ~2-4ms)
    CVPixelBufferRef src = [_gpuProcessor adaptiveRotateIfNeeded:base targetWidth:targetW targetHeight:targetH token:gen];

    // 4. 写入相机帧: VT transfer(Trim 保比例 crop fill)主路径。
    //    全格式处理无白名单(对齐千面 0xb0f8-0xb154: 私有格式 |8v0/-8f0/p420 也 transfer,
    //    这正是千面能替换视频模式预览和拍照保存的原因), 失败保留原相机帧
    BOOL usedFallbackSource = NO;
    BOOL ok = [self writeFrame:src toPixelBuffer:pixelBuffer token:gen];
    if (!ok && base == yuv) {
        // YUV 源失败(该 420f→目标组合 VT 不支持): 懒转 BGRA 回退(预渲染已不预产 BGRA,
        // 罕见路径现场转换一次, 正常帧不付这个代价)
        // (外层已持 _renderLock, 原 inner lock 已移除 —— NSLock 不可重入)
        if (src) CVPixelBufferRelease(src);
        src = NULL;
        CVPixelBufferRef lazyBGRA = [_gpuProcessor convertFormat:yuv toFormat:kCVPixelFormatType_32BGRA];
        if (lazyBGRA) {
            src = [_gpuProcessor adaptiveRotateIfNeeded:lazyBGRA targetWidth:targetW targetHeight:targetH token:0];
            CVPixelBufferRelease(lazyBGRA);
        }
        ok = [self writeFrame:src toPixelBuffer:pixelBuffer token:0];  // 0 = 不复用 staging
        usedFallbackSource = ok;
        if (ok && diagThisFrame) {
            vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d YUV->0x%x failed, retry via lazy BGRA OK", vcamRenderCount, (unsigned)origFormat]);
        }
    }
    if (ok) {
        _frameCount++;
        if (diagThisFrame) {
            vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d OK %zux%zu fmt=0x%x via %@%@",
                           vcamRenderCount, targetW, targetH, (unsigned)origFormat,
                           usedFallbackSource ? @"BGRA(fb)" : @"YUV",
                           (src != base && !usedFallbackSource) ? @" +CCW90" : @""]);
        }
        // 缓存回退帧(千面缓存旋转后的实际 transfer 源 x24, 0xb15c-0xb19c) + 同帧去重
        // (外层已持 _renderLock)
        if (_fallbackFrame) CVPixelBufferRelease(_fallbackFrame);
        _fallbackFrame = src;
        CVPixelBufferRetain(_fallbackFrame);
        _fallbackWidth = targetW;
        _fallbackHeight = targetH;
        _dedupLastBuffer = pixelBuffer;
        _dedupLastTime = CFAbsoluteTimeGetCurrent();
    } else if (diagThisFrame) {
        vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d FAILED write fmt=0x%x, keep camera", vcamRenderCount, (unsigned)origFormat]);
    }

    if (src) CVPixelBufferRelease(src);
    if (bgra) CVPixelBufferRelease(bgra);
    if (yuv) CVPixelBufferRelease(yuv);
    [_renderLock unlock];
}

- (BOOL)hasReplacementFrame {
    // 1.3.55 未激活 = 无替换帧(拍照流也走真实相机); 与 render 入口组合不同,
    // 单点补丁跳不过两处
    if (!_enabled || !_licGate || !_licMark) return NO;
    CVPixelBufferRef frame = [_videoPlayer getCurrentFrame];
    return frame != NULL;
}

- (void)clearReplacementFrame {
    [self stopPrerenderThread];
    [_processLock lock];
    // 显示同步快照清理(2026-08-16 叠影修复配套)
    if (_syncDisplayFrame) {
        CVPixelBufferRelease(_syncDisplayFrame);
        _syncDisplayFrame = NULL;
    }
    _syncDisplayGen = 0;
    _lastGenAdvanceTime = 0;
    if (_liveBGRAPixelBuffer) {
        CVPixelBufferRelease(_liveBGRAPixelBuffer);
        _liveBGRAPixelBuffer = NULL;
    }
    if (_liveYUVPixelBuffer) {
        CVPixelBufferRelease(_liveYUVPixelBuffer);
        _liveYUVPixelBuffer = NULL;
    }
    if (_cachedProcessedFrame) {
        CVPixelBufferRelease(_cachedProcessedFrame);
        _cachedProcessedFrame = NULL;
    }
    _lastProcessedFrameCount = 0;
    _lastProcessedWidth = 0;
    _lastProcessedHeight = 0;
    _lastProcessedFormat = 0;
    _targetSizeKnown = NO;
    _targetWidth = 0;
    _targetHeight = 0;
    _targetFormat = 0;
    [_processLock unlock];
    // 清理回退缓存 + 去重指针
    [_renderLock lock];
    if (_fallbackFrame) {
        CVPixelBufferRelease(_fallbackFrame);
        _fallbackFrame = NULL;
    }
    _fallbackWidth = 0;
    _fallbackHeight = 0;
    _dedupLastBuffer = NULL;
    _dedupLastTime = 0;
    _dedupLastPts = 0;
    _lastAdvancePts = 0;
    [_renderLock unlock];
    vcam_core_log(@"[vcam] Replacement frame cleared, real camera restored");
}

- (void)cacheLastRenderedFrame:(CVPixelBufferRef)buffer width:(size_t)width height:(size_t)height {
    if (!buffer) return;
    OSType format = CVPixelBufferGetPixelFormatType(buffer);

    [_processLock lock];
    if (format == kCVPixelFormatType_32BGRA) {
        if (_liveBGRAPixelBuffer) {
            CVPixelBufferRelease(_liveBGRAPixelBuffer);
        }
        _liveBGRAPixelBuffer = buffer;
        CVPixelBufferRetain(_liveBGRAPixelBuffer);
    } else {
        if (_liveYUVPixelBuffer) {
            CVPixelBufferRelease(_liveYUVPixelBuffer);
        }
        _liveYUVPixelBuffer = buffer;
        CVPixelBufferRetain(_liveYUVPixelBuffer);
    }
    _lastRenderedWidth = width;
    _lastRenderedHeight = height;
    [_processLock unlock];
}

// 私有格式判断(选转换源用): 私有目标优先用 BGRA 源(实测 BGRA->私有格式 VT 成功率高)
// 注意: 千面 render 无白名单, 所有格式都 transfer —— 此方法仅用于选源, 不过滤
- (BOOL)isPrivateFormat:(OSType)format {
    return !(format == kCVPixelFormatType_32BGRA || format == '420v' || format == '420f');
}

// 像素级诊断: dump buffer 的颜色 attachments + 亮度采样(量化单次转换的提亮效应)
// 采样中心十字 5 点: Y 平面(YUV) 或 G 通道(BGRA), 附 attachments 全字典
- (void)dumpBufferDiagnostics:(CVPixelBufferRef)buf label:(NSString *)label {
    if (!buf) return;
    OSType fmt = CVPixelBufferGetPixelFormatType(buf);
    size_t w = CVPixelBufferGetWidth(buf);
    size_t h = CVPixelBufferGetHeight(buf);

    CVPixelBufferLockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
    NSMutableArray *samples = [NSMutableArray array];
    if (CVPixelBufferGetPlaneCount(buf) >= 1) {
        // YUV: 采样 plane0(Y) 中心十字
        uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(buf, 0);
        size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 0);
        if (base) {
            size_t cx = w / 2, cy = h / 2;
            size_t xs[] = {cx, cx / 2, cx + cx / 2, cx, cx};
            size_t ys[] = {cy, cy, cy, cy / 2, cy + cy / 2};
            for (int i = 0; i < 5; i++) {
                if (xs[i] < w && ys[i] < h) {
                    [samples addObject:@(base[ys[i] * bpr + xs[i]])];
                }
            }
        }
    } else {
        // BGRA: 采样 G 通道(Offset+1)
        uint8_t *base = CVPixelBufferGetBaseAddress(buf);
        size_t bpr = CVPixelBufferGetBytesPerRow(buf);
        if (base) {
            size_t cx = w / 2, cy = h / 2;
            size_t xs[] = {cx, cx / 2, cx + cx / 2, cx, cx};
            size_t ys[] = {cy, cy, cy, cy / 2, cy + cy / 2};
            for (int i = 0; i < 5; i++) {
                if (xs[i] < w && ys[i] < h) {
                    [samples addObject:@(base[ys[i] * bpr + xs[i] * 4 + 1])];
                }
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);

    NSDictionary *atts = CFBridgingRelease(CVBufferCopyAttachments(buf, kCVAttachmentMode_ShouldPropagate));
    vcam_core_log([NSString stringWithFormat:@"[vcam][pix] %@ %zux%zu fmt=0x%x Y/G=%@ atts=%@",
                   label, w, h, (unsigned)fmt, samples, atts ?: @"(nil)"]);
}

#pragma mark - 帧写入

// 对齐逆向: VT transfer(Trim 保比例 crop fill 缩放+格式转换) 主路径
// 失败回退 CoreImage crop fill(仅标准格式), 再失败保留原相机帧(绝不输出未初始化 buffer 防绿屏)
// token: 该 src 帧的代数(私有格式两步法 staging 复用判断用)。传 0 = 永不复用(安全)。
// 在 renderLock 内设置到 GPU —— 多 hook 线程并发 render 时各自携带自己的 token,
// 避免 lock 外全局赋值被其他线程覆盖导致 staging 误用别帧内容
- (BOOL)writeFrame:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst token:(uint64_t)token {
    if (!src || !dst) return NO;

    static int vcamWriteCount = 0;
    vcamWriteCount++;
    BOOL diag = (vcamWriteCount % 900 == 1);
    if (diag) {
        vcam_core_log([NSString stringWithFormat:@"[vcam] write#%d VT begin %zux%zu(0x%x) -> %zux%zu(0x%x)",
                       vcamWriteCount,
                       CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), (unsigned)CVPixelBufferGetPixelFormatType(src),
                       CVPixelBufferGetWidth(dst), CVPixelBufferGetHeight(dst), (unsigned)CVPixelBufferGetPixelFormatType(dst)]);
    }

    // 并行锁体系(2026-08-15): 不再用全局 renderLock —— 拍照流(4032x3024 大帧 ~100ms)
    // 持全局锁会阻塞所有预览流(拍照瞬间预览冻结/黑屏)。锁下沉到 GPU 内部:
    //   一步 transfer 按目标格式 3 把锁(异格式流并行), 两步法 per-key 锁(异尺寸流并行),
    //   rotation/CI 回退内部自锁。token 经参数传递(线程安全, 不写全局属性)
    BOOL done = NO;

    // 路径1: VTPixelTransferSession（任意尺寸+格式组合, CropSourceToCleanAperture 自动 crop fill）
    // 对齐千面(0xb0f8-0xb158): VT 是唯一路径, 失败直接保留相机帧 —— 千面无 CI 回退。
    // (CI 软件渲染 12MP 照片帧需数秒且持 rotationRenderLock, 会饿死全部预览流的
    //  自适应旋转 → 相机管线线程卡死 → mediaserverd watchdog 60s kill, 拍照黑屏根因)
    @try {
        if ([_gpuProcessor transferPixelBuffer:src toPixelBuffer:dst token:token]) {
            if (diag) {
                vcam_core_log([NSString stringWithFormat:@"[vcam] write#%d VT ok", vcamWriteCount]);
            }
            done = YES;
        }
    } @catch (NSException *e) {
        vcam_core_log([NSString stringWithFormat:@"[vcam] write#%d VT exception: %@", vcamWriteCount, e]);
    }

    return done ? YES : NO;
}

#pragma mark - 预渲染线程

// 对齐逆向: 只产出视频原尺寸(旋转后互换)的 BGRA + 420f 双格式缓存
// render 时由 VTPixelTransferSession(CropSourceToCleanAperture) 一步完成 crop fill 缩放+格式转换
// (不再按相机帧格式做多尺寸缩放 —— 那会导致比例失真/性能差/未初始化 buffer 绿闪)
- (void)startPrerenderThread {
    if (_prerenderActive) return;
    _prerenderActive = YES;
    vcam_core_log(@"[vcam] Prerender thread started (native-size dual-format)");
    __weak typeof(self) weakSelf = self;
    dispatch_async(_prerenderQueue, ^{
        VCamCore *strongSelf = weakSelf;
        if (!strongSelf) return;

        // 绝对时间节拍器: 累计节拍(nextTick += interval), 消除 sleep 精度导致的累计漂移(卡顿/跳帧)
        CFAbsoluteTime nextTick = CFAbsoluteTimeGetCurrent();
        uint64_t renderedFrames = 0;
        static uint64_t prerenderLogSeq = 0;

        while (strongSelf.prerenderActive && strongSelf.enabled) {
            @autoreleasepool {
                // 空闲门控(2026-08-16 发热优化): 相机无流(render 心跳 >2s 无刷新) →
                // 整条预渲染睡眠等待, 不取帧不转换; render 被调时清 pipelineIdle 自动恢复
                if (strongSelf.pipelineIdle) {
                    [NSThread sleepForTimeInterval:0.1];
                    nextTick = CFAbsoluteTimeGetCurrent();
                    continue;
                }

                // effectiveFps = PTS 实测帧率(校准 nominalFrameRate 低估导致的节拍慢放)
                // 1.3.47 帧率稳定硬约束(用户要求: 替换视频永不掉帧):
                // 移除 20fps 降载上限 —— 预渲染按源帧率产出, 内容帧率永不打折;
                // CPU 治理由 render 端 staging 去重(同 gen 跳过) + 不可见流节流 +
                // hardTrip 紧急档(render 窗)承担, 不再压解码/预渲染节拍
                double fps = strongSelf.videoPlayer.effectiveFps;
                nextTick += 1.0 / fps;
                double wait = nextTick - CFAbsoluteTimeGetCurrent();
                if (wait > 0.0005) {
                    // 1.3.49 打光快速响应: NSThread sleep → 信号量超时等待。
                    // 超时=正常节拍(帧率约束零改动); signal(光色/参数变化时由
                    // light 轮询回调发出) → 立即出拍重产出当前帧(新光斑)。
                    // 早醒拍后 nextTick 逻辑自然自愈, 不丢帧不重帧
                    if (strongSelf->_prerenderWakeSem) {
                        dispatch_semaphore_wait(strongSelf->_prerenderWakeSem,
                            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)));
                    } else {
                        [NSThread sleepForTimeInterval:wait];
                    }
                } else {
                    nextTick = CFAbsoluteTimeGetCurrent();  // 已落后(转换耗时超帧间隔), 重置基线
                }

                // 消费式取帧 + 短等待(2026-08-17 卡顿修复: 双时钟拍频):
                // 解码/预渲染是两个独立 24Hz 时钟, 相位漂移使预渲染拍点周期性
                // 落在解码入队之前 → dequeue 空 → 回退当前帧 = 同一帧重复产出两拍,
                // 下一拍取到积压帧 = 周期性"重复-紧接"节奏(拍频微卡顿)。
                // 修: 队列空时短等(≤1/3 帧间隔)让解码先产出。
                // 图片模式/暂停(解码不再产出)等待自然超时走当前帧回退, 行为不变
                // 1.3.49 早醒拍(光色/参数变化唤醒): 只重产出当前帧, 不消费解码
                // 队列 —— 1:1 FIFO 出帧节律完全不受影响(帧率稳定硬约束),
                // 早醒拍与正常拍唯一差别 = 烘焙了新打光签名的同一源帧
                BOOL earlyWake = strongSelf->_prerenderWakeEarly;
                if (earlyWake) strongSelf->_prerenderWakeEarly = NO;

                CVPixelBufferRef frame = NULL;
                if (!earlyWake) {
                    frame = [strongSelf.videoPlayer.frameQueue dequeuePixelBuffer];
                    if (!frame) {
                        CFAbsoluteTime waitStart = CFAbsoluteTimeGetCurrent();
                        double waitBudget = (1.0 / fps) / 3.0;
                        while (!frame && CFAbsoluteTimeGetCurrent() - waitStart < waitBudget) {
                            [NSThread sleepForTimeInterval:0.002];
                            frame = [strongSelf.videoPlayer.frameQueue dequeuePixelBuffer];
                        }
                    }
                }
                if (frame) {
                    // FIFO + 突发限深(2026-08-20 帧数优化, 取代 drain-to-latest):
                    // 逐帧顺序消费 —— 相位漂移由队列吸收, 每拍 1:1 产出, 稳态零丢帧
                    // 零重复; 仅积压 >1(换源预填 5 帧/解码突发)时丢最旧余量, 延迟
                    // 有界(≤2 帧)。旧 drain-to-latest 把任何 2 帧积压整批丢成最新
                    // 1 帧 + 顺手清空队列 → 下一拍必然回退重复帧 = "跳帧+重复"成对
                    // 卡顿(双时钟拍频残留); FIFO 下 2 帧积压是正常相位缓冲, 不丢。
                    while ([strongSelf.videoPlayer.frameQueue count] > 1) {
                        CVPixelBufferRef excess = [strongSelf.videoPlayer.frameQueue dequeuePixelBuffer];
                        if (excess) CVPixelBufferRelease(excess);
                    }
                }
                if (!frame) {
                    frame = [strongSelf.videoPlayer copyCurrentFrame];
                }
                if (!frame) {
                    continue;
                }

                // 重复源跳过: 无新帧入队(frameCount 未变, 如解码间隙/暂停回退当前帧)且
                // 总旋转(视频自带+用户手动)/镜像/打光未变时, 下一拍已产出相同内容 →
                // 跳过旋转+VT 转换(用解码器单调递增的 frameCount 判断, 不用指针:
                // 解码器会回收复用 buffer 指针)。1.3.37: 打光签名加入判定 —— 暂停状态
                // 下检测颜色跳变/滑块调节也即时重产出(与 pan/zoom 同款处理)
                strongSelf.gpuProcessor.sourceRotation = strongSelf.videoPlayer.preferredRotation;
                int curRot = (strongSelf.gpuProcessor.sourceRotation + strongSelf.gpuProcessor.rotationAngle) % 360;
                BOOL curMirror = strongSelf.gpuProcessor.mirrored;
                double curPanX = strongSelf.gpuProcessor.userPanX;
                double curPanY = strongSelf.gpuProcessor.userPanY;
                double curZoom = strongSelf.gpuProcessor.userZoom;
                uint64_t curLightSig =
                    ((uint64_t)(strongSelf.gpuProcessor.lightEnabled ? 1 : 0) << 59)
                  | ((uint64_t)(strongSelf.gpuProcessor.lightColorRGB & 0xFFFFFF) << 35)
                  | ((uint64_t)(strongSelf.gpuProcessor.lightX & 0x7F) << 28)
                  | ((uint64_t)(strongSelf.gpuProcessor.lightY & 0x7F) << 21)
                  | ((uint64_t)(strongSelf.gpuProcessor.lightIntensity & 0x7F) << 14)
                  | ((uint64_t)(strongSelf.gpuProcessor.lightDiameter & 0x7F) << 7)
                  | (uint64_t)(strongSelf.gpuProcessor.lightFeather & 0x7F);
                uint64_t curCount = strongSelf.videoPlayer.frameCount;
                if (curCount == strongSelf->_lastPrerenderSrcGen &&
                    curRot == strongSelf->_lastPrerenderRot &&
                    curMirror == strongSelf->_lastPrerenderMirror &&
                    curPanX == strongSelf->_lastPrerenderPanX &&
                    curPanY == strongSelf->_lastPrerenderPanY &&
                    curZoom == strongSelf->_lastPrerenderZoom &&
                    curLightSig == strongSelf->_lastPrerenderLightSig) {
                    CVPixelBufferRelease(frame);
                    continue;
                }
                strongSelf->_lastPrerenderSrcGen = curCount;
                strongSelf->_lastPrerenderRot = curRot;
                strongSelf->_lastPrerenderMirror = curMirror;
                strongSelf->_lastPrerenderPanX = curPanX;
                strongSelf->_lastPrerenderPanY = curPanY;
                strongSelf->_lastPrerenderZoom = curZoom;
                strongSelf->_lastPrerenderLightSig = curLightSig;

                // 1. 旋转/镜像（如需要, 视频原尺寸; 解码帧为 420f, 旋转保持 420f）
                CVPixelBufferRef rotated = [strongSelf.gpuProcessor rotateAndMirrorIfNeeded:frame];
                CVPixelBufferRelease(frame);
                if (!rotated) continue;

                // 1.5 三色打光注入(1.3.37, 复刻 Android vcplax; 1.3.51 移到 bake 前):
                // 屏幕取色检测到的颜色以圆形渐变光斑注入【完整内容帧】(内部 3 槽
                // 画布副本, 不污染旋转/bake 池)。关闭/无色时直通零开销; 打光签名
                // 参与上方跳过判定。
                // 1.3.51 光斑锚定内容(用户要求): 旧顺序(bake 后注入)光斑画在"烘焙
                // 后画布"上 —— zoom>1 时画布=可见窗口本身, 光斑%坐标恒钉在窗口上,
                // 放大缩小光斑纹丝不动(钉在屏幕而非内容)。新顺序(bake 前注入):
                // 光斑先画进内容像素(用户在原始大小下调好的位置/直径即内容坐标),
                // 之后 zoom/pan 烘焙裁窗口+下游 Trim 放大 —— 光斑跟着内容一起
                // 放大/移动/裁掉, 等效"光打在视频画面本身上"
                CVPixelBufferRef lit = [strongSelf.gpuProcessor injectLightIntoFrame:rotated];
                CVPixelBufferRelease(rotated);
                if (!lit) continue;
                rotated = lit;

                // 1.6 用户画面变换(箭头/＋/−/复, 画布合成): zoom/pan 烘焙进像素 ——
                // zoom>1 画布=源窗口(memcpy); zoom<=1 黑底+画面区域(平移出界露黑)。
                // 默认无变换时直通零开销。pan/zoom 参与上方跳过判定: 变化时重新
                // 产出 → token 刷新, 暂停状态点箭头也即时生效
                CVPixelBufferRef baked = [strongSelf.gpuProcessor bakeUserTransformIntoCanvas:rotated];
                CVPixelBufferRelease(rotated);
                if (!baked) continue;

                // 2. 懒 BGRA(产能优化): 不再每帧预转 BGRA —— 旋转+转换两个 VT 调用
                //    每帧 ~68ms > 41.6ms(24fps 帧间隔), 预渲染只跑出 14.6fps → 卡顿。
                //    YUV 是 render 主源(千面解码原生单源架构); BGRA 回退需求罕见
                //    (仅 420f→某私有格式 VT 不支持时), 由 render 现场懒转。
                //    只做旋转一个 VT → 预渲染恢复源视频帧率

                // 3. 完整产出后才替换缓存（避免半成品被 render 读到）
                [strongSelf.processLock lock];
                if (strongSelf->_liveYUVPixelBuffer) {
                    CVPixelBufferRelease(strongSelf->_liveYUVPixelBuffer);
                }
                strongSelf->_liveYUVPixelBuffer = baked;  // 所有权转移(画布合成结果)
                strongSelf->_liveFrameGen++;  // render 端 staging 复用的帧代数
                [strongSelf.processLock unlock];

                renderedFrames++;
                if (renderedFrames % 600 == 1) {
                    prerenderLogSeq++;
                    vcam_core_log([NSString stringWithFormat:@"[vcam] prerender #%llu frames ok fps=%.1f", (unsigned long long)renderedFrames, fps]);
                }
            }
        }
        vcam_core_log(@"[vcam] Prerender thread exited");
    });
}

- (void)stopPrerenderThread {
    _prerenderActive = NO;
    vcam_core_log(@"[vcam] Prerender thread stopped");
}

#pragma mark - 状态控制

- (void)setEnabled:(BOOL)enabled {
    // SpringBoard 进程守卫: SB 不解码视频(替换渲染在 mediaserverd), 只记录状态。
    // 否则 SB 会启动解码线程+预渲染线程白白解码整个视频 → 桌面卡顿/悬浮窗按钮迟钝
    if (!_isMediaserverdProcess) {
        _enabled = enabled;
        return;
    }

    [_processLock lock];
    if (_enabled == enabled) {
        // enable→enable (no reload) / disable→disable (no action)
        [_processLock unlock];
        return;
    }
    [_processLock unlock];

    if (enabled) {
        // disable→enable: 加载视频
        NSString *path = [VCamNotify activePlaybackPath];
        if (!path || path.length == 0) {
            path = @"/var/mobile/Media/DCIM/vcam.mp4";
        }
        vcam_core_log([NSString stringWithFormat:@"[vcam] readActivePlaybackPath -> %@", path]);

        // 异步加载: loadVideoFile 含同步轨道解析 + 预解码 5 帧(50-150ms+),
        // 在 0.15s 节拍的轮询线程上同步执行会积压队列 → XPC watchdog 超时 →
        // mediaserverd 被杀(相机黑屏/闪退)。串行 processingQueue 天然合并连点请求
        __weak typeof(self) weakSelf = self;
        dispatch_async(_processingQueue, ^{
            VCamCore *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf->_videoPlayer loadVideoAtPath:path completion:^(BOOL success, NSError *error) {
                if (success) {
                    vcam_core_log(@"[vcam] Video loaded OK (async)");
                    [[VCamNotify sharedInstance] postNotification:VCamNotifyLiveChanged];
                } else {
                    vcam_core_log([NSString stringWithFormat:@"[vcam] Failed to load video: %@", error]);
                }
            }];
            [strongSelf->_videoPlayer startWatchingFile:path];
        });

        [_processLock lock];
        _enabled = YES;
        [_processLock unlock];

        // 空闲门控基线(2026-08-16 发热优化): enable 后给 2s 心跳宽限, 期间预渲染正常跑
        // (相机若已开着, render 心跳会持续刷新, 永不进入空闲)
        _pipelineIdle = NO;
        _lastRenderActivity = CFAbsoluteTimeGetCurrent();

        // 必须在 _enabled=YES 之后启动（否则预渲染 while(enabled) 读到 NO 立即退出, 之后永远不替换）
        [self startPrerenderThread];
        vcam_core_log(@"[vcam] Live state changed to: enabled");
    } else {
        // enable→disable: 停止解码/预渲染, 但保留帧缓存(_liveYUV/_fallback)。
        // _enabled=NO 时 render 直接 return → 相机真实画面自然恢复, 语义不变;
        // 而下次 enable 时异步加载视频需要 0.5~4s(轨道解析+预解码), 期间
        // render NO frame → 若缓存被清则黑屏。保留缓存 → 冻结上一帧画面平滑过渡
        [self stopPrerenderThread];
        [_videoPlayer stopDecodingThread];
        [_videoPlayer stopWatchingFile];

        [_processLock lock];
        _enabled = NO;
        [_processLock unlock];
        _pipelineIdle = NO;  // 门控状态复位, 下次 enable 从正常态启动
        vcam_core_log(@"[vcam] Live state changed to: disabled (frame cache kept)");
        [[VCamNotify sharedInstance] postNotification:VCamNotifyLiveChanged];
    }
}

#pragma mark - plist 轮询

- (void)startStatePolling {
    if (_pollingActive) return;
    _pollingActive = YES;
    vcam_core_log(@"[vcam] State polling timer started");

    __weak typeof(self) weakSelf = self;
    // 0.15s 主轮询: 悬浮球按钮(转/镜/播/切源)生效延迟降到最长 0.15s(平均 75ms),
    // 单次 plist 读取 ~0.1ms 开销可忽略, 读取在后台 notify 队列不占主线程
    // (打光 7 键 1.3.45 起拆到下方 0.04s 快速轮询 —— 跟随屏幕闪烁)
    [[VCamNotify sharedInstance] startPollingWithInterval:0.15 callback:^(BOOL enabled) {
        VCamCore *strongSelf = weakSelf;
        if (!strongSelf) return;
        // poll 心跳日志已移除(2026-08-16): mediaserverd disk writes 限额 12.43KB/s,
        // 高频日志按 4KB 脏页/行记账 → EXC_RESOURCE 杀进程(崩溃循环根因)
        // 密钥门禁(1.3.55): 每拍重算双变量 —— licGate = ECDSA 验签(VCamNotify,
        // 内部 0.5s 节流, plist 读 + 验签走轮询线程不碰渲染); licMark = 跨进程
        // 设备码互证(dcPub) + 自身 IMP 范围自检(防 swizzle)。
        // effEnabled = plist enabled && licGate && licMark —— 未激活时把 md 侧
        // 管线一并停掉(省 CPU); 激活写入后 0.15s 内自动拉起。
        // lastEnabledState 记忆的是 effEnabled, 故 license 无效→有效的翻转也走
        // setEnabled 重新加载, 无需额外通知链路; 内存强翻 BOOL 会在下一拍纠正
        strongSelf->_licGate = [VCamNotify vcamLicenseValid];
        // 1.3.70: licMark 加入 __TEXT 哈希自校验(改 dylib 任何字节 → 关门禁)
        // 1.3.78: 串入 vcamNoLateHookLibs(快照后新出现的 hook 框架 → 关门禁)。
        // 放链首: && 短路会让排后面的检查在前面失败时被跳过 —— 反注入快照
        // 必须每拍都建立/扫描(破解者故意让互证失败以跳过反注入扫描的路径封死)
        strongSelf->_licMark = vcamNoLateHookLibs() && [VCamNotify vcamCrossDeviceCodeOK]
            && vcamSelfIntegrityOK() && vcamSelfTextOK();
        // 1.3.64: 许可有效首拍预热 T 表(方案A 参数解密) —— 内部 dispatch_once
        // 记 T diag 日志(m=3fa7c2e1 ok=1), 无需打开相机/打光即可远程确认
        // 设备端解密链路。1.3.78: vcamLicenseTable 已改为栈式解码(明文不驻
        // 留), 预热改走 vcamLicenseTableInt(0=校验+擦除路径, 诊断语义不变)
        static dispatch_once_t tWarmOnce;
        if (strongSelf->_licGate) {
            dispatch_once(&tWarmOnce, ^{
                (void)[VCamNotify vcamLicenseTableInt:0];
            });
        }
        BOOL effEnabled = enabled && strongSelf->_licGate && strongSelf->_licMark;
        if (effEnabled != strongSelf.lastEnabledState) {
            vcam_core_log([NSString stringWithFormat:@"[vcam] state change: %d -> %d (lic=%d mk=%d), calling setEnabled", strongSelf.lastEnabledState, effEnabled, strongSelf->_licGate, strongSelf->_licMark]);
            strongSelf.lastEnabledState = effEnabled;
            [strongSelf setEnabled:effEnabled];
        }

        // 1.3.61 门禁诊断(10s 节流): effEnabled=0 时报各闸值 —— en=plist
        // 开关, lic=ECDSA 验签, mk=互证+自检; cr/si 为 mk 两分量, md 标进程。
        // SB 与 md 两进程都跑本回调, 行量 12 行/min 可忽略
        static double lastGateDiagAt = 0;
        if (!effEnabled && (CFAbsoluteTimeGetCurrent() - lastGateDiagAt) > 10.0) {
            lastGateDiagAt = CFAbsoluteTimeGetCurrent();
            vcam_core_log([NSString stringWithFormat:
                @"[vcam] gate diag en=%d lic=%d mk=%d cr=%d si=%d ts=%d md=%d",
                enabled, strongSelf->_licGate, strongSelf->_licMark,
                [VCamNotify vcamCrossDeviceCodeOK], vcamSelfIntegrityOK(),
                vcamSelfTextOK(), strongSelf.isMediaserverdProcess]);
        }

        // 空闲看门狗分级(2026-08-19 首开冻结根治): 替换开着但相机流心跳 >2s 未刷新
        // (相机关闭/切后台/非相机 App) → 暂停解码+预渲染, CPU 归零;
        // 相机重新打开时 render 同步清 pipelineIdle 即时恢复。
        // 旧版缺陷(设备实证 11:08-11:11 日志): 2s 即全量卸载媒体管线, 而扫码页
        // 相机流周期性静默/重建(5-10s 周期) → "卸载→重载"抖动循环, 每轮重载期间
        // render 只能显示冻结快照 1-14s(loadVideo+rebuild+prefill), 用户看到
        // "首开画面被替换但卡住, 等一段时间才开始播放"。
        // 新分级: 2s 只暂停(不动 reader/帧队列, 恢复=置标志零延迟); 60s 真长期
        // 空闲(锁屏/退出相机)才卸载媒体管线+GPU 池。
        if (strongSelf.isMediaserverdProcess && strongSelf.enabled && !strongSelf.pipelineIdle &&
            strongSelf->_lastRenderActivity > 0 &&
            (CFAbsoluteTimeGetCurrent() - strongSelf->_lastRenderActivity) > 2.0 &&
            (CFAbsoluteTimeGetCurrent() - strongSelf->_lastIdleResumeTime) > 5.0) {  // 恢复保持: 恢复后 5s 内不重复暂停
            strongSelf->_pipelineIdle = YES;
            [strongSelf->_videoPlayer stopDecodingThread];
            vcam_core_log(@"[vcam] camera idle >2s, pipeline paused (CPU zero, reader kept)");
        }

        // 深度空闲卸载(60s, jetsam guard): 真长期空闲才释放媒体管线+GPU 池。
        // 2026-08-18 云闪付崩溃循环根因: 部分扫码 App 相机流不经过 hook 节点,
        // mediaserverd 被系统判 inactive, dylib 已初始化的 footprint 124MB >
        // inactive jetsam 硬限 75MB → 5-6s 击杀。卸载 reader/帧队列/living 帧链/
        // GPU 池压回线下; asset/track 复用链保留(LocalVideoPlayer 内部), 恢复
        // 重载跳过 tracksWithMediaType, rebuild <100ms。
        // 60s 窗口(2026-08-18): 扫码页相机流 5-10s 周期静默在 2s 暂停层已被
        // 零成本吸收, 不会到达这里; 只有锁屏/退出相机才触发。
        if (strongSelf.isMediaserverdProcess && strongSelf.enabled && strongSelf.pipelineIdle &&
            strongSelf->_lastRenderActivity > 0 &&
            (CFAbsoluteTimeGetCurrent() - strongSelf->_lastRenderActivity) > 60.0) {
            static CFAbsoluteTime lastIdleRelease = 0;
            CFAbsoluteTime nowIdle = CFAbsoluteTimeGetCurrent();
            // 释放一次后不再重复(资源已空); render 心跳恢复后再空闲才会重新进入
            if (nowIdle - lastIdleRelease > 30.0) {
                lastIdleRelease = nowIdle;
                if (!strongSelf->_idleUnloaded) {
                    strongSelf->_idleUnloaded = YES;
                    strongSelf->_idleResumePath = [strongSelf->_videoPlayer currentVideoPath];
                    [strongSelf->_videoPlayer unloadForIdle];
                    [strongSelf->_gpuProcessor releaseHeavyBuffersForIdle];
                    [strongSelf->_gpuProcessor releaseIdleMemory];
                    // live 帧链也释放(砍常驻内存): 预渲染线程已因 pipelineIdle
                    // 睡眠不再产出, _syncDisplayFrame 快照独立 retain 旧内容, 恢复期间
                    // render 冻结显示快照, 重载完成后无缝跟上。
                    // 持 _processLock 与 render 线程互斥(该字段 render 侧同锁访问)
                    [strongSelf->_processLock lock];
                    if (strongSelf->_liveYUVPixelBuffer) {
                        CVPixelBufferRelease(strongSelf->_liveYUVPixelBuffer);
                        strongSelf->_liveYUVPixelBuffer = NULL;
                    }
                    if (strongSelf->_liveBGRAPixelBuffer) {
                        CVPixelBufferRelease(strongSelf->_liveBGRAPixelBuffer);
                        strongSelf->_liveBGRAPixelBuffer = NULL;
                    }
                    if (strongSelf->_cachedProcessedFrame) {
                        CVPixelBufferRelease(strongSelf->_cachedProcessedFrame);
                        strongSelf->_cachedProcessedFrame = NULL;
                    }
                    [strongSelf->_processLock unlock];
                    vcam_core_log(@"[vcam] camera idle >60s, media pipeline + GPU pools released (jetsam guard)");
                } else {
                    [strongSelf->_gpuProcessor releaseIdleMemory];
                    vcam_core_log(@"[vcam] camera idle >60s, GPU stream pools released (jetsam guard)");
                }
            }
        }

        // 资源探针(2026-08-16 黑屏取证 v2): 每 30s 一行内存/CPU%/按流渲染统计
        // 修复(2026-08-16): takeStreamStats 是"取出并清零"语义, 之前每 0.15s 轮询调用
        // → 统计被高频清零, telemetry 里只剩最后 0.15s 的数据(9 vs 实际 1376)。
        // 节流到 30s 窗口到点才取, 统计恢复真实
        if (strongSelf.isMediaserverdProcess) {
            static CFAbsoluteTime lastStatsTake = 0;
            CFAbsoluteTime nowStats = CFAbsoluteTimeGetCurrent();
            if (nowStats - lastStatsTake >= 30.0) {
                lastStatsTake = nowStats;
                vcam_telemetry_sample(strongSelf->_frameCount,
                                      [strongSelf->_gpuProcessor takeStreamStats]);
            }
        }

        // 旋转/镜像跨进程同步: 悬浮球(SpringBoard)写 vc.plist, mediaserverd 轮询应用
        // (对齐千面 vc.plist manualRotation 字段; rotationAngle!=0 时 render 不做自适应旋转)
        // 性能: 一次读 plist 提取全部控制字段(原来 5 个字段各读一次文件 = 5x IO)
        NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{};
        static NSInteger lastSyncedRotation = -1;
        static BOOL lastSyncedMirrored = NO;
        // 手动旋转直接透传(2026-08-24 回滚 manualComp 补偿): 曾以为自适应 CCW90 与
        // 手动角度同向抵消而加 90° 冻结补偿 —— 实证错误: adaptiveRotateIfNeeded 在
        // rotationAngle!=0 时本就直接跳过(无抵消发生), 且 hasAdaptiveRotated latch 是
        // 被录制流(横目标)置位的, 用户看的预览流(竖目标)并未被自适应旋转 → 补偿被
        // 错误叠加: 点一次"转"显示 90+90=180°(实测), m=270 时算出 0°、m 回 0 时算出
        // 90°, 循环全乱。透传后: 每次点击角度恰好 +90, 自适应已被 guard 禁用,
        // 显示 = 手动角度, 线性无跳变。
        // 1.3.32 追记: 透传只对"预览流为竖 buffer"的 App 成立。视频模式实测预览主流
        // 为横 buffer(2304x1296)+App transform 旋转显示, m!=0 跳过 CCW90 会让 CW90
        // 与 App transform 叠加 → 一次点击视觉 180°(0→180→270→0)。已在
        // GPUImageProcessor adaptiveRotateIfNeeded 修复: 正交判定基准改为假想
        // m=0 的源宽高比(m%180==90 时翻转回), CCW90 抵消手动翻转, 视觉恒 +90/点击;
        // plist 侧透传机制不变。
        NSInteger plistRotation = [pl[@"manualRotation"] integerValue];
        BOOL plistMirrored = [pl[@"mirrored"] boolValue];
        if (plistRotation != lastSyncedRotation) {
            strongSelf.gpuProcessor.rotationAngle = (int)(plistRotation % 360);
            lastSyncedRotation = plistRotation;
            vcam_core_log([NSString stringWithFormat:
                @"[vcam] rotation synced: plist=%ld", (long)plistRotation]);
        }
        if (plistMirrored != lastSyncedMirrored) {
            strongSelf.gpuProcessor.mirrored = plistMirrored;
            lastSyncedMirrored = plistMirrored;
            vcam_core_log([NSString stringWithFormat:@"[vcam] mirror synced: %d", plistMirrored]);
        }

        // 用户画面变换同步(悬浮球 箭头/＋/−/复): 变化时更新到 gpuProcessor,
        // 预渲染线程下一拍黑底画布合成烘焙进 live 帧(跳过判定已含 pan/zoom, 暂停时也重产出)
        // 前置方向修正(设置页开关): 前置流显示旋转与后置差 180°(pan 双反),
        // 开启时应用值 X/Y 同时取反 —— 比较用应用值, 开关切换也触发重新烘焙
        static double lastSyncedPanX = 0.0;
        static double lastSyncedPanY = 0.0;
        static double lastSyncedZoom = -1.0;  // -1 保证首拍必同步
        double plistPanX = [pl[@"userPanX"] doubleValue];
        double plistPanY = [pl[@"userPanY"] doubleValue];
        double plistZoom = [pl[@"userZoom"] doubleValue];
        if (plistZoom <= 0.0) plistZoom = 1.0;  // 缺失/非法回退原始
        double panSgn = [pl[@"frontPanFix"] boolValue] ? -1.0 : 1.0;
        double applyPanX = plistPanX * panSgn;
        double applyPanY = plistPanY * panSgn;
        if (applyPanX != lastSyncedPanX || applyPanY != lastSyncedPanY || plistZoom != lastSyncedZoom) {
            strongSelf.gpuProcessor.userPanX = applyPanX;
            strongSelf.gpuProcessor.userPanY = applyPanY;
            strongSelf.gpuProcessor.userZoom = plistZoom;
            lastSyncedPanX = applyPanX;
            lastSyncedPanY = applyPanY;
            lastSyncedZoom = plistZoom;
            vcam_core_log([NSString stringWithFormat:
                @"[vcam] transform synced: pan(%.2f,%.2f)%@ zoom=%.2f",
                plistPanX, plistPanY, panSgn < 0 ? @"[front-fix]" : @"", plistZoom]);
        }

        // 三色打光同步(1.3.45): 挪到 0.04s 专用快速轮询(见 startLightPolling
        // 回调), lightColor 跟随屏幕闪烁 0.1s 级变化, 0.15s 主节拍跟不上

        // 视频源切换(悬浮球 1/2/3 键): activePlaybackPath 变化 → 自动重载新视频
        // (无需 toggle enabled, 轮询 0.15s 内生效; 路径写入由悬浮球完成)
        static NSString *lastSyncedPath = nil;
        static BOOL pathSyncInit = NO;
        NSString *activePath = pl[@"activePlaybackPath"];
        if (activePath.length > 0 && ![activePath isEqualToString:lastSyncedPath]) {
            if (pathSyncInit && strongSelf.enabled) {
                vcam_core_log([NSString stringWithFormat:
                    @"[vcam] activePlaybackPath changed: %@ -> %@, reloading", lastSyncedPath, activePath]);
                // 切视频重置手动旋转/镜像: 残留的手动角度会与新视频自带的 preferredRotation
                // 叠加, 产生意外的 180° 等翻转(换视频后画面倒立的根因)。
                // 新视频按其自身元数据从干净起点显示
                // 1.3.30: 画面变换(pan/zoom)一并重置, 新视频从原始全幅位置显示
                strongSelf.gpuProcessor.rotationAngle = 0;
                strongSelf.gpuProcessor.mirrored = NO;
                strongSelf.gpuProcessor.userPanX = 0.0;
                strongSelf.gpuProcessor.userPanY = 0.0;
                strongSelf.gpuProcessor.userZoom = 1.0;
                [VCamNotify setPlistRotation:0];
                [VCamNotify setPlistMirrored:NO];
                [VCamNotify resetPlistTransform];
                lastSyncedRotation = 0;
                lastSyncedMirrored = NO;
                lastSyncedPanX = 0.0;
                lastSyncedPanY = 0.0;
                lastSyncedZoom = 1.0;
                // 1.3.48 视频切换重置车道记忆(新视频不继承旧失败): 直转/stage/
                // split/熔断 memo 全清零 —— 新视频尺寸/时序组合不同, 旧视频上
                // 的 -12902/-12905 失败记忆(甚至熔断态 keep camera)会让新视频
                // 一起不替换; 清零后新视频首帧重新探测各车道
                vcamLaneResetAllMemos();
                vcam_core_log(@"[vcam] lane memo reset on video switch (1.3.48)");
                // 异步重载(同步加载阻塞轮询线程 → watchdog 崩溃)
                __weak typeof(strongSelf) wSelf = strongSelf;
                dispatch_async(strongSelf.processingQueue, ^{
                    VCamCore *sSelf = wSelf;
                    if (!sSelf) return;
                    [sSelf.videoPlayer loadVideoAtPath:activePath completion:nil];
                    [sSelf.videoPlayer startWatchingFile:activePath];
                });
            }
            lastSyncedPath = [activePath copy];
            pathSyncInit = YES;
        }

        // 暂停/继续(悬浮球 ▶ 键): paused → 解码线程停止取帧, 预渲染冻结最后一帧
        static BOOL lastSyncedPaused = NO;
        BOOL plistPaused = [pl[@"paused"] boolValue];
        if (plistPaused != lastSyncedPaused) {
            strongSelf.videoPlayer.paused = plistPaused;
            vcam_core_log([NSString stringWithFormat:@"[vcam] paused synced: %d", plistPaused]);
            lastSyncedPaused = plistPaused;
        }

        // 从头重播(悬浮球 播 键): restartToken 自增 → 重载当前视频回到开头
        static NSInteger lastRestartToken = -1;
        NSInteger restartToken = [pl[@"restartToken"] integerValue];
        if (restartToken != lastRestartToken) {
            if (lastRestartToken >= 0 && strongSelf.enabled && strongSelf.videoPlayer.currentVideoPath.length > 0) {
                vcam_core_log(@"[vcam] restart token bumped, replay from beginning");
                [strongSelf.videoPlayer resetPlaybackPosition];  // 清续播位置, 真从头播(2026-08-19)
                // 异步重载(同步加载阻塞轮询线程 → watchdog 崩溃)
                NSString *replayPath = [strongSelf.videoPlayer.currentVideoPath copy];
                __weak typeof(strongSelf) wSelf = strongSelf;
                dispatch_async(strongSelf.processingQueue, ^{
                    VCamCore *sSelf = wSelf;
                    if (!sSelf) return;
                    [sSelf.videoPlayer loadVideoAtPath:replayPath completion:nil];
                });
            }
            lastRestartToken = restartToken;
        }
    }];

    // 三色打光快速轮询(1.3.45→1.3.49 提频): 0.02s 节拍(50Hz)同步打光 7 键到
    // gpuProcessor。延迟链: 悬浮球检测(自适应 0.02/0.04s) → 写 plist → 本轮询
    // ≤0.02s → gpuProcessor 参数即时生效 → 下一预渲染节拍(≤41.6ms@24fps)
    // 烘焙新光斑 → render。1.3.72: 早醒已移除(变色早醒 → 解码队列积压 +
    // FIFO 限深丢帧 = 卡顿根因), 光斑延迟 = 下一节拍, 人眼无感。
    // plist 读 ~0.15ms, 50Hz ≈ 0.75% 单核
    [[VCamNotify sharedInstance] startLightPollingWithInterval:0.02 callback:^(NSDictionary *pl) {
        VCamCore *strongSelf = weakSelf;
        if (!strongSelf) return;
        static uint64_t lastLightSig = 0;
        BOOL lEnabled = [pl[@"lightEnabled"] boolValue];
        // 1.3.69 原版逻辑回退: 总线直接携带标准纯色(检测端内置色表, 不经
        // T 表 —— SB 端 T 表解密失败导致光永远不亮的教训)。md 无任何映射,
        // 读到什么打什么。总线不新鲜(检测全关)时 fallback plist(同样存色值)。
        uint32_t lColor = (uint32_t)[pl[@"lightColor"] unsignedIntValue];
        int busCnt = 0;
        uint32_t busColor = 0;
        if ([VCamNotify vcamPickSharedColor:&busColor count:&busCnt]) {
            lColor = busColor;
        }
        int lX = [pl[@"lightX"] intValue];
        int lY = [pl[@"lightY"] intValue];
        int lInt = [pl[@"lightIntensity"] intValue];
        int lDia = [pl[@"lightDiameter"] intValue];
        int lFea = [pl[@"lightFeather"] intValue];
        if (lX <= 0 || lX > 100) lX = 50;      // 缺失/非法回默认
        if (lY <= 0 || lY > 100) lY = 50;
        if (lInt < 0 || lInt > 100) lInt = 30;
        if (lDia <= 0 || lDia > 100) lDia = 48;
        if (lFea < 0 || lFea > 100) lFea = 100;
        uint64_t sig = ((uint64_t)(lEnabled ? 1 : 0) << 59)
                     | ((uint64_t)(lColor & 0xFFFFFF) << 35)
                     | ((uint64_t)lX << 28) | ((uint64_t)lY << 21)
                     | ((uint64_t)lInt << 14) | ((uint64_t)lDia << 7)
                     | (uint64_t)lFea;
        if (sig != lastLightSig) {
            strongSelf.gpuProcessor.lightEnabled = lEnabled;
            strongSelf.gpuProcessor.lightColorRGB = lColor;
            strongSelf.gpuProcessor.lightX = lX;
            strongSelf.gpuProcessor.lightY = lY;
            strongSelf.gpuProcessor.lightIntensity = lInt;
            strongSelf.gpuProcessor.lightDiameter = lDia;
            strongSelf.gpuProcessor.lightFeather = lFea;
            lastLightSig = sig;
            // 1.3.72 早醒彻底移除: 1.3.71 节流后仍卡 —— 早醒拍不消费解码队列
            // → 队列积压 +1 → 下拍 FIFO 限深(>1 丢最旧)跳帧 + 早醒拍整帧重
            // 渲染(旋转VT+memcpy+光斑+烘焙 ≈ 1 帧间隔)挤占节拍 → 每次变色
            // = 丢帧+节拍错位 = 一卡一卡。根修: 光色变化不再唤醒预渲染线程,
            // 由下一正常节拍(≤41.6ms@24fps)自然烘焙新光斑 —— 检测去抖本身
            // 已 40ms 延迟, 此延迟人眼无感; 帧率节拍零扰动、零跳帧(帧率
            // 稳定是硬性验收标准)。semaphore 保留无人 signal = 纯超时等待,
            // 行为等同 sleep, 零风险。
            vcam_core_log([NSString stringWithFormat:
                @"[vcam] light synced: on=%d color=0x%06x pos(%d,%d) int=%d dia=%d fea=%d",
                (int)lEnabled, lColor, lX, lY, lInt, lDia, lFea]);
        }
    }];
}

- (void)stopStatePolling {
    [[VCamNotify sharedInstance] stopPolling];
    [[VCamNotify sharedInstance] stopLightPolling];
    _pollingActive = NO;
}

@end
