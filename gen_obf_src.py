# -*- coding: utf-8 -*-
"""gen_obf_src.py — 发布级源码混淆变换器(一级防护)

产出 obfsrc/ 目录(FINALPACKAGE=1 时 Makefile 从这里编译), 本地源码保持可读:
  1. 字符串全量加密: @"..." / "..." / CFSTR("...") / @selector(...) 全部替换为
     运行时解密调用(obfN/obfC/obfCF/obfSEL), 二进制内零明文(strings/class-dump 失效)
  2. 自有类运行时改名: __attribute__((objc_runtime_name)) — 源码不动,
     二进制类名变为无意义名(class-dump 看到的类是 Qz1/Wv2/...)
  3. 相邻字符串字面量合并(编译器拼接语义), 转义序列解码后按真实字节加密
  4. length 前缀存储(不依赖 NUL 终止 —— 根治 1.2.x 时代 vcStrX 越界 bug)

安全约束(2026-08-20 审计):
  - 无 `== @"` 指针比较, 无文件级字符串常量初始化, 无 C 字符串长期存储(全部实测)
  - 运行时值与原字面量完全一致: 跨进程契约(vc.plist 键/Darwin 通知名)不变,
    旧版本升级后配置无缝继承
  - obfN 带 per-id 缓存, 热路径零额外分配; obfC 纯计算无锁, 信号上下文安全

用法: python3 gen_obf_src.py   (CI 在 make 前运行)
"""
import os
import re
import random
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, 'obfsrc')

M_FILES = ['Tweak.m', 'VCamCore.m', 'GPUImageProcessor.m', 'LocalVideoPlayer.m',
           'NSQueue.m', 'VCamNotify.m', 'VCamFloatingBall.m']
# 变换的头文件(类声明 + 可能的内联字符串)
H_FILES = ['VCamCore.h', 'GPUImageProcessor.h', 'LocalVideoPlayer.h',
           'NSQueue.h', 'VCamNotify.h', 'VCamFloatingBall.h']
# 原样拷贝(已是密文数组/图标字节/签名洞, 无字面量)
# VCamTextSig.h: 魔数字节序列必须原样进二进制(inject_text_sig.py 定位用)
COPY_FILES = ['VCamStr.h', 'ball_icon.h', 'btn_icons.h', 'VCamTextSig.h']

# 运行时类名映射(class-dump 只能看到这些)
CLASS_RUNTIME_NAMES = {
    'VCamCore': 'Qz1',
    'LocalVideoPlayer': 'Wv2',
    'GPUImageProcessor': 'Rk3',
    'NSQueue': 'Nm4',
    'VCamNotify': 'Bt5',
    'VCamFloatingBall': 'Jx6',
}

MAX_STR = 250          # 单串上限(obfC 栈缓冲 256)
BUF = 256

# ---------- 全局字符串表 ----------
_str_map = {}          # plain value -> id
_str_list = []         # id -> plain value


def register(val):
    if '\x00' in val:
        raise SystemExit('字符串含 NUL, 无法加密: %r' % val)
    if val in _str_map:
        return _str_map[val]
    if len(val.encode('utf-8')) > MAX_STR:
        raise SystemExit('字符串过长(%d bytes): %r' % (len(val.encode('utf-8')), val[:80]))
    _str_map[val] = len(_str_list)
    _str_list.append(val)
    return _str_map[val]


# ---------- 词法工具 ----------
ESC_MAP = {'n': '\n', 't': '\t', 'r': '\r', '\\': '\\', '"': '"', "'": "'",
           'a': '\a', 'b': '\b', 'f': '\f', 'v': '\v', '0': '\0'}


def read_string(text, q):
    """q = 开引号下标; 返回 (解码值, 闭引号后下标)"""
    j = q + 1
    val = []
    n = len(text)
    while j < n:
        ch = text[j]
        if ch == '\\':
            nxt = text[j + 1] if j + 1 < n else ''
            if nxt in ESC_MAP:
                val.append(ESC_MAP[nxt])
                j += 2
            elif nxt == 'x':
                m = re.match(r'\\x([0-9a-fA-F]{1,2})', text[j:j + 4])
                if m:
                    val.append(chr(int(m.group(1), 16)))
                    j += 1 + len(m.group(0)) - 1
                else:
                    val.append('x')
                    j += 2
            else:
                val.append(nxt)
                j += 2
        elif ch == '"':
            return ''.join(val), j + 1
        elif ch == '\n':
            raise SystemExit('字符串字面量内换行(不支持): %r' % text[max(0, q - 40):q + 40])
        else:
            val.append(ch)
            j += 1
    raise SystemExit('未闭合字符串: %r' % text[max(0, q - 40):q + 40])


def skip_ws(text, i):
    n = len(text)
    while i < n:
        c = text[i]
        if c in ' \t\r\n':
            i += 1
        elif c == '\\' and i + 1 < n and text[i + 1] == '\n':
            i += 2
        else:
            break
    return i


def read_adjacent(text, i, first_val, first_end):
    """合并相邻字符串字面量(编译器拼接语义), 返回 (合并值, 结束下标)"""
    val = first_val
    k = first_end
    n = len(text)
    while True:
        k2 = skip_ws(text, k)
        if k2 < n and text[k2] == '"':
            v2, e2 = read_string(text, k2)
            val += v2
            k = e2
            continue
        if k2 + 1 < n and text[k2] == '@' and text[k2 + 1] == '"':
            v2, e2 = read_string(text, k2 + 1)
            val += v2
            k = e2
            continue
        break
    return val, k


DIRECTIVE_VERBATIM = re.compile(
    r'#\s*(import|include|pragma|if|ifdef|ifndef|elif|else|endif|error|warning|undef|line)\b')


def transform(text, in_directive=False):
    """主变换: 状态机扫描, 返回变换后文本"""
    out = []
    i = 0
    n = len(text)
    line_start = True
    while i < n:
        c = text[i]
        if not in_directive and line_start and c == '#':
            j = i
            while j < n and not (text[j] == '\n' and (j == 0 or text[j - 1] != '\\')):
                j += 1
            logical = text[i:j]
            if DIRECTIVE_VERBATIM.match(logical.lstrip()):
                out.append(logical)
            else:
                out.append(transform(logical, in_directive=True))
            if j < n:
                out.append('\n')
                j += 1
            i = j
            line_start = True
            continue
        line_start = False
        if c == '\n':
            out.append(c)
            line_start = True
            i += 1
            continue
        if text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            out.append(text[i:j])
            i = j
            continue
        if text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = (n - 2) if j < 0 else j
            j += 2
            out.append(text[i:j])
            i = j
            continue
        if c == "'":
            j = i + 1
            while j < n:
                if text[j] == '\\':
                    j += 2
                    continue
                if text[j] == "'":
                    j += 1
                    break
                if text[j] == '\n':
                    break
                j += 1
            out.append(text[i:j])
            i = j
            continue
        if c == '@':
            if i + 1 < n and text[i + 1] == '"':
                v, e = read_string(text, i + 1)
                val, k = read_adjacent(text, i, v, e)
                out.append('obfN(%d)' % register(val))
                i = k
                continue
            m = re.match(r'@selector\s*\(', text[i:])
            if m:
                depth = 1
                j = i + m.end()
                while j < n and depth:
                    if text[j] == '(':
                        depth += 1
                    elif text[j] == ')':
                        depth -= 1
                    j += 1
                sel = ''.join(text[i + m.end():j - 1].split())
                # 1.3.78: 选择器名命中高危改名表时注册【改名后】的值 ——
                # 方法定义在后续标识符改名阶段已变为 qvLv 等无意义名,
                # @selector 字面量若不同步改名, 运行时 sel_registerName 查
                # 不到方法(IMP 自检返回 msgForward 地址 → 恒误报 → 门禁
                # 恒关, 1.3.78 首部署设备日志实锤 b0==b1==msgForward)
                # 1.3.90: 带参选择器(形如 "name:")的冒号剥离后再查表,
                # 命中则把冒号拼回改名后 —— 旧版直接查全名(含冒号)必落空
                # → 定义改名为 qvVb: 而 selector 仍是 vcamLicenseVerifyBlob:
                # → 运行时查无此方法(msgForward), 1.3.90 首部署 b3-b5 实锤
                if sel.endswith(':') and sel[:-1] in IDENT_RENAMES:
                    sel = IDENT_RENAMES[sel[:-1]] + ':'
                else:
                    sel = IDENT_RENAMES.get(sel, sel)
                out.append('obfSEL(%d)' % register(sel))
                i = j
                continue
            out.append(c)
            i += 1
            continue
        if c == '"':
            v, e = read_string(text, i)
            val, k = read_adjacent(text, i, v, e)
            out.append('OBCS(%d)' % register(val))
            i = k
            continue
        if re.match(r'CFSTR\s*\(\s*"', text[i:]) and (i == 0 or not (text[i-1].isalnum() or text[i-1] == '_')):
            m = re.match(r'CFSTR\s*\(\s*"', text[i:])
            # read_string 要求 q=开引号下标; m.end() 在引号之后, 必须回退 1。
            # (2026-08-20 1.3.14 拉伸 bug 根因: 旧版少减 1, 每个 CFSTR 值被吃掉
            #  首字符 —— "ScalingMode"→"calingMode" → VT 属性键无效 → 设置失败
            #  → 会话退回默认缩放模式(拉伸填充)而非 Trim 裁剪)
            q = i + m.end() - 1
            v, e = read_string(text, q)
            val, k = read_adjacent(text, q, v, e)
            k2 = skip_ws(text, k)
            if k2 < n and text[k2] == ')':
                out.append('obfCF(%d)' % register(val))
                i = k2 + 1
                continue
            # 非常规写法, 回退按普通 C 串处理
            out.append('OBCS(%d)' % register(val))
            i = k
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def insert_obf_import(text):
    if '#import "ObfStr.h"' in text or '#import <ObfStr.h>' in text:
        return text
    lines = text.split('\n')
    last_imp = -1
    for idx, ln in enumerate(lines):
        if ln.startswith('#import') or ln.startswith('#include'):
            last_imp = idx
    if last_imp >= 0:
        lines.insert(last_imp + 1, '#import "ObfStr.h"')
    else:
        lines.insert(0, '#import "ObfStr.h"')
    return '\n'.join(lines)


def apply_runtime_names(text):
    for src, dst in CLASS_RUNTIME_NAMES.items():
        text = re.sub(r'(@interface\s+)%s\b' % re.escape(src),
                      r'__attribute__((objc_runtime_name("%s"))) \1%s' % (dst, src), text)
    return text


# ---------- 密表生成 ----------
def build_tables():
    random.seed(20260820)
    offs, lens, keys, dat = [], [], [], bytearray()
    for s in _str_list:
        b = s.encode('utf-8')
        key = random.randint(0x01, 0xFF)
        cipher = bytes(x ^ key for x in b)
        offs.append(len(dat))
        lens.append(len(b))
        keys.append(key)
        dat += cipher
    return offs, lens, keys, bytes(dat)


def emit_obfstr():
    offs, lens, keys, dat = build_tables()
    n = len(_str_list)

    def fmt_arr(name, ctype, vals, per=16):
        rows = []
        for i in range(0, len(vals), per):
            rows.append('    ' + ', '.join(str(v) for v in vals[i:i + per]) + ',')
        body = '\n'.join(rows) if rows else '    0,'
        return 'static const %s %s[] = {\n%s\n};' % (ctype, name, body)

    def fmt_bytes(name, vals, per=16):
        rows = []
        for i in range(0, len(vals), per):
            rows.append('    ' + ', '.join('0x%02X' % v for v in vals[i:i + per]) + ',')
        body = '\n'.join(rows) if rows else '    0x00,'
        return 'static const unsigned char %s[] = {\n%s\n};' % (name, body)

    hdr = '''//
//  ObfStr.h - 自动生成(gen_obf_src.py), 勿手改
//  全量字符串混淆运行时层: obfN(NSString)/obfC(C串)/obfCF(CFString)/obfSEL(SEL)
//  length 前缀解密(无 NUL 依赖), obfN per-id 缓存(热路径零分配)
//
#ifndef OBF_STR_H
#define OBF_STR_H

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>

NSString *obfN(unsigned i);
const char *obfC(unsigned i, char *buf, unsigned bufSize);
CFStringRef obfCF(unsigned i);
SEL obfSEL(unsigned i);

// C 字符串字面量替换宏(块作用域复合字面量, 禁止用于静态初始化/长期存储)
#define OBCS(id) obfC((id), (char[%d]){0}, %d)

#endif // OBF_STR_H
''' % (BUF, BUF)

    dat_m = '''//
//  ObfStrData.m - 自动生成(gen_obf_src.py), 勿手改
//
#import "ObfStr.h"

#define _OB_COUNT %d

%s
%s
%s
%s

static NSString *_ob_cache[_OB_COUNT];

NSString *obfN(unsigned i) {
    if (i >= _OB_COUNT) return @"";
    NSString *s = _ob_cache[i];
    if (!s) {
        char buf[%d];
        obfC(i, buf, sizeof(buf));
        s = [NSString stringWithUTF8String:buf];
        _ob_cache[i] = s;  // 良性竞态: 双写同值仅多一次分配
    }
    return s;
}

const char *obfC(unsigned i, char *buf, unsigned bufSize) {
    unsigned len = _ob_len[i];
    if (len >= bufSize) len = bufSize - 1;
    const unsigned char *p = _ob_dat + _ob_off[i];
    unsigned char k = _ob_key[i];
    for (unsigned j = 0; j < len; j++) buf[j] = (char)(p[j] ^ k);
    buf[len] = 0;
    return buf;
}

CFStringRef obfCF(unsigned i) {
    char buf[%d];
    obfC(i, buf, sizeof(buf));
    return CFStringCreateWithCString(NULL, buf, kCFStringEncodingUTF8);
}

SEL obfSEL(unsigned i) {
    char buf[%d];
    obfC(i, buf, sizeof(buf));
    return sel_registerName(buf);
}
''' % (n,
       fmt_arr('_ob_off', 'unsigned int', offs),
       fmt_arr('_ob_len', 'unsigned char', lens),
       fmt_arr('_ob_key', 'unsigned char', keys),
       fmt_bytes('_ob_dat', dat),
       BUF, BUF, BUF)

    open(os.path.join(OUT, 'ObfStr.h'), 'w', encoding='utf-8', newline='\n').write(hdr)
    open(os.path.join(OUT, 'ObfStrData.m'), 'w', encoding='utf-8', newline='\n').write(dat_m)


# ---------- 校验 ----------
def verify_no_plain_literals(text):
    """确认变换输出中不再有裸字符串(注释/预处理指令除外)"""
    i = 0
    n = len(text)
    line_start = True
    while i < n:
        c = text[i]
        if line_start and c == '#':
            j = text.find('\n', i)
            j = n if j < 0 else j
            i = j
            continue
        line_start = False
        if c == '\n':
            line_start = True
            i += 1
            continue
        if text.startswith('//', i):
            j = text.find('\n', i)
            i = n if j < 0 else j
            continue
        if text.startswith('/*', i):
            j = text.find('*/', i + 2)
            i = n if j < 0 else j + 2
            continue
        if c == '"':
            raise SystemExit('校验失败: 仍有裸字符串 @ %r' % text[max(0, i - 60):i + 60])
        i += 1


def roundtrip_check():
    offs, lens, keys, dat = build_tables()
    for idx, s in enumerate(_str_list):
        b = bytes(dat[offs[idx]:offs[idx] + lens[idx]])
        dec = bytes(x ^ keys[idx] for x in b).decode('utf-8')
        assert dec == s, 'roundtrip 失败 id=%d' % idx


CONST_DEF_RE = re.compile(r'NSString\s*\*\s*const\s+(\w+)\s*=\s*(obfN\(\d+\))\s*;')
CONST_DECL_RE = re.compile(r'extern\s+NSString\s*\*\s*const\s+(\w+)\s*;')

# 高危标识符改名(元数据/符号表泄露): 须无 @selector 引用(已验证);
# 在字符串变换之后执行 —— 字面量已替换, 不会误伤字符串内容
IDENT_RENAMES = {
    'initializeInMediaserverd': 'stageInitA',   # 方法名含进程目标词
    'initializeInSpringBoard': 'stageInitB',
    'vcam_log_budget_take': 'qzbt0',            # 全局符号(strip -x 不删外部符号)
    'activePlaybackPath': 'ap0x',               # 类方法名(plist 键字符串已加密, 不受影响)
    'setActivePlaybackPath': 'setAp0x',         # 对应 setter(大小写变体)
    # 密钥验证(1.3.55): 含激活/设备/验签语义的标识符改无意义名, 防逆向按
    # 符号表/ObjC 元数据定位。类方法为直接调用(无 @selector/KVC 引用),
    # C static 函数定义/调用/取址均在同一文件内 —— 文本级统一替换安全
    'vcamDeviceCode': 'qvDc',                   # 类方法: 设备码
    'vcamLicenseValid': 'qvLv',                 # 类方法: 激活校验(验签+节流)
    'vcamActivateLicense': 'qvLa',              # 类方法: 激活写入
    'vcamLicenseVerifyBlob': 'qvVb',            # 类方法: ECDSA 验签(私有, 不在头文件)
    'vcamPublishDeviceCode': 'qvPd',            # 类方法: SB 侧发布 dcPub
    'vcamCrossDeviceCodeOK': 'qvCc',            # 类方法: md 侧跨进程互证
    'vcamPersistDeviceUUID': 'qvUu',            # 类方法: UUID 回退持久化
    # 1.3.63 方案A(T 表): 含许可/密钥语义的方法与 static 函数改无意义名
    # (词边界正则防前缀互吃: \bvcamLicenseTable\b 不会命中 vcamLicenseTableDouble)
    'vcamLicenseTableDouble': 'qvTd',           # 类方法: T 表定点参数取值
    'vcamLicenseTableInt': 'qvTi',              # 类方法: T 表整数参数取值
    'vcamLicenseTable': 'qvTa',                 # 类方法: T 表解密(72B, 1.3.78 已删)
    'vcamLicenseDecodeT': 'qvDt',               # 1.3.78 类方法: T 表栈式解码
    # 1.3.65 取色采样器: 采样/共享总线方法名(含检测语义)
    'vcamStartAppSampler': 'qvSa',              # 类方法: App 采样器入口
    'vcamAppSampleSlotAtX': 'qvAp',             # 类方法: 采样一拍(返色档)
    'vcamNotifyPickSlot': 'qvNp',               # 类方法: Darwin slot 上行
    'vcamStartPickRelay': 'qvSr',               # 类方法: SB 中继
    'vcamPublishPickCfg': 'qvPc',               # 类方法: 配置下行(Darwin+state)
    'vcamPickPublishSlot': 'qvPb',              # 类方法: 总线写端(slot+color)
    'vcamPickSharedColor': 'qvRd',              # 类方法: 总线读端(色值直用)
    'vcamBusHasLiveOtherWriter': 'qvBo',        # 1.3.79 类方法: 总线写者仲裁
    'vcamMatchKnownLightShared': 'qvMk',        # 类方法: 共享颜色匹配
    'vcamMatchKnownLight': 'qvMl',              # C static(VCamFloatingBall.m): name 外壳
    'vcamPickShmMap': 'qzSm',                   # C static(VCamNotify.m): mmap 映射
    'vcamPickSlotName': 'qzPn',                 # C static(VCamNotify.m): slot 通知名
    'vcamPickCfgName': 'qzCn',                  # C static(VCamNotify.m): cfg 通知名
    'detectWithUICreateScreenImage': 'dwUSI',   # 方法名(VCamFloatingBall.m): UICSI 符号词(1.3.65 gate)
    'vcamSelfIntegrityOK': 'qvSi',              # C static(VCamCore.m): IMP 范围自检
    'vcamSelfTextOK': 'qvTs2',                  # C static(VCamCore.m): __TEXT 哈希自校验(1.3.70)
    'vcamDlsymTrusted': 'qzDs',                 # C static(VCamNotify.m): 可信符号解析
    'vcamTamperNote': 'qzTn',                   # 1.3.91 全局(VCamCore.m): 篡改登记(全局符号进符号表, 须改名)
    'vcamScatterChk': 'qzSc',                   # 1.3.91 全局(VCamCore.m): 散射复核(extern 跨文件引用)
    'vcamPlatformSerial': 'qzPs',               # C static(VCamNotify.m): IOKit 序列号
    'vcamDigestHex16': 'qzDh',                  # C static(VCamNotify.m): SHA256 派生
    'vcamMGResolve': 'qzMg',                    # C static(VCamNotify.m): MobileGestalt
    'vcamHexDigit': 'qzHx',                     # C static(VCamNotify.m): hex 单字符
    # 门禁属性(VCamCore.m): 属性名会进 ObjC 元数据, 改无意义名。
    # 词边界正则不吃 _前缀 —— ivar 直访(_licGate)须单独加映射, 否则属性改名
    # 后合成 ivar 变 _lq1 而 _licGate 残留 = 编译失败
    'licGate': 'lq1',
    '_licGate': '_lq1',
    'licMark': 'lq2',
    '_licMark': '_lq2',
}


def convert_const_to_funcs(texts):
    """文件级 `NSString *const X = obfN(n);` 编译不了(非常量初始化) ——
    转为函数 getter。函数名用无意义名 ovfN(全局符号会进符号表,
    原名 VCamNotifyLiveChanged 等会泄露机制); 定义/声明/使用点统一改名"""
    const_defs = {}
    for f, t in texts.items():
        if not f.endswith('.m'):
            continue
        for m in CONST_DEF_RE.finditer(t):
            const_defs[m.group(1)] = m.group(2)
    if not const_defs:
        return
    # 原名 -> 无意义函数名
    func_names = {name: 'ovf%d' % i for i, name in enumerate(sorted(const_defs))}
    ph_map = {}
    counter = [0]
    for f in list(texts.keys()):
        t = texts[f]

        def _def_ph(m):
            ph = '/*__OBC%d__*/' % counter[0]
            counter[0] += 1
            ph_map[ph] = ('def', m.group(1), m.group(2))
            return ph

        t = CONST_DEF_RE.sub(_def_ph, t)

        def _decl_ph(m):
            if m.group(1) not in const_defs:
                return m.group(0)
            ph = '/*__OBC%d__*/' % counter[0]
            counter[0] += 1
            ph_map[ph] = ('decl', m.group(1), const_defs[m.group(1)])
            return ph

        t = CONST_DECL_RE.sub(_decl_ph, t)
        for name, fn in func_names.items():
            t = re.sub(r'\b%s\b(?!\s*\()' % re.escape(name), fn + '()', t)
        for ph, (kind, name, call) in ph_map.items():
            if kind == 'def':
                t = t.replace(ph, 'NSString *%s(void) { return %s; }'
                              % (func_names[name], call))
            else:
                t = t.replace(ph, 'NSString *%s(void);' % func_names[name])
        texts[f] = t


def apply_ident_renames(texts):
    """字符串变换之后做标识符改名(此时字面量已是 obfN()/OBCS() 调用,
    词边界正则只命中代码标识符, 不会破坏字符串值/选择器密文)"""
    for f in list(texts.keys()):
        t = texts[f]
        for old, new in IDENT_RENAMES.items():
            t = re.sub(r'\b%s\b' % re.escape(old), new, t)
        texts[f] = t


# ---------- 源保真校验(防解析 bug 静默损坏密表) ----------
# 背景(2026-08-20, 1.3.14 拉伸 bug): 变换器 CFSTR 引号下标算错一位, 每个
# CFSTR 值被吃掉首字符("Trim"→"rim"), roundtrip 校验只验"表↔表"无法发现。
# 本校验用独立提取器从原始源码抽全部字面量, 逐个断言在密表中 —— 解析器
# 与提取器逻辑独立, 一方出错即被抓。

CRITICAL_STRS = [
    # VT 属性(裁剪/硬件提示 —— 1.3.14 事故主角)
    'ScalingMode', 'Trim', 'Normal', 'RealTime',
    # 旋转 dlsym 回退值
    'Rotation', 'CCW90', 'CW90', '180', 'FlipHorizontalOrientation',
    # Hook 目标
    'BWNodeOutput', 'BWStillImageScalerNode', 'BWPhotoEncoderNode',
    'emitSampleBuffer:', 'renderSampleBuffer:forInput:',
    # 进程判定
    'mediaserverd', 'SpringBoard',
    # 配置契约(路径在源码中是完整字面量)
    '/var/mobile/Media/DCIM/vc.plist', '/var/mobile/Media/DCIM/vcam.mp4',
    'logEnabled', 'enabled', 'paused', 'mirrored',
    'manualRotation', 'restartToken', 'decodeMaxEdge', 'activePlaybackPath',
    # 队列/通知
    'com.vcam.processing', 'com.vcam.processing.bg', 'com.vcam.decoder',
    'com.vcam.videoreader', 'com.vcam.filewatch', 'com.vcam.notify',
    'com.vcam.ios.media.reload', 'com.vcam.ios.live.changed',
]

LIT_RE = re.compile(
    r'CFSTR\s*\(\s*"((?:[^"\\\n]|\\.)*)"\s*\)'
    r'|@selector\s*\(([^)]*)\)'
    r'|@"((?:[^"\\\n]|\\.)*)"'
    r'|(?<![\w@])"((?:[^"\\\n]|\\.)*)"')


def decode_escapes(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            out.append(ESC_MAP.get(s[i + 1], s[i + 1]))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return ''.join(out)


def verify_source_fidelity(paths):
    problems = []
    for path in paths:
        text = open(path, encoding='utf-8').read()
        # 去注释 + 去 char 字面量(防止 '"' 被误当字符串) + 丢弃 verbatim 预处理行
        text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
        text = re.sub(r'//[^\n]*', '', text)
        text = re.sub(r"'(?:\\.|[^'\\\n])'", "''", text)
        kept = []
        for ln in text.split('\n'):
            if DIRECTIVE_VERBATIM.match(ln.lstrip()):
                continue
            kept.append(ln)
        text = '\n'.join(kept)
        fname = os.path.basename(path)
        for m in LIT_RE.finditer(text):
            if m.group(1) is not None:
                val = decode_escapes(m.group(1))
                if val not in _str_map:
                    problems.append('%s: CFSTR 值不在密表: %r' % (fname, val))
            elif m.group(2) is not None:
                val = ''.join(m.group(2).split())
                # 1.3.78: 与 @selector 变换同步走改名映射(注册值是改名后的)
                # 1.3.90: 带参选择器冒号剥离后查表(与变换侧同口径)
                if val.endswith(':') and val[:-1] in IDENT_RENAMES:
                    val = IDENT_RENAMES[val[:-1]] + ':'
                else:
                    val = IDENT_RENAMES.get(val, val)
                if val and val not in _str_map:
                    problems.append('%s: selector 不在密表: %r' % (fname, val))
            else:
                raw = m.group(3) if m.group(3) is not None else m.group(4)
                val = decode_escapes(raw)
                if val and val not in _str_map:
                    problems.append('%s: 字符串不在密表: %r' % (fname, val))
    for s in CRITICAL_STRS:
        if s not in _str_map:
            problems.append('关键字符串不在密表: %r' % s)
    if problems:
        raise SystemExit('源保真校验失败:\n  ' + '\n  '.join(problems))
    return True


def main():
    if os.path.isdir(OUT):
        for f in os.listdir(OUT):
            os.remove(os.path.join(OUT, f))
    os.makedirs(OUT, exist_ok=True)

    # Pass 1: 字符串/选择器/CFSTR 全量变换
    texts = {}
    for f in M_FILES:
        texts[f] = transform(open(os.path.join(ROOT, f), encoding='utf-8').read())
    for f in H_FILES:
        texts[f] = transform(open(os.path.join(ROOT, f), encoding='utf-8').read())

    # Pass 2: 文件级 const 常量 → 无意义名函数 getter
    convert_const_to_funcs(texts)

    # Pass 3: 高危标识符改名(方法名/全局符号)
    apply_ident_renames(texts)

    # Pass 4: 源保真校验 —— 独立提取器抽原始字面量, 逐个断言已入密表
    verify_source_fidelity([os.path.join(ROOT, f) for f in M_FILES + H_FILES])

    for f in M_FILES:
        t = insert_obf_import(texts[f])
        verify_no_plain_literals(t)
        open(os.path.join(OUT, f), 'w', encoding='utf-8', newline='\n').write(t)

    for f in H_FILES:
        t = texts[f]
        verify_no_plain_literals(t)
        # runtime_name 属性自带编译期字符串("Qz1" 无意义名, 非泄露), 在校验之后插入
        t = apply_runtime_names(t)
        t = insert_obf_import(t)
        open(os.path.join(OUT, f), 'w', encoding='utf-8', newline='\n').write(t)

    for f in COPY_FILES:
        data = open(os.path.join(ROOT, f), 'rb').read()
        open(os.path.join(OUT, f), 'wb').write(data)

    emit_obfstr()
    roundtrip_check()

    print('obfsrc 生成完成: %d 个文件, %d 条加密字符串, blob %d bytes'
          % (len(M_FILES) + len(H_FILES) + len(COPY_FILES) + 2, len(_str_list),
             sum(len(s.encode('utf-8')) for s in _str_list)))
    leaked_cls = [c for c in CLASS_RUNTIME_NAMES
                  if any(c in s for s in _str_list)]
    if leaked_cls:
        print('提示: 以下类名仍出现在加密字符串值中(运行时日志可见, 二进制不可见): %s' % leaked_cls)


if __name__ == '__main__':
    main()
