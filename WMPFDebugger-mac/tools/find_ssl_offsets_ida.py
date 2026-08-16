#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
find_ssl_offsets_ida.py
在 IDA Pro 里一键定位 WeChatAppEx Framework 的 BoringSSL SSL_read / SSL_write 偏移
（macOS 微信小程序 TLS 层抓包用，配合 scripts/run-cloud-capture.js）。

用法：
  1. IDA Pro 打开 WeChatAppEx Framework（fat 文件选 arm64 slice，或先 lipo -thin）
  2. 等左下角自动分析完成
  3. 菜单 File -> Script file...  选择本文件（macOS IDA 也可以 File -> Script command 里执行）
  4. 输出窗口打印：
       [*] SSL_read  = 0x9A8308   (module offset)
       [*] SSL_write = 0x1357BAC  (module offset)
     以及可直接粘进 frida/config/addresses.{版本}.json 的 JSON 片段。

原理：
  - 字符串 "SSL_read" / "SSL_write" 属于 Chromium 网络栈包装函数（BoringSSL 本体是
    stripped 的，函数体里没有字符串）
  - 找到字符串的代码引用 -> 包装函数
  - 包装函数里有 `LDR X0, [X?, #0x1E8]`（从对象里取 SSL*）后紧跟的 `BL`，
    该 BL 目标就是真实的 SSL_read / SSL_write
  - 版本更新后字符串地址会变，但锚点字符串和代码模式不变，本脚本自动适配

说明：
  - 仅适配 ARM64（Apple Silicon）。Intel x64 切片把 BL 换成 CALL 即可，模式类似。
  - 运行时需要 IDA 已完成自动分析（idautils.Strings / XrefsTo 依赖它）。
"""
import ida_auto
import ida_bytes
import ida_funcs
import ida_ida
import ida_idaapi
import ida_kernwin
import ida_name
import ida_ua
import idautils
import struct

TARGET_STRINGS = ("SSL_read", "SSL_write")
LDR_FIELD_RANGE = (0x100, 0x300)   # 对象里取 SSL* 的字段偏移经验范围
PROLOGUE_WINDOW = 0x400            # 向上找函数序言的最大距离


def log(msg):
    ida_kernwin.msg(msg + "\n")


def clean_optext(s):
    """去掉 print_operand 输出里夹带的颜色控制字节。"""
    return "".join(ch for ch in (s or "") if ch >= " ")


def find_string_ea(text):
    """在所有字符串里找精确匹配，返回地址；找不到则返回 None。"""
    for s in idautils.Strings():
        if str(s) == text:
            return s.ea
    return None


def is_prologue(ea):
    """ARM64 函数序言启发式：stp x29,x30 / sub sp,sp,#imm。"""
    insn = ida_ua.insn_t()
    if not ida_ua.decode_insn(insn, ea):
        return False
    m = insn.get_canon_mnem().lower()
    if m == "stp":
        op0 = clean_optext(ida_ua.print_operand(ea, 0))
        op1 = clean_optext(ida_ua.print_operand(ea, 1))
        if op0.lower().startswith("x29") and op1.lower().startswith("x30"):
            return True
    if m == "sub":
        op0 = clean_optext(ida_ua.print_operand(ea, 0))
        op1 = clean_optext(ida_ua.print_operand(ea, 1))
        if op0.lower() == "sp" and op1.lower() == "sp":
            return True
    return False


def func_start_of(ea):
    """先看 IDA 是否已建函数，否则向上扫序言；都失败返回 None。"""
    f = ida_funcs.get_func(ea)
    if f:
        return f.start_ea
    for a in range(ea, max(ea - PROLOGUE_WINDOW, ida_ida.inf_get_min_ea()) - 1, -4):
        if is_prologue(a):
            return a
    return None


def scan_bl_targets(func_ea):
    """遍历函数内所有指令，返回 [(bl_addr, target), ...]。"""
    out = []
    for head in idautils.FuncItems(func_ea):
        insn = ida_ua.insn_t()
        if not ida_ua.decode_insn(insn, head):
            continue
        m = insn.get_canon_mnem().lower()
        if m in ("bl", "call"):
            for op in insn.ops:
                if op.type == ida_ua.o_near and op.addr != ida_idaapi.BADADDR:
                    out.append((head, op.addr))
                    break
    return out


def arm64_ldr_x0_imm_next_bl(ea):
    """按 ARM64 原始编码匹配：`LDR X0, [Xn, #imm]` 且【下一条就是 BL】。

    返回 (ldr_ea, bl_ea, bl_target) 或 None。
    LDR(imm,64bit) = 11 111 001 01 imm12 Rn Rt；BL = 10 0101 imm26。
    用字节级匹配，完全绕开 IDA 9 操作数格式化/颜色码的差异。
    """
    raw = ida_bytes.get_bytes(ea, 8)
    if not raw or len(raw) < 8:
        return None
    w = struct.unpack("<I", raw[:4])[0]
    if (w & 0xFFC00000) != 0xF9400000:   # LDR Xt, [Xn, #imm]
        return None
    rt = w & 0x1F
    if rt != 0:                          # 目标寄存器必须是 X0
        return None
    disp = ((w >> 10) & 0xFFF) << 3
    if disp < LDR_FIELD_RANGE[0] or disp > LDR_FIELD_RANGE[1]:
        return None
    bw = struct.unpack("<I", raw[4:8])[0]
    if (bw & 0xFC000000) != 0x94000000:  # BL
        return None
    imm26 = bw & 0x03FFFFFF
    if imm26 & 0x02000000:
        imm26 -= 0x04000000
    bl_ea = ea + 4
    return ea, bl_ea, bl_ea + (imm26 << 2)


def find_ldr_ssl_pattern(func_ea):
    """在函数里找 `LDR X0, [X?, #0x100~0x300]` 且【下一条指令就是 BL】的模式。

    返回 (ldr_addr, bl_addr, bl_target) 或 None。字段偏移在经验范围内即可，
    不写死 0x1E8，方便版本更新后字段偏移变化的情况。
    """
    for ea in idautils.FuncItems(func_ea):
        hit = arm64_ldr_x0_imm_next_bl(ea)
        if hit:
            return hit
    return None


def safe_rename(ea, name):
    """重命名前先释放旧位置上占用的同名（防止之前运行残留的名字卡住）。"""
    try:
        old = ida_name.get_name_ea(ida_idaapi.BADADDR, name)
        if old != ida_idaapi.BADADDR and old != ea:
            ida_name.del_global_name(old)
    except Exception:
        pass
    return ida_name.set_name(ea, name, ida_name.SN_NOCHECK)


def get_image_base():
    """兼容不同 IDA 版本取镜像基址。

    IDA 9.x 移除了 ida_ida.get_imagebase / inf_get_imagebase，
    Mach-O 下没有重定位，显示地址本身就是模块偏移（vmaddr），直接返回 0 即可。
    """
    for name in ("inf_get_imagebase", "get_imagebase"):
        fn = getattr(ida_ida, name, None)
        if callable(fn):
            try:
                return fn()
            except Exception:
                pass
    return 0


def offset_of(ea):
    """模块偏移。Mach-O: IDA 显示地址就是 vmaddr（=Frida 模块偏移）。
    仅当 IDA 以非零基址重定位时才需要减基址。"""
    base = get_image_base()
    if base and ea >= base:
        return ea - base
    return ea

def main():
    ida_auto.auto_wait()
    log("[*] find_ssl_offsets_ida.py start")
    log(f"[*] imagebase = {get_image_base():#x}")

    results = {}
    for text in TARGET_STRINGS:
        sva = find_string_ea(text)
        if sva is None:
            log(f"[!] string not found: {text!r}（确认分析已完成？）")
            continue
        log(f"[+] string {text!r} @ 0x{sva:x}")

        # 字符串的所有代码引用 -> 包装函数
        funcs = set()
        for xr in idautils.XrefsTo(sva, 0):
            fs = func_start_of(xr.frm)
            if fs is not None:
                funcs.add(fs)
            else:
                log(f"    (xref 0x{xr.frm:x} 无函数，跳过)")

        if not funcs:
            log(f"[!] {text!r} 没有代码引用，换版本后可能字符串变了")
            continue

        # 候选 BL 目标：优先 LDR+紧邻 BL 模式；再统计包装函数里所有 BL 调用次数
        pattern_cands = {}
        all_cands = {}
        for f in sorted(funcs):
            pat = find_ldr_ssl_pattern(f)
            if pat:
                ldr_ea, bl_ea, tgt = pat
                pattern_cands[tgt] = pattern_cands.get(tgt, 0) + 1
                log(f"    wrapper 0x{f:x}: [模式] LDR X0,[X?,#imm] @ 0x{ldr_ea:x} + BL @ 0x{bl_ea:x} -> 0x{tgt:x}")
            for bl_ea, tgt in scan_bl_targets(f):
                all_cands[tgt] = all_cands.get(tgt, 0) + 1
                log(f"    wrapper 0x{f:x}: BL @ 0x{bl_ea:x} -> 0x{tgt:x}")

        if pattern_cands:
            # 有模式命中的话只从模式候选里选：模式次数多 -> BL 调用多 -> 地址低
            best = max(pattern_cands, key=lambda t: (pattern_cands[t], all_cands.get(t, 0), -t))
        elif all_cands:
            log("[!] 没命中 LDR+紧邻 BL 模式，按包装函数内 BL 调用次数兜底，请人工核对：")
            for tgt, cnt in sorted(all_cands.items(), key=lambda kv: (-kv[1], kv[0])):
                log(f"      BL -> 0x{tgt:x}  (x{cnt})")
            best = max(all_cands, key=lambda t: (all_cands[t], -t))
        else:
            log(f"[!] {text!r} 相关函数里没找到 BL/CALL，请手动检查")
            continue

        results[text] = best
        log(f"[*] {text} -> 0x{best:x} (offset 0x{offset_of(best):x})")

    if "SSL_read" in results:
        safe_rename(results["SSL_read"], "SSL_read")
    if "SSL_write" in results:
        safe_rename(results["SSL_write"], "SSL_write")

    if results:
        read_off = offset_of(results["SSL_read"])
        write_off = offset_of(results["SSL_write"])
        log("")
        log("[*] ==== 结果（module offsets）====")
        log(f"    SSLPayloadReadOffset  = 0x{read_off:X}")
        log(f"    SSLPayloadWriteOffset = 0x{write_off:X}")
        log("")
        log("[*] ==== 可直接粘进 frida/config/addresses.{版本}.json ====")
        log('{')
        log(f'  "SSLPayloadReadOffset": "0x{read_off:X}",')
        log(f'  "SSLPayloadWriteOffset": "0x{write_off:X}"')
        log('}')
        ida_kernwin.jumpto(results["SSL_read"])
    else:
        log("[!] 什么都没找到，请确认加载的是 WeChatAppEx Framework 且选择了 arm64 slice")


if __name__ == "__main__":
    main()
