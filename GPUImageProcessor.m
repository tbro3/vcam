//
//  GPUImageProcessor.m
//  VCamPlus
//
//  对标 vcameracrack.dylib 的 GPUImageProcessor 实现
//

#import "GPUImageProcessor.h"
#import "VCamNotify.h"
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

// 手动声明 VideoToolbox 类型和函数（不依赖 SDK 头文件，避免类型冲突）
typedef struct OpaqueVTPixelTransferSession *VTPixelTransferSessionRef;
typedef struct OpaqueVTPixelRotationSession *VTPixelRotationSessionRef;
OSStatus VTPixelTransferSessionCreate(CFAllocatorRef, VTPixelTransferSessionRef *);
OSStatus VTPixelTransferSessionTransferImage(VTPixelTransferSessionRef, CVPixelBufferRef, CVPixelBufferRef);
OSStatus VTSessionSetProperty(CFTypeRef session, CFStringRef propertyKey, CFTypeRef propertyValue);

// VTPixelRotationSession 私有 API 函数指针类型
typedef OSStatus (*VTPixelRotationSessionCreateFunc)(CFAllocatorRef, VTPixelRotationSessionRef *);
typedef OSStatus (*VTPixelRotationSessionTransferImageFunc)(VTPixelRotationSessionRef, CVPixelBufferRef, CVPixelBufferRef);

// 日志全局限速令牌桶(定义在 VCamCore.m, 全进程共享磁盘写入预算 —— 磁盘配额击杀根治)
extern BOOL vcam_log_budget_take(void);

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

static void vcam_gpu_log(NSString *msg) {
    if (!vcam_log_enabled()) return;
    if (!vcam_log_budget_take()) return;
    @try {
        NSString *logPath = @"/tmp/vcam_gpu_log.txt";
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

@interface GPUImageProcessor ()
// 会话（VT session 非线程安全且内部缓存 pipeline 状态, 必须按用途隔离）
// 对齐千面 render 逆向(0xb0f8-0xb154): 按目标格式三套 session
//   BGRA 目标 -> 专用 session(千面 _0xe8) / 420v/420f 目标 -> 专用 session(千面 _0xf0)
//   其他私有格式(|8v0/-8f0/p420 等) -> base session(千面 _0x30), 千面对所有格式无白名单全 transfer
@property (nonatomic, assign) VTPixelTransferSessionRef bgraTransferSession;       // render 线程: BGRA 目标专用
@property (nonatomic, assign) VTPixelTransferSessionRef yuvTransferSession;        // render 线程: 420v/420f 目标专用
@property (nonatomic, assign) VTPixelTransferSessionRef privateTransferSession;    // render 线程: 私有格式目标专用(base, 隔离状态)
@property (nonatomic, assign) VTPixelTransferSessionRef prerenderTransferSession;  // 预渲染线程专用

// ===== 千面模型固定车道(2026-08-19 相机开启猝死链路根治) =====
// 设备实证(1.2.4, 13:48:42-13:49:02): 相机开启多流突发时 mediaserverd 4 连崩,
// 无 .ips/无 CPU 超限 —— 根因是 per-key 池体系在热路径现场建 session/建 12MB
// staging + LRU 淘汰重建 + 全局组锁串行, 相机回调线程阻塞 → Apple watchdog 杀。
// 千面(唯一稳定参照)只有 3 个全局 session: 永不冷启动/永不重建/零抖动。
// 本体系对齐: 固定 3 车道 + 单一 grow-only 中转 + 全局 token 复用 + 按格式熔断。
// 旧 per-key/组共享/结果缓存体系整体退役(热路径不再触达, 池保持空)。
@property (nonatomic, strong) NSLock *laneLockBGRA;        // BGRA 车道锁
@property (nonatomic, strong) NSLock *laneLockYUV;         // 420f/420v/p420 车道锁
@property (nonatomic, strong) NSLock *laneLockPrivate;     // 私有格式两步法车道锁(含 s1)
@property (nonatomic, assign) VTPixelTransferSessionRef twoStepS1Session;  // 420f→BGRA 专用(与 prerender session 隔离)
// staging 按源尺寸缓存(2026-08-19 交替重建风暴修复): 源帧最多 2 种尺寸
// (原始 720x538 与 CCW90 旋转后 538x720 并存), 旧 grow-only 单 staging 在两种
// 尺寸间互相触发重建 → 每帧 12MB 创建/释放风暴 → 相机线程卡死 → msd 被杀
// (设备实证: 同秒 "Lane staging built" 交替 20 次)。按源尺寸 key 缓存(上限 4),
// 每尺寸建一次后零重建。
// 卡顿优化(2026-08-19): 字典版每帧 NSNumber 装箱 + 双字典查找(且在串行车道锁内),
// 改定长槽位数组纯指针比较 —— 零分配; (w,h,token) 全部原值存取。
// (定义见 @interface 之后的文件级区: gVcamLaneStaging)
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *laneFailCounts;   // 格式 fourcc → 连续失败
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *laneDisabled;     // 格式 fourcc → 熔断标记
// 私有格式两步法中转: 已迁移到下方 per-key 池(2026-08-15), 旧单例字段移除
// 两步法按流池化(2026-08-15): 相机多条流(预览/照片/录像)目标尺寸各异,
// 共用一个 session/staging 交替不同尺寸 → VT 内部 pipeline 状态污染 → 偶发
// -12905 → writeFrame NO → 替换画面中断(黑屏/闪回相机)。
// session/staging/token 按 "dstW_dstH_fmt" 独立, 各流互不干扰
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *twoStepSessionPool;    // key -> session 指针
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *twoStepStagingPool;    // key -> CVPixelBufferRef 指针(池持有引用)
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *twoStepTokenPool;     // key -> staging 内容帧代数
// 2step 失败熔断(2026-08-15, App 相机黑屏根因): App 摄像头带 328x184 '18f0' 微型分析流,
// VT 不支持该组合(-12905), 高频流上"失败→重建 session→再失败"每秒 8 次 → mediaserverd
// wakeups 资源超限被杀 → 死循环重启(6s/次) → 所有相机黑屏。
// 同 key 连续失败 ≥2 次即熔断: 永久跳过该流两步法(保留相机原帧, 分析流无视觉影响),
// 不再创建/销毁 session
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *twoStepFailCountPool; // key -> 连续失败计数
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *twoStepDisabledPool;  // key -> 熔断标记

// 按流并行体系(2026-08-16 自研优化: VT 会话+锁全部 per-stream):
// 旧版一步 transfer 按格式 3 把锁 —— 同格式的多条流(如 QQ 两条 420f 流)共用
// 一个 session 串行执行, 多流场景 render 排队延迟大。现改为 per-(w,h,fmt) 池化:
// 每条流独立 session + 独立锁, 全部流完全并行 VT transfer。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *oneStepSessionPool;   // key -> session
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSLock *> *oneStepKeyLockPool;   // key -> lock
@property (nonatomic, strong) NSLock *rotationRenderLock;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSLock *> *twoStepKeyLockPool;

// ===== 前置多流卡顿优化(2026-08-17 实测数据驱动) =====
// 实测(微信/抖音等 App 前置): 4-5 条流并发, 3 条私有格式全走两步法 →
// CPU 65-86% 两次触发紧急降载 → 内容 24↔20fps 摆动 = 前置卡顿(后置仅 2 流 30-40% 无此问题)。
// 两个成本炸弹:
//   1) 2304x1650 照片流渲染率 94fps(30s 2825 帧): 同一相机帧过 emit/scaler/encoder
//      三节点, buffer 不同去重失效 → 同 token 重复全价转换 3 次(s2 5.7ms x3)
//   2) 2112x1584 流 s1=8.7-12.9ms 无复用(渲染率 26fps ≈ 内容率 24fps, 几乎每帧新 token)
// 修复:
//   A) 组 staging: 同比例家族(量化 0.1%)的私有格式流共享一个最大尺寸 BGRA
//      中转, s1(缩放)每帧每组只付一次, 各流 s2 从组 staging 直转/缩转
//   B) s2 结果缓存: 同 key 同 token 第二次消费起, 全价转换进自有缓存 buffer,
//      后续消费 VT 同格式 blit(~1-2ms)复用 —— 三消费链只付一次全价
//      (私有→私有 blit 未实证, 失败一次即熔断该 key 回直转, 无风暴风险)
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *groupStagingPool;   // "g:1333" -> BGRA buffer
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *groupTokenPool;    // 组内容帧代数
@property (nonatomic, strong) NSLock *groupGlobalLock;   // 全局组锁: 组资源(staging/session/token)读写互斥。
// 不用 per-ratio 组锁的原因: 懒建锁对象自身有并发竞态(两线程各建一把锁互相不见),
// 且 LRU 淘汰持组锁与 @synchronized 的锁序复杂化。组数极少(1-2 个比例家族),
// s1 每帧每组仅一次(~24 次/s), 全局锁竞争可忽略
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *groupSessionPool;   // 组 s1 session
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *groupSizePool;     // 组 staging 像素量(取组内最大)
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *resultCachePool;    // 流 key -> 私有格式结果缓存
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *resultBlitSessionPool; // 流 key -> 专用 blit session(私有→私有, 与全价 session 隔离防 pipeline 反复切换)
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *resultCacheTokenPool; // 缓存内容帧代数
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *lastReqTokenPool;  // 上次请求 token(检测重复消费)
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *resultBlitDisabledPool; // blit 熔断
@property (nonatomic, assign) VTPixelRotationSessionRef pixelRotationSession;
// render 路径专用旋转 session（非线程安全: 预渲染线程与 render 线程并发用同一 session 会崩溃）
@property (nonatomic, assign) VTPixelRotationSessionRef renderRotationSession;
// 自适应旋转 buffer 缓存（按 尺寸+格式 复用, 避免拍照流每帧创建 ~3MB buffer; 仅 renderLock 内访问）
@property (nonatomic, assign) CVPixelBufferRef adaptiveRotateCache;
@property (nonatomic, assign) size_t adaptiveRotateCacheW;
@property (nonatomic, assign) size_t adaptiveRotateCacheH;
@property (nonatomic, assign) OSType adaptiveRotateCacheFmt;
// 旋转结果帧代数: 同一帧(token)多流渲染时只 rotate 一次, 后续流直接复用
@property (nonatomic, assign) uint64_t adaptiveRotatedGen;
// 流 key LRU 顺序(2026-08-16 黑屏修复): per-key 池(session+staging 12MB 级 buffer)
// 无上限增长 —— App 切前后摄/分辨率/多流组合变化时 key 只增不减, 内存缓慢累积 →
// mediaserverd 内存超限被杀 → 相机黑屏(重进恢复=重启清零, 再累积再黑, 周期循环)。
// 超 kVcamMaxStreamKeys 淘汰最久未用 key(释放 session+staging), 熔断标记保留
@property (nonatomic, strong) NSMutableArray<NSString *> *streamKeyOrder;
// 死锁修复(2026-08-17 graph-stop watchdog 根因): 统计/池字典专用最内层锁。
// 锁序规则: @synchronized(self) / per-key lock -> _statsLock/_poolDictLock, 永不反向。
// 之前 noteStageTiming 在持 keyLock 的 transfer 路径内进 @synchronized(self), 而
// touchStreamKeyLRU 持 @synchronized(self) 再 lock keyLock(evict) —— 锁倒置互等死锁:
// emitSampleBuffer 永不返回 -> capture graph stop drain 超时 5s -> watchdog 杀
// mediaserverd("Timed out waiting for the capture graph to stop") -> 崩溃循环。
@property (nonatomic, strong) NSLock *statsLock;
@property (nonatomic, strong) NSLock *poolDictLock;
// (按流渲染统计定长槽位 gVcamStatSlots 见 @interface 外文件级定义)

// 私有 API 函数指针
@property (nonatomic, assign) VTPixelRotationSessionCreateFunc createRotationSession;
@property (nonatomic, assign) VTPixelRotationSessionTransferImageFunc transferRotationImage;
// 千面逆向确认(0xb094/0xe598): 属性是 kVTPixelRotationPropertyKey_Rotation,
// 值是 CFString 常量 kVTRotation_CCW90/CW90/180 (不是 RotationInDegrees + 数字!)
@property (nonatomic, assign) CFStringRef rotationPropertyKey;
@property (nonatomic, assign) CFStringRef rotationCCW90Value;
@property (nonatomic, assign) CFStringRef rotationCW90Value;
@property (nonatomic, assign) CFStringRef rotation180Value;
@property (nonatomic, assign) CFStringRef flipHorizontalKey;

// 预渲染几何输出 3 槽轮转 buffer(仅预渲染线程访问, 旋转与 mirror-only 镜像共用):
// 旋转若每帧 CVPixelBufferCreate ~3MB(1080p 420f) = 30fps 下 90MB/s 分配释放,
// malloc 压力 + 内存碎片 → 卡顿/不稳。live 缓存 + render fallback + in-flight
// transfer 最多同时持有 2 帧旧输出, 3 槽轮转保证写入槽不被任何读者持有。
// 独立镜像池已删(2026-08-18 砍常驻内存): mirror-only 借本槽 copy+原地反转,
// 省 3 帧常驻(720p 420f ~4MB / BGRA ~11MB), 对齐千面 footprint 水平
@property (nonatomic, assign) CVPixelBufferRef prerenderRotatePool0;
@property (nonatomic, assign) CVPixelBufferRef prerenderRotatePool1;
@property (nonatomic, assign) CVPixelBufferRef prerenderRotatePool2;
@property (nonatomic, assign) int prerenderRotateSlot;
// (hasAdaptiveRotated latch 已随 manualComp 补偿回滚一并删除 —— 该补偿实证错误)

// 用户画面变换画布池(2026-08-23 箭头/＋/−/复): 黑底画布 3 槽轮转
// (live/snapshot/render fallback 持有期与预渲染写入错开, 同旋转池模式)
// zoom>1 时画布=源窗口尺寸(W/z, 纯 memcpy 零重采样, 下游 Trim 放大);
// zoom<=1 时画布=源原尺寸(黑底+画面区域, 平移出界露黑)
@property (nonatomic, assign) CVPixelBufferRef userCanvasPool0;
@property (nonatomic, assign) CVPixelBufferRef userCanvasPool1;
@property (nonatomic, assign) CVPixelBufferRef userCanvasPool2;
@property (nonatomic, assign) int userCanvasSlot;
// 变换中间 piece(预渲染线程同步用, 无跨帧持有):
// userShrinkBuffer = pieceA(源裁剪 1:1), userPieceBuffer = pieceB(VT 缩放后)
@property (nonatomic, assign) CVPixelBufferRef userShrinkBuffer;
@property (nonatomic, assign) CVPixelBufferRef userPieceBuffer;
// bake 专用 VT session(2026-08-24 视频模式黑屏根治): 绝不能复用
// _prerenderTransferSession —— render 线程的懒 BGRA 回退(convertFormat:)与
// 预渲染线程 bake 并发调用同一 session(VT session 非线程安全) → IOFence
// 死锁 → backboardd GPU 崩溃(实测 "blocked by IOFence" ×4) → mediaserverd
// 挂死 → 相机全黑。视频模式(encoder 私有格式流)必触发懒回退, 照片模式不触发,
// 与"仅视频模式黑屏"现象完全吻合
@property (nonatomic, assign) VTPixelTransferSessionRef userTransferSession;

// 三色打光注入画布池(1.3.37): 3 槽轮转(同 userCanvas 模式, live/render 持有期
// 与预渲染写入错开)。注入必须写副本 —— baked 可能是旋转池/bake 画布的复用 buffer,
// 直接注入会污染缓存池(下一帧复用时残留光斑)。关闭时直通零开销不建画布。
@property (nonatomic, assign) CVPixelBufferRef lightCanvasPool0;
@property (nonatomic, assign) CVPixelBufferRef lightCanvasPool1;
@property (nonatomic, assign) CVPixelBufferRef lightCanvasPool2;
@property (nonatomic, assign) int lightCanvasSlot;

// CIContext（软件渲染，mediaserverd 没有 GPU 上下文）
// 两个独立 CIContext: 预渲染线程用 preprocessContext, render 线程回退用 renderContext（CIContext 非线程安全）
@property (nonatomic, strong) CIContext *preprocessContext;
@property (nonatomic, strong) CIContext *renderContext;

// ===== GPU 渲染路径(2026-08-16 多流 1080p CPU 超配额最终解) =====
// 背景: 纯 CPU VT 下 5-7 条 1080p 级相机流(含 1080x2340 屏幕流)替换总 CPU 85-175%,
// 远超 daemon 50% 配额 → 冻结机制也压不住(stage1 内容更新成本固有大) → 被杀循环。
// mediaserverd 是相机/显示管线宿主, 内部本就使用 Metal —— 旧注释"没有 GPU 上下文"
// 是未验证的假设。probe MTLCreateSystemDefaultDevice, 可用则 GPU CIContext 直接
// crop-fill 渲染到标准格式(BGRA/420f/420v)相机帧: 一次 GPU 提交(CPU ~1ms)替代
// 全量 CPU VT 转换(8-10ms)。私有格式流(-8f0 等 IOSurface Metal 不认识)保持 VT。
@property (nonatomic, strong) CIContext *ciGPUContext;
@property (nonatomic, assign) BOOL metalAvailable;
// GPU 路径 per-key CIImage 缓存: (key, token) 相同 → 变换结果直接复用, 冻结帧零重建
// (调用方已持该 key 的 per-key 锁, 池字典自身用 @synchronized 保护)
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *gpuImgTokenPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CIImage *> *gpuImgOutPool;
// 每流 stage 耗时统计已并入定长槽位 gVcamStatSlots(见文件头)
// 一步直转熔断(2026-08-17 统一路径配套): 连续失败 2 次的流永久跳过(保真实相机)
// —— 替代两步法时代的 twoStepDisabledPool 职责('18f0' wakeups 风暴教训)
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *oneStepFailPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *oneStepDisabledPool;

// 缓冲池字典（key="w_h", value=CVPixelBufferPoolRef）—— 每个尺寸独立池，避免频繁重建
@property (nonatomic, strong) NSMutableDictionary *bgraBufferPoolMap;

// 内部方法（前向声明，让 ARC 正确处理 CF_RETURNS_RETAINED）
- (CVPixelBufferRef)scaleToBGRA:(CVPixelBufferRef)input width:(size_t)width height:(size_t)height CF_RETURNS_RETAINED;
@end

// ===== 文件级零分配数据结构(2026-08-19 卡顿优化) =====
// 按流渲染统计定长槽位: 旧字典实现每帧每流 ~5 次 NSString 分配 + NSNumber 装箱
// + 字典写(且在车道锁内), 8 流 × 30fps = 每秒数百次分配/malloc 争用 = 渲染
// 延迟毛刺。改纯数字累计, takeStreamStats 30s 出字符串。
// (文件级静态: 每进程仅一个 GPUImageProcessor 实例, 统计是纯诊断用途)
typedef struct {
    uint32_t fmt;
    uint32_t w, h;
    uint64_t renders;
    uint64_t pixels;
    double   s1TotalMs;
    uint64_t s1Cnt;
    double   s2TotalMs;
    uint64_t s2Cnt;
} VCamStatSlot;
#define kVcamStatSlots 12
static VCamStatSlot gVcamStatSlots[kVcamStatSlots];

// 私有车道 staging 定长槽位(替代 laneStagingMap/laneTokenMap 两个字典):
// 每帧 NSNumber 装箱 + 双字典查找(串行车道锁内) → 纯指针比较零分配。
// 全部访问都在 _laneLockPrivate 临界区内, dealloc/idle 释放例外(进程级单实例安全)。
typedef struct {
    size_t w, h;
    CVPixelBufferRef staging;   // 所有权归槽位(槽位占用即持有)
    uint64_t token;             // staging 内容的帧代数
} VCamLaneStagingSlot;
#define kVcamLaneStagingMax 4
static VCamLaneStagingSlot gVcamLaneStaging[kVcamLaneStagingMax];

// 绿线修复 v2: per-ratio 预裁剪 staging 槽(非整数 crop 流专用)。
// 调用方持 _laneLockPrivate; lastUse 做 LRU(极端多比例族时淘汰最久未用)
typedef struct {
    size_t w, h;
    CVPixelBufferRef staging;
    uint64_t token;         // 源 staging 的帧代数(同帧跳过 memcpy)
    CFAbsoluteTime lastUse;
} VCamCropStagingSlot;
#define kVcamCropStagingMax 4
static VCamCropStagingSlot gVcamCropStaging[kVcamCropStagingMax];
// Normal 等比缩放 session(预裁剪路径专用, 进程级懒建, 锁内调用)
static VTPixelTransferSessionRef gVcamNormalSession = NULL;

// 发热优化(2026-08-20): 私有格式 YUV 域上采样中转槽。
// 设备遥测实证: |xv0 流 BGRA→私有 3MP 上采样+RGB→YUV = 8.1ms/帧(×24fps≈19% CPU,
// 发热主热点); 而 p420 流 420f→p420 YUV 域直转同量级输出仅 2.8ms。
// 拆两段: RGB→YUV 在源分辨率完成(~1ms), 上采样走同格式缩放(YUV 域快路径 ~3ms)。
// 设备实证#2(2026-08-20 1.3.7): BGRA→私有 **同尺寸**直转 -12905 —— 私有格式
// 写入仅走缩放路径 → mid 必须与源有尺寸差(源+2 微拉伸 <0.3% 不可见)。
// 设备实证#3(2026-08-20 1.3.8): probeDst(2304x1296 |xv0)创建失败走静默路径。
// v3: 去掉探针 buffer —— 首帧直接在真实相机 dst 上试跑全链, s2b 失败同帧内
// direct 立即重写 dst(同一 render 调用, fence 顺序化无闪烁), 并 memo 永久回退;
// s2a/mid创建失败同样 memo。任何失败都有错误码日志(可诊断)。
typedef struct {
    uint32_t fmt;               // 私有目标格式(|xv0/-8f0/|8v0...)
    size_t w, h;                // mid 尺寸(= 源+2, 强制缩放路径)
    CVPixelBufferRef staging;   // 私有格式 @ mid 尺寸
    uint64_t token;             // 内容帧代数(同帧多流共享跳过 s2a 转换)
    CFAbsoluteTime lastUse;
} VCamYuvStagingSlot;
#define kVcamYuvStagingMax 4
static VCamYuvStagingSlot gVcamYuvStaging[kVcamYuvStagingMax];

// 拆段支持 memo(进程级 per-format): 0=未探测(允许首试) -1=不可用(永久直转)。
// s2a/mid创建/s2b 任一失败即 memo=-1, 此后零重试零日志(1.3.7 每帧重试教训)
static uint32_t gVcamYuvSplitFmt[4] = {0, 0, 0, 0};
static int8_t gVcamYuvSplitOk[4] = {0, 0, 0, 0};
static int8_t vcamYuvSplitState(uint32_t fmt) {
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvSplitFmt[i] == fmt) return gVcamYuvSplitOk[i];
    }
    return 0;  // 未登记: 允许首试
}
static void vcamYuvSplitDisable(uint32_t fmt) {
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvSplitFmt[i] == fmt) { gVcamYuvSplitOk[i] = -1; return; }
    }
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvSplitFmt[i] == 0) { gVcamYuvSplitFmt[i] = fmt; gVcamYuvSplitOk[i] = -1; return; }
    }
}

// 直转快路径 memo(2026-08-24 视频模式帧率优化, 进程级 per-format):
// 0=未探测(允许首试) 1=YUV→私有直转可用(恒走直转) -1=回退(YUV staging/
// BGRA 两步法)。拆段 v3 同款模式: 首帧真实 dst 试跑。
// 失败延迟重试(1.3.36): -12902/-12905 可能是启动竞态(会话刚建/首帧
// buffer 状态特殊)而非格式永久不支持 —— 失败 30s 后允许重试, 最多 3 次
// 防每帧重试风暴; 重试窗口期 getter 返回 0(视为未探测)。
static uint32_t gVcamYuvDirectFmt[4] = {0, 0, 0, 0};
static int8_t gVcamYuvDirectOk[4] = {0, 0, 0, 0};
static uint8_t gVcamYuvDirectFails[4] = {0, 0, 0, 0};
static CFAbsoluteTime gVcamYuvDirectFailAt[4] = {0, 0, 0, 0};
static int8_t vcamYuvDirectState(uint32_t fmt) {
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvDirectFmt[i] == fmt) {
            if (gVcamYuvDirectOk[i] == -1 &&
                gVcamYuvDirectFails[i] < 3 && gVcamYuvDirectFailAt[i] > 0 &&
                (CFAbsoluteTimeGetCurrent() - gVcamYuvDirectFailAt[i]) > 30.0) {
                return 0;  // 重试窗口: 允许再试
            }
            return gVcamYuvDirectOk[i];
        }
    }
    return 0;  // 未登记: 允许首试
}
static void vcamYuvDirectSet(uint32_t fmt, int8_t ok) {
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvDirectFmt[i] == fmt) {
            if (ok == -1) {
                gVcamYuvDirectFails[i]++;
                gVcamYuvDirectFailAt[i] = CFAbsoluteTimeGetCurrent();
            }
            gVcamYuvDirectOk[i] = ok; return;
        }
    }
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvDirectFmt[i] == 0) {
            gVcamYuvDirectFmt[i] = fmt; gVcamYuvDirectOk[i] = ok;
            if (ok == -1) {
                gVcamYuvDirectFails[i] = 1;
                gVcamYuvDirectFailAt[i] = CFAbsoluteTimeGetCurrent();
            }
            return;
        }
    }
}

// YUV staging 两步法 memo(1.3.36 帧率优化 v2, 进程级 per-format):
// 0=未探测 1=可用(YUV→420f→私有) -1=不可用(回退 BGRA 两步法)。
// 动机: 直转失败的私有流走 YUV→BGRA→私有 ~21ms/帧, BGRA 中转(RGB
// 转换 ~13ms)是 CPU 大头; 420f 中转纯 YUV 域 ~1-2ms + 缩放段 ~3-8ms。
// staging 是自建干净 buffer(无 cleanAperture 附件), s2' 与直转同款
// VT 操作但源参数干净, 可能绕过直转的 -12902/-12905 限制。
static uint32_t gVcamYuvStageFmt[4] = {0, 0, 0, 0};
static int8_t gVcamYuvStageOk[4] = {0, 0, 0, 0};
static int8_t vcamYuvStageState(uint32_t fmt) {
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvStageFmt[i] == fmt) return gVcamYuvStageOk[i];
    }
    return 0;  // 未登记: 允许首试
}
static void vcamYuvStageSet(uint32_t fmt, int8_t ok) {
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvStageFmt[i] == fmt) { gVcamYuvStageOk[i] = ok; return; }
    }
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvStageFmt[i] == 0) { gVcamYuvStageFmt[i] = fmt; gVcamYuvStageOk[i] = ok; return; }
    }
}

// YUV 中转 staging 槽(源尺寸 420f): 按 (w,h) 缓存, token 复用同帧多消费者
typedef struct {
    size_t w, h;
    CVPixelBufferRef staging;
    uint64_t token;
} VCamYuvLaneSlot;
#define kVcamYuvLaneMax 4
static VCamYuvLaneSlot gVcamYuvLane[kVcamYuvLaneMax];

// 车道熔断 memo: 热路径零装箱查表; 熔断写入时刷新对应槽
// 1.3.48 熔断自动恢复: 旧版 CIRCUIT-BROKEN 永久禁用(进程重启前 keep camera
// 永不替换) —— 设备实证(14:38:19 p420 熔断后 0x7c787630 流全部 keep camera
// = "相机不替换"直接来源)。-12902/-12905 失败常是时序/尺寸组合临时性
// (视频切换/会话竞态), 永久熔断过于激进。改: 熔断 30s 后自动重试;
// 失败计数成功时清零(旧版只增不减, 隔很久的 2 次失败也误熔断)
static uint32_t gVcamLaneMemoFmt[4] = {0, 0, 0, 0};
static BOOL gVcamLaneMemoOff[4] = {NO, NO, NO, NO};
static CFAbsoluteTime gVcamLaneMemoOffAt[4] = {0, 0, 0, 0};
static void vcamLaneMemoInvalidate(uint32_t fmt, BOOL off) {
    for (int i = 0; i < 4; i++) {
        if (gVcamLaneMemoFmt[i] == fmt) {
            if (off && !gVcamLaneMemoOff[i]) gVcamLaneMemoOffAt[i] = CFAbsoluteTimeGetCurrent();
            gVcamLaneMemoOff[i] = off; return;
        }
    }
    gVcamLaneMemoFmt[fmt & 3] = fmt;
    if (off) gVcamLaneMemoOffAt[fmt & 3] = CFAbsoluteTimeGetCurrent();
    gVcamLaneMemoOff[fmt & 3] = off;
}
// 熔断是否已过期(30s 自动恢复探测窗口)
static BOOL vcamLaneMemoExpired(uint32_t fmt) {
    for (int i = 0; i < 4; i++) {
        if (gVcamLaneMemoFmt[i] == fmt) {
            return gVcamLaneMemoOff[i] && gVcamLaneMemoOffAt[i] > 0 &&
                   (CFAbsoluteTimeGetCurrent() - gVcamLaneMemoOffAt[i]) > 30.0;
        }
    }
    return NO;
}

// 1.3.48 失败计数文件级化(成功即清零, 防隔很久的 2 次失败误熔断):
// 热路径无锁 int32 写(启发式计数, 竞态无害); _laneDisabled 字典只表达
// 熔断开关, 计数以此数组为准
static int32_t gVcamLaneFailCnt[4] = {0, 0, 0, 0};
static int vcamLaneFailSlot(uint32_t fmt) {
    for (int i = 0; i < 4; i++) {
        if (gVcamLaneMemoFmt[i] == fmt) return i;
    }
    return (int)(fmt & 3);
}
static void vcamLaneNoteSuccess(uint32_t fmt) {
    gVcamLaneFailCnt[vcamLaneFailSlot(fmt)] = 0;
}

// 1.3.48 视频切换重置车道记忆(新视频不继承旧失败): 直转/stage/split/
// 熔断 memo 全清零, 新视频首帧重新探测各车道。VCamCore 切源时调用
void vcamLaneResetAllMemos(void) {
    memset(gVcamYuvDirectFmt, 0, sizeof(gVcamYuvDirectFmt));
    memset(gVcamYuvDirectOk, 0, sizeof(gVcamYuvDirectOk));
    memset(gVcamYuvDirectFails, 0, sizeof(gVcamYuvDirectFails));
    memset(gVcamYuvDirectFailAt, 0, sizeof(gVcamYuvDirectFailAt));
    memset(gVcamYuvStageFmt, 0, sizeof(gVcamYuvStageFmt));
    memset(gVcamYuvStageOk, 0, sizeof(gVcamYuvStageOk));
    memset(gVcamYuvSplitFmt, 0, sizeof(gVcamYuvSplitFmt));
    memset(gVcamYuvSplitOk, 0, sizeof(gVcamYuvSplitOk));
    memset(gVcamLaneMemoFmt, 0, sizeof(gVcamLaneMemoFmt));
    memset(gVcamLaneMemoOff, 0, sizeof(gVcamLaneMemoOff));
    memset(gVcamLaneMemoOffAt, 0, sizeof(gVcamLaneMemoOffAt));
    memset(gVcamLaneFailCnt, 0, sizeof(gVcamLaneFailCnt));
}

@implementation GPUImageProcessor

- (instancetype)init {
    self = [super init];
    if (self) {
        _rotationAngle = 0;
        _mirrored = NO;
        _userPanX = 0.0;
        _userPanY = 0.0;
        _userZoom = 1.0;
        _rotationApiAvailable = NO;
        _bgraTransferSession = NULL;
        _yuvTransferSession = NULL;
        _privateTransferSession = NULL;
        _prerenderTransferSession = NULL;
        _pixelRotationSession = NULL;
        _bgraBufferPoolMap = [[NSMutableDictionary alloc] init];
        _twoStepSessionPool = [[NSMutableDictionary alloc] init];
        _twoStepStagingPool = [[NSMutableDictionary alloc] init];
        _twoStepTokenPool = [[NSMutableDictionary alloc] init];
        _twoStepFailCountPool = [[NSMutableDictionary alloc] init];
        _twoStepDisabledPool = [[NSMutableDictionary alloc] init];
        _oneStepSessionPool = [[NSMutableDictionary alloc] init];
        _oneStepKeyLockPool = [[NSMutableDictionary alloc] init];
        _rotationRenderLock = [[NSLock alloc] init];
        _twoStepKeyLockPool = [[NSMutableDictionary alloc] init];
        _adaptiveRotatedGen = 0;
        _streamKeyOrder = [NSMutableArray array];
        memset(gVcamStatSlots, 0, sizeof(gVcamStatSlots));  // 统计槽位(替代三个字典)
        _gpuImgTokenPool = [NSMutableDictionary dictionary];
        _gpuImgOutPool = [NSMutableDictionary dictionary];
        _oneStepFailPool = [NSMutableDictionary dictionary];
        _oneStepDisabledPool = [NSMutableDictionary dictionary];
        _groupStagingPool = [[NSMutableDictionary alloc] init];
        _groupTokenPool = [[NSMutableDictionary alloc] init];
        _groupGlobalLock = [[NSLock alloc] init];
        _groupSessionPool = [[NSMutableDictionary alloc] init];
        _groupSizePool = [[NSMutableDictionary alloc] init];
        _resultCachePool = [[NSMutableDictionary alloc] init];
        _resultBlitSessionPool = [[NSMutableDictionary alloc] init];
        _resultCacheTokenPool = [[NSMutableDictionary alloc] init];
        _lastReqTokenPool = [[NSMutableDictionary alloc] init];
        _resultBlitDisabledPool = [[NSMutableDictionary dictionary] init];
        _statsLock = [[NSLock alloc] init];
        _poolDictLock = [[NSLock alloc] init];

        // 千面模型固定车道(2026-08-19): 3 锁 + s1 会话 + 熔断表
        // (staging 槽位 gVcamLaneStaging 为文件级静态数组, 零初始化即空槽)
        _laneLockBGRA = [[NSLock alloc] init];
        _laneLockYUV = [[NSLock alloc] init];
        _laneLockPrivate = [[NSLock alloc] init];
        _twoStepS1Session = NULL;
        _laneFailCounts = [NSMutableDictionary dictionary];
        _laneDisabled = [NSMutableDictionary dictionary];

        // 软件渲染 CIContext（回退用）
        @try {
            _preprocessContext = [CIContext contextWithOptions:@{
                kCIContextUseSoftwareRenderer: @YES
            }];
            _renderContext = [CIContext contextWithOptions:@{
                kCIContextUseSoftwareRenderer: @YES
            }];
        } @catch (NSException *e) {
            _preprocessContext = nil;
            _renderContext = nil;
        }

        // Metal GPU probe(2026-08-16): mediaserverd 是相机/显示管线宿主, 大概率有
        // GPU 访问。dlsym 动态加载避免硬链接依赖(Metal 弱链接, 探测失败静默回退 VT)。
        // 实测判决(2026-08-16 v2): 探针显示 6.4ms/帧 —— CoreImage+MTL 在 mediaserverd
        // 落到 CPU 回退管线(真 GPU ~1-2ms), 比 VT 两步法(内容复用帧 ~1.5ms)更贵。
        // probe 保留(记录设备能力供未来验证), 路径永久禁用 —— 走 VT token 复用路径
        _metalAvailable = NO;
        @try {
            typedef void *(*CreateDeviceFn)(void);
            CreateDeviceFn createDevice = (CreateDeviceFn)dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice");
            if (createDevice) {
                id device = (__bridge id)createDevice();
                BOOL devicePresent = (device != nil);
                vcam_gpu_log([NSString stringWithFormat:@"[vcam] Metal device probe: %@ (CI/MTL path DISABLED - CPU fallback measured 6.4ms/frame, VT token-reuse path is cheaper)",
                              devicePresent ? @"present" : @"absent"]);
            }
        } @catch (NSException *e) {
        }

        [self setupBGRATransferSession];
        [self setupYUVTransferSession];
        [self setupPrerenderTransferSession];
        [self setupPixelRotationSession];
        vcam_gpu_log(@"[vcam] GPUImageProcessor initialized (VT token-reuse path, CI/MTL disabled)");
    }
    return self;
}

- (void)dealloc {
    typedef void (*InvalidateFunc)(VTPixelTransferSessionRef);
    if (_bgraTransferSession) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_bgraTransferSession);
    }
    if (_yuvTransferSession) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_yuvTransferSession);
    }
    if (_prerenderTransferSession) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_prerenderTransferSession);
    }
    if (_userTransferSession) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_userTransferSession);
    }
    if (_privateTransferSession) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_privateTransferSession);
    }
    // 千面车道(2026-08-19): s1 会话 + staging 槽位
    if (_twoStepS1Session) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_twoStepS1Session);
    }
    for (int i = 0; i < kVcamLaneStagingMax; i++) {
        if (gVcamLaneStaging[i].staging) {
            CVPixelBufferRelease(gVcamLaneStaging[i].staging);
            gVcamLaneStaging[i].staging = NULL;
            gVcamLaneStaging[i].w = gVcamLaneStaging[i].h = 0;
            gVcamLaneStaging[i].token = 0;
        }
    }
    // 释放两步法池(per-key session + staging buffer)
    {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        for (NSValue *v in _twoStepSessionPool.allValues) {
            VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[v pointerValue];
            if (s && invalidate) invalidate(s);
        }
        for (NSValue *v in _twoStepStagingPool.allValues) {
            CVPixelBufferRef b = (CVPixelBufferRef)[v pointerValue];
            if (b) CVPixelBufferRelease(b);
        }
        [_twoStepSessionPool removeAllObjects];
        [_twoStepStagingPool removeAllObjects];
        [_twoStepTokenPool removeAllObjects];
        // 组 staging 池 + s2 结果缓存池(前置多流优化配套)
        {
            for (NSString *k in _groupSessionPool.allKeys) {
                NSValue *sv = _groupSessionPool[k];
                VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[sv pointerValue];
                if (s && invalidate) invalidate(s);
            }
            for (NSValue *v in _groupStagingPool.allValues) {
                CVPixelBufferRef b = (CVPixelBufferRef)[v pointerValue];
                if (b) CVPixelBufferRelease(b);
            }
            [_groupSessionPool removeAllObjects];
            [_groupStagingPool removeAllObjects];
            [_groupTokenPool removeAllObjects];
            for (NSValue *v in _resultCachePool.allValues) {
                CVPixelBufferRef b = (CVPixelBufferRef)[v pointerValue];
                if (b) CVPixelBufferRelease(b);
            }
            [_resultCachePool removeAllObjects];
            [_resultCacheTokenPool removeAllObjects];
            for (NSValue *v in _resultBlitSessionPool.allValues) {
                VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[v pointerValue];
                if (s && invalidate) invalidate(s);
            }
            [_resultBlitSessionPool removeAllObjects];
        }
        // 一步 transfer per-stream session 池
        for (NSValue *v in _oneStepSessionPool.allValues) {
            VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[v pointerValue];
            if (s && invalidate) invalidate(s);
        }
        [_oneStepSessionPool removeAllObjects];
    }
    // 释放旋转 session 与自适应旋转缓存
    {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelRotationSessionInvalidate");
        if (invalidate) {
            if (_pixelRotationSession) invalidate((VTPixelTransferSessionRef)_pixelRotationSession);
            if (_renderRotationSession) invalidate((VTPixelTransferSessionRef)_renderRotationSession);
        }
    }
    if (_adaptiveRotateCache) {
        CVPixelBufferRelease(_adaptiveRotateCache);
        _adaptiveRotateCache = NULL;
    }
    // 释放预渲染旋转 3 槽池 + 镜像 buffer
    for (int i = 0; i < 3; i++) {
        CVPixelBufferRef b = [self prerenderRotateBufferAtSlot:i];
        if (b) CVPixelBufferRelease(b);
        [self setPrerenderRotateBuffer:NULL atSlot:i];
    }
    // 释放用户画面变换画布池 + 缩小中转
    for (int i = 0; i < 3; i++) {
        CVPixelBufferRef b = [self userCanvasAtSlot:i];
        if (b) CVPixelBufferRelease(b);
        [self setUserCanvas:NULL atSlot:i];
    }
    if (_userShrinkBuffer) {
        CVPixelBufferRelease(_userShrinkBuffer);
        _userShrinkBuffer = NULL;
    }
    if (_userPieceBuffer) {
        CVPixelBufferRelease(_userPieceBuffer);
        _userPieceBuffer = NULL;
    }
    // 释放所有缓冲池
    for (id key in _bgraBufferPoolMap) {
        CVPixelBufferPoolRef pool = (__bridge CVPixelBufferPoolRef)_bgraBufferPoolMap[key];
        CVPixelBufferPoolRelease(pool);
    }
    [_bgraBufferPoolMap removeAllObjects];
    vcam_gpu_log(@"[vcam] GPUImageProcessor deallocated");
}

#pragma mark - Session 初始化

- (void)setupBGRATransferSession {
    if (_bgraTransferSession) return;
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_bgraTransferSession);
    if (status == noErr) {
        // 对齐千面 init 反汇编(0xa494-0xa518): 三个 session 仅设 ScalingMode=Trim, 无 RealTime
        // 千面导入 kVTScalingMode_Trim: 保宽高比填充目标 + 裁剪超出部分(crop fill)
        VTSessionSetProperty(_bgraTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
        vcam_gpu_log(@"[vcam] BGRA VTPixelTransferSession created (Trim only)");
    } else {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create BGRA session: %d", (int)status]);
    }
}

- (void)setupYUVTransferSession {
    if (_yuvTransferSession) return;
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_yuvTransferSession);
    if (status == noErr) {
        VTSessionSetProperty(_yuvTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
        vcam_gpu_log(@"[vcam] YUV VTPixelTransferSession created (Trim only)");
    } else {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create YUV session: %d", (int)status]);
    }
}

- (void)setupPrerenderTransferSession {
    if (_prerenderTransferSession) return;
    // 预渲染线程专用 session（与 render 的 session 分离, 避免并发调用崩溃）
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_prerenderTransferSession);
    if (status == noErr) {
        VTSessionSetProperty(_prerenderTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
        vcam_gpu_log(@"[vcam] Prerender VTPixelTransferSession created (Trim)");
    } else {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create prerender session: %d", (int)status]);
    }
}

- (void)setupPrivateTransferSession {
    if (_privateTransferSession) return;
    // 私有格式目标(|xv0/|8v0/-8f0/p420 等)专用 session:
    // 与标准格式 session 隔离 —— 私有格式的 pipeline 会改写 session 内部状态,
    // 混用会污染标准流(之前照片模式上下反复拉伸的教训)
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_privateTransferSession);
    if (status == noErr) {
        VTSessionSetProperty(_privateTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
        vcam_gpu_log(@"[vcam] Private-format VTPixelTransferSession created (Trim)");
    } else {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create private session: %d", (int)status]);
    }
}

// 两步法 per-key session 存取
// 死锁修复(2026-08-17): 旧注释"renderLock 内调用, 无并发"已被每流独立 keyLock 的
// 并行化打破 —— 多流线程并发懒建直接 mutate 共享字典(并发损坏/死循环风险), 且本方法
// 在 keyLock 持有期间被调, 统一走 poolDictLock(最内层, 锁内无外部调用)
- (VTPixelTransferSessionRef)twoStepSessionForKey:(NSString *)key {
    NSValue *v = nil;
    [_poolDictLock lock];
    v = _twoStepSessionPool[key];
    [_poolDictLock unlock];
    if (v) return (VTPixelTransferSessionRef)[v pointerValue];
    VTPixelTransferSessionRef s = NULL;
    if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &s) == noErr && s) {
        VTSessionSetProperty(s, CFSTR("ScalingMode"), CFSTR("Trim"));
        // RealTime 硬件加速提示(2026-08-16 延迟修复): VT 择优硬件路径(相机管线内
        // GPU/ANE 可用), 降低 -8f0 照片流等纯 CPU 转换的 CPU 占用; 失败自动回退软件
        VTSessionSetProperty(s, CFSTR("RealTime"), kCFBooleanTrue);
        [_poolDictLock lock];
        _twoStepSessionPool[key] = [NSValue valueWithPointer:s];
        [_poolDictLock unlock];
        return s;
    }
    vcam_gpu_log([NSString stringWithFormat:@"[vcam] failed to create 2step session for %@", key]);
    return NULL;
}

- (void)invalidateTwoStepSessionForKey:(NSString *)key {
    NSValue *v = _twoStepSessionPool[key];
    if (!v) return;
    VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[v pointerValue];
    if (s) {
        void (*invalidate)(VTPixelTransferSessionRef) =
            (void (*)(VTPixelTransferSessionRef))dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(s);
    }
    [_twoStepSessionPool removeObjectForKey:key];
    // session 重建后 staging 内容仍有效(纯格式转换), token 保留以继续复用缩放
}

- (void)setupPixelRotationSession {
    if (_pixelRotationSession) return;

    // dlsym(RTLD_DEFAULT) 在 mediaserverd 中找不到 VideoToolbox 私有符号
    // (rotation session 因此从未创建, 自适应旋转从未执行)。
    // 改为显式 dlopen VideoToolbox 后在其镜像内查找。
    void *vt = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_LAZY | RTLD_GLOBAL);
    void *base = vt ? vt : RTLD_DEFAULT;

    _createRotationSession = (VTPixelRotationSessionCreateFunc)dlsym(base, "VTPixelRotationSessionCreate");
    _transferRotationImage = (VTPixelRotationSessionTransferImageFunc)dlsym(base, "VTPixelRotationSessionRotateImage");

    // 注意: kVTPixelRotationPropertyKey_* / kVTRotation_* 是 CFStringRef 全局变量,
    // dlsym 返回的是变量地址, 需解引用拿到 CFString 对象; 解引用失败回退已知字符串值。
    // 千面逆向(0xb094/0xe598)确认: 属性 kVTPixelRotationPropertyKey_Rotation,
    // 值为 kVTRotation_CCW90 / kVTRotation_CW90 / kVTRotation_180 CFString 常量
    void *rotSym = dlsym(base, "kVTPixelRotationPropertyKey_Rotation");
    _rotationPropertyKey = rotSym ? *(CFStringRef *)rotSym : CFSTR("Rotation");
    void *ccwSym = dlsym(base, "kVTRotation_CCW90");
    _rotationCCW90Value = ccwSym ? *(CFStringRef *)ccwSym : CFSTR("CCW90");
    void *cwSym = dlsym(base, "kVTRotation_CW90");
    _rotationCW90Value = cwSym ? *(CFStringRef *)cwSym : CFSTR("CW90");
    void *r180Sym = dlsym(base, "kVTRotation_180");
    _rotation180Value = r180Sym ? *(CFStringRef *)r180Sym : CFSTR("180");
    void *flipSym = dlsym(base, "kVTPixelRotationPropertyKey_FlipHorizontalOrientation");
    _flipHorizontalKey = flipSym ? *(CFStringRef *)flipSym : CFSTR("FlipHorizontalOrientation");

    vcam_gpu_log([NSString stringWithFormat:@"[vcam] rotation api probe: handle=%d create=%d rotate=%d rotKey=%d ccw=%d cw=%d r180=%d flipKey=%d",
                  vt != NULL, _createRotationSession != NULL, _transferRotationImage != NULL,
                  rotSym != NULL, ccwSym != NULL, cwSym != NULL, r180Sym != NULL, flipSym != NULL]);

    if (!_createRotationSession || !_transferRotationImage) {
        _rotationApiAvailable = NO;
        vcam_gpu_log(@"[vcam] VTPixelRotationSession API unavailable (adaptive rotation disabled)");
        return;
    }

    OSStatus status = _createRotationSession(kCFAllocatorDefault, &_pixelRotationSession);
    if (status == noErr) {
        _rotationApiAvailable = YES;
        // render 路径专用第二个 session（预渲染与 render 并发旋转同一 session 会崩溃）
        OSStatus st2 = _createRotationSession(kCFAllocatorDefault, &_renderRotationSession);
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] VTPixelRotationSession created (render session: %d)", (int)st2]);
    } else {
        _rotationApiAvailable = NO;
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create VTPixelRotationSession: %d", (int)status]);
    }
}

#pragma mark - 缓冲池（多池字典，每个尺寸独立池，避免频繁重建）

- (CVPixelBufferPoolRef)getOrCreatePoolForWidth:(size_t)width height:(size_t)height format:(OSType)format {
    if (width == 0 || height == 0) return NULL;

    // 池字典非线程安全: render 线程与预渲染线程(convertFormat 回退)都会访问
    @synchronized(self) {
        NSString *key = [NSString stringWithFormat:@"%zu_%zu_%u", width, height, (unsigned)format];
        id existing = _bgraBufferPoolMap[key];
        if (existing) {
            return (__bridge CVPixelBufferPoolRef)existing;
        }
        // 新建池纳入流 key LRU(与 session/staging 同一上限管理, 防尺寸种类累积)
        [self touchStreamKeyLRU:key];

        // 创建新池（关键约束：不能用 kCVPixelBufferIOSurfacePropertiesKey）
        NSDictionary *poolAttributes = @{
            (id)kCVPixelBufferPoolMinimumBufferCountKey: @2,
        };
        NSDictionary *pixelBufferAttributes = @{
            (id)kCVPixelBufferWidthKey:  @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferPixelFormatTypeKey: @(format),
        };

        CVPixelBufferPoolRef pool = NULL;
        OSStatus status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            (__bridge CFDictionaryRef)poolAttributes,
            (__bridge CFDictionaryRef)pixelBufferAttributes,
            &pool
        );

        if (status != noErr) {
            // 回退：NULL pool attributes
            status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                NULL,
                (__bridge CFDictionaryRef)pixelBufferAttributes,
                &pool
            );
        }

        if (status == noErr && pool) {
            _bgraBufferPoolMap[key] = (__bridge id)pool;
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] Created buffer pool: %zux%zu fmt=%u (key=%@)", width, height, (unsigned)format, key]);
            return pool;
        }

        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create buffer pool: %d, %zux%zu", (int)status, width, height]);
        return NULL;
    }
}

- (CVPixelBufferRef)getOrCreateBGRABufferWithWidth:(size_t)width height:(size_t)height CF_RETURNS_RETAINED {
    @synchronized(self) {
        CVPixelBufferPoolRef pool = [self getOrCreatePoolForWidth:width height:height format:kCVPixelFormatType_32BGRA];

        CVPixelBufferRef buffer = NULL;
        if (pool) {
            OSStatus status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer);
            if (status == noErr && buffer) {
                return buffer;
            }
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to get buffer from pool: %d", (int)status]);
        }

        // 回退：直接创建（不带 IOSurface 属性）
        OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, NULL, &buffer);
        if (status != noErr) {
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create pixel buffer: %d, %zux%zu BGRA", (int)status, width, height]);
            return NULL;
        }
        return buffer;
    }
}

- (void)configureWithWidth:(size_t)width height:(size_t)height format:(OSType)format {
    [self getOrCreatePoolForWidth:width height:height format:format];
    NSString *fmtStr = [self stringForFormat:format];
    vcam_gpu_log([NSString stringWithFormat:@"[vcam] GPUImageProcessor configured: %zux%zu format: %@", width, height, fmtStr]);
}

#pragma mark - 核心处理

- (CVPixelBufferRef)processPixelBuffer:(CVPixelBufferRef)input
                                toWidth:(size_t)width
                                height:(size_t)height
                                format:(OSType)format CF_RETURNS_RETAINED {
    if (!input) return NULL;

    @try {
        size_t inW = CVPixelBufferGetWidth(input);
        size_t inH = CVPixelBufferGetHeight(input);

        int total = (_sourceRotation + _rotationAngle) % 360;
        if (total < 0) total += 360;

        // 旋转后的尺寸
        size_t rotW = inW, rotH = inH;
        if (total == 90 || total == 270) {
            rotW = inH;
            rotH = inW;
        }

        // 1. 旋转/镜像（如果需要）→ BGRA
        // 1.3.83: 去掉 VT rotation 前置条件(iOS 12 无该私有符号时原来整体跳过),
        // rotateAndMirror 内部自回退 CPU 软件旋转
        CVPixelBufferRef processedBuffer = NULL;
        if (total != 0 || _mirrored) {
            processedBuffer = [self rotateAndMirror:input width:rotW height:rotH angle:total];
        }
        // 如果旋转失败或不需要旋转，直接用输入
        if (!processedBuffer) {
            processedBuffer = input;
            CVPixelBufferRetain(processedBuffer);
        }

        // 2. 缩放到目标尺寸的 BGRA（CoreImage 擅长 BGRA→BGRA 缩放）
        //    VTPixelTransferSession 不支持缩放，必须先缩放到目标尺寸再做格式转换
        size_t curW = CVPixelBufferGetWidth(processedBuffer);
        size_t curH = CVPixelBufferGetHeight(processedBuffer);
        if (curW != width || curH != height) {
            CVPixelBufferRef scaledBGRA = [self scaleToBGRA:processedBuffer width:width height:height];
            CVPixelBufferRelease(processedBuffer);
            processedBuffer = scaledBGRA;  // scaledBGRA 已 retain (CF_RETURNS_RETAINED)
            if (!processedBuffer) {
                return NULL;
            }
        }

        // 3. 格式转换（BGRA → 目标格式，同尺寸）
        CVPixelBufferRef outputBuffer = NULL;
        if (format == kCVPixelFormatType_32BGRA) {
            // 目标格式是 BGRA，直接返回缩放后的缓冲区
            outputBuffer = processedBuffer;
        } else {
            // 用 VTPixelTransferSession 转换格式（同尺寸 BGRA→YUV）
            outputBuffer = [self createBufferWithWidth:width height:height format:format];
            if (outputBuffer) {
                OSStatus status = VTPixelTransferSessionTransferImage(_yuvTransferSession, processedBuffer, outputBuffer);
                if (status != noErr) {
                    NSString *fmtStr = [self stringForFormat:format];
                    vcam_gpu_log([NSString stringWithFormat:@"[vcam] VTPixelTransferSession failed: %d, format: %@", (int)status, fmtStr]);
                    // 回退到 CoreImage（同尺寸 BGRA→YUV）
                    CVPixelBufferRelease(outputBuffer);
                    outputBuffer = [self convertWithCoreImage:processedBuffer toFormat:format width:width height:height];
                }
            }
            CVPixelBufferRelease(processedBuffer);
        }

        return outputBuffer;
    } @catch (NSException *e) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Exception in processPixelBuffer: %@", e]);
        return NULL;
    }
}

// crop fill: 保持宽高比, 填充整个目标, 裁剪超出部分（无黑边, 居中）
- (CVPixelBufferRef)scaleToBGRA:(CVPixelBufferRef)input
                          width:(size_t)width
                         height:(size_t)height CF_RETURNS_RETAINED {
    if (!input || !_preprocessContext) return NULL;

    size_t inW = CVPixelBufferGetWidth(input);
    size_t inH = CVPixelBufferGetHeight(input);
    if (inW == 0 || inH == 0 || width == 0 || height == 0) return NULL;

    CIImage *image = [CIImage imageWithCVPixelBuffer:input];
    if (!image) return NULL;

    CVPixelBufferRef output = [self getOrCreateBGRABufferWithWidth:width height:height];
    if (!output) return NULL;

    // crop fill: 取较大缩放比填充整个目标, 超出部分裁剪（无黑边）
    CGFloat scale = MAX((CGFloat)width / (CGFloat)inW, (CGFloat)height / (CGFloat)inH);
    CGFloat scaledW = (CGFloat)inW * scale;
    CGFloat scaledH = (CGFloat)inH * scale;
    // 居中偏移（负值 = 图像超出目标边界, 被 bounds 裁剪）
    CGFloat offsetX = ((CGFloat)width - scaledW) / 2.0;
    CGFloat offsetY = ((CGFloat)height - scaledH) / 2.0;

    // 变换: 缩放后平移到居中位置
    CGAffineTransform t = CGAffineTransformMakeScale(scale, scale);
    t = CGAffineTransformTranslate(t, offsetX / scale, offsetY / scale);
    CIImage *scaled = [image imageByApplyingTransform:t];

    // 千面用 DeviceRGB 渲染(逆向: CGColorSpaceCreateDeviceRGB + render:colorSpace:),
    // sRGB 会导致照片流(-8f0 full-range)高光过爆
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [_preprocessContext render:scaled toCVPixelBuffer:output
                        bounds:CGRectMake(0, 0, (CGFloat)width, (CGFloat)height)
                    colorSpace:colorSpace];
    
    return output;
}

// 前置声明(定义在本文件后部): CPU 旋转回退路径使用
static BOOL vcamCopyPlanes(CVPixelBufferRef src, CVPixelBufferRef dst);
static void vcamMirrorRowsInPlace(CVPixelBufferRef pb);
static BOOL vcamRotateBufferCPU(CVPixelBufferRef src, CVPixelBufferRef dst, int angle);

- (CVPixelBufferRef)rotateAndMirror:(CVPixelBufferRef)input width:(size_t)width height:(size_t)height angle:(int)angle CF_RETURNS_RETAINED {
    if (!input) return NULL;
    // 1.3.83 CPU 回退: VT rotation 不可用(iOS 12 无该私有符号)时软件旋转 +
    // 原地行反转镜像, 语义与 VT 路径一致(同格式输出, 角度 0 只镜像)
    if (!_rotationApiAvailable || !_pixelRotationSession || !_transferRotationImage) {
        OSType fmt = CVPixelBufferGetPixelFormatType(input);
        CVPixelBufferRef dst = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, fmt, NULL, &dst) != noErr || !dst) {
            return NULL;
        }
        BOOL ok;
        if (angle != 0) {
            ok = vcamRotateBufferCPU(input, dst, angle);
        } else {
            ok = vcamCopyPlanes(input, dst);
        }
        if (!ok) {
            CVPixelBufferRelease(dst);
            return NULL;
        }
        if (_mirrored) vcamMirrorRowsInPlace(dst);
        return dst;
    }
    if (!_pixelRotationSession) return NULL;

    // 目标缓冲保持源格式（对齐千面 rotateBuffer: 0xe514-0xe578:
    // GetPixelFormatType(src) → CVPixelBufferCreate(同格式) —— 420f 源旋转后仍是 420f,
    // range/矩阵 attachments 语义保持, 不做 BGRA 中转）
    OSType srcFormat = CVPixelBufferGetPixelFormatType(input);
    CVPixelBufferRef dst = NULL;
    OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, srcFormat, NULL, &dst);
    if (status != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create rotation buffer: %d", (int)status]);
        return NULL;
    }

    // 设置旋转角度（千面 prerender rotateBuffer 用 kVTRotation_* 常量值, 90=CW90 与其一致）
    // angle==0 也显式设置: 不设置会残留上一次的角度, 只镜像场景会多转 90/270
    if (angle == 90) {
        VTSessionSetProperty(_pixelRotationSession, _rotationPropertyKey, _rotationCW90Value);
    } else if (angle == 180) {
        VTSessionSetProperty(_pixelRotationSession, _rotationPropertyKey, _rotation180Value);
    } else if (angle == 270) {
        VTSessionSetProperty(_pixelRotationSession, _rotationPropertyKey, _rotationCCW90Value);
    } else {
        VTSessionSetProperty(_pixelRotationSession, _rotationPropertyKey, kCFBooleanFalse);  // 显式归零防残留
    }
    // 设置镜像
    VTSessionSetProperty(_pixelRotationSession, _flipHorizontalKey, _mirrored ? kCFBooleanTrue : kCFBooleanFalse);

    status = _transferRotationImage(_pixelRotationSession, input, dst);
    if (status != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] VTPixelRotationSession failed: %d", (int)status]);
        CVPixelBufferRelease(dst);
        return NULL;
    }

    return dst;
}

// 3 槽存取 helper(仅预渲染线程 + dealloc 调用)
- (CVPixelBufferRef)prerenderRotateBufferAtSlot:(int)slot {
    if (slot == 0) return _prerenderRotatePool0;
    if (slot == 1) return _prerenderRotatePool1;
    return _prerenderRotatePool2;
}

- (void)setPrerenderRotateBuffer:(CVPixelBufferRef)buf atSlot:(int)slot {
    if (slot == 0) _prerenderRotatePool0 = buf;
    else if (slot == 1) _prerenderRotatePool1 = buf;
    else _prerenderRotatePool2 = buf;
}

// CPU 水平镜像(原地行反转): 420f/420v Y 平面按 1 字节粒度、UV 平面按 2 字节粒度
// (CbCr 对不能拆开), BGRA 按 4 字节粒度。~3MB 帧约 1ms(预渲染线程可承受)。
// 千面二进制无任何 Flip 属性字符串 —— VTPixelRotationSession 的 flip 在 420f 上
// 不支持(-12914), 镜像必须自己实现(对齐千面: VT 只做纯旋转)
static void vcamMirrorRowsInPlace(CVPixelBufferRef pb) {
    if (!pb) return;
    CVPixelBufferLockBaseAddress(pb, 0);
    int planes = (int)CVPixelBufferGetPlaneCount(pb);
    if (planes <= 0) {
        // 单平面 BGRA: 4 字节/像素
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
        size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        size_t w = CVPixelBufferGetWidth(pb) * 4;
        size_t h = CVPixelBufferGetHeight(pb);
        for (size_t y = 0; y < h && base; y++) {
            uint8_t *row = base + y * bpr;
            for (size_t l = 0, r = w - 4; l < r; l += 4, r -= 4) {
                uint32_t t = *(uint32_t *)(row + l);
                *(uint32_t *)(row + l) = *(uint32_t *)(row + r);
                *(uint32_t *)(row + r) = t;
            }
        }
    } else {
        for (int p = 0; p < planes; p++) {
            uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, p);
            size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, p);
            size_t pw = CVPixelBufferGetWidthOfPlane(pb, p);
            size_t ph = CVPixelBufferGetHeightOfPlane(pb, p);
            size_t px = (p == 0) ? 1 : 2;  // Y=1字节/px, UV=2字节/px(CbCr 对)
            size_t rowBytes = pw * px;
            for (size_t y = 0; y < ph && base; y++) {
                uint8_t *row = base + y * bpr;
                for (size_t l = 0, r = rowBytes - px; l < r; l += px, r -= px) {
                    for (size_t b = 0; b < px; b++) {
                        uint8_t t = row[l + b];
                        row[l + b] = row[r + b];
                        row[r + b] = t;
                    }
                }
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

// CPU 软件旋转(1.3.83, iOS 12 回退): VTPixelRotationSessionCreate/RotateImage
// 是 iOS 15/16 才有的符号, 老系统 dlsym 不到 → _rotationApiAvailable=NO →
// 旋转整体直通("转"按钮点了个寂寞, 替换/镜像/缩放不受影响 —— 它们走的
// VTPixelTransferSession 是 iOS 8+ 全有的老 API)。
// 本函数逐平面旋转: 双平面 YUV(420f/420v: Y=1字节粒度, UV=2字节 CbCr 对
// 粒度, 对不拆开)/单平面 BGRA(4字节粒度)。90/270 宽高互换, 180 原尺寸。
// 映射: CW90 dst(dx,dy)=src(sx=dy, sy=ph-1-dx); CCW90 dst(dx,dy)=src(sx=pw-1-dy, sy=dx);
//       180 dst(dx,dy)=src(pw-1-dx, ph-1-dy)。~1080p YUV 3~8ms, 预渲染 41ms
// 预算内; 仅 VT rotation 不可用(老系统)时走此路径, 15/16 设备零影响。
static BOOL vcamRotateBufferCPU(CVPixelBufferRef src, CVPixelBufferRef dst, int angle) {
    if (!src || !dst) return NO;
    if (angle != 90 && angle != 180 && angle != 270) return NO;
    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);
    BOOL ok = YES;
    int planes = (int)CVPixelBufferGetPlaneCount(src);
    if (planes > 0 && planes == (int)CVPixelBufferGetPlaneCount(dst)) {
        // 多平面(双平面 YUV): 每平面独立旋转(UV 半分辨率, 映射公式相同)
        for (int p = 0; p < planes; p++) {
            size_t px = (p == 0) ? 1 : 2;  // Y=1字节/单元, UV=2字节(CbCr 对)
            size_t pw = CVPixelBufferGetWidthOfPlane(src, p);
            size_t ph = CVPixelBufferGetHeightOfPlane(src, p);
            uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(src, p);
            uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(dst, p);
            size_t sbpr = CVPixelBufferGetBytesPerRowOfPlane(src, p);
            size_t dbpr = CVPixelBufferGetBytesPerRowOfPlane(dst, p);
            if (!sb || !db || !pw || !ph) { ok = NO; continue; }
            if (angle == 90 || angle == 270) {
                if (CVPixelBufferGetWidthOfPlane(dst, p) != ph ||
                    CVPixelBufferGetHeightOfPlane(dst, p) != pw) { ok = NO; continue; }
            } else {
                if (CVPixelBufferGetWidthOfPlane(dst, p) != pw ||
                    CVPixelBufferGetHeightOfPlane(dst, p) != ph) { ok = NO; continue; }
            }
            if (angle == 180) {
                for (size_t dy = 0; dy < ph; dy++) {
                    uint8_t *drow = db + dy * dbpr;
                    const uint8_t *srow = sb + (ph - 1 - dy) * sbpr;
                    for (size_t dx = 0; dx < pw; dx++) {
                        for (size_t b = 0; b < px; b++) {
                            drow[dx * px + b] = srow[(pw - 1 - dx) * px + b];
                        }
                    }
                }
            } else if (angle == 90) {
                // CW90: dst 平面 ph×pw; 行 dy ← src 列 dy 自底向上
                for (size_t dy = 0; dy < pw; dy++) {
                    uint8_t *drow = db + dy * dbpr;
                    const uint8_t *sp = sb + (ph - 1) * sbpr + dy * px;
                    for (size_t dx = 0; dx < ph; dx++) {
                        for (size_t b = 0; b < px; b++) drow[dx * px + b] = sp[b];
                        sp -= sbpr;
                    }
                }
            } else {  // 270
                // CCW90: dst 平面 ph×pw; 行 dy ← src 列 pw-1-dy 自顶向下
                for (size_t dy = 0; dy < pw; dy++) {
                    uint8_t *drow = db + dy * dbpr;
                    const uint8_t *sp = sb + (pw - 1 - dy) * px;
                    for (size_t dx = 0; dx < ph; dx++) {
                        for (size_t b = 0; b < px; b++) drow[dx * px + b] = sp[b];
                        sp += sbpr;
                    }
                }
            }
        }
    } else if (planes <= 0 && CVPixelBufferGetPlaneCount(dst) <= 0) {
        // 单平面(BGRA): 4 字节/像素
        size_t px = 4;
        size_t pw = CVPixelBufferGetWidth(src), ph = CVPixelBufferGetHeight(src);
        uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddress(src);
        uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddress(dst);
        size_t sbpr = CVPixelBufferGetBytesPerRow(src);
        size_t dbpr = CVPixelBufferGetBytesPerRow(dst);
        if (!sb || !db || !pw || !ph) {
            ok = NO;
        } else if ((angle == 90 || angle == 270) &&
                   (CVPixelBufferGetWidth(dst) != ph || CVPixelBufferGetHeight(dst) != pw)) {
            ok = NO;
        } else if (angle == 180 &&
                   (CVPixelBufferGetWidth(dst) != pw || CVPixelBufferGetHeight(dst) != ph)) {
            ok = NO;
        } else if (angle == 180) {
            for (size_t dy = 0; dy < ph; dy++) {
                uint32_t *drow = (uint32_t *)(db + dy * dbpr);
                const uint32_t *srow = (const uint32_t *)(sb + (ph - 1 - dy) * sbpr);
                for (size_t dx = 0; dx < pw; dx++) drow[dx] = srow[pw - 1 - dx];
            }
        } else if (angle == 90) {
            for (size_t dy = 0; dy < pw; dy++) {
                uint32_t *drow = (uint32_t *)(db + dy * dbpr);
                const uint8_t *sp = sb + (ph - 1) * sbpr + dy * px;
                for (size_t dx = 0; dx < ph; dx++) {
                    drow[dx] = *(const uint32_t *)sp;
                    sp -= sbpr;
                }
            }
        } else {
            for (size_t dy = 0; dy < pw; dy++) {
                uint32_t *drow = (uint32_t *)(db + dy * dbpr);
                const uint8_t *sp = sb + (pw - 1 - dy) * px;
                for (size_t dx = 0; dx < ph; dx++) {
                    drow[dx] = *(const uint32_t *)sp;
                    sp += sbpr;
                }
            }
        }
    } else {
        ok = NO;  // 源/目标平面结构不匹配
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return ok;
}


// 录像绿线修复教训(2026-08-19):
// v1(已回滚): VT 写完后对相机 dst IOSurface 做 CPU lock + 边缘 UV 覆盖 ——
// 录制时编码器持该 surface GPU fence, CPU map 与 fence 互等死锁(IOFence 事故
// 同款) → 录制黑屏(1.3.3 设备实证)。相机 surface 绝不允许 CPU lock。
// v2(现行): 裁剪几何前移到自有 staging(见 cropStagingForRatio), 不碰相机 buffer。
// 根因: VT Trim crop offset 非整数(如 BGRA 720x538→1920x1080 垂直 crop 354.7)
// 时 RGB→YUV420 私有格式路径边界半像素越界 → 边缘 UV=0 → 绿线
// (竖屏录制文件旋转 90° 后显示为左侧)。
// 预览流无此问题: BGRA 无 UV 子采样; 420f→420f 是 YUV 域缩放(千面同路径)。

// 色彩附件同步(2026-08-19 变色修复): memcpy 预裁剪只拷像素, colorspace 附件
// 不跟随 → VT 对无附件源做 RGB→YUV 时用默认色彩矩阵而非源视频实际色彩描述
// → 录制画面变色(设备实证 1.3.4)。只拷 3 个色彩键 —— 不拷 clean aperture 等
// 几何附件(裁剪槽几何已变, 旧 CA 会被 VT 二次裁剪)。
static void vcamSyncColorAttachments(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (!src || !dst) return;
    static CFStringRef keys[3];
    static dispatch_once_t onceTok;
    dispatch_once(&onceTok, ^{
        keys[0] = kCVImageBufferColorPrimariesKey;
        keys[1] = kCVImageBufferTransferFunctionKey;
        keys[2] = kCVImageBufferYCbCrMatrixKey;
    });
    for (int i = 0; i < 3; i++) {
        CFTypeRef v = CVBufferGetAttachment(src, keys[i], NULL);
        if (v) CVBufferSetAttachment(dst, keys[i], v, kCVAttachmentMode_ShouldPropagate);
    }
}

// Trim crop offset 非整数判定: 水平/垂直 crop 总量非正偶数 → offset x.5/x.33 非整
static void vcamTrimFractionalCrop(CVPixelBufferRef src, CVPixelBufferRef dst, BOOL *fixH, BOOL *fixV) {
    *fixH = NO; *fixV = NO;
    if (!src || !dst) return;
    size_t srcW = CVPixelBufferGetWidth(src), srcH = CVPixelBufferGetHeight(src);
    size_t dstW = CVPixelBufferGetWidth(dst), dstH = CVPixelBufferGetHeight(dst);
    if (!srcW || !srcH || !dstW || !dstH) return;
    double sc = MAX((double)dstW / srcW, (double)dstH / srcH);
    double cropW = srcW * sc - dstW;   // 水平 crop 总量(>0 才有裁剪)
    double cropH = srcH * sc - dstH;
    if (cropW > 0.5) {
        double off = cropW / 2.0;
        *fixH = (fabs(off - floor(off + 0.5)) > 1e-3);  // offset 非整数
    }
    if (cropH > 0.5) {
        double off = cropH / 2.0;
        *fixV = (fabs(off - floor(off + 0.5)) > 1e-3);
    }
}

// 逐平面复制(格式/尺寸需一致, bytesPerRow 允许不同 → 逐行 min 拷贝)
static BOOL vcamCopyPlanes(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (!src || !dst) return NO;
    if (CVPixelBufferGetPixelFormatType(src) != CVPixelBufferGetPixelFormatType(dst)) return NO;
    int planes = (int)CVPixelBufferGetPlaneCount(src);
    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);
    if (planes <= 0) {
        uint8_t *s = (uint8_t *)CVPixelBufferGetBaseAddress(src);
        uint8_t *d = (uint8_t *)CVPixelBufferGetBaseAddress(dst);
        size_t sbpr = CVPixelBufferGetBytesPerRow(src), dbpr = CVPixelBufferGetBytesPerRow(dst);
        size_t w = CVPixelBufferGetWidth(src) * 4, h = CVPixelBufferGetHeight(src);
        for (size_t y = 0; y < h && s && d; y++)
            memcpy(d + y * dbpr, s + y * sbpr, w);
    } else {
        for (int p = 0; p < planes; p++) {
            uint8_t *s = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(src, p);
            uint8_t *d = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(dst, p);
            size_t sbpr = CVPixelBufferGetBytesPerRowOfPlane(src, p);
            size_t dbpr = CVPixelBufferGetBytesPerRowOfPlane(dst, p);
            size_t px = (p == 0) ? 1 : 2;
            size_t w = CVPixelBufferGetWidthOfPlane(src, p) * px;
            size_t h = CVPixelBufferGetHeightOfPlane(src, p);
            for (size_t y = 0; y < h && s && d; y++)
                memcpy(d + y * dbpr, s + y * sbpr, w);
        }
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return YES;
}

// 预渲染用: 旋转(VT 纯旋转, 永不设 flip 属性 —— 420f 上 VT flip 报 -12914,
// 千面二进制亦无任何 Flip 字符串) + 镜像(CPU 行反转)。保持源格式。
// 总旋转 = 视频自带(sourceRotation) + 用户手动(rotationAngle)
- (CVPixelBufferRef)rotateAndMirrorIfNeeded:(CVPixelBufferRef)input CF_RETURNS_RETAINED {
    if (!input) return NULL;
    int total = (_sourceRotation + _rotationAngle) % 360;
    if (total < 0) total += 360;
    BOOL needRotate = (total != 0);
    BOOL needMirror = _mirrored;
    if (!needRotate && !needMirror) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }

    size_t inW = CVPixelBufferGetWidth(input);
    size_t inH = CVPixelBufferGetHeight(input);
    OSType fmt = CVPixelBufferGetPixelFormatType(input);

    // 阶段1: 纯旋转(VT) → 产出可写池 buffer; 失败/不需要时用原帧
    CVPixelBufferRef work = NULL;
    BOOL workIsWritable = NO;
    if (needRotate && _rotationApiAvailable && _pixelRotationSession && _transferRotationImage) {
        size_t rotW = (total == 90 || total == 270) ? inH : inW;
        size_t rotH = (total == 90 || total == 270) ? inW : inH;
        int slot = _prerenderRotateSlot;
        _prerenderRotateSlot = (slot + 1) % 3;
        CVPixelBufferRef dst = [self prerenderRotateBufferAtSlot:slot];
        if (!dst || CVPixelBufferGetWidth(dst) != rotW || CVPixelBufferGetHeight(dst) != rotH ||
            CVPixelBufferGetPixelFormatType(dst) != fmt) {
            if (dst) CVPixelBufferRelease(dst);
            dst = NULL;
            OSStatus cst = CVPixelBufferCreate(kCFAllocatorDefault, rotW, rotH, fmt, NULL, &dst);
            if (cst != noErr || !dst) {
                [self setPrerenderRotateBuffer:NULL atSlot:slot];
            } else {
                // 所有权转移给池(2026-08-18 泄漏修复): 旧代码 Retain(dst) 使 create 的
                // 名义引用永不释放 → 每次尺寸重建(转按钮/前后摄切换)泄漏一整帧 buffer,
                // idle releaseHeavyBuffersForIdle 时槽 buffer 也因多 1 引用不真正释放
                [self setPrerenderRotateBuffer:dst atSlot:slot];
            }
        }
        if (dst) {
            CFTypeRef rotValue;
            if (total == 90)       rotValue = _rotationCW90Value;
            else if (total == 270) rotValue = _rotationCCW90Value;
            else                   rotValue = _rotation180Value;
            VTSessionSetProperty(_pixelRotationSession, _rotationPropertyKey, rotValue);
            OSStatus st = _transferRotationImage(_pixelRotationSession, input, dst);
            if (st == noErr) {
                work = CVPixelBufferRetain(dst);  // 池 buffer 可写, 后续可原地镜像
                workIsWritable = YES;
            } else {
                static int rotFailLogged = 0;
                if (rotFailLogged++ < 2) {
                    vcam_gpu_log([NSString stringWithFormat:@"[vcam] prerender rotate failed: %d (keep unrotated)", (int)st]);
                }
            }
        }
    }
    // 1.3.83 CPU 旋转回退: VT rotation 不可用(iOS 12 无该私有符号)时软件旋转。
    // 复用同一 3 槽几何池(与 VT 分支互斥, 不会双写); 槽 buffer 可写 →
    // 阶段2 镜像原地行反转零额外拷贝。失败仍回退原帧(不旋转但不崩)
    if (!work && needRotate) {
        size_t rotW = (total == 90 || total == 270) ? inH : inW;
        size_t rotH = (total == 90 || total == 270) ? inW : inH;
        int slot = _prerenderRotateSlot;
        _prerenderRotateSlot = (slot + 1) % 3;
        CVPixelBufferRef dst = [self prerenderRotateBufferAtSlot:slot];
        if (!dst || CVPixelBufferGetWidth(dst) != rotW || CVPixelBufferGetHeight(dst) != rotH ||
            CVPixelBufferGetPixelFormatType(dst) != fmt) {
            if (dst) CVPixelBufferRelease(dst);
            dst = NULL;
            if (CVPixelBufferCreate(kCFAllocatorDefault, rotW, rotH, fmt, NULL, &dst) == noErr && dst) {
                [self setPrerenderRotateBuffer:dst atSlot:slot];  // 所有权转移给池
            } else {
                [self setPrerenderRotateBuffer:NULL atSlot:slot];
            }
        }
        if (dst && vcamRotateBufferCPU(input, dst, total)) {
            work = CVPixelBufferRetain(dst);
            workIsWritable = YES;
            static int cpuRotLogged = 0;
            if (cpuRotLogged++ < 2) {
                vcam_gpu_log(@"[vcam] CPU rotation fallback in use (VT rotation unavailable, e.g. iOS 12)");
            }
        }
    }
    if (!work) {
        work = (CVPixelBufferRef)CVPixelBufferRetain(input);  // 解码器 buffer, 不可写
    }

    // 阶段2: 镜像(CPU 行反转)
    if (!needMirror) return work;  // CF_RETURNS_RETAINED
    if (workIsWritable) {
        vcamMirrorRowsInPlace(work);
        return work;
    }
    // mirror-only: 复制到几何槽再反转(不动解码器 buffer)
    // 闪烁防护(2026-08-17): 3 槽轮转(单 buffer 会被 render 线程并发读取撕裂)。
    // 独立镜像池已删(2026-08-18 砍常驻内存): 与旋转共用几何 3 槽 ——
    // live缓存+fallback+in-flight transfer 最多持有 2 帧旧输出, 写入槽永不被读者持有。
    // mirror-only 时槽尺寸=源尺寸(inW×inH), 用户切换旋转模式时按需重建一次
    int mslot = _prerenderRotateSlot;
    _prerenderRotateSlot = (mslot + 1) % 3;
    CVPixelBufferRef mb = [self prerenderRotateBufferAtSlot:mslot];
    if (!mb || CVPixelBufferGetWidth(mb) != inW || CVPixelBufferGetHeight(mb) != inH ||
        CVPixelBufferGetPixelFormatType(mb) != fmt) {
        if (mb) CVPixelBufferRelease(mb);
        mb = NULL;
        CVPixelBufferRef created = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, inW, inH, fmt, NULL, &created) == noErr && created) {
            [self setPrerenderRotateBuffer:created atSlot:mslot];  // 所有权转移给池
            mb = created;
        } else {
            [self setPrerenderRotateBuffer:NULL atSlot:mslot];
        }
    }
    if (mb && vcamCopyPlanes(work, mb)) {
        vcamMirrorRowsInPlace(mb);
        CVPixelBufferRelease(work);
        return CVPixelBufferRetain(mb);
    }
    // 复制失败(罕见): 返回未镜像帧, 不崩溃
    return work;
}

// 用户画面变换画布池存取(仅预渲染线程 + 空闲释放调用)
- (CVPixelBufferRef)userCanvasAtSlot:(int)slot {
    if (slot == 0) return _userCanvasPool0;
    if (slot == 1) return _userCanvasPool1;
    return _userCanvasPool2;
}

- (void)setUserCanvas:(CVPixelBufferRef)buf atSlot:(int)slot {
    if (slot == 0) _userCanvasPool0 = buf;
    else if (slot == 1) _userCanvasPool1 = buf;
    else _userCanvasPool2 = buf;
}

// 按需取/建中间 buffer(piece: 同步用 1 槽, 尺寸/格式不符时重建; 返回池持有的引用)
- (CVPixelBufferRef)userPieceBuffer:(CVPixelBufferRef *)slot
                              width:(size_t)w height:(size_t)h format:(OSType)fmt {
    if (*slot && CVPixelBufferGetWidth(*slot) == w && CVPixelBufferGetHeight(*slot) == h &&
        CVPixelBufferGetPixelFormatType(*slot) == fmt) {
        return *slot;
    }
    if (*slot) CVPixelBufferRelease(*slot);
    *slot = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, NULL, slot);
    return *slot;
}

// 双平面 YUV(420f/420v) 区域拷贝: 从 src 的 (srcX,srcY,w,h) 矩形拷到 dst 的
// (dstX,dstY)。坐标/尺寸必须偶数对齐(UV 平面半分辨率)。调用方保证矩形在
// 两个 buffer 边界内(相交裁剪由调用方完成)。
static void vcamCopyRegionBiPlanar(CVPixelBufferRef dst, CVPixelBufferRef src,
                                   size_t dstX, size_t dstY,
                                   size_t srcX, size_t srcY,
                                   size_t w, size_t h) {
    if (!dst || !src || !w || !h) return;
    for (int p = 0; p < 2; p++) {
        uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(src, p);
        uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(dst, p);
        if (!sb || !db) continue;
        size_t sbpr = CVPixelBufferGetBytesPerRowOfPlane(src, p);
        size_t dbpr = CVPixelBufferGetBytesPerRowOfPlane(dst, p);
        // Y 平面: w 字节/行, h 行; UV 平面: w/2 像素对 ×2 字节 = w 字节/行, h/2 行。
        // 偶对齐下 UV 的字节偏移 = 像素偏移, 行号 = y/2
        size_t rowBytes = w;
        size_t rows = (p == 0) ? h : h / 2;
        size_t yDiv = (p == 0) ? 1 : 2;
        for (size_t y = 0; y < rows; y++) {
            memcpy(db + (dstY / yDiv + y) * dbpr + dstX,
                   sb + (srcY / yDiv + y) * sbpr + srcX,
                   rowBytes);
        }
    }
}

// 双平面 YUV 清黑: 420f(full range) Y=0; 420v(video range) Y=16; UV 一律 128
static void vcamClearBiPlanarBlack(CVPixelBufferRef buf, OSType fmt) {
    if (!buf) return;
    int yBlack = (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ? 0 : 16;
    uint8_t *yb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buf, 0);
    uint8_t *uvb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buf, 1);
    size_t ybpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 0);
    size_t uvbpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 1);
    size_t w = CVPixelBufferGetWidth(buf);
    size_t h = CVPixelBufferGetHeight(buf);
    if (yb) for (size_t y = 0; y < h; y++) memset(yb + y * ybpr, yBlack, w);
    if (uvb) for (size_t y = 0; y < h / 2; y++) memset(uvb + y * uvbpr, 128, w);
}

// 用户画面变换烘焙(箭头/＋/−/复, 2026-08-23 v3 统一裁剪窗口模型, 对齐安卓 Vcam):
// 模型(借鉴安卓 vc.c replace_yuv_buffer):
//   窗口 = 视频尺寸/z(等比, z>1 缩小窗口=放大 / z<1 窗口大于视频=缩小黑边),
//   窗口位置 = 居中基准 + pan×W(两轴统一用源宽做基数, 上下左右移动幅度一致);
//   窗口可与视频出界相交 → 出界部分=黑(平移/缩小的黑边统一由此产生);
//   画布(恒为 W×H 固定尺寸) = 窗口内容(含出界黑区)缩放到全幅。
// 统一性: 缩放恒以画面正中心为锚(pan=0 时窗口正对中心, 向四周均匀变化);
//         平移自由(z=1 也可移出画面, 露黑)。
// 固定画布尺寸的意义: 不随 zoom 重建(无闪烁), 色彩附件稳定(见下)。
// 色彩附件(变色 bug 修复): 新建 CVPixelBuffer 不带解码帧的 range/矩阵附件,
//   下游 VT 用默认色彩空间 → 画面偏色/过曝。每帧复制 input 的
//   ShouldPropagate 附件到画布, 保证 YUV→私有格式转换 range 正确。
// 实现: 交集 srcRect(窗口∩视频) → memcpy 裁剪到 pieceA → VT 等比缩放到
//   pieceB(srcRect×z, 与 srcRect 同宽高比 → Trim 完整缩放无裁剪) → 贴到画布
//   对应位置(canvasRect = (srcRect−窗口原点)×z) + 清黑其余区域。
// 性能: VT 一次 ~3ms + 区域 memcpy×2 ~2ms + 清黑 ~1ms(预渲染 41ms 预算内);
//       默认(无变换)直通零开销。仅预渲染线程调用(池无锁)。
- (CVPixelBufferRef)bakeUserTransformIntoCanvas:(CVPixelBufferRef)input CF_RETURNS_RETAINED {
    if (!input) return NULL;
    double z = _userZoom;
    if (z < 0.5) z = 0.5;
    if (z > 4.0) z = 4.0;
    if (fabs(z - 1.0) < 0.001 && _userPanX == 0.0 && _userPanY == 0.0) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);  // 默认直通零开销
    }

    // 仅处理双平面 YUV(解码原生 420f/420v); 其他格式直通保底(变换不生效但不崩)
    OSType fmt = CVPixelBufferGetPixelFormatType(input);
    if (CVPixelBufferGetPlaneCount(input) != 2) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }

    size_t W = CVPixelBufferGetWidth(input);
    size_t H = CVPixelBufferGetHeight(input);
    if (W < 16 || H < 16) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }

    // 画布(3 槽轮转, 恒 W×H 固定尺寸): live/snapshot/render 持有期与写入错开
    int slot = _userCanvasSlot;
    _userCanvasSlot = (slot + 1) % 3;
    CVPixelBufferRef canvas = [self userCanvasAtSlot:slot];
    if (!canvas || CVPixelBufferGetWidth(canvas) != W || CVPixelBufferGetHeight(canvas) != H ||
        CVPixelBufferGetPixelFormatType(canvas) != fmt) {
        if (canvas) CVPixelBufferRelease(canvas);
        canvas = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, W, H, fmt, NULL, &canvas) != noErr || !canvas) {
            [self setUserCanvas:NULL atSlot:slot];
            return (CVPixelBufferRef)CVPixelBufferRetain(input);  // 建不出画布: 直通保底
        }
        [self setUserCanvas:canvas atSlot:slot];
    }

    // 色彩附件复制(变色修复): range/矩阵等 ShouldPropagate 附件从解码帧带到画布,
    // 下游 VT 转换色彩语义才正确(教训: BGRA 源缺 range 信息 → 照片过曝)
    CFDictionaryRef colorAtts = CVBufferCopyAttachments(input, kCVAttachmentMode_ShouldPropagate);
    if (colorAtts) {
        CVBufferSetAttachments(canvas, colorAtts, kCVAttachmentMode_ShouldPropagate);
        CFRelease(colorAtts);
    }

    // ===== 窗口(等比, 可出界; 对齐安卓: 两轴 pan 基数统一用源宽 W) =====
    // 窗口与画面反向移动(画面右移 = 窗口向源左侧取, 显示源更左的内容):
    // wx = 居中基准 − panX·W; 画布映射 canvasRect = (srcRect−wx)·z → 窗口恒映射满幅
    double ww = (double)W / z;
    double wh = (double)H / z;
    double wx = ((double)W - ww) / 2.0 - _userPanX * (double)W;  // pan 正=画面右移
    double wy = ((double)H - wh) / 2.0 - _userPanY * (double)W;  // pan 正=画面下移(基数同为 W)

    // 交集 srcRect(窗口∩视频), 偶对齐
    long sx0 = (long)MAX(wx, 0.0), sy0 = (long)MAX(wy, 0.0);
    long sx1 = (long)MIN(wx + ww, (double)W), sy1 = (long)MIN(wy + wh, (double)H);
    sx0 &= ~1L; sy0 &= ~1L;
    sx1 &= ~1L; sy1 &= ~1L;

    CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(canvas, 0);

    if (sx1 <= sx0 || sy1 <= sy0) {
        vcamClearBiPlanarBlack(canvas, fmt);  // 窗口完全出界: 全黑
    } else {
        size_t sw = (size_t)(sx1 - sx0), sh = (size_t)(sy1 - sy0);

        // canvasRect = (srcRect − 窗口原点) × z(等比, 同宽高比), 偶对齐 + clamp 画布内
        double kx = (double)W / ww;   // = z
        long dx0 = lround(((double)sx0 - wx) * kx) & ~1L;
        long dy0 = lround(((double)sy0 - wy) * kx) & ~1L;
        long dx1 = lround(((double)sx1 - wx) * kx) & ~1L;
        long dy1 = lround(((double)sy1 - wy) * kx) & ~1L;
        if (dx0 < 0) dx0 = 0; if (dy0 < 0) dy0 = 0;
        if (dx1 > (long)W) dx1 = (long)W;
        if (dy1 > (long)H) dy1 = (long)H;
        if (dx1 > dx0 && dy1 > dy0) {
            size_t dw = (size_t)(dx1 - dx0), dh = (size_t)(dy1 - dy0);

            vcamClearBiPlanarBlack(canvas, fmt);  // 先清黑(其余区域=黑边)

            if (fabs(kx - 1.0) < 0.001) {
                // z=1(纯平移): 源区域直接贴到画布(零缩放开销)
                vcamCopyRegionBiPlanar(canvas, input, (size_t)dx0, (size_t)dy0,
                                       (size_t)sx0, (size_t)sy0, dw, dh);
            } else {
                // 通用: memcpy 裁剪 srcRect → pieceA, VT 等比缩放 pieceA → pieceB(×z)
                CVPixelBufferRef pieceA = [self userPieceBuffer:&_userShrinkBuffer
                                                          width:sw height:sh format:fmt];
                if (pieceA) {
                    CVPixelBufferLockBaseAddress(pieceA, 0);
                    vcamCopyRegionBiPlanar(pieceA, input, 0, 0, (size_t)sx0, (size_t)sy0, sw, sh);
                    CVPixelBufferUnlockBaseAddress(pieceA, 0);
                    // bake 专用 session(线程冲突修复, 见属性注释): 懒建一次
                    if (!_userTransferSession) {
                        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &_userTransferSession) == noErr) {
                            VTSessionSetProperty(_userTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
                            VTSessionSetProperty(_userTransferSession, CFSTR("RealTime"), kCFBooleanTrue);
                            vcam_gpu_log(@"[vcam] user-transform VT session created (Trim)");
                        }
                    }
                    if (_userTransferSession) {
                        CVPixelBufferRef pieceB = [self userPieceBuffer:&_userPieceBuffer
                                                                  width:dw height:dh format:fmt];
                        if (pieceB) {
                            if (VTPixelTransferSessionTransferImage(_userTransferSession,
                                                                    pieceA, pieceB) == noErr) {
                                CVPixelBufferLockBaseAddress(pieceB, kCVPixelBufferLock_ReadOnly);
                                vcamCopyRegionBiPlanar(canvas, pieceB, (size_t)dx0, (size_t)dy0,
                                                       0, 0, dw, dh);
                                CVPixelBufferUnlockBaseAddress(pieceB, kCVPixelBufferLock_ReadOnly);
                            } else {
                                // VT 失败(罕见): pieceA 1:1 贴画布左上角保底 —— 画面位置/
                                // 缩放不对但绝不全黑, 下一帧重试
                                vcamCopyRegionBiPlanar(canvas, pieceA, 0, 0, 0, 0,
                                                       MIN(sw, W), MIN(sh, H));
                            }
                        }
                    } else {
                        // session 建不出: 1:1 贴左上角保底
                        vcamCopyRegionBiPlanar(canvas, pieceA, 0, 0, 0, 0, MIN(sw, W), MIN(sh, H));
                    }
                }
            }
        } else {
            vcamClearBiPlanarBlack(canvas, fmt);
        }
    }

    CVPixelBufferUnlockBaseAddress(canvas, 0);
    CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    return (CVPixelBufferRef)CVPixelBufferRetain(canvas);  // 池持有 + 返回额外 retain
}

#pragma mark - 三色打光注入(1.3.37, 复刻 Android vcplax apply_color_injection_nv21)

// 420f/420v 是 bi-planar: plane0 = Y(W×H), plane1 = CbCr 交织(W/2 对 × 2 字节/行 H/2)
// 与 Android NV21(VU 交织) 结构同族, 仅 UV 顺序相反: NV21 row[V,U], 420f row[U,V]。
// 公式与 Android 完全一致(含两处用户校准映射):
//   inner_r = radius*(100-feather)*80/10000  → feather=0 等同旧版 20 的羽化
//   max_alpha_256 = intensity*192/100        → intensity=100 等同旧版 75 的强度
static void vcamApplyLightBiPlanar(CVPixelBufferRef buf, uint32_t rgb,
                                   int px, int py, int intensity,
                                   int diameter, int feather) {
    if (!buf || rgb == 0) return;
    if (intensity > 100) intensity = 100;
    if (diameter == 0) diameter = 50;
    if (feather > 100) feather = 100;
    if (px > 100) px = 50;
    if (py > 100) py = 50;

    size_t fw = CVPixelBufferGetWidth(buf);
    size_t fh = CVPixelBufferGetHeight(buf);
    if (fw < 8 || fh < 8) return;

    int cx = (int)((int64_t)px * (int64_t)fw / 100);
    int cy = (int)((int64_t)py * (int64_t)fh / 100);
    int minDim = (int)((fw < fh) ? fw : fh);
    int radius = (int)((int64_t)diameter * minDim / 200);
    if (radius < 2) return;
    // 1.3.69 原版逻辑回退: 羽化/强度映射系数硬编码(原版校准值 —— 羽化
    // 80/10000, 强度 192: intensity=100 等同旧版 75)。不再从 T 表取
    // (T 表参与打光的实验失败, 密钥只保留激活门禁用途)。
    const int featherK = 80;
    const int featherScale = 10000;
    const int intensityK = 192;
    int innerR = radius * (100 - feather) * featherK / featherScale;
    if (innerR < 0) innerR = 0;
    int maxAlpha256 = intensity * intensityK / 100;

    uint8_t r = (rgb >> 16) & 0xFF;
    uint8_t g = (rgb >> 8) & 0xFF;
    uint8_t b = rgb & 0xFF;
    // BT.601 整数近似(与 Android 相同; 直接写进 buffer, 显示端语义与 Android 观感一致)
    uint8_t colorY = (uint8_t)((299 * r + 587 * g + 114 * b) / 1000);
    uint8_t colorU = (uint8_t)((-169 * r - 331 * g + 500 * b) / 1000 + 128);
    uint8_t colorV = (uint8_t)((500 * r - 419 * g - 81 * b) / 1000 + 128);

    uint8_t *yPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buf, 0);
    uint8_t *cPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buf, 1);
    size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(buf, 0);
    size_t cStride = CVPixelBufferGetBytesPerRowOfPlane(buf, 1);
    if (!yPlane || !cPlane) return;

    // ===== Y 平面: 圆形渐变(中心实心 inner_r, 线性羽化到 radius) =====
    // 1.3.45 卡顿优化(用户反馈开打光后画面卡顿掉帧):
    // (1)除法预乘 —— alpha = maxAlpha*(radiusSq-distSq)/featherRange 的整数
    //    除法改为 double 预乘 invAlpha(精度足够: 值域 ≤192), 内层纯乘法;
    // (2)常数 alpha 快路径 —— [cx±innerR] 区间 alpha 恒为 maxAlpha256,
    //    预计算 inv/blend 常量, 每像素 1 乘 1 加 1 移位, 省距离判定分支
    int radiusSq = radius * radius;
    int innerSq = innerR * innerR;
    int featherRange = radiusSq - innerSq;
    double invAlphaY = (featherRange > 0) ? (double)maxAlpha256 / (double)featherRange : 0.0;
    // 常数段混合常量: v' = (v*inv + colorY*alpha) >> 8
    const int cInvA = 256 - maxAlpha256;
    const int cAdd = colorY * maxAlpha256;
    int yStart = cy - radius; if (yStart < 0) yStart = 0;
    int yEnd = cy + radius;   if (yEnd > (int)fh) yEnd = (int)fh;

    for (int y = yStart; y < yEnd; y++) {
        int dy = y - cy;
        int dySq = dy * dy;
        if (dySq >= radiusSq) continue;
        uint8_t *row = yPlane + (size_t)y * yStride;

        // 本行 x 有效范围(整数 sqrt 近似, 同 Android 牛顿一次迭代)
        int remain = radiusSq - dySq;
        int dxMax = radius;
        dxMax = (dxMax + remain / dxMax) / 2;
        if (dxMax > radius) dxMax = radius;

        int rxStart = cx - dxMax; if (rxStart < 0) rxStart = 0;
        int rxEnd = cx + dxMax;   if (rxEnd > (int)fw) rxEnd = (int)fw;
        // 常数 alpha 段边界(内圆在本行的投影, clamp 到行范围)
        int cStart = cx - innerR; if (cStart < rxStart) cStart = rxStart;
        int cEnd = cx + innerR;   if (cEnd > rxEnd) cEnd = rxEnd;
        // 左羽化段
        for (int x = rxStart; x < cStart; x++) {
            int dx = x - cx;
            int distSq = dx * dx + dySq;
            if (distSq < innerSq || distSq >= radiusSq) continue;
            int alpha256 = (int)((radiusSq - distSq) * invAlphaY);
            row[x] = (uint8_t)((row[x] * (256 - alpha256) + colorY * alpha256) >> 8);
        }
        // 常数 alpha 段(内圆, 无距离计算)
        for (int x = cStart; x < cEnd; x++) {
            row[x] = (uint8_t)((row[x] * cInvA + cAdd) >> 8);
        }
        // 右羽化段
        for (int x = cEnd; x < rxEnd; x++) {
            int dx = x - cx;
            int distSq = dx * dx + dySq;
            if (distSq < innerSq || distSq >= radiusSq) continue;
            int alpha256 = (int)((radiusSq - distSq) * invAlphaY);
            row[x] = (uint8_t)((row[x] * (256 - alpha256) + colorY * alpha256) >> 8);
        }
    }

    // ===== CbCr 平面(半分辨率 UV 交织, 每行处理防色度像素方块) =====
    int bw2 = (int)fw / 2, bh2 = (int)fh / 2;
    if (bw2 < 2 || bh2 < 2) return;
    int cx2 = cx / 2, cy2 = cy / 2;
    int radius2 = radius / 2;
    int innerR2 = innerR / 2;
    int radius2Sq = radius2 * radius2;
    int inner2Sq = innerR2 * innerR2;
    int feather2 = radius2Sq - inner2Sq;
    double invAlphaC = (feather2 > 0) ? (double)maxAlpha256 / (double)feather2 : 0.0;
    const int cInvU = 256 - maxAlpha256;
    const int cAddU = colorU * maxAlpha256;
    const int cAddV = colorV * maxAlpha256;

    int y2Start = cy2 - radius2; if (y2Start < 0) y2Start = 0;
    int y2End = cy2 + radius2;   if (y2End > bh2) y2End = bh2;

    for (int y = y2Start; y < y2End; y++) {
        int dy = y - cy2;
        int dySq = dy * dy;
        if (dySq >= radius2Sq) continue;
        uint8_t *row = cPlane + (size_t)y * cStride;

        int remain2 = radius2Sq - dySq;
        int dxMax2 = radius2;
        if (dxMax2 < 1) dxMax2 = 1;
        dxMax2 = (dxMax2 + remain2 / dxMax2) / 2;
        if (dxMax2 > radius2) dxMax2 = radius2;

        int rx2Start = cx2 - dxMax2; if (rx2Start < 0) rx2Start = 0;
        int rx2End = cx2 + dxMax2;   if (rx2End > bw2) rx2End = bw2;
        int c2Start = cx2 - innerR2; if (c2Start < rx2Start) c2Start = rx2Start;
        int c2End = cx2 + innerR2;   if (c2End > rx2End) c2End = rx2End;
        // 左羽化段
        for (int x = rx2Start; x < c2Start; x++) {
            int dx = x - cx2;
            int distSq = dx * dx + dySq;
            if (distSq < inner2Sq || distSq >= radius2Sq) continue;
            int alpha256 = (int)((radius2Sq - distSq) * invAlphaC);
            int idx = x * 2;
            row[idx]     = (uint8_t)((row[idx]     * (256 - alpha256) + colorU * alpha256) >> 8);
            row[idx + 1] = (uint8_t)((row[idx + 1] * (256 - alpha256) + colorV * alpha256) >> 8);
        }
        // 常数 alpha 段
        for (int x = c2Start; x < c2End; x++) {
            int idx = x * 2;
            // 420f plane1 = [Cb, Cr, Cb, Cr...] (UV 交织; NV21 是 VU, 顺序相反)
            row[idx]     = (uint8_t)((row[idx]     * cInvU + cAddU) >> 8);
            row[idx + 1] = (uint8_t)((row[idx + 1] * cInvU + cAddV) >> 8);
        }
        // 右羽化段
        for (int x = c2End; x < rx2End; x++) {
            int dx = x - cx2;
            int distSq = dx * dx + dySq;
            if (distSq < inner2Sq || distSq >= radius2Sq) continue;
            int alpha256 = (int)((radius2Sq - distSq) * invAlphaC);
            int idx = x * 2;
            row[idx]     = (uint8_t)((row[idx]     * (256 - alpha256) + colorU * alpha256) >> 8);
            row[idx + 1] = (uint8_t)((row[idx + 1] * (256 - alpha256) + colorV * alpha256) >> 8);
        }
    }
}

// 注入画布取槽(与 userCanvasAtSlot 同模式)
- (CVPixelBufferRef)lightCanvasAtSlot:(int)slot {
    if (slot == 0) return _lightCanvasPool0;
    if (slot == 1) return _lightCanvasPool1;
    return _lightCanvasPool2;
}
- (void)setLightCanvas:(CVPixelBufferRef)buf atSlot:(int)slot {
    if (slot == 0) _lightCanvasPool0 = buf;
    else if (slot == 1) _lightCanvasPool1 = buf;
    else _lightCanvasPool2 = buf;
}

- (CVPixelBufferRef)injectLightIntoFrame:(CVPixelBufferRef)input CF_RETURNS_RETAINED {
    if (!input) return NULL;
    // 直通快路径: 关闭/无色 → 零开销(常态)
    if (!_lightEnabled || _lightColorRGB == 0) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }
    // 仅双平面 YUV(解码原生 420f/420v); 其他格式直通保底
    if (CVPixelBufferGetPlaneCount(input) != 2) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }

    OSType fmt = CVPixelBufferGetPixelFormatType(input);
    size_t W = CVPixelBufferGetWidth(input);
    size_t H = CVPixelBufferGetHeight(input);
    if (W < 16 || H < 16) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }

    // 注入画布(3 槽轮转): 尺寸/格式变化时重建(切视频)
    int slot = _lightCanvasSlot;
    _lightCanvasSlot = (slot + 1) % 3;
    CVPixelBufferRef canvas = [self lightCanvasAtSlot:slot];
    if (!canvas || CVPixelBufferGetWidth(canvas) != W ||
        CVPixelBufferGetHeight(canvas) != H ||
        CVPixelBufferGetPixelFormatType(canvas) != fmt) {
        if (canvas) CVPixelBufferRelease(canvas);
        canvas = NULL;
        // 约束(记忆): mediaserverd 绝不用 IOSurface attributes, 传 NULL
        if (CVPixelBufferCreate(kCFAllocatorDefault, W, H, fmt, NULL, &canvas) != noErr || !canvas) {
            [self setLightCanvas:NULL atSlot:slot];
            return (CVPixelBufferRef)CVPixelBufferRetain(input);  // 建不出: 直通保底
        }
        [self setLightCanvas:canvas atSlot:slot];
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] light canvas built %zux%zu (slot %d)", W, H, slot]);
    }

    // 源内容整帧复制到画布(Y + CbCr 两平面, 行对齐逐行 memcpy)
    CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(canvas, 0);
    for (int p = 0; p < 2; p++) {
        const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(input, p);
        uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(canvas, p);
        size_t rows = (p == 0) ? H : H / 2;
        size_t srs = CVPixelBufferGetBytesPerRowOfPlane(input, p);
        size_t drs = CVPixelBufferGetBytesPerRowOfPlane(canvas, p);
        size_t rowBytes = MIN(srs, drs);
        if (!src || !dst) continue;
        for (size_t y = 0; y < rows; y++) {
            memcpy(dst + y * drs, src + y * srs, rowBytes);
        }
    }
    CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);

    // 色彩附件复制: 下游 VT 转换色彩语义正确(同 bake 画布)
    CFDictionaryRef colorAtts = CVBufferCopyAttachments(input, kCVAttachmentMode_ShouldPropagate);
    if (colorAtts) {
        CVBufferSetAttachments(canvas, colorAtts, kCVAttachmentMode_ShouldPropagate);
        CFRelease(colorAtts);
    }

    // 圆形渐变光斑注入(参数 clamp 在函数内)
    vcamApplyLightBiPlanar(canvas, _lightColorRGB, _lightX, _lightY,
                           _lightIntensity, _lightDiameter, _lightFeather);

    CVPixelBufferUnlockBaseAddress(canvas, 0);
    return (CVPixelBufferRef)CVPixelBufferRetain(canvas);  // 池持有 + 返回额外 retain
}

// 预渲染用: 同尺寸格式转换(如 BGRA -> 420f), VT 主路径 + CoreImage 回退
// 注意: 用预渲染专用 session（避免与 render 线程的 session 并发调用崩溃）
- (CVPixelBufferRef)convertFormat:(CVPixelBufferRef)input toFormat:(OSType)format CF_RETURNS_RETAINED {
    if (!input) return NULL;
    if (CVPixelBufferGetPixelFormatType(input) == format) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }
    size_t w = CVPixelBufferGetWidth(input);
    size_t h = CVPixelBufferGetHeight(input);

    // VT transfer 同尺寸格式转换（预渲染专用 session）
    CVPixelBufferRef out = [self createBufferWithWidth:w height:h format:format];
    if (out) {
        if (!_prerenderTransferSession) {
            [self setupPrerenderTransferSession];
        }
        if (_prerenderTransferSession &&
            VTPixelTransferSessionTransferImage(_prerenderTransferSession, input, out) == noErr) {
            return out;
        }
        CVPixelBufferRelease(out);
    }

    // CoreImage 回退
    return [self convertWithCoreImage:input toFormat:format width:w height:h];
}

// writeFrame 回退路径: crop fill 渲染到任意格式目标 buffer（保持宽高比填满, 居中裁剪）
// 注意: 用 render 线程专用 CIContext（避免与预渲染线程的 context 并发崩溃）
- (BOOL)renderCropFill:(CVPixelBufferRef)input toPixelBuffer:(CVPixelBufferRef)dst {
    if (!input || !dst || !_renderContext) return NO;

    size_t inW = CVPixelBufferGetWidth(input);
    size_t inH = CVPixelBufferGetHeight(input);
    size_t w = CVPixelBufferGetWidth(dst);
    size_t h = CVPixelBufferGetHeight(dst);
    if (inW == 0 || inH == 0 || w == 0 || h == 0) return NO;

    CIImage *image = [CIImage imageWithCVPixelBuffer:input];
    if (!image) return NO;

    CGFloat scale = MAX((CGFloat)w / (CGFloat)inW, (CGFloat)h / (CGFloat)inH);
    CGFloat offsetX = ((CGFloat)w - (CGFloat)inW * scale) / 2.0;
    CGFloat offsetY = ((CGFloat)h - (CGFloat)inH * scale) / 2.0;
    CGAffineTransform t = CGAffineTransformMakeScale(scale, scale);
    t = CGAffineTransformTranslate(t, offsetX / scale, offsetY / scale);
    CIImage *scaled = [image imageByApplyingTransform:t];

    // renderContext 非线程安全, 内部自锁(多流并发回退时串行)
    [_rotationRenderLock lock];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [_renderContext render:scaled toCVPixelBuffer:dst
                    bounds:CGRectMake(0, 0, (CGFloat)w, (CGFloat)h)
                colorSpace:colorSpace];
    [_rotationRenderLock unlock];

    return YES;
}

// render 路径用: 自适应正交旋转 —— 源/目标宽高比正交(一横一竖)时 CCW90 旋转
// (宽高互换, 保持源格式), 预览流(竖向)与拍照/录像流(横向)各自正确方向。
// 手动旋转(m!=0)时同样参与正交判定(基准见下), CCW90 抵消手动旋转带来的宽高
// 翻转 —— 保证"转"按钮每次点击视觉恰好 +90°。
// token = 帧代数: 同一帧被相机多条流渲染时只 CCW90 一次, 后续流直接复用缓存
// (每流省一次 VT rotate ~2-4ms, 多流场景 CPU 大降)。传 0 = 不缓存。
- (CVPixelBufferRef)adaptiveRotateIfNeeded:(CVPixelBufferRef)src
                               targetWidth:(size_t)targetW
                              targetHeight:(size_t)targetH
                                     token:(uint64_t)token CF_RETURNS_RETAINED {
    if (!src) return NULL;
    if (!_rotationApiAvailable || !_renderRotationSession) {
        return (CVPixelBufferRef)CVPixelBufferRetain(src);
    }

    size_t srcW = CVPixelBufferGetWidth(src);
    size_t srcH = CVPixelBufferGetHeight(src);
    if (!srcW || !srcH || !targetW || !targetH) {
        return (CVPixelBufferRef)CVPixelBufferRetain(src);
    }

    // 正交判定基准 = 假想 manualRotation=0 的源宽高比(2026-08-24 修复视频模式
    // 点"转"直接 180°): 手动角度 90/270 时预渲染已把宽高比翻转, 判定前翻回。
    // 旧行为(m!=0 直接跳过 CCW90)在"预览流为横 buffer + App 固定 transform 旋转
    // 显示"的相机(视频模式主流 2304x1296 横向)下: m=0 时 CCW90 与 App transform
    // 抵消显示正常, 点转后 CW90 与 App transform 同向叠加 → 视觉 180°
    // (实测序列 0→180→270→0, 90° 状态不存在)。基准统一后 CCW90 恰好抵消手动
    // 旋转的宽高翻转: 预览显示角 = m, 每次点击视觉 +90°; 且预览(数据+T_app)与
    // 录像回放(数据+文件 transform)方向天然一致, 不会预览/录制分裂。
    int manualRot = _rotationAngle % 360;
    if (manualRot < 0) manualRot += 360;
    size_t baseW = srcW, baseH = srcH;
    if (manualRot % 180 == 90) {
        baseW = srcH;
        baseH = srcW;
    }

    // 源/目标宽高比正交(一横一竖) -> CCW90
    double srcRatio = (double)baseW / (double)baseH;
    double dstRatio = (double)targetW / (double)targetH;
    BOOL orthogonal = (srcRatio > 1.0 && dstRatio < 1.0) || (srcRatio < 1.0 && dstRatio > 1.0);
    if (!orthogonal) {
        return (CVPixelBufferRef)CVPixelBufferRetain(src);
    }

    // rotation session + 缓存串行锁(内部自锁, 调用方无需再包全局锁)
    [_rotationRenderLock lock];

    OSType fmt = CVPixelBufferGetPixelFormatType(src);

    // 同帧复用(2026-08-16): 同一帧(token)已旋转过且缓存尺寸/格式匹配 → 直接返回,
    // 多流共享一次旋转结果
    if (token != 0 && _adaptiveRotatedGen == token && _adaptiveRotateCache &&
        _adaptiveRotateCacheW == srcH && _adaptiveRotateCacheH == srcW &&
        _adaptiveRotateCacheFmt == fmt) {
        CVPixelBufferRef hit = CVPixelBufferRetain(_adaptiveRotateCache);
        [_rotationRenderLock unlock];
        return hit;
    }

    // CCW90: 宽高互换, 保持源格式(YUV 源旋转后仍是 YUV, 后续 YUV->私有格式转换 range 不变)
    CVPixelBufferRef rotated = NULL;
    if (_adaptiveRotateCache && _adaptiveRotateCacheW == srcH && _adaptiveRotateCacheH == srcW && _adaptiveRotateCacheFmt == fmt) {
        rotated = CVPixelBufferRetain(_adaptiveRotateCache);  // 复用缓存(RotateImage 全覆盖写, 无需清空)
    } else {
        rotated = [self createBufferWithWidth:srcH height:srcW format:fmt];
        if (!rotated) {
            [_rotationRenderLock unlock];
            return (CVPixelBufferRef)CVPixelBufferRetain(src);
        }
        if (_adaptiveRotateCache) CVPixelBufferRelease(_adaptiveRotateCache);
        _adaptiveRotateCache = CVPixelBufferRetain(rotated);
        _adaptiveRotateCacheW = srcH;
        _adaptiveRotateCacheH = srcW;
        _adaptiveRotateCacheFmt = fmt;
    }

    VTSessionSetProperty(_renderRotationSession, _rotationPropertyKey, _rotationCCW90Value);
    OSStatus st = _transferRotationImage(_renderRotationSession, src, rotated);
    if (st == noErr && token != 0) {
        _adaptiveRotatedGen = token;  // 旋转成功才登记代数(失败结果不可缓存)
    }
    [_rotationRenderLock unlock];
    if (st != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] adaptive CCW90 failed: %d fmt=%@ (keep unrotated)",
                      (int)st, [self stringForFormat:fmt]]);
        CVPixelBufferRelease(rotated);
        return (CVPixelBufferRef)CVPixelBufferRetain(src);
    }
    return rotated;  // CF_RETURNS_RETAINED
}

// CoreImage 回退: CI 只渲染到 BGRA(软件渲染器对 planar YUV 支持不可靠, 渲染失败会留下未初始化 buffer → 黑屏/绿屏)
// 目标是 YUV 时再用 VT transfer 转换, VT 失败返回 NULL(绝不返回未初始化的 YUV buffer)
- (CVPixelBufferRef)convertWithCoreImage:(CVPixelBufferRef)input
                                toFormat:(OSType)format
                                  width:(size_t)width
                                 height:(size_t)height CF_RETURNS_RETAINED {
    if (!input || !_preprocessContext) return NULL;

    CIImage *image = [CIImage imageWithCVPixelBuffer:input];
    if (!image) return NULL;

    // 1. CI 渲染到 BGRA（bounds + sRGB, 软件渲染器对 BGRA 支持可靠）
    CVPixelBufferRef bgra = [self getOrCreateBGRABufferWithWidth:width height:height];
    if (!bgra) return NULL;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [_preprocessContext render:image toCVPixelBuffer:bgra
                        bounds:CGRectMake(0, 0, (CGFloat)width, (CGFloat)height)
                    colorSpace:colorSpace];
    

    // 2. 目标就是 BGRA: 直接返回
    if (format == kCVPixelFormatType_32BGRA) {
        return bgra;
    }

    // 3. BGRA -> YUV 用 VT 转换（预渲染专用 session）; 失败返回 NULL
    CVPixelBufferRef output = [self createBufferWithWidth:width height:height format:format];
    if (!output) {
        CVPixelBufferRelease(bgra);
        return NULL;
    }
    if (!_prerenderTransferSession) {
        [self setupPrerenderTransferSession];
    }
    if (!_prerenderTransferSession ||
        VTPixelTransferSessionTransferImage(_prerenderTransferSession, bgra, output) != noErr) {
        CVPixelBufferRelease(output);
        CVPixelBufferRelease(bgra);
        vcam_gpu_log(@"[vcam] convertWithCoreImage: VT BGRA->YUV failed, return NULL (no uninitialized buffer)");
        return NULL;
    }
    CVPixelBufferRelease(bgra);
    return output;
}

- (CVPixelBufferRef)createBufferWithWidth:(size_t)width height:(size_t)height format:(OSType)format CF_RETURNS_RETAINED {
    CVPixelBufferRef buffer = NULL;
    // 不带 IOSurface 属性（mediaserverd 安全）
    OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, NULL, &buffer);
    if (status != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create pixel buffer: %d, size: %zux%zu, format: %@",
                      (int)status, width, height, [self stringForFormat:format]]);
        return NULL;
    }
    return buffer;
}

- (BOOL)transferPixelBuffer:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst {
    return [self transferPixelBuffer:src toPixelBuffer:dst token:0];
}

// per-key 锁获取(池字典自身用 @synchronized 保护)
- (NSLock *)twoStepLockForKey:(NSString *)key {
    @synchronized(self) {
        NSLock *l = _twoStepKeyLockPool[key];
        if (!l) {
            l = [[NSLock alloc] init];
            _twoStepKeyLockPool[key] = l;
        }
        return l;
    }
}

// 一步 transfer per-stream session/lock 获取(2026-08-16: 每流独立 session,
// 同格式多条流不再共用 session 串行 —— 多流完全并行, render 排队延迟大降)
// 死锁修复(2026-08-17): 本方法在持 keyLock 的 transfer 路径内调用(先锁后取 session
// 防 LRU evict 窗口), 旧 @synchronized(self) 与 evict 的 self→keyLock 锁序相反 →
// 换 poolDictLock(最内层专用锁, 持锁期间不做任何其他调用)
- (VTPixelTransferSessionRef)oneStepSessionForKey:(NSString *)key {
    NSValue *v = nil;
    [_poolDictLock lock];
    v = _oneStepSessionPool[key];
    [_poolDictLock unlock];
    if (v) return (VTPixelTransferSessionRef)[v pointerValue];
    VTPixelTransferSessionRef s = NULL;
    if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &s) == noErr && s) {
        VTSessionSetProperty(s, CFSTR("ScalingMode"), CFSTR("Trim"));
        VTSessionSetProperty(s, CFSTR("RealTime"), kCFBooleanTrue);  // 硬件路径提示
        [_poolDictLock lock];
        _oneStepSessionPool[key] = [NSValue valueWithPointer:s];
        [_poolDictLock unlock];
        return s;
    }
    return NULL;
}

- (NSLock *)oneStepLockForKey:(NSString *)key {
    @synchronized(self) {
        NSLock *l = _oneStepKeyLockPool[key];
        if (!l) {
            l = [[NSLock alloc] init];
            _oneStepKeyLockPool[key] = l;
        }
        return l;
    }
}

// Normal 等比缩放 session(预裁剪路径专用): 比例已匹配 → 纯等比拉伸(<0.5% 不可见),
// 无 crop 概念 → 边界 clamp 正常, 规避 VT Trim 非整数 crop 的边界色度 bug
- (VTPixelTransferSessionRef)normalTransferSession {
    if (!gVcamNormalSession) {
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &gVcamNormalSession) == noErr) {
            VTSessionSetProperty(gVcamNormalSession, CFSTR("ScalingMode"), CFSTR("Normal"));
            VTSessionSetProperty(gVcamNormalSession, CFSTR("RealTime"), kCFBooleanTrue);
            vcam_gpu_log(@"[vcam] Lane S2-Normal session created (green-line fix)");
        }
    }
    return gVcamNormalSession;
}

// 绿线修复 v2: 源尺寸 staging 中心整数预裁剪到 dst 比例(per-ratio 槽)。
// 自有 CPU buffer 的 memcpy(非相机 IOSurface, 无 IOFence 死锁风险);
// 裁剪矩形宽高/偏移均偶对齐; token 与源 staging 同步(同帧多流共享跳过 memcpy)。
// 调用方持 _laneLockPrivate。返回 NULL = 裁剪失败(调用方回退 Trim 直转)
- (CVPixelBufferRef)cropStagingForRatio:(CVPixelBufferRef)staging dst:(CVPixelBufferRef)dst srcToken:(uint64_t)srcToken {
    if (!staging || !dst) return NULL;
    size_t sw = CVPixelBufferGetWidth(staging), sh = CVPixelBufferGetHeight(staging);
    size_t dw = CVPixelBufferGetWidth(dst), dh = CVPixelBufferGetHeight(dst);
    if (!sw || !sh || !dw || !dh) return NULL;

    double r = (double)dw / dh;
    size_t cw, ch;
    if ((double)sw / sh > r) { ch = sh; cw = (size_t)(sh * r); }
    else                     { cw = sw; ch = (size_t)(sw / r); }
    cw &= ~(size_t)1; ch &= ~(size_t)1;  // 偶对齐(UV 2:1)
    if (cw < 4 || ch < 4 || cw > sw || ch > sh) return NULL;
    size_t cx = (((sw - cw) / 2) & ~(size_t)1);
    size_t cy = (((sh - ch) / 2) & ~(size_t)1);

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    // 查槽(key = 裁剪尺寸) / LRU 淘汰建槽
    VCamCropStagingSlot *slot = NULL;
    int lruIdx = 0;
    for (int i = 0; i < kVcamCropStagingMax; i++) {
        if (gVcamCropStaging[i].staging &&
            gVcamCropStaging[i].w == cw && gVcamCropStaging[i].h == ch) { slot = &gVcamCropStaging[i]; break; }
        if (gVcamCropStaging[i].lastUse < gVcamCropStaging[lruIdx].lastUse) lruIdx = i;
    }
    if (!slot) {
        int idx = -1;
        for (int i = 0; i < kVcamCropStagingMax; i++) {
            if (!gVcamCropStaging[i].staging) { idx = i; break; }
        }
        if (idx < 0) {  // 全满: LRU 覆盖
            idx = lruIdx;
            CVPixelBufferRelease(gVcamCropStaging[idx].staging);
            gVcamCropStaging[idx].staging = NULL;
        }
        CVPixelBufferRef nb = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, cw, ch,
                                kCVPixelFormatType_32BGRA, NULL, &nb) != noErr || !nb) return NULL;
        gVcamCropStaging[idx].w = cw; gVcamCropStaging[idx].h = ch;
        gVcamCropStaging[idx].staging = nb;
        gVcamCropStaging[idx].token = 0;  // 新槽内容无效, 强制 memcpy
        gVcamCropStaging[idx].lastUse = now;
        slot = &gVcamCropStaging[idx];
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Crop staging built %zux%zu (slot %d)", cw, ch, idx]);
    }
    slot->lastUse = now;
    if (slot->token == srcToken && srcToken != 0) return slot->staging;  // 同帧已裁剪

    // memcpy 中心裁剪(BGRA 4B/px, 自有 CPU buffer); 失败返回 NULL 回退 Trim 直转
    BOOL copied = NO;
    if (CVPixelBufferLockBaseAddress(staging, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
        if (CVPixelBufferLockBaseAddress(slot->staging, 0) == kCVReturnSuccess) {
            uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddress(staging);
            uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddress(slot->staging);
            size_t srb = CVPixelBufferGetBytesPerRow(staging);
            size_t drb = CVPixelBufferGetBytesPerRow(slot->staging);
            if (sb && db && srb >= cw * 4 && drb >= cw * 4) {
                size_t rowBytes = cw * 4;
                for (size_t y = 0; y < ch; y++) {
                    memcpy(db + y * drb, sb + (cy + y) * srb + cx * 4, rowBytes);
                }
                slot->token = srcToken;
                copied = YES;
            }
            // 色彩附件同步(锁内, buffer 无 GPU 在飞): 源有附件就拷, 无则维持
            vcamSyncColorAttachments(staging, slot->staging);
            CVPixelBufferUnlockBaseAddress(slot->staging, 0);
        }
        CVPixelBufferUnlockBaseAddress(staging, kCVPixelBufferLock_ReadOnly);
    }
    return copied ? slot->staging : NULL;
}

// 发热优化(2026-08-20 v3): 取/建私有格式 @ mid(源+2) 尺寸的 YUV 中转槽, 并把
// s2src(BGRA) 转换进去(RGB→YUV 在 ~0.3MP 源分辨率完成 ~1ms; 3MP 直转要 8.1ms)。
// 同帧(token 匹配)已转 → 直接复用跳过转换。
// s2a/mid 创建失败 → memo 禁用该格式拆段(调用方永久走直转, 零重试)。
// 调用方持 _laneLockPrivate。返回 NULL = 本次拆段不可用(调用方回退直转)
- (CVPixelBufferRef)yuvStagingForSrc:(CVPixelBufferRef)s2src
                                  fmt:(uint32_t)dstFormat
                             srcToken:(uint64_t)srcToken {
    if (!s2src) return NULL;
    size_t sw = CVPixelBufferGetWidth(s2src), sh = CVPixelBufferGetHeight(s2src);
    if (!sw || !sh) return NULL;
    // mid = 源+2(偶): 与源有尺寸差强制走缩放路径(同尺寸 -12905), 偶对齐保 UV
    size_t mw = (sw + 2) & ~(size_t)1, mh = (sh + 2) & ~(size_t)1;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    VCamYuvStagingSlot *slot = NULL;
    int lruIdx = 0;
    for (int i = 0; i < kVcamYuvStagingMax; i++) {
        if (gVcamYuvStaging[i].staging && gVcamYuvStaging[i].fmt == dstFormat &&
            gVcamYuvStaging[i].w == mw && gVcamYuvStaging[i].h == mh) {
            slot = &gVcamYuvStaging[i]; break;
        }
        if (gVcamYuvStaging[i].lastUse < gVcamYuvStaging[lruIdx].lastUse) lruIdx = i;
    }
    if (!slot) {
        int idx = -1;
        for (int i = 0; i < kVcamYuvStagingMax; i++) {
            if (!gVcamYuvStaging[i].staging) { idx = i; break; }
        }
        if (idx < 0) {  // 全满: LRU 覆盖
            idx = lruIdx;
            CVPixelBufferRelease(gVcamYuvStaging[idx].staging);
            gVcamYuvStaging[idx].staging = NULL;
        }
        CVPixelBufferRef nb = NULL;
        OSStatus cc = CVPixelBufferCreate(kCFAllocatorDefault, mw, mh, dstFormat, NULL, &nb);
        if (cc != noErr || !nb) {
            vcamYuvSplitDisable(dstFormat);  // mid 创建失败: memo 永久直转(防每帧重试)
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] YUV mid create failed (%d) %zux%zu fmt=0x%x, split disabled", (int)cc, mw, mh, (unsigned)dstFormat]);
            return NULL;
        }
        gVcamYuvStaging[idx].fmt = dstFormat;
        gVcamYuvStaging[idx].w = mw; gVcamYuvStaging[idx].h = mh;
        gVcamYuvStaging[idx].staging = nb;
        gVcamYuvStaging[idx].token = 0;  // 新槽内容无效, 强制转换
        gVcamYuvStaging[idx].lastUse = now;
        slot = &gVcamYuvStaging[idx];
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] YUV upscale staging built %zux%zu fmt=0x%x (slot %d, heat fix)", mw, mh, (unsigned)dstFormat, idx]);
    }
    slot->lastUse = now;
    if (slot->token == srcToken && srcToken != 0) return slot->staging;  // 同帧已转

    // s2a: BGRA → 私有 @ mid(Normal 微拉伸 <0.3% 不可见, 强制缩放路径);
    // VT 自动携带色彩附件(非 memcpy), 无需手动同步
    OSStatus st = VTPixelTransferSessionTransferImage([self normalTransferSession], s2src, slot->staging);
    if (st != noErr) {
        slot->token = 0;
        vcamYuvSplitDisable(dstFormat);  // s2a 失败: memo 永久直转
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] YUV s2a failed (%d) fmt=0x%x, split disabled", (int)st, (unsigned)dstFormat]);
        return NULL;
    }
    slot->token = srcToken;
    return slot->staging;
}

- (BOOL)transferPixelBuffer:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst token:(uint64_t)token {
    if (!src || !dst) return NO;

    OSType dstFormat = CVPixelBufferGetPixelFormatType(dst);
    size_t dstW = CVPixelBufferGetWidth(dst);
    size_t dstH = CVPixelBufferGetHeight(dst);
    size_t srcW = CVPixelBufferGetWidth(src);
    size_t srcH = CVPixelBufferGetHeight(src);

    // ===== 千面模型固定车道(2026-08-19 相机开启猝死链路根治, 全 App 通用) =====
    // 设备实证(1.2.4): 相机开启多流突发时 per-key 池体系在热路径现场建 session/
    // 建 staging + LRU 淘汰重建 + 组锁串行 → 相机回调线程阻塞 → watchdog 杀
    // mediaserverd(13:48:42-13:49:02 四连崩, 无 .ips 无 CPU 超限)。
    // 对齐千面(唯一稳定参照, 3 全局 session): 固定车道 + 车道锁, 热路径零创建
    // 零淘汰零抖动; 私有格式两步法整车道串行(千面等价稳定模型, 多流排队延迟
    // 可接受 —— 稳定性优先于并行)。token 复用保留(同帧多消费者 s1 免单 +
    // CPU 降载冻结复用)。按格式(非按流)熔断: 同 fourcc 连续失败 2 次 →
    // 永久跳过该格式保真实相机(防 wakeups 风暴, '18f0' 分析流教训)。
    // 卡顿优化(2026-08-19): 熔断查表走文件级 memo(零装箱零字典),
    // 熔断写入路径 vcamLaneMemoInvalidate 同步刷新
    {
        BOOL laneOff = NO;
        int hit = -1;
        for (int i = 0; i < 4; i++) {
            if (gVcamLaneMemoFmt[i] == dstFormat) { hit = i; laneOff = gVcamLaneMemoOff[i]; break; }
        }
        if (hit < 0) {
            laneOff = [_laneDisabled[@(dstFormat)] boolValue];
            vcamLaneMemoInvalidate((uint32_t)dstFormat, laneOff);  // 建槽并缓存
        }
        // 1.3.48 熔断自动恢复: 过期(30s)后解除熔断 + 清失败计数, 给一次重试
        // 窗口 —— -12902/-12905 常是视频切换/会话竞态的临时态, 永久 keep
        // camera = "相机不替换"直接来源。重试再失败会重新计数熔断(自愈闭环)
        if (laneOff && vcamLaneMemoExpired((uint32_t)dstFormat)) {
            vcamLaneMemoInvalidate((uint32_t)dstFormat, NO);
            gVcamLaneFailCnt[vcamLaneFailSlot((uint32_t)dstFormat)] = 0;
            @synchronized(self) {
                _laneDisabled[@(dstFormat)] = @NO;
            }
            laneOff = NO;
            vcam_gpu_log([NSString stringWithFormat:
                @"[vcam] lane 0x%x circuit-broken expired, retry enabled (1.3.48)",
                (unsigned)dstFormat]);
        }
        if (laneOff) return NO;
    }

    BOOL isYuvLane = ((dstFormat & 0xffffffef) == '420f' || dstFormat == 0x70343230 /* p420 */);
    BOOL isBgraLane = (dstFormat == kCVPixelFormatType_32BGRA);

    // ---- 私有格式车道: 两步法(src→BGRA staging→私有), 整车道串行 ----
    if (!isBgraLane && !isYuvLane) {
        [_laneLockPrivate lock];
        // s1/s2 会话懒建(进程内仅一次, 之后热路径零创建)
        if (!_twoStepS1Session) {
            if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &_twoStepS1Session) == noErr) {
                VTSessionSetProperty(_twoStepS1Session, CFSTR("ScalingMode"), CFSTR("Trim"));
                VTSessionSetProperty(_twoStepS1Session, CFSTR("RealTime"), kCFBooleanTrue);
                vcam_gpu_log(@"[vcam] Lane S1 session created (Trim)");
            }
        }
        if (!_privateTransferSession) {
            if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &_privateTransferSession) == noErr) {
                VTSessionSetProperty(_privateTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
                VTSessionSetProperty(_privateTransferSession, CFSTR("RealTime"), kCFBooleanTrue);
                vcam_gpu_log(@"[vcam] Lane S2(private) session created (Trim)");
            }
        }

        // ===== 直转快路径(2026-08-24 视频模式帧率优化): YUV 源 → 私有格式一步直转 =====
        // 设备遥测实证: p420 流 420f→p420 直转仅 ~2.8ms/3MP, 而下方两步法
        // 420f→BGRA(2MP 源尺寸 RGB 中转 ~13ms)+BGRA→私有(3MP 缩放 ~8ms) 合计
        // ~21ms/帧 —— |xv0/-8f0 流被 BGRA 中转吃掉近半 CPU(EMA 72-83% 触发
        // 紧急节流 20fps, 每秒丢 4 帧 = 视频模式卡顿掉帧主因)。
        // 约束: 私有格式写入须有尺寸差(同尺寸 -12905, 1.3.7 BGRA 实证),
        // 预渲染源(2MP 级)与相机流目标(≥2.5MP)天然满足; 源须 YUV planar。
        // 千面 0xb0f8 同款直转架构; YUV range/矩阵 attachments 全程保留,
        // 无 BGRA 中转的高光洗白风险。首帧真实 dst 试跑(拆段 v3 同款):
        // 成功 memo=1 此后恒走直转(零 BGRA staging 零中转); 失败 memo=-1
        // 回退(同帧内完成, fence 顺序化无闪烁)。失败 30s 后延迟重试(1.3.36,
        // 最多 3 次): -12902 疑似启动竞态而非格式永久不支持。
        {
            OSType srcFmtD = CVPixelBufferGetPixelFormatType(src);
            BOOL srcYuvPlanar = (srcFmtD == '420f' || srcFmtD == '420v' ||
                                 srcFmtD == 0x70343230);
            if (srcYuvPlanar && (srcW != dstW || srcH != dstH) &&
                vcamYuvDirectState(dstFormat) >= 0 && _privateTransferSession) {
                int8_t prevState = vcamYuvDirectState(dstFormat);
                OSStatus stD = VTPixelTransferSessionTransferImage(_privateTransferSession, src, dst);
                if (stD == noErr) {
                    if (prevState == 0) {
                        vcamYuvDirectSet(dstFormat, 1);
                        vcam_gpu_log([NSString stringWithFormat:
                            @"[vcam] lane direct YUV->0x%x OK (fast path, BGRA detour skipped)",
                            (unsigned)dstFormat]);
                    }
                    vcamLaneNoteSuccess((uint32_t)dstFormat);
                    [self noteStreamRenderFmt:(uint32_t)dstFormat w:(uint32_t)dstW h:(uint32_t)dstH pixels:(uint64_t)dstW * dstH];
                    [_laneLockPrivate unlock];
                    return YES;
                }
                vcamYuvDirectSet(dstFormat, -1);
                vcam_gpu_log([NSString stringWithFormat:
                    @"[vcam] lane direct YUV->0x%x failed (%d), fallback two-step",
                    (unsigned)dstFormat, (int)stD]);
            }
            // ===== YUV staging 两步法(1.3.36 帧率优化 v2): 直转失败格式的 YUV 域中转 =====
            // 旧两步法 YUV→BGRA(源尺寸 RGB 中转 ~13ms)→私有(~8ms) 的 BGRA 段是
            // CPU 大头。此处先试: s1' YUV→420f(源尺寸, 纯 YUV 域 ~1-2ms, token
            // 复用同帧多消费者) + s2' 420f→私有(带缩放) —— staging 自建干净
            // buffer 无 cleanAperture 附件, s2' 与直转同款 VT 操作但源参数
            // 干净, 可能绕过直转的 -12902/-12905 限制。首帧试跑: 成功 memo=1
            // 恒走此路; 失败 memo=-1 同帧继续 BGRA 两步法(不丢帧)。YUV→YUV
            // 无 RGB 往返, 色彩保真优于 BGRA 中转(无高光洗白)。
            if (srcYuvPlanar && (srcW != dstW || srcH != dstH) &&
                vcamYuvDirectState(dstFormat) == -1 &&
                vcamYuvStageState(dstFormat) >= 0 && _privateTransferSession) {
                VCamYuvLaneSlot *yslot = NULL;
                for (int i = 0; i < kVcamYuvLaneMax; i++) {
                    if (gVcamYuvLane[i].staging &&
                        gVcamYuvLane[i].w == srcW && gVcamYuvLane[i].h == srcH) {
                        yslot = &gVcamYuvLane[i];
                        break;
                    }
                }
                if (!yslot) {
                    for (int i = 0; i < kVcamYuvLaneMax; i++) {
                        if (!gVcamYuvLane[i].staging) {
                            CVPixelBufferRef nb = NULL;
                            if (CVPixelBufferCreate(kCFAllocatorDefault, srcW, srcH,
                                                    '420f', NULL, &nb) == noErr && nb) {
                                gVcamYuvLane[i].w = srcW;
                                gVcamYuvLane[i].h = srcH;
                                gVcamYuvLane[i].staging = nb;
                                gVcamYuvLane[i].token = 0;
                                yslot = &gVcamYuvLane[i];
                                vcam_gpu_log([NSString stringWithFormat:
                                    @"[vcam] YUV lane staging built %zux%zu (slot %d)",
                                    srcW, srcH, i]);
                            }
                            break;
                        }
                    }
                }
                BOOL ysOk = NO;
                if (yslot && _twoStepS1Session) {
                    if (token != 0 && yslot->token == token) {
                        ysOk = YES;  // 同帧已转
                    } else {
                        OSStatus st1 = VTPixelTransferSessionTransferImage(_twoStepS1Session, src, yslot->staging);
                        if (st1 == noErr) {
                            yslot->token = token;
                            ysOk = YES;
                        } else {
                            yslot->token = 0;
                        }
                    }
                    if (ysOk) {
                        OSStatus st2 = VTPixelTransferSessionTransferImage(_privateTransferSession, yslot->staging, dst);
                        if (st2 == noErr) {
                            if (vcamYuvStageState(dstFormat) == 0) {
                                vcamYuvStageSet(dstFormat, 1);
                                vcam_gpu_log([NSString stringWithFormat:
                                    @"[vcam] lane YUV-staging 0x%x OK (YUV detour, BGRA detour skipped)",
                                    (unsigned)dstFormat]);
                            }
                            [self noteStreamRenderFmt:(uint32_t)dstFormat w:(uint32_t)dstW h:(uint32_t)dstH pixels:(uint64_t)dstW * dstH];
                            [_laneLockPrivate unlock];
                            return YES;
                        }
                        vcamYuvStageSet(dstFormat, -1);
                        vcam_gpu_log([NSString stringWithFormat:
                            @"[vcam] lane YUV-staging 0x%x failed (%d), fallback BGRA two-step",
                            (unsigned)dstFormat, (int)st2]);
                    }
                }
            }
        }
        // staging 按源尺寸缓存(2026-08-19 交替重建风暴修复): 源有 2 种尺寸并存
        // (原始/CCW90 旋转后), 每尺寸一条, 建后零重建; 槽位数组零分配(卡顿优化)
        VCamLaneStagingSlot *slot = NULL;
        for (int i = 0; i < kVcamLaneStagingMax; i++) {
            if (gVcamLaneStaging[i].staging &&
                gVcamLaneStaging[i].w == srcW && gVcamLaneStaging[i].h == srcH) {
                slot = &gVcamLaneStaging[i];
                break;
            }
        }
        if (!slot) {
            // 空槽现建(每尺寸进程内仅一次; 上限 4 条防极端场景)
            for (int i = 0; i < kVcamLaneStagingMax; i++) {
                if (!gVcamLaneStaging[i].staging) {
                    CVPixelBufferRef nb = NULL;
                    if (CVPixelBufferCreate(kCFAllocatorDefault, srcW, srcH,
                                            kCVPixelFormatType_32BGRA, NULL, &nb) == noErr && nb) {
                        gVcamLaneStaging[i].w = srcW;
                        gVcamLaneStaging[i].h = srcH;
                        gVcamLaneStaging[i].staging = nb;  // 所有权归槽位
                        gVcamLaneStaging[i].token = 0;
                        slot = &gVcamLaneStaging[i];
                        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Lane staging built %zux%zu (slot %d)", srcW, srcH, i]);
                    }
                    break;
                }
            }
        }

        BOOL ok = NO;
        if (_twoStepS1Session && _privateTransferSession && slot) {
            CVPixelBufferRef staging = slot->staging;
            // s1: token 复用(同帧多消费者/CPU 冻结 token → 跳过缩放只付 s2)
            if (token != 0 && slot->token == token) {
                ok = YES;  // staging 内容已是本帧
            } else {
                OSStatus st1 = VTPixelTransferSessionTransferImage(_twoStepS1Session, src, staging);
                if (st1 == noErr) {
                    slot->token = token;  // token=0 也记(下帧不匹配自然重付)
                    ok = YES;
                } else {
                    slot->token = 0;  // staging 内容不可信
                    vcam_gpu_log([NSString stringWithFormat:@"[vcam] lane s1 failed (%d)", (int)st1]);
                }
            }
            // s2: BGRA staging → 私有目标(逐流尺寸/格式不同, VT 内部处理)
            if (ok) {
                CVPixelBufferRef s2src = staging;
                // 录像绿线修复 v2(2026-08-19, v1 CPU 修相机 surface 因 IOFence 死锁回滚):
                // VT Trim crop offset 非整数时, RGB→YUV420 私有格式边界半像素越界 →
                // 边缘 UV=0 → 绿线(竖屏录制文件旋转 90° 后左侧)。
                // v1 教训(设备实证 1.3.3 录制黑屏): VT 写完对相机 IOSurface 做
                // CVPixelBufferLockBaseAddress + CPU 写 —— 录制时编码器持该 surface
                // GPU fence, CPU map 与 fence 互等死锁(同帧去重 v2 的 IOFence 事故
                // 同款) → GPU 管线卡死 → 录制黑屏。相机 surface 绝不允许 CPU lock。
                // v2: 裁剪几何前移 —— 非整数 crop 命中时, 把自有 staging(纯 CPU
                // buffer)中心整数预裁剪到 dst 比例(per-ratio 槽, memcpy 安全),
                // s2 用 Normal 等比缩放(比例匹配无 crop → 无边界重采样 → 无绿线)。
                {
                    BOOL fixH = NO, fixV = NO;
                    vcamTrimFractionalCrop(staging, dst, &fixH, &fixV);
                    if (fixH || fixV) {
                        CVPixelBufferRef cropped = [self cropStagingForRatio:staging dst:dst srcToken:slot->token];
                        if (cropped) s2src = cropped;
                    }
                }
                CFAbsoluteTime t2 = CFAbsoluteTimeGetCurrent();
                // Normal 车道(预裁剪路径): 等比拉伸填充, 比例已匹配变形 <0.5% 不可见,
                // 无 crop 概念 → 边界 clamp 正常; 直转路径(整数 crop)仍走 Trim
                BOOL useNormal = (s2src != staging);
                VTPixelTransferSessionRef s2sess = useNormal
                    ? [self normalTransferSession] : _privateTransferSession;
                // 发热优化(2026-08-20 v3): 大倍率上采样(dst 像素 >4x 源)拆两段 ——
                // s2a: BGRA→私有 @ 源+2(RGB→YUV 在 ~0.3MP 源分辨率完成 ~1ms);
                // s2b: 私有→私有 同格式缩放(YUV 域上采样, p420 直转同款快路径 ~3ms)。
                // 设备遥测实证: |xv0 3MP 直转 8.1ms/帧 ×24fps ≈19% CPU(发热主热点),
                // 拆段后 ~4ms。首帧直接在真实 dst 试跑全链: s2b 失败同帧内 direct
                // 立即整帧重写(同一 render 调用, fence 顺序化无闪烁) + memo 永久
                // 回退; 熔断只计 direct 失败(拆段失败≠格式不可用)
                OSStatus st2 = -1;
                uint64_t dstPx = (uint64_t)dstW * dstH;
                uint64_t srcPx = (uint64_t)CVPixelBufferGetWidth(s2src) * CVPixelBufferGetHeight(s2src);
                if (dstPx > 4 * srcPx && vcamYuvSplitState((uint32_t)dstFormat) >= 0) {
                    CVPixelBufferRef yuvMid = [self yuvStagingForSrc:s2src fmt:(uint32_t)dstFormat srcToken:slot->token];
                    if (yuvMid) {
                        st2 = VTPixelTransferSessionTransferImage(s2sess, yuvMid, dst);
                        if (st2 != noErr) {
                            vcamYuvSplitDisable((uint32_t)dstFormat);  // s2b 不支持: memo 永久直转
                            vcam_gpu_log([NSString stringWithFormat:@"[vcam] YUV s2b failed (%d) fmt=0x%x, split disabled", (int)st2, (unsigned)dstFormat]);
                        }
                    }
                }
                if (st2 != noErr) {
                    st2 = VTPixelTransferSessionTransferImage(s2sess, s2src, dst);
                }
                [self noteStageTimingFmt:(uint32_t)dstFormat w:(uint32_t)dstW h:(uint32_t)dstH stage:2 ms:(CFAbsoluteTimeGetCurrent() - t2) * 1000.0];
                if (st2 != noErr) ok = NO;
            }
        }
        [_laneLockPrivate unlock];

        if (ok) {
            vcamLaneNoteSuccess((uint32_t)dstFormat);
            [self noteStreamRenderFmt:(uint32_t)dstFormat w:(uint32_t)dstW h:(uint32_t)dstH pixels:(uint64_t)dstW * dstH];
            return YES;
        }
        // 失败计数/熔断(按格式, 1.3.48 计数文件级+成功清零): 连续 2 次 →
        // 熔断(30s 自动恢复, 同步刷新 memo)
        {
            int32_t fails = ++gVcamLaneFailCnt[vcamLaneFailSlot((uint32_t)dstFormat)];
            if (fails >= 2) {
                @synchronized(self) { _laneDisabled[@(dstFormat)] = @YES; }
                vcamLaneMemoInvalidate(dstFormat, YES);
                vcam_gpu_log([NSString stringWithFormat:@"[vcam] lane CIRCUIT-BROKEN format %u (err, keep camera)", (unsigned)dstFormat]);
            }
        }
        return NO;
    }

    // ---- 标准格式车道: 一步直转, 固定会话 ----
    VTPixelTransferSessionRef session = isBgraLane ? _bgraTransferSession : _yuvTransferSession;
    NSLock *laneLock = isBgraLane ? _laneLockBGRA : _laneLockYUV;
    if (!session) {
        if (isBgraLane) [self setupBGRATransferSession]; else [self setupYUVTransferSession];
        session = isBgraLane ? _bgraTransferSession : _yuvTransferSession;
    }
    if (!session || !laneLock) return NO;

    [laneLock lock];

    // 1.3.50 视频模式预览绿边修复(标准 YUV 车道): BGRA 源 → YUV420 dst 且 Trim
    // crop offset 非整数时, RGB→YUV 转换 UV 平面边界半像素越界 → 左缘 UV=0 →
    // 绿色竖条(与 1.3.3 录像绿线同机理 —— 当时 v2 修复只接在私有两步法 lane,
    // 标准车道漏接)。视频模式预览流(p420 1080x2340) YUV 直转失败走 lazy BGRA
    // 路径(404x720 BGRA → 1080x2340, crop off=35.85 非偶数), 1.3.48 熔断自愈
    // 恢复替换后暴露; 拍照流尺寸组合不同不受影响。修法同 v2: 偶数中心预裁剪
    // (自有 CPU buffer memcpy) + Normal 等比缩放(比例匹配无 crop 无边界重采样)。
    // cropStagingForRatio/normalTransferSession 归 _laneLockPrivate 保护(私有
    // lane 同款), 锁序 laneLock→Private 单向, 与私有 lane(_laneLockPrivate 内
    // 不取 laneLock)无倒置
    CVPixelBufferRef xferSrc = src;
    VTPixelTransferSessionRef xferSess = session;
    if (isYuvLane && !isBgraLane &&
        CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA) {
        BOOL fixH = NO, fixV = NO;
        vcamTrimFractionalCrop(src, dst, &fixH, &fixV);
        if (fixH || fixV) {
            [_laneLockPrivate lock];
            CVPixelBufferRef cropped = [self cropStagingForRatio:src dst:dst srcToken:token];
            if (cropped) {
                VTPixelTransferSessionRef ns = [self normalTransferSession];
                if (ns) {
                    xferSrc = cropped;
                    xferSess = ns;
                    static BOOL loggedOnce = NO;
                    if (!loggedOnce) {
                        loggedOnce = YES;
                        vcam_gpu_log([NSString stringWithFormat:
                            @"[vcam] green-edge fix: BGRA->YUV lane fractional crop, pre-crop %zux%zu (1.3.50)",
                            CVPixelBufferGetWidth(cropped), CVPixelBufferGetHeight(cropped)]);
                    }
                }
            }
            [_laneLockPrivate unlock];
        }
    }

    CFAbsoluteTime tOp = CFAbsoluteTimeGetCurrent();
    OSStatus status = VTPixelTransferSessionTransferImage(xferSess, xferSrc, dst);
    [self noteStageTimingFmt:(uint32_t)dstFormat w:(uint32_t)dstW h:(uint32_t)dstH stage:2 ms:(CFAbsoluteTimeGetCurrent() - tOp) * 1000.0];
    [laneLock unlock];

    if (status == noErr) {
        vcamLaneNoteSuccess((uint32_t)dstFormat);
        [self noteStreamRenderFmt:(uint32_t)dstFormat w:(uint32_t)dstW h:(uint32_t)dstH pixels:(uint64_t)dstW * dstH];
        return YES;
    }
    // 失败计数/熔断(按格式, 1.3.48 计数文件级+成功清零): 连续 2 次 →
    // 熔断(30s 自动恢复)
    {
        int32_t fails = ++gVcamLaneFailCnt[vcamLaneFailSlot((uint32_t)dstFormat)];
        if (fails >= 2) {
            @synchronized(self) { _laneDisabled[@(dstFormat)] = @YES; }
            vcamLaneMemoInvalidate(dstFormat, YES);
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] lane CIRCUIT-BROKEN format %u (err %d, keep camera)",
                          (unsigned)dstFormat, (int)status]);
        }
    }
    return NO;
}

// 按流渲染统计累计(诊断) —— 定长槽位版(2026-08-19 卡顿优化):
// 零 NSString/NSNumber 分配, 短临界区纯数字累计(旧字典版每帧 ~5 次分配)。
// 死锁修复(2026-08-17 沿用): 专用 statsLock, 锁序 @synchronized(self)/keyLock → statsLock 单向
static VCamStatSlot *vcam_stat_slot(uint32_t fmt, uint32_t w, uint32_t h) {
    for (int i = 0; i < kVcamStatSlots; i++) {
        if (gVcamStatSlots[i].fmt == fmt && gVcamStatSlots[i].w == w && gVcamStatSlots[i].h == h) {
            return &gVcamStatSlots[i];
        }
        if (gVcamStatSlots[i].fmt == 0 && gVcamStatSlots[i].renders == 0) {
            gVcamStatSlots[i].fmt = fmt;
            gVcamStatSlots[i].w = w;
            gVcamStatSlots[i].h = h;
            return &gVcamStatSlots[i];
        }
    }
    return NULL;  // 槽位满(>12 条流, 罕见): 丢弃统计不影响渲染
}

- (void)noteStreamRenderFmt:(uint32_t)fmt w:(uint32_t)w h:(uint32_t)h pixels:(uint64_t)px {
    [_statsLock lock];
    VCamStatSlot *s = vcam_stat_slot(fmt, w, h);
    if (s) { s->renders++; s->pixels += px; }
    [_statsLock unlock];
}

// 每流 stage 耗时累计(诊断): stage 1=缩放 2=格式转换
- (void)noteStageTimingFmt:(uint32_t)fmt w:(uint32_t)w h:(uint32_t)h stage:(int)stage ms:(double)ms {
    [_statsLock lock];
    VCamStatSlot *s = vcam_stat_slot(fmt, w, h);
    if (s) {
        if (stage == 1) { s->s1TotalMs += ms; s->s1Cnt++; }
        else            { s->s2TotalMs += ms; s->s2Cnt++; }
    }
    [_statsLock unlock];
}

// 流 key LRU(2026-08-16 黑屏修复): 每次流访问把 key 移到 MRU 尾部,
// 超 kVcamMaxStreamKeys 淘汰最旧 key 的全部池资源(session/staging/token/锁)。
// 防切前后摄/换分辨率场景 key 无限累积 → mediaserverd 内存超限被杀(黑屏循环)。
// 熔断标记(twoStepDisabledPool)保留: 熔断语义是永久的, 淘汰后重试已确认
// 不支持的组合会复发 wakeups 风暴。持锁中的 NSLock 淘汰安全: 持有线程栈上
// 有强引用, unlock 释放后才可能 dealloc
// 12→6(2026-08-18 砍常驻内存): 实测活跃可见流 ≤6(预览+照片+录像×前后摄),
// per-key staging 是常驻大头, 千面无 per-key 池也不黑屏; 超出即最旧淘汰
static const NSUInteger kVcamMaxStreamKeys = 6;

// 单 key 资源释放体(2026-08-17 提取共用): 调用方必须已持 @synchronized(self)。
// LRU 超限淘汰与空闲全量清空(releaseIdleMemory)共用。
- (void)evictStreamKeyResourcesLocked:(NSString *)old {
    if (!old) return;
    // 修复(2026-08-16 崩溃循环): 淘汰必须先持该 key 的 per-key 锁 —— 否则
    // 另一线程正持锁 transfer 该 staging/session, 我们并发 release →
    // use-after-free → mediaserverd 启动即崩循环(相机全黑)。
    // 锁对象先取栈引用(防淘汰后别人拿不到/自身被释放), 字典条目 unlock 后清。
    // 锁序(2026-08-17 死锁修复后): synchronized(self)→keyLock→poolDictLock
    // 单向无环 —— transfer 路径持 keyLock 时只进 statsLock/poolDictLock,
    // 永不进 @synchronized(self)
    NSLock *olock = _oneStepKeyLockPool[old];
    NSLock *tlock = _twoStepKeyLockPool[old];
    if (olock) [olock lock];
    if (tlock) [tlock lock];

    void (*invalidateSession)(VTPixelTransferSessionRef) =
        (void (*)(VTPixelTransferSessionRef))dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");

    // 字典条目取出/移除过 poolDictLock(与懒建端一致, 防 concurrent mutate);
    // 资源释放(invalidate/Release)在锁外执行, poolDictLock 保持最内层短临界区
    NSValue *osv = nil, *tsv = nil, *stv = nil, *rcv = nil, *rbsv = nil;
    id poolObj = nil;
    [_poolDictLock lock];
    osv = _oneStepSessionPool[old];
    if (osv) [_oneStepSessionPool removeObjectForKey:old];
    tsv = _twoStepSessionPool[old];
    if (tsv) [_twoStepSessionPool removeObjectForKey:old];
    stv = _twoStepStagingPool[old];
    if (stv) [_twoStepStagingPool removeObjectForKey:old];
    [_twoStepTokenPool removeObjectForKey:old];
    [_twoStepFailCountPool removeObjectForKey:old];
    poolObj = _bgraBufferPoolMap[old];
    if (poolObj) [_bgraBufferPoolMap removeObjectForKey:old];
    if (![old hasPrefix:@"g:"]) {
        rcv = _resultCachePool[old];
        if (rcv) [_resultCachePool removeObjectForKey:old];
        [_resultCacheTokenPool removeObjectForKey:old];
        [_lastReqTokenPool removeObjectForKey:old];
        rbsv = _resultBlitSessionPool[old];
        if (rbsv) [_resultBlitSessionPool removeObjectForKey:old];
    }
    [_poolDictLock unlock];

    // one-step session
    if (osv) {
        VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[osv pointerValue];
        if (s && invalidateSession) invalidateSession(s);
    }

    // two-step session + staging(大头: 12MP 流级 BGRA ~12-48MB/条)
    if (tsv) {
        VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[tsv pointerValue];
        if (s && invalidateSession) invalidateSession(s);
    }
    if (stv) {
        CVPixelBufferRef b = (CVPixelBufferRef)[stv pointerValue];
        if (b) CVPixelBufferRelease(b);
    }

    // BGRA 分配池(__bridge 存储, 手动 release; 池内 idle buffer 随之释放)
    if (poolObj) {
        CVPixelBufferPoolRelease((__bridge CVPixelBufferPoolRef)poolObj);
    }

    // ===== 前置多流优化资源(2026-08-17) =====
    if ([old hasPrefix:@"g:"]) {
        // 组条目: 释放组 staging/session(持全局组锁防与 transfer 并发;
        // 锁序 synchronized→groupLock→poolDictLock 单向无环)
        NSLock *gLock = _groupGlobalLock;
        if (gLock) [gLock lock];
        NSValue *gsv = nil, *gssv = nil;
        [_poolDictLock lock];
        gsv = _groupStagingPool[old];
        if (gsv) [_groupStagingPool removeObjectForKey:old];
        gssv = _groupSessionPool[old];
        if (gssv) [_groupSessionPool removeObjectForKey:old];
        [_groupTokenPool removeObjectForKey:old];
        [_groupSizePool removeObjectForKey:old];
        [_poolDictLock unlock];
        if (gsv) {
            CVPixelBufferRef b = (CVPixelBufferRef)[gsv pointerValue];
            if (b) CVPixelBufferRelease(b);
        }
        if (gssv) {
            VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[gssv pointerValue];
            if (s && invalidateSession) invalidateSession(s);
        }
        if (gLock) [gLock unlock];
    } else {
        // 流条目: 释放 s2 结果缓存 + blit session + 消费追踪
        if (rcv) {
            CVPixelBufferRef b = (CVPixelBufferRef)[rcv pointerValue];
            if (b) CVPixelBufferRelease(b);
        }
        if (rbsv) {
            VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[rbsv pointerValue];
            if (s && invalidateSession) invalidateSession(s);
        }
        // blitDisabled 故意不清(熔断语义与 twoStepDisabledPool 一致)
    }

    // 锁池条目最后清(先 unlock 再 remove 与先 remove 再 unlock 等价安全,
    // 统一: unlock 前移除, 持锁线程栈引用保证对象存活)
    [_oneStepKeyLockPool removeObjectForKey:old];
    [_twoStepKeyLockPool removeObjectForKey:old];
    // twoStepDisabledPool 故意不清(熔断永久)

    if (tlock) [tlock unlock];
    if (olock) [olock unlock];
}

- (void)touchStreamKeyLRU:(NSString *)key {
    if (!key) return;
    @synchronized(self) {
        NSUInteger idx = [_streamKeyOrder indexOfObject:key];
        if (idx != NSNotFound) {
            [_streamKeyOrder removeObjectAtIndex:idx];
        }
        [_streamKeyOrder addObject:key];

        while (_streamKeyOrder.count > kVcamMaxStreamKeys) {
            NSString *old = _streamKeyOrder.firstObject;
            [_streamKeyOrder removeObjectAtIndex:0];
            if (!old) break;
            [self evictStreamKeyResourcesLocked:old];
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] LRU evict stream key %@ (pool now %lu)", old, (unsigned long)_streamKeyOrder.count]);
        }
    }
}

// 空闲内存释放(2026-08-17 偶发全黑优化): 清空全部 LRU 流资源(组 staging 大头
// ~45MB + per-key session/staging/result cache)。mediaserverd inactive jetsam
// 硬限 75MB, 空闲 footprint 120MB+ 会被杀 → 下次开相机黑屏 2-3s("偶尔全黑")。
// 熔断标记保留; 恢复渲染时惰性重建(session/staging 首帧一次性 ~10-20ms)
- (void)releaseIdleMemory {
    NSUInteger freed = 0;
    @synchronized(self) {
        while (_streamKeyOrder.count > 0) {
            NSString *old = _streamKeyOrder.firstObject;
            [_streamKeyOrder removeObjectAtIndex:0];
            if (!old) break;
            [self evictStreamKeyResourcesLocked:old];
            freed++;
        }
    }
    if (freed > 0) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] idle memory release: %lu stream/group entries freed", (unsigned long)freed]);
    }
}

// 资源探针用: 当前 LRU 活跃 key 数
- (NSUInteger)activeStreamKeyCount {
    @synchronized(self) {
        return _streamKeyOrder.count;
    }
}

// 预渲染重缓冲释放(2026-08-18 云闪付崩溃循环): 只动缓冲不动 session(恢复零成本)。
// idle 暂停态调用(预渲染线程已 sleep, render 心跳静默 >2s, 竞态窗口与
// releaseIdleMemory 同级)。释放后 VCamCore 的 _syncDisplayFrame 快照保留,
// 恢复期间 render 冻结帧显示, 重载完成后无缝跟上。
- (void)releaseHeavyBuffersForIdle {
    NSUInteger released = 0;
    @synchronized(self) {
        if (_adaptiveRotateCache) {
            CVPixelBufferRelease(_adaptiveRotateCache);
            _adaptiveRotateCache = NULL;
            released++;
        }
        for (int i = 0; i < 3; i++) {
            CVPixelBufferRef b = [self prerenderRotateBufferAtSlot:i];
            if (b) {
                CVPixelBufferRelease(b);
                [self setPrerenderRotateBuffer:NULL atSlot:i];
                released++;
            }
        }
        // 用户画面变换画布池 + 缩小中转(预渲染线程已暂停, 安全释放; 恢复惰性重建)
        for (int i = 0; i < 3; i++) {
            CVPixelBufferRef b = [self userCanvasAtSlot:i];
            if (b) {
                CVPixelBufferRelease(b);
                [self setUserCanvas:NULL atSlot:i];
                released++;
            }
        }
        if (_userShrinkBuffer) {
            CVPixelBufferRelease(_userShrinkBuffer);
            _userShrinkBuffer = NULL;
            released++;
        }
        if (_userPieceBuffer) {
            CVPixelBufferRelease(_userPieceBuffer);
            _userPieceBuffer = NULL;
            released++;
        }
        // 三色打光注入画布池(1.3.37, 同上: 预渲染线程已暂停, 安全释放)
        for (int i = 0; i < 3; i++) {
            CVPixelBufferRef b = [self lightCanvasAtSlot:i];
            if (b) {
                CVPixelBufferRelease(b);
                [self setLightCanvas:NULL atSlot:i];
                released++;
            }
        }
        for (id key in _bgraBufferPoolMap) {
            CVPixelBufferPoolRelease((__bridge CVPixelBufferPoolRef)_bgraBufferPoolMap[key]);
            released++;
        }
        [_bgraBufferPoolMap removeAllObjects];
    }
    // 千面车道中转释放(2026-08-19): 深度空闲时归还内存, 恢复首帧锁内重建(一次性)
    [_laneLockPrivate lock];
    for (int i = 0; i < kVcamLaneStagingMax; i++) {
        if (gVcamLaneStaging[i].staging) {
            CVPixelBufferRelease(gVcamLaneStaging[i].staging);
            gVcamLaneStaging[i].staging = NULL;
            gVcamLaneStaging[i].w = gVcamLaneStaging[i].h = 0;
            gVcamLaneStaging[i].token = 0;
            released++;
        }
    }
    // 绿线修复 v2 裁剪槽同步释放(同上, 深度空闲 jetsam guard)
    for (int i = 0; i < kVcamCropStagingMax; i++) {
        if (gVcamCropStaging[i].staging) {
            CVPixelBufferRelease(gVcamCropStaging[i].staging);
            gVcamCropStaging[i].staging = NULL;
            gVcamCropStaging[i].w = gVcamCropStaging[i].h = 0;
            gVcamCropStaging[i].token = 0;
            gVcamCropStaging[i].lastUse = 0;
            released++;
        }
    }
    // 发热优化 YUV 上采样中转槽同步释放(同上; 拆段 memo 保留 —— 支持性是格式
    // 组合属性, 与槽生命周期无关, 重测无意义且浪费首帧)
    for (int i = 0; i < kVcamYuvStagingMax; i++) {
        if (gVcamYuvStaging[i].staging) {
            CVPixelBufferRelease(gVcamYuvStaging[i].staging);
            gVcamYuvStaging[i].staging = NULL;
            gVcamYuvStaging[i].w = gVcamYuvStaging[i].h = 0;
            gVcamYuvStaging[i].fmt = 0;
            gVcamYuvStaging[i].token = 0;
            gVcamYuvStaging[i].lastUse = 0;
            released++;
        }
    }
    [_laneLockPrivate unlock];
    vcam_gpu_log([NSString stringWithFormat:@"[vcam] idle heavy buffers released: %lu entries (jetsam guard)", (unsigned long)released]);
}

// 按流渲染统计(诊断, 30s 窗口): takeStreamStats 输出并清零
// 2026-08-16: 附带每流 stage1/stage2 平均耗时(ms) —— CPU 归因探针
// 死锁修复(2026-08-17): statsLock(与写入端一致, 不再用 @synchronized(self))
- (NSString *)takeStreamStats {
    [_statsLock lock];
    NSString *out = @"";
    NSMutableArray *parts = [NSMutableArray array];
    for (int i = 0; i < kVcamStatSlots; i++) {
        VCamStatSlot *s = &gVcamStatSlots[i];
        if (s->fmt == 0 || s->renders == 0) continue;
        uint64_t mb = (s->pixels * 4ull) >> 20;  // BGRA 4B/px
        // stage 均值: s1=缩放(内容帧才跑) s2=格式转换(每相机帧都跑)
        double s1Avg = s->s1Cnt > 0 ? (s->s1TotalMs / s->s1Cnt) : -1.0;
        double s2Avg = s->s2Cnt > 0 ? (s->s2TotalMs / s->s2Cnt) : -1.0;
        [parts addObject:[NSString stringWithFormat:@"%ux%u_%u:%llu/%lluMB(%.1f,%.1fms)",
                          s->w, s->h, s->fmt, s->renders, mb, s1Avg, s2Avg]];
    }
    if (parts.count > 0) out = [parts componentsJoinedByString:@" "];
    memset(gVcamStatSlots, 0, sizeof(gVcamStatSlots));
    [_statsLock unlock];
    return out;
}

// GPU crop-fill 渲染(2026-08-16): CIImage 源 → 中心裁剪到 dst 宽高比(对齐 VT Trim
// 语义) → 缩放到 dst 尺寸 → GPU CIContext 渲染直写相机帧。
// 缩放+色彩转换全在 GPU, CPU 只剩命令提交(~1ms) —— 替代 CPU VT 全量转换(8-10ms)。
// (key, token) 缓存变换结果: 冻结帧(每 100ms 才换内容)30fps 中 2/3 帧零重建。
// 调用方已持 per-key 锁(oneStepLockForKey), 本方法内不再加锁。
- (BOOL)gpuCropFillRender:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst
                      key:(NSString *)key token:(uint64_t)token {
    if (!src || !dst || !_ciGPUContext) return NO;
    size_t dstW = CVPixelBufferGetWidth(dst);
    size_t dstH = CVPixelBufferGetHeight(dst);
    if (!dstW || !dstH) return NO;

    @try {
        CIImage *out = nil;

        // 冻结帧缓存命中: 同 (key, token) 已构建过变换结果
        if (token != 0) {
            @synchronized(self) {
                NSNumber *cachedTok = _gpuImgTokenPool[key];
                if (cachedTok && [cachedTok unsignedLongLongValue] == token) {
                    out = _gpuImgOutPool[key];
                }
            }
        }

        if (!out) {
            CIImage *img = [CIImage imageWithCVPixelBuffer:src];
            if (!img) return NO;
            CGRect ext = img.extent;
            CGFloat srcW = ext.size.width, srcH = ext.size.height;
            if (srcW <= 0 || srcH <= 0) return NO;

            // crop-fill: 源中心裁剪到目标宽高比(超宽裁左右/超高裁上下), 再缩放到 dst
            CGFloat srcRatio = srcW / srcH;
            CGFloat dstRatio = (CGFloat)dstW / (CGFloat)dstH;
            CGRect cropRect = ext;
            if (srcRatio > dstRatio) {
                CGFloat cw = srcH * dstRatio;
                cropRect = CGRectMake(ext.origin.x + (srcW - cw) / 2, ext.origin.y, cw, srcH);
            } else if (srcRatio < dstRatio) {
                CGFloat ch = srcW / dstRatio;
                cropRect = CGRectMake(ext.origin.x, ext.origin.y + (srcH - ch) / 2, srcW, ch);
            }
            CIImage *cropped = [img imageByCroppingToRect:cropRect];
            // 原点归零(2026-08-16 照片模式叠影根因修复): 裁剪后 CIImage extent 原点
            // 非 (0,0)(裁左右时 x0>0), 仅缩放会使渲染内容整体偏移 S*x0 → 画面右移,
            // 左侧条带永不写入(残留旧内容) → "两个视频叠加+右偏"伪影。
            // 复合矩阵 p' = S*(p - origin): 先平移到原点再缩放
            CGFloat sx = dstW / cropRect.size.width;
            CGFloat sy = dstH / cropRect.size.height;
            CGAffineTransform fillT = CGAffineTransformMake(
                sx, 0, 0, sy, -sx * cropRect.origin.x, -sy * cropRect.origin.y);
            out = [cropped imageByApplyingTransform:fillT];
            if (!out) return NO;

            if (token != 0) {
                @synchronized(self) {
                    _gpuImgTokenPool[key] = @(token);
                    _gpuImgOutPool[key] = out;  // CIImage 懒持有 src, 同 key 覆盖旧帧引用
                }
            }
        }

        // GPU 渲染直写相机帧(dst 是 IOSurface-backed, Metal 可直接导入)
        // 计时探针(2026-08-16): 每 300 帧记一次平均耗时 —— 若 >5ms 说明 Metal 在
        // mediaserverd 实际走了 CPU fallback(CoreImage 软件管线), 需要回退 VT 主路径
        CFAbsoluteTime rStart = CFAbsoluteTimeGetCurrent();
        [_ciGPUContext render:out toCVPixelBuffer:dst];
        {
            static uint64_t gpuRenderCount = 0;
            static double gpuRenderTotalMs = 0;
            double ms = (CFAbsoluteTimeGetCurrent() - rStart) * 1000.0;
            gpuRenderCount++;
            gpuRenderTotalMs += ms;
            if (gpuRenderCount % 300 == 0) {
                vcam_gpu_log([NSString stringWithFormat:@"[vcam] GPU render avg %.2fms/frame (%llu frames)",
                              gpuRenderTotalMs / gpuRenderCount, (unsigned long long)gpuRenderCount]);
                gpuRenderCount = 0;
                gpuRenderTotalMs = 0;
            }
        }
        return YES;
    } @catch (NSException *e) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] GPU render exception: %@", e]);
        return NO;
    }
}

// 两步法主体(调用方已持 per-key 锁) —— 组共享 + 结果缓存快速路径, 失败回退 legacy
- (BOOL)twoStepTransferLocked:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst
                          key:(NSString *)poolKey token:(uint64_t)token {
    // 失败熔断: 该流组合 VT 不支持 → 放弃替换保真实相机(与 legacy 一致)
    if ([_twoStepDisabledPool[poolKey] boolValue]) {
        return NO;
    }
    // token=0(懒 BGRA 回退调用): 无帧代数语义, 组/token 复用判定失效, 直接走 legacy
    if (token == 0 || !src || !dst) {
        return [self legacyTwoStepTransferLocked:src toPixelBuffer:dst key:poolKey token:token];
    }

    size_t dstW = CVPixelBufferGetWidth(dst);
    size_t dstH = CVPixelBufferGetHeight(dst);
    if (!dstW || !dstH) return NO;

    // ===== B1: s2 结果缓存快路径(同 token 第 2+ 次消费, ~1-2ms blit) =====
    // 实测 2304x1650 照片流 94fps: 同一相机帧过 emit/scaler/encoder 三节点,
    // buffer 不同指针去重失效 → 同 token 全价转换 x3。缓存建立后第 2+ 次
    // 消费只付 VT 同格式 blit。
    if (![_resultBlitDisabledPool[poolKey] boolValue]) {
        NSValue *cv = _resultCachePool[poolKey];
        CVPixelBufferRef cacheBuf = cv ? (CVPixelBufferRef)[cv pointerValue] : NULL;
        NSNumber *ct = _resultCacheTokenPool[poolKey];
        if (cacheBuf && ct && [ct unsignedLongLongValue] == token) {
            VTPixelTransferSessionRef blitS = [self resultBlitSessionForKey:poolKey];
            if (blitS) {
                CFAbsoluteTime tB = CFAbsoluteTimeGetCurrent();
                OSStatus stB = VTPixelTransferSessionTransferImage(blitS, cacheBuf, dst);
                double msB = (CFAbsoluteTimeGetCurrent() - tB) * 1000.0;
                [self noteStageTimingFmt:(uint32_t)CVPixelBufferGetPixelFormatType(dst)
                                       w:(uint32_t)dstW h:(uint32_t)dstH stage:2 ms:msB];
                if (stB == noErr) return YES;
                // 私有→私有 blit 该组合 VT 不支持: 熔断缓存路径(该 key 永远全价), 无风暴
                _resultBlitDisabledPool[poolKey] = @YES;
                CVPixelBufferRelease(cacheBuf);
                [_resultCachePool removeObjectForKey:poolKey];
                [_resultCacheTokenPool removeObjectForKey:poolKey];
                vcam_gpu_log([NSString stringWithFormat:@"[vcam] result-cache blit rejected (%d), disabled for %@", (int)stB, poolKey]);
            }
        }
    }

    // ===== A: 组 staging(同比例家族共享, s1 每帧每组只付一次) =====
    // 实测 2112x1584 流 s1 8.7-12.9ms 几乎每帧全价(渲染率≈内容率, per-key token
    // 复用率为零); 而它与 1440x1080 流比例同为 4:3 —— 两条流各自 s1 是纯重复劳动。
    // 比例量化 0.1% 分组(组内 Trim 构图一致), 组 staging 取组内最大尺寸 BGRA,
    // s1 由每帧首个到达的流垫付, 其余流 s2 直接从组 staging 缩转。
    // ratioKey 由调用方(transferPixelBuffer, per-key 锁外)算好传入 —— 组 key 的
    // LRU touch 含 @synchronized, 锁序禁止(synchronized→keyLock 单向)。
    NSString *ratioKey = [NSString stringWithFormat:@"g:%d",
                          (int)llround((double)dstH * 1000.0 / (double)dstW)];

    NSLock *gLock = _groupGlobalLock;
    [gLock lock];

    CVPixelBufferRef groupStaging = NULL;
    {
        NSValue *gv = _groupStagingPool[ratioKey];
        if (gv) groupStaging = (CVPixelBufferRef)[gv pointerValue];
        uint64_t needPx = (uint64_t)dstW * dstH;
        uint64_t havePx = [_groupSizePool[ratioKey] unsignedLongLongValue];
        if (!groupStaging || needPx > havePx) {
            // 组内出现更大流: 重建组 staging(内容代数清零, 下次 s1 重付)
            CVPixelBufferRef bigger = [self createBufferWithWidth:dstW height:dstH
                                                           format:kCVPixelFormatType_32BGRA];
            if (bigger) {
                if (groupStaging) CVPixelBufferRelease(groupStaging);
                groupStaging = bigger;
                _groupStagingPool[ratioKey] = [NSValue valueWithPointer:groupStaging];
                _groupSizePool[ratioKey] = @(needPx);
                _groupTokenPool[ratioKey] = @0;
                vcam_gpu_log([NSString stringWithFormat:@"[vcam] group staging %@ built %zux%zu", ratioKey, dstW, dstH]);
            }
            // 创建失败: 保留旧组 staging(尺寸不足时 s2 走缩小, 仍正确), 无旧则回退 legacy
        }
    }

    CVPixelBufferRef effectiveStaging = NULL;
    BOOL groupOk = NO;
    if (groupStaging) {
        NSNumber *gt = _groupTokenPool[ratioKey];
        if (!gt || [gt unsignedLongLongValue] != token) {
            VTPixelTransferSessionRef gSession = [self groupSessionForKey:ratioKey];
            if (gSession) {
                CFAbsoluteTime t1 = CFAbsoluteTimeGetCurrent();
                OSStatus st1 = VTPixelTransferSessionTransferImage(gSession, src, groupStaging);
                [self noteStageTimingFmt:(uint32_t)CVPixelBufferGetPixelFormatType(dst)
                                       w:(uint32_t)dstW h:(uint32_t)dstH stage:1
                                       ms:(CFAbsoluteTimeGetCurrent() - t1) * 1000.0];
                if (st1 == noErr) {
                    _groupTokenPool[ratioKey] = @(token);
                    groupOk = YES;
                } else {
                    // 组 s1 失败(src→BGRA 组合异常): 本帧回退 legacy, 不熔断组(下帧重试)
                    vcam_gpu_log([NSString stringWithFormat:@"[vcam] group s1 failed (%d) %@, fallback legacy", (int)st1, ratioKey]);
                }
            }
        } else {
            groupOk = YES;  // 组内容新鲜(本帧已被同组其他流垫付), s1 免单
        }
        if (groupOk) {
            effectiveStaging = CVPixelBufferRetain(groupStaging);  // 栈引用, 防 LRU 并发释放
        }
    }
    [gLock unlock];

    if (!effectiveStaging) {
        return [self legacyTwoStepTransferLocked:src toPixelBuffer:dst key:poolKey token:token];
    }

    // ===== B2/s2: 组staging → dst(私有格式) =====
    // 缓存模式自适应: 首次"同 token 二次消费"(lastReq==token)证明该流是多消费链,
    // 激活缓存 —— 此后每个新 token 首次消费即建缓存(全价+blit), 后续消费 blit 复用。
    // 单消费流(每帧 token 唯一)永不激活, 零额外成本。
    VTPixelTransferSessionRef s2 = [self twoStepSessionForKey:poolKey];
    if (!s2) {
        CVPixelBufferRelease(effectiveStaging);
        return [self legacyTwoStepTransferLocked:src toPixelBuffer:dst key:poolKey token:token];
    }

    NSNumber *lastReq = _lastReqTokenPool[poolKey];
    BOOL repeatConsume = (lastReq && [lastReq unsignedLongLongValue] == token);

    if (repeatConsume && ![_resultBlitDisabledPool[poolKey] boolValue] && !_resultCachePool[poolKey]) {
        // 激活缓存: 全价转换进自有 buffer, 再 blit 到 dst
        CVPixelBufferRef cacheBuf = [self createBufferWithWidth:dstW height:dstH
                                                         format:CVPixelBufferGetPixelFormatType(dst)];
        if (cacheBuf) {
            CFAbsoluteTime t2 = CFAbsoluteTimeGetCurrent();
            OSStatus st2a = VTPixelTransferSessionTransferImage(s2, effectiveStaging, cacheBuf);
            double ms2 = (CFAbsoluteTimeGetCurrent() - t2) * 1000.0;
            [self noteStageTimingFmt:(uint32_t)CVPixelBufferGetPixelFormatType(dst)
                                   w:(uint32_t)dstW h:(uint32_t)dstH stage:2 ms:ms2];
            if (st2a == noErr) {
                VTPixelTransferSessionRef blitS = [self resultBlitSessionForKey:poolKey];
                OSStatus st2b = blitS ? VTPixelTransferSessionTransferImage(blitS, cacheBuf, dst) : -1;
                if (st2b == noErr) {
                    _resultCachePool[poolKey] = [NSValue valueWithPointer:cacheBuf];  // 所有权归池
                    _resultCacheTokenPool[poolKey] = @(token);
                    _lastReqTokenPool[poolKey] = @(token);
                    CVPixelBufferRelease(effectiveStaging);
                    return YES;
                }
                // blit 不支持: 熔断缓存路径
                _resultBlitDisabledPool[poolKey] = @YES;
                CVPixelBufferRelease(cacheBuf);
                vcam_gpu_log([NSString stringWithFormat:@"[vcam] result-cache blit(build) rejected (%d), disabled for %@", (int)st2b, poolKey]);
            } else {
                CVPixelBufferRelease(cacheBuf);
            }
        } else {
            _resultBlitDisabledPool[poolKey] = @YES;  // 私有格式 buffer 创建失败, 不再尝试
        }
    }

    // 直转(首次消费 / 缓存路径不可用)
    CFAbsoluteTime t2 = CFAbsoluteTimeGetCurrent();
    OSStatus st2 = VTPixelTransferSessionTransferImage(s2, effectiveStaging, dst);
    [self noteStageTimingFmt:(uint32_t)CVPixelBufferGetPixelFormatType(dst)
                           w:(uint32_t)dstW h:(uint32_t)dstH stage:2
                           ms:(CFAbsoluteTimeGetCurrent() - t2) * 1000.0];
    _lastReqTokenPool[poolKey] = @(token);
    CVPixelBufferRelease(effectiveStaging);
    if (st2 == noErr) return YES;

    // s2 失败: 回退 legacy(其内部带失败计数+熔断, 语义不变)
    return [self legacyTwoStepTransferLocked:src toPixelBuffer:dst key:poolKey token:token];
}

// 组 s1 session(懒建, Trim; 组内 src→组staging 组合固定, pipeline 稳定)
// 死锁修复(2026-08-17): 字典访问过 poolDictLock(调用方持组锁/evict 持 self 锁,
// 本锁最内层无环; 同时防多组并发懒建的字典并发写)
- (VTPixelTransferSessionRef)groupSessionForKey:(NSString *)ratioKey {
    NSValue *v = nil;
    [_poolDictLock lock];
    v = _groupSessionPool[ratioKey];
    [_poolDictLock unlock];
    if (v) return (VTPixelTransferSessionRef)[v pointerValue];
    VTPixelTransferSessionRef s = NULL;
    if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &s) == noErr && s) {
        VTSessionSetProperty(s, CFSTR("ScalingMode"), CFSTR("Trim"));
        VTSessionSetProperty(s, CFSTR("RealTime"), kCFBooleanTrue);
        [_poolDictLock lock];
        _groupSessionPool[ratioKey] = [NSValue valueWithPointer:s];
        [_poolDictLock unlock];
        return s;
    }
    return NULL;
}

// 结果缓存专用 blit session(私有→私有, 与全价 s2 session 隔离, 防 pipeline 反复切换)
// 死锁修复(2026-08-17): 同上过 poolDictLock(调用方持 per-key 锁, 本锁最内层)
- (VTPixelTransferSessionRef)resultBlitSessionForKey:(NSString *)key {
    NSValue *v = nil;
    [_poolDictLock lock];
    v = _resultBlitSessionPool[key];
    [_poolDictLock unlock];
    if (v) return (VTPixelTransferSessionRef)[v pointerValue];
    VTPixelTransferSessionRef s = NULL;
    if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &s) == noErr && s) {
        [_poolDictLock lock];
        _resultBlitSessionPool[key] = [NSValue valueWithPointer:s];
        [_poolDictLock unlock];
        return s;
    }
    return NULL;
}

// legacy 两步法(2026-08-17 前的路径): per-key staging + 同格式→BGRA 回退 + 熔断计数。
// 作为组路径/缓存路径的回退保留 —— 任何新路径失败都不能闪回真实相机(闪烁教训)
- (BOOL)legacyTwoStepTransferLocked:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst
                          key:(NSString *)poolKey token:(uint64_t)token {
    size_t dstW = CVPixelBufferGetWidth(dst);
    size_t dstH = CVPixelBufferGetHeight(dst);

    // 失败熔断: 该流组合 VT 不支持(如 328x184 '18f0' 分析流) → 直接放弃替换。
    // 高频流上反复尝试+重建 session 会造成 wakeups 风暴 → mediaserverd 被杀
    if ([_twoStepDisabledPool[poolKey] boolValue]) {
        return NO;
    }

    // staging: 目标尺寸中转 buffer(每流独立, 池持有引用)。
    // 同格式 staging 全面化(2026-08-17 卡顿根治): 探针实测 |8v0 流 BGRA staging 的
    // stage2(BGRA→|8v0 色彩转换) 12.3ms × 24fps = 单流 30% CPU, 加上另一条私有流
    // 合计 ~50%, 总 CPU 在 46% 冻结线上下震荡(59↔43) → 内容 24↔20fps 反复切换 =
    // 用户看到的持续卡顿。修: staging 一律先用目标自身格式(私有格式
    // CVPixelBufferCreate 通常可行, VT 可写, 我们不做 CPU 访问) → stage2 退化为
    // 同格式 blit(~1.5ms), 省 ~26% CPU, 冻结不再触发。
    // 回退: 创建失败或 stage1 转换失败(该 src→私有组合 VT 不支持 -12905) →
    // 重建 BGRA staging 走旧路径, 每流只回退一次(记入 fmt 选择)
    OSType dstFmt = CVPixelBufferGetPixelFormatType(dst);
    CVPixelBufferRef staging = NULL;
    NSValue *sv = _twoStepStagingPool[poolKey];
    if (sv) staging = (CVPixelBufferRef)[sv pointerValue];
    if (!staging) {
        staging = [self createBufferWithWidth:dstW height:dstH format:dstFmt];
        if (!staging) {
            staging = [self createBufferWithWidth:dstW height:dstH format:kCVPixelFormatType_32BGRA];
        }
        if (!staging) return NO;
        _twoStepStagingPool[poolKey] = [NSValue valueWithPointer:staging];  // 所有权归池
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] 2step staging created for stream %@ fmt=%@", poolKey,
                      [self stringForFormat:CVPixelBufferGetPixelFormatType(staging)]]);
    }

    // 缩放复用: 同一源帧(token 未变)同流已缩放 → 跳过步骤1
    NSNumber *cachedTok = _twoStepTokenPool[poolKey];
    BOOL stagingFresh = (token != 0 && cachedTok && [cachedTok unsignedLongLongValue] == token);
    CFAbsoluteTime tS1 = 0, tS2 = 0;
    if (!stagingFresh) {
        // 步骤1: src → staging 缩放+格式转换(per-key session, Trim crop fill)
        VTPixelTransferSessionRef s1 = [self twoStepSessionForKey:poolKey];
        if (!s1) return NO;
        tS1 = CFAbsoluteTimeGetCurrent();
        OSStatus st1 = VTPixelTransferSessionTransferImage(s1, src, staging);
        [self noteStageTimingFmt:(uint32_t)dstFmt w:(uint32_t)dstW h:(uint32_t)dstH stage:1
                               ms:(CFAbsoluteTimeGetCurrent() - tS1) * 1000.0];
        if (st1 != noErr &&
            CVPixelBufferGetPixelFormatType(staging) != kCVPixelFormatType_32BGRA) {
            // 同格式 staging 的组合 VT 不支持 → 每流一次性回退 BGRA staging 重试
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] same-fmt staging rejected (%d), fallback BGRA for %@",
                          (int)st1, poolKey]);
            CVPixelBufferRelease(staging);
            staging = [self createBufferWithWidth:dstW height:dstH format:kCVPixelFormatType_32BGRA];
            if (!staging) return NO;
            _twoStepStagingPool[poolKey] = [NSValue valueWithPointer:staging];
            tS1 = CFAbsoluteTimeGetCurrent();
            st1 = VTPixelTransferSessionTransferImage(s1, src, staging);
            [self noteStageTimingFmt:(uint32_t)dstFmt w:(uint32_t)dstW h:(uint32_t)dstH stage:1
                                   ms:(CFAbsoluteTimeGetCurrent() - tS1) * 1000.0];
        }
        if (st1 != noErr) {
            // stage1 失败也计数熔断(2026-08-17 微型流放开配套): 同格式与 BGRA
            // 两种 staging 都失败 = 该 src→dst 组合 VT 确认不支持。不计数的话
            // 不支持的微型流(如 328x184 '18f0')会每帧白付 2 次 VT 失败调用
            NSInteger fails = [_twoStepFailCountPool[poolKey] integerValue] + 1;
            _twoStepFailCountPool[poolKey] = @(fails);
            if (fails >= 2) {
                _twoStepDisabledPool[poolKey] = @YES;
                [self invalidateTwoStepSessionForKey:poolKey];
                NSValue *stv = _twoStepStagingPool[poolKey];
                if (stv) {
                    CVPixelBufferRef b = (CVPixelBufferRef)[stv pointerValue];
                    if (b) CVPixelBufferRelease(b);
                    [_twoStepStagingPool removeObjectForKey:poolKey];
                }
                vcam_gpu_log([NSString stringWithFormat:@"[vcam] 2step stage1 CIRCUIT-BROKEN for stream %@ (err %d, keep camera)", poolKey, (int)st1]);
            } else {
                vcam_gpu_log([NSString stringWithFormat:@"[vcam] 2step stage1 failed: %d key=%@ (fail %ld)", (int)st1, poolKey, (long)fails]);
            }
            return NO;
        }
        _twoStepTokenPool[poolKey] = @(token);
    }

    // 步骤2: 同尺寸 BGRA → 私有格式(per-key session)。
    // 失败处理: 计数 + 熔断(不做高频 session 重建 —— 328x184 '18f0' 分析流场景
    // 曾每秒 rebuild 8 次 → wakeups 风暴 → mediaserverd 被杀死循环)
    VTPixelTransferSessionRef s2 = [self twoStepSessionForKey:poolKey];
    tS2 = CFAbsoluteTimeGetCurrent();
    OSStatus st2 = s2 ? VTPixelTransferSessionTransferImage(s2, staging, dst) : -1;
    [self noteStageTimingFmt:(uint32_t)dstFmt w:(uint32_t)dstW h:(uint32_t)dstH stage:2
                           ms:(CFAbsoluteTimeGetCurrent() - tS2) * 1000.0];
    if (st2 != noErr) {
        NSInteger fails = [_twoStepFailCountPool[poolKey] integerValue] + 1;
        _twoStepFailCountPool[poolKey] = @(fails);
        if (fails >= 2) {
            // 熔断: 该流组合确认不支持, 释放该流 session/staging, 之后永久跳过
            _twoStepDisabledPool[poolKey] = @YES;
            [self invalidateTwoStepSessionForKey:poolKey];
            NSValue *stv = _twoStepStagingPool[poolKey];
            if (stv) {
                CVPixelBufferRef b = (CVPixelBufferRef)[stv pointerValue];
                if (b) CVPixelBufferRelease(b);
                [_twoStepStagingPool removeObjectForKey:poolKey];
            }
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] 2step CIRCUIT-BROKEN for stream %@ (unsupported combo, keep camera frame)", poolKey]);
        } else {
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] 2step stage2 failed: %d key=%@ (fail %ld)", (int)st2, poolKey, (long)fails]);
        }
        return NO;
    }
    _twoStepFailCountPool[poolKey] = @0;
    return YES;
}

#pragma mark - 工具

- (NSString *)stringForFormat:(OSType)format {
    char fstr[5] = {0};
    fstr[0] = (char)(format >> 24);
    fstr[1] = (char)(format >> 16);
    fstr[2] = (char)(format >> 8);
    fstr[3] = (char)format;
    return [NSString stringWithUTF8String:fstr];
}

@end
