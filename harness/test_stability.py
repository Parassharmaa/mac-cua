"""Hammer each broker with 100 back-to-back calls to catch leaks or flakes."""
import os, subprocess, time, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from broker import make_brokers


def hammer(broker, N=100):
    subprocess.run(["open", "-a", "Calculator"])
    time.sleep(0.8)
    errors = []
    t0 = time.time()
    for i in range(N):
        r = broker.call("get_app_state", {"app": "com.apple.calculator"})
        if "error" in r or "sky_rejected" in r:
            errors.append((i, r.get("error") or r.get("sky_rejected", "")[:60]))
    dt = time.time() - t0
    return N, errors, dt


def main():
    sky, mac = make_brokers()
    try:
        print("\n[stability: 100 × get_app_state Calculator]")
        s_n, s_err, s_dt = hammer(sky)
        print(f"  sky: {s_n - len(s_err)}/{s_n} ok in {s_dt:.1f}s  ({s_dt/s_n*1000:.1f}ms/call)")
        if s_err: print(f"        errors: {s_err[:3]}")

        m_n, m_err, m_dt = hammer(mac)
        print(f"  mac: {m_n - len(m_err)}/{m_n} ok in {m_dt:.1f}s  ({m_dt/m_n*1000:.1f}ms/call)")
        if m_err: print(f"        errors: {m_err[:3]}")

        return 0 if (not s_err and not m_err) else 1
    finally:
        sky.close(); mac.close()


if __name__ == "__main__":
    sys.exit(main())
