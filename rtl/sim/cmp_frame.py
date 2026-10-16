# ===========================================================================
# cmp_frame.py --- 比对 frame_ctrl 实测事件流与黄金模型期望
# 用法: python cmp_frame.py <got_prefix> [exp_prefix]
#   <got_prefix>_got.txt  = 本次 TB 实测产物 (可落在临时 WORK 目录)
#   <exp_prefix>_exp.txt  = 黄金模型期望, 缺省与 got_prefix 相同
# 退出码 0 = PASS, 1 = FAIL (含缺少期望/实测文件的情形)
# ===========================================================================
import sys


def load(path):
    stat = None
    evs = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for ln in f:
            t = ln.split()
            if not t:
                continue
            if t[0] == "STAT":
                stat = tuple(int(x) for x in t[1:])
            else:
                evs.append(t)
    return stat, evs


def main():
    if len(sys.argv) < 2:
        print("用法: cmp_frame.py <got_prefix> [exp_prefix]")
        return 2
    pfx = sys.argv[1]
    epfx = sys.argv[2] if len(sys.argv) > 2 else pfx
    exp_s, exp_e = load(epfx + "_exp.txt")
    got_s, got_e = load(pfx + "_got.txt")
    # 缺文件即 FAIL, 不把「读不到」当成空期望后误判 PASS
    if exp_s is None:
        print("  缺少期望文件: %s_exp.txt" % epfx)
        return 1
    if got_s is None:
        print("  缺少实测文件: %s_got.txt" % pfx)
        return 1
    # 显示向量名: 优先用期望文件前缀 (向量目录里的 <name>_exp.txt),
    # 因为 got 前缀可能是临时 WORK 里的 out_<name>。
    name = epfx.replace("\\", "/").split("/")[-1]
    if name.startswith("out_"):
        name = name[4:]
    errs = []
    labels = ["bad", "late", "dup", "oor", "desc_bad", "tile", "done", "drop"]
    if exp_s != got_s:
        for i, lb in enumerate(labels):
            if exp_s[i] != got_s[i]:
                errs.append("stat %s: got %d exp %d" % (lb, got_s[i], exp_s[i]))
    if len(exp_e) != len(got_e):
        errs.append("事件数 got %d exp %d" % (len(got_e), len(exp_e)))
        extra = got_e[len(exp_e):len(exp_e) + 2]
        miss = exp_e[len(got_e):len(got_e) + 2]
        if extra:
            errs.append("多出: " + " | ".join(" ".join(x) for x in extra))
        if miss:
            errs.append("缺少: " + " | ".join(" ".join(x) for x in miss))
    else:
        for i, (a, b) in enumerate(zip(exp_e, got_e)):
            if a != b:
                errs.append("事件[%d] got[%s] exp[%s]" % (i, " ".join(b), " ".join(a)))
                if len(errs) > 6:
                    errs.append("...")
                    break
    if errs:
        print("  %s FAIL  %s" % (name, "; ".join(errs[:8])))
        return 1
    print("  %s PASS  stat=[%s] 事件=%d" % (name, " ".join(str(x) for x in got_s),
                                            len(got_e)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
