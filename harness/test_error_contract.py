"""Probe error paths on both brokers and compare error text.

Target error strings (from reverse-engineering Sky's binary):
  - "Running application not found: <id>"
  - "Cannot set a value for an element that is not settable"
  - "<action> is not a valid secondary action for <element>"
  - "Invalid scroll direction: <dir>"
  - "Missing scroll direction"
  - "The element ID is no longer valid. Re-query the latest state with get_app_state..."
"""
import os, sys, time, re, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from broker import make_brokers


def probe(broker, tool, args, needle_regex):
    r = broker.call(tool, args)
    err = r.get("error") or r.get("sky_rejected") or ""
    match = bool(re.search(needle_regex, err, re.IGNORECASE))
    return match, err[:200]


def cases_for(broker):
    """Needles are regexes (case-insensitive) that should match BOTH brokers' error strings."""
    idx = broker.index_arg
    return [
        ("get_app_state",  {"app": "com.fake.does-not-exist"},                    r"not ?found"),
        ("click",          {"element_index": idx(99999), "app": "com.apple.TextEdit"}, r"invalid element|no longer valid"),
        ("set_value",      {"element_index": idx(0), "value": "x", "app": "com.apple.TextEdit"}, r"not settable"),
        ("scroll",         {"direction": "sideways", "app": "com.apple.TextEdit"}, r"scroll direction"),
    ]


def main():
    # Prime textedit
    subprocess.run(["open", "-a", "TextEdit"])
    time.sleep(1.0)

    sky, mac = make_brokers()
    # Prime both brokers for TextEdit (needed for most Sky calls to be active)
    sky.call("get_app_state", {"app": "com.apple.TextEdit"})
    mac.call("get_app_state", {"app": "com.apple.TextEdit"})

    print(f"\n{'case':<38} {'sky':<6} {'mac':<6}")
    print("─" * 58)
    all_ok = True
    try:
        sky_cases = cases_for(sky)
        mac_cases = cases_for(mac)
        for (s_tool, s_args, needle), (m_tool, m_args, _) in zip(sky_cases, mac_cases):
            s_ok, s_err = probe(sky, s_tool, s_args, needle)
            m_ok, m_err = probe(mac, m_tool, m_args, needle)
            tag = f"{s_tool}({list(s_args.values())[0]!r})"[:38]
            print(f"{tag:<38} {'OK' if s_ok else 'NO':<6} {'OK' if m_ok else 'NO':<6}  needle={needle!r}")
            if not s_ok: print(f"    sky err: {s_err!r}")
            if not m_ok: print(f"    mac err: {m_err!r}")
            all_ok = all_ok and s_ok and m_ok
    finally:
        sky.close(); mac.close()

    print(f"\n{'all error messages match contract' if all_ok else 'some errors diverge from contract'}")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
