"""Compare get_app_state latency between sky and mac-cua across several apps."""
import time, sys, subprocess
sys.path.insert(0, "/Users/paras/projects/mac-cua-mcp/harness")
from broker import make_brokers


APPS = [
    ("com.apple.calculator", "Calculator"),
    ("com.apple.TextEdit", "TextEdit"),
    ("com.apple.finder", "Finder"),
    ("com.apple.Notes", "Notes"),
]


def bench(broker, bundle):
    broker.call("get_app_state", {"app": bundle})  # warm
    samples = []
    for _ in range(3):
        t0 = time.perf_counter()
        r = broker.call("get_app_state", {"app": bundle})
        samples.append(time.perf_counter() - t0)
    txt = r.get("text", "")
    return min(samples), sum(samples) / len(samples), len(txt.splitlines())


def main():
    for _, name in APPS:
        subprocess.run(["open", "-a", name])
    time.sleep(2.0)

    sky, mac = make_brokers()
    try:
        print(f"\n{'app':<16} {'sky min(s)':>11} {'mac min(s)':>11} {'sky lines':>10} {'mac lines':>10}")
        print("─" * 62)
        for bundle, name in APPS:
            try:
                s_min, _, s_lines = bench(sky, bundle)
            except Exception as e:
                s_min, s_lines = -1, 0
            try:
                m_min, _, m_lines = bench(mac, bundle)
            except Exception as e:
                m_min, m_lines = -1, 0
            print(f"{name:<16} {s_min:>11.3f} {m_min:>11.3f} {s_lines:>10} {m_lines:>10}")
    finally:
        sky.close(); mac.close()


if __name__ == "__main__":
    main()
