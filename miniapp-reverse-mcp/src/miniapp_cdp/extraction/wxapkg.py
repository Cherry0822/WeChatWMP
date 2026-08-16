"""
wxapkg.py — 微信小程序 wxapkg 解密 + 解包 (WeChat 4.0+)
纯 Python 实现，基于 KillWxapkg 算法

加密格式:
    - Magic: "V1MMWX" (6 bytes)
    - AES-256-CBC 加密区: file[6:1030] → 解密取前 1023 bytes
    - XOR 加密区: file[1030:] → 逐字节 XOR appID[-2]
    - Key = PBKDF2(appID, "saltiest", 1000, 32, SHA1)
    - IV  = "the iv: 16 bytes"

解包格式:
    - 0xBE marker (1 byte)
    - info1 (4 bytes, big-endian uint32)
    - indexInfoLength (4 bytes)
    - bodyInfoLength (4 bytes)
    - 0xED marker (1 byte)
    - fileCount (4 bytes)
    - index entries: nameLen(4) + name(nameLen) + offset(4) + size(4)
    - body data
"""
import hashlib
import os
import struct
from pathlib import Path
from typing import List, Optional, Tuple

try:
    from Crypto.Cipher import AES
    from Crypto.Util.Padding import unpad
except ImportError:
    try:
        from Cryptodome.Cipher import AES
        from Cryptodome.Util.Padding import unpad
    except ImportError:
        AES = None
        unpad = None

MAGIC = b"V1MMWX"
SALT = b"saltiest"
IV = b"the iv: 16 bytes"
PBKDF2_ITER = 1000
KEY_LEN = 32


def _derive_key(app_id: str) -> bytes:
    """PBKDF2-SHA1 派生 AES-256 密钥"""
    return hashlib.pbkdf2_hmac("sha1", app_id.encode("utf-8"), SALT, PBKDF2_ITER, KEY_LEN)


def decrypt_wxapkg(data: bytes, app_id: str) -> bytes:
    """解密单个 wxapkg 文件内容，返回解密后的 bytes"""
    if AES is None:
        raise ImportError("需要安装 pycryptodome: pip install pycryptodome")

    if len(data) < 1030:
        raise ValueError("文件太小，不是有效的加密 wxapkg")

    # 检查 magic header
    if data[:6] != MAGIC:
        # 可能是未加密的 wxapkg，直接返回
        if data[0:1] == b'\xbe':
            return data
        raise ValueError(f"未知文件格式 (magic: {data[:6].hex()})")

    key = _derive_key(app_id)

    # AES-256-CBC 解密前 1024 bytes (file[6:1030])
    cipher = AES.new(key, AES.MODE_CBC, IV)
    decrypted_header = cipher.decrypt(data[6:1030])
    # 取前 1023 bytes（去掉 PKCS7 padding 的最后一个字节）
    decrypted_header = decrypted_header[:1023]

    # XOR 解密剩余部分
    xor_key = ord(app_id[-2]) if len(app_id) >= 2 else 0
    tail = data[1030:]
    xor_decrypted = bytes(b ^ xor_key for b in tail)

    return decrypted_header + xor_decrypted


def unpack_wxapkg(data: bytes) -> List[Tuple[str, bytes]]:
    """解包 wxapkg，返回 [(文件路径, 文件内容), ...]"""
    if len(data) < 14:
        raise ValueError("数据太短，不是有效的 wxapkg")

    pos = 0

    # 0xBE marker
    marker1 = data[pos]
    if marker1 != 0xBE:
        raise ValueError(f"无效的 wxapkg 格式 (marker1: 0x{marker1:02x}, 期望 0xBE)")
    pos += 1

    # info1 (4 bytes)
    _info1 = struct.unpack(">I", data[pos:pos + 4])[0]
    pos += 4

    # indexInfoLength (4 bytes)
    index_info_length = struct.unpack(">I", data[pos:pos + 4])[0]
    pos += 4

    # bodyInfoLength (4 bytes)
    _body_info_length = struct.unpack(">I", data[pos:pos + 4])[0]
    pos += 4

    # 0xED marker
    marker2 = data[pos]
    if marker2 != 0xED:
        raise ValueError(f"无效的 wxapkg 格式 (marker2: 0x{marker2:02x}, 期望 0xED)")
    pos += 1

    # fileCount (4 bytes)
    file_count = struct.unpack(">I", data[pos:pos + 4])[0]
    pos += 4

    files = []
    for _ in range(file_count):
        if pos + 4 > len(data):
            break

        # nameLen (4 bytes)
        name_len = struct.unpack(">I", data[pos:pos + 4])[0]
        pos += 4

        if pos + name_len > len(data):
            break

        # name (nameLen bytes)
        name = data[pos:pos + name_len].decode("utf-8", errors="replace")
        pos += name_len

        if pos + 8 > len(data):
            break

        # offset (4 bytes)
        offset = struct.unpack(">I", data[pos:pos + 4])[0]
        pos += 4

        # size (4 bytes)
        size = struct.unpack(">I", data[pos:pos + 4])[0]
        pos += 4

        files.append((name, offset, size))

    # 提取文件内容
    result = []
    for name, offset, size in files:
        if offset + size <= len(data):
            content = data[offset:offset + size]
            result.append((name, content))

    return result


def extract_wxapkg(wxapkg_path: str, output_dir: str, app_id: str) -> List[str]:
    """解密并解包 wxapkg 到指定目录，返回提取的文件路径列表"""
    with open(wxapkg_path, "rb") as f:
        raw = f.read()

    decrypted = decrypt_wxapkg(raw, app_id)
    files = unpack_wxapkg(decrypted)

    extracted = []
    for name, content in files:
        # 规范化路径，防止路径穿越
        name = name.lstrip("/").replace("\\", "/")
        if ".." in name:
            continue

        out_path = os.path.join(output_dir, name)
        os.makedirs(os.path.dirname(out_path), exist_ok=True)

        with open(out_path, "wb") as f:
            f.write(content)
        extracted.append(out_path)

    return extracted


def find_wxapkg_files(packages_dir: str) -> List[dict]:
    """扫描 packages 目录，返回所有 wxapkg 文件信息

    目录结构: packages/{appid}/  下有 .wxapkg 文件
    返回: [{"appid": str, "path": str, "name": str, "size": int}, ...]
    """
    results = []
    if not os.path.isdir(packages_dir):
        return results

    for entry in os.listdir(packages_dir):
        app_dir = os.path.join(packages_dir, entry)
        if not os.path.isdir(app_dir):
            continue
        # 检查是否像 appid (wx开头 或 纯字母数字)
        appid = entry

        for root, dirs, filenames in os.walk(app_dir):
            for fn in filenames:
                if fn.endswith(".wxapkg"):
                    fpath = os.path.join(root, fn)
                    results.append({
                        "appid": appid,
                        "path": fpath,
                        "name": fn,
                        "size": os.path.getsize(fpath),
                    })

    return results


def get_default_packages_dir() -> Optional[str]:
    """获取默认的微信小程序包路径（Windows / macOS）"""
    import sys
    user_home = os.path.expanduser("~")
    if sys.platform == "darwin":
        # macOS: ~/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/radium/users/{wxid}/applet/packages
        users_dir = os.path.join(
            user_home, "Library", "Containers", "com.tencent.xinWeChat",
            "Data", "Documents", "app_data", "radium", "users"
        )
        if not os.path.isdir(users_dir):
            return None
        # 找最近修改的用户目录
        user_dirs = [
            os.path.join(users_dir, d)
            for d in os.listdir(users_dir)
            if os.path.isdir(os.path.join(users_dir, d)) and not d.startswith(".")
        ]
        for ud in sorted(user_dirs, key=os.path.getmtime, reverse=True):
            pkg_dir = os.path.join(ud, "applet", "packages")
            if os.path.isdir(pkg_dir):
                return pkg_dir
        return None
    elif os.name == "nt":
        pkg_dir = os.path.join(
            user_home, "AppData", "Roaming", "Tencent",
            "xwechat", "radium", "Applet", "packages"
        )
        if os.path.isdir(pkg_dir):
            return pkg_dir
    return None
