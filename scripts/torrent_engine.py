#!/usr/bin/env python3
"""
OmaTorrent Multi-Source Torrent Search Engine
Aggregates search results from ThePirateBay, LimeTorrents, YTS, EZTV, FitGirl, and Nyaa.
Provides 1-click magnet URI generation, categories, and fast multi-threaded execution.
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
REQUEST_TIMEOUT = 4.0

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

def make_magnet(info_hash, name, trackers=None):
    if not info_hash:
        return ""
    clean_hash = info_hash.strip().lower()
    encoded_name = urllib.parse.quote(name.strip())
    tr_list = trackers or DEFAULT_TRACKERS
    tr_params = "&".join(f"tr={urllib.parse.quote(t)}" for t in tr_list)
    return f"magnet:?xt=urn:btih:{clean_hash}&dn={encoded_name}&{tr_params}"

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

def fetch_url(url, as_json=False, as_xml=False, timeout=REQUEST_TIMEOUT):
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        content = resp.read()
        if as_json:
            return json.loads(content.decode('utf-8', errors='ignore'))
        if as_xml:
            return ET.fromstring(content)
        return content.decode('utf-8', errors='ignore')

# -----------------------------------------------------------------------------
# qBittorrent WebUI API Engine
# -----------------------------------------------------------------------------
def get_qbittorrent_data(host="127.0.0.1", port=8080):
    base_url = f"http://{host}:{port}/api/v2"
    try:
        ver_req = urllib.request.Request(f"{base_url}/app/version")
        with urllib.request.urlopen(ver_req, timeout=1.2) as resp:
            version = resp.read().decode('utf-8').strip()

        transfer_req = urllib.request.Request(f"{base_url}/transfer/info")
        global_info = {}
        with urllib.request.urlopen(transfer_req, timeout=1.2) as resp:
            global_info = json.loads(resp.read().decode('utf-8'))

        torrents_req = urllib.request.Request(f"{base_url}/torrents/info?filter=all")
        torrents_raw = []
        with urllib.request.urlopen(torrents_req, timeout=1.5) as resp:
            torrents_raw = json.loads(resp.read().decode('utf-8'))

        torrents_list = []
        active_downloads = 0
        active_uploads = 0

        for t in torrents_raw:
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

            state_label = "Downloading"
            if state in ["pausedDL", "pausedUP"]:
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
                "hash": t.get("hash", ""),
                "name": t.get("name", "Unknown Torrent"),
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
                "state": state,
                "state_label": state_label,
                "seeds": t.get("num_seeds", 0),
                "peers": t.get("num_leechs", 0),
                "category": t.get("category", "") or "General",
                "save_path": t.get("save_path", ""),
                "added_on": t.get("added_on", 0)
            })

        torrents_list.sort(key=lambda x: (x["state_label"] != "Downloading", -x["dlspeed"], -x["progress"]))

        dl_speed_global = int(global_info.get("dl_info_speed", 0))
        up_speed_global = int(global_info.get("up_info_speed", 0))

        return {
            "status": "connected",
            "version": version,
            "global": {
                "dl_speed": dl_speed_global,
                "dl_speed_str": format_speed(dl_speed_global),
                "up_speed": up_speed_global,
                "up_speed_str": format_speed(up_speed_global),
                "active_downloads": active_downloads,
                "active_uploads": active_uploads,
                "total_torrents": len(torrents_list),
                "dht_nodes": global_info.get("dht_nodes", 0)
            },
            "torrents": torrents_list
        }
    except Exception as e:
        return {
            "status": "disconnected",
            "error": str(e),
            "global": {
                "dl_speed": 0,
                "dl_speed_str": "0 B/s",
                "up_speed": 0,
                "up_speed_str": "0 B/s",
                "active_downloads": 0,
                "active_uploads": 0,
                "total_torrents": 0
            },
            "torrents": []
        }

def control_qbittorrent(action, target, host="127.0.0.1", port=8080):
    base_url = f"http://{host}:{port}/api/v2/torrents"
    try:
        if action == "pause":
            url = f"{base_url}/pause"
            data = urllib.parse.urlencode({"hashes": target}).encode('utf-8')
            req = urllib.request.Request(url, data=data)
            with urllib.request.urlopen(req, timeout=2.0) as resp:
                return {"status": "success", "action": "pause", "hash": target}

        elif action == "resume":
            url = f"{base_url}/resume"
            data = urllib.parse.urlencode({"hashes": target}).encode('utf-8')
            req = urllib.request.Request(url, data=data)
            with urllib.request.urlopen(req, timeout=2.0) as resp:
                return {"status": "success", "action": "resume", "hash": target}

        elif action == "delete":
            url = f"{base_url}/delete"
            data = urllib.parse.urlencode({"hashes": target, "deleteFiles": "false"}).encode('utf-8')
            req = urllib.request.Request(url, data=data)
            with urllib.request.urlopen(req, timeout=2.0) as resp:
                return {"status": "success", "action": "delete", "hash": target}

        elif action == "add":
            url = f"{base_url}/add"
            data = urllib.parse.urlencode({"urls": target}).encode('utf-8')
            req = urllib.request.Request(url, data=data)
            with urllib.request.urlopen(req, timeout=2.0) as resp:
                return {"status": "success", "action": "add", "target": target}

        return {"status": "error", "message": f"Unknown action {action}"}
    except Exception as e:
        return {"status": "error", "message": str(e)}

# -----------------------------------------------------------------------------
# Provider 1: The Pirate Bay (via apibay.org)
# -----------------------------------------------------------------------------
def search_tpb(query, category_filter="all"):
    results = []
    try:
        cat_code = ""
        if category_filter in ["movies", "tv"]:
            cat_code = "&cat=200"
        elif category_filter == "music":
            cat_code = "&cat=100"
        elif category_filter == "games":
            cat_code = "&cat=400"
        elif category_filter == "software":
            cat_code = "&cat=300"

        url = f"https://apibay.org/q.php?q={urllib.parse.quote(query)}{cat_code}"
        data = fetch_url(url, as_json=True)
        if isinstance(data, list):
            for item in data:
                name = item.get("name", "").strip()
                info_hash = item.get("info_hash", "").strip()
                if not name or not info_hash or info_hash == "0000000000000000000000000000000000000000" or name == "No results found":
                    continue

                size_bytes = int(item.get("size", 0))
                seeds = int(item.get("seeders", 0))
                leechers = int(item.get("leechers", 0))
                cat_id = str(item.get("category", ""))
                
                # Category label
                cat_label = "Other"
                if cat_id.startswith("1"):
                    cat_label = "Music"
                elif cat_id.startswith("2"):
                    cat_label = "Movies" if "201" in cat_id or "207" in cat_id else "TV"
                elif cat_id.startswith("3"):
                    cat_label = "Software"
                elif cat_id.startswith("4"):
                    cat_label = "Games"

                date_val = ""
                added_ts = item.get("added")
                if added_ts and str(added_ts).isdigit():
                    try:
                        date_val = time.strftime("%Y-%m-%d", time.gmtime(int(added_ts)))
                    except Exception:
                        pass

                results.append({
                    "title": name,
                    "provider": "ThePirateBay",
                    "provider_badge": "TPB",
                    "category": cat_label,
                    "size": format_bytes(size_bytes),
                    "size_bytes": size_bytes,
                    "seeds": seeds,
                    "leechers": leechers,
                    "date": date_val,
                    "magnet": make_magnet(info_hash, name),
                    "info_hash": info_hash
                })
    except Exception:
        pass
    return results

# -----------------------------------------------------------------------------
# Provider 2: LimeTorrents (limetorrents.fun)
# -----------------------------------------------------------------------------
def search_limetorrents(query, category_filter="all"):
    results = []
    try:
        url = f"https://www.limetorrents.fun/search/all/{urllib.parse.quote(query)}/seeds/1/"
        html = fetch_url(url)
        
        pattern = re.compile(
            r'itorrents\.net/torrent/([0-9a-fA-F]{40})\.torrent.*?'
            r'<a href=\"(/[^\"<>]+-torrent-\d+\.html)\">([^<]+)</a></div>.*?'
            r'<td class=\"tdnormal\">([^<]+)</td>.*?'
            r'<td class=\"tdnormal\">([^<]+)</td>.*?'
            r'<td class=\"tdseed\">([^<]+)</td>.*?'
            r'<td class=\"tdleech\">([^<]+)</td>',
            re.DOTALL
        )

        for match in pattern.finditer(html):
            info_hash = match.group(1).strip()
            title = match.group(3).strip()
            date_cat = match.group(4).strip()
            size_str = match.group(5).strip()
            seeds_str = match.group(6).strip().replace(",", "")
            leech_str = match.group(7).strip().replace(",", "")

            seeds = int(seeds_str) if seeds_str.isdigit() else 0
            leechers = int(leech_str) if leech_str.isdigit() else 0
            size_bytes = parse_size_to_bytes(size_str)

            # Extract category strictly from LimeTorrents date_cat text
            cat_label = "General"
            date_cat_lower = date_cat.lower()
            if "application" in date_cat_lower or "software" in date_cat_lower:
                cat_label = "Software"
            elif "movie" in date_cat_lower:
                cat_label = "Movies"
            elif "tv" in date_cat_lower or "television" in date_cat_lower:
                cat_label = "TV"
            elif "game" in date_cat_lower:
                cat_label = "Games"
            elif "music" in date_cat_lower or "audio" in date_cat_lower:
                cat_label = "Music"
            elif "anime" in date_cat_lower:
                cat_label = "Anime"

            # Check title heuristics for better categorization if marked General
            if cat_label == "General":
                title_lower = title.lower()
                if any(ext in title_lower for ext in [".repack", "repack", "fitgirl", "dodi", "codex", "cpiy", "plaza", "skidrow", "switch", "ps4", "xbox", "gog", "pc game"]):
                    cat_label = "Games"
                elif any(ext in title_lower for ext in ["1080p", "720p", "2160p", "bluray", "web-dl", "webrip", "hdrip", "x264", "x265", "hevc"]):
                    if any(s_tag in title_lower for s_tag in ["s01", "s02", "s03", "s04", "s05", "s06", "s07", "s08", "season", "episode", "e01", "e02"]):
                        cat_label = "TV"
                    else:
                        cat_label = "Movies"

            date_clean = date_cat.split("- in")[0].strip() if "- in" in date_cat else date_cat

            results.append({
                "title": title,
                "provider": "LimeTorrents",
                "provider_badge": "Lime",
                "category": cat_label,
                "size": size_str,
                "size_bytes": size_bytes,
                "seeds": seeds,
                "leechers": leechers,
                "date": date_clean,
                "magnet": make_magnet(info_hash, title),
                "info_hash": info_hash
            })
    except Exception:
        pass
    return results

# -----------------------------------------------------------------------------
# Provider 3: YTS Movies (yts.lt / mirrors)
# -----------------------------------------------------------------------------
def search_yts(query, category_filter="all"):
    # If user selected games, software, music, or anime, YTS has none of these
    if category_filter in ["games", "software", "music", "anime"]:
        return []

    results = []
    domains = ["yts.lt", "yts.torrentbay.to", "yts.mx"]
    for domain in domains:
        try:
            url = f"https://{domain}/api/v2/list_movies.json?query_term={urllib.parse.quote(query)}&sort_by=seeds&limit=15"
            data = fetch_url(url, as_json=True, timeout=3.5)
            movies = data.get("data", {}).get("movies", [])
            if not movies:
                continue

            for movie in movies:
                movie_title = movie.get("title_long") or movie.get("title") or "Movie"
                year = movie.get("year", "")
                torrents = movie.get("torrents", [])
                for t in torrents:
                    quality = t.get("quality", "")
                    t_type = t.get("type", "")
                    title_full = f"{movie_title} [{quality}] ({t_type.upper()})"
                    info_hash = t.get("hash", "")
                    seeds = int(t.get("seeds", 0))
                    peers = int(t.get("peers", 0))
                    size_str = t.get("size", "0 MB")
                    size_bytes = int(t.get("size_bytes", parse_size_to_bytes(size_str)))
                    date_uploaded = t.get("date_uploaded", "").split()[0] if t.get("date_uploaded") else str(year)

                    results.append({
                        "title": title_full,
                        "provider": "YTS",
                        "provider_badge": "YTS",
                        "category": "Movies",
                        "size": size_str,
                        "size_bytes": size_bytes,
                        "seeds": seeds,
                        "leechers": peers,
                        "date": date_uploaded,
                        "magnet": make_magnet(info_hash, title_full),
                        "info_hash": info_hash
                    })
            if results:
                break
        except Exception:
            continue
    return results

# -----------------------------------------------------------------------------
# Provider 4: EZTV Shows (eztv.re / mirrors)
# -----------------------------------------------------------------------------
def search_eztv(query, category_filter="all"):
    # If user selected games, software, music, or movies, EZTV is TV shows only
    if category_filter in ["games", "software", "music", "movies", "anime"]:
        return []

    results = []
    try:
        url = f"https://eztv.re/api/get-torrents?limit=25&query={urllib.parse.quote(query)}"
        data = fetch_url(url, as_json=True)
        torrents = data.get("torrents", [])
        for t in torrents:
            title = t.get("title", "")
            magnet_url = t.get("magnet_url", "")
            info_hash = t.get("hash", "")
            seeds = int(t.get("seeds", 0))
            peers = int(t.get("peers", 0))
            size_bytes = int(t.get("size_bytes", 0))
            date_ts = t.get("date_released_unix", 0)
            date_str = ""
            if date_ts:
                try:
                    date_str = time.strftime("%Y-%m-%d", time.gmtime(int(date_ts)))
                except Exception:
                    pass

            if not magnet_url and info_hash:
                magnet_url = make_magnet(info_hash, title)

            results.append({
                "title": title,
                "provider": "EZTV",
                "provider_badge": "EZTV",
                "category": "TV",
                "size": format_bytes(size_bytes),
                "size_bytes": size_bytes,
                "seeds": seeds,
                "leechers": peers,
                "date": date_str,
                "magnet": magnet_url,
                "info_hash": info_hash
            })
    except Exception:
        pass
    return results

# -----------------------------------------------------------------------------
# Provider 5: FitGirl Repacks (fitgirl-repacks.site)
# -----------------------------------------------------------------------------
def search_fitgirl(query, category_filter="all"):
    if category_filter not in ["all", "games"]:
        return []

    results = []
    try:
        url = f"https://fitgirl-repacks.site/feed/?s={urllib.parse.quote(query)}"
        root = fetch_url(url, as_xml=True)
        for item in root.findall('./channel/item'):
            title_node = item.find('title')
            title = title_node.text.strip() if title_node is not None else ""
            if not title or "updates digest" in title.lower():
                continue

            pub_date_node = item.find('pubDate')
            pub_date = pub_date_node.text.strip() if pub_date_node is not None else ""
            date_clean = ""
            if pub_date:
                parts = pub_date.split()
                if len(parts) >= 4:
                    date_clean = f"{parts[3]}-{parts[2]}-{parts[1]}"

            content_node = item.find('{http://purl.org/rss/1.0/modules/content/}encoded')
            content_text = content_node.text if content_node is not None else ""
            
            magnets = re.findall(r'href=[\"\'](magnet:\?[^\"\']+)[\"\']', content_text)
            if not magnets:
                hash_match = re.search(r'magnet:\?xt=urn:btih:([0-9a-zA-Z]{40})', content_text)
                if hash_match:
                    magnets = [make_magnet(hash_match.group(1), title)]

            if magnets:
                size_match = re.search(r'Repack Size:\s*<strong>([^<]+)</strong>', content_text, re.IGNORECASE)
                if not size_match:
                    size_match = re.search(r'Size:\s*([^,\n<]+)', content_text)
                
                size_str = size_match.group(1).strip() if size_match else "Game Repack"
                size_bytes = parse_size_to_bytes(size_str)

                results.append({
                    "title": f"FitGirl Repack: {title}",
                    "provider": "FitGirl",
                    "provider_badge": "FitGirl",
                    "category": "Games",
                    "size": size_str,
                    "size_bytes": size_bytes,
                    "seeds": 120,  # Evergreen game torrents
                    "leechers": 15,
                    "date": date_clean,
                    "magnet": magnets[0],
                    "info_hash": ""
                })
    except Exception:
        pass
    return results

# -----------------------------------------------------------------------------
# Provider 6: Nyaa Anime & Media (nyaa.si)
# -----------------------------------------------------------------------------
def search_nyaa(query, category_filter="all"):
    if category_filter in ["software", "games"]:
        return []

    results = []
    try:
        url = f"https://nyaa.si/?page=rss&q={urllib.parse.quote(query)}&s=seeders&o=desc"
        root = fetch_url(url, as_xml=True)
        for item in root.findall('./channel/item'):
            title_node = item.find('title')
            title = title_node.text.strip() if title_node is not None else ""
            if not title:
                continue

            pub_date_node = item.find('pubDate')
            pub_date = pub_date_node.text.strip() if pub_date_node is not None else ""

            seeds_node = item.find('{https://nyaa.si/xmlns/nyaa}seeders')
            leech_node = item.find('{https://nyaa.si/xmlns/nyaa}leechers')
            size_node = item.find('{https://nyaa.si/xmlns/nyaa}size')
            hash_node = item.find('{https://nyaa.si/xmlns/nyaa}infoHash')
            cat_node = item.find('{https://nyaa.si/xmlns/nyaa}category')

            seeds = int(seeds_node.text) if seeds_node is not None and seeds_node.text.isdigit() else 0
            leechers = int(leech_node.text) if leech_node is not None and leech_node.text.isdigit() else 0
            size_str = size_node.text if size_node is not None else "Unknown"
            info_hash = hash_node.text if hash_node is not None else ""
            cat_label = cat_node.text.split("-")[-1].strip() if cat_node is not None else "Anime"

            results.append({
                "title": title,
                "provider": "Nyaa",
                "provider_badge": "Nyaa",
                "category": cat_label,
                "size": size_str,
                "size_bytes": parse_size_to_bytes(size_str),
                "seeds": seeds,
                "leechers": leechers,
                "date": pub_date.split("+")[0].strip() if "+" in pub_date else pub_date,
                "magnet": make_magnet(info_hash, title),
                "info_hash": info_hash
            })
    except Exception:
        pass
    return results

# -----------------------------------------------------------------------------
# Category Strict Post-Filtering
# -----------------------------------------------------------------------------
def matches_category(item, category_filter):
    if category_filter == "all":
        return True
    cat = (item.get("category") or "").lower()
    title = (item.get("title") or "").lower()

    if category_filter == "games":
        return cat == "games" or "repack" in title or "game" in title or item.get("provider") == "FitGirl"
    elif category_filter == "movies":
        return cat in ["movies", "movie", "video"] and not ("season" in title or "episode" in title or "s0" in title)
    elif category_filter == "tv":
        return cat in ["tv", "tv shows", "video"] or any(s in title for s in ["s01", "s02", "s03", "s04", "s05", "s06", "s07", "s08", "season", "episode", "e01", "e02"])
    elif category_filter == "anime":
        return cat in ["anime", "raw", "translated", "lossless", "lossy"] or item.get("provider") == "Nyaa"
    elif category_filter == "software":
        return cat in ["software", "applications", "apps"]
    elif category_filter == "music":
        return cat in ["music", "audio", "lossless", "lossy"]
    return True

# -----------------------------------------------------------------------------
# Main Query Aggregator
# -----------------------------------------------------------------------------
def search_all(query, category="all", provider="all", sort_mode="seeds"):
    start_time = time.time()
    all_results = []
    provider_stats = {}

    providers_map = {
        "tpb": ("The Pirate Bay", search_tpb),
        "lime": ("LimeTorrents", search_limetorrents),
        "yts": ("YTS", search_yts),
        "eztv": ("EZTV", search_eztv),
        "fitgirl": ("FitGirl", search_fitgirl),
        "nyaa": ("Nyaa", search_nyaa)
    }

    selected_providers = {}
    if provider == "all":
        selected_providers = providers_map
    elif provider in providers_map:
        selected_providers = {provider: providers_map[provider]}
    else:
        selected_providers = providers_map

    with ThreadPoolExecutor(max_workers=min(8, len(selected_providers))) as executor:
        future_to_prov = {
            executor.submit(func, query, category): key
            for key, (name, func) in selected_providers.items()
        }

        for future in as_completed(future_to_prov):
            prov_key = future_to_prov[future]
            prov_name = selected_providers[prov_key][0]
            try:
                prov_results = future.result()
                all_results.extend(prov_results)
                provider_stats[prov_key] = {
                    "name": prov_name,
                    "count": len(prov_results),
                    "status": "ok"
                }
            except Exception as e:
                provider_stats[prov_key] = {
                    "name": prov_name,
                    "count": 0,
                    "status": f"error: {str(e)}"
                }

    # Deduplicate by info_hash or clean title
    seen = set()
    deduped = []
    for item in all_results:
        # Check strict category filter
        if not matches_category(item, category):
            continue

        key = item.get("info_hash") or item.get("title", "").strip().lower()
        if key and key not in seen:
            seen.add(key)
            deduped.append(item)

    # Sorting
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
        "query": query,
        "category": category,
        "provider": provider,
        "sort": sort_mode,
        "total": len(deduped),
        "time_ms": elapsed_ms,
        "providers": provider_stats,
        "results": deduped[:50]
    }

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: torrent_engine.py --query <search_term> | --qbittorrent | --qb-action <action> <target>"}))
        return

    action = sys.argv[1]

    if action == "--qbittorrent":
        port = 8080
        if len(sys.argv) > 2 and sys.argv[2].isdigit():
            port = int(sys.argv[2])
        print(json.dumps(get_qbittorrent_data(port=port)))
        return

    if action == "--qb-action" and len(sys.argv) > 3:
        act = sys.argv[2]
        target = sys.argv[3]
        port = 8080
        if len(sys.argv) > 4 and sys.argv[4].isdigit():
            port = int(sys.argv[4])
        print(json.dumps(control_qbittorrent(act, target, port=port)))
        return

    if action == "--test-providers":
        test_out = search_all("ubuntu", category="all", provider="all")
        print(json.dumps(test_out, indent=2))
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
        print(json.dumps(output, indent=2))
        return

    print(json.dumps({"error": f"Unknown argument: {action}"}))

if __name__ == "__main__":
    main()
