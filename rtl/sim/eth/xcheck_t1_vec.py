#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""xcheck_t1_vec.py --- 把 t1 (sfp_path) 独立生成的场景向量接进 t5 的仿真台。

目的: t1 的 scen_*.{hex,len} 是由**上游任务独立生成**的激励, 并且 t1 已经用
厂商 RTL 链实测出每个场景的字节数 (RESULT bytes=...)。把它们喂给 t5 的
tb_eth_pkt_rx.v, 就是拿另一来源的激励 + 另一来源的期望去校验 t5 的 RTL,
避免"自己出题自己判卷"。

输入:
  D:/FPGA/docs/assets/sfp_path_rx_sim/scen_<s>.hex   每行 1 字节 hex
  D:/FPGA/docs/assets/sfp_path_rx_sim/scen_<s>.len   首行帧数; 随后 "帧长 应用载荷 包数"

列语义 (已核实, 见 tb_sfp_rx_scen.v:48 与 t1 实测 RESULT):
  - 列 2 是**应用载荷**字节数 (不含 16 B 应用包头); V1 写 1456 而 RTL 应投递 1472。
    反证: t1 实测 base bytes=24016 = 16*1472 + 4*116 ✓ (若按 1456 计只有 23696 ✗)。
  - 列 3 是 t1 的信息性备注, t1 自己的 TB 未用它做比较 (只在 $display 里打印)。
    故本脚本只在列 3 == 1 时用列 2 做逐帧断言。

输出: vec/t1_<s>_*.{hex,txt} (含 t1_total / t1_sof 两行硬锚点) + 追加 manifest。
硬锚点取自 t1 实测 (bash run_sfp_rx_sim.sh 的 RESULT 行), 与 t5 模型**独立**。
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))          # D:/FPGA/rtl/sim -> gen_ethvec
import gen_ethvec as G

T1 = r'D:/FPGA/docs/assets/sfp_path_rx_sim'
OUT = G.OUT

# ---- t1 实测锚点 (bash run_sfp_rx_sim.sh, IFG=48) ----
# 场景 -> (RESULT bytes, RESULT sof, 是否要求逐帧载荷断言)
# 场景 -> (实测 bytes, 实测 sof, 实测 crcfail)
T1_MEASURED = {
    'base':    (24016, 20, 0),
    'badbody': (24016, 20, 1),   # 帧 1 的 16 B 应用包头被故意改坏 -> pkt_parse crc 校验失败
    'badfcs':  (24016, 20, 0),   # MAC FCS 错不影响投递, 应用层 CRC 仍全过
    'arp':     (24016, 20, 0),
    'badport': (22544, 19, 0),
    'badip':   (22544, 19, 0),
}

mismatch = 0
lines_out = []

for s in ['base', 'badbody', 'badfcs', 'arp', 'badport', 'badip']:
    hp = os.path.join(T1, 'scen_%s.hex' % s)
    lp = os.path.join(T1, 'scen_%s.len' % s)
    if not (os.path.exists(hp) and os.path.exists(lp)):
        print('  SKIP %s (缺文件)' % s); continue
    with open(hp) as f:
        raw = bytes(int(x.strip(), 16) for x in f if x.strip())
    with open(lp) as f:
        meta = [l.split() for l in f if l.strip()]
    nfr = int(meta[0][0])
    if len(meta) - 1 != nfr:
        print('  WARN %s: len 文件帧数 %d != 首行 %d' % (s, len(meta) - 1, nfr))
        nfr = len(meta) - 1

    frames = []
    off = 0
    for i in range(nfr):
        L = int(meta[i + 1][0])
        frames.append(raw[off:off + L])
        off += L
    if off != len(raw):
        print('  WARN %s: 消费 %d B != 文件 %d B' % (s, off, len(raw)))

    seg, exp = [], []
    pay_all = bytearray()
    arp_req = 0
    for i, fr in enumerate(frames):
        r = G.with_macerr(G.expect_frame(fr), fr)
        assert_pay = (len(meta[i + 1]) > 2 and meta[i + 1][2] == '1')
        if assert_pay:
            t1_pload = int(meta[i + 1][1])
            t1_pay = (16 + t1_pload) if t1_pload > 0 else 0
            if t1_pay != len(r['pay']):
                mismatch += 1
                print('  MODEL MISMATCH %s fd %d: t5 %d B vs t1 折算 %d B (载荷 %d) bucket=%s note=%s'
                      % (s, i, len(r['pay']), t1_pay, t1_pload, r['bucket'], r['note']))
        pay_all += r['pay']
        seg.append('%04x' % len(fr))
        seg.append('ffff')
        exp.append('%d %d %d %s %d %s' % (i, len(r['pay']), 1 if len(r['pay']) > 0 else 0,
                                          r['bucket'], r['mac_err'], 'from t1 scen_%s' % s))
        # ARP 请求 (op=1 且 target IP = 本机 IP 且长度 >= 64) => 本机应回应答
        if len(fr) >= 64 and fr[12:14] == b'\x08\x06' and fr[20:22] == b'\x00\x01' and fr[38:42] == G.LOCAL_IP:
            arp_req += 1

    t1_total, t1_sof, t1_crcfail = T1_MEASURED[s]
    my_total = len(pay_all)
    my_sof = sum(1 for e in exp if int(e.split()[2]) > 0)
    if my_total != t1_total:
        mismatch += 1
        print('  MODEL MISMATCH %s 总字节: t5 模型 %d vs t1 实测 %d' % (s, my_total, t1_total))
    if my_sof != t1_sof:
        mismatch += 1
        print('  MODEL MISMATCH %s sot 包数: t5 模型 %d vs t1 实测 %d' % (s, my_sof, t1_sof))

    pfx = 't1_' + s
    with open(os.path.join(OUT, pfx + '_p.hex'), 'w') as f:
        f.write(''.join('%02x\n' % b for b in raw))
    with open(os.path.join(OUT, pfx + '_seg.hex'), 'w') as f:
        f.write(''.join(x + '\n' for x in seg))
    with open(os.path.join(OUT, pfx + '_e.txt'), 'w') as f:
        f.write(''.join(x + '\n' for x in exp))
    with open(os.path.join(OUT, pfx + '_pay.hex'), 'w') as f:
        f.write(''.join('%02x\n' % b for b in pay_all))
    with open(os.path.join(OUT, pfx + '_meta.txt'), 'w') as f:
        f.write('ifg 48\n')
        f.write('arp_req %d\n' % arp_req)
        f.write('t1_total %d\n' % t1_total)
        f.write('t1_sof %d\n' % t1_sof)
        f.write('crc_fail %d\n' % t1_crcfail)
    lines_out.append('%s %d %d %d' % (pfx, nfr, my_total, my_sof))
    print('  OK %s: %d 帧, 投递 %d B / %d 包 (t1 实测锚点 %d B / %d 包), arp_req=%d'
          % (pfx, nfr, my_total, my_sof, t1_total, t1_sof, arp_req))

mf = os.path.join(OUT, 'manifest.txt')
old = []
if os.path.exists(mf):
    with open(mf) as f:
        old = [l.strip() for l in f if l.strip() and not l.startswith('t1_')]
with open(mf, 'w') as f:
    f.write('\n'.join(old + lines_out) + '\n')
print('MODEL MISMATCH count = %d' % mismatch)
print('manifest 共 %d 条 (自有 %d + t1 %d)' % (len(old) + len(lines_out), len(old), len(lines_out)))
sys.exit(1 if mismatch else 0)
