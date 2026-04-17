"""Run every harness test and report an aggregate scoreboard. Writes REPORT.md."""
import subprocess, sys, time, os, datetime

HERE = os.path.dirname(os.path.abspath(__file__))
REPORT_PATH = os.path.join(HERE, "REPORT.md")
TESTS = [
    ("core tools (9)",          "core_tools.py"),
    ("error contract (4)",      "test_error_contract.py"),
    ("press_key vocab (25)",    "test_press_key_vocab.py"),
    ("perf bench (4 apps)",     "test_perf.py"),
    ("input latency (2 ops)",   "test_input_latency.py"),
    ("stability (100 calls)",   "test_stability.py"),
    ("concurrency (2 agents)",  "test_concurrency.py"),
    ("workflow (5-step calc)",  "test_workflow.py"),
]

GREEN, RED, YELLOW, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"


def run_one(label, script):
    print(f"\n{YELLOW}▶ {label}{RESET}  ({script})")
    t0 = time.time()
    r = subprocess.run(["python3", "-u", os.path.join(HERE, script)], capture_output=True, text=True)
    dt = time.time() - t0
    tail_raw = r.stdout.strip()
    tail = "\n".join(tail_raw.splitlines()[-3:])
    ok = r.returncode == 0
    color = GREEN if ok else RED
    print(f"  {color}{'PASS' if ok else 'FAIL'}{RESET}  in {dt:.1f}s")
    print(f"  tail: {tail[:300]}")
    if not ok and r.stderr:
        print(f"  stderr: {r.stderr[-200:]}")
    return ok, dt, tail_raw


def main():
    # Clean up stragglers
    subprocess.run(["pkill", "-9", "-f", "harness"], capture_output=True)
    subprocess.run(["pkill", "-9", "-f", "sky_cua"], capture_output=True)
    subprocess.run(["pkill", "-9", "cua-mcp"], capture_output=True)
    time.sleep(1)

    results = []
    for label, script in TESTS:
        ok, dt, tail = run_one(label, script)
        results.append((label, script, ok, dt, tail))

    print(f"\n{'='*60}")
    print("SCOREBOARD")
    print("=" * 60)
    for label, _, ok, dt, _ in results:
        mark = f"{GREEN}✓{RESET}" if ok else f"{RED}✗{RESET}"
        print(f"  {mark}  {label:<30}  {dt:>5.1f}s")
    total_pass = sum(1 for _, _, ok, _, _ in results if ok)
    total_time = sum(dt for _, _, _, dt, _ in results)
    print(f"\n  {total_pass}/{len(results)} suites passed in {total_time:.1f}s")

    write_report(results, total_pass, total_time)
    print(f"\nwrote {REPORT_PATH}")
    return 0 if total_pass == len(results) else 1


def write_report(results, total_pass, total_time):
    lines = []
    lines.append("# mac-cua-mcp harness report\n")
    lines.append(f"Generated: {datetime.datetime.now().isoformat(timespec='seconds')}\n\n")
    lines.append(f"**{total_pass}/{len(results)} suites passed** in {total_time:.1f}s\n\n")
    lines.append("| suite | status | duration |\n")
    lines.append("| --- | --- | --- |\n")
    for label, script, ok, dt, _ in results:
        mark = "✅ pass" if ok else "❌ fail"
        lines.append(f"| {label} ({script}) | {mark} | {dt:.1f}s |\n")
    lines.append("\n## Suite outputs\n\n")
    for label, script, ok, dt, tail in results:
        lines.append(f"### {label}\n\n```\n{tail[-1200:]}\n```\n\n")
    with open(REPORT_PATH, "w") as f:
        f.writelines(lines)


if __name__ == "__main__":
    sys.exit(main())
