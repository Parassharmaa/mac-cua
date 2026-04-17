"""Measure end-to-end input latency: tool call → observable effect via AX.

For each tool, time how long between sending the call and seeing the state
change in AX. This catches overhead differences in event dispatch.
"""
import subprocess, time, sys
sys.path.insert(0, "/Users/paras/projects/mac-cua-mcp/harness")
from broker import make_brokers
from ax_util import read_ax_value


def setup_textedit():
    subprocess.run(["pkill", "-9", "TextEdit"])
    time.sleep(0.8)
    path = f"/tmp/latency-{int(time.time())}.txt"
    open(path, "w").write("")
    subprocess.run(["open", "-a", "TextEdit", path])
    time.sleep(1.5)
    subprocess.run(["osascript", "-e", 'tell application "TextEdit" to activate'])
    time.sleep(0.4)


def clear_textedit():
    subprocess.run(["osascript", "-e",
        '''tell application "System Events" to tell process "TextEdit"
              set value of text area 1 of scroll area 1 of window 1 to ""
           end tell'''])
    time.sleep(0.15)


def measure_type_text(broker, marker, samples=5):
    """tool call -> AX-readable text change."""
    ts = []
    for _ in range(samples):
        clear_textedit()
        broker.call("get_app_state", {"app": "com.apple.TextEdit"})  # prime
        t0 = time.perf_counter()
        broker.call("type_text", {"text": marker, "app": "com.apple.TextEdit"})
        # poll until the text appears in AX
        deadline = t0 + 2.0
        while time.perf_counter() < deadline:
            v = read_ax_value("com.apple.TextEdit",
                                "value of text area 1 of scroll area 1 of window 1")
            if marker in v:
                ts.append(time.perf_counter() - t0)
                break
            time.sleep(0.01)
        else:
            ts.append(None)
    return [t for t in ts if t is not None]


def measure_press_key(broker, ch, samples=5):
    """press_key -> AX-readable content change."""
    ts = []
    for _ in range(samples):
        clear_textedit()
        broker.call("get_app_state", {"app": "com.apple.TextEdit"})
        t0 = time.perf_counter()
        broker.call("press_key", {"key": ch, "app": "com.apple.TextEdit"})
        deadline = t0 + 2.0
        while time.perf_counter() < deadline:
            v = read_ax_value("com.apple.TextEdit",
                                "value of text area 1 of scroll area 1 of window 1")
            if ch in v:
                ts.append(time.perf_counter() - t0)
                break
            time.sleep(0.01)
        else:
            ts.append(None)
    return [t for t in ts if t is not None]


def fmt(ts):
    if not ts: return "no samples"
    mn = min(ts); mx = max(ts); avg = sum(ts) / len(ts)
    return f"min={mn*1000:.0f}ms  avg={avg*1000:.0f}ms  max={mx*1000:.0f}ms  (n={len(ts)})"


def main():
    setup_textedit()
    sky, mac = make_brokers()
    try:
        print("\n[type_text 'X']  — broker call → AX visible")
        print(f"  sky: {fmt(measure_type_text(sky, 'X'))}")
        print(f"  mac: {fmt(measure_type_text(mac, 'X'))}")
        print("\n[press_key 'z']")
        print(f"  sky: {fmt(measure_press_key(sky, 'z'))}")
        print(f"  mac: {fmt(measure_press_key(mac, 'z'))}")
    finally:
        sky.close(); mac.close()


if __name__ == "__main__":
    main()
