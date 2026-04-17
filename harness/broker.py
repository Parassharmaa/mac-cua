"""Shared MCP broker subprocess client used by every harness test."""
import json, subprocess

SKY_CMD = ["python3", "/Users/paras/Documents/Codex/2026-04-17-open-the-chrome-app/sky_cua.py"]
MAC_CMD = ["/Users/paras/projects/mac-cua-mcp/.build/release/cua-mcp"]


class Broker:
    def __init__(self, name, cmd):
        self.name = name
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        self.id = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "harness", "version": "0"}})

    def rpc(self, method, params=None):
        self.id += 1
        msg = {"jsonrpc": "2.0", "id": self.id, "method": method}
        if params is not None: msg["params"] = params
        self.p.stdin.write((json.dumps(msg) + "\n").encode()); self.p.stdin.flush()
        line = self.p.stdout.readline()
        if not line:
            raise RuntimeError(f"[{self.name}] broker died")
        return json.loads(line)

    def call(self, tool, args=None):
        r = self.rpc("tools/call", {"name": tool, "arguments": args or {}})
        if "error" in r:
            return {"error": r["error"].get("message", str(r["error"]))}
        content = r["result"].get("content", [])
        if content:
            txt = content[0].get("text", "")
            if "Computer Use is not active" in txt or txt.startswith("The user changed"):
                return {"sky_rejected": txt}
            return {"text": txt}
        return {"raw": r["result"]}

    def index_arg(self, idx):
        """Sky expects string, mac expects int."""
        return str(idx) if self.name == "sky" else idx

    def close(self):
        try: self.p.stdin.close()
        except: pass
        try: self.p.wait(timeout=2)
        except: self.p.kill()


def make_brokers():
    return Broker("sky", SKY_CMD), Broker("mac", MAC_CMD)
