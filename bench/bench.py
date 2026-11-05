"""Tensor-core throughput benchmark for before/after comparison of nv-uefi-unlocker.

Usage:  python bench.py <label>      e.g.  python bench.py before   /   python bench.py after
Writes results/<label>.json and prints a table. Run `python bench.py --compare before after` to diff.
Keep conditions identical: power adapter plugged in, same vendor power/performance mode, GPU cool, nothing else running.
"""

import json
import subprocess
import sys
import time
from pathlib import Path

RESULTS = Path(__file__).parent / "results"
N = 8192          # square matmul size
WARMUP_S = 3.0    # warm-up seconds per case
MEASURE_S = 10.0  # measured seconds per case


def smi():
    q = "name,vbios_version,driver_version,clocks.sm,clocks.mem,power.draw,enforced.power.limit,temperature.gpu"
    out = subprocess.run(["nvidia-smi", f"--query-gpu={q}", "--format=csv,noheader,nounits"],
                         capture_output=True, text=True).stdout.strip()
    return dict(zip(q.split(","), [v.strip() for v in out.split(",")]))


def bench_case(torch, name, dtype, tf32=False):
    torch.backends.cuda.matmul.allow_tf32 = tf32
    torch.backends.cuda.matmul.allow_fp16_reduced_precision_reduction = False  # force FP32 accumulate
    torch.backends.cuda.matmul.allow_bf16_reduced_precision_reduction = False
    a = torch.randn(N, N, device="cuda", dtype=dtype)
    b = torch.randn(N, N, device="cuda", dtype=dtype)
    flop = 2 * N ** 3

    def run_for(seconds):
        iters, t0 = 0, time.perf_counter()
        torch.cuda.synchronize()
        while time.perf_counter() - t0 < seconds:
            for _ in range(5):
                a @ b
            torch.cuda.synchronize()
            iters += 5
        return iters, time.perf_counter() - t0

    run_for(WARMUP_S)
    iters, dt = run_for(MEASURE_S * 0.5)
    mid = smi()  # sample clocks/power under load
    iters2, dt2 = run_for(MEASURE_S * 0.5)
    tflops = flop * (iters + iters2) / (dt + dt2) / 1e12
    del a, b
    torch.cuda.empty_cache()
    return {"case": name, "tflops": round(tflops, 2), "sm_mhz": mid.get("clocks.sm"),
            "power_w": mid.get("power.draw"), "temp_c": mid.get("temperature.gpu")}


def run(label):
    import torch
    assert torch.cuda.is_available(), "CUDA not available"
    info = smi()
    print(f"GPU: {info['name']}  vBIOS {info['vbios_version']}  driver {info['driver_version']}  "
          f"PL {info['enforced.power.limit']} W  torch {torch.__version__}")
    cases = [
        ("FP32 (no TF32)", torch.float32, False),
        ("TF32", torch.float32, True),
        ("FP16 (FP32 acc)", torch.float16, False),
        ("BF16 (FP32 acc)", torch.bfloat16, False),
    ]
    res = []
    for name, dt, tf32 in cases:
        r = bench_case(torch, name, dt, tf32)
        print(f"  {name:18s} {r['tflops']:7.2f} TFLOPS   SM {r['sm_mhz']} MHz  {r['power_w']} W  {r['temp_c']} °C")
        res.append(r)
        time.sleep(5)  # cool-down between cases
    RESULTS.mkdir(exist_ok=True)
    out = RESULTS / f"{label}.json"
    out.write_text(json.dumps({"label": label, "time": time.ctime(), "gpu": info,
                               "torch": torch.__version__, "results": res}, indent=2))
    print(f"saved {out}")


def compare(a, b):
    A = json.loads((RESULTS / f"{a}.json").read_text())
    B = json.loads((RESULTS / f"{b}.json").read_text())
    bm = {r["case"]: r for r in B["results"]}
    print(f"{'case':18s} {a:>10s} {b:>10s}   factor")
    for r in A["results"]:
        o = bm.get(r["case"])
        if o:
            print(f"{r['case']:18s} {r['tflops']:10.2f} {o['tflops']:10.2f}   x{o['tflops'] / r['tflops']:.2f}")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--compare":
        compare(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 2:
        run(sys.argv[1])
    else:
        print(__doc__)
