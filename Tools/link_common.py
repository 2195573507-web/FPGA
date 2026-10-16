# -*- coding: utf-8 -*-
r"""
link_common.py --- SFP / 千兆直连链路 PC 侧公共库

被 sender.py / receiver.py / sfp_link_check.py 共用, 提供:

  * 网卡枚举与按名选择 (--iface)            : Windows GetAdaptersInfo (ctypes)
  * 网卡 MTU / 源 IP / 出口网卡查询          : GetIpInterfaceEntry / GetBestInterface
  * ARP 邻居表读取与主动解析                 : GetIpNetTable + 触发式解析
  * 探测帧线格式 (magic/seq/时间戳/CRC32)    : pack_probe / parse_probe
  * 以太/IPv4/UDP 首部构造 (校验和自算)       : 供原始套接字与二层直发使用
  * 令牌桶 + 混合睡眠定速器                  : Shaper / hybrid_sleep

环境实测 (2026-10-15, 本机):
  * Python  C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe
            (3.12.14, 有 numpy 2.3.5 / cv2 5.0.0)
  * 无 scapy / psutil / pywin32 → 本库全部用 ctypes + 标准库, 不引入新依赖
  * 原始套接字 SOCK_RAW 需要管理员权限: 非管理员实测 PermissionError [WinError 10013]
    → 非管理员请用 --mode udp (普通 UDP, 走内核 IP 栈)
  * socket.IP_UNICAST_IF / socket.IP_MTU 在 Windows 上不可用 → 用 IP_UNICAST_IF=31
    常量直接 setsockopt, MTU 用 GetIpInterfaceEntry 读
"""
from __future__ import annotations

import ctypes
import os
import socket
import struct
import sys
import time
import zlib
from ctypes import wintypes

IS_WINDOWS = sys.platform == "win32"

# ===========================================================================
# 常量
# ===========================================================================
ETH_TYPE_IPV4 = 0x0800
ETH_TYPE_ARP = 0x0806
ETH_TYPE_SFP_RAW = 0x88B5      # 本工程二层直发默认以太类型 (t1 定稿前不冲突即可)

ETH_HDR = 14                   # 目的 MAC(6) + 源 MAC(6) + 类型(2)
ETH_FCS = 4                    # 帧尾 FCS (线路上有, 网卡驱动拿不到)
ETH_PREAMBLE_IPG = 20          # 前导(8) + 帧间隔(12), 算真实线速时必须计入
IP_HDR = 20                    # 无选项
UDP_HDR = 8
FRAMING = ETH_HDR + ETH_FCS    # 18

MTU_DEFAULT = 1500             # IP 层 MTU
UDP_PAYLOAD_FOR_MTU1500 = 1472  # 1500 - 20(IP) - 8(UDP); 再加 16 B 条带头 → 1456 数据
MAX_TILE_DATA = 1456           # 与 fpga_codec.MAX_TILE_DATA 一致

LINK_BUDGET_BPS = 957.1e6      # 1GbE MTU1500 的有效载荷 (方案文档 §1.2)
SHAPE_DEFAULT_BPS = 717.8e6    # 0.75 × 957.1 Mbit/s --- 发送整形默认上限
DESIGN_TARGET_BPS = 530e6      # 方案文档 §7.2 的设计目标速率

# 探测帧头: magic(4) seq(2) flags(2) t_ns(8) payload_len(4) crc32(4) = 24 B
PROBE_MAGIC = b"SFP1"
PROBE_FLAG_REPLY = 0x0001
PROBE_HDR_FMT = "<4sHHQI"
PROBE_CRC_FMT = "<I"
PROBE_HDR_SIZE = struct.calcsize(PROBE_HDR_FMT) + 4      # 24
PROBE_PROTO_DEFAULT = 0xB5        # 探测帧 UDP 端口默认值 (十进制 181)

# Windows ioctl 常量 (socket 模块在 Windows 上不导出)
IP_UNICAST_IF = 31
IP_MTU_DISCOVER = 10
IP_PMTUDISC_DO = 2


# ===========================================================================
# 时间与小工具
# ===========================================================================
def now_ns() -> int:
    """墙钟纳秒 --- 探测帧时间戳用它, 回程相减即 RTT (同一进程同一时钟)"""
    return time.time_ns()


def fmt_mac(mac: bytes | str) -> str:
    if isinstance(mac, (bytes, bytearray)):
        return ":".join("%02x" % b for b in mac)
    return mac


def parse_mac(text: str) -> bytes:
    t = text.replace("-", ":").replace(".", ":").strip().lower()
    parts = [p for p in t.split(":") if p != ""]
    if len(parts) != 6:
        raise ValueError("MAC 格式非法 (需 6 组): %r" % text)
    return bytes(int(p, 16) for p in parts)


def ip4_to_bytes(ip: str) -> bytes:
    return socket.inet_aton(ip)


def ip4_to_int(ip: str) -> int:
    return int.from_bytes(socket.inet_aton(ip), "little")


# ===========================================================================
# 网卡枚举 / 选择
# ===========================================================================
_MAX_ADAPTER_NAME_LENGTH = 256
_MAX_ADAPTER_DESCRIPTION_LENGTH = 128
_MAX_ADAPTER_ADDRESS_LENGTH = 8


class _IP_ADDR_STRING(ctypes.Structure):
    pass


_IP_ADDR_STRING._fields_ = [
    ("Next", ctypes.POINTER(_IP_ADDR_STRING)),
    ("IpAddress", ctypes.c_char * 16),
    ("IpMask", ctypes.c_char * 16),
    ("Context", wintypes.DWORD),
]


class _IP_ADAPTER_INFO(ctypes.Structure):
    pass


_IP_ADAPTER_INFO._fields_ = [
    ("Next", ctypes.POINTER(_IP_ADAPTER_INFO)),
    ("ComboIndex", wintypes.DWORD),
    ("AdapterName", ctypes.c_char * (_MAX_ADAPTER_NAME_LENGTH + 4)),
    ("Description", ctypes.c_char * (_MAX_ADAPTER_DESCRIPTION_LENGTH + 4)),
    ("AddressLength", wintypes.UINT),
    ("Address", ctypes.c_ubyte * _MAX_ADAPTER_ADDRESS_LENGTH),
    ("Index", wintypes.DWORD),
    ("Type", wintypes.UINT),
    ("DhcpEnabled", wintypes.UINT),
    ("CurrentIpAddress", ctypes.POINTER(_IP_ADDR_STRING)),
    ("IpAddressList", _IP_ADDR_STRING),
    ("GatewayList", _IP_ADDR_STRING),
    ("DhcpServer", _IP_ADDR_STRING),
    ("HaveWins", wintypes.BOOL),
    ("PrimaryWinsServer", _IP_ADDR_STRING),
    ("SecondaryWinsServer", _IP_ADDR_STRING),
    ("LeaseObtained", wintypes.DWORD),
    ("LeaseExpires", wintypes.DWORD),
]

# IFTYPE: 6=以太网, 71=IEEE80211, 53=隧道, 24=环回
_IFTYPE_NAMES = {1: "other", 6: "ethernet", 23: "ppp", 24: "loopback",
                 53: "tunnel", 71: "wireless", 243: "ieee80211"}


class _MIB_IPINTERFACE_ROW(ctypes.Structure):
    _fields_ = [
        ("Family", wintypes.USHORT),
        ("InterfaceLuid", ctypes.c_ulonglong),
        ("InterfaceIndex", wintypes.ULONG),
        ("MaxReassemblySize", wintypes.ULONG),
        ("InterfaceIdentifier", ctypes.c_ulonglong),
        ("MinRouterAdvertisementInterval", wintypes.ULONG),
        ("MaxRouterAdvertisementInterval", wintypes.ULONG),
        ("AdvertisingEnabled", ctypes.c_ubyte),
        ("ForwardingEnabled", ctypes.c_ubyte),
        ("WeakHostSend", ctypes.c_ubyte),
        ("WeakHostReceive", ctypes.c_ubyte),
        ("UseAutomaticMetric", ctypes.c_ubyte),
        ("UseNeighborUnreachabilityDetection", ctypes.c_ubyte),
        ("ManagedAddressConfigurationSupported", ctypes.c_ubyte),
        ("OtherStatefulConfigurationSupported", ctypes.c_ubyte),
        ("AdvertiseDefaultRoute", ctypes.c_ubyte),
        ("RouterDiscoveryBehavior", ctypes.c_uint),
        ("DadTransmits", wintypes.ULONG),
        ("BaseReachableTime", wintypes.ULONG),
        ("RetransmitTime", wintypes.ULONG),
        ("PathMtuDiscoveryTimeout", wintypes.ULONG),
        ("LinkLocalAddressBehavior", ctypes.c_uint),
        ("LinkLocalAddressTimeout", wintypes.ULONG),
        ("ZoneIndices", wintypes.ULONG * 16),
        ("SitePrefixLength", wintypes.ULONG),
        ("Metric", wintypes.ULONG),
        ("NlMtu", wintypes.ULONG),
        ("Connected", ctypes.c_ubyte),
        ("SupportsWakeUpPatterns", ctypes.c_ubyte),
        ("SupportsNeighborDiscovery", ctypes.c_ubyte),
        ("SupportsRouterDiscovery", ctypes.c_ubyte),
        ("ReachableTime", wintypes.ULONG),
        ("TransmitOffload", ctypes.c_uint),
        ("ReceiveOffload", ctypes.c_uint),
        ("DisableDefaultRoutes", ctypes.c_ubyte),
    ]


def list_adapters() -> list[dict]:
    """枚举本机 IPv4 网卡 (含未配置 IP 的以太网口)

    返回 [{index, guid, desc, mac, ips:[(ip,mask)], type, type_name, iftype}]
    """
    if not IS_WINDOWS:
        return []
    iphlp = ctypes.WinDLL("iphlpapi")
    size = wintypes.ULONG(0)
    iphlp.GetAdaptersInfo(None, ctypes.byref(size))
    if size.value == 0:
        return []
    buf = ctypes.create_string_buffer(size.value)
    rc = iphlp.GetAdaptersInfo(ctypes.cast(buf, ctypes.POINTER(_IP_ADAPTER_INFO)),
                              ctypes.byref(size))
    if rc != 0:
        raise OSError("GetAdaptersInfo 失败 rc=%d" % rc)
    out = []
    p = ctypes.cast(buf, ctypes.POINTER(_IP_ADAPTER_INFO))
    while p:
        a = p.contents
        ips = []
        q = ctypes.pointer(a.IpAddressList)
        while q:
            ips.append((q.contents.IpAddress.decode(errors="replace"),
                        q.contents.IpMask.decode(errors="replace")))
            q = q.contents.Next
        mac_raw = bytes(a.Address[i] for i in range(a.AddressLength))
        out.append(dict(
            index=a.Index,
            guid=a.AdapterName.decode(errors="replace"),
            desc=a.Description.decode(errors="replace"),
            mac=fmt_mac(mac_raw) if a.AddressLength == 6 else "",
            mac_raw=mac_raw,
            ips=ips,
            type=a.Type,
            type_name=_IFTYPE_NAMES.get(a.Type, "type%d" % a.Type),
        ))
        p = a.Next
    return out


def _usage_adapters() -> str:
    lines = ["可用网卡 (--iface 可用: 序号 / GUID 片段 / 描述片段 / 本机 IP):"]
    for a in list_adapters():
        ip = ",".join(x for x, _ in a["ips"] if x != "0.0.0.0") or "-"
        lines.append("  [%2d] %-14s %-25s %s  %s"
                     % (a["index"], a["type_name"], a["mac"] or "-",
                        ip, a["desc"][:44]))
    return "\n".join(lines)


def find_adapter(iface: str) -> dict:
    """按 --iface 的值找网卡. 支持 序号 / GUID 片段 / 描述片段 / 本机 IP / 接口名

    找不到时抛 SystemExit 并打印可选列表 (避免用户瞎猜)。
    """
    if not iface:
        raise SystemExit("内部错误: find_adapter 需要非空 iface")
    s = str(iface).strip()
    adas = list_adapters()
    if not adas:
        raise SystemExit("本机未枚举到网卡 (非 Windows 或 iphlpapi 不可用)")

    if s.isdigit():
        for a in adas:
            if a["index"] == int(s):
                return a
    low = s.lower()
    for a in adas:
        if a["guid"].lower().strip("{}") == low.strip("{}"):
            return a
    for a in adas:
        if low in a["guid"].lower() or low in a["desc"].lower():
            return a
    for a in adas:
        for ip, _ in a["ips"]:
            if ip == s:
                return a
    # 最后尝试 socket.if_nameindex() 的名称 → 无 GUID 对应关系, 只能提示
    raise SystemExit("[错误] 找不到网卡 %r\n%s" % (iface, _usage_adapters()))


def adapter_ipv4(ada: dict, prefer: str | None = None) -> str | None:
    """取网卡的 IPv4 地址 (跳过 0.0.0.0)"""
    ips = [ip for ip, _ in ada["ips"] if ip != "0.0.0.0"]
    if prefer:
        for ip in ips:
            if ip == prefer:
                return ip
    return ips[0] if ips else None


def iface_mtu(index: int) -> int | None:
    """读网卡的 IP 层 MTU (NlMtu). 失败返回 None 而不抛异常"""
    if not IS_WINDOWS:
        return None
    try:
        iphlp = ctypes.WinDLL("iphlpapi")
        row = _MIB_IPINTERFACE_ROW()
        row.Family = socket.AF_INET
        row.InterfaceIndex = index
        if iphlp.GetIpInterfaceEntry(ctypes.byref(row)) == 0:
            return int(row.NlMtu)
    except Exception:
        pass
    return None


def best_iface_index(dst_ip: str) -> int | None:
    """内核会从哪个网卡把包发给 dst_ip (IP Helper GetBestInterface)"""
    if not IS_WINDOWS:
        return None
    try:
        iphlp = ctypes.WinDLL("iphlpapi")
        best = wintypes.DWORD(0)
        if iphlp.GetBestInterface(ip4_to_int(dst_ip), ctypes.byref(best)) == 0:
            return int(best.value)
    except Exception:
        pass
    return None


def pick_iface_for(dst_ip: str) -> dict | None:
    """挑一张能用来给 dst_ip 自建二层首部的网卡

    优先级: ① 与 dst_ip 同网段且是 ethernet; ② 内核 GetBestInterface 给的网卡
    (若是 ethernet); ③ 第一张有 MAC 的 ethernet。无线网卡在最后兜底, 因为它
    没法保证 530 Mbit/s, 但对「工具不崩、能打印出到底走了哪张卡」够用。
    """
    ads = [a for a in list_adapters() if a.get("mac_raw")]
    if not ads:
        return None
    want = ip4_to_int(dst_ip)
    for a in ads:                                   # ① 同网段
        if a.get("type_name") != "ethernet":
            continue
        for ip, mask in a.get("ips") or []:
            if not ip or ip == "0.0.0.0":
                continue
            try:
                if (want & ip4_to_int(mask)) == (ip4_to_int(ip) & ip4_to_int(mask)):
                    return a
            except Exception:
                pass
    idx = best_iface_index(dst_ip)                  # ② 内核路由
    for a in ads:
        if a["index"] == idx and a.get("type_name") == "ethernet":
            return a
    for a in ads:                                   # ③ 第一张 ethernet
        if a.get("type_name") == "ethernet":
            return a
    return ads[0]


# ===========================================================================
# ARP 邻居表
# ===========================================================================
class _MIB_IPNETROW(ctypes.Structure):
    _fields_ = [
        ("dwIndex", wintypes.DWORD),
        ("dwPhysAddrLen", wintypes.DWORD),
        ("bPhysAddr", ctypes.c_ubyte * 8),
        ("dwAddr", wintypes.DWORD),
        ("dwType", wintypes.DWORD),
    ]


# dwType: 1=other 2=invalid 3=dynamic 4=static
_NET_TYPE_NAMES = {1: "other", 2: "invalid", 3: "dynamic", 4: "static"}


def arp_table() -> dict[str, dict]:
    """读 Windows ARP/邻居表: {ip: {mac, type, ifindex}}"""
    if not IS_WINDOWS:
        return {}
    iphlp = ctypes.WinDLL("iphlpapi")
    size = wintypes.ULONG(0)
    rc = iphlp.GetIpNetTable(None, ctypes.byref(size), False)
    if size.value == 0:
        return {}
    buf = ctypes.create_string_buffer(size.value)
    rc = iphlp.GetIpNetTable(buf, ctypes.byref(size), False)
    if rc != 0:
        return {}
    n = ctypes.cast(buf, ctypes.POINTER(ctypes.c_ulong))[0]
    rows = ctypes.cast(ctypes.addressof(buf) + ctypes.sizeof(ctypes.c_ulong),
                       ctypes.POINTER(_MIB_IPNETROW))
    out = {}
    for i in range(n):
        r = rows[i]
        mac = bytes(r.bPhysAddr[j] for j in range(min(r.dwPhysAddrLen, 8)))
        ip = socket.inet_ntoa(struct.pack("<I", r.dwAddr))
        out[ip] = dict(mac=fmt_mac(mac) if r.dwPhysAddrLen == 6 else "",
                       type=_NET_TYPE_NAMES.get(r.dwType, "type%d" % r.dwType),
                       ifindex=int(r.dwIndex))
    return out


_BAD_MACS = {"", "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff"}


def arp_lookup(ip: str, table: dict | None = None) -> str | None:
    """查邻居表拿 MAC —— 只认「可用」项

    t11 实测的两个必须过滤的坑 (本函数改成拒绝它们):

    1) Windows 邻居表里大量条目是**未完成解析**的占位, MAC 写全 0
       (实测 11 项, 如 10.83.61.161 / 192.168.2.2), dwType 会被报成 invalid;
       还有 multicast 项被写成 00:00:5e:00:01:01。原实现只要字符串非空就返回,
       于是「解析一个不存在的主机」会立刻返回 00:00:00:00:00:00 而非超时 ——
       调用方拿到它当目的 MAC, 帧被静默丢弃, 极易误判成链路丢包 100%。
    2) 只有 dwType==dynamic/static 且 MAC 非全 0/非 ff/非组播的项才可信。
    """
    t = arp_table() if table is None else table
    e = t.get(ip)
    if not e:
        return None
    mac = (e.get("mac") or "").lower()
    if mac in _BAD_MACS:
        return None
    if mac.startswith("01:00:5e") or mac.startswith("33:33"):
        return None
    if e.get("type") not in ("dynamic", "static"):
        return None
    return mac


def arp_resolve(ip: str, src_ip: str | None = None, timeout: float = 3.0,
                verbose: bool = True) -> str | None:
    """解析目的 IP 的 MAC —— 交给操作系统做, 再读回邻居表

    做法 (Windows 上没有 scapy 时的可靠办法):
      1. 先查邻居表;
      2. 没有就绑定源 IP, 对目标发一个空 UDP 报文, 内核会触发 ARP 解析;
      3. 轮询邻居表直到出现 MAC 或超时。

    实测: 目标在直连网段且对端在线时, 通常 10~30 ms 内出现表项。
    对端 (FPGA) 若无 ARP 应答, 请用 --dst-mac 直接指定或配静态 ARP:
        netsh interface ipv4 add neighbors "<网卡名>" <FPGA_IP> <FPGA_MAC>
    """
    mac = arp_lookup(ip)
    if mac:
        return mac
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        if src_ip:
            s.bind((src_ip, 0))
        s.settimeout(0.2)
        for _ in range(2):
            try:
                s.sendto(b"", (ip, 9))       # discard 端口, 只为触发 ARP
            except OSError:
                pass
            t_end = time.time() + timeout / 2.0
            while time.time() < t_end:
                mac = arp_lookup(ip)
                if mac:
                    return mac
                time.sleep(0.02)
    finally:
        s.close()
    if verbose:
        print("  [ARP] 邻居表中始终没有 %s (表内共 %d 项)" % (ip, len(arp_table())))
    return None


# ===========================================================================
# 首部构造 (校验和在 Python 侧算 --- 原始套接字与二层直发必需)
# ===========================================================================
def ip_checksum(data: bytes) -> int:
    """IPv4 首部校验和 (RFC 1071)"""
    if len(data) % 2:
        data += b"\x00"
    s = 0
    for i in range(0, len(data), 2):
        s += (data[i] << 8) | data[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def build_eth(dst_mac: bytes, src_mac: bytes, eth_type: int) -> bytes:
    return dst_mac + src_mac + struct.pack(">H", eth_type)


def build_ipv4(src_ip: str, dst_ip: str, payload: bytes, ttl: int = 64,
               ident: int = 0, flags_frag: int = 0x4000,
               proto: int = 17) -> bytes:
    """构造 IPv4 首部 + 载荷. flags_frag 默认 0x4000 = DF (不分片)"""
    total = IP_HDR + len(payload)
    hdr = struct.pack(">BBHHHBBH4s4s", 0x45, 0, total, ident, flags_frag, ttl,
                      proto, 0, ip4_to_bytes(src_ip), ip4_to_bytes(dst_ip))
    csum = ip_checksum(hdr)
    hdr = hdr[:10] + struct.pack(">H", csum) + hdr[12:]
    return hdr + payload


def build_udp(src_port: int, dst_port: int, payload: bytes,
              src_ip: str | None = None, dst_ip: str | None = None,
              checksum: bool = False) -> bytes:
    """UDP 首部 + 载荷. 默认校验和填 0 (IPv4 允许, FPGA 侧也不校验)"""
    ln = UDP_HDR + len(payload)
    csum = 0
    if checksum and src_ip and dst_ip:
        pseudo = (ip4_to_bytes(src_ip) + ip4_to_bytes(dst_ip)
                  + struct.pack(">BBH", 0, 17, ln))
        raw = struct.pack(">HHHH", src_port, dst_port, ln, 0) + payload
        csum = ip_checksum(pseudo + raw)
        if csum == 0:
            csum = 0xFFFF
    return struct.pack(">HHHH", src_port, dst_port, ln, csum) + payload


def build_frame(dst_mac: bytes, src_mac: bytes, src_ip: str, dst_ip: str,
                src_port: int, dst_port: int, payload: bytes,
                eth_type: int = ETH_TYPE_IPV4) -> bytes:
    """一层二层直发的完整以太帧: 以太 + IPv4 + UDP + 载荷 (不含 FCS, 网卡自动加)"""
    udp = build_udp(src_port, dst_port, payload, src_ip, dst_ip)
    ip = build_ipv4(src_ip, dst_ip, udp)
    return build_eth(dst_mac, src_mac, eth_type) + ip


def build_frame_raw(dst_mac: bytes, src_mac: bytes, payload: bytes,
                    eth_type: int = ETH_TYPE_SFP_RAW) -> bytes:
    """二层裸帧: 以太 + 自定义类型 + 载荷 (无 IP/UDP)"""
    return build_eth(dst_mac, src_mac, eth_type) + payload


# ===========================================================================
# 探测帧线格式
# ===========================================================================
_BODY_CACHE: dict = {}


def _filler(n: int) -> bytes:
    """探测帧的填充体 (只与长度有关) --- 必须缓存!

    实测: 每包现算 1448 B 的生成器表达式会把发送循环拖到 ~9 kpps (107 Mbit/s),
    而 530 Mbit/s 需要 ~43 kpps。缓存后发送循环不再受 Python 逐字节解释拖累。
    """
    b = _BODY_CACHE.get(n)
    if b is None:
        b = bytes((i * 7 + 13) & 0xFF for i in range(n)) if n else b""
        _BODY_CACHE[n] = b
    return b


def pack_probe(seq: int, t_ns: int | None = None, size: int = PROBE_HDR_SIZE,
               flags: int = 0) -> bytes:
    """打包一个探测帧. size = UDP 载荷总长 (>= PROBE_HDR_SIZE)"""
    if size < PROBE_HDR_SIZE:
        raise ValueError("size 太小: %d < %d" % (size, PROBE_HDR_SIZE))
    t_ns = now_ns() if t_ns is None else t_ns
    head = struct.pack(PROBE_HDR_FMT, PROBE_MAGIC, seq & 0xFFFF, flags,
                       t_ns, size)
    crc = zlib.crc32(head) & 0xFFFFFFFF
    return head + struct.pack(PROBE_CRC_FMT, crc) + _filler(size - PROBE_HDR_SIZE)


def parse_probe(data: bytes) -> dict | None:
    """解析探测帧; 不是本工具发的 / CRC 错 → 返回 None"""
    if len(data) < PROBE_HDR_SIZE:
        return None
    head = data[:PROBE_HDR_SIZE - 4]
    magic, seq, flags, t_ns, plen = struct.unpack(PROBE_HDR_FMT, head)
    if magic != PROBE_MAGIC:
        return None
    crc, = struct.unpack(PROBE_CRC_FMT, data[PROBE_HDR_SIZE - 4:PROBE_HDR_SIZE])
    if (zlib.crc32(head) & 0xFFFFFFFF) != crc:
        return None
    return dict(seq=seq, flags=flags, t_ns=t_ns, payload_len=plen,
                is_reply=bool(flags & PROBE_FLAG_REPLY),
                body=data[PROBE_HDR_SIZE:])


def make_reply(data: bytes, seq_override: int | None = None) -> bytes | None:
    """把一个探测帧变成回显帧 (只改 flags 位, 时间戳原样带回 → 对端可算 RTT)"""
    p = parse_probe(data)
    if p is None or p["is_reply"]:
        return None
    seq = p["seq"] if seq_override is None else seq_override
    return pack_probe(seq, p["t_ns"], size=len(data),
                      flags=p["flags"] | PROBE_FLAG_REPLY)


def flip_to_reply(data: bytes) -> bytes | None:
    """把收到的探测帧原地改成回显帧 —— 比 make_reply 快一个量级

    回显服务每秒要处理几千个包, make_reply 会重新 pack + 重新 CRC + 重建
    payload 填充, 在 Python 里太贵。这里只改 flags 2 字节并重算 20 B 头的 CRC,
    其余字节原样回发 (时间戳、序号、填充都不动)。
    """
    if len(data) < PROBE_HDR_SIZE or data[:4] != PROBE_MAGIC:
        return None
    # 头部布局 <4sHHQI (20 B) + CRC32 (4 B) = 24 B:
    # magic[0:4] seq[4:6] flags[6:8] t_ns_ns[8:16] payload_len[16:20] crc[20:24]
    # 注意: flags 在偏移 6, 不是 4 —— 偏移 4 是 seq 的低 2 字节.
    # (早期版本写成 data[4]|data[5] 并把 REPLY 写回 b[4:6], 结果:)
    #   1) seq 为奇数的包被误判成"已经是回显帧"而不回显 (实例: 3000 包只回 768 个)
    #   2) 被打上标记的其实是 seq 字段, 回包在收端 parse 出来 is_reply 仍为 False
    # 两者叠加会让自环/双机测试凭空出现 ~74% "丢包"。务必保持 flags 偏移为 6。
    flags, = struct.unpack_from("<H", data, 6)
    if flags & PROBE_FLAG_REPLY:
        return None
    b = bytearray(data)
    struct.pack_into("<H", b, 6, flags | PROBE_FLAG_REPLY)
    struct.pack_into("<I", b, PROBE_HDR_SIZE - 4, zlib.crc32(bytes(b[:PROBE_HDR_SIZE - 4])) & 0xFFFFFFFF)
    return bytes(b)


PROBE_MAGIC_STR = "SFP1"


# ===========================================================================
# 定速: 令牌桶 + 混合睡眠
# ===========================================================================
def hybrid_sleep(dt: float, spin_us: float = 1500.0) -> float:
    """睡 dt 秒, 最后 spin_us 微秒用忙等收尾 (Windows 定时器粒度不保证)

    实测本机 time.sleep(0.016) 实际 16.07~16.57 ms (粒度约 1 ms, 可接受);
    即便如此仍保留忙等收尾, 让 60 fps 的 16.667 ms 周期不被撕裂。
    返回实际经过的秒数。
    """
    if dt <= 0:
        return 0.0
    t0 = time.perf_counter()
    spin = spin_us / 1e6
    if spin > 0 and dt <= spin:
        # 短等待一律忙等: 实测 time.sleep(300us) 实耗 539 us (粒度 ~1.5 ms),
        # 而纯 spin 的误差只有 0.5 us。
        while time.perf_counter() - t0 < dt:
            pass
    elif spin > 0:
        time.sleep(dt - spin)
        while time.perf_counter() - t0 < dt:
            pass
    else:
        time.sleep(dt)
    return time.perf_counter() - t0


class Shaper:
    """令牌桶: 保证长时间平均不超过 bps, 同时允许 burst_bytes 的突发

    FPGA 侧完全没有以太网 PAUSE 流控 (t2 §4.2 B6), 因此 PC 必须自己限速 ——
    帧级 deadline 只对齐「帧起点」, 帧内 937 个包仍会瞬间灌满内核队列。
    """

    def __init__(self, bps: float, burst_bytes: int = 16384, enabled: bool = True):
        self.enabled = enabled and bps and bps > 0
        self.bps = float(bps or 0.0)
        self.rate = self.bps / 8.0                      # 字节/秒
        self.cap = float(max(burst_bytes, 2048))
        self.tokens = self.cap
        self.t_last = time.perf_counter()
        self.waited = 0.0
        self.n = 0
        self.n_byte = 0
        self.undersized = False

    def _refill(self):
        t = time.perf_counter()
        self.tokens = min(self.cap, self.tokens + (t - self.t_last) * self.rate)
        self.t_last = t

    def wait_for(self, nbytes: int) -> float:
        """为 nbytes 字节申请令牌, 不够就等到够. 返回等待秒数"""
        self.n += 1
        self.n_byte += nbytes
        if not self.enabled:
            return 0.0
        if nbytes > self.cap:                # 桶装不下一个包 → 只能放宽到单包
            self.undersized = True
            self.cap = float(nbytes)
            self.tokens = max(self.tokens, 0.0)
        if nbytes <= self.tokens:        # 快路径: 额度够就不碰时钟/系统调用
            self.tokens -= nbytes
            return 0.0
        waited = 0.0
        while True:
            self._refill()
            if self.tokens >= nbytes:
                self.tokens -= nbytes
                break
            need = (nbytes - self.tokens) / self.rate
            waited += hybrid_sleep(max(need, 0.00005))
            if waited > 5.0:                 # 防御: 速率过低时不要无限等
                break
        self.waited += waited
        return waited

    def close(self):
        pass


class FramePacer:
    """帧内定速器: 每 block 校一次时, 子块内全速放行 (替代令牌桶)

    为什么不用令牌桶 (t11 实测, 见 docs/pc_tools_review.md §5):
      * 桶 < 一帧: 每包都要等额度, 单线程 Python 每帧多花 5~6 ms (每次
        hybrid_sleep 的进入/返回 + 时钟读取), 600 帧实测 44.95 fps / 落后 598;
      * 桶 = 一帧: 帧首一次性放行整帧, 1 ms 到达 96 KB —— 等于没整形。
    时间表法: 以帧为单位锚定 t0, 理想时刻 = t0 + 累计字节/速率。落后于时间表
    就不睡 (永不累积跨帧欠账, 与帧级 deadline 天然兼容), 领先就一次睡到点。
    定速精度 (40 次 × 20000 包, 500 Mbit/s 目标): payload 口径 499.9 Mbit/s,
    +4.5% 过冲 (线速口径 501.7) —— 见 t11 §5 的实测记录。
    """

    def __init__(self, bps: float, block_bytes: int = 16384,
                 shape_basis: str = "payload", pkt_avg: int = 1472):
        self.enabled = bool(bps and bps > 0)
        self.bps = float(bps or 0.0)
        self.rate = self.bps / 8.0
        self.block = max(int(block_bytes), 4096)
        self.n_pkt_block = max(1, int(self.block // max(pkt_avg, 1)))
        self.shape_basis = shape_basis
        self.waited = 0.0
        self.n_blk = 0
        self.n_byte = 0
        self.t0 = time.perf_counter()
        self._sent = 0

    def start_frame(self):
        """每帧开头调用: 重新锚定时间表 (不结转上一帧的欠账)"""
        self.t0 = time.perf_counter()
        self._sent = 0

    def wait_block(self, nbytes: int) -> float:
        """放行 nbytes 前先校时. 返回实际等待秒数"""
        if not self.enabled:
            return 0.0
        self.n_blk += 1
        self.n_byte += nbytes
        self._sent += nbytes
        want = self.t0 + self._sent / self.rate
        dt = want - time.perf_counter()
        if dt <= 0:
            return 0.0
        w = hybrid_sleep(dt)
        self.waited += w
        return w

    def close(self):
        pass


class RateMeter:
    """简单速率计: 用于打印瞬时/平均吞吐"""

    def __init__(self):
        self.t0 = time.perf_counter()
        self.n = 0
        self.n_byte = 0
        self.t_mark = self.t0

    def add(self, nbytes: int):
        self.n += 1
        self.n_byte += nbytes

    def avg_mbps(self) -> float:
        dt = max(time.perf_counter() - self.t0, 1e-9)
        return self.n_byte * 8 / dt / 1e6

    def inst_mbps(self) -> float:
        now = time.perf_counter()
        dt = max(now - self.t_mark, 1e-9)
        self.t_mark = now
        return self.n_byte * 8 / dt / 1e6


# ===========================================================================
# 输出小工具
# ===========================================================================
def hr(ch: str = "-", n: int = 78) -> str:
    return ch * n


def print_adapters(prefix: str = "") -> None:
    if prefix:
        print(prefix)
    print(_usage_adapters())


def verdict(name: str, ok: bool, detail: str = "") -> str:
    tag = "PASS" if ok else "FAIL"
    return "  [%s] %-22s %s" % (tag, name, detail)


# ===========================================================================
# 统一发送器 (sender.py / sfp_link_check.py 共用)
# ===========================================================================
SFP_SRC_PORT_DEFAULT = 40000    # 自建首部模式下的固定源端口 (FPGA 侧不校验源端口)


class FrameSender:
    """UDP / raw(IP_HDRINCL) / l2(AF_PACKET) 三模式统一发送器

    对上层只暴露 send(payload): payload 是 **UDP 载荷** (fpga_codec 产出的一个个
    包, 含 16 B 条带头). 首部由本类按模式补齐:

        udp : 交给内核 IP 栈 (需要 OS 路由 / 邻居表里有目的 MAC)
        raw : SOCK_RAW + IP_HDRINCL, 以太头交给网卡, IP/UDP 首部自建 (需管理员)
        l2  : 以太 + IP + UDP 全部自建 (Linux AF_PACKET; Windows 需 Npcap, 本机未装)

    首部缓存: 首部只与 payload 长度有关 (UDP 校验和填 0, IPv4 校验和只覆盖 20 B
    首部), 所以按长度缓存前缀, 之后每包只做一次 bytes 拼接 —— 1080p60 有 ~4.6 万
    pps, 每包重算三层首部在 Python 里根本来不及。
    """

    def __init__(self, dst_ip: str, dst_port: int, mode: str = "udp",
                 iface: str | None = None, src_ip: str | None = None,
                 src_port: int = 0, dst_mac: str | None = None,
                 no_arp: bool = False, arp_timeout: float = 3.0,
                 sndbuf_mb: int = 8, eth_type: int = ETH_TYPE_IPV4,
                 verbose: bool = True):
        self.dst_ip = dst_ip
        self.dst_port = dst_port
        self.mode = mode
        self.eth_type = eth_type
        self.verbose = verbose
        self.n_pkt = 0
        self.n_byte = 0            # 载荷字节 (不含自建首部)
        self.n_wire = 0            # 线上字节 (含首部+前导+IPG+FCS)
        self.n_err = 0
        self.note = ""
        self.arp_type = "-"
        self.dst_mac = None
        self._hdr: dict = {}
        self.src_port = src_port or (SFP_SRC_PORT_DEFAULT if mode != "udp" else 0)

        self.ada = find_adapter(iface) if iface else None
        if self.ada is None and iface:
            raise SystemExit("[错误] --iface %r 未匹配到网卡 (用 --list-iface 看列表)"
                             % iface)
        self.src_ip = src_ip or (adapter_ipv4(self.ada) if self.ada else None)
        if self.ada is not None and not self.src_ip:
            raise SystemExit("[错误] 网卡 %d 没有 IPv4 地址, 请显式给 --src-ip"
                             % self.ada["index"])
        self.mtu = iface_mtu(self.ada["index"]) if self.ada else None

        if dst_ip.startswith("127.") and mode != "udp":
            raise SystemExit("[错误] %s 模式不支持 127.x 回环 (回环没有二层帧)" % mode)

        if mode == "udp":
            self._open_udp()
            return

        self.dst_mac_b = parse_mac(dst_mac) if dst_mac else None
        if self.dst_mac_b is None:
            if no_arp:
                raise SystemExit("[错误] --no-arp 需要同时给 --dst-mac")
            if verbose:
                print("  [ARP] 正在解析 %s 的 MAC ..." % dst_ip)
            got = arp_resolve(dst_ip, self.src_ip, timeout=arp_timeout, verbose=verbose)
            if not got:
                raise SystemExit(
                    "[错误] ARP 解析 %s 失败。可选: ① --dst-mac 00:11:22:33:44:55; "
                    "② 配静态 ARP (arp -s); ③ 用 --mode udp 走内核 IP 栈" % dst_ip)
            self.dst_mac_b = parse_mac(got)
            self.arp_type = arp_table().get(dst_ip, {}).get("type", "?")
        self.dst_mac = fmt_mac(self.dst_mac_b)
        self.src_mac_b = (self.ada or {}).get("mac_raw") or b"\x00" * 6
        if not (self.ada or {}).get("mac_raw"):
            # 没给 --iface 就自动挑一张: 目的 IP 所在网段优先, 否则第一张有线网卡
            pick = pick_iface_for(dst_ip)
            if pick:
                self.ada = pick
                self.src_ip = self.src_ip or adapter_ipv4(pick)
                self.mtu = iface_mtu(pick["index"])
                self.src_mac_b = pick.get("mac_raw") or b"\x00" * 6
                if verbose:
                    print("  [iface] 自建首部需要 MAC, 自动选网卡 [%d] %s (%s)"
                          % (pick["index"], pick["desc"], pick["mac"]))
        if not (self.ada or {}).get("mac_raw"):
            raise SystemExit("[错误] 网卡 MAC 未取到, 自建二层首部需要它 (--list-iface 看)")

        if mode == "l2":
            if not hasattr(socket, "AF_PACKET"):
                raise SystemExit(
                    "[错误] l2 模式在 Windows 上需要 Npcap (wpcap.dll), 本机未安装。\n"
                    "         实测 C:\\Windows\\System32\\wpcap.dll 不存在\n"
                    "         替代: ① --mode raw (管理员 + 原始套接字, 首部自建, 效果等价);\n"
                    "               ② --mode udp (普通 UDP, FPGA 侧一样能收);\n"
                    "               ③ 装 Npcap 后重试 (未证实: 本机从未验证成功过 l2)。")
            self._open_l2()
        else:
            try:
                self._open_raw()
            except PermissionError as e:
                raise SystemExit("[错误] raw 模式需要管理员权限: %s\n"
                                 "         请用管理员终端, 或改用 --mode udp" % e)

    # ---- 三种底层套接字 ----
    def _open_udp(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        if self.ada is not None:
            s.bind((self.src_ip, self.src_port))
        elif self.src_port:
            s.bind(("0.0.0.0", self.src_port))
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8 << 20)
        except OSError:
            pass
        # 如果手动指定了源 IP, 这里校验它是否真的挂在本机 (否则 sendto 会
        # 静默地把包交给默认路由 —— 实测: 源 IP 10.83.61.159 发往 192.168.1.10
        # 无人应答, 而内核并不报错, 极易误判成「链路丢包 100%」)。
        if self.src_ip:
            ips = {(ip, _m) for a in (list_adapters() or [])
                   for (ip, _m) in a.get("ips") or []}
            ips = {ip for (ip, _m) in ips if ip and ip != "0.0.0.0"}
            if self.src_ip not in ips:
                raise SystemExit(
                    "[错误] 源 IP %s 不在本机任何网卡上。sendto 会改走默认路由, "
                    "让你在错误的网卡上压测。\n         本机网卡 IP: %s\n"
                    "         用 Tools/sfp_link_check.py --list-iface 查看。"
                    % (self.src_ip, ", ".join(sorted(ips)) or "(无)"))
        self.sock = s
        self.addr = (self.dst_ip, self.dst_port)
        self.note = "内核 IP 栈 (自动 ARP/路由)"

    def _open_raw(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
        s.setsockopt(socket.IPPROTO_IP, socket.IP_HDRINCL, 1)
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8 << 20)
        except OSError:
            pass
        if self.src_ip:
            try:
                s.bind((self.src_ip, 0))
            except OSError:
                pass
        if self.ada:
            try:
                s.setsockopt(socket.IPPROTO_IP, IP_UNICAST_IF,
                             socket.htonl(self.ada["index"]))
            except OSError as e:
                if self.verbose:
                    print("  [提示] IP_UNICAST_IF 设置失败 (%s); 发送网卡由路由决定" % e)
        self.sock = s
        self.addr = (self.dst_ip, 0)
        self.note = "原始套接字 + IP_HDRINCL (需管理员)"

    def _open_l2(self):
        s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(self.eth_type))
        s.bind((self.ada["name"], 0))
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8 << 20)
        except OSError:
            pass
        self.sock = s
        self.addr = None
        self.note = "AF_PACKET 二层直发"

    # ---- 首部缓存 ----
    def header_for(self, plen: int) -> bytes:
        h = self._hdr.get(plen)
        if h is None:
            eth = (build_eth(self.dst_mac_b, self.src_mac_b, self.eth_type)
                   if self.mode == "l2" else b"")
            # 首部字段必须算「真实长度」, 用占位载荷算长度字段即可 (不真发占位数据):
            #   UDP 校验和=0 (IPv4 允许), 所以只看 长度 字段 = 8 + plen
            #   IPv4 总长 = 20 + 8 + plen
            ip = build_ipv4(self.src_ip or "0.0.0.0", self.dst_ip,
                            bytes(UDP_HDR + plen))[:IP_HDR]
            udp = struct.pack(">HHHH", self.src_port, self.dst_port,
                              UDP_HDR + plen, 0)
            h = eth + ip + udp
            self._hdr[plen] = h
        return h

    def send(self, payload: bytes) -> int:
        n = len(payload)
        wire = n + ETH_HDR + IP_HDR + UDP_HDR + ETH_FCS + ETH_PREAMBLE_IPG
        try:
            if self.mode == "udp":
                self.sock.sendto(payload, self.addr)
            else:
                frame = self.header_for(n) + payload
                if self.addr is None:
                    self.sock.send(frame)
                else:
                    self.sock.sendto(frame, self.addr)
        except OSError as e:
            self.n_err += 1
            if self.n_err <= 3 and self.verbose:
                print("  [发送错误] %s: %s" % (type(e).__name__, e))
            return 0
        self.n_pkt += 1
        self.n_byte += n
        self.n_wire += wire
        return n

    def wire_bytes(self, payload) -> int:
        """该包在 1GbE 线路上的总字节数 (载荷 + 各层首部 + FCS + 前导/IPG)

        用途: --shape-basis wire 时按真实线速计费 (1GbE 物理层 125 MB/s =
        1000 Mbit/s, 不是 957.1). 省略 FCS/前导/IPG 会低估 ~5%%.
        """
        return len(payload) + ETH_HDR + IP_HDR + UDP_HDR + ETH_FCS + ETH_PREAMBLE_IPG

    def send_frame(self, packets) -> int:
        """发一帧的全部包, 返回载荷字节数 (与旧 UdpSender 接口兼容)"""
        tot = 0
        for p in packets:
            tot += self.send(p)
        return tot

    def describe(self) -> str:
        bits = ["模式=%s" % self.mode, "目的=%s:%d" % (self.dst_ip, self.dst_port),
                self.note]
        if self.ada:
            bits.append("网卡=[%d]%s" % (self.ada["index"], self.ada["desc"][:28]))
        if self.src_ip:
            bits.append("源IP=%s" % self.src_ip)
        if self.mode != "udp":
            bits.append("源端口=%d" % self.src_port)
            bits.append("目的MAC=%s(ARP:%s)" % (self.dst_mac, self.arp_type))
        return "  ".join(bits)

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


__all__ = [
    "SFP_SRC_PORT_DEFAULT", "FrameSender", "pick_iface_for",
    "IS_WINDOWS", "ETH_TYPE_IPV4", "ETH_TYPE_ARP", "ETH_TYPE_SFP_RAW",
    "ETH_HDR", "ETH_FCS", "ETH_PREAMBLE_IPG", "IP_HDR", "UDP_HDR", "FRAMING",
    "MTU_DEFAULT", "UDP_PAYLOAD_FOR_MTU1500", "MAX_TILE_DATA",
    "LINK_BUDGET_BPS", "SHAPE_DEFAULT_BPS", "DESIGN_TARGET_BPS",
    "PROBE_MAGIC", "PROBE_HDR_SIZE", "PROBE_PROTO_DEFAULT", "PROBE_FLAG_REPLY",
    "IP_UNICAST_IF", "IP_MTU_DISCOVER", "IP_PMTUDISC_DO",
    "now_ns", "fmt_mac", "parse_mac", "ip4_to_int", "ip4_to_bytes",
    "list_adapters", "find_adapter", "adapter_ipv4", "iface_mtu",
    "best_iface_index", "print_adapters",
    "arp_table", "arp_lookup", "arp_resolve",
    "ip_checksum", "build_eth", "build_ipv4", "build_udp", "build_frame",
    "build_frame_raw", "pack_probe", "parse_probe", "make_reply", "flip_to_reply",
    "hybrid_sleep", "Shaper", "FramePacer", "RateMeter", "hr", "verdict",
]
