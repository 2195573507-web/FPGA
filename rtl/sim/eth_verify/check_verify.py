#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""check_verify.py --- compare <scen>.got against <scen>.exp line by line.
Usage: python check_verify.py <prefix>   (reads <prefix>.got and <prefix>.exp)
Output: 'V6 PASS <name> lines=N STAT=...' or 'V6 FAIL <name> <reason>'"""
import sys, os

def load(p):
    rows = []
    with open(p) as f:
        for ln in f:
            ln = ln.strip()
            if ln: rows.append(ln)
    return rows

def norm(rows):
    out = []
    for r in rows:
        tok = r.split()
        out.append((tok[0], tuple(int(x) for x in tok[1:])))
    return out

def main():
    pfx = sys.argv[1]
    name = os.path.basename(pfx)
    got_p, exp_p = pfx + '.got', pfx + '.exp'
    if not os.path.exists(got_p): print('V6 FAIL %s no .got (TB did not run)' % name); return 1
    if not os.path.exists(exp_p): print('V6 FAIL %s no .exp' % name); return 1
    g, e = norm(load(got_p)), norm(load(exp_p))
    if len(g) != len(e):
        print('V6 FAIL %s line count got=%d exp=%d' % (name, len(g), len(e))); return 1
    for i, (a, b) in enumerate(zip(g, e)):
        if a != b:
            print('V6 FAIL %s first mismatch line %d: got=%s exp=%s' % (name, i + 1, a, b)); return 1
    st = [r for r in g if r[0] == 'STAT'][0][1]
    print('V6 PASS %s lines=%d STAT=%s' % (name, len(g), ' '.join('%d' % x for x in st)))
    return 0

if __name__ == '__main__':
    sys.exit(main())
