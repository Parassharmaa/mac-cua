"""Run every harness test and report an aggregate scoreboard."""
import subprocess, sys, time, os

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = [
    ("core tools (9)",          "core_tools.py"),
    ("error contract (4)",      "test_error_contract.py"),
    ("press_key vocab (25)",    "test_press_key_vocab.py"),
    ("perf bench (4 apps)",     "test_perf.py"),
    ("input latency (2 ops)",   "test_input_latency.py"),
]

GREEN, RED, YELLOW, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"


def run_one(label, script):
    print(f"\n{YELLOW}▶ {label}{RESET}  ({script})")
    t0 = time.time()
    r = subprocess.run(["python3", "-u", os.path.join(HERE, script)], capture_output=True, text=True)
    dt = time.time() - t0
    tail = "\n".join(r.stdout.strip().splitlines()[-3:])
    ok = r.returncode == 0
    color = GREEN if ok else RED
    print(f"  {color}{'PASS' if ok else 'FAIL'}{RESET}  in {dt:.1f}s")
    print(f"  tail: {tail[:300]}")
    if not ok and r.stderr:
        print(f"  stderr: {r.stderr[-200:]}")
    return ok, dt


def main():
    # Clean up stragglers
    subprocess.run(["pkill", "-9", "-f", "harness"], capture_output=True)
    subprocess.run(["pkill", "-9", "-f", "sky_cua"], capture_output=True)
    subprocess.run(["pkill", "-9", "cua-mcp"], capture_output=True)
    time.sleep(1)

    results = []
    for label, script in TESTS:
        ok, dt = run_one(label, script)
        results.append((label, ok, dt))

    print(f"\n{'='*60}")
    print("SCOREBOARD")
    print("=" * 60)
    for label, ok, dt in results:
        mark = f"{GREEN}✓{RESET}" if ok else f"{RED}✗{RESET}"
        print(f"  {mark}  {label:<30}  {dt:>5.1f}s")
    total_pass = sum(1 for _, ok, _ in results if ok)
    total_time = sum(dt for _, _, dt in results)
    print(f"\n  {total_pass}/{len(results)} suites passed in {total_time:.1f}s")
    return 0 if total_pass == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
