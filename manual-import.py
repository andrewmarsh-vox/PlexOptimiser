#!/usr/bin/env python3
"""Import hand-picked TV torrents that Sonarr can't match by name.

Torrents live in qBittorrent under category `pokemon-manual` (Pokémon, series 24,
English/Netflix numbering -> TVDB numbering) or `manual-import` with a
`sonarr-series-<id>` tag (plain SxxEyy numbering). When a torrent's selected
files are complete, each video is mapped to a Sonarr episode, imported via
Sonarr's ManualImport (move), and the torrent is removed once everything it
carried is in the library. Anything not confidently mapped is logged and left.

Usage: manual-import.py [--dry-run] [--plan [--apply-selection]]
  --plan             map every selected file now (even if not downloaded) and print the mapping
  --apply-selection  with --plan: deselect files that won't import (unresolved or already in library)
"""
import difflib, json, re, sys, time, urllib.parse, urllib.request
from datetime import datetime

QBIT = "http://127.0.0.1:8080/api/v2"
SONARR = "http://127.0.0.1:8989/api/v3"
SONARR_KEY = re.search(r"<ApiKey>([^<]+)", open("/root/media-stack/config/sonarr/config.xml").read()).group(1)
LOG = "/home/naboo/ruby/manual-import.log"
POKEMON_SERIES = 24
VIDEO = re.compile(r"\.(mkv|mp4|avi|m4v)$", re.I)
PLAN = "--plan" in sys.argv
APPLY_SEL = "--apply-selection" in sys.argv
DRY = "--dry-run" in sys.argv or PLAN
PLANNED = set()  # episode ids already claimed by an earlier (better-seeded) torrent during --plan


def log(msg):
    line = f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {'DRY ' if DRY else ''}{msg}"
    print(line)
    if not DRY:
        with open(LOG, "a") as f:
            f.write(line + "\n")


def http(url, method="GET", data=None, headers=None, form=False):
    body = None
    headers = dict(headers or {})
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            body = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    raw = urllib.request.urlopen(req, timeout=300).read()
    return json.loads(raw) if raw[:1] in (b"{", b"[") else raw


def qbit(path, method="GET", data=None):
    return http(QBIT + path, method, data, form=True)


def sonarr(path, method="GET", data=None):
    return http(SONARR + path, method, data, headers={"X-Api-Key": SONARR_KEY})


def norm(s):
    s = s.lower().replace("&", "and").replace("pokémon", "pokemon").replace("é", "e")
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def similarity(a, b):
    return difflib.SequenceMatcher(None, norm(a), norm(b)).ratio()


def pokemon_candidate(fname):
    """Return (season, episode, title_or_None) guess from a Pokémon release filename."""
    m = re.search(r"Horizons.*?S01E0*(\d+)\.(.+?)\.(?:1080p|720p)", fname, re.I)
    if m:
        return 20, int(m.group(1)), m.group(2).replace(".", " ")
    m = re.search(r"Master\.Journeys.*?S0\dE0*(\d+)\.(.+?)\.(?:1080p|720p)", fname, re.I)
    if m:  # Master Journeys E1 = TVDB S19E49; NanDesuKa part packs may restart numbering, so title decides
        return 19, 48 + int(m.group(1)), m.group(2).replace(".", " ")
    m = re.search(r"Master Journeys.*? - S01E(\d+) - ", fname)
    if m:  # untitled NanDesuKa part-2 files continue part-1 numbering (E13-27)
        return 19, 48 + int(m.group(1)), None
    m = re.search(r"Master Journeys.*? - S03E(\d+) - ", fname)
    if m:  # NanDesuKa "S03" = Master Journeys part 3 = MJ E28-42 = TVDB S19E76-90
        return 19, 75 + int(m.group(1)), None
    m = re.match(r"25(\d\d) - (.+)\.\w+$", fname)
    if m:  # Ultimate Journeys E1 ("The Spectral Express!") = TVDB S19E91
        return 19, 90 + int(m.group(1)), m.group(2)
    m = re.search(r"Pok[eé]mon S25E(\d+) ", fname)
    if m:  # untitled Tsundere-Raws Ultimate Journeys files: numeric mapping only
        return 19, 90 + int(m.group(1)), None
    m = re.search(r"Master Quest (\d+) - (.+?) \[", fname)
    if m:
        return 5, int(m.group(1)), m.group(2)
    m = re.match(r"\d{3} - (.+)\.\w+$", fname)
    if m:
        return 19, None, m.group(1)
    return None


def map_pokemon(fname, eps_by_se, missing):
    """Map to an episode id; title evidence wins, numbers are the fallback."""
    cand = pokemon_candidate(fname)
    if not cand:
        return None, "unrecognised name"
    season, num, title = cand
    guess = eps_by_se.get((season, num)) if num else None
    if title:
        pool = [e for e in missing if e["seasonNumber"] == season]
        best = max(pool, key=lambda e: similarity(title, e["title"]), default=None)
        best_score = similarity(title, best["title"]) if best else 0
        if guess and similarity(title, guess["title"]) >= 0.6:
            return guess, f"number+title ({similarity(title, guess['title']):.2f})"
        if best and best_score >= 0.8:
            return best, f"title match ({best_score:.2f}) '{best['title']}'"
        return None, f"no confident title match for '{title}' (best {best_score:.2f})"
    if guess and season == 19 and 61 <= num <= 90:
        return guess, "numeric (Master Journeys parts 2-3, untitled; part 1 title-verified E1=S19E49)"
    return None, "no title and no safe numeric rule"


def map_generic(fname, eps_by_se):
    m = re.search(r"S(\d{1,2})E(\d{1,3})", fname, re.I)
    if not m:
        return None, "no SxxEyy"
    e = eps_by_se.get((int(m.group(1)), int(m.group(2))))
    return (e, "SxxEyy") if e else (None, "episode not in Sonarr")


def process(t):
    tags = t.get("tags", "")
    if t["category"] == "pokemon-manual":
        series_id = POKEMON_SERIES
    else:
        m = re.search(r"sonarr-series-(\d+)", tags)
        if not m:
            log(f"SKIP {t['name']}: manual-import torrent without sonarr-series-<id> tag")
            return
        series_id = int(m.group(1))

    files = [f for f in qbit(f"/torrents/files?hash={t['hash']}") if f["priority"] > 0 and VIDEO.search(f["name"])]
    if not files or (not PLAN and any(f["progress"] < 1 for f in files)):
        return  # still downloading

    eps = sonarr(f"/episode?seriesId={series_id}")
    eps_by_se = {(e["seasonNumber"], e["episodeNumber"]): e for e in eps}
    missing = [e for e in eps if not e["hasFile"]]
    base = t["save_path"].rstrip("/")

    to_import, unresolved, already = [], [], 0
    used = PLANNED if PLAN else set()
    for f in files:
        fname = f["name"].split("/")[-1]
        ep, why = (map_pokemon(fname, eps_by_se, missing) if series_id == POKEMON_SERIES
                   else map_generic(fname, eps_by_se))
        if not ep:
            unresolved.append(f"{fname}: {why}")
            continue
        if ep["hasFile"]:
            already += 1
            continue
        if ep["id"] in used:
            unresolved.append(f"{fname}: S{ep['seasonNumber']:02d}E{ep['episodeNumber']:02d} already covered by another file/torrent")
            continue
        used.add(ep["id"])
        to_import.append((f"{base}/{f['name']}", ep, why))

    for u in unresolved:
        log(f"  UNRESOLVED [{t['name'][:50]}] {u}")

    if PLAN:
        for path, ep, why in to_import:
            log(f"  plan {path.split('/')[-1][:70]} -> S{ep['seasonNumber']:02d}E{ep['episodeNumber']:02d} '{ep['title']}' [{why}]")
        drop = [f for f in files if f"{base}/{f['name']}" not in {p for p, _, _ in to_import}]
        log(f"PLAN {t['name'][:60]}: {len(to_import)} to import, {already} already in library, {len(unresolved)} unresolved")
        if APPLY_SEL and drop:
            qbit("/torrents/filePrio", "POST", {"hash": t["hash"], "id": "|".join(str(f["index"]) for f in drop), "priority": 0})
            print(f"  deselected {len(drop)} files")
        return

    if to_import:
        folder = to_import[0][0].rsplit("/", 1)[0]
        parsed = {i["path"]: i for i in sonarr(f"/manualimport?folder={urllib.parse.quote(folder)}&filterExistingFiles=false")}
        payload = []
        for path, ep, why in to_import:
            p = parsed.get(path)
            if not p:  # files in sub-folders: ask Sonarr about that folder
                sub = path.rsplit("/", 1)[0]
                parsed.update({i["path"]: i for i in sonarr(f"/manualimport?folder={urllib.parse.quote(sub)}&filterExistingFiles=false")})
                p = parsed.get(path)
            if not p:
                log(f"  UNRESOLVED [{t['name'][:50]}] Sonarr can't see {path}")
                continue
            log(f"  map {path.split('/')[-1][:70]} -> S{ep['seasonNumber']:02d}E{ep['episodeNumber']:02d} '{ep['title']}' [{why}]")
            payload.append({"path": path, "seriesId": series_id, "episodeIds": [ep["id"]],
                            "quality": p["quality"], "languages": p.get("languages") or [{"id": 1, "name": "English"}],
                            "releaseGroup": p.get("releaseGroup") or "", "indexerFlags": 0, "releaseType": "singleEpisode"})
        if payload and not DRY:
            cmd = sonarr("/command", "POST", {"name": "ManualImport", "importMode": "move", "files": payload})
            for _ in range(360):
                time.sleep(5)
                status = sonarr(f"/command/{cmd['id']}")["status"]
                if status in ("completed", "failed", "aborted"):
                    break
            log(f"IMPORT {t['name'][:60]}: {len(payload)} files -> command {status}")

    # Remove the torrent only when every selected file is either in the library or unresolved-and-reported.
    if DRY:
        return
    eps = {e["id"]: e for e in sonarr(f"/episode?seriesId={series_id}")}
    pending = [ep for _, ep, _ in to_import if not eps[ep["id"]]["hasFile"]]
    if not pending and not unresolved:
        qbit("/torrents/delete", "POST", {"hashes": t["hash"], "deleteFiles": "true"})
        log(f"DONE {t['name'][:60]}: all files imported ({len(to_import)} new, {already} already present); torrent removed")
    elif pending:
        log(f"WAIT {t['name'][:60]}: {len(pending)} files not yet in library; torrent kept")
    else:
        log(f"KEEP {t['name'][:60]}: {len(unresolved)} unresolved files need a look; torrent kept")


def main():
    torrents = [t for c in ("pokemon-manual", "manual-import") for t in qbit(f"/torrents/info?category={c}")]
    torrents.sort(key=lambda t: -t.get("num_complete", 0))  # overlapping packs: best-seeded claims episodes first
    for t in torrents:
        try:
            process(t)
        except Exception as e:
            log(f"ERROR {t['name'][:60]}: {e!r}")


if __name__ == "__main__":
    main()
