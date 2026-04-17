"""End-to-end test: create a new Notes note, type into it, verify via AX.

Exercises: get_app_state + click (to find & press New Note button) + type_text + set_value.
"""
import time, re, sys
sys.path.insert(0, "/Users/paras/projects/mac-cua-mcp/harness")
from broker import make_brokers
from ax_util import parse_tree, find_by, activate, read_ax_value


def find_new_note_button(tree):
    # "button Description: Create a note" or "button New Note"
    for idx, desc in tree.items():
        low = desc.lower()
        if "button" in low and ("new note" in low or "create a note" in low):
            return idx
    return None


def run_via(broker, marker):
    print(f"  [{broker.name}]")
    activate("com.apple.Notes")
    time.sleep(0.5)
    # Prime session
    state = broker.call("get_app_state", {"app": "com.apple.Notes"}).get("text", "")
    btn_idx = find_new_note_button(parse_tree(state))
    if btn_idx is None:
        return False, "no new-note button found"

    # Click to create new note
    broker.call("click", {"element_index": broker.index_arg(btn_idx), "app": "com.apple.Notes"})
    time.sleep(0.8)

    # Re-prime and type content
    broker.call("get_app_state", {"app": "com.apple.Notes"})
    broker.call("type_text", {"text": marker, "app": "com.apple.Notes"})
    time.sleep(0.6)

    # Verify via AX: read topmost text area content
    content = read_ax_value("com.apple.Notes",
                             "value of text area 1 of scroll area 1 of group 1 of splitter group 1 of window 1")
    if content.startswith("ERROR:"):
        # try alternate path
        content = read_ax_value("com.apple.Notes",
                                 "value of text area 1 of UI element 1 of scroll area 1 of window 1")
    present = marker in content
    return present, f"content head={content[:80]!r}"


def main():
    sky, mac = make_brokers()
    try:
        sky_ok, sky_detail = run_via(sky, "NOTE_FROM_SKY_XYZ123")
        mac_ok, mac_detail = run_via(mac, "NOTE_FROM_MAC_ABC456")
    finally:
        sky.close(); mac.close()
    print(f"\n  sky: {'PASS' if sky_ok else 'FAIL'}  {sky_detail}")
    print(f"  mac: {'PASS' if mac_ok else 'FAIL'}  {mac_detail}")
    return sky_ok and mac_ok


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
