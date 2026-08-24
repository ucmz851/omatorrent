# OmaTorrent for Omarchy

[![Omarchy 4.0+](https://img.shields.io/badge/Omarchy-4.0%2B-c6aa75?style=flat-square)](https://omarchy.org/manual/shell-plugins/)
[![Multi-Source](https://img.shields.io/badge/Indexers-TPB%20%7C%20Lime%20%7C%20YTS%20%7C%20EZTV%20%7C%20FitGirl%20%7C%20Nyaa-6aa6b2?style=flat-square)](https://github.com/ucmz851/omatorrent)
[![MIT License](https://img.shields.io/badge/license-MIT-7952b3?style=flat-square)](LICENSE)

An ultra-fast, multi-source torrent search engine, filter aggregator, and one-click magnet launcher built natively for the **Omarchy Quattro bar**.

---

## Highlights

- **⚡ Multi-Indexer Aggregation:** Simultaneously queries **ThePirateBay**, **LimeTorrents**, **YTS** (Movies), **EZTV** (TV Shows), **FitGirl Repacks** (Games), and **Nyaa** (Anime & Media) in parallel.
- **🧲 One-Click Magnet Dispatch:** Click `󰚌` to instantly inject into **qBittorrent** or open in your default Linux desktop torrent client (`xdg-open`).
- **📊 Live qBittorrent Monitor:** Real-time transfer cards, live DL/UP speeds, ETA countdown, progress bars, and pause/resume/delete actions.
- **⚙️ Advanced Speed & Path Limiters:** Configure global and per-torrent speed limits, turtle mode toggle, and customize default download folders directly in the panel.
- **📋 Direct Wayland Clipboard:** Click `󰆏` to sanitize and copy clean magnet links to your clipboard via `wl-copy`.
- **🏷️ Instant Categories:** Filter by **All**, **Movies**, **TV Shows**, **Games**, **Anime**, **Software**, and **Music**.
- **🔄 Dynamic Sorting:** Sort by **Most Seeds** (default), **Largest Size**, **Smallest Size**, or **Newest Date**.
- **⌨️ Keyboard-First Workflow:** Press global shortcut or click to open with immediate search input focus. Press `Enter` to search, `Esc` to close.
- **🎨 Quattro Visual Design:** Dynamic bar status colors, high-contrast seed/peer counters, provider badges, and plain-text safety sanitization.

---

## Supported Search Indexers

| Provider | Type / Focus | Source / Method |
| :--- | :--- | :--- |
| **The Pirate Bay** | General, Movies, TV, Software | Direct JSON API (`apibay.org`) |
| **LimeTorrents** | General, Games, Applications, Music | Fast HTML stream parser & infohash resolver |
| **YTS** | HD / 4K Movies (YIFY) | Direct API with multi-resolution torrent streams |
| **EZTV** | TV Episodes & Complete Seasons | Direct Show API (`eztv.re`) |
| **FitGirl Repacks** | PC Games & Evergreen Repacks | Direct RSS XML Content Scraper |
| **Nyaa** | Anime, Asian Media, Audio | High-speed XML RSS feed parser |

---

## Install

OmaTorrent requires Omarchy with shell plugin support.

```sh
omarchy plugin add https://github.com/ucmz851/omatorrent.git --enable
```

The shell normally picks up the plugin immediately. If the widget does not appear, restart the shell:

```sh
omarchy restart shell
```

---

## Keybindings & Usage

| Action | Result |
| :--- | :--- |
| **Left-click bar icon** | Open search popout with immediate keyboard focus |
| **Middle-click bar icon** | Re-run last search query |
| **`Enter` in search box** | Execute multi-indexer search |
| **Click category pill** | Switch category filter & re-search instantly |
| **Click provider selector** | Toggle between All Indexers or a specific site |
| **Click sort selector** | Cycle sorting modes (Most Seeds, Size, Date) |
| **`󰚌` on result card** | Launch magnet link into qBittorrent or desktop app |
| **`󰆏` on result card** | Copy clean magnet link to clipboard (`wl-copy`) |
| **`Esc`** | Close search panel |

---

## Privacy & Safety

- **100% On-Device:** No analytics, tracking tokens, or intermediate proxy servers.
- **Direct Queries:** Search requests are sent directly to public indexers or APIs.
- **No Background Auto-Downloads:** Magnet links are only dispatched when explicitly clicked.
- **PlainText Sanitization:** All titles, descriptions, and metadata enforce `Text.PlainText` rendering to eliminate injection risks.

---

## Development

Test the Python search engine directly:

```sh
python3 scripts/torrent_engine.py --query "linux iso" --category software
```

Validate the plugin schema from the checkout:

```sh
omarchy plugin validate .
```

---

## License

[MIT](LICENSE) © 2026 Usama Imran (ucmz851).
