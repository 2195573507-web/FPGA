
"""t17 完整吞吐曲线 bench --- 输出到 stdout, 用后台作业跑以免阻塞。

覆盖:
  * 单线程参考 (与旧 --live 同路径) + md5
  * encode_pool 在 W=1/2/4/8/12/16 的吞吐 + 帧序 + 逐字节一致性
  * 解码/编码/等待耗时分解
"""
import os, sys, time, json, hashlib
def main():
    sys.path.insert(0, r"D:/FPGA/Tools")
    import numpy as np, fpga_codec as fc, encode_pool as ep
    VIDEO = r"D:/FPGA/videos/video_20260929_111440.mp4"
    NF = int(os.environ.get("NF", "96"))
    WS = [int(x) for x in os.environ.get("WORKERS", "1,2,4,8,12,16").split(",")]
    TR = os.environ.get("TR", "pickle")
    FAST = os.environ.get("FAST", "0") == "1"
    out = os.environ.get("OUT", "D:/FPGA/_tmp/t17_curve.json")

    print("== reference serial (encode_frame, no pool) ==", flush=True)
    t0 = time.perf_counter()
    ref_md5, ref_bytes = [], 0
    for idx, rgb in enumerate(ep.decode_frames(VIDEO, NF)):
        pkts, st = fc.encode_frame(rgb, idx)
        ref_md5.append(hashlib.md5(b"".join(pkts)).hexdigest())
        ref_bytes += st["payload_bytes"]
    t_ref = time.perf_counter() - t0
    print("serial: %d frames %.3f s = %.2f fps  (%.1f ms/frame) payload %.1f KB/frame"
          % (NF, t_ref, NF/t_ref, t_ref/NF*1000, ref_bytes/NF/1024), flush=True)
    print("md5[f0]=%s" % ref_md5[0], flush=True)

    rows = []
    for W in WS:
        t0 = time.perf_counter()
        pool = ep.FrameEncoderPool(VIDEO, n_workers=W, max_frames=NF, transport=TR,
                                   fast=FAST, budget=10 ** 9)
        md5s, ids, nb = [], [], 0
        try:
            for idx, q, pkts, st in pool.frames():
                ids.append(idx)
                md5s.append(hashlib.md5(b"".join(pkts)).hexdigest())
                nb += st["payload_bytes"]
        finally:
            pool.close()
        dt = time.perf_counter() - t0
        same = md5s == ref_md5
        print("W=%-3d %.2fs %6.2f fps %7.1f Mbit/s | order:%s identical:%s | dec %.2f enc %.2f wait %.2f"
              % (W, dt, NF/dt, nb*8/NF*fc.FPS/1e6,
                 "OK" if ids == list(range(len(ids))) else "BAD",
                 "OK" if same else "MISMATCH",
                 pool.decode_seconds, pool.encode_seconds, pool.wait_seconds), flush=True)
        rows.append(dict(workers=W, seconds=dt, fps=NF/dt, mbit_s=nb*8/NF*fc.FPS/1e6,
                         identical=same, order_ok=(ids == list(range(len(ids)))),
                         decode_s=pool.decode_seconds, encode_s=pool.encode_seconds,
                         wait_s=pool.wait_seconds))
    json.dump(dict(n_frames=NF, video=os.path.basename(VIDEO), transport=TR, fast=FAST,
                   reference=dict(seconds=t_ref, fps=NF/t_ref, md5_f0=ref_md5[0],
                                  payload_bytes=ref_bytes), rows=rows),
              open(out, "w"), indent=1)
    print("curve written to", out, flush=True)

if __name__ == "__main__":
    main()
