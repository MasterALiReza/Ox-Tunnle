#!/usr/bin/env python3
"""
Ox Tunnle — High-Performance Reverse TCP Tunnel
https://github.com/MasterALiReza/Ox-Tunnle
"""
import os, sys, time, socket, struct, threading, subprocess, re, resource, signal, logging
from queue import Queue, Empty
from typing import Optional

# --------- Logging ----------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
import random

log = logging.getLogger("ox-tunnle")

# --------- Optional file logging (for tail -f in shell; FIX LIVE-LOG-BUG) ----------
_log_env = os.environ.get("OXTUNNEL_LOG", "")
if _log_env:
    try:
        _fh = logging.FileHandler(_log_env, mode="a", encoding="utf-8")
        _fh.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s",
                                           datefmt="%H:%M:%S"))
        log.addHandler(_fh)
    except Exception:
        pass

# --------- Tunables ----------
DIAL_TIMEOUT   = 5
KEEPALIVE_SECS = 20
SOCKBUF        = 8 * 1024 * 1024
BUF_COPY       = 256 * 1024
POOL_WAIT      = 5
SYNC_INTERVAL  = 3
MAX_SYNC_CONNS = 50   # FIX BUG-6: max concurrent sync connections

# --------- Graceful shutdown (FIX BUG-1) ----------
_stop_event = threading.Event()

def _handle_signal(sig, frame):
    log.info("Shutdown signal received, stopping gracefully...")
    _stop_event.set()

signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT,  _handle_signal)

# --------- Auto pool sizing ----------
def auto_pool_size(role: str = "ir") -> int:
    """Pick a safe default pool size based on process FD limit + RAM.

    Override with env var OXTUNNEL_POOL (positive int).
    Legacy env var PAHLAVI_POOL is also accepted for backward compatibility.
    """
    for env_key in ("OXTUNNEL_POOL", "PAHLAVI_POOL"):
        try:
            v = int(os.environ.get(env_key, "0"))
            if v > 0:
                return v
        except Exception:
            pass

    # File descriptor limit for this process
    try:
        soft, _ = resource.getrlimit(resource.RLIMIT_NOFILE)
        nofile = soft if soft and soft > 0 else 1024
    except Exception:
        nofile = 1024

    # Total RAM — Linux only, best-effort
    mem_mb = 0
    try:
        with open("/proc/meminfo", "r") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    mem_mb = int(line.split()[1]) // 1024
                    break
    except Exception:
        mem_mb = 0

    reserve  = 500
    fd_budget = max(0, nofile - reserve)
    frac      = 0.22 if role.lower().startswith("ir") else 0.30
    fd_based  = int(fd_budget * frac)
    ram_based = int((mem_mb / 1024) * 250) if mem_mb else 500
    pool      = min(fd_based, ram_based)

    if pool < 50:  pool = 50
    if pool > 400: pool = 400  # FIX CPU-SPIKE: was 2000; 400 is ample and avoids thundering-herd
    return pool


# --------- Socket helpers ----------

def is_socket_alive(s: socket.socket) -> bool:
    """Best-effort check to avoid using dead sockets from the pool.

    FIX BUG-3: removed unreachable `return True` and fixed exception
    handling — unknown exceptions now correctly return False (dead socket)
    instead of silently returning True.
    """
    try:
        s.setblocking(False)
        data = s.recv(1, socket.MSG_PEEK)
        if data == b"":
            return False   # Peer closed the connection cleanly
        return True
    except BlockingIOError:
        return True        # No data ready yet — socket is alive
    except Exception:
        return False       # Connection reset, broken pipe, etc.
    finally:
        try:
            s.setblocking(True)
        except Exception:
            pass


def tune_tcp(sock: socket.socket):
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except Exception:
        pass
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, SOCKBUF)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, SOCKBUF)
    except Exception:
        pass
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        if hasattr(socket, "TCP_KEEPIDLE"):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE,  KEEPALIVE_SECS)
        if hasattr(socket, "TCP_KEEPINTVL"):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, KEEPALIVE_SECS)
        if hasattr(socket, "TCP_KEEPCNT"):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)
    except Exception:
        pass


def dial_tcp(host, port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    tune_tcp(s)
    s.settimeout(DIAL_TIMEOUT)
    s.connect((host, port))
    s.settimeout(None)
    return s


def recv_exact(sock: socket.socket, n: int) -> Optional[bytes]:
    """Receive exactly n bytes or return None if the connection closes."""
    data = bytearray()
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            return None
        data.extend(chunk)
    return bytes(data)


def pipe(a: socket.socket, b: socket.socket):
    buf = bytearray(BUF_COPY)
    try:
        while True:
            n = a.recv_into(buf)
            if n <= 0:
                break
            b.sendall(memoryview(buf)[:n])
    except Exception:
        pass
    finally:
        try: a.shutdown(socket.SHUT_RD)
        except Exception: pass
        try: b.shutdown(socket.SHUT_WR)
        except Exception: pass


def bridge(a: socket.socket, b: socket.socket):
    t1 = threading.Thread(target=pipe, args=(a, b), daemon=True)
    t2 = threading.Thread(target=pipe, args=(b, a), daemon=True)
    t1.start(); t2.start()
    t1.join();  t2.join()
    try: a.close()
    except Exception: pass
    try: b.close()
    except Exception: pass


# --------- EU: detect listening TCP ports ----------

_port_re = re.compile(r":(\d+)$")


def _get_listen_ports_proc(exclude_bridge: int, exclude_sync: int) -> list:
    """Fallback: read /proc/net/tcp[6] when `ss` is unavailable."""
    ports: set = set()
    for fname in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(fname) as f:
                for line in f.readlines()[1:]:
                    parts = line.split()
                    if len(parts) < 4:
                        continue
                    if parts[3] != "0A":   # 0A = TCP_LISTEN
                        continue
                    port_hex = parts[1].split(":")[1]
                    p = int(port_hex, 16)
                    if p in (exclude_bridge, exclude_sync):
                        continue
                    if 1 <= p <= 65535:
                        ports.add(p)
        except Exception:
            pass
    return sorted(ports)


def get_listen_ports(exclude_bridge: int, exclude_sync: int) -> list:
    """Return sorted list of listening TCP ports on this machine.

    FIX BUG-5: replaced `bash -lc 'ss ... | awk ...'` with a direct
    subprocess call to `ss` (no login-shell overhead, runs every 3 s).
    Falls back to /proc/net/tcp when `ss` is not installed.
    """
    try:
        out = subprocess.check_output(
            ["ss", "-lntp"],
            stderr=subprocess.DEVNULL,
        ).decode(errors="replace")
    except FileNotFoundError:
        return _get_listen_ports_proc(exclude_bridge, exclude_sync)
    except Exception:
        return []

    ports: set = set()
    for ln in out.splitlines()[1:]:   # skip header row
        parts = ln.split()
        if len(parts) < 5:
            continue
        local_addr = parts[4]         # "0.0.0.0:8080" or "[::]:443"
        m = _port_re.search(local_addr)
        if not m:
            continue
        p = int(m.group(1))
        if p in (exclude_bridge, exclude_sync):
            continue
        if 1 <= p <= 65535:
            ports.add(p)
    return sorted(ports)


# --------- EU mode ----------

def eu_mode(iran_ip: str, bridge_port: int, sync_port: int, pool_size: int):

    def port_sync_loop():
        """FIX BUG-1,11: respects _stop_event; uses _stop_event.wait()
        instead of time.sleep() so shutdown is immediate; timeout aligned
        with SYNC_INTERVAL to avoid sendall racing with the next cycle."""
        while not _stop_event.is_set():
            try:
                c = dial_tcp(iran_ip, sync_port)
            except Exception:
                _stop_event.wait(SYNC_INTERVAL)
                continue
            try:
                while not _stop_event.is_set():
                    ports = get_listen_ports(bridge_port, sync_port)[:255]
                    payload = bytes([len(ports)]) + b"".join(
                        struct.pack("!H", p) for p in ports
                    )
                    c.settimeout(SYNC_INTERVAL - 0.5)   # FIX BUG-11: safe margin
                    c.sendall(payload)
                    c.settimeout(None)
                    _stop_event.wait(SYNC_INTERVAL)
            except Exception:
                try: c.close()
                except Exception: pass
                _stop_event.wait(SYNC_INTERVAL)

    def reverse_link_worker():
        """FIX BUG-1: checks _stop_event so threads exit cleanly on SIGTERM."""
        delay = 0.2
        while not _stop_event.is_set():
            try:
                conn = dial_tcp(iran_ip, bridge_port)
                hdr  = recv_exact(conn, 2)
                if not hdr:
                    conn.close()
                    delay = 0.2
                    continue
                (target_port,) = struct.unpack("!H", hdr)
                local = dial_tcp("127.0.0.1", target_port)
                bridge(conn, local)
                delay = 0.2
            except Exception:
                if not _stop_event.is_set():
                    _stop_event.wait(delay)
                    delay = min(delay * 2, 5.0)

    threading.Thread(target=port_sync_loop, daemon=True).start()

    # FIX THUNDERING-HERD: stagger thread startup so not all threads
    # try to connect simultaneously when the server first comes up.
    _stagger = min(2.0, pool_size * 0.005)  # spread over at most 2 seconds
    for i in range(pool_size):
        delay = random.uniform(0, _stagger)
        t = threading.Thread(target=reverse_link_worker, daemon=True)
        t.start()
        if delay > 0 and i < pool_size - 1:
            _stop_event.wait(timeout=delay / pool_size)
            if _stop_event.is_set():
                break

    log.info(f"[EU] Running | IRAN={iran_ip} bridge={bridge_port} sync={sync_port} pool={pool_size}")
    _stop_event.wait()
    log.info("[EU] Stopped.")


# --------- IR mode ----------

def ir_mode(bridge_port: int, sync_port: int, pool_size: int,
            auto_sync: bool, manual_ports_csv: str):

    pool       = Queue(maxsize=pool_size * 2)
    active     = {}
    active_lock = threading.Lock()
    _sync_sem  = threading.Semaphore(MAX_SYNC_CONNS)  # FIX BUG-6

    def accept_bridge():
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("0.0.0.0", bridge_port))
        srv.listen(16384)
        srv.settimeout(1.0)
        log.info(f"[IR] Bridge listening on {bridge_port}")
        while not _stop_event.is_set():
            try:
                c, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError as e:
                if not _stop_event.is_set():
                    log.error(f"[IR] Bridge accept error: {e}")
                    time.sleep(0.2)
                continue
            tune_tcp(c)
            try:
                pool.put(c, block=False)
            except Exception:
                try: c.close()
                except Exception: pass
        srv.close()

    def handle_user(user_sock: socket.socket, target_port: int):
        tune_tcp(user_sock)
        deadline = time.time() + POOL_WAIT
        europe   = None
        while time.time() < deadline:
            try:
                cand = pool.get(timeout=max(0.1, deadline - time.time()))
            except Empty:
                break
            if is_socket_alive(cand):
                europe = cand
                break
            try: cand.close()
            except Exception: pass
        if europe is None:
            try: user_sock.close()
            except Exception: pass
            return
        try:
            europe.settimeout(2)
            europe.sendall(struct.pack("!H", target_port))
            europe.settimeout(None)
        except Exception:
            try: user_sock.close()
            except Exception: pass
            try: europe.close()
            except Exception: pass
            return
        bridge(user_sock, europe)

    def open_port(p: int):
        """FIX BUG-2: use 'pending' state to prevent false-positive
        active flag when bind() fails after the lock is released."""
        with active_lock:
            if p in active:
                return
            active[p] = "pending"   # ← reservation, not yet confirmed

        try:
            srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind(("0.0.0.0", p))
            srv.listen(16384)
        except Exception as e:
            with active_lock:
                active.pop(p, None)
            log.error(f"[IR] Cannot open port {p}: {e}")
            return

        with active_lock:
            active[p] = True   # ← confirmed only after successful bind+listen

        log.info(f"[IR] Port Active: {p}")

        def accept_users():
            srv.settimeout(1.0)
            while not _stop_event.is_set():
                try:
                    u, _ = srv.accept()
                except socket.timeout:
                    continue
                except OSError as e:
                    if not _stop_event.is_set():
                        log.error(f"[IR] accept_users({p}) error: {e}")
                        time.sleep(0.2)
                    continue
                try:
                    threading.Thread(target=handle_user, args=(u, p), daemon=True).start()
                except Exception as e:
                    log.error(f"[IR] spawn thread error: {e}")
                    try: u.close()
                    except Exception: pass
            srv.close()

        threading.Thread(target=accept_users, daemon=True).start()

    def sync_listener():
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("0.0.0.0", sync_port))
        srv.listen(1024)
        srv.settimeout(1.0)
        log.info(f"[IR] Sync listening on {sync_port} (AutoSync)")

        while not _stop_event.is_set():
            try:
                c, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError as e:
                if not _stop_event.is_set():
                    log.error(f"[IR] Sync accept error: {e}")
                    time.sleep(0.2)
                continue

            def handle_sync(conn):
                """FIX BUG-6: Semaphore limits concurrent sync handlers."""
                with _sync_sem:
                    try:
                        while True:
                            h = recv_exact(conn, 1)
                            if not h:
                                break
                            count = h[0]
                            for _ in range(count):
                                pd = recv_exact(conn, 2)
                                if not pd:
                                    return
                                (p,) = struct.unpack("!H", pd)
                                open_port(p)
                    except Exception:
                        pass
                    finally:
                        try: conn.close()
                        except Exception: pass

            threading.Thread(target=handle_sync, args=(c,), daemon=True).start()
        srv.close()

    threading.Thread(target=accept_bridge, daemon=True).start()

    if auto_sync:
        threading.Thread(target=sync_listener, daemon=True).start()
    else:
        ports = []
        if manual_ports_csv.strip():
            for part in manual_ports_csv.split(","):
                part = part.strip()
                if not part:
                    continue
                try:
                    p = int(part)
                    if 1 <= p <= 65535:
                        ports.append(p)
                except Exception:
                    pass
        for p in ports:
            open_port(p)
        log.info("[IR] Manual ports opened.")

    log.info(f"[IR] Running | bridge={bridge_port} sync={sync_port} pool={pool_size} autoSync={auto_sync}")
    _stop_event.wait()
    log.info("[IR] Stopped.")


# --------- Input helpers ----------

def read_line(prompt: Optional[str] = None) -> str:
    if prompt:
        print(prompt, end="", flush=True)
    s = sys.stdin.readline()
    if not s:
        return ""
    return s.strip()


def validate_port(raw: str, default: int, name: str) -> int:
    """FIX BUG-7 (partial): parse and validate a single port value."""
    try:
        p = int(raw) if raw else default
    except ValueError:
        log.warning(f"Invalid {name} port '{raw}'. Using default {default}.")
        return default
    if not (1 <= p <= 65535):
        log.warning(f"{name} port {p} out of range 1–65535. Using default {default}.")
        return default
    return p


# --------- Entry point ----------

def main():
    choice = read_line()
    if choice not in ("1", "2"):
        print("Invalid mode selection.")
        sys.exit(1)

    if choice == "1":
        iran_ip = read_line()
        if not iran_ip:
            print("Error: Iran IP cannot be empty.")
            sys.exit(1)
        bridge = validate_port(read_line() or "7000", 7000, "bridge")
        sync   = validate_port(read_line() or "7001", 7001, "sync")

        # FIX BUG-7: reject identical ports before starting listeners
        if bridge == sync:
            print(f"Error: Bridge port and Sync port must be different (both are {bridge}).")
            sys.exit(1)

        pool = auto_pool_size("eu")
        try:
            nofile = resource.getrlimit(resource.RLIMIT_NOFILE)[0]
        except Exception:
            nofile = -1
        log.info(f"[AUTO] role=EU nofile={nofile} pool={pool} (override: OXTUNNEL_POOL)")
        eu_mode(iran_ip, bridge, sync, pool_size=pool)

    else:
        bridge = validate_port(read_line() or "7000", 7000, "bridge")
        sync   = validate_port(read_line() or "7001", 7001, "sync")

        # FIX BUG-7: reject identical ports before starting listeners
        if bridge == sync:
            print(f"Error: Bridge port and Sync port must be different (both are {bridge}).")
            sys.exit(1)

        yn = (read_line() or "y").lower()
        pool = auto_pool_size("ir")
        try:
            nofile = resource.getrlimit(resource.RLIMIT_NOFILE)[0]
        except Exception:
            nofile = -1
        log.info(f"[AUTO] role=IR nofile={nofile} pool={pool} (override: OXTUNNEL_POOL)")

        if yn == "y":
            ir_mode(bridge, sync, pool_size=pool, auto_sync=True,  manual_ports_csv="")
        else:
            ports = read_line()
            ir_mode(bridge, sync, pool_size=pool, auto_sync=False, manual_ports_csv=ports)


if __name__ == "__main__":
    main()
