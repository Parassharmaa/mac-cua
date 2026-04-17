#!/usr/bin/env python3
"""Comparative harness: runs each tool through Sky (cua) and mac-cua, asserts AX behavior."""
import json, subprocess, time, sys, re, os
sys.stdout.reconfigure(line_buffering=True)

SKY = ["python3", "/Users/paras/Documents/Codex/2026-04-17-open-the-chrome-app/sky_cua.py"]
MAC = ["/Users/paras/projects/mac-cua-mcp/.build/release/cua-mcp"]

GREEN, RED, YELLOW, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"


def okmark(ok): return f"{GREEN}PASS{RESET}" if ok else f"{RED}FAIL{RESET}"


class Broker:
    """Generic JSON-RPC stdio client for an MCP broker."""
    def __init__(self, name, cmd):
        self.name = name
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        self.id = 0
        try:
            self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "harness", "version": "0"}})
        except Exception as e:
            raise RuntimeError(f"[{name}] initialize failed: {e}")

    def rpc(self, method, params=None, timeout=30):
        self.id += 1
        msg = {"jsonrpc": "2.0", "id": self.id, "method": method}
        if params is not None: msg["params"] = params
        self.p.stdin.write((json.dumps(msg) + "\n").encode()); self.p.stdin.flush()
        line = self.p.stdout.readline()
        if not line:
            err = self.p.stderr.read().decode()
            raise RuntimeError(f"[{self.name}] broker died. stderr tail: {err[-500:]}")
        return json.loads(line)

    def call(self, tool, args=None, timeout=30):
        r = self.rpc("tools/call", {"name": tool, "arguments": args or {}}, timeout=timeout)
        if "error" in r:
            return {"error": r["error"].get("message", str(r["error"]))}
        content = r["result"].get("content", [])
        if content:
            txt = content[0].get("text", "")
            # Sky wraps errors as normal content text — surface them
            if "Computer Use is not active" in txt or txt.startswith("The user changed"):
                return {"sky_rejected": txt}
            return {"text": txt}
        return {"raw": r["result"]}

    def close(self):
        try: self.p.stdin.close()
        except: pass
        try: self.p.wait(timeout=2)
        except: self.p.kill()


def front_app():
    return subprocess.check_output(
        ["osascript", "-e", 'tell application "System Events" to get name of first application process whose frontmost is true']
    ).decode().strip()


PROCESS_NAMES = {
    "com.apple.TextEdit": "TextEdit",
    "com.apple.calculator": "Calculator",
    "com.apple.Notes": "Notes",
    "com.google.Chrome": "Google Chrome",
}


def read_ax_value(bundle_id, path):
    proc_name = PROCESS_NAMES.get(bundle_id, bundle_id)
    src = f'''
    tell application "System Events"
      tell process "{proc_name}"
        try
          return {path}
        on error errStr
          return "ERROR:" & errStr
        end try
      end tell
    end tell
    '''
    return subprocess.check_output(["osascript", "-e", src]).decode().strip()


def parse_tree_by_index(state_text):
    """Parse an AX tree response into a dict of index -> (role_label, raw_line)."""
    tree = {}
    for line in state_text.splitlines():
        m = re.match(r"\s*(\d+)\s+(.+)", line)
        if m:
            idx = int(m.group(1))
            tree[idx] = m.group(2)
    return tree


def find_by(tree, predicate):
    for idx, desc in tree.items():
        if predicate(desc): return idx, desc
    return None, None


def find_scroll_area_index(state):
    """Return index of first 'scroll area' element in the tree."""
    for line in state.splitlines():
        m = re.match(r"\s*(\d+)\s+scroll area", line)
        if m: return int(m.group(1))
    return None


# ── Tool tests ──────────────────────────────────────────────────────────────

def test_list_apps(sky, mac):
    print("\n[list_apps]")
    sky_out = sky.call("list_apps")
    mac_out = mac.call("list_apps")
    if "error" in sky_out or "error" in mac_out:
        return False, f"error: sky={sky_out.get('error','-')}  mac={mac_out.get('error','-')}"
    # both return a newline-delimited textual list of apps
    def app_names(text):
        names = []
        for ln in (text or "").splitlines():
            # sky format: "Chrome — com.google.Chrome [running, ...]"
            # mac format: "Google Chrome — com.google.Chrome [active]"
            m = re.match(r"^(.*?)\s+—\s+([^\s\[]+)", ln)
            if m:
                names.append(m.group(2))
        return set(names)
    sky_apps = app_names(sky_out.get("text", ""))
    mac_apps = app_names(mac_out.get("text", ""))
    common = sky_apps & mac_apps
    only_sky = sky_apps - mac_apps
    only_mac = mac_apps - sky_apps
    ok = len(common) >= 5  # both should find many shared apps
    summary = f"common={len(common)}  only_sky={len(only_sky)}  only_mac={len(only_mac)}"
    return ok, summary


def test_get_app_state(sky, mac):
    print("\n[get_app_state]")
    subprocess.run(["open", "-a", "TextEdit", "/tmp/cua-scroll-test.txt"])
    time.sleep(0.8)
    sky_out = sky.call("get_app_state", {"app": "com.apple.TextEdit"})
    mac_out = mac.call("get_app_state", {"app": "com.apple.TextEdit"})
    if "error" in sky_out or "error" in mac_out:
        return False, f"errs: sky={sky_out.get('error','-')} mac={mac_out.get('error','-')}"
    sky_tree = parse_tree_by_index(sky_out.get("text", ""))
    mac_tree = parse_tree_by_index(mac_out.get("text", ""))
    sky_has_scroll = any("scroll area" in d.lower() for d in sky_tree.values())
    mac_has_scroll = any("scroll area" in d.lower() for d in mac_tree.values())
    ok = sky_has_scroll and mac_has_scroll
    return ok, f"sky_nodes={len(sky_tree)} mac_nodes={len(mac_tree)}  both-see-scroll-area={ok}"


def test_scroll_textedit(sky, mac):
    print("\n[scroll TextEdit down]")
    # Fresh open via unique filename — scroll to top first
    subprocess.run(["pkill", "-9", "TextEdit"])
    time.sleep(1.0)
    path = f"/tmp/scroll-test-{int(time.time())}.txt"
    with open(path, "w") as f:
        for i in range(500): f.write(f"Line {i:04d}\n")
    subprocess.run(["open", "-a", "TextEdit", path])
    time.sleep(1.2)
    subprocess.run(["osascript", "-e", 'tell application "TextEdit" to activate'])
    time.sleep(0.3)

    def scroll_to_top_via_os():
        # Cmd+Up in TextEdit scrolls to start
        subprocess.run(["osascript", "-e",
            'tell application "System Events" to tell process "TextEdit" to key code 126 using {command down}'])
        time.sleep(0.3)

    def run(broker):
        scroll_to_top_via_os()
        state = broker.call("get_app_state", {"app": "com.apple.TextEdit"}).get("text", "")
        idx = find_scroll_area_index(state)
        v0 = read_ax_value("com.apple.TextEdit",
                            "value of scroll bar 2 of scroll area 1 of window 1")
        idx_arg = str(idx) if broker.name == "sky" else idx
        broker.call("scroll", {"direction": "down", "pages": 3, "element_index": idx_arg, "app": "com.apple.TextEdit"})
        time.sleep(0.4)
        v1 = read_ax_value("com.apple.TextEdit",
                            "value of scroll bar 2 of scroll area 1 of window 1")
        try:
            d0 = float(v0); d1 = float(v1)
            return d0, d1, d1 > d0 + 0.01
        except:
            return v0, v1, False

    s0, s1, s_ok = run(sky)
    m0, m1, m_ok = run(mac)
    return (s_ok and m_ok), f"sky: {s0}→{s1} ({'ok' if s_ok else 'no'})  mac: {m0}→{m1} ({'ok' if m_ok else 'no'})"


def test_type_text(sky, mac):
    print("\n[type_text into TextEdit]")
    # Quit TextEdit and discard unsaved state, use unique filename to avoid autosave conflicts
    subprocess.run(["pkill", "-9", "TextEdit"])
    time.sleep(1.0)
    unique = f"/tmp/type-test-{int(time.time())}.txt"
    with open(unique, "w") as f: f.write("")
    subprocess.run(["open", "-a", "TextEdit", unique])
    time.sleep(1.5)
    subprocess.run(["osascript", "-e", 'tell application "TextEdit" to activate'])
    time.sleep(0.5)
    # Click the text area to give it focus (needed for keystrokes in the fallback path)
    subprocess.run(["osascript", "-e",
        '''tell application "System Events" to tell process "TextEdit"
             try
               click text area 1 of scroll area 1 of window 1
             end try
           end tell'''])
    time.sleep(0.3)

    def clear_and_prime(broker):
        # Use Cmd+A + Delete via direct AppleScript keystroke to ensure true clear
        subprocess.run(["osascript", "-e",
            'tell application "System Events" to tell process "TextEdit" to keystroke "a" using {command down}'])
        time.sleep(0.15)
        subprocess.run(["osascript", "-e",
            'tell application "System Events" to tell process "TextEdit" to key code 51'])  # delete
        time.sleep(0.25)
        broker.call("get_app_state", {"app": "com.apple.TextEdit"})

    def run_with(broker, marker):
        clear_and_prime(broker)
        r = broker.call("type_text", {"text": marker, "app": "com.apple.TextEdit"})
        rejected = "sky_rejected" in r
        time.sleep(0.6)
        val = read_ax_value("com.apple.TextEdit",
                              'value of text area 1 of scroll area 1 of window 1')
        return val, rejected

    sky_text, sky_rej = run_with(sky, "HELLO_FROM_SKY")
    mac_text, mac_rej = run_with(mac, "HELLO_FROM_MAC")
    sky_ok = "HELLO_FROM_SKY" in (sky_text or "")
    mac_ok = "HELLO_FROM_MAC" in (mac_text or "")
    return (sky_ok and mac_ok), f"sky={sky_text!r}(rej={sky_rej})  mac={mac_text!r}(rej={mac_rej})"


def prime(broker, bundle_id):
    """Sky requires a get_app_state on each target app first in every session."""
    broker.call("get_app_state", {"app": bundle_id})


def test_press_key(sky, mac):
    print("\n[press_key Calculator]")
    subprocess.run(["open", "-a", "Calculator"])
    time.sleep(0.8)
    # Force Basic mode — Cmd+1
    subprocess.run(["osascript", "-e",
        'tell application "Calculator" to activate'])
    time.sleep(0.3)
    subprocess.run(["osascript", "-e",
        'tell application "System Events" to tell process "Calculator" to keystroke "1" using {command down}'])
    time.sleep(0.5)
    prime(sky, "com.apple.calculator")
    prime(mac, "com.apple.calculator")

    def read_calc_display():
        # Scan AX tree for the display Value
        out = subprocess.check_output([
            "osascript", "-e",
            '''tell application "System Events" to tell process "Calculator"
              try
                return value of text field 1 of group 1 of scroll area 1 of group 1 of group 1 of splitter group 1 of group 1 of window 1
              end try
              try
                -- find first static text whose value parses as a number
                return value of static text 1 of scroll area 1 of group 1 of group 1 of splitter group 1 of group 1 of window 1
              end try
              return "?"
            end tell
            '''
        ]).decode().strip()
        return out

    def reset_calc():
        subprocess.run(["osascript", "-e",
            'tell application "Calculator" to activate'])
        time.sleep(0.25)
        # Press Escape several times to clear any pending input, then AC via Escape
        for _ in range(3):
            subprocess.run(["osascript", "-e",
                'tell application "System Events" to tell process "Calculator" to key code 53'])  # Escape
            time.sleep(0.05)
        time.sleep(0.2)

    def display_via_ax():
        # Use osascript to read the calc display
        src = '''
        tell application "System Events"
          tell process "Calculator"
            try
              return value of static text 1 of UI element 1 of scroll area 1 of group 1 of group 1 of splitter group 1 of group 1 of window 1
            end try
            try
              return value of static text 1 of scroll area 1 of group 1 of group 1 of splitter group 1 of group 1 of window 1
            end try
            return "?"
          end tell
        end tell
        '''
        return subprocess.check_output(["osascript", "-e", src]).decode().strip()

    def clear_and_compute(broker, expected):
        reset_calc()
        # Re-prime Sky's session since our AppleScript keystrokes invalidated it
        broker.call("get_app_state", {"app": "com.apple.calculator"})
        rejections = 0
        def tap(k):
            nonlocal rejections
            r = broker.call("press_key", {"key": k, "app": "com.apple.calculator"})
            if "sky_rejected" in r: rejections += 1
            time.sleep(0.1)
        for ch in "25": tap(ch)
        tap("plus")
        for ch in "75": tap(ch)
        tap("Return")
        time.sleep(0.5)
        # Read input value from broker tree — robust to Calculator basic vs unit-conversion mode.
        state = broker.call("get_app_state", {"app": "com.apple.calculator"}).get("text", "")
        # Look for any "Value: 100" or "text ‎100" line — expected result always appears verbatim
        target = str(expected)
        ok = bool(re.search(r"(?:Value:\s*|text\s+)‎?\s*" + re.escape(target) + r"\b", state))
        # Also surface the raw display
        dav = display_via_ax().replace(",", "").replace("\u200e", "")
        return ok, f"tree-has-{target}={ok}  disp={dav!r}  (rejects={rejections})"

    sky_disp = clear_and_compute(sky, 100)
    mac_disp = clear_and_compute(mac, 100)
    return (sky_disp[0] and mac_disp[0]), f"sky={sky_disp[1]!r}  mac={mac_disp[1]!r}  expected=100"


def test_click_calculator(sky, mac):
    print("\n[click Calculator buttons]")
    subprocess.run(["open", "-a", "Calculator"])
    time.sleep(0.8)

    def compute_via_clicks(broker):
        st = broker.call("get_app_state", {"app": "com.apple.calculator"}).get("text", "")
        tree = parse_tree_by_index(st)
        def btn(descs):
            # descs: list of substrings; match a button desc that contains exactly one of them
            # Sky format: "button (settable, string) Description: 6" or "button 6"
            # mac format: "button Description: 6, ID: Six"
            for needle in descs:
                pattern = re.compile(r"button[^\n]*?(?:Description:\s*)?" + re.escape(needle) + r"\b")
                for idx, desc in tree.items():
                    if desc.lower().startswith("button") and re.search(r"\b" + re.escape(needle) + r"\b", desc):
                        return idx
            return None
        ac = btn(["All Clear", "Clear"])
        six = btn(["6"])
        seven = btn(["7"])
        plus = btn(["Add"])
        eq = btn(["Equals"])
        if ac is None or six is None or seven is None or plus is None or eq is None:
            return False, "missing buttons"
        def idx_arg(i): return str(i) if broker.name == "sky" else i
        broker.call("click", {"element_index": idx_arg(ac)})
        broker.call("click", {"element_index": idx_arg(six)})
        broker.call("click", {"element_index": idx_arg(plus)})
        broker.call("click", {"element_index": idx_arg(seven)})
        broker.call("click", {"element_index": idx_arg(eq)})
        time.sleep(0.3)
        st2 = broker.call("get_app_state", {"app": "com.apple.calculator"}).get("text", "")
        return "13" in st2, st2[:200]

    sky_ok, _ = compute_via_clicks(sky)
    mac_ok, _ = compute_via_clicks(mac)
    return (sky_ok and mac_ok), f"sky 6+7=13 via clicks={sky_ok}  mac={mac_ok}"


def test_set_value(sky, mac):
    """Set the value of TextEdit's text area directly via AX."""
    print("\n[set_value TextEdit text area]")
    subprocess.run(["pkill", "-9", "TextEdit"])
    time.sleep(1.0)
    unique = f"/tmp/setval-{int(time.time())}.txt"
    with open(unique, "w") as f: f.write("")
    subprocess.run(["open", "-a", "TextEdit", unique])
    time.sleep(1.5)
    subprocess.run(["osascript", "-e", 'tell application "TextEdit" to activate'])
    time.sleep(0.3)

    def run_with(broker, marker):
        state = broker.call("get_app_state", {"app": "com.apple.TextEdit"}).get("text", "")
        tree = parse_tree_by_index(state)
        # Find the settable text entry area — both brokers show "(settable, string)"
        ta_idx = None
        for idx, desc in tree.items():
            low = desc.lower()
            if "settable, string" in low and ("text entry area" in low or "text area" in low):
                ta_idx = idx; break
        if ta_idx is None:
            # fallback
            ta_idx, _ = find_by(tree, lambda d: "text entry area" in d.lower() or "text area" in d.lower())
        if ta_idx is None:
            return None, "no text area found"
        idx_arg = str(ta_idx) if broker.name == "sky" else ta_idx
        r = broker.call("set_value", {"element_index": idx_arg, "value": marker, "app": "com.apple.TextEdit"})
        time.sleep(0.4)
        val = read_ax_value("com.apple.TextEdit", "value of text area 1 of scroll area 1 of window 1")
        return val, r

    sky_val, sky_r = run_with(sky, "SET_BY_SKY")
    # Close the SAVE ANYWAY / Revert dialog if it appeared
    subprocess.run(["osascript", "-e",
        'tell application "System Events" to tell process "TextEdit" to key code 53'], capture_output=True)
    time.sleep(0.3)
    mac_val, mac_r = run_with(mac, "SET_BY_MAC")
    sky_ok = "SET_BY_SKY" in (sky_val or "")
    mac_ok = "SET_BY_MAC" in (mac_val or "")
    if not sky_ok: print(f"  debug sky r={sky_r}")
    return (sky_ok and mac_ok), f"sky={sky_val!r}  mac={mac_val!r}"


def test_perform_secondary_action(sky, mac):
    """Raise a Calculator window from within Calculator (same app). Easier than cross-app."""
    print("\n[perform_secondary_action Raise]")
    subprocess.run(["open", "-a", "Calculator"])
    time.sleep(0.8)

    def run_with(broker):
        state = broker.call("get_app_state", {"app": "com.apple.calculator"}).get("text", "")
        tree = parse_tree_by_index(state)
        win_idx, win_desc = find_by(tree, lambda d: "standard window" in d.lower())
        if win_idx is None:
            return False, "no window"
        idx_arg = str(win_idx) if broker.name == "sky" else win_idx
        r = broker.call("perform_secondary_action", {"element_index": idx_arg, "action": "Raise", "app": "com.apple.calculator"})
        ok = "error" not in r and "sky_rejected" not in r
        return ok, r

    sky_ok, sky_r = run_with(sky)
    mac_ok, mac_r = run_with(mac)
    return (sky_ok and mac_ok), f"sky accepted={sky_ok} ({str(sky_r)[:80]})  mac accepted={mac_ok} ({str(mac_r)[:80]})"


def test_drag(sky, mac):
    """Drag a Finder item to see if coordinates arrive. Use a Notes window resize as a safer test."""
    print("\n[drag - verify event sequence is accepted]")
    # Without a safe draggable target, we just verify the call returns ok
    # Both brokers should accept the drag params without error
    def run_with(broker):
        r = broker.call("drag", {"from_x": 500, "from_y": 500, "to_x": 600, "to_y": 600, "app": "com.apple.calculator"})
        return "error" not in r and "sky_rejected" not in r
    sky_ok = run_with(sky)
    mac_ok = run_with(mac)
    return (sky_ok and mac_ok), f"sky accepted={sky_ok}  mac accepted={mac_ok}"


TESTS = [
    ("list_apps", test_list_apps),
    ("get_app_state", test_get_app_state),
    ("scroll_textedit", test_scroll_textedit),
    ("press_key", test_press_key),
    ("click_calculator", test_click_calculator),
    ("type_text", test_type_text),
    ("set_value", test_set_value),
    ("perform_secondary_action", test_perform_secondary_action),
    ("drag", test_drag),
]


if __name__ == "__main__":
    # Seed TextEdit content
    with open("/tmp/cua-scroll-test.txt", "w") as f:
        for i in range(500): f.write(f"Line {i:04d}\n")

    sky = Broker("sky", SKY)
    mac = Broker("mac", MAC)
    results = []
    try:
        for name, fn in TESTS:
            try:
                ok, detail = fn(sky, mac)
            except Exception as e:
                ok, detail = False, f"exception: {e}"
            results.append((name, ok, detail))
            print(f"  {okmark(ok)}  {detail}")
    finally:
        sky.close()
        mac.close()

    print("\n\033[1m=== summary ===\033[0m")
    for name, ok, detail in results:
        print(f"  {okmark(ok)}  {name}: {detail}")
    passed = sum(1 for _, ok, _ in results if ok)
    print(f"\n{passed}/{len(results)} passed")
    sys.exit(0 if passed == len(results) else 1)
