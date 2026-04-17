"""AX tree parsing and AppleScript helpers shared by tests."""
import re, subprocess

PROCESS_NAMES = {
    "com.apple.TextEdit": "TextEdit",
    "com.apple.calculator": "Calculator",
    "com.apple.Notes": "Notes",
    "com.apple.finder": "Finder",
    "com.google.Chrome": "Google Chrome",
    "com.apple.Safari": "Safari",
}


def front_app():
    return subprocess.check_output(
        ["osascript", "-e",
         'tell application "System Events" to get name of first application process whose frontmost is true']
    ).decode().strip()


def read_ax_value(bundle_id, path):
    proc = PROCESS_NAMES.get(bundle_id, bundle_id)
    src = f'''
    tell application "System Events"
      tell process "{proc}"
        try
          return {path}
        on error e
          return "ERROR:" & e
        end try
      end tell
    end tell
    '''
    return subprocess.check_output(["osascript", "-e", src]).decode().strip()


def parse_tree(state_text):
    """Returns dict of index -> raw description line."""
    tree = {}
    for line in state_text.splitlines():
        m = re.match(r"\s*(\d+)\s+(.+)", line)
        if m:
            tree[int(m.group(1))] = m.group(2)
    return tree


def find_by(tree, predicate):
    for idx, desc in tree.items():
        if predicate(desc): return idx, desc
    return None, None


def find_scroll_area(state):
    """Return index of first 'scroll area' element in the tree."""
    for line in state.splitlines():
        m = re.match(r"\s*(\d+)\s+scroll area", line)
        if m: return int(m.group(1))
    return None


def activate(bundle_id):
    proc = PROCESS_NAMES.get(bundle_id, bundle_id)
    subprocess.run(["osascript", "-e", f'tell application "{proc}" to activate'])


def quit_and_relaunch(bundle_id, arg=None):
    proc = PROCESS_NAMES.get(bundle_id, bundle_id)
    subprocess.run(["pkill", "-9", proc])
    import time
    time.sleep(1.0)
    cmd = ["open", "-a", proc]
    if arg: cmd.append(arg)
    subprocess.run(cmd)
    time.sleep(1.5)
