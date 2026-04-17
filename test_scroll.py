#!/usr/bin/env python3
"""Self-evaluating scroll tests. Each test:
  1. Sets up a known state
  2. Calls mac-cua scroll
  3. Reads AX state back to assert the page actually moved."""

import json, subprocess, time, sys, os

BIN = "/Users/paras/projects/mac-cua-mcp/.build/release/cua-mcp"


class Client:
    def __init__(self):
        self.p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        self.id = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}})

    def rpc(self, method, params=None):
        self.id += 1
        msg = {"jsonrpc": "2.0", "id": self.id, "method": method}
        if params is not None: msg["params"] = params
        self.p.stdin.write((json.dumps(msg) + "\n").encode()); self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def call(self, name, **args):
        r = self.rpc("tools/call", {"name": name, "arguments": args})
        if "error" in r: raise RuntimeError(f"{name}: {r['error']['message']}")
        return r["result"]["content"][0]["text"]

    def state(self, app): return self.call("get_app_state", app=app)

    def close(self):
        self.p.stdin.close()
        try: self.p.wait(timeout=2)
        except: self.p.kill()


def front_app():
    out = subprocess.check_output(
        ["osascript", "-e", 'tell application "System Events" to get name of first application process whose frontmost is true']
    ).decode().strip()
    return out


def find_scroll_value(state_text):
    """Find a scrollbar value in the AX tree."""
    import re
    for line in state_text.splitlines():
        m = re.search(r"scroll bar.*Value:\s*([\d.]+)", line)
        if m:
            return float(m.group(1))
    return None


def find_positions(state_text):
    """Extract positions of elements (approximation: their index in the tree).
    If scroll happened, the set of visible elements at top of main area shifts."""
    lines = state_text.splitlines()
    return [l.strip()[:80] for l in lines if l.strip() and not l.lstrip().startswith(("App=", "Window:", "Selected:"))]


# ─── Test 1: TextEdit scroll via AXValue on scrollbar ───
def test_textedit():
    print("\n\033[1m[TEST 1] TextEdit scroll — verify via scrollbar AXValue\033[0m")

    # Write a long doc
    path = "/tmp/cua-scroll-test.txt"
    with open(path, "w") as f:
        for i in range(500):
            f.write(f"Line {i:04d} — this is test content for scroll verification\n")

    subprocess.run(["open", "-a", "TextEdit", path])
    time.sleep(1.2)

    before_front = front_app()
    print(f"  front before: {before_front}")

    c = Client()
    try:
        state = c.state("com.apple.TextEdit")
        v0 = find_scroll_value(state)
        print(f"  scrollbar value before: {v0}")

        # Find HTML content or scroll area index
        # Look for first scroll area in the tree
        scroll_idx = None
        for line in state.splitlines():
            if "scroll area" in line and "ID: Scroll" not in line:
                # extract leading digits
                import re
                m = re.match(r"\s*(\d+)\s+scroll area", line)
                if m:
                    scroll_idx = int(m.group(1))
                    break
        print(f"  scroll area index: {scroll_idx}")

        c.call("scroll", direction="down", pages=5, element_index=scroll_idx, app="com.apple.TextEdit")
        time.sleep(0.4)

        state2 = c.state("com.apple.TextEdit")
        v1 = find_scroll_value(state2)
        print(f"  scrollbar value after:  {v1}")

        after_front = front_app()
        print(f"  front after:  {after_front}")

        assert v0 is not None and v1 is not None, "Could not read scrollbar values"
        assert v1 > v0, f"Expected scrollbar to advance; {v0} -> {v1}"
        assert before_front == after_front, f"Focus stolen: {before_front} -> {after_front}"
        print("  \033[32mPASS\033[0m")
        return True
    except AssertionError as e:
        print(f"  \033[31mFAIL: {e}\033[0m")
        return False
    finally:
        c.close()


# ─── Test 2: Chrome scroll — verify via position change of a known element ───
def test_chrome():
    print("\n\033[1m[TEST 2] Chrome scroll — verify via AX tree content shift\033[0m")

    # Make sure Chrome has a scrollable page
    subprocess.run(["osascript", "-e",
        'tell application "Google Chrome" to set URL of active tab of front window to "https://en.wikipedia.org/wiki/Apple_Inc."'])
    time.sleep(3.5)

    before_front = front_app()
    print(f"  front before: {before_front}")

    c = Client()
    try:
        # Get state, find HTML content
        state = c.state("com.google.Chrome")
        html_idx = None
        for line in state.splitlines():
            if "HTML content" in line:
                import re
                m = re.match(r"\s*(\d+)\s+HTML content", line)
                if m:
                    html_idx = int(m.group(1))
                    break
        print(f"  HTML content index: {html_idx}")

        before_content = find_positions(state)
        before_sample = [l for l in before_content if l.startswith(("10", "11", "12"))][:3]
        # snapshot first 20 text-containing lines
        before_first20 = [l for l in before_content if "Value:" in l or "Description:" in l][:20]

        c.call("scroll", direction="down", pages=8, element_index=html_idx, app="com.google.Chrome")
        time.sleep(0.6)

        state2 = c.state("com.google.Chrome")
        after_first20 = [l for l in find_positions(state2) if "Value:" in l or "Description:" in l][:20]

        diff = sum(1 for a, b in zip(before_first20, after_first20) if a != b)
        print(f"  first-20 AX lines differing after scroll: {diff}/20")

        after_front = front_app()
        print(f"  front after:  {after_front}")

        assert diff >= 3, f"AX tree didn't shift enough ({diff} lines changed); scroll may not have moved the page"
        # Focus may have flashed — acceptable if restored
        assert before_front == after_front, f"Focus not restored: {before_front} -> {after_front}"
        print("  \033[32mPASS\033[0m")
        return True
    except AssertionError as e:
        print(f"  \033[31mFAIL: {e}\033[0m")
        return False
    finally:
        c.close()


if __name__ == "__main__":
    results = []
    results.append(("textedit", test_textedit()))
    results.append(("chrome", test_chrome()))
    print("\n\033[1m=== summary ===\033[0m")
    for name, ok in results:
        mark = "\033[32mPASS\033[0m" if ok else "\033[31mFAIL\033[0m"
        print(f"  {mark}  {name}")
    sys.exit(0 if all(ok for _, ok in results) else 1)
