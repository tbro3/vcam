//
//  VCamNotify.m
//  VCamPlus
//
//  对标 vcameracrack.dylib 的 VCamNotify 实现
//  双通道：Darwin 通知 + plist 轮询
//

#import "VCamNotify.h"
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <string.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <notify.h>

NSString *const VCamNotifyReloadMedia = @"com.vcam.ios.media.reload";
NSString *const VCamNotifyLiveChanged = @"com.vcam.ios.live.changed";
NSString *const VCamPlistPath         = @"/var/mobile/Media/DCIM/vc.plist";
NSString *const VCamStateBackupPath   = @"/var/mobile/vc.plist";

// 日志总开关(2026-08-16, diskwrites 崩溃循环止血): 默认静默, vc.plist "logEnabled=YES" 打开
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

// 日志全局限速令牌桶(定义在 VCamCore.m, 全进程共享磁盘写入预算 —— 磁盘配额击杀根治)
extern BOOL vcam_log_budget_take(void);

static void vcam_notify_log(NSString *msg) {
    if (!vcam_log_enabled()) return;
    if (!vcam_log_budget_take()) return;
    @try {
        NSString *logPath = @"/tmp/vcam_notify_log.txt";
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

// Darwin 通知回调（必须是 C 函数，不能用 block）
@interface VCamNotify (Private)
- (void)dispatchCallbackForName:(NSString *)name;
@end

static void vcam_darwin_callback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    if (observer && name) {
        VCamNotify *notify = (__bridge VCamNotify *)observer;
        [notify dispatchCallbackForName:(__bridge NSString *)name];
    }
}

@interface VCamNotify ()
@property (nonatomic, strong) dispatch_queue_t notifyQueue;  // com.vcam.notify
@property (nonatomic, strong) NSMutableDictionary *callbacks; // name -> NSMutableArray of callback wrappers
@property (nonatomic, strong) NSLock *callbackLock;
@property (nonatomic, strong) NSMutableDictionary *darwinTokens; // name -> token number
@property (nonatomic, strong) dispatch_source_t pollingTimer;
@property (nonatomic, copy)   void(^pollingCallback)(BOOL enabled);
@property (nonatomic, assign) BOOL pollingActive;
// 打光快速轮询(1.3.45): 与主轮询同队列串行, 见 .h 注释
@property (nonatomic, strong) dispatch_source_t lightPollingTimer;
@property (nonatomic, copy)   void(^lightPollingCallback)(NSDictionary *plist);
@property (nonatomic, assign) BOOL lightPollingActive;
@end

@implementation VCamNotify

+ (instancetype)sharedInstance {
    static VCamNotify *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamNotify alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _notifyQueue = dispatch_queue_create("com.vcam.notify", DISPATCH_QUEUE_SERIAL);
        _callbacks = [[NSMutableDictionary alloc] init];
        _callbackLock = [[NSLock alloc] init];
        _darwinTokens = [[NSMutableDictionary alloc] init];
        _pollingActive = NO;
    }
    return self;
}

#pragma mark - Darwin 通知

- (void)postNotification:(NSString *)name {
    if (!name) return;
    vcam_notify_log([NSString stringWithFormat:@"[vcam] Posted notification: %@", name]);
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)name,
        NULL,
        NULL,
        TRUE
    );
}

- (NSInteger)registerForNotification:(NSString *)name callback:(VCamNotifyCallback)callback {
    if (!name || !callback) return -1;

    NSInteger token = [self nextTokenForName:name];

    // 包装回调，使其能在 notifyQueue 上执行
    __block VCamNotifyCallback blockCallback = [callback copy];
    NSDictionary *wrapper = @{@"token": @(token), @"callback": blockCallback};

    [_callbackLock lock];
    NSMutableArray *arr = _callbacks[name];
    if (!arr) {
        arr = [[NSMutableArray alloc] init];
        _callbacks[name] = arr;
    }
    [arr addObject:wrapper];
    [_callbackLock unlock];

    // 注册 Darwin 通知监听（仅第一次注册时）
    if (arr.count == 1) {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge void *)self,
            vcam_darwin_callback,
            (__bridge CFStringRef)name,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );
        vcam_notify_log([NSString stringWithFormat:@"[vcam] Registered for notification: %@ (token: %ld)", name, (long)token]);
    }

    return token;
}

- (void)unregisterNotification:(NSString *)name token:(NSInteger)token {
    if (!name) return;
    [_callbackLock lock];
    NSMutableArray *arr = _callbacks[name];
    if (arr) {
        for (NSInteger i = arr.count - 1; i >= 0; i--) {
            if ([arr[i][@"token"] integerValue] == token) {
                [arr removeObjectAtIndex:i];
            }
        }
        if (arr.count == 0) {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                (__bridge void *)self,
                (__bridge CFStringRef)name,
                NULL
            );
            [_callbacks removeObjectForKey:name];
            vcam_notify_log([NSString stringWithFormat:@"[vcam] Unregistered notification: %@", name]);
        }
    }
    [_callbackLock unlock];
}

- (NSInteger)nextTokenForName:(NSString *)name {
    NSNumber *current = _darwinTokens[name];
    NSInteger next = current ? [current integerValue] + 1 : 1;
    _darwinTokens[name] = @(next);
    return next;
}

- (void)dispatchCallbackForName:(NSString *)name {
    [_callbackLock lock];
    NSArray *arr = [_callbacks[name] copy];
    [_callbackLock unlock];
    for (NSDictionary *wrapper in arr) {
        VCamNotifyCallback cb = wrapper[@"callback"];
        if (cb) {
            dispatch_async(_notifyQueue, ^{
                cb(name);
            });
        }
    }
}

#pragma mark - plist 轮询

- (void)startPollingWithInterval:(NSTimeInterval)interval
                        callback:(void(^)(BOOL enabled))callback {
    if (_pollingActive) return;
    _pollingActive = YES;
    _pollingCallback = [callback copy];

    vcam_notify_log(@"[vcam] State polling timer started");

    _pollingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _notifyQueue);
    uint64_t intervalNs = interval * NSEC_PER_SEC;
    dispatch_source_set_timer(_pollingTimer, dispatch_time(DISPATCH_TIME_NOW, 0), intervalNs, intervalNs / 2);
    dispatch_source_set_event_handler(_pollingTimer, ^{
        // 心跳日志已移除(2026-08-16): mediaserverd 的 EXC_RESOURCE disk writes 限额
        // 仅 12.43KB/s(每日 ~1GB), 高频日志每行按 4KB 脏页记账曾达 69KB/s → 4 小时
        // 耗尽 1GB → 系统杀进程 → coalition 计数跨重启 → 6 秒崩溃循环
        BOOL enabled = [VCamNotify isPlistEnabled];
        if (self->_pollingCallback) {
            self->_pollingCallback(enabled);
        }
    });
    dispatch_resume(_pollingTimer);
}

- (void)stopPolling {
    if (_pollingTimer) {
        dispatch_source_cancel(_pollingTimer);
        _pollingTimer = nil;
    }
    _pollingActive = NO;
    _pollingCallback = nil;
}

// 打光专用快速轮询(1.3.45): timer 挂与主轮询同一个 _notifyQueue ——
// dispatch serial queue 上两个 timer handler 串行执行, 与主轮询回调
// 天然互斥(都能安全访问 VCamCore 的 gpuProcessor 状态)。
// 单次开销 = 一次 plist 文件读(~0.1-0.2ms) + 回调, 25Hz ≈ 0.5% 单核
- (void)startLightPollingWithInterval:(NSTimeInterval)interval
                             callback:(void(^)(NSDictionary *plist))callback {
    if (_lightPollingActive) return;
    _lightPollingActive = YES;
    _lightPollingCallback = [callback copy];

    _lightPollingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _notifyQueue);
    uint64_t intervalNs = interval * NSEC_PER_SEC;
    dispatch_source_set_timer(_lightPollingTimer, dispatch_time(DISPATCH_TIME_NOW, 0), intervalNs, intervalNs / 2);
    dispatch_source_set_event_handler(_lightPollingTimer, ^{
        NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
        if (self->_lightPollingCallback) {
            self->_lightPollingCallback(pl ?: @{});
        }
    });
    dispatch_resume(_lightPollingTimer);
}

- (void)stopLightPolling {
    if (_lightPollingTimer) {
        dispatch_source_cancel(_lightPollingTimer);
        _lightPollingTimer = nil;
    }
    _lightPollingActive = NO;
    _lightPollingCallback = nil;
}

#pragma mark - plist 读写

+ (BOOL)isPlistEnabled {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    if (!dict) {
        // 回退到备份路径
        dict = [NSDictionary dictionaryWithContentsOfFile:VCamStateBackupPath];
    }
    NSNumber *enabled = dict[@"enabled"];
    return enabled ? [enabled boolValue] : NO;
}

+ (void)setPlistEnabled:(BOOL)enabled {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"enabled"] = @(enabled);
    [dict writeToFile:VCamPlistPath atomically:YES];
    // 同步到备份路径
    [dict writeToFile:VCamStateBackupPath atomically:YES];
}

+ (NSString *)activePlaybackPath {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    return dict[@"activePlaybackPath"];
}

+ (void)setActivePlaybackPath:(NSString *)path {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"activePlaybackPath"] = path;
    [dict writeToFile:VCamPlistPath atomically:YES];
}

+ (NSInteger)plistRotation {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *rot = dict[@"manualRotation"];
    return rot ? [rot integerValue] : 0;
}

+ (void)setPlistRotation:(NSInteger)degrees {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"manualRotation"] = @(degrees);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

+ (BOOL)plistMirrored {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *m = dict[@"mirrored"];
    return m ? [m boolValue] : NO;
}

+ (void)setPlistMirrored:(BOOL)mirrored {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"mirrored"] = @(mirrored);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

#pragma mark - 用户画面变换(箭头/＋/−/复)

+ (double)plistPanX {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"userPanX"];
    return v ? [v doubleValue] : 0.0;
}

+ (void)setPlistPanX:(double)panX {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"userPanX"] = @(panX);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

+ (double)plistPanY {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"userPanY"];
    return v ? [v doubleValue] : 0.0;
}

+ (void)setPlistPanY:(double)panY {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"userPanY"] = @(panY);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

+ (double)plistZoom {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"userZoom"];
    return v ? [v doubleValue] : 1.0;  // 缺失时 1.0(原始等比填充)
}

+ (void)setPlistZoom:(double)zoom {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"userZoom"] = @(zoom);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

+ (void)resetPlistTransform {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"userPanX"] = @0.0;
    dict[@"userPanY"] = @0.0;
    dict[@"userZoom"] = @1.0;
    [dict writeToFile:VCamPlistPath atomically:YES];
}

// 前置方向修正: 前置流显示旋转与后置差 180°, pan 应用时 X/Y 同时取反(设置页开关)
+ (BOOL)plistFrontPanFix {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    return [dict[@"frontPanFix"] boolValue];
}

+ (void)setPlistFrontPanFix:(BOOL)fix {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"frontPanFix"] = @(fix);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

#pragma mark - 播放控制（跨进程: 悬浮球写, mediaserverd 轮询应用）

+ (BOOL)plistPaused {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    return [dict[@"paused"] boolValue];  // 缺失时 NO(播放中)
}

+ (void)setPlistPaused:(BOOL)paused {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"paused"] = @(paused);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

+ (NSInteger)plistRestartToken {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    return [dict[@"restartToken"] integerValue];  // 缺失时 0
}

+ (void)bumpRestartToken {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    NSInteger token = [dict[@"restartToken"] integerValue] + 1;
    dict[@"restartToken"] = @(token);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

#pragma mark - 三色打光(1.3.37, 跨进程: 悬浮球检测写, mediaserverd 轮询应用)

// 检测颜色高频写(0.1s 节拍且仅变化时): 单键写, 与既有 per-key 模式一致
+ (BOOL)plistLightEnabled {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    return [dict[@"lightEnabled"] boolValue];
}
+ (void)setPlistLightEnabled:(BOOL)enabled {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"lightEnabled"] = @(enabled);
    [dict writeToFile:VCamPlistPath atomically:YES];
}
+ (uint32_t)plistLightColor {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    return (uint32_t)[dict[@"lightColor"] unsignedIntValue];
}
+ (void)setPlistLightColor:(uint32_t)color {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"lightColor"] = @(color);
    [dict writeToFile:VCamPlistPath atomically:YES];
}
+ (int)plistLightX {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"lightX"];
    return v ? [v intValue] : 50;
}
+ (void)setPlistLightX:(int)x {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"lightX"] = @(x);
    [dict writeToFile:VCamPlistPath atomically:YES];
}
+ (int)plistLightY {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"lightY"];
    return v ? [v intValue] : 50;
}
+ (void)setPlistLightY:(int)y {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"lightY"] = @(y);
    [dict writeToFile:VCamPlistPath atomically:YES];
}
+ (int)plistLightIntensity {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"lightIntensity"];
    return v ? [v intValue] : 30;
}
+ (void)setPlistLightIntensity:(int)v {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"lightIntensity"] = @(v);
    [dict writeToFile:VCamPlistPath atomically:YES];
}
+ (int)plistLightDiameter {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"lightDiameter"];
    return v ? [v intValue] : 48;
}
+ (void)setPlistLightDiameter:(int)v {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"lightDiameter"] = @(v);
    [dict writeToFile:VCamPlistPath atomically:YES];
}
+ (int)plistLightFeather {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"lightFeather"];
    return v ? [v intValue] : 100;
}
+ (void)setPlistLightFeather:(int)v {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"lightFeather"] = @(v);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

#pragma mark - 密钥验证(1.3.55, ECDSA P-256 设备绑定签名 / 激活后永久)

// ==== 可信符号解析(防 rebind/interpose Hook) ====
// dlsym + dladdr 双重校验: 符号必须解析自系统镜像(/usr/lib 或 /System 前缀)。
// 越狱注入的第三方 dylib 全在 /var/jb / /Library 等路径下 —— 符号被 rebind
// 到攻击者镜像时 dli_fname 不在信任前缀 → 返回 NULL。调用方随之走"身份值
// 劣化"路径(静默): 设备码变垃圾/拿不到硬件源 → md 侧验签自然失败。
// (注: 对内联补丁式 Hook 由 VCamCore 的 IMP 范围自检 + 帧门禁周期重算兜底)
static void *vcamDlsymTrusted(const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (!p) return NULL;
    Dl_info info;
    if (dladdr(p, &info) == 0 || !info.dli_fname) return NULL;
    const char *fn = info.dli_fname;
    if (strncmp(fn, "/usr/lib", 8) == 0 || strncmp(fn, "/System", 7) == 0) return p;
    vcam_notify_log(@"[vcam][lic] untrusted sym src");
    return NULL;
}

// 信任校验公共层: 地址必须归属 /usr/lib 或 /System 镜像
static void *vcamSymTrusted(void *p) {
    if (!p) return NULL;
    Dl_info info;
    if (dladdr(p, &info) == 0 || !info.dli_fname) return NULL;
    const char *fn = info.dli_fname;
    if (strncmp(fn, "/usr/lib", 8) == 0 || strncmp(fn, "/System", 7) == 0) return p;
    vcam_notify_log(@"[vcam][lic] untrusted sym src");
    return NULL;
}

// Security.framework 显式加载(1.3.57): SB/mediaserverd 主程序不直接链接
// Security, RTLD_DEFAULT 搜索域里没有该镜像 → 全部 Sec 符号落空
// ("sec syms missing", 1.3.56 激活失败根因: MGCopyAnswer/IOKit 在 SB 已加载
//  所以解析成功, Security 没有)。dlopen 从共享缓存把镜像拉进进程(幂等,
//  已加载仅加引用计数), 之后 dlsym 可见。路径字面量走混淆字符串层。
// 1.3.58: RTLD_LOCAL → RTLD_GLOBAL —— LOCAL 模式下镜像符号不进全局搜索域,
// dlsym(RTLD_DEFAULT) 兜底永远落空(1.3.57 实测: dlopen 成功无 fail 日志,
// 句柄内 dlsym 也落空); GLOBAL 让兜底与 IOKit/MobileGestalt 同机制解析
// (该机制在本设备 SB 实证可用: mg=1 io=1)。
static void *vcamSecImg(void) {
    static void *img = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        img = dlopen("/System/Library/Frameworks/Security.framework/Security",
                     RTLD_LAZY | RTLD_GLOBAL);
        if (!img) {
            const char *err = dlerror();
            vcam_notify_log([NSString stringWithFormat:
                @"[vcam][lic] sec img load fail: %s", err ? err : "null"]);
        }
    });
    return img;
}

// 镜像扫描兜底(1.3.59): 符号不在 dlopen 句柄/全局搜索域时, 遍历进程
// 已加载的 /System /usr/lib 镜像(RTLD_NOLOAD 现成句柄)逐个 dlsym, 找到后
// 照走 dladdr 信任校验。_dyld_* 在 libdyld(/usr/lib/system), 与已实证可
// 解析的 MGCopyAnswer/IOKit 同机制。
// (1.3.60 根因实锤, 依据 iOS 15.6 SDK 头文件: 1.3.55~59 的 d=..0..0 并非
// 镜像问题, 是符号名错 —— kSecAttrKeyTypeECSECPrime256 是 macOS-only 常量
// (SecItem.h 标 ios NA), iOS 的 EC key type 真名是 kSecAttrKeyTypeECSECPrimeRandom;
// 算法常量真名是 kSecKeyAlgorithmECDSASignatureMessageX962SHA256(kSecKeyAlgorithm*
// 前缀 + X962, iOS 无 kSecSignatureAlgorithm* 旧 macOS 枚举符号)。已修正。)
static void *vcamScanImagesFor(const char *name) {
    typedef uint32_t (*ImgCountFn)(void);
    typedef const char *(*ImgNameFn)(uint32_t);
    static ImgCountFn cnt = NULL;
    static ImgNameFn nm = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cnt = (ImgCountFn)vcamDlsymTrusted("_dyld_image_count");
        nm  = (ImgNameFn)vcamDlsymTrusted("_dyld_get_image_name");
    });
    if (!cnt || !nm) return NULL;
    uint32_t n = cnt();
    for (uint32_t i = 0; i < n; i++) {
        const char *path = nm(i);
        if (!path) continue;
        if (strncmp(path, "/System", 7) != 0 && strncmp(path, "/usr/lib", 8) != 0) continue;
        void *h = dlopen(path, RTLD_LAZY | RTLD_NOLOAD);
        if (!h) continue;
        void *s = dlsym(h, name);
        if (s) {
            void *t = vcamSymTrusted(s);
            if (t) return t;
        }
    }
    return NULL;
}

// Security 符号专用解析 + 逐符号诊断(1.3.58): *diag 0=dlsym 全落空,
// 1=dlsym 命中但 dladdr 信任拒, 2=通过, 4=镜像扫描兜底命中。
// 单行合并输出防令牌桶吃行。
static void *vcamSecSymX(void *img, const char *name, int *diag) {
    void *p = img ? dlsym(img, name) : NULL;
    if (!p) p = dlsym(RTLD_DEFAULT, name);
    if (p) {
        void *t = vcamSymTrusted(p);
        if (t) { *diag = 2; return t; }
        *diag = 1;
        return NULL;
    }
    void *s = vcamScanImagesFor(name);
    if (s) { *diag = 4; return s; }
    *diag = 0;
    return NULL;
}

// SHA256(源) 前 8 字节 → 16 位大写 hex NSString(设备码口径, 展示分组由 UI 做)
typedef unsigned char *(*vcamSHA256Fn)(const void *, unsigned int, unsigned char *);
static NSString *vcamDigestHex16(NSString *src) {
    static vcamSHA256Fn sha = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sha = (vcamSHA256Fn)vcamDlsymTrusted("CC_SHA256");
    });
    if (!sha || src.length == 0) return nil;
    NSData *d = [src dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return nil;
    unsigned char md[32];
    sha(d.bytes, (unsigned int)d.length, md);
    char hex[17];
    for (int i = 0; i < 8; i++) {
        unsigned char b = md[i];
        hex[i * 2]     = "0123456789ABCDEF"[b >> 4];
        hex[i * 2 + 1] = "0123456789ABCDEF"[b & 0xF];
    }
    hex[16] = 0;
    return [NSString stringWithUTF8String:hex];
}

// hex 单字符 → 数值(非法返回 -1)
static int vcamHexDigit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// MobileGestalt(可信任源解析)
typedef CFStringRef (*vcamMGCopyAnswerFn)(CFStringRef);
static vcamMGCopyAnswerFn vcamMGResolve(void) {
    static vcamMGCopyAnswerFn fn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fn = (vcamMGCopyAnswerFn)vcamDlsymTrusted("MGCopyAnswer");
    });
    return fn;
}

// IOKit 平台序列号: 与 MobileGestalt 完全独立的第二条身份 API 路径。
// 类型按框架 ABI 手工声明(iOS 公开 SDK 不带 IOKit 用户头);
// kIOMasterPortDefault == 0 直传
static NSString *vcamPlatformSerial(void) {
    static NSString *serial = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        typedef uint32_t vcamIOObj;
        typedef CFMutableDictionaryRef (*IOServiceMatchingFn)(const char *);
        typedef vcamIOObj (*IOServiceGetMatchingServiceFn)(uint32_t, CFDictionaryRef);
        typedef CFTypeRef (*IORegistryEntryCreateCFPropertyFn)(vcamIOObj, CFStringRef, CFAllocatorRef, uint32_t);
        typedef int (*IOObjectReleaseFn)(vcamIOObj);
        IOServiceMatchingFn matching =
            (IOServiceMatchingFn)vcamDlsymTrusted("IOServiceMatching");
        IOServiceGetMatchingServiceFn getsvc =
            (IOServiceGetMatchingServiceFn)vcamDlsymTrusted("IOServiceGetMatchingService");
        IORegistryEntryCreateCFPropertyFn getprop =
            (IORegistryEntryCreateCFPropertyFn)vcamDlsymTrusted("IORegistryEntryCreateCFProperty");
        IOObjectReleaseFn release =
            (IOObjectReleaseFn)vcamDlsymTrusted("IOObjectRelease");
        if (!matching || !getsvc || !getprop || !release) return;
        NSString *svc = @"IOPlatformExpertDevice";
        vcamIOObj entry = getsvc(0, matching([svc UTF8String]));
        if (entry) {
            CFTypeRef v = getprop(entry, CFSTR("IOPlatformSerialNumber"),
                                  kCFAllocatorDefault, 0);
            if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
                serial = [NSString stringWithString:(__bridge NSString *)v];
            }
            if (v) CFRelease(v);
            release(entry);
        }
    });
    return serial;
}

// UDID/硬件源不可用时回退: plist 持久 UUID(两进程同读同值; 首次缺省生成并
// 写回, 原子写双路径与既有 setter 一致)
+ (NSString *)vcamPersistDeviceUUID {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSString *uuid = dict[@"deviceUUID"];
    if ([uuid isKindOfClass:[NSString class]] && uuid.length > 0) return uuid;
    uuid = [[NSUUID UUID] UUIDString];
    NSMutableDictionary *mdict = [NSMutableDictionary dictionaryWithDictionary:dict ?: @{}];
    mdict[@"deviceUUID"] = uuid;
    [mdict writeToFile:VCamPlistPath atomically:YES];
    [mdict writeToFile:VCamStateBackupPath atomically:YES];
    return uuid;
}

// 设备码(静态缓存, 多源绑定): UDID + SerialNumber(MobileGestalt) +
// IOPlatformSerialNumber(IOKit) 混入 SHA256 —— 两条独立 API 路径, 单点
// Hook 难以在 SB/md 两进程伪造一致的假身份。硬件源全不可用时回退 plist
// UUID(仅同机一致, 换机必变)。logEnabled 时打印设备码与源可用性, 用于
// 跨进程一致性诊断(SB 与 md 必须算出同值, 否则激活在 md 侧不生效)
+ (NSString *)vcamDeviceCode {
    static NSString *code = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableString *mix = [NSMutableString stringWithString:@"QvD|"];
        vcamMGCopyAnswerFn mg = vcamMGResolve();
        BOOL gotHW = NO;
        if (mg) {
            CFStringRef udid = mg(CFSTR("UniqueDeviceID"));
            if (udid) {
                [mix appendString:(__bridge NSString *)udid];
                CFRelease(udid);
                gotHW = YES;
            }
            [mix appendString:@"|S|"];
            CFStringRef serial = mg(CFSTR("SerialNumber"));
            if (serial) {
                [mix appendString:(__bridge NSString *)serial];
                CFRelease(serial);
                gotHW = YES;
            }
        }
        [mix appendString:@"|P|"];
        NSString *platformSerial = vcamPlatformSerial();
        if (platformSerial.length > 0) {
            [mix appendString:platformSerial];
            gotHW = YES;
        }
        if (!gotHW) {
            [mix appendString:[self vcamPersistDeviceUUID]];
        }
        code = vcamDigestHex16(mix);
        vcam_notify_log([NSString stringWithFormat:
            @"[vcam][lic] device code %@ (mg=%d io=%d)",
            code, mg != NULL, platformSerial.length > 0]);
    });
    return code;
}

// ==== ECDSA P-256 验签(全 dlsym, 符号不进符号表) ====
// 消息 = 本机设备码原文(16 hex 大写); 签名 = base64(DER x9.62) blob(~96 字符)。
// (1.3.60: iOS 的 kSecKeyAlgorithmECDSASignatureMessageX962SHA256 要求 DER
// 编码签名(SEQUENCE of r,s); 1.3.56 改的 raw r||s 64B 是按 macOS 文档臆断
// 的格式, iOS 验签必失败 —— gen_license.py 已同步改回 DER 输出)
// 公钥 = X9.63 未压缩 65 字节(hex 嵌入, 混淆字符串层加密)。
// 私钥仅存在于开发机 license_priv.pem, 永不上设备 —— 逆向再彻底也无法
// 伪造密钥(数学保证, 非混淆保证)
+ (BOOL)vcamLicenseVerifyBlob:(NSString *)blob {
    if (![blob isKindOfClass:[NSString class]]) return NO;
    // 1.3.63 方案A: blob v2 = base64(DER 签名) "." base64(T_enc 72B)。
    // 旧格式(无 "." 段)fail-closed —— 验签消息升级为 设备码||T_enc
    NSRange dot = [blob rangeOfString:@"."];
    if (dot.location == NSNotFound || dot.location == 0 ||
        dot.location + 1 >= blob.length) return NO;
    NSData *sig = [[NSData alloc] initWithBase64EncodedString:
        [blob substringToIndex:dot.location]
        options:NSDataBase64DecodingIgnoreUnknownCharacters];
    NSData *tEnc = [[NSData alloc] initWithBase64EncodedString:
        [blob substringFromIndex:dot.location + 1]
        options:NSDataBase64DecodingIgnoreUnknownCharacters];
    // DER P-256 签名 = 0x30 开头的 SEQUENCE, 66~72 字节(r/s 前导零致不定长;
    // 此处只做快速 fail-closed, 真正解析由 SecKeyVerifySignature 完成)
    if (!sig || sig.length < 64 || sig.length > 72) return NO;
    if (((const uint8_t *)sig.bytes)[0] != 0x30) return NO;
    // T 表 = 18 × u32(BE) = 72 字节(gen_license.py T_TRUE 布局)
    if (!tEnc || tEnc.length != 72) return NO;
    NSString *dc = [self vcamDeviceCode];
    if (dc.length != 16) return NO;
    // 消息 = 设备码(16 ascii) || T_enc(签名覆盖参数密文, 篡改即验签失败)
    NSMutableData *msg = [NSMutableData dataWithCapacity:16 + 72];
    [msg appendData:[dc dataUsingEncoding:NSUTF8StringEncoding]];
    [msg appendData:tEnc];
    NSData *msgData = [msg copy];

    typedef CFTypeRef (*SecKeyCreateWithDataFn)(CFDataRef, CFDictionaryRef, void **);
    typedef BOOL (*SecKeyVerifySignatureFn)(CFTypeRef, CFStringRef, CFDataRef, CFDataRef, void **);
    static SecKeyCreateWithDataFn createKey = NULL;
    static SecKeyVerifySignatureFn verifySig = NULL;
    static CFStringRef attrType = NULL, attrClass = NULL, attrSize = NULL;
    static CFStringRef keyTypeEC = NULL, keyClassPub = NULL, sigAlg = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *img = vcamSecImg();
        int dg[8];
        createKey  = (SecKeyCreateWithDataFn)vcamSecSymX(img, "SecKeyCreateWithData", &dg[0]);
        verifySig  = (SecKeyVerifySignatureFn)vcamSecSymX(img, "SecKeyVerifySignature", &dg[1]);
        // kSecAttr*/kSecKeyAlgorithm* 是 const CFStringRef 指针常量: dlsym 返回的是
        // "存放该指针的变量"的地址, 须再解一层引用(*slot)取真正的 CFStringRef 值。
        // (1.3.55 激活失败设备端根因: 直接把符号地址当 CFStringRef 用 → 属性
        //  字典键全错 → SecKeyCreateWithData 建钥失败 → 验签永远 NO)
        CFStringRef *slot = NULL;
        slot      = (CFStringRef *)vcamSecSymX(img, "kSecAttrKeyType", &dg[2]);
        attrType  = slot ? *slot : NULL;
        slot      = (CFStringRef *)vcamSecSymX(img, "kSecAttrKeyClass", &dg[3]);
        attrClass = slot ? *slot : NULL;
        slot      = (CFStringRef *)vcamSecSymX(img, "kSecAttrKeySizeInBits", &dg[4]);
        attrSize  = slot ? *slot : NULL;
        slot      = (CFStringRef *)vcamSecSymX(img, "kSecAttrKeyTypeECSECPrimeRandom", &dg[5]);
        keyTypeEC = slot ? *slot : NULL;
        slot      = (CFStringRef *)vcamSecSymX(img, "kSecAttrKeyClassPublic", &dg[6]);
        keyClassPub = slot ? *slot : NULL;
        slot      = (CFStringRef *)vcamSecSymX(img, "kSecKeyAlgorithmECDSASignatureMessageX962SHA256", &dg[7]);
        sigAlg    = slot ? *slot : NULL;
        // 单行诊断: img=句柄, d=8 符号各自 0/1/2 (见 vcamSecSymX)
        vcam_notify_log([NSString stringWithFormat:
            @"[vcam][lic] sec diag img=%d d=%d%d%d%d%d%d%d%d", img != NULL,
            dg[0], dg[1], dg[2], dg[3], dg[4], dg[5], dg[6], dg[7]]);
        if (!createKey || !verifySig || !attrType || !attrClass || !attrSize ||
            !keyTypeEC || !keyClassPub || !sigAlg) {
            vcam_notify_log(@"[vcam][lic] sec syms missing");
        }
    });
    if (!createKey || !verifySig || !attrType || !attrClass || !attrSize ||
        !keyTypeEC || !keyClassPub || !sigAlg) return NO;

    // 公钥 hex → 65 字节未压缩点(静态缓存)
    static NSData *pubKeyData = nil;
    static dispatch_once_t pubOnce;
    dispatch_once(&pubOnce, ^{
        NSString *pubHex = @"047ac82d0d8ba9e315bebf8ebdb1c6a8065b4156f9a5839fd2ba92082081a10fa67972526b49606266b25d87911b5b707838390d4ce3eef81039e986da6cd58cd6";
        if ([pubHex length] != 130) return;
        const char *hex = [pubHex UTF8String];
        NSMutableData *d = [NSMutableData dataWithLength:65];
        uint8_t *b = (uint8_t *)d.mutableBytes;
        for (int i = 0; i < 65; i++) {
            int hi = vcamHexDigit(hex[i * 2]);
            int lo = vcamHexDigit(hex[i * 2 + 1]);
            if (hi < 0 || lo < 0) return;
            b[i] = (uint8_t)((hi << 4) | lo);
        }
        pubKeyData = [d copy];
    });
    // 1.3.61 验签链路逐环诊断(每进程一次): 1.3.60 设备实测 d=22222222
    // (8 符号全解出)后仍无 state change → 失败点在符号解析之后的静默
    // return。pub=公钥字节数(65 正常, 0=hex 解码失败) key=SecKey 建钥
    // 结果 sig=验签结果 bl/sl=blob 字符数与 DER 字节数
    static dispatch_once_t verDiagOnce;
    BOOL keyOK = NO, sigOK = NO;
    if (pubKeyData.length == 65) {
        int bits = 256;
        CFNumberRef sizeNum = CFNumberCreate(NULL, kCFNumberIntType, &bits);
        const void *dk[3] = { attrType, attrClass, attrSize };
        const void *dv[3] = { keyTypeEC, keyClassPub, sizeNum };
        CFDictionaryRef attrs = CFDictionaryCreate(NULL, dk, dv, 3,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFTypeRef key = attrs ? createKey((__bridge CFDataRef)pubKeyData, attrs, NULL) : NULL;
        if (attrs) CFRelease(attrs);
        if (sizeNum) CFRelease(sizeNum);
        keyOK = key != NULL;
        if (key) {
            sigOK = verifySig(key, sigAlg,
                              (__bridge CFDataRef)msgData, (__bridge CFDataRef)sig, NULL);
            CFRelease(key);
        }
    }
    dispatch_once(&verDiagOnce, ^{
        vcam_notify_log([NSString stringWithFormat:
            @"[vcam][lic] ver diag pub=%lu key=%d sig=%d bl=%lu sl=%lu",
            (unsigned long)pubKeyData.length, keyOK, sigOK,
            (unsigned long)blob.length, (unsigned long)sig.length]);
    });
    return sigOK;
}

// 已激活: plist licBlob 对本机设备码验签通过。0.5s 节流缓存(ECDSA ~1ms,
// 0.15s 轮询全验签无必要; 激活写入后 0.5s 内过期重验, md 下一拍生效)
+ (BOOL)vcamLicenseValid {
    @synchronized ([VCamNotify class]) {
        static BOOL cached = NO;
        static double cachedAt = 0;
        static BOOL hasCache = NO;
        double now = [NSDate timeIntervalSinceReferenceDate];
        if (hasCache && now - cachedAt < 0.5) return cached;
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
        if (!dict) dict = [NSDictionary dictionaryWithContentsOfFile:VCamStateBackupPath];
        NSString *blob = dict[@"licBlob"];
        cached = [blob isKindOfClass:[NSString class]] && [self vcamLicenseVerifyBlob:blob];
        cachedAt = now;
        hasCache = YES;
        return cached;
    }
}

// 激活: 输入密钥(base64, 区分大小写, 仅去空白/换行)验签通过 → 写
// licBlob/activated/dcPub。mediaserverd 0.15s 轮询下一拍即生效
+ (BOOL)vcamActivateLicense:(NSString *)input {
    if (![input isKindOfClass:[NSString class]]) return NO;
    NSString *blob = [[input componentsSeparatedByCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]]
        componentsJoinedByString:@""];
    if (![self vcamLicenseVerifyBlob:blob]) return NO;
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"licBlob"] = blob;
    dict[@"activated"] = @YES;
    dict[@"dcPub"] = [self vcamDeviceCode];
    [dict writeToFile:VCamPlistPath atomically:YES];
    [dict writeToFile:VCamStateBackupPath atomically:YES];
    return YES;
}

// SB 侧发布本进程设备码(打开激活页/激活成功时调用) → md 侧互证
+ (void)vcamPublishDeviceCode {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"dcPub"] = [self vcamDeviceCode];
    [dict writeToFile:VCamPlistPath atomically:YES];
    [dict writeToFile:VCamStateBackupPath atomically:YES];
}

// md 侧跨进程互证: SB 发布的 dcPub 与本机计算值一致(单边被 Hook →
// 不一致 → VCamCore licMark 关门禁)
+ (BOOL)vcamCrossDeviceCodeOK {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    if (!dict) dict = [NSDictionary dictionaryWithContentsOfFile:VCamStateBackupPath];
    NSString *pub = dict[@"dcPub"];
    if (![pub isKindOfClass:[NSString class]] || pub.length != 16) return NO;
    return [pub isEqualToString:[self vcamDeviceCode]];
}

// ===== 1.3.63 方案A: 许可携带功能参数密文(T 表) =====
// 验签不再是"开关"而是"钥匙": blob v2 的 T 段解密出打光颜色/HSV 门限/
// 计票阈值/zoom/pan/旋转/羽化等真值 —— 跳过验证 = T 无来源 = 参数全垃圾
// (画面数学错误, 非简单"不工作", 补丁者无从得知正确值)。
// 链路(与 gen_license.py 严格一致, 流布局 1.3.64 设备实锤对齐):
//   验签: SecKeyVerifySignature(公钥, 设备码||T_enc, DER 签名)
//   K    = SHA256(设备码 16 ascii || T_SALT 16B)
//   流    = 每块 SHA256(K||u32be(blk)) 只取前 24B(6×u32)拼接
//          (word idx 的流字节在块 idx/6 内偏移 (idx%6)*4 —— 非平铺)
//   T[i] = (T_enc_u32[i] ^ 流_u32[i]) ^ devHash32[i%8]
//   devHash32 = SHA256(设备码) 前 32B 按 8×u32(BE)
// 防抄许可: T_enc 加密端已预混签发设备的 devHash32, 本机再混自己值,
// 他人许可在本机掺混后必为垃圾(魔数校验拦截)。
// 1.3.78 明文驻留最小化(防内存 dump): 旧版把 72B 明文表作为 NSData 缓存
// 在堆上 0.5s —— 持合法许可的本机 dump mediaserverd 内存可整表拿走
// (破解链: 买一个真许可 → 全链本机正常解密 → dump T_TRUE → patch 常量
// + 跳门禁)。现改为解码直写【调用方栈缓冲】, 调用方读值后立即擦除 ——
// 明文仅在栈上存活微秒级, dump 拿不到连续 72B 明文表。验签每次全跑
// (~1ms, 消费端均为低频参数读取, 不做结果缓存)。
// 成功返回 YES 且 outT 为 18×u32(BE 语义值); 失败返回 NO 并擦除。
+ (BOOL)vcamLicenseDecodeT:(uint32_t *)outT {
    @synchronized ([VCamNotify class]) {
        if (!outT) return NO;
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
        if (!dict) dict = [NSDictionary dictionaryWithContentsOfFile:VCamStateBackupPath];
        NSString *blob = dict[@"licBlob"];
        if (![blob isKindOfClass:[NSString class]] ||
            ![self vcamLicenseVerifyBlob:blob]) return NO;
        // 复用验签内部同款解析: sig 段(解 K 不需要) + T_enc 段
        NSRange dot = [blob rangeOfString:@"."];
        NSData *tEnc = [[NSData alloc] initWithBase64EncodedString:
            [blob substringFromIndex:dot.location + 1]
            options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (tEnc.length != 72) return NO;
        NSString *dc = [self vcamDeviceCode];
        if (dc.length != 16) return NO;
        NSData *dcData = [dc dataUsingEncoding:NSUTF8StringEncoding];

        // CC_SHA256(可信解析, 与设备码同链路)
        static vcamSHA256Fn sha = NULL;
        static dispatch_once_t shaOnce;
        dispatch_once(&shaOnce, ^{
            sha = (vcamSHA256Fn)vcamDlsymTrusted("CC_SHA256");
        });
        if (!sha) return NO;

        // T_SALT(构建期盐, hex 32 字符 → 16B; 与 gen_license.py 一致)。
        // 局部变量(非 static): 混淆器把 C 字符串换成运行时解密调用,
        // static const 初始化会因非常量初始化器编译失败(工程既有约束)
        const char *saltHex = "7ecfba852c100ab4228ac14f062f737c";
        uint8_t salt[16];
        for (int i = 0; i < 16; i++) {
            int hi = vcamHexDigit(saltHex[i * 2]);
            int lo = vcamHexDigit(saltHex[i * 2 + 1]);
            if (hi < 0 || lo < 0) return NO;
            salt[i] = (uint8_t)((hi << 4) | lo);
        }

        // K = SHA256(设备码 || T_SALT)
        uint8_t bufK[16 + 16];
        memcpy(bufK, dcData.bytes, 16);
        memcpy(bufK + 16, salt, 16);
        uint8_t k[32];
        sha(bufK, 32, k);

        // devHash32 = SHA256(设备码) → 8×u32(BE)
        uint8_t devHash[32];
        sha(dcData.bytes, 16, devHash);
        uint32_t dev32[8];
        for (int i = 0; i < 8; i++) {
            dev32[i] = ((uint32_t)devHash[i * 4] << 24) | ((uint32_t)devHash[i * 4 + 1] << 16) |
                       ((uint32_t)devHash[i * 4 + 2] << 8) | (uint32_t)devHash[i * 4 + 3];
        }

        // 解密: t[i] = T_enc_u32[i] ^ 流_u32[i] ^ dev32[i%8](直写调用方缓冲)
        const uint8_t *enc = (const uint8_t *)tEnc.bytes;
        uint8_t ctr[32 + 4];
        memcpy(ctr, k, 32);
        for (int blk = 0; blk < 3; blk++) {  // 72B = 3 块 SHA256
            ctr[32] = (uint8_t)(blk >> 24); ctr[33] = (uint8_t)(blk >> 16);
            ctr[34] = (uint8_t)(blk >> 8);  ctr[35] = (uint8_t)blk;
            uint8_t st[32];
            sha(ctr, 36, st);
            for (int j = 0; j < 6; j++) {  // 每块 6 × u32
                int idx = blk * 6 + j;
                uint32_t e = ((uint32_t)enc[idx * 4] << 24) | ((uint32_t)enc[idx * 4 + 1] << 16) |
                             ((uint32_t)enc[idx * 4 + 2] << 8) | (uint32_t)enc[idx * 4 + 3];
                uint32_t s = ((uint32_t)st[j * 4] << 24) | ((uint32_t)st[j * 4 + 1] << 16) |
                             ((uint32_t)st[j * 4 + 2] << 8) | (uint32_t)st[j * 4 + 3];
                outT[idx] = e ^ s ^ dev32[idx % 8];
            }
        }
        // 自校验: idx0 魔数 + idx17 = idx0..16 XOR
        // (先拷标量再进 block: C 数组不能被 block 捕获)
        static dispatch_once_t tDiagOnce;
        BOOL ok = (outT[0] == 0x3FA7C2E1u);
        uint32_t x = 0;
        for (int i = 0; i < 17; i++) x ^= outT[i];
        if (x != outT[17]) ok = NO;
        uint32_t m0 = outT[0], m17 = outT[17];
        dispatch_once(&tDiagOnce, ^{
            vcam_notify_log([NSString stringWithFormat:
                @"[vcam][lic] T diag m=%08x c=%08x ok=%d",
                m0, m17, ok]);
        });
        if (!ok) {
            memset(outT, 0, 72);  // 失败也擦: 半解密态不留明文残留
            return NO;
        }
        return YES;
    }
}

// T 表参数取值(u32 → double, ×100 定点): 消费端统一入口。
// 1.3.78 栈式解码: 不落堆不缓存, 取值后立即擦除(明文只存活于本栈帧)
+ (double)vcamLicenseTableDouble:(NSUInteger)idx {
    uint32_t t[18];
    double v = 0.0;
    if (idx <= 17 && [self vcamLicenseDecodeT:t]) v = (double)t[idx] / 100.0;
    memset(t, 0, sizeof(t));
    return v;
}

// T 表参数取值(u32 原值): 颜色表/门限等整数参数。同上栈式解码+擦除
+ (uint32_t)vcamLicenseTableInt:(NSUInteger)idx {
    uint32_t t[18];
    uint32_t v = 0;
    if (idx <= 17 && [self vcamLicenseDecodeT:t]) v = t[idx];
    memset(t, 0, sizeof(t));
    return v;
}

#pragma mark - 1.3.65 前台 App 进程取色采样器 + mmap 颜色总线
// 根因(1.3.64 设备日志实锤): UICSI 在 SB 进程只截 SB 自己的图层, App 前台
// 时采样区全黑(color=0x000000 cnt=0) —— 1.3.44 的 441/441 是桌面层假阳性。
// 架构: 检测搬进前台 App 进程(进程内 UICSI 截本 App 画面=屏幕实际内容),
// 结果写 mmap 共享页(零磁盘写), md 0.02s 光轮询读总线打光; SB 检测双写总线。
//
// 共享页布局(一页 4096B, u32 视图):
//   [0]  magic 'VCP1'  (0x56435031)
//   [1]  color  (RGB, 0=熄灭)
//   [2]  count  (匹配票数)
//   [3]  avg    (采样区平均 RGB, 诊断)
//   [4-5] timestamp double(CFAbsoluteTime, 8B 对齐原子写) —— 最后写,
//         读端两次读一致才有效(seqlock 风格)
//   [6]  pid    (写进程诊断)
// 前台唯一性: 只 UIApplicationStateActive 进程写 → 天然单写者
// (SB 在 App 前台时 Inactive 不写, 桌面时 Active 写)。

typedef struct {
    uint32_t magic;
    uint32_t slot;   // 色档编号(0=熄灭, 1-6=红绿蓝黄青紫; 诊断用)
    uint32_t color;  // 1.3.69 原版逻辑: 检测端直接给标准纯色(不经 T 表)
    uint32_t count;
    uint32_t avg;
    double   ts;
    uint32_t pid;
} VCamPickShm;

static VCamPickShm *vcamPickShmMap(void) {
    static VCamPickShm *mapped = (VCamPickShm *)MAP_FAILED;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 路径字面量(混淆器构建期加密为 OBCS 运行时解密)
        const char *path = "/var/mobile/Media/DCIM/.vcampick";
        int fd = open(path, O_RDWR | O_CREAT, 0644);
        if (fd < 0) return;
        ftruncate(fd, 4096);
        void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (p == MAP_FAILED) return;
        mapped = (VCamPickShm *)p;
        if (mapped->magic != 0x56435031u) {
            // 首次映射(或异版本残留): 初始化; magic 先置 0 再置值防半初始化读入
            mapped->magic = 0;
            mapped->slot = 0;
            mapped->color = 0;
            mapped->count = 0;
            mapped->avg = 0;
            mapped->ts = 0;
            mapped->pid = 0;
            __sync_synchronize();
            mapped->magic = 0x56435031u;
        }
    });
    return (mapped == MAP_FAILED) ? NULL : mapped;
}

// 1.3.79 总线写者仲裁(双写者根修): App 采样器与 SB 悬浮球是两套独立投票
// 状态机写同一条 mmap 总线 —— SB 的 applicationState 恒 Active(实锤:
// App 前台窗口 13:37:30-35 SB 仍在 pick cadence 翻转), 两套稳定色以
// ~100ms 周期交替写总线 → 光在 0x000000(灭)↔色 间高频翻转("时而打时而
// 不打")且每次变色触发 md 全帧重烘焙 → 视频掉帧。
// 仲裁规则: SB tick 前查总线 —— ts 新鲜(<300ms)且写者 pid≠本进程
// (= 前台 App 在采样) → SB 完全让位(不采样不发布); App 退后台后其
// ts 陈旧 → SB 自动恢复桌面检测。App 侧无需对称检查(非 Active 本就跳过)。
+ (BOOL)vcamBusHasLiveOtherWriter {
    VCamPickShm *shm = vcamPickShmMap();
    if (!shm) return NO;
    uint32_t wpid = shm->pid;
    double wts = shm->ts;
    if (wpid == 0 || (pid_t)wpid == getpid()) return NO;
    return (CFAbsoluteTimeGetCurrent() - wts) < 0.3;
}

// 写端: 采样器(App/SB 进程)调用; slot=色档, color=标准纯色(检测端自带);
// timestamp 最后写(seqlock 发布点)
+ (void)vcamPickPublishSlot:(int)slot color:(uint32_t)color count:(int)cnt avg:(uint32_t)avg {
    VCamPickShm *shm = vcamPickShmMap();
    if (!shm) return;
    __sync_synchronize();
    shm->slot = (uint32_t)MAX(0, MIN(6, slot));
    shm->color = color;
    shm->count = (uint32_t)cnt;
    shm->avg = avg;
    shm->pid = (uint32_t)getpid();
    __sync_synchronize();
    shm->ts = CFAbsoluteTimeGetCurrent();  // 8B 对齐原子写 = 发布点
}

// 读端: md 光轮询调用; 返回 YES = 总线新鲜(≤1s 有活跃采样), outColor 直接
// 是可打光的标准色(检测端已给, md 无需映射); NO = 无采样 → fallback plist。
+ (BOOL)vcamPickSharedColor:(uint32_t *)outColor count:(int *)outCount {
    if (outColor) *outColor = 0;
    if (outCount) *outCount = 0;
    VCamPickShm *shm = vcamPickShmMap();
    if (!shm || shm->magic != 0x56435031u) return NO;
    double t1 = shm->ts;
    uint32_t color = shm->color;
    uint32_t cnt = shm->count;
    double t2 = shm->ts;
    if (t1 != t2 || t1 <= 0) return NO;                    // 写撕裂
    if (CFAbsoluteTimeGetCurrent() - t1 > 1.0) return NO;  // 不新鲜
    if (outColor) *outColor = color;
    if (outCount) *outCount = (int)cnt;
    return YES;
}

// ===== 共享颜色匹配(算法从 VCamFloatingBall 移入, 供 SB/App 两侧共用) =====
// HSV 色相分档(1.3.46): [330,30)红 [30,90)黄 [90,150)绿 [150,210)青
// [210,270)蓝 [270,330)紫; V/S 门限 60 / 计票阈值 30(441 像素口径)。
// 1.3.69 回退原版逻辑(用户指令): 色表/门限全部内置常量, 检测命中直接
// 返回标准纯色 —— 不再经密钥 T 表中转(SB 端 T 表解密失败导致光永远
// 不亮的教训)。密钥体系只保留激活门禁(licGate 双变量), 不参与打光参数。
+ (uint32_t)vcamMatchKnownLightShared:(const uint8_t *)rgba
                                    n:(int)n
                            outBestIdx:(int *)outBestIdx
                               outCount:(int *)outCount
                                  outAvg:(uint32_t *)outAvg {
    if (outBestIdx) *outBestIdx = -1;
    if (outCount) *outCount = 0;
    if (outAvg) *outAvg = 0;
    if (!rgba || n <= 0) return 0;
    static const uint32_t kKnown[6] = {
        0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0x00FFFF, 0xFF00FF
    };
    const int hsvGate = 60;
    const int voteGate = 30;
    int counts[6] = {0};
    long sr = 0, sg = 0, sb = 0;
    for (int i = 0; i < n; i++) {
        int r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2];
        sr += r; sg += g; sb += b;
        int maxc = MAX(MAX(r, g), b), minc = MIN(MIN(r, g), b);
        int delta = maxc - minc;
        if (maxc < hsvGate || delta < hsvGate) continue;
        double h;
        if (maxc == r)      h = 60.0 * (double)(g - b) / (double)delta;
        else if (maxc == g) h = 60.0 * (2.0 + (double)(b - r) / (double)delta);
        else                h = 60.0 * (4.0 + (double)(r - g) / (double)delta);
        if (h < 0) h += 360.0;
        int idx;
        if (h < 30.0 || h >= 330.0)      idx = 0;
        else if (h < 90.0)               idx = 3;
        else if (h < 150.0)              idx = 1;
        else if (h < 210.0)              idx = 4;
        else if (h < 270.0)              idx = 2;
        else                             idx = 5;
        counts[idx]++;
    }
    if (outAvg) *outAvg = (uint32_t)(((sr / n) << 16) | ((sg / n) << 8) | (sb / n));
    int bestK = -1, bestC = 0;
    for (int k = 0; k < 6; k++) {
        if (counts[k] > bestC) { bestC = counts[k]; bestK = k; }
    }
    BOOL matched = (bestK >= 0 && bestC >= voteGate);
    if (outBestIdx) *outBestIdx = matched ? bestK : -1;
    if (outCount) *outCount = bestC;
    if (matched) {
        return kKnown[bestK];  // 标准纯色(内置, 原版行为)
    }
    return 0;
}

// ===== Darwin 通知颜色通道(1.3.65 沙盒保底上行) =====
// notify_post 走 notifyd XPC(公开 API), App 沙盒必放行 —— mmap 直写被
// 沙盒拒时的兜底。7 固定名(注册无通配): s0=熄灭, s1-s6=色档(匹配档位,
// 非色值 —— 色值由 SB 中继端查 T 表映射, App 端无需 T 表色值)。
static NSString *vcamPickSlotName(int slot) {
    return [NSString stringWithFormat:@"com.vcam.ios.p.s%d", slot];
}

+ (void)vcamNotifyPickSlot:(int)slot {
    if (slot < 0 || slot > 6) return;
    notify_post([vcamPickSlotName(slot) UTF8String]);
}

// ===== 配置下行(1.3.66: App 沙盒拒读 DCIM plist, cfgRead=0 实锤) =====
// SB → App 的取色配置(开关+坐标)也走 Darwin 通知: notify_set_state 携带
// 坐标(u64: X×10 低 20bit | Y×10 高 44bit), post 触发 App 端回调读取。
// 全链 notifyd XPC, App 沙盒必放行。
// 通知名: 开=com.vcam.ios.p.cfg1 关=com.vcam.ios.p.cfg0
static NSString *vcamPickCfgName(BOOL on) {
    return on ? @"com.vcam.ios.p.cfg1" : @"com.vcam.ios.p.cfg0";
}

+ (void)vcamPublishPickCfg:(BOOL)on X:(double)px Y:(double)py {
    static int cfgToken = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_dispatch([vcamPickCfgName(YES) UTF8String],
            &cfgToken, dispatch_get_main_queue(), ^(int t){ (void)t; });
    });
    if (on) {
        uint64_t state = ((uint64_t)(uint32_t)lround(px * 10) << 20)
                       | (uint64_t)(uint32_t)lround(py * 10);
        notify_set_state(cfgToken, state);
    }
    notify_post([vcamPickCfgName(on) UTF8String]);
}

// SB 端中继(Tweak.m initializeInSpringBoard 调用): 注册 7 名 → 收到 →
// 写 mmap 总线(色值由内置表映射, 原版逻辑, 不经 T 表)。App 每拍 post。
+ (void)vcamStartPickRelay {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const uint32_t kKnown[7] = {
            0x000000,  // slot 0: 熄灭
            0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0x00FFFF, 0xFF00FF
        };
        for (int slot = 0; slot <= 6; slot++) {
            int token = -1;
            int capturedSlot = slot;
            notify_register_dispatch([vcamPickSlotName(slot) UTF8String], &token,
                dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                ^(int t) {
                    (void)t;
                    [VCamNotify vcamPickPublishSlot:capturedSlot
                        color:kKnown[capturedSlot] count:0 avg:0];
                });
        }
        vcam_notify_log(@"[vcam][light] pick relay armed (7 slots, Darwin notify)");
    });
}

// ===== App 进程采样器 =====
// UICSI 函数指针(App 进程 UIKit 已加载, dlsym 直接命中)
typedef CGImageRef (*VcamUICreateScreenImageFn)(void);

// 进程内 UICSI 采样一拍: 截屏 → 全屏网格采样 → 分档匹配 → 色值直写总线。
// 1.3.69 原版逻辑回退: 命中档位直接映射内置标准纯色(不经 T 表) —— SB 端
// T 表解密失败的教训, 检测端自带完整色表, 光色在源头就正确。
// 1.3.68 遗产: 全屏最强色扫描(无坐标依赖), ≥12% 采样点同档才命中。
+ (int)vcamAppSampleSlotAtX:(double)px Y:(double)py {
    (void)px; (void)py;  // 全屏扫描, 坐标不再使用
    VcamUICreateScreenImageFn capFn =
        (VcamUICreateScreenImageFn)dlsym(RTLD_DEFAULT, "UICreateScreenImage");
    if (!capFn) return 0;
    // 1.3.89 崩溃根修(2026-09-01 相机 4 连崩实证): UICreateScreenImage 在
    // 照片模式/前后台切换等状态内部 __CFDictionaryCreateGeneric 抛 ObjC 异常,
    // 采样器跑在 dispatch block 里无兜底 → 未捕获异常 SIGABRT 杀死宿主 App。
    // 本拍失败返回 0(无色), 滑窗机制天然容忍个别拍丢失。
    @try {
    CGImageRef full = capFn();
    if (!full) return 0;
    size_t iw = CGImageGetWidth(full), ih = CGImageGetHeight(full);
    if (iw < 40 || ih < 40) { CFRelease(full); return 0; }
    // 全屏降采样: 缩到 32×64 网格(2048 采样点)
    const int GW = 32, GH = 64;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bctx = CGBitmapContextCreate(NULL, GW, GH, 8, GW * 4, cs,
                                              kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
    static const uint32_t kKnown[6] = {
        0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0x00FFFF, 0xFF00FF
    };
    int bestIdx = -1;
    int bestCnt = 0;
    if (bctx) {
        CGContextSetInterpolationQuality(bctx, kCGInterpolationLow);
        CGContextDrawImage(bctx, CGRectMake(0, 0, GW, GH), full);
        const uint8_t *rgba = (const uint8_t *)CGBitmapContextGetData(bctx);
        if (rgba) {
            // HSV 分档计票(60° 档, V/S 门限 60, 与共享算法同口径)
            const int n = GW * GH;
            int counts[6] = {0};
            for (int i = 0; i < n; i++) {
                int r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2];
                int maxc = MAX(MAX(r, g), b), minc = MIN(MIN(r, g), b);
                int delta = maxc - minc;
                if (maxc < 60 || delta < 60) continue;
                double h;
                if (maxc == r)      h = 60.0 * (double)(g - b) / (double)delta;
                else if (maxc == g) h = 60.0 * (2.0 + (double)(b - r) / (double)delta);
                else                h = 60.0 * (4.0 + (double)(r - g) / (double)delta);
                if (h < 0) h += 360.0;
                int idx;
                if (h < 30.0 || h >= 330.0)      idx = 0;  // 红
                else if (h < 90.0)               idx = 3;  // 黄
                else if (h < 150.0)              idx = 1;  // 绿
                else if (h < 210.0)              idx = 4;  // 青
                else if (h < 270.0)              idx = 2;  // 蓝
                else                             idx = 5;  // 紫
                counts[idx]++;
            }
            for (int k = 0; k < 6; k++) {
                if (counts[k] > bestCnt) { bestCnt = counts[k]; bestIdx = k; }
            }
            // 比例阈值: <12% = 噪声(零散 UI 元素) → 不命中
            if (bestCnt < n / 8) { bestIdx = -1; bestCnt = 0; }
        }
        CGContextRelease(bctx);
    }
    CGColorSpaceRelease(cs);
    CFRelease(full);
    // 1.3.69: 色档 + 内置色值一起上总线 —— 检测源头直接给正确色, md 端
    // 无需任何映射。slot 编号同时写(诊断/日志用)。
    uint32_t color = (bestIdx >= 0 && bestIdx < 6) ? kKnown[bestIdx] : 0;
    int slot = (bestIdx >= 0 && bestIdx < 6) ? bestIdx + 1 : 0;
    // 1.3.76 光稳定 v3(灭光跳动根修): 1.3.74 滑窗多数票把 slot=0(无色)和
    // 有色放在同一阈值竞争 —— 快速闪烁切换时过渡帧(混合色/暗帧)采样失败
    // → slot=0 混入滑窗, 周期性占到多数(≥8/12) → 灭光, 随后有效色又占
    // 多数 → 亮光 → 光"时而打时而不打"(设备实测症状)。
    // 修: 有色与无色不对称判定 ——
    //   有色: 最近 12 拍(480ms@25Hz)里某色占 ≥8 拍才切换(维持 1.3.74)
    //   无色: 必须连续 8 拍(320ms)全部无色才灭光 —— 闪烁期窗内总夹着
    //         有效色拍, 连 0 被打断 → 光钉住永不灭; 光源真正消失
    //         320ms 后才灭(与前版本灭光时延一致)
    // 1.3.77 采样降频 25→12.5Hz(发热根修): UICreateScreenImage 全屏捕获
    // 是 App 进程 CPU 大头; 打光已有滑窗投票保持稳定, 无需高频跟踪闪烁。
    // 窗口等比缩短: 12 拍@40ms → 6 拍@80ms, 时序语义完全不变。
    static int sWin[6] = {0};     // 滑窗原始 slot(初值 0=无色)
    static int sWinPos = 0;
    static int sStableSlot = -2;  // 已发布的稳定 slot
    static int sZeroRun = 0;      // 连续无色(0)拍数
    sWin[sWinPos] = slot;
    sWinPos = (sWinPos + 1) % 6;
    if (slot >= 1 && slot <= 6) {
        sZeroRun = 0;             // 有效色拍打断连续无色计数
        int cnt[7] = {0};         // slot 1..6 有色计票
        for (int i = 0; i < 6; i++) {
            if (sWin[i] >= 1 && sWin[i] <= 6) cnt[sWin[i]]++;
        }
        int majSlot = 0, majCnt = 0;
        for (int s = 1; s <= 6; s++) {
            if (cnt[s] > majCnt) { majCnt = cnt[s]; majSlot = s; }
        }
        if (majCnt >= 4 && majSlot != sStableSlot) {
            sStableSlot = majSlot;  // 窗内 ≥4/6 过半: 确认切换
        }
    } else {
        // 无色滞回(硬条件): 连续 4 拍(320ms)全无色才灭, 单拍/交替混入的 0 无效
        if (sZeroRun < 4) sZeroRun++;
        if (sZeroRun >= 4 && sStableSlot != 0) {
            sStableSlot = 0;        // 连续 320ms 无任何有效色: 真消失, 灭光
        }
    }
    int outSlot = (sStableSlot >= 0 && sStableSlot <= 6) ? sStableSlot : 0;
    uint32_t outColor = (outSlot >= 1 && outSlot <= 6) ? kKnown[outSlot - 1] : 0;
    [self vcamPickPublishSlot:outSlot color:outColor count:bestCnt avg:0];
    // 通道B: Darwin slot 通知 —— 每拍 post(25Hz 心跳): relay 每次收到都写
    // 总线刷新时间戳, 颜色稳定也能保活新鲜度(1s 窗口)
    [self vcamNotifyPickSlot:outSlot];
    return outSlot;
    } @catch (NSException *e) {
        // 兜底: UICSI 内部异常不吃帧语义, 返回 0(无色拍)
        return 0;
    }
}

// App 采样器入口(Tweak.m constructor App 分支调用):
// 主队列 timer 0.04s → 判 Active(前台才采样) → 后台串行队列采样。
// 1.3.67 配置改 Darwin cfg 通道: App 沙盒拒读 DCIM plist(cfgRead=0 实锤),
// SB 端开/关取色时 vcamPublishPickCfg post(开关) + set_state(坐标) →
// 本端注册 cfgOn/cfgOff 回调更新 static 配置。全链沙盒安全。
+ (void)vcamStartAppSampler {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 配置(Darwin cfg 回调更新; 初始关)
        static BOOL cfgEn = NO;
        static double cfgPx = 0, cfgPy = 0;
        __block int diagCfg = 0;      // 收到 cfgOn 次数
        __block int diagSamp = 0;     // 采样执行次数
        __block int diagMmap = 0;     // mmap 总线写成功次数
        __block int diagLastSlot = -1;
        int onToken = -1, offToken = -1;
        notify_register_dispatch([vcamPickCfgName(YES) UTF8String], &onToken,
            dispatch_get_main_queue(), ^(int t) {
                uint64_t state = 0;
                notify_get_state(onToken, &state);
                cfgPx = (double)((state >> 20) & 0xFFFFF) / 10.0;
                cfgPy = (double)(state & 0xFFFFF) / 10.0;
                cfgEn = YES;
                diagCfg++;
                (void)t;
            });
        notify_register_dispatch([vcamPickCfgName(NO) UTF8String], &offToken,
            dispatch_get_main_queue(), ^(int t) {
                cfgEn = NO;
                (void)t;
            });

        // 1.3.89 采样耗时 EMA + 跳拍计数(跨 block 静态, 采样队列写/主队列读)
        static double sSampDurEma = 0;
        static int sSampSkipLeft = 0;
        dispatch_queue_t sampQ = dispatch_queue_create("com.vcam.samp", NULL);
        dispatch_source_t timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        // 1.3.77 降频 25→12.5Hz(发热根修): UICreateScreenImage 全屏捕获 +
        // 降采样缩放是 App 进程 CPU/整机发热主力; 打光有滑窗投票保稳定,
        // 检测延迟 +40ms 人眼无感。总线心跳(保活 1s 窗口)12.5Hz 仍充裕。
        dispatch_source_set_timer(timer,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
            (uint64_t)(0.08 * NSEC_PER_SEC), (uint64_t)(0.02 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            // 前台判定: 后台/锁屏/分屏非 Active → 跳过(SB 是桌面模式的写者)
            UIApplication *app = [UIApplication sharedApplication];
            if (!app || app.applicationState != UIApplicationStateActive) return;
            if (!cfgEn) return;
            // 1.3.89 CPU 自适应退避(17:46 Camera cpu_resource 97% 实证):
            // 相机照片模式等重绘场景 UICSI 单拍可达 ~77ms(全屏捕获与实时
            // 预览合成竞争), 12.5Hz 全速跑 = 采样器独占一整核 → 宿主 App
            // 超 CPU 配额被杀。按采样耗时 EMA 跳拍, 采样器 CPU 上限 ~30%:
            //   ema>160ms 隔5拍(~2Hz) / >80ms 隔2拍(~4Hz) / >40ms 隔1拍(~6Hz)
            // 滑窗投票是按拍数(非绝对时间)判定, 跳拍只拉长响应不改语义。
            if (sSampSkipLeft > 0) { sSampSkipLeft--; return; }
            if (sSampDurEma > 0.16) sSampSkipLeft = 5;
            else if (sSampDurEma > 0.08) sSampSkipLeft = 2;
            else if (sSampDurEma > 0.04) sSampSkipLeft = 1;
            dispatch_async(sampQ, ^{
                // 1.3.89 后台竞态二次判定(18:54 相机后台崩溃实证): 主队列
                // 判定后 App 可能已切入后台, UICSI 在后台 App 直接抛异常。
                // 采样队列执行前再查一次, 竞态窗口内直接放弃本拍。
                UIApplication *app2 = [UIApplication sharedApplication];
                if (!app2 || app2.applicationState != UIApplicationStateActive) return;
                CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
                @try {
                    diagLastSlot = [self vcamAppSampleSlotAtX:cfgPx Y:cfgPy];
                    diagSamp++;
                } @catch (NSException *e) {
                    // 双保险: 采样内部异常也不允许杀死宿主
                }
                double dur = CFAbsoluteTimeGetCurrent() - t0;
                sSampDurEma = (sSampDurEma > 0) ? (sSampDurEma * 0.7 + dur * 0.3) : dur;
                if (vcamPickShmMap() != NULL) diagMmap++;
            });
        });
        dispatch_resume(timer);
        static dispatch_source_t keepTimer = nil;
        keepTimer = timer;  // 静态持有(进程生命周期, ARC strong)
        // 沙盒诊断: 每 5s 落 App 容器 tmp(独立全局队列, SSH 可扫容器 tmp)
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            while (YES) {
                [NSThread sleepForTimeInterval:5.0];
                @try {
                    NSString *dp = [NSTemporaryDirectory()
                        stringByAppendingPathComponent:@"vcampick_diag.txt"];
                    NSString *line = [NSString stringWithFormat:
                        @"[%@] cfg=%d samp=%d mmap=%d lastSlot=%d px=%.0f py=%.0f pid=%d\n",
                        [NSDate date], diagCfg, diagSamp,
                        diagMmap, diagLastSlot, cfgPx, cfgPy, getpid()];
                    [line writeToFile:dp atomically:YES
                              encoding:NSUTF8StringEncoding error:nil];
                } @catch (NSException *e) {}
            }
        });
        vcam_notify_log(@"[vcam][light] app sampler started (Darwin cfg + UICSI + slot bus)");
    });
}

@end
