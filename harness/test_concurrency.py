"""Two mac-cua brokers running simultaneously — verify element caches don't bleed.

Sky can't do this (single codex app-server socket), so this test is mac-only.
Simulates two agents driving the same Mac through two mac-cua processes.
"""
import subprocess, sys, time, threading
sys.path.insert(0, "/Users/paras/projects/mac-cua-mcp/harness")
from broker import Broker, MAC_CMD
from ax_util import parse_tree, find_by


def run_agent(agent_id, result_box):
    broker = Broker(f"mac-{agent_id}", MAC_CMD)
    try:
        # Each agent independently primes and clicks
        state = broker.call("get_app_state", {"app": "com.apple.calculator"}).get("text", "")
        tree = parse_tree(state)
        # Click a specific digit button. Agent 0 → 7, agent 1 → 3
        digit_desc = "Description: 7," if agent_id == 0 else "Description: 3,"
        btn_idx, _ = find_by(tree, lambda d: "button" in d.lower() and digit_desc in d)
        if btn_idx is None:
            result_box[agent_id] = f"agent {agent_id}: couldn't find digit button"
            return
        r = broker.call("click", {"element_index": btn_idx, "app": "com.apple.calculator"})
        result_box[agent_id] = f"agent {agent_id}: idx={btn_idx} click={('ok' if 'error' not in r else r.get('error',''))}"
    finally:
        broker.close()


def main():
    subprocess.run(["open", "-a", "Calculator"])
    time.sleep(0.8)
    # Clear
    subprocess.run(["osascript", "-e",
        'tell application "System Events" to tell process "Calculator" to key code 53'])
    time.sleep(0.3)

    results = [None, None]
    threads = [threading.Thread(target=run_agent, args=(i, results)) for i in range(2)]
    for t in threads: t.start()
    for t in threads: t.join(timeout=15)

    print(f"\n[two-agent concurrent click on Calculator]")
    for r in results: print(f"  {r}")
    ok = all(r is not None and "error" not in (r or "") and "couldn't" not in (r or "") for r in results)
    print(f"\n{'both agents succeeded' if ok else 'concurrent access broke something'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
