# -*- coding: utf-8 -*-
"""fdc <-> 顶层端口一致性检查 (复跑: python PGL/Design/constraints/check_fdc_ports.py)。
判据: fdc 里出现的每个端口名 (归一化去掉位下标) 都必须存在于顶层端口列表。"""
import io, re, sys

TOP = r'D:/FPGA/PGL/Design/source/sfp_pcie_top.v'
FDC = r'D:/FPGA/PGL/Design/constraints/sfp_pcie_top.fdc'

src = io.open(TOP, encoding='utf-8').read()
fdc = io.open(FDC, encoding='utf-8').read()

body = src[src.index('module sfp_pcie_top'):]
i0 = body.index('(')
depth, i1 = 0, -1
for i, ch in enumerate(body[i0:], start=i0):
    if ch == '(':
        depth += 1
    elif ch == ')':
        depth -= 1
        if depth == 0:
            i1 = i
            break
ports = []
for line in body[i0 + 1:i1].split('\n'):
    line = line.split('//')[0].strip().rstrip(',')
    if not line:
        continue
    m = re.match(r'^(input|output|inout)\s+(?:wire\s+|reg\s+)?(?:\[[^\]]*\]\s*)?(.+)$', line)
    if m:
        ports.append(m.group(2).strip())

norm = lambda n: re.sub(r'\[[^\]]*\]$', '', n)
fdc_ports = sorted(set(norm(p) for p in re.findall(r'\{p:([A-Za-z_][A-Za-z0-9_\[\]]*)\}', fdc)))

missing = [p for p in fdc_ports if p not in ports]
unconstrained = [p for p in ports if p not in fdc_ports]

print('顶层端口数: %d (%s)' % (len(ports), ', '.join(ports)))
print('fdc  约束数: %d' % len(fdc_ports))
print('fdc 约束了但顶层没有的端口 (必须为空): %s' % (missing if missing else 'NONE'))
print('顶层有但 fdc 未约束的端口 (PCIe 串行差分对由 IP 内部约束, 仅提示): %s'
      % (unconstrained if unconstrained else 'NONE'))
bad = len(missing) > 0
print('FDCPORT: %s' % ('FAIL' if bad else 'PASS'))
sys.exit(1 if bad else 0)
