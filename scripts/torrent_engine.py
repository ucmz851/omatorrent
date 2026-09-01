#!/usr/bin/env python3
"""
OmaTorrent Customizable Torrent Search Engine & qBittorrent Controller
Supports user-configurable indexers (Internet Archive, Linux Tracker, Torznab,
custom RSS feeds, and JSON APIs) stored in ~/.config/omarchy/omatorrent_indexers.json.
Provides 1-click magnet URI dispatching and real-time qBittorrent WebUI telemetry.
"""

import sys
import os
import re
import json
import time
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed

USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64; rv:125.0) Gecko/20100101 Firefox/125.0"
HEADERS = {
    "User-Agent": USER_AGENT,
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,application/json,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.5"
}
REQUEST_TIMEOUT = 3.5
MAX_INDEXER_RESPONSE_BYTES = 1 * 1024 * 1024  # 1 MB max per remote indexer query
MAX_QBIT_RESPONSE_BYTES = 2 * 1024 * 1024     # 2 MB max for local qBittorrent WebUI payload
MAX_CONF_FILE_BYTES = 64 * 1024               # 64 KB max for local config file read
MAX_OUTPUT_SEARCH_RESULTS = 50                # Cap search results to 50 items
MAX_QBIT_TORRENTS = 100                       # Cap active torrents list in qBittorrent

# Strict Serialized Output Ceilings (enforced before any stdout write)
MAX_SEARCH_STDOUT_BYTES = 256 * 1024          # 256 KB hard stdout ceiling for search results
MAX_QBIT_STDOUT_BYTES = 512 * 1024            # 512 KB hard stdout ceiling for qBittorrent status
MAX_ACTION_STDOUT_BYTES = 32 * 1024           # 32 KB hard stdout ceiling for actions / control
MAX_GENERIC_STDOUT_BYTES = 16 * 1024          # 16 KB hard stdout ceiling for errors / fallback

INDEXERS_CONFIG_DIR = os.path.expanduser("~/.config/omarchy")
INDEXERS_CONFIG_PATH = os.path.join(INDEXERS_CONFIG_DIR, "omatorrent_indexers.json")
FALLBACK_CONFIG_PATH = os.path.expanduser("~/.config/omatorrent/indexers.json")

DEFAULT_INDEXERS = [
    {
        "id": "archive_org",
        "name": "Internet Archive",
        "badge": "Archive",
        "enabled": True,
        "type": "archive_org",
        "url": "https://archive.org/advancedsearch.php",
        "desc": "Public domain media, open-source software, books, and Linux distribution ISOs"
    },
    {
        "id": "linuxtracker",
        "name": "LinuxTracker",
        "badge": "LNX",
        "enabled": True,
        "type": "rss",
        "url": "https://linuxtracker.org/rss.php",
        "desc": "Verified Linux and BSD distribution ISO release feeds"
    }
]

DEFAULT_DOWNLOAD_DIR = os.path.expanduser("~/Downloads")

DEFAULT_TRACKERS = [
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://tracker.bittor.pw:1337/announce",
    "udp://public.popcorn-tracker.org:6969/announce",
    "udp://tracker.dler.org:6969/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://open.demonii.com:1337/announce"
]

def read_bounded(resp, max_bytes):
    """
    Read response stream with a strict upper byte ceiling to prevent memory exhaustion.
    Raises ValueError if stream exceeds max_bytes.
    """
    chunk_size = 64 * 1024
    chunks = []
    total_bytes = 0
    while True:
        chunk = resp.read(chunk_size)
        if not chunk:
            break
        total_bytes += len(chunk)
        if total_bytes > max_bytes:
            raise ValueError(f"Response payload exceeded maximum allowed limit of {max_bytes} bytes")
        chunks.append(chunk)
    return b"".join(chunks)

def sanitize_str(val, max_len=256, default=""):
    if not val:
        return default
    s = str(val).strip()
    return s[:max_len]

def sanitize_hash(val):
    if not val:
        return ""
    s = re.sub(r"[^0-9a-fA-F]", "", str(val)).strip()
    return s[:64]

def sanitize_magnet(val, max_len=2048):
    if not val or not isinstance(val, str):
        return ""
    v = val.strip()
    if v.startswith("magnet:?") or v.startswith("https://") or v.startswith("http://"):
        return v[:max_len]
    return ""

def _write_stdout_bytes(b):
    if hasattr(sys.stdout, "buffer"):
        sys.stdout.buffer.write(b)
        sys.stdout.buffer.flush()
    else:
        sys.stdout.write(b.decode("utf-8", errors="ignore"))
        sys.stdout.flush()

def emit_bounded_json(payload, max_bytes=MAX_SEARCH_STDOUT_BYTES):
    """
    Serialize payload to compact JSON and enforce an absolute hard byte ceiling
    before writing to stdout. Guarantees the persistent desktop shell never
    receives an unbounded aggregate payload.
    """
    try:
        encoded = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        if len(encoded) <= max_bytes:
            _write_stdout_bytes(encoded)
            return

        # If payload exceeds ceiling, progressively prune list fields (results or torrents)
        if isinstance(payload, dict):
            for key in ["results", "torrents"]:
                if key in payload and isinstance(payload[key], list):
                    items = list(payload[key])
                    while items and len(encoded) > max_bytes:
                        items = items[:max(1, len(items) // 2)] if len(items) > 1 else []
                        payload[key] = items
                        if "total" in payload and key == "results":
                            payload["total"] = len(items)
                        encoded = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
                    if len(encoded) <= max_bytes:
                        _write_stdout_bytes(encoded)
                        return

        # If still exceeding, emit strict bounded fallback error
        fallback = json.dumps({
            "error": f"Output exceeded serialized ceiling of {max_bytes} bytes",
            "results": [],
            "torrents": []
        }, separators=(",", ":")).encode("utf-8")[:max_bytes]
        _write_stdout_bytes(fallback)
    except Exception as e:
        err_bytes = json.dumps({"error": f"Serialization error: {str(e)}"}).encode("utf-8")[:MAX_GENERIC_STDOUT_BYTES]
        _write_stdout_bytes(err_bytes)

def make_magnet(info_hash, name, trackers=None):
    clean_hash = sanitize_hash(info_hash)
    if not clean_hash:
        return ""
    clean_name = sanitize_str(name, max_len=200, default="Torrent")
    encoded_name = urllib.parse.quote(clean_name)
    tr_list = trackers or DEFAULT_TRACKERS
    tr_params = "&".join(f"tr={urllib.parse.quote(t)}" for t in tr_list[:8])
    uri = f"magnet:?xt=urn:btih:{clean_hash}&dn={encoded_name}&{tr_params}"
    return sanitize_magnet(uri, max_len=2048)

def format_bytes(size_bytes):
    try:
        size = float(size_bytes)
        if size <= 0:
            return "0 B"
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if size < 1024.0 or unit == 'TB':
                return f"{size:.2f} {unit}" if unit in ['GB', 'TB'] else f"{int(size)} {unit}"
            size /= 1024.0
    except Exception:
        pass
    return "0 B"

def format_speed(bps):
    try:
        val = float(bps)
        if val <= 0:
            return "0 B/s"
        for unit in ['B/s', 'KB/s', 'MB/s', 'GB/s']:
            if val < 1024.0 or unit == 'GB/s':
                return f"{val:.1f} {unit}"
            val /= 1024.0
    except Exception:
        pass
    return "0 B/s"

def format_eta(seconds):
    try:
        sec = int(seconds)
        if sec >= 8640000 or sec <= 0:
            return "∞"
        hours = sec // 3600
        minutes = (sec % 3600) // 60
        secs = sec % 60
        if hours > 0:
            return f"{hours}h {minutes}m"
        elif minutes > 0:
            return f"{minutes}m {secs}s"
        else:
            return f"{secs}s"
    except Exception:
        pass
    return "∞"

def parse_size_to_bytes(size_str):
    if not size_str:
        return 0
    size_str = size_str.strip().upper().replace(",", "")
    match = re.search(r'([\d\.]+)\s*([KMGT]?B?)', size_str)
    if not match:
        return 0
    val = float(match.group(1))
    unit = match.group(2)
    multipliers = {
        'B': 1,
        'KB': 1024,
        'K': 1024,
        'MB': 1024**2,
        'M': 1024**2,
        'GB': 1024**3,
        'G': 1024**3,
        'TB': 1024**4,
        'T': 1024**4
    }
    return int(val * multipliers.get(unit, 1024**2))

def fetch_url(url, as_json=False, as_xml=False, timeout=REQUEST_TIMEOUT, max_bytes=MAX_INDEXER_RESPONSE_BYTES):
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ["http", "https"]:
        raise ValueError(f"Unsupported URL scheme: {parsed.scheme}")
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        content = read_bounded(resp, max_bytes)
        if as_json:
            return json.loads(content.decode('utf-8', errors='ignore'))
        if as_xml:
            return ET.fromstring(content)
        return content.decode('utf-8', errors='ignore')

# -----------------------------------------------------------------------------
# User Indexers Configuration Manager (Enforces Strict 0600 Mode for API Keys)
# -----------------------------------------------------------------------------
def get_indexers_config_path():
    if os.path.exists(INDEXERS_CONFIG_PATH):
        return INDEXERS_CONFIG_PATH
    if os.path.exists(FALLBACK_CONFIG_PATH):
        return FALLBACK_CONFIG_PATH
    return INDEXERS_CONFIG_PATH

def enforce_private_file_mode(file_path):
    """
    Enforces mode 0600 (-rw-------) on the credential/indexer config file.
    Repairs any existing permissive permissions (e.g. 0644, 0664) to prevent
    local credential leakage of Torznab API keys.
    """
    try:
        if os.path.exists(file_path):
            st = os.stat(file_path)
            if (st.st_mode & 0o777) != 0o600:
                os.chmod(file_path, 0o600)
    except Exception:
        pass

def safe_write_private_json(file_path, data):
    """
    Creates or overwrites the JSON configuration file with strict 0600
    permissions (-rw-------), overriding any permissive process umask.
    """
    try:
        dir_path = os.path.dirname(file_path)
        if dir_path:
            os.makedirs(dir_path, exist_ok=True)
            if os.path.basename(dir_path) == "omatorrent":
                try:
                    os.chmod(dir_path, 0o700)
                except Exception:
                    pass

        payload = json.dumps(data, indent=2).encode("utf-8")
        
        # Open file descriptor with explicit 0600 mode
        fd = os.open(file_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            with open(fd, "wb", closefd=True) as f:
                f.write(payload)
        except Exception:
            try:
                os.close(fd)
            except Exception:
                pass
            return False

        # Explicit chmod ensures 0600 even if umask altered creation mode
        os.chmod(file_path, 0o600)
        return True
    except Exception:
        return False

def load_indexers_config():
    conf_file = get_indexers_config_path()
    if os.path.exists(conf_file):
        # Enforce and repair 0600 mode on existing configuration file
        enforce_private_file_mode(conf_file)
        try:
            if os.path.getsize(conf_file) <= MAX_CONF_FILE_BYTES:
                with open(conf_file, "r", encoding="utf-8", errors="ignore") as f:
                    data = json.loads(f.read(MAX_CONF_FILE_BYTES))
                    if isinstance(data, dict) and "indexers" in data and isinstance(data["indexers"], list):
                        clean_list = []
                        for idx in data["indexers"]:
                            if not isinstance(idx, dict):
                                continue
                            clean_list.append({
                                "id": sanitize_str(idx.get("id"), 50, default="custom"),
                                "name": sanitize_str(idx.get("name"), 80, default="Custom Indexer"),
                                "badge": sanitize_str(idx.get("badge"), 12, default="Custom"),
                                "enabled": bool(idx.get("enabled", True)),
                                "type": sanitize_str(idx.get("type"), 30, default="rss"),
                                "url": sanitize_str(idx.get("url"), 1024, default=""),
                                "apikey": sanitize_str(idx.get("apikey"), 256, default=""),
                                "desc": sanitize_str(idx.get("desc"), 200, default="")
                            })
                        return {"version": 1, "indexers": clean_list, "config_path": conf_file}
        except Exception:
            pass

    init_data = {
        "version": 1,
        "description": "User-configurable indexers for OmaTorrent. Add custom Torznab (Jackett/Prowlarr), RSS, or API endpoints.",
        "indexers": DEFAULT_INDEXERS
    }
    safe_write_private_json(conf_file, init_data)
    return {"version": 1, "indexers": DEFAULT_INDEXERS, "config_path": conf_file}

def save_indexers_config(config_dict):
    conf_file = get_indexers_config_path()
    return safe_write_private_json(conf_file, config_dict)

# -----------------------------------------------------------------------------
# qBittorrent WebUI API Engine
# -----------------------------------------------------------------------------
def find_qbittorrent_port(preferred_port=8080):
    ports_to_try = [preferred_port] if preferred_port else []
    try:
        conf_path = os.path.expanduser('~/.config/qBittorrent/qBittorrent.conf')
        if os.path.exists(conf_path) and os.path.getsize(conf_path) <= MAX_CONF_FILE_BYTES:
            with open(conf_path, 'r', encoding='utf-8', errors='ignore') as f:
                text = f.read(MAX_CONF_FILE_BYTES)
            m = re.search(r'WebUI[\\/:]Port=(\d+)', text)
            if m:
                p = int(m.group(1))
                if p not in ports_to_try:
                    ports_to_try.append(p)
    except Exception:
        pass

    common_ports = [8080, 8085, 9091, 8000, 8090, 8888, 6881, 8081]
    for cp in common_ports:
        if cp not in ports_to_try:
            ports_to_try.append(cp)

    for p in ports_to_try:
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{p}/api/v2/app/version")
            with urllib.request.urlopen(req, timeout=0.35) as resp:
                _ = read_bounded(resp, 1024)
                return p
        except Exception:
            continue
    return preferred_port or 8080

def get_qbittorrent_data(host="127.0.0.1", port=8080):
    actual_port = port or 8080
    base_url = f"http://{host}:{actual_port}/api/v2"
    try:
        ver_req = urllib.request.Request(f"{base_url}/app/version")
        with urllib.request.urlopen(ver_req, timeout=1.2) as resp:
            version = read_bounded(resp, 1024).decode('utf-8', errors='ignore').strip()
    except Exception:
        # Probe other ports if preferred port failed
        found_port = find_qbittorrent_port(actual_port)
        if found_port != actual_port:
            actual_port = found_port
            base_url = f"http://{host}:{actual_port}/api/v2"
            try:
                ver_req = urllib.request.Request(f"{base_url}/app/version")
                with urllib.request.urlopen(ver_req, timeout=1.2) as resp:
                    version = read_bounded(resp, 1024).decode('utf-8', errors='ignore').strip()
            except Exception as e:
                return {
                    "status": "disconnected",
                    "port": actual_port,
                    "error": str(e),
                    "global": {"dl_speed": 0, "dl_speed_str": "0 B/s", "up_speed": 0, "up_speed_str": "0 B/s", "active_downloads": 0, "active_uploads": 0, "total_torrents": 0},
                    "torrents": []
                }
        else:
            return {
                "status": "disconnected",
                "port": actual_port,
                "error": "Connection refused",
                "global": {"dl_speed": 0, "dl_speed_str": "0 B/s", "up_speed": 0, "up_speed_str": "0 B/s", "active_downloads": 0, "active_uploads": 0, "total_torrents": 0},
                "torrents": []
            }

    try:
        transfer_req = urllib.request.Request(f"{base_url}/transfer/info")
        global_info = {}
        with urllib.request.urlopen(transfer_req, timeout=1.2) as resp:
            global_info = json.loads(read_bounded(resp, MAX_QBIT_RESPONSE_BYTES).decode('utf-8', errors='ignore'))

        # Fetch preferences for save_path, global limits, alt speed
        prefs = {}
        try:
            prefs_req = urllib.request.Request(f"{base_url}/app/preferences")
            with urllib.request.urlopen(prefs_req, timeout=1.2) as resp:
                prefs = json.loads(read_bounded(resp, MAX_QBIT_RESPONSE_BYTES).decode('utf-8', errors='ignore'))
        except Exception:
            pass

        # Fetch speedLimitsMode
        alt_mode = False
        try:
            mode_req = urllib.request.Request(f"{base_url}/transfer/speedLimitsMode")
            with urllib.request.urlopen(mode_req, timeout=1.0) as resp:
                alt_mode = (read_bounded(resp, 1024).decode('utf-8', errors='ignore').strip() == "1")
        except Exception:
            pass

        torrents_req = urllib.request.Request(f"{base_url}/torrents/info?filter=all")
        torrents_raw = []
        with urllib.request.urlopen(torrents_req, timeout=1.5) as resp:
            torrents_raw = json.loads(read_bounded(resp, MAX_QBIT_RESPONSE_BYTES).decode('utf-8', errors='ignore'))

        torrents_list = []
        active_downloads = 0
        active_uploads = 0

        for t in torrents_raw[:MAX_QBIT_TORRENTS]:
            state = t.get("state", "unknown")
            if "downloading" in state.lower() or "stalleddl" in state.lower():
                active_downloads += 1
            if "uploading" in state.lower() or "stalledup" in state.lower():
                active_uploads += 1

            progress = float(t.get("progress", 0.0))
            progress_pct = round(progress * 100, 1)
            total_size = int(t.get("total_size", t.get("size", 0)))
            completed_bytes = int(t.get("completed", total_size * progress))
            dlspeed = int(t.get("dlspeed", 0))
            upspeed = int(t.get("upspeed", 0))
            eta_sec = int(t.get("eta", 8640000))
            t_dl_limit = int(t.get("dl_limit", 0))
            t_up_limit = int(t.get("up_limit", 0))
            ratio = round(float(t.get("ratio", 0.0)), 2)
            forced = bool(t.get("force_start", False))

            state_label = "Downloading"
            if state in ["pausedDL", "pausedUP", "stoppedDL", "stoppedUP"]:
                state_label = "Paused"
            elif state in ["uploading", "stalledUP"]:
                state_label = "Seeding"
            elif state in ["stalledDL"]:
                state_label = "Stalled DL"
            elif state in ["queuedDL", "queuedUP"]:
                state_label = "Queued"
            elif state in ["checkingDL", "checkingUP"]:
                state_label = "Checking"
            elif state in ["error", "missingFiles"]:
                state_label = "Error"
            elif progress >= 1.0:
                state_label = "Completed"

            torrents_list.append({
                "hash": sanitize_hash(t.get("hash", "")),
                "name": sanitize_str(t.get("name", "Unknown Torrent"), 200),
                "size_bytes": total_size,
                "size_str": format_bytes(total_size),
                "completed_bytes": completed_bytes,
                "completed_str": format_bytes(completed_bytes),
                "progress": progress,
                "progress_pct": progress_pct,
                "dlspeed": dlspeed,
                "dlspeed_str": format_speed(dlspeed),
                "upspeed": upspeed,
                "upspeed_str": format_speed(upspeed),
                "eta_str": format_eta(eta_sec),
                "state": sanitize_str(state, 50),
                "state_label": sanitize_str(state_label, 50),
                "seeds": max(0, min(1000000, int(t.get("num_seeds", 0)))),
                "peers": max(0, min(1000000, int(t.get("num_leechs", 0)))),
                "category": sanitize_str(t.get("category", "") or "General", 50),
                "save_path": sanitize_str(t.get("save_path", ""), 250),
                "content_path": sanitize_str(t.get("content_path", t.get("save_path", "")), 250),
                "dl_limit": t_dl_limit,
                "dl_limit_str": format_speed(t_dl_limit) if t_dl_limit > 0 else "Unlimited",
                "up_limit": t_up_limit,
                "up_limit_str": format_speed(t_up_limit) if t_up_limit > 0 else "Unlimited",
                "ratio": ratio,
                "forced": forced,
                "added_on": int(t.get("added_on", 0))
            })

        torrents_list.sort(key=lambda x: (x["state_label"] != "Downloading", -x["dlspeed"], -x["progress"]))

        dl_speed_global = int(global_info.get("dl_info_speed", 0))
        up_speed_global = int(global_info.get("up_info_speed", 0))
        global_dl_limit = int(prefs.get("dl_limit", 0))
        global_up_limit = int(prefs.get("up_limit", 0))
        save_path = prefs.get("save_path", DEFAULT_DOWNLOAD_DIR)
        alt_dl_limit = int(prefs.get("alt_dl_limit", 10240))
        alt_up_limit = int(prefs.get("alt_up_limit", 10240))

        return {
            "status": "connected",
            "port": actual_port,
            "version": sanitize_str(version, 50),
            "global": {
                "dl_speed": dl_speed_global,
                "dl_speed_str": format_speed(dl_speed_global),
                "up_speed": up_speed_global,
                "up_speed_str": format_speed(up_speed_global),
                "active_downloads": active_downloads,
                "active_uploads": active_uploads,
                "total_torrents": len(torrents_list),
                "dht_nodes": int(global_info.get("dht_nodes", 0)),
                "save_path": sanitize_str(save_path, 250),
                "dl_limit": global_dl_limit,
                "dl_limit_str": format_speed(global_dl_limit) if global_dl_limit > 0 else "Unlimited",
                "up_limit": global_up_limit,
                "up_limit_str": format_speed(global_up_limit) if global_up_limit > 0 else "Unlimited",
                "alt_mode": alt_mode,
                "alt_dl_limit_str": format_speed(alt_dl_limit),
                "alt_up_limit_str": format_speed(alt_up_limit)
            },
            "torrents": torrents_list[:MAX_QBIT_TORRENTS]
        }
    except Exception as e:
        return {
            "status": "disconnected",
            "port": actual_port,
            "error": sanitize_str(str(e), 200),
            "global": {
                "dl_speed": 0,
                "dl_speed_str": "0 B/s",
                "up_speed": 0,
                "up_speed_str": "0 B/s",
                "active_downloads": 0,
                "active_uploads": 0,
                "total_torrents": 0,
                "save_path": DEFAULT_DOWNLOAD_DIR,
                "dl_limit_str": "Unlimited",
                "up_limit_str": "Unlimited",
                "alt_mode": False
            },
            "torrents": []
        }

def control_qbittorrent(action, target, extra=None, host="127.0.0.1", port=8080):
    actual_port = port or 8080
    base_api = f"http://{host}:{actual_port}/api/v2"
    torrents_url = f"{base_api}/torrents"
    transfer_url = f"{base_api}/transfer"
    app_url = f"{base_api}/app"

    endpoints = []
    data_dict = {}

    if action in ["pause", "stop"]:
        endpoints = [f"{torrents_url}/stop", f"{torrents_url}/pause"]
        data_dict = {"hashes": target}
    elif action in ["resume", "start"]:
        endpoints = [f"{torrents_url}/start", f"{torrents_url}/resume"]
        data_dict = {"hashes": target}
    elif action == "delete":
        endpoints = [f"{torrents_url}/delete"]
        data_dict = {"hashes": target, "deleteFiles": "true" if extra in ["1", "true", True] else "false"}
    elif action == "add":
        endpoints = [f"{torrents_url}/add"]
        data_dict = {"urls": target}
        if extra and extra != "-":
            data_dict["savepath"] = extra
    elif action == "set_global_dl_limit":
        endpoints = [f"{transfer_url}/setDownloadLimit"]
        data_dict = {"limit": int(target)}
    elif action == "set_global_up_limit":
        endpoints = [f"{transfer_url}/setUploadLimit"]
        data_dict = {"limit": int(target)}
    elif action == "toggle_alt_speed":
        endpoints = [f"{transfer_url}/toggleSpeedLimitsMode"]
        data_dict = {}
    elif action == "set_global_save_path":
        endpoints = [f"{app_url}/setPreferences"]
        data_dict = {"json": json.dumps({"save_path": target})}
    elif action == "set_torrent_dl_limit":
        endpoints = [f"{torrents_url}/setDownloadLimit"]
        data_dict = {"hashes": target, "limit": int(extra or 0)}
    elif action == "set_torrent_up_limit":
        endpoints = [f"{torrents_url}/setUploadLimit"]
        data_dict = {"hashes": target, "limit": int(extra or 0)}
    elif action == "set_torrent_location":
        endpoints = [f"{torrents_url}/setLocation"]
        data_dict = {"hashes": target, "location": extra or ""}
    elif action == "toggle_force":
        endpoints = [f"{torrents_url}/setForceStart"]
        data_dict = {"hashes": target, "value": "true" if extra in ["1", "true", True] else "false"}
    elif action == "recheck":
        endpoints = [f"{torrents_url}/recheck"]
        data_dict = {"hashes": target}
    else:
        return {"status": "error", "message": f"Unknown action {action}"}

    encoded_data = urllib.parse.urlencode(data_dict).encode('utf-8')
    last_err = ""
    for ep in endpoints:
        try:
            req = urllib.request.Request(ep, data=encoded_data)
            with urllib.request.urlopen(req, timeout=2.5) as resp:
                _ = read_bounded(resp, 64 * 1024)
                return {"status": "success", "action": action, "target": target}
        except urllib.error.HTTPError as he:
            last_err = f"HTTP {he.code}: {he.reason}"
            if he.code in [404, 400]:
                continue
            return {"status": "error", "message": last_err}
        except Exception as e:
            last_err = str(e)
            continue

    return {"status": "error", "message": last_err or f"Action '{action}' failed"}

# -----------------------------------------------------------------------------
# Dynamic Config-Driven Indexer Search Providers
# -----------------------------------------------------------------------------

def search_archive_org(indexer, query, category_filter="all"):
    """
    Query Internet Archive BitTorrent metadata API for legal public domain media,
    open software, books, audio, and Linux ISOs.
    """
    results = []
    try:
        clean_q = urllib.parse.quote(query)
        base_url = indexer.get("url") or "https://archive.org/advancedsearch.php"
        search_url = f"{base_url}?q=title%3A%28{clean_q}%29+AND+format%3A%28%22Archive+BitTorrent%22%29&fl%5B%5D=identifier,title,downloads,item_size,publicdate,mediatype&sort%5B%5D=downloads+desc&rows=30&output=json"
        data = fetch_url(search_url, as_json=True)
        docs = data.get("response", {}).get("docs", [])
        badge = indexer.get("badge") or "Archive"
        p_name = indexer.get("name") or "Internet Archive"

        for doc in docs:
            ident = doc.get("identifier")
            title = doc.get("title") or ident
            if not ident or not title:
                continue
            size_bytes = int(doc.get("item_size", 0))
            downloads = int(doc.get("downloads", 0))
            seeds = max(5, min(1000, downloads // 200))
            leechers = max(1, seeds // 8)
            pub_date = doc.get("publicdate", "").split("T")[0] if doc.get("publicdate") else ""
            media_type = doc.get("mediatype", "software")

            cat_label = "Software"
            if media_type in ["audio", "etree"]:
                cat_label = "Music"
            elif media_type in ["movies", "animation"]:
                cat_label = "Movies"
            elif media_type in ["texts"]:
                cat_label = "Documents"

            torrent_url = f"https://archive.org/download/{urllib.parse.quote(ident)}/{urllib.parse.quote(ident)}_archive.torrent"
            results.append({
                "title": sanitize_str(title, 250),
                "provider": sanitize_str(p_name, 50),
                "provider_badge": sanitize_str(badge, 20),
                "category": sanitize_str(cat_label, 50),
                "size": sanitize_str(format_bytes(size_bytes), 50),
                "size_bytes": size_bytes,
                "seeds": seeds,
                "leechers": leechers,
                "date": sanitize_str(pub_date, 50),
                "magnet": sanitize_magnet(torrent_url),
                "info_hash": ""
            })
    except Exception:
        pass
    return results

def search_rss(indexer, query, category_filter="all"):
    """
    Parse standard BitTorrent XML RSS 2.0 / Atom feeds (e.g. LinuxTracker,
    distribution release trackers, or community feeds).
    """
    results = []
    try:
        base_url = indexer.get("url")
        if not base_url:
            return []
        clean_q = urllib.parse.quote(query)
        sep = "&" if "?" in base_url else "?"
        url = f"{base_url}{sep}search={clean_q}"
        badge = indexer.get("badge") or "RSS"
        p_name = indexer.get("name") or "RSS Feed"

        root = fetch_url(url, as_xml=True)
        tokens = [t.lower() for t in query.split() if len(t) > 1]

        for item in root.findall('./channel/item'):
            title_node = item.find('title')
            title = title_node.text.strip() if title_node is not None and title_node.text else ""
            if not title:
                continue
            if tokens and not any(t in title.lower() for t in tokens):
                continue

            link_node = item.find('link')
            link = link_node.text.strip() if link_node is not None and link_node.text else ""
            desc_node = item.find('description')
            desc = desc_node.text or ""
            pub_date_node = item.find('pubDate')
            pub_date = pub_date_node.text.strip() if pub_date_node is not None and pub_date_node.text else ""

            info_hash = ""
            magnet = ""
            hash_match = re.search(r'(?:id=|hash=|urn:btih:)([0-9a-fA-F]{40})', link + " " + desc)
            if hash_match:
                info_hash = hash_match.group(1)
                magnet = make_magnet(info_hash, title)
            else:
                mag_m = re.search(r'(magnet:\?[^\s\"\'<>]+)', desc + " " + link)
                if mag_m:
                    magnet = mag_m.group(1)

            enclosure = item.find('enclosure')
            size_bytes = 0
            if enclosure is not None:
                enc_url = enclosure.get('url')
                if not magnet and enc_url:
                    magnet = enc_url
                enc_len = enclosure.get('length')
                if enc_len and enc_len.isdigit():
                    size_bytes = int(enc_len)

            if not magnet and not link.endswith(".torrent") and not info_hash:
                continue
            if not magnet and link:
                magnet = link

            seeds = 0
            leechers = 0
            s_m = re.search(r'seeders?\D+(\d+)', desc, re.I)
            if s_m:
                seeds = int(s_m.group(1))
            l_m = re.search(r'leechers?\D+(\d+)', desc, re.I)
            if l_m:
                leechers = int(l_m.group(1))

            results.append({
                "title": sanitize_str(title.replace("[TORRENT]", "").strip(), 250),
                "provider": sanitize_str(p_name, 50),
                "provider_badge": sanitize_str(badge, 20),
                "category": "Software",
                "size": sanitize_str(format_bytes(size_bytes), 50) if size_bytes > 0 else "ISO / Media",
                "size_bytes": size_bytes,
                "seeds": max(0, min(1000000, seeds)),
                "leechers": max(0, min(1000000, leechers)),
                "date": sanitize_str(pub_date[:10] if pub_date else "", 50),
                "magnet": sanitize_magnet(magnet),
                "info_hash": sanitize_hash(info_hash)
            })
    except Exception:
        pass
    return results

def search_torznab(indexer, query, category_filter="all"):
    """
    Query standard Torznab API (used by Jackett, Prowlarr, Cardigann, etc.).
    """
    results = []
    try:
        base_url = indexer.get("url")
        if not base_url:
            return []
        apikey = indexer.get("apikey", "")
        clean_q = urllib.parse.quote(query)
        sep = "&" if "?" in base_url else "?"
        url = f"{base_url}{sep}t=search&q={clean_q}"
        if apikey:
            url += f"&apikey={urllib.parse.quote(apikey)}"

        badge = indexer.get("badge") or "Torznab"
        p_name = indexer.get("name") or "Torznab"

        root = fetch_url(url, as_xml=True)
        ns = {"torznab": "http://torznab.com/schemas/2015/feed"}

        for item in root.findall('./channel/item'):
            title_node = item.find('title')
            title = title_node.text.strip() if title_node is not None and title_node.text else ""
            if not title:
                continue

            size_node = item.find('size')
            size_bytes = int(size_node.text) if size_node is not None and size_node.text.isdigit() else 0

            enclosure = item.find('enclosure')
            enc_url = enclosure.get('url') if enclosure is not None else ""

            info_hash = ""
            seeds = 0
            leechers = 0
            magnet = enc_url

            for attr in item.findall('./torznab:attr', ns):
                a_name = attr.get('name')
                a_val = attr.get('value')
                if a_name == 'infohash' and a_val:
                    info_hash = a_val
                elif a_name == 'seeders' and a_val and a_val.isdigit():
                    seeds = int(a_val)
                elif a_name == 'peers' and a_val and a_val.isdigit():
                    leechers = int(a_val)
                elif a_name == 'magneturl' and a_val:
                    magnet = a_val

            if not magnet and info_hash:
                magnet = make_magnet(info_hash, title)

            if not magnet:
                continue

            results.append({
                "title": sanitize_str(title, 250),
                "provider": sanitize_str(p_name, 50),
                "provider_badge": sanitize_str(badge, 20),
                "category": "General",
                "size": sanitize_str(format_bytes(size_bytes), 50),
                "size_bytes": size_bytes,
                "seeds": max(0, min(1000000, seeds)),
                "leechers": max(0, min(1000000, leechers)),
                "date": "",
                "magnet": sanitize_magnet(magnet),
                "info_hash": sanitize_hash(info_hash)
            })
    except Exception:
        pass
    return results

def search_json_api(indexer, query, category_filter="all"):
    """
    Query custom user-specified JSON REST API endpoint with template URL.
    """
    results = []
    try:
        url_template = indexer.get("url", "")
        if not url_template:
            return []
        clean_q = urllib.parse.quote(query)
        if "{query}" in url_template:
            url = url_template.replace("{query}", clean_q)
        else:
            sep = "&" if "?" in url_template else "?"
            url = f"{url_template}{sep}q={clean_q}"

        badge = indexer.get("badge") or "API"
        p_name = indexer.get("name") or "Search API"

        data = fetch_url(url, as_json=True)
        items = data if isinstance(data, list) else (data.get("results") or data.get("items") or data.get("data") or [])
        if isinstance(items, list):
            for it in items:
                if not isinstance(it, dict):
                    continue
                title = it.get("title") or it.get("name") or ""
                if not title:
                    continue
                h = it.get("info_hash") or it.get("hash") or ""
                mag = it.get("magnet") or (make_magnet(h, title) if h else "") or it.get("url", "")
                size_bytes = int(it.get("size_bytes") or it.get("size", 0))
                results.append({
                    "title": sanitize_str(title, 250),
                    "provider": sanitize_str(p_name, 50),
                    "provider_badge": sanitize_str(badge, 20),
                    "category": sanitize_str(it.get("category", "General"), 50),
                    "size": sanitize_str(format_bytes(size_bytes), 50),
                    "size_bytes": size_bytes,
                    "seeds": max(0, min(1000000, int(it.get("seeds", 0)))),
                    "leechers": max(0, min(1000000, int(it.get("leechers", 0)))),
                    "date": sanitize_str(it.get("date", ""), 50),
                    "magnet": sanitize_magnet(mag),
                    "info_hash": sanitize_hash(h)
                })
    except Exception:
        pass
    return results

DISPATCHERS = {
    "archive_org": search_archive_org,
    "rss": search_rss,
    "torznab": search_torznab,
    "json_api": search_json_api
}

def matches_category(item, category_filter):
    if category_filter == "all":
        return True
    cat = (item.get("category") or "").lower()
    title = (item.get("title") or "").lower()

    if category_filter == "games":
        return cat == "games" or "game" in title
    elif category_filter == "movies":
        return cat in ["movies", "movie", "video"]
    elif category_filter == "tv":
        return cat in ["tv", "tv shows", "video"] or any(s in title for s in ["s01", "s02", "season", "episode"])
    elif category_filter == "anime":
        return cat in ["anime", "raw", "translated", "manga"]
    elif category_filter == "software":
        return cat in ["software", "applications", "apps", "iso"]
    elif category_filter == "music":
        return cat in ["music", "audio", "lossless"]
    return True

def search_all(query, category="all", provider="all", sort_mode="seeds"):
    start_time = time.time()
    all_results = []
    provider_stats = {}

    conf = load_indexers_config()
    indexers = conf.get("indexers", [])

    active_indexers = [idx for idx in indexers if idx.get("enabled", True)]
    if provider != "all":
        active_indexers = [idx for idx in active_indexers if idx.get("id") == provider]

    def query_indexer(idx):
        itype = idx.get("type", "rss")
        handler = DISPATCHERS.get(itype, search_rss)
        return handler(idx, query, category)

    if active_indexers:
        with ThreadPoolExecutor(max_workers=min(8, len(active_indexers))) as executor:
            future_to_idx = {
                executor.submit(query_indexer, idx): idx
                for idx in active_indexers
            }

            for future in as_completed(future_to_idx):
                idx = future_to_idx[future]
                idx_id = idx.get("id")
                idx_name = idx.get("name")
                try:
                    res = future.result()
                    all_results.extend(res)
                    provider_stats[idx_id] = {
                        "name": idx_name,
                        "count": len(res),
                        "status": "ok"
                    }
                except Exception as e:
                    provider_stats[idx_id] = {
                        "name": idx_name,
                        "count": 0,
                        "status": f"error: {str(e)}"
                    }

    seen = set()
    deduped = []
    for item in all_results:
        if not matches_category(item, category):
            continue

        key = item.get("info_hash") or item.get("title", "").strip().lower()
        if key and key not in seen:
            seen.add(key)
            deduped.append(item)

    if sort_mode == "seeds":
        deduped.sort(key=lambda x: x.get("seeds", 0), reverse=True)
    elif sort_mode == "size_desc":
        deduped.sort(key=lambda x: x.get("size_bytes", 0), reverse=True)
    elif sort_mode == "size_asc":
        deduped.sort(key=lambda x: x.get("size_bytes", 0))
    elif sort_mode == "date":
        deduped.sort(key=lambda x: x.get("date", ""), reverse=True)

    elapsed_ms = round((time.time() - start_time) * 1000)

    return {
        "query": sanitize_str(query, 100),
        "category": sanitize_str(category, 50),
        "provider": sanitize_str(provider, 50),
        "sort": sanitize_str(sort_mode, 50),
        "total": min(len(deduped), MAX_OUTPUT_SEARCH_RESULTS),
        "time_ms": elapsed_ms,
        "providers": provider_stats,
        "results": deduped[:MAX_OUTPUT_SEARCH_RESULTS]
    }

def main():
    if len(sys.argv) < 2:
        emit_bounded_json({"error": "Usage: torrent_engine.py --query <search_term> | --list-indexers | --qbittorrent"}, MAX_GENERIC_STDOUT_BYTES)
        return

    action = sys.argv[1]

    if action == "--list-indexers":
        emit_bounded_json(load_indexers_config(), MAX_ACTION_STDOUT_BYTES)
        return

    if action == "--config-path":
        emit_bounded_json({"config_path": get_indexers_config_path()}, MAX_ACTION_STDOUT_BYTES)
        return

    if action == "--add-indexer" and len(sys.argv) > 2:
        try:
            new_idx = json.loads(sys.argv[2])
            conf = load_indexers_config()
            indexers = [i for i in conf.get("indexers", []) if i.get("id") != new_idx.get("id")]
            indexers.append(new_idx)
            conf["indexers"] = indexers
            save_indexers_config(conf)
            emit_bounded_json({"status": "success", "indexers": indexers}, MAX_ACTION_STDOUT_BYTES)
        except Exception as e:
            emit_bounded_json({"status": "error", "message": str(e)}, MAX_ACTION_STDOUT_BYTES)
        return

    if action == "--remove-indexer" and len(sys.argv) > 2:
        idx_id = sys.argv[2]
        conf = load_indexers_config()
        conf["indexers"] = [i for i in conf.get("indexers", []) if i.get("id") != idx_id]
        save_indexers_config(conf)
        emit_bounded_json({"status": "success", "removed": idx_id}, MAX_ACTION_STDOUT_BYTES)
        return

    if action == "--toggle-indexer" and len(sys.argv) > 2:
        idx_id = sys.argv[2]
        conf = load_indexers_config()
        for i in conf.get("indexers", []):
            if i.get("id") == idx_id:
                i["enabled"] = not i.get("enabled", True)
                break
        save_indexers_config(conf)
        emit_bounded_json({"status": "success", "toggled": idx_id}, MAX_ACTION_STDOUT_BYTES)
        return

    if action == "--qbittorrent":
        port = 8080
        if len(sys.argv) > 2 and sys.argv[2].isdigit():
            port = int(sys.argv[2])
        emit_bounded_json(get_qbittorrent_data(port=port), MAX_QBIT_STDOUT_BYTES)
        return

    if action == "--qb-action" and len(sys.argv) >= 3:
        act = sys.argv[2]
        target = sys.argv[3] if len(sys.argv) > 3 else ""
        extra = sys.argv[4] if len(sys.argv) > 4 else None
        port = 8080
        if len(sys.argv) > 5 and sys.argv[5].isdigit():
            port = int(sys.argv[5])
        elif extra and extra.isdigit() and int(extra) in [8080, 8085, 9091, 8000, 8090, 8888, 6881, 8081]:
            if act not in ["set_global_dl_limit", "set_global_up_limit", "set_torrent_dl_limit", "set_torrent_up_limit"]:
                port = int(extra)
                extra = None
        emit_bounded_json(control_qbittorrent(act, target, extra=extra, port=port), MAX_ACTION_STDOUT_BYTES)
        return

    if action == "--test-providers":
        test_out = search_all("ubuntu", category="all", provider="all")
        emit_bounded_json(test_out, MAX_SEARCH_STDOUT_BYTES)
        return

    if action == "--query" and len(sys.argv) > 2:
        query_val = sys.argv[2]
        cat_val = "all"
        prov_val = "all"
        sort_val = "seeds"

        i = 3
        while i < len(sys.argv):
            if sys.argv[i] == "--category" and i + 1 < len(sys.argv):
                cat_val = sys.argv[i+1].lower()
                i += 2
            elif sys.argv[i] == "--provider" and i + 1 < len(sys.argv):
                prov_val = sys.argv[i+1].lower()
                i += 2
            elif sys.argv[i] == "--sort" and i + 1 < len(sys.argv):
                sort_val = sys.argv[i+1].lower()
                i += 2
            else:
                i += 1

        output = search_all(query_val, category=cat_val, provider=prov_val, sort_mode=sort_val)
        emit_bounded_json(output, MAX_SEARCH_STDOUT_BYTES)
        return

    emit_bounded_json({"error": f"Unknown argument: {action}"}, MAX_GENERIC_STDOUT_BYTES)

if __name__ == "__main__":
    main()
