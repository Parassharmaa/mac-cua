"""Verify both brokers return a screenshot in get_app_state content[1]."""
import os, sys, subprocess, time, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from broker import SKY_CMD, MAC_CMD


def raw_content_items(cmd, app):
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    def rpc(m, params=None):
        msg = {"jsonrpc": "2.0", "id": 1, "method": m}
        if params: msg["params"] = params
        p.stdin.write((json.dumps(msg)+"\n").encode()); p.stdin.flush()
        return json.loads(p.stdout.readline())
    try:
        rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}})
        r = rpc("tools/call", {"name": "get_app_state", "arguments": {"app": app}})
        return r.get("result", {}).get("content", [])
    finally:
        p.stdin.close(); p.kill()


def summarize(items):
    out = []
    for it in items:
        t = it.get("type")
        if t == "text":
            out.append(f"text({len(it.get('text','') )}ch)")
        elif t == "image":
            out.append(f"image/{it.get('mimeType','?').split('/')[-1]}({len(it.get('data',''))}b64)")
        else:
            out.append(f"{t}?")
    return " + ".join(out)


def main():
    subprocess.run(["open", "-a", "Calculator"]); time.sleep(0.8)
    sky_items = raw_content_items(SKY_CMD, "com.apple.calculator")
    mac_items = raw_content_items(MAC_CMD, "com.apple.calculator")

    print(f"\n[get_app_state content shape]")
    print(f"  sky: {summarize(sky_items)}")
    print(f"  mac: {summarize(mac_items)}")

    sky_ok = any(it.get("type") == "image" for it in sky_items)
    mac_ok = any(it.get("type") == "image" for it in mac_items)
    print(f"\nsky includes screenshot: {sky_ok}")
    print(f"mac includes screenshot: {mac_ok}")
    return 0 if (sky_ok and mac_ok) else 1


if __name__ == "__main__":
    sys.exit(main())
