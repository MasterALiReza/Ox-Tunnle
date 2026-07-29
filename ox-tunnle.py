#!/usr/bin/env python3
"""
Ox Tunnle — High-Performance Reverse TCP Tunnel
https://github.com/MasterALiReza/Ox-Tunnle
"""
import os, sys, time, socket, struct, subprocess, re, signal, logging, hashlib, hmac, random, asyncio
try:
    import resource
except ImportError:
    resource = None
from typing import Optional, List, Set, Dict, Any, Tuple

# --------- Logging ----------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("ox-tunnle")

# --------- Optional uvloop acceleration ----------
try:
    import uvloop
    uvloop.install()
    log.info("[ENGINE] uvloop acceleration enabled.")
except ImportError:
    pass

# --------- Optional file logging (for tail -f in shell; FIX LIVE-LOG-BUG) ----------
_log_env = os.environ.get("OXTUNNEL_LOG", "")
if _log_env:
    try:
        from logging.handlers import RotatingFileHandler
        _fh = RotatingFileHandler(_log_env, maxBytes=10 * 1024 * 1024, backupCount=3, encoding="utf-8")
        _fh.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s",
                                           datefmt="%H:%M:%S"))
        log.addHandler(_fh)
    except Exception:
        pass

# --------- Tunables ----------
DIAL_TIMEOUT   = 5
KEEPALIVE_SECS = 20
SOCKBUF        = 8 * 1024 * 1024    # 8 MB standard socket buffer
BUF_COPY       = 64 * 1024           # 64 KB userspace buffer (optimized from 256KB to reduce RAM)
POOL_WAIT      = 5                   # 5 seconds pool wait
SYNC_INTERVAL  = 3
MAX_SYNC_CONNS = 50

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

    if pool < 100:  pool = 100
    if pool > 2000: pool = 2000
    return pool


# --------- Socket helpers & tuning ----------

def tune_tcp(sock: socket.socket):
    """Apply standard high-performance TCP socket options."""
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


def tune_writer(writer: asyncio.StreamWriter):
    try:
        sock = writer.get_extra_info("socket")
        if sock:
            tune_tcp(sock)
    except Exception:
        pass


def is_socket_alive_async(writer: asyncio.StreamWriter, reader: asyncio.StreamReader) -> bool:
    """Check if an asyncio connection in the pool is still alive and not closed by peer."""
    if writer.is_closing() or reader.at_eof():
        return False
    try:
        sock = writer.get_extra_info("socket")
        if sock is None:
            return True
        try:
            sock.setblocking(False)
            data = sock.recv(1, socket.MSG_PEEK)
            if data == b"":
                return False
            return True
        except (BlockingIOError, OSError) as e:
            if getattr(e, 'errno', None) in (errno.EAGAIN, errno.EWOULDBLOCK):
                return True
            # Any other socket error means dead
            return False
    except Exception:
        return True
    return True


def setup_signals(stop_event: asyncio.Event, loop: asyncio.AbstractEventLoop):
    def _shutdown(*_):
        log.info("Shutdown signal received, stopping gracefully...")
        loop.call_soon_threadsafe(stop_event.set)

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, _shutdown)
        except (NotImplementedError, RuntimeError, AttributeError, ValueError):
            try:
                signal.signal(sig, _shutdown)
            except Exception:
                pass


# --------- Security Authentication (SEC-01 / SEC-02) ----------

async def authenticate_client_async(reader: asyncio.StreamReader, writer: asyncio.StreamWriter, secret: str) -> bool:
    """Client side (EU): perform mutual HMAC-SHA256 Challenge-Response handshake on Bridge/Sync channels."""
    secret = (secret or "").strip().strip("'\"")
    try:
        if not secret:
            writer.write(b"\x00")
            await writer.drain()
            return True
        # Send flag 0x02 + 16-byte client nonce
        nonce_c = os.urandom(16)
        writer.write(b"\x02" + nonce_c)
        await writer.drain()

        # Receive 16-byte server nonce + 32-byte server HMAC (48 bytes total)
        resp = await asyncio.wait_for(reader.readexactly(48), timeout=10.0)
        nonce_s, server_mac = resp[:16], resp[16:]
        expected_server_mac = hmac.new(secret.encode("utf-8"), nonce_c + nonce_s, hashlib.sha256).digest()
        if not hmac.compare_digest(server_mac, expected_server_mac):
            log.warning("[SECURITY] Server HMAC verification failed (MITM or incorrect secret).")
            return False

        # Send client HMAC response to complete mutual authentication
        client_mac = hmac.new(secret.encode("utf-8"), nonce_s + nonce_c, hashlib.sha256).digest()
        writer.write(client_mac)
        await writer.drain()
        return True
    except (asyncio.TimeoutError, asyncio.IncompleteReadError, ConnectionError):
        return False
    except Exception:
        return False


async def authenticate_server_async(reader: asyncio.StreamReader, writer: asyncio.StreamWriter, expected_secret: str) -> bool:
    """Server side (IR): verify incoming connection with strict 10-second timeout against DoS & Scanners."""
    expected_secret = (expected_secret or "").strip().strip("'\"")
    try:
        async def _handshake():
            flag = await reader.readexactly(1)
            if not expected_secret:
                if flag == b"\x00":
                    return True
                if flag in (b"\x01", b"\x02"):
                    try:
                        if flag == b"\x01": await reader.readexactly(32)
                        elif flag == b"\x02":
                            await reader.readexactly(16)
                            writer.write(b"\x00" * 48)
                            await writer.drain()
                    except Exception: pass
                return False

            if flag == b"\x00":
                log.warning("[SECURITY] Connection dropped: unauthenticated client attempted connection.")
                return False
            elif flag == b"\x01":
                # Legacy static token hash compatibility
                client_hash = await reader.readexactly(32)
                expected_hash = hashlib.sha256(expected_secret.encode("utf-8")).digest()
                if not hmac.compare_digest(client_hash, expected_hash):
                    log.warning("[SECURITY] Connection dropped: invalid legacy static secret token.")
                    return False
                return True
            elif flag == b"\x02":
                # Mutual HMAC-SHA256 Challenge-Response protocol
                nonce_c = await reader.readexactly(16)
                nonce_s = os.urandom(16)
                server_mac = hmac.new(expected_secret.encode("utf-8"), nonce_c + nonce_s, hashlib.sha256).digest()
                writer.write(nonce_s + server_mac)
                await writer.drain()

                client_mac = await reader.readexactly(32)
                expected_client_mac = hmac.new(expected_secret.encode("utf-8"), nonce_s + nonce_c, hashlib.sha256).digest()
                if not hmac.compare_digest(client_mac, expected_client_mac):
                    log.warning("[SECURITY] Connection dropped: invalid HMAC challenge-response signature.")
                    return False
                return True
            else:
                log.warning("[SECURITY] Connection dropped: unknown authentication protocol flag.")
                return False

        return await asyncio.wait_for(_handshake(), timeout=10.0)
    except (asyncio.TimeoutError, asyncio.IncompleteReadError, ConnectionError):
        return False
    except Exception as e:
        return False


# --------- Async Data Piping and Bridging ----------

async def pipe_async(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    """High-efficiency asynchronous byte stream copying."""
    try:
        while not reader.at_eof():
            data = await reader.read(BUF_COPY)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (asyncio.CancelledError, ConnectionError, OSError):
        pass
    except Exception:
        pass
    finally:
        try:
            if not writer.is_closing():
                writer.close()
        except Exception:
            pass


async def bridge_async(reader_a: asyncio.StreamReader, writer_a: asyncio.StreamWriter,
                       reader_b: asyncio.StreamReader, writer_b: asyncio.StreamWriter):
    """Bridge two asynchronous TCP streams concurrently."""
    t1 = asyncio.create_task(pipe_async(reader_a, writer_b))
    t2 = asyncio.create_task(pipe_async(reader_b, writer_a))
    done, pending = await asyncio.wait([t1, t2], return_when=asyncio.FIRST_COMPLETED)
    for t in pending:
        t.cancel()
    for w in (writer_a, writer_b):
        try:
            if not w.is_closing():
                w.close()
        except Exception:
            pass


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


async def get_listen_ports_async(exclude_bridge: int, exclude_sync: int) -> list:
    """Return sorted list of listening TCP ports on this machine without blocking event loop."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "ss", "-lntp",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL
        )
        stdout, _ = await proc.communicate()
        out = stdout.decode(errors="replace")
    except FileNotFoundError:
        return _get_listen_ports_proc(exclude_bridge, exclude_sync)
    except Exception:
        return []

    ports: set = set()
    for ln in out.splitlines()[1:]:
        parts = ln.split()
        if len(parts) < 5:
            continue
        local_addr = parts[4]
        m = _port_re.search(local_addr)
        if not m:
            continue
        p = int(m.group(1))
        if p in (exclude_bridge, exclude_sync):
            continue
        if 1 <= p <= 65535:
            ports.add(p)
    return sorted(ports)


# --------- EU mode (AsyncIO) ----------

async def eu_mode_async(iran_ip: str, bridge_port: int, sync_port: int, pool_size: int, secret: str = ""):
    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()
    setup_signals(stop_event, loop)

    worker_tasks = set()
    idle_workers = 0
    active_workers = 0
    desired_idle = pool_size
    max_workers = pool_size * 5
    last_conn_err_time = 0
    global_conn_error = False

    async def port_sync_loop():
        last_log_time = 0
        while not stop_event.is_set():
            try:
                reader, writer = await asyncio.open_connection(iran_ip, sync_port)
                tune_writer(writer)
                if not await authenticate_client_async(reader, writer, secret):
                    log.warning(f"[SYNC] Authentication FAILED with Iran server {iran_ip}:{sync_port} (Secret mismatch or MITM).")
                    writer.close()
                    await asyncio.sleep(SYNC_INTERVAL)
                    continue
                log.info(f"[SYNC] Connected & Authenticated with Iran server {iran_ip}:{sync_port}")
            except Exception as e:
                now = time.time()
                if now - last_log_time > 15:
                    log.warning(f"[SYNC] Cannot connect to Iran server {iran_ip}:{sync_port} -> {e}")
                    last_log_time = now
                await asyncio.sleep(SYNC_INTERVAL)
                continue

            try:
                while not stop_event.is_set():
                    ports = (await get_listen_ports_async(bridge_port, sync_port))[:255]
                    payload = bytes([len(ports)]) + b"".join(struct.pack("!H", p) for p in ports)
                    writer.write(payload)
                    await writer.drain()
                    try:
                        await asyncio.wait_for(stop_event.wait(), timeout=SYNC_INTERVAL)
                    except asyncio.TimeoutError:
                        pass
            except Exception as e:
                log.warning(f"[SYNC] AutoSync connection lost to {iran_ip}:{sync_port}: {e}")
                try: writer.close()
                except Exception: pass
                await asyncio.sleep(SYNC_INTERVAL)

    async def reverse_link_worker():
        nonlocal idle_workers, active_workers, last_conn_err_time, global_conn_error
        
        try:
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(iran_ip, bridge_port), timeout=10.0
            )
            tune_writer(writer)
            
            if not await authenticate_client_async(reader, writer, secret):
                now = time.time()
                if now - last_conn_err_time > 15:
                    log.warning(f"[EU-WORKER] Auth FAILED on bridge {iran_ip}:{bridge_port}")
                    last_conn_err_time = now
                writer.close()
                global_conn_error = True
                return

            global_conn_error = False
            idle_workers += 1
            try:
                # Wait for target port from IR server
                hdr = await reader.readexactly(2)
            finally:
                idle_workers -= 1

        except asyncio.IncompleteReadError:
            return
        except Exception as e:
            global_conn_error = True
            now = time.time()
            if now - last_conn_err_time > 15:
                log.warning(f"[EU-WORKER] Connection error to Iran bridge {iran_ip}:{bridge_port} -> {e}")
                last_conn_err_time = now
            return

        # Bridge active
        active_workers += 1
        
        try:
            (target_port,) = struct.unpack("!H", hdr)
            try:
                local_reader, local_writer = await asyncio.wait_for(
                    asyncio.open_connection("127.0.0.1", target_port), timeout=5.0
                )
            except Exception as e:
                log.warning(f"[EU-WORKER] Local target port {target_port} unreachable on EU server (127.0.0.1:{target_port}): {e}")
                try:
                    writer.write(b"\x01")
                    await asyncio.wait_for(writer.drain(), timeout=2.0)
                except Exception:
                    pass
                writer.close()
                return

            try:
                writer.write(b"\x00")
                await asyncio.wait_for(writer.drain(), timeout=2.0)
            except Exception:
                pass
                
            tune_writer(local_writer)
            await bridge_async(reader, writer, local_reader, local_writer)
        except Exception:
            pass
        finally:
            active_workers -= 1
            try: writer.close()
            except Exception: pass

    async def pool_manager():
        while not stop_event.is_set():
            if global_conn_error and idle_workers > 5:
                await asyncio.sleep(1.0)
                
            total = idle_workers + active_workers
            if idle_workers < desired_idle and total < max_workers:
                to_spawn = min(desired_idle - idle_workers, max_workers - total)
                batch_size = 25 if idle_workers < 20 else 10
                batch = min(to_spawn, batch_size)
                for _ in range(batch):
                    task = asyncio.create_task(reverse_link_worker())
                    worker_tasks.add(task)
                    task.add_done_callback(worker_tasks.discard)
            
            await asyncio.sleep(0.05 if idle_workers < 10 else 0.2)

    sync_task = asyncio.create_task(port_sync_loop())
    manager_task = asyncio.create_task(pool_manager())

    log.info(f"[EU] Running (AsyncIO Engine) | IRAN={iran_ip} bridge={bridge_port} sync={sync_port} pool={pool_size} (Max {max_workers})")
    await stop_event.wait()
    log.info("[EU] Stopping tasks gracefully...")
    sync_task.cancel()
    manager_task.cancel()
    for t in list(worker_tasks):
        t.cancel()
    await asyncio.gather(sync_task, manager_task, *worker_tasks, return_exceptions=True)
    log.info("[EU] Stopped.")


def eu_mode(iran_ip: str, bridge_port: int, sync_port: int, pool_size: int, secret: str = ""):
    try:
        asyncio.run(eu_mode_async(iran_ip, bridge_port, sync_port, pool_size, secret))
    except (KeyboardInterrupt, SystemExit):
        log.info("[EU] Terminated.")


# --------- IR mode (AsyncIO) ----------

async def ir_mode_async(bridge_port: int, sync_port: int, pool_size: int,
                        auto_sync: bool, manual_ports_csv: str, secret: str = ""):
    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()
    setup_signals(stop_event, loop)

    pool = asyncio.LifoQueue(maxsize=pool_size * 2)
    active_servers: Dict[int, Any] = {}
    sync_sem = asyncio.Semaphore(MAX_SYNC_CONNS)

    async def handle_bridge_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        tune_writer(writer)
        peer = writer.get_extra_info("peername")
        peer_str = f"{peer[0]}:{peer[1]}" if peer else "unknown"
        if await authenticate_server_async(reader, writer, secret):
            if pool.full():
                log.warning(f"[IR-BRIDGE] Connection from {peer_str} dropped: Pool is FULL ({pool.maxsize} connections).")
                writer.close()
                return
            try:
                pool.put_nowait((reader, writer))
            except Exception as e:
                log.warning(f"[IR-BRIDGE] Failed to put worker from {peer_str} into pool: {e}")
                writer.close()
        else:
            log.warning(f"[IR-BRIDGE] Auth FAILED for incoming bridge connection from {peer_str}")
            writer.close()

    async def handle_user_client(user_reader: asyncio.StreamReader, user_writer: asyncio.StreamWriter, target_port: int):
        tune_writer(user_writer)
        deadline = time.time() + POOL_WAIT
        europe: Optional[Tuple[asyncio.StreamReader, asyncio.StreamWriter]] = None
        while time.time() < deadline:
            try:
                rem_time = max(0.05, deadline - time.time())
                cand_r, cand_w = await asyncio.wait_for(pool.get(), timeout=rem_time)
            except (asyncio.TimeoutError, asyncio.QueueEmpty):
                break

            if is_socket_alive_async(cand_w, cand_r):
                europe = (cand_r, cand_w)
                break
            try:
                cand_w.close()
            except Exception:
                pass

        if europe is None:
            log.warning(f"[IR-TRAFFIC] Connection for port {target_port} FAILED: No EU bridge worker available in pool (Pool empty / Timeout).")
            try: user_writer.close()
            except Exception: pass
            return

        eu_reader, eu_writer = europe
        try:
            eu_writer.write(struct.pack("!H", target_port))
            await asyncio.wait_for(eu_writer.drain(), timeout=5.0)
            
            status = await asyncio.wait_for(eu_reader.readexactly(1), timeout=5.0)
            if status != b"\x00":
                log.warning(f"[IR-TRAFFIC] EU worker rejected connection for port {target_port} (Local service not running on EU).")
                try: user_writer.close()
                except Exception: pass
                try: eu_writer.close()
                except Exception: pass
                return
                
        except Exception as e:
            log.warning(f"[IR-TRAFFIC] Failed sending target port {target_port} header to EU worker (or timeout): {e}")
            try: user_writer.close()
            except Exception: pass
            try: eu_writer.close()
            except Exception: pass
            return

        await bridge_async(user_reader, user_writer, eu_reader, eu_writer)

    def create_user_handler(target_port: int):
        async def _cb(r: asyncio.StreamReader, w: asyncio.StreamWriter):
            await handle_user_client(r, w, target_port)
        return _cb

    async def open_port(p: int):
        if p in active_servers:
            return
        active_servers[p] = "pending"
        try:
            srv = await asyncio.start_server(
                create_user_handler(p),
                "0.0.0.0", p,
                backlog=16384
            )
            active_servers[p] = srv
            log.info(f"[IR] Port Active: {p}")
            asyncio.create_task(srv.serve_forever())
        except Exception as e:
            active_servers.pop(p, None)
            log.error(f"[IR] Cannot open port {p}: {e}")

    async def prune_inactive_ports(synced_ports: set):
        to_close = [p for p, srv in active_servers.items() if p not in synced_ports and srv != "pending"]
        for p in to_close:
            srv = active_servers.pop(p, None)
            log.info(f"[IR] Pruning inactive port {p}")
            try:
                if hasattr(srv, "close"):
                    srv.close()
                    await srv.wait_closed()
            except Exception:
                pass

    async def handle_sync_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        peer = writer.get_extra_info("peername")
        peer_str = f"{peer[0]}:{peer[1]}" if peer else "unknown"
        async with sync_sem:
            try:
                if not await authenticate_server_async(reader, writer, secret):
                    log.warning(f"[IR-SYNC] Auth FAILED for sync connection from {peer_str}")
                    writer.close()
                    return
                log.info(f"[IR-SYNC] EU client connected & authenticated for AutoSync from {peer_str}")
                while not stop_event.is_set():
                    try:
                        h = await asyncio.wait_for(reader.readexactly(1), timeout=KEEPALIVE_SECS * 2)
                    except (asyncio.TimeoutError, asyncio.IncompleteReadError):
                        break
                    if not h:
                        break
                    count = h[0]
                    current_ports = set()
                    for _ in range(count):
                        pd = await reader.readexactly(2)
                        (p,) = struct.unpack("!H", pd)
                        current_ports.add(p)
                    if auto_sync:
                        for p in current_ports:
                            await open_port(p)
                        await prune_inactive_ports(current_ports)
            except Exception:
                pass
            finally:
                try: writer.close()
                except Exception: pass

    try:
        bridge_srv = await asyncio.start_server(handle_bridge_client, "0.0.0.0", bridge_port, backlog=16384)
        log.info(f"[IR] Bridge listening on {bridge_port}")
    except Exception as e:
        log.error(f"[IR] Failed to bind bridge port {bridge_port}: {e}")
        return

    sync_srv = None
    try:
        sync_srv = await asyncio.start_server(handle_sync_client, "0.0.0.0", sync_port, backlog=1024)
        log.info(f"[IR] Sync listening on {sync_port} (AutoSync={auto_sync})")
    except Exception as e:
        log.error(f"[IR] Failed to bind sync port {sync_port}: {e}")
        bridge_srv.close()
        return

    if not auto_sync:
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
            await open_port(p)
        log.info(f"[IR] Manual ports opened: {ports}")

    log.info(f"[IR] Running (AsyncIO Engine) | bridge={bridge_port} sync={sync_port} pool={pool_size} autoSync={auto_sync}")
    await stop_event.wait()
    log.info("[IR] Stopping servers gracefully...")
    bridge_srv.close()
    await bridge_srv.wait_closed()
    if sync_srv:
        sync_srv.close()
        await sync_srv.wait_closed()
    for p, srv in list(active_servers.items()):
        if hasattr(srv, "close"):
            srv.close()
            try: await srv.wait_closed()
            except Exception: pass
    log.info("[IR] Stopped.")


def ir_mode(bridge_port: int, sync_port: int, pool_size: int,
            auto_sync: bool, manual_ports_csv: str, secret: str = ""):
    try:
        asyncio.run(ir_mode_async(bridge_port, sync_port, pool_size, auto_sync, manual_ports_csv, secret))
    except (KeyboardInterrupt, SystemExit):
        log.info("[IR] Terminated.")


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
    import argparse
    parser = argparse.ArgumentParser(description="Ox Tunnle — High-Performance Reverse TCP Tunnel")
    parser.add_argument("--role", "-r", choices=["eu", "ir", "1", "2"], help="Role: 'eu' (1) or 'ir' (2)")
    parser.add_argument("--iran-ip", "-i", help="Iran Server IP (required for EU role)")
    parser.add_argument("--bridge-port", "-b", type=int, default=7000, help="Bridge Port (default: 7000)")
    parser.add_argument("--sync-port", "-s", type=int, default=7001, help="Sync Port (default: 7001)")
    parser.add_argument("--auto-sync", "-a", action="store_true", default=True, help="Auto sync ports from IR (IR role)")
    parser.add_argument("--ports", "-p", default="", help="Manual ports CSV if auto-sync is disabled")
    parser.add_argument("--secret", default=os.environ.get("OXTUNNEL_SECRET", ""), help="Secret auth token")

    args, unknown = parser.parse_known_args()

    # If flags were provided via CLI
    if args.role:
        role = "1" if args.role in ("eu", "1") else "2"
        bridge = validate_port(str(args.bridge_port), 7000, "bridge")
        sync   = validate_port(str(args.sync_port), 7001, "sync")
        if bridge == sync:
            print(f"Error: Bridge port and Sync port must be different (both are {bridge}).")
            sys.exit(1)

        if role == "1":
            if not args.iran_ip:
                print("Error: --iran-ip is required for EU role.")
                sys.exit(1)
            pool = auto_pool_size("eu")
            log.info(f"[CLI] role=EU iran_ip={args.iran_ip} bridge={bridge} sync={sync} pool={pool}")
            eu_mode(args.iran_ip, bridge, sync, pool_size=pool, secret=args.secret)
        else:
            pool = auto_pool_size("ir")
            log.info(f"[CLI] role=IR bridge={bridge} sync={sync} pool={pool} autoSync={args.auto_sync}")
            ir_mode(bridge, sync, pool_size=pool, auto_sync=args.auto_sync, manual_ports_csv=args.ports, secret=args.secret)
        return

    # Check if parameters are provided via Environment variables (e.g., from systemd EnvironmentFile)
    role_env = os.environ.get("ROLE", "").lower()
    if not args.role and role_env in ("eu", "ir", "iran"):
        role_val = "ir" if role_env in ("ir", "iran") else "eu"
        secret_val = os.environ.get("SECRET") or os.environ.get("TOKEN") or os.environ.get("OXTUNNEL_SECRET", "")
        bridge = validate_port(os.environ.get("BRIDGE", "7000"), 7000, "bridge")
        sync = validate_port(os.environ.get("SYNC", "7001"), 7001, "sync")
        if bridge == sync:
            log.error(f"[ENV] Bridge port and Sync port must be different (both are {bridge}).")
            sys.exit(1)
        if role_val == "eu":
            iran_ip = os.environ.get("IRAN_IP", "")
            if not iran_ip:
                log.error("[ENV] ROLE=eu requires IRAN_IP environment variable.")
                sys.exit(1)
            pool = auto_pool_size("eu")
            log.info(f"[ENV] role=EU iran_ip={iran_ip} bridge={bridge} sync={sync} pool={pool}")
            eu_mode(iran_ip, bridge, sync, pool_size=pool, secret=secret_val)
        else:
            auto_sync_str = os.environ.get("AUTO_SYNC", "true").lower()
            auto_sync = (auto_sync_str == "true")
            manual_ports = os.environ.get("PORTS", "")
            pool = auto_pool_size("ir")
            log.info(f"[ENV] role=IR bridge={bridge} sync={sync} pool={pool} autoSync={auto_sync}")
            ir_mode(bridge, sync, pool_size=pool, auto_sync=auto_sync, manual_ports_csv=manual_ports, secret=secret_val)
        return

    # Fallback to stdin prompt / pipe mode (legacy compatibility)
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

        secret = os.environ.get("OXTUNNEL_SECRET", "")
        pool = auto_pool_size("eu")
        try:
            nofile = resource.getrlimit(resource.RLIMIT_NOFILE)[0]
        except Exception:
            nofile = -1
        log.info(f"[AUTO] role=EU nofile={nofile} pool={pool} (override: OXTUNNEL_POOL)")
        eu_mode(iran_ip, bridge, sync, pool_size=pool, secret=secret)

    else:
        bridge = validate_port(read_line() or "7000", 7000, "bridge")
        sync   = validate_port(read_line() or "7001", 7001, "sync")

        # FIX BUG-7: reject identical ports before starting listeners
        if bridge == sync:
            print(f"Error: Bridge port and Sync port must be different (both are {bridge}).")
            sys.exit(1)

        yn = (read_line() or "y").lower()
        secret = os.environ.get("OXTUNNEL_SECRET", "")
        pool = auto_pool_size("ir")
        try:
            nofile = resource.getrlimit(resource.RLIMIT_NOFILE)[0]
        except Exception:
            nofile = -1
        log.info(f"[AUTO] role=IR nofile={nofile} pool={pool} (override: OXTUNNEL_POOL)")

        if yn == "y":
            ir_mode(bridge, sync, pool_size=pool, auto_sync=True,  manual_ports_csv="", secret=secret)
        else:
            ports = read_line()
            ir_mode(bridge, sync, pool_size=pool, auto_sync=False, manual_ports_csv=ports, secret=secret)


if __name__ == "__main__":
    main()
