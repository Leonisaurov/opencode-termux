#!/usr/bin/env python3
"""Run opencode-android under a real pty, capture output, kill after N sec.
Usage: pty-run.py <binary> <outfile> <seconds> [env K=V ...]
Returns: prints EXIT:<code> and <bytes> captured. Kills entire process group.
"""
import os, sys, time, signal

def main():
    binary = sys.argv[1]
    outfile = sys.argv[2]
    seconds = float(sys.argv[3])

    # Build env overrides
    env = dict(os.environ)
    for kv in sys.argv[4:]:
        k, _, v = kv.partition("=")
        env[k] = v

    pid, fd = pty_fork()
    if pid == 0:
        # child
        os.chdir(os.path.dirname(binary) or ".")
        os.setpgid(0, 0)
        os.execve(binary, [binary], env)
        os._exit(127)

    # parent (child already did setpgid(0,0) in its branch)
    start = time.time()
    total = 0
    with open(outfile, "wb") as f:
        while time.time() - start < seconds:
            try:
                import select
                r, _, _ = select.select([fd], [], [], 0.5)
                if fd in r:
                    data = os.read(fd, 65536)
                    if not data:
                        break
                    f.write(data)
                    total += len(data)
            except OSError:
                break
        # drain any remaining
        try:
            while True:
                import select
                r, _, _ = select.select([fd], [], [], 0)
                if fd not in r:
                    break
                data = os.read(fd, 65536)
                if not data:
                    break
                f.write(data)
                total += len(data)
        except OSError:
            pass

    elapsed = time.time() - start

    # Check if child already exited
    status = None
    try:
        wpid, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        status = -1

    if status is None:
        # still running -> kill whole group
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            _, status = os.waitpid(pid, 0)
        except ChildProcessError:
            status = -1
        result = "TIMEOUT_KILLED"
    else:
        result = f"EXITED_STATUS_{status}"

    # Report
    if os.WIFSIGNALED(status) if isinstance(status, int) and status >= 0 else False:
        sig = os.WTERMSIG(status)
        result = f"CRASH_SIGNAL_{sig}"
    elif os.WIFEXITED(status) if isinstance(status, int) and status >= 0 else False:
        result = f"EXITED_CODE_{os.WEXITSTATUS(status)}"

    print(f"RESULT: {result}")
    print(f"ELAPSED: {elapsed:.1f}s")
    print(f"BYTES: {total}")
    sys.stdout.flush()

def pty_fork():
    import pty
    pid, fd = pty.fork()
    return pid, fd

if __name__ == "__main__":
    main()
