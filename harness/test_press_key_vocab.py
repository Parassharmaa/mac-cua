"""Exercise press_key across the xdotool-style key vocabulary Sky supports.

Uses TextEdit as a typing sandbox. For each key spec, verify that:
- sky accepts the call (or at least doesn't reject as unrecognized)
- mac-cua accepts the call
Focuses on named keys (Return, Tab, arrows) and modifier combos (cmd+a).
"""
import sys, time, subprocess
sys.path.insert(0, "/Users/paras/projects/mac-cua-mcp/harness")
from broker import make_brokers
from ax_util import read_ax_value


KEY_CASES = [
    "Return", "Tab", "BackSpace", "Escape", "Delete",
    "Left", "Right", "Up", "Down",
    "Home", "End", "Page_Up", "Page_Down",
    "plus", "minus", "period",
    "KP_0", "KP_5", "KP_9",
    "F1", "F5",
    "cmd+a", "shift+Tab", "alt+Return", "cmd+shift+z",
]


def setup_textedit():
    subprocess.run(["pkill", "-9", "TextEdit"])
    time.sleep(1.0)
    path = f"/tmp/press-key-test-{int(time.time())}.txt"
    open(path, "w").write("")
    subprocess.run(["open", "-a", "TextEdit", path])
    time.sleep(1.5)
    subprocess.run(["osascript", "-e", 'tell application "TextEdit" to activate'])
    time.sleep(0.3)


def probe(broker, key):
    # Re-prime each call — Sky invalidates its session after state changes.
    broker.call("get_app_state", {"app": "com.apple.TextEdit"})
    r = broker.call("press_key", {"key": key, "app": "com.apple.TextEdit"})
    if "error" in r:
        return False, r["error"][:100]
    if "sky_rejected" in r:
        return False, r["sky_rejected"][:100]
    return True, ""


def main():
    setup_textedit()
    sky, mac = make_brokers()
    sky.call("get_app_state", {"app": "com.apple.TextEdit"})
    mac.call("get_app_state", {"app": "com.apple.TextEdit"})

    print(f"\n{'key':<18} {'sky':<6} {'mac':<6}  notes")
    print("─" * 55)
    results = []
    try:
        for key in KEY_CASES:
            s_ok, s_err = probe(sky, key)
            m_ok, m_err = probe(mac, key)
            results.append((key, s_ok, m_ok))
            print(f"{key:<18} {'OK' if s_ok else 'NO':<6} {'OK' if m_ok else 'NO':<6}  {s_err or m_err}")
    finally:
        sky.close(); mac.close()

    s_pass = sum(1 for _, s, _ in results if s)
    m_pass = sum(1 for _, _, m in results if m)
    total = len(results)
    print(f"\nsky: {s_pass}/{total}  mac: {m_pass}/{total}")
    return 0 if (s_pass == total and m_pass == total) else 1


if __name__ == "__main__":
    sys.exit(main())
