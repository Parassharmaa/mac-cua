"""Multi-step agent-style workflow — chains 5 tool calls per broker and verifies each step."""
import subprocess, sys, time, re
sys.path.insert(0, "/Users/paras/projects/mac-cua-mcp/harness")
from broker import make_brokers
from ax_util import parse_tree, find_by


def read_calc_input(broker):
    """Pull the Calculator input display value from the broker tree (basic or unit-converter mode)."""
    state = broker.call("get_app_state", {"app": "com.apple.calculator"}).get("text", "")
    m = re.search(r"(?:Value:\s*|text\s+)‎?\s*([\d,\.]+)", state)
    return m.group(1).replace(",", "") if m else None


def run_workflow(broker):
    """
    Step 1: clear calc (AC)
    Step 2: press_key 9
    Step 3: press_key asterisk
    Step 4: press_key 9
    Step 5: press_key Return
    Verify: display contains 81 somewhere in tree
    """
    # Prime
    state = broker.call("get_app_state", {"app": "com.apple.calculator"}).get("text", "")
    tree = parse_tree(state)
    # Find AC / Clear button (Sky: "button Clear" or "button All Clear"; mac: "button Description: All Clear, ID: AllClear")
    ac_idx = None
    for idx, desc in tree.items():
        low = desc.lower()
        if "button" in low and ("all clear" in low or "clear," in low or "id: allclear" in low or low.strip().endswith("clear")):
            ac_idx = idx; break
    if ac_idx is None:
        return False, "no AC button"

    # Step 1: click AC
    r1 = broker.call("click", {"element_index": broker.index_arg(ac_idx), "app": "com.apple.calculator"})
    time.sleep(0.15)

    # Step 2-5: press keys with prime between each (Sky invalidates on state change)
    for key in ["9", "asterisk", "9", "Return"]:
        broker.call("get_app_state", {"app": "com.apple.calculator"})
        r = broker.call("press_key", {"key": key, "app": "com.apple.calculator"})
        time.sleep(0.1)
        if "error" in r or "sky_rejected" in r:
            return False, f"press_key {key} failed: {r.get('error') or r.get('sky_rejected','')[:60]}"

    time.sleep(0.3)
    # Verify
    state2 = broker.call("get_app_state", {"app": "com.apple.calculator"}).get("text", "")
    has_81 = bool(re.search(r"(?:Value:\s*|text\s+)‎?\s*81\b", state2))
    return has_81, f"tree-has-81={has_81}"


def main():
    subprocess.run(["open", "-a", "Calculator"]); time.sleep(0.8)
    sky, mac = make_brokers()
    try:
        print("\n[workflow: clear → 9 × 9 = → expect 81]")
        s_ok, s_detail = run_workflow(sky)
        print(f"  sky: {'PASS' if s_ok else 'FAIL'}  {s_detail}")
        m_ok, m_detail = run_workflow(mac)
        print(f"  mac: {'PASS' if m_ok else 'FAIL'}  {m_detail}")
        return 0 if (s_ok and m_ok) else 1
    finally:
        sky.close(); mac.close()


if __name__ == "__main__":
    sys.exit(main())
