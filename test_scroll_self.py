#!/usr/bin/env python3
"""Self-eval mac-cua scroll: invoke the Swift binary directly, verify AX scrollbar shifts."""
import json, subprocess, time, sys, re

BIN = "/Users/paras/projects/mac-cua-mcp/.build/release/cua-mcp"


def front_app():
    return subprocess.check_output(
        ["osascript", "-e",
         'tell application "System Events" to get name of first application process whose frontmost is true']
    ).decode().strip()


def vbar_value_from_state(state):
    for line in state.splitlines():
        s = line.strip()
        if s.startswith(("scroll bar", "")) and "scroll bar" in s and "(disabled)" not in s:
            m = re.search(r"Value:\s*([-\d.]+)", s)
            if m:
                try: return float(m.group(1))
                except: continue
    return None


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


def find_scroll_area_index(state):
    for line in state.splitlines():
        m = re.match(r"\s*(\d+)\s+scroll area", line)
        if m: return int(m.group(1))
    return None


def run_test(bundle_id: str, label: str):
    print(f"\n\033[1m[{label}] {bundle_id}\033[0m")
    before_front = front_app()
    c = Client()
    try:
        state = c.call("get_app_state", app=bundle_id)
        idx = find_scroll_area_index(state)
        v0 = vbar_value_from_state(state)
        print(f"  scroll area index={idx}  vbar-before={v0}  front={before_front}")

        c.call("scroll", direction="down", pages=3, element_index=idx, app=bundle_id)
        time.sleep(0.3)
        state = c.call("get_app_state", app=bundle_id)
        v1 = vbar_value_from_state(state)
        f1 = front_app()
        print(f"  after down 3:  vbar={v1}  front={f1}  Δ={None if v1 is None or v0 is None else round(v1-v0, 4)}")

        c.call("scroll", direction="up", pages=2, element_index=idx, app=bundle_id)
        time.sleep(0.3)
        state = c.call("get_app_state", app=bundle_id)
        v2 = vbar_value_from_state(state)
        f2 = front_app()
        print(f"  after up 2:    vbar={v2}  front={f2}  Δ={None if v2 is None or v1 is None else round(v2-v1, 4)}")

        ok_down = (v0 is not None and v1 is not None and v1 > v0 + 0.01)
        ok_up = (v1 is not None and v2 is not None and v2 < v1 - 0.01)
        ok_focus = (before_front == f2)
        return ok_down, ok_up, ok_focus
    finally:
        c.close()


if __name__ == "__main__":
    # Fresh TextEdit file
    p = "/tmp/cua-scroll-test.txt"
    with open(p, "w") as f:
        for i in range(500): f.write(f"Line {i:04d}\n")
    subprocess.run(["open", "-a", "TextEdit", p]); time.sleep(1)

    d, u, foc = run_test("com.apple.TextEdit", "TextEdit")
    GREEN, RED, RESET = "\033[32m", "\033[31m", "\033[0m"
    yesno = lambda ok: f"{GREEN}YES{RESET}" if ok else f"{RED}NO{RESET}"
    print(f"\n  down moved?  {yesno(d)}")
    print(f"  up moved?    {yesno(u)}")
    print(f"  focus kept?  {yesno(foc)}")
    sys.exit(0 if (d and u and foc) else 1)
