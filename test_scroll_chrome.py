#!/usr/bin/env python3
"""Verify Chrome scroll via mac-cua."""
import json, subprocess, time, sys, re

BIN = "/Users/paras/projects/mac-cua-mcp/.build/release/cua-mcp"


def front_app():
    return subprocess.check_output(
        ["osascript", "-e",
         'tell application "System Events" to get name of first application process whose frontmost is true']
    ).decode().strip()


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

    def close(self):
        self.p.stdin.close()
        try: self.p.wait(timeout=2)
        except: self.p.kill()


def extract_visible_text(state, start_marker="HTML content"):
    """Only keep text extracted from within the HTML content subtree."""
    out = []
    in_html = False
    for line in state.splitlines():
        if start_marker in line:
            in_html = True
            continue
        if not in_html: continue
        if line and not line.startswith(("\t", " ")): break  # left subtree
        m = re.search(r"(?:Value|Description):\s*([^,]+)", line)
        if m:
            t = m.group(1).strip()
            if 10 < len(t) < 120 and "ScrollToVisible" not in t:
                out.append(t)
    return out[:40]


def html_content_index(state):
    for line in state.splitlines():
        m = re.match(r"\s*(\d+)\s+HTML content", line)
        if m: return int(m.group(1))
    return None


if __name__ == "__main__":
    before_front = front_app()
    print(f"front before: {before_front}")
    c = Client()
    try:
        state = c.call("get_app_state", app="com.google.Chrome")
        idx = html_content_index(state)
        before_text = extract_visible_text(state)
        print(f"HTML content idx={idx}, sample first-5 visible-text lines:")
        for t in before_text[:5]: print(f"    {t[:80]}")

        c.call("scroll", direction="down", pages=5, element_index=idx, app="com.google.Chrome")
        time.sleep(0.8)
        state2 = c.call("get_app_state", app="com.google.Chrome")
        after_text = extract_visible_text(state2)
        print("\nafter scroll down 5, sample first-5:")
        for t in after_text[:5]: print(f"    {t[:80]}")

        diff = sum(1 for a, b in zip(before_text[:20], after_text[:20]) if a != b)
        after_front = front_app()
        print(f"\ndiff lines:  {diff}/20")
        print(f"focus after: {after_front}")
        print(f"scroll moved? {'YES' if diff >= 3 else 'NO'}")
        print(f"focus kept?   {'YES' if before_front == after_front else 'NO'}")
    finally:
        c.close()
