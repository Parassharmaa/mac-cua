"""Shared MCP broker subprocess client used by every harness test.

Paths resolve in this order (first match wins):
  1. CUA_MAC_CMD / CUA_SKY_CMD env vars (space-separated argv)
  2. Defaults computed relative to this file's repo checkout
     and the standard Codex install location.
"""
import json, os, shlex, subprocess, sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.dirname(_HERE)
_DEFAULT_MAC = [os.path.join(_REPO, ".build/release/cua-mcp")]
_DEFAULT_SKY = [sys.executable,
                os.path.expanduser("~/Documents/Codex/2026-04-17-open-the-chrome-app/sky_cua.py")]


def _env_argv(name, default):
    raw = os.environ.get(name)
    return shlex.split(raw) if raw else default


SKY_CMD = _env_argv("CUA_SKY_CMD", _DEFAULT_SKY)
MAC_CMD = _env_argv("CUA_MAC_CMD", _DEFAULT_MAC)


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
        result = r["result"]
        content = result.get("content", [])
        txt = content[0].get("text", "") if content else ""
        if result.get("isError"):
            return {"error": txt}
        if "Computer Use is not active" in txt or txt.startswith("The user changed"):
            return {"sky_rejected": txt}
        return {"text": txt} if content else {"raw": result}

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
