#!/usr/bin/env python3
"""Live dashboard for the media compression batch.

Serves a polling web page at http://<host>:8800/ showing:
  - summary cards: progress, space reclaimed (exact), projected total savings,
    drive free
  - the live encode (frame, fps, speed, %, ETA, tier, quality)
  - the full plan as a FILTERABLE / SEARCHABLE / SORTABLE table
    (status chips, name search, sort by name/size/saved/reduction)
  - per-file original/new/saved/reduction for completed items

Reads only the batch's state files; it never touches media.

Savings are computed EXACTLY where possible: original bytes come from plan.tsv,
new bytes from the replaced file on disk (done in-place). Falls back to the
human-rounded values scraped from ruby.log when a file's plan entry has
already been rewritten to DONE by a monthly rescan.
"""
import json, os, re, subprocess, time
import hmac, hashlib, base64, secrets as _secrets, ctypes, ctypes.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.cookies import SimpleCookie
from urllib.parse import parse_qs

BASE = "/home/naboo/ruby"
STATE = os.path.join(BASE, "state")
PLAN = os.path.join(STATE, "plan.tsv")
DONE = os.path.join(STATE, "done.list")
FAIL = os.path.join(STATE, "failed.list")
# Durable per-file conversion stats written by ruby.sh at DONE time. Authoritative
# for original size + savings (survives plan.tsv rescans, which otherwise re-probe a
# converted file at its now-compressed size and lose the original).
CONVERTED = os.path.join(STATE, "converted.tsv")
LOG = os.path.join(BASE, "ruby.log")
CUR_JSON = os.path.join(STATE, "current.json")
CUR_PROG = os.path.join(STATE, "current.progress")
DRIVE = "/mnt/disks/16TBSeagate"
PORT = 8800

UNIT = {"B": 1, "KB": 1024, "MB": 1024**2, "GB": 1024**3, "TB": 1024**4, "PB": 1024**5}

CONF = os.path.join(BASE, "ruby.conf")
SECRETS = "/root/media-stack/homeassistant/secrets.yaml"
PLEX = "http://127.0.0.1:32400"

# Web-editable settings -> each maps 1:1 to a ruby.sh env var (ruby.sh sources ruby.conf).
# (key, kind, default, label)
CONFIG_SPEC = [
    ("SCAN_MIN_MB",    "int",  500,          "Scan floor (MB) — ignore files smaller than this"),
    ("PLEX_LIB_TYPES", "str",  "movie show", "Libraries to optimise (space-separated: e.g. 'movie show')"),
    ("Q_4K",           "int",  24,           "4K quality target (lower = better & larger)"),
    ("Q_1080",         "int",  23,           "1080p quality target (lower = better & larger)"),
    ("MIN_MBPS_4K",    "int",  28,           "Only shrink 4K above this bitrate (Mbps)"),
    ("MIN_MBPS_1080",  "int",  18,           "Only shrink 1080p above this bitrate (Mbps)"),
    ("ADD_AC3",        "bool", 1,            "Add Dolby Digital 5.1 when no TV-friendly audio"),
    ("ADD_AAC",        "bool", 1,            "Add AAC 2.0 stereo when no TV-friendly audio"),
    ("BAD_VIDEO",      "str",  "vc1 mpeg2video av1 mpeg4 msmpeg4v3 wmv3 vp6f vp6 rv40",
                                             "Video codecs to force to HEVC (space-separated)"),
    ("GOV_ENABLED",    "bool", 1,            "iGPU governor: back Ruby off when Plex is active and the iGPU is saturated"),
    ("GOV_GPU_MAX",    "int",  95,           "Back off Ruby when iGPU busy % exceeds this (only while Plex is active)"),
    ("GOV_POLL_SEC",   "int",  5,            "Governor iGPU poll interval (seconds)"),
    ("GOV_MIN_PCT",    "int",  10,           "Lowest Ruby capacity % the governor will throttle down to"),
    ("GOV_NICE_IDLE",  "int",  0,            "CPU priority for Ruby when Plex is idle (0=full juice, 10=gentle)"),
]
CONFIG_DEFAULTS = {k: d for k, _, d, _ in CONFIG_SPEC}
CONFIG_KIND = {k: t for k, t, _, _ in CONFIG_SPEC}


def read_config():
    """Effective settings = defaults overridden by ruby.conf (KEY=value / KEY=\"value\")."""
    vals = dict(CONFIG_DEFAULTS)
    try:
        with open(CONF) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip(); v = v.strip().strip('"').strip("'")
                if k not in CONFIG_KIND:
                    continue
                if CONFIG_KIND[k] in ("int", "bool"):
                    try: vals[k] = int(v)
                    except ValueError: pass
                else:
                    vals[k] = v
    except OSError:
        pass
    return vals


def write_config(new):
    """Merge known keys into ruby.conf (shell-safe, atomic). Returns effective dict."""
    cur = read_config()
    for k, v in (new or {}).items():
        if k not in CONFIG_KIND:
            continue
        if CONFIG_KIND[k] in ("int", "bool"):
            try: cur[k] = int(v)
            except (ValueError, TypeError): continue
        else:
            cur[k] = str(v)
    lines = ["# Ruby - Plex Optimiser settings — written by the web dashboard. Edit via :8800.\n"]
    for k, _, _, _ in CONFIG_SPEC:
        v = cur[k]
        if CONFIG_KIND[k] == "str":
            lines.append('%s="%s"\n' % (k, str(v).replace('"', "")))
        else:
            lines.append('%s=%d\n' % (k, int(v)))
    tmp = CONF + ".tmp"
    with open(tmp, "w") as f:
        f.writelines(lines)
    os.replace(tmp, CONF)
    return cur


def plex_token():
    try:
        with open(SECRETS) as f:
            for line in f:
                if "plex_token:" in line:
                    return line.split("plex_token:", 1)[1].strip().strip('"').strip("'")
    except OSError:
        pass
    return ""


_lib_cache = {"t": 0.0, "v": []}
def plex_libraries():
    """Discover Plex libraries (cached 60s) -> [{key,type,title,path,realpath}]."""
    now = time.time()
    if now - _lib_cache["t"] < 60 and _lib_cache["v"]:
        return _lib_cache["v"]
    tok = plex_token(); libs = []
    if tok:
        try:
            import urllib.request, xml.etree.ElementTree as ET
            raw = urllib.request.urlopen(
                "%s/library/sections?X-Plex-Token=%s" % (PLEX, tok), timeout=5).read()
            for d in ET.fromstring(raw).findall("Directory"):
                for loc in d.findall("Location"):
                    p = loc.get("path")
                    if p:
                        libs.append({"key": d.get("key"), "type": d.get("type"),
                                     "title": d.get("title"), "path": p,
                                     "realpath": os.path.realpath(p)})
        except Exception:
            libs = []
    _lib_cache["t"] = now; _lib_cache["v"] = libs
    return libs


def restart_ruby():
    try:
        subprocess.run(["systemctl", "restart", "ruby.service"], timeout=20,
                       capture_output=True)
        return True
    except Exception:
        return False


def plex_sessions():
    """Active Plex playback -> {streams, transcodes, ok}. Transcodes share the iGPU
    with Ruby, so the governor pauses Ruby whenever Plex is streaming."""
    tok = plex_token()
    if not tok:
        return {"streams": 0, "transcodes": 0, "ok": False}
    try:
        import urllib.request, xml.etree.ElementTree as ET
        raw = urllib.request.urlopen(
            "%s/status/sessions?X-Plex-Token=%s" % (PLEX, tok), timeout=4).read()
        root = ET.fromstring(raw)
        streams = trans = 0
        for el in list(root):
            if el.tag not in ("Video", "Track", "Photo"):
                continue
            streams += 1
            for ts in el.findall("TranscodeSession"):
                if ts.get("videoDecision") == "transcode" or ts.get("audioDecision") == "transcode":
                    trans += 1
                    break
        return {"streams": streams, "transcodes": trans, "ok": True}
    except Exception:
        return {"streams": 0, "transcodes": 0, "ok": False}


_cpu_prev = {"idle": 0, "total": 0}
def host_stats():
    s = {"cores": os.cpu_count()}
    try: s["load1"] = round(os.getloadavg()[0], 2)
    except Exception: s["load1"] = None
    try:
        with open("/proc/stat") as f:
            n = list(map(int, f.readline().split()[1:]))
        idle = n[3] + (n[4] if len(n) > 4 else 0); total = sum(n)
        di, dt = idle - _cpu_prev["idle"], total - _cpu_prev["total"]
        s["cpu"] = round((1 - di / dt) * 100, 1) if dt > 0 and _cpu_prev["total"] else None
        _cpu_prev["idle"], _cpu_prev["total"] = idle, total
    except Exception: s["cpu"] = None
    try:
        mem = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k = line.split(":")[0]; mem[k] = int(line.split()[1])
        tot, av = mem.get("MemTotal", 0), mem.get("MemAvailable", 0)
        s["mem"] = round((1 - av / tot) * 100, 1) if tot else None
        s["mem_used_h"] = human((tot - av) * 1024); s["mem_total_h"] = human(tot * 1024)
    except Exception: s["mem"] = None
    s["temp"] = None
    try:
        for z in ("/sys/class/thermal/thermal_zone0/temp", "/sys/class/thermal/thermal_zone1/temp"):
            if os.path.exists(z):
                s["temp"] = round(int(open(z).read()) / 1000, 1); break
    except Exception: pass
    return s


def governor_state():
    try:
        with open(os.path.join(STATE, "governor.json")) as f:
            return json.load(f)
    except Exception:
        return {}


def system_status():
    return {"host": host_stats(), "plex": plex_sessions(),
            "governor": governor_state(), "disks": disk_stats()}


_music_cache = {"t": 0.0, "k": None, "v": {}}
def music_counts(root):
    """Count audio files in a music library (cached 30s)."""
    now = time.time()
    if now - _music_cache["t"] < 30 and _music_cache["k"] == root:
        return _music_cache["v"]
    LOSSLESS = {".flac", ".wav", ".ape", ".wv", ".tak", ".tta", ".aiff", ".aif", ".alac"}
    LOSSY = {".mp3", ".m4a", ".aac", ".opus", ".ogg", ".wma", ".mpc"}
    tracks = ll = ly = 0
    try:
        for d, _, fs in os.walk(root):
            for f in fs:
                e = os.path.splitext(f)[1].lower()
                if e in LOSSLESS: tracks += 1; ll += 1
                elif e in LOSSY: tracks += 1; ly += 1
    except Exception:
        pass
    v = {"tracks": tracks, "lossless": ll, "lossy": ly}
    _music_cache.update(t=now, k=root, v=v)
    return v


def music_status():
    """Per-track good/needs-work summary written by the music pass (ruby-music.sh)."""
    try:
        with open(os.path.join(STATE, "music-status.json")) as f:
            return json.load(f)
    except Exception:
        return None


# ============================ authentication =================================
# Login with a SYSTEM account (PAM). Dashboard runs as root, so PAM/pam_unix can
# verify any local user's password (any hash: sha512/yescrypt/…) and honour
# account locking/expiry. Session = HMAC-signed cookie; secret persists so a
# dashboard restart (e.g. on settings-save) doesn't log you out.
SECRET_FILE = os.path.join(BASE, ".session_secret")
SESSION_TTL = 7 * 24 * 3600
COOKIE = "ruby_sess"
PAM_SERVICE = "ruby-dashboard"

def _session_secret():
    try:
        with open(SECRET_FILE, "rb") as f:
            s = f.read()
        if len(s) >= 16:
            return s
    except OSError:
        pass
    s = _secrets.token_bytes(32)
    try:
        with open(SECRET_FILE, "wb") as f:
            f.write(s)
        os.chmod(SECRET_FILE, 0o600)
    except OSError:
        pass
    return s

SECRET = _session_secret()

def make_token(user):
    msg = "%s|%d" % (user, int(time.time()) + SESSION_TTL)
    sig = hmac.new(SECRET, msg.encode(), hashlib.sha256).hexdigest()
    return base64.urlsafe_b64encode((msg + "|" + sig).encode()).decode()

def check_token(tok):
    try:
        raw = base64.urlsafe_b64decode(tok.encode()).decode()
        user, exp, sig = raw.rsplit("|", 2)
        good = hmac.new(SECRET, ("%s|%s" % (user, exp)).encode(), hashlib.sha256).hexdigest()
        if hmac.compare_digest(good, sig) and int(exp) >= time.time():
            return user
    except Exception:
        pass
    return None

# --- minimal ctypes libpam wrapper (no third-party deps) ---
try:
    _LIBPAM = ctypes.CDLL(ctypes.util.find_library("pam") or "libpam.so.0")
    _LIBC = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6")
    _calloc = _LIBC.calloc; _calloc.restype = ctypes.c_void_p
    _calloc.argtypes = [ctypes.c_size_t, ctypes.c_size_t]
    _PAM_ECHO_OFF, _PAM_OK = 1, 0
    class _Handle(ctypes.Structure):
        _fields_ = [("h", ctypes.c_void_p)]
    class _Msg(ctypes.Structure):
        _fields_ = [("msg_style", ctypes.c_int), ("msg", ctypes.c_char_p)]
    class _Resp(ctypes.Structure):
        _fields_ = [("resp", ctypes.c_char_p), ("resp_retcode", ctypes.c_int)]
    _CONV = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int,
        ctypes.POINTER(ctypes.POINTER(_Msg)),
        ctypes.POINTER(ctypes.POINTER(_Resp)), ctypes.c_void_p)
    class _Conv(ctypes.Structure):
        _fields_ = [("conv", _CONV), ("appdata_ptr", ctypes.c_void_p)]
    _start = _LIBPAM.pam_start; _start.restype = ctypes.c_int
    _start.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(_Conv), ctypes.POINTER(_Handle)]
    _authc = _LIBPAM.pam_authenticate; _authc.restype = ctypes.c_int
    _authc.argtypes = [_Handle, ctypes.c_int]
    _acct = _LIBPAM.pam_acct_mgmt; _acct.restype = ctypes.c_int
    _acct.argtypes = [_Handle, ctypes.c_int]
    _endp = _LIBPAM.pam_end; _endp.restype = ctypes.c_int
    _endp.argtypes = [_Handle, ctypes.c_int]
except Exception:
    _LIBPAM = None

def pam_auth(username, password):
    if not _LIBPAM or not username or password is None:
        return False
    pw = password.encode()
    @_CONV
    def conv_cb(n, messages, p_response, app_data):
        buf = _calloc(n, ctypes.sizeof(_Resp))
        p_response[0] = ctypes.cast(buf, ctypes.POINTER(_Resp))
        for i in range(n):
            if messages[i].contents.msg_style == _PAM_ECHO_OFF:
                dst = _calloc(len(pw) + 1, 1)
                ctypes.memmove(dst, pw, len(pw))
                p_response[0][i].resp = ctypes.cast(dst, ctypes.c_char_p)
                p_response[0][i].resp_retcode = 0
        return 0
    handle = _Handle()
    conv_struct = _Conv(conv_cb, 0)
    if _start(PAM_SERVICE.encode(), username.encode(), ctypes.byref(conv_struct), ctypes.byref(handle)) != _PAM_OK:
        return False
    ok = _authc(handle, 0) == _PAM_OK
    if ok:
        ok = _acct(handle, 0) == _PAM_OK
    _endp(handle, 0)
    return ok

LOGIN_PAGE = """<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>Ruby · Sign in</title>
<style>body{font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;background:#0f1115;color:#e6e6e6;display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}
.box{background:#161a22;border:1px solid #262c38;border-radius:14px;padding:28px 30px;width:320px}
h1{font-size:22px;margin:0 0 2px}.s{color:#8b95a7;font-size:12px;margin-bottom:18px}
label{display:block;color:#9fb0c3;font-size:12px;margin:12px 0 4px}
input{width:100%;box-sizing:border-box;background:#0f1115;border:1px solid #262c38;border-radius:8px;color:#e6e6e6;padding:9px 11px;font-size:14px}
button{width:100%;margin-top:20px;background:#e0234e;border:0;border-radius:8px;color:#fff;padding:10px;font-weight:600;font-size:14px;cursor:pointer}
.err{color:#ff8b8b;font-size:12px;margin-top:12px;min-height:14px;text-align:center}</style></head><body>
<form class=box method=post action=/login>
<h1>💎 Ruby</h1><div class=s>Plex Optimiser — sign in with your system account</div>
<label>Username</label><input name=username autofocus autocomplete=username>
<label>Password</label><input name=password type=password autocomplete=current-password>
<button>Sign in</button><div class=err>%ERR%</div>
</form></body></html>"""


def human(n):
    n = float(n or 0)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024:
            return f"{n:.1f} {u}"
        n /= 1024
    return f"{n:.1f} PB"


def to_bytes(val, unit):
    return float(val) * UNIT.get(unit.upper(), 1)


def read_lines(p):
    try:
        with open(p) as f:
            return [l.rstrip("\n") for l in f if l.strip()]
    except OSError:
        return []


def parse_progress():
    """Tail ffmpeg -progress key=val output -> dict of the latest block."""
    d = {}
    try:
        with open(CUR_PROG) as f:
            for line in f.read().splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    d[k] = v
    except OSError:
        pass
    return d


def batch_running():
    return subprocess.run(["pgrep", "-f", "ruby.sh"],
                          capture_output=True).returncode == 0


def encoder_running():
    return subprocess.run(["pgrep", "-f", "hevc_vaapi"],
                          capture_output=True).returncode == 0


def drive_free():
    try:
        s = os.statvfs(DRIVE)
        return s.f_bavail * s.f_frsize, s.f_blocks * s.f_frsize
    except OSError:
        return 0, 0


# Disks shown as usage graphs under "Server hardware": the two media drives + the
# NVMe system disk (holds Ruby scratch/pending, downloads, and the music library).
DISKS = [
    ("Movies · 16TB", "/mnt/disks/16TBSeagate"),
    ("Shows · 5TB", "/mnt/disks/5TBSeagate"),
    ("NVMe · system", "/"),
]
def disk_stats():
    out = []
    for label, path in DISKS:
        try:
            s = os.statvfs(path)
        except OSError:
            continue
        total = s.f_blocks * s.f_frsize
        free = s.f_bavail * s.f_frsize
        used = total - free
        if not total:
            continue
        out.append({
            "label": label, "pct": round(used / total * 100, 1),
            "used_h": human(used), "total_h": human(total), "free_h": human(free),
        })
    return out


def scratch_size(base):
    if not base:
        return 0
    stem = base.rsplit(".", 1)[0]
    p = os.path.join(BASE, "scratch", stem + ".hevc.mkv")
    try:
        return os.path.getsize(p)
    except OSError:
        return 0


# "[2026-06-28 09:22:31] DONE: <name> 18GB -> 16GB saved 1.1GB (94%)"
DONE_RE = re.compile(
    r"\[([\d :-]+)\] DONE: (.+?) ([\d.]+)([KMGTP]?B) -> ([\d.]+)([KMGTP]?B) "
    r"saved ([\d.]+)([KMGTP]?B) \((\d+)%\)")


def parse_log_done():
    """Return {name: {ts, orig, new, saved, retained_pct}} from ruby.log."""
    out = {}
    for l in read_lines(LOG):
        m = DONE_RE.search(l)
        if not m:
            continue
        ts, name, ov, ou, nv, nu, sv, su, pct = m.groups()
        out[name] = {
            "ts": ts,
            "orig": to_bytes(ov, ou),
            "new": to_bytes(nv, nu),
            "saved": to_bytes(sv, su),
            "retained_pct": int(pct),
        }
    return out


def parse_converted():
    """Durable per-file stats from converted.tsv, keyed by dest path.
    Row: ts<TAB>mode<TAB>orig<TAB>new<TAB>delta<TAB>dest."""
    out = {}
    for l in read_lines(CONVERTED):
        p = l.split("\t")
        if len(p) < 6:
            continue
        dest = "\t".join(p[5:])
        try:
            out[dest] = {"ts": p[0], "mode": p[1],
                         "orig": int(p[2]), "new": int(p[3]), "saved": int(p[4])}
        except ValueError:
            continue
    return out


def tier_of(detail):
    if "4K" in detail or "2160" in detail:
        return "4K"
    if "1080" in detail:
        return "1080p"
    if "720" in detail:
        return "720p"
    return ""


def build_status():
    done_set = set(read_lines(DONE))
    fail_set = set(read_lines(FAIL))
    log_done = parse_log_done()
    conv = parse_converted()   # durable orig/new/saved, keyed by dest path

    cur = {}
    try:
        with open(CUR_JSON) as f:
            cur = json.load(f)
    except (OSError, ValueError):
        cur = {}
    cur_src = cur.get("src", "")

    # exact original sizes by path, from the plan
    plan_size = {}
    plan_rows = []
    for line in read_lines(PLAN):
        parts = line.split("\t")
        if len(parts) != 4:
            continue
        decision, detail, size, path = parts
        try:
            size = int(size or 0)
        except ValueError:
            size = 0
        plan_size[path] = size
        plan_rows.append((decision, detail, size, path))

    files = []
    reclaimed = 0          # exact bytes saved across done files
    orig_done = 0          # exact original bytes of done files
    new_done = 0           # exact new bytes of done files
    queued_orig = 0        # original bytes still queued
    ratios = []            # new/orig per done file (for projection)

    for decision, detail, size, path in plan_rows:
        base = os.path.basename(path)
        stem = base.rsplit(".", 1)[0]
        dest = os.path.join(os.path.dirname(path), stem + ".mkv")
        is_done = dest in done_set or path in done_set or decision == "DONE"
        is_fail = path in fail_set
        is_cur = path == cur_src and not is_done

        row = {
            "name": base, "tier": tier_of(detail),
            "size": size, "size_h": human(size),
            "new_size": None, "new_h": "", "saved": None, "saved_h": "",
            "reduction": None, "quality": "", "info": detail,
        }

        if is_cur:
            row["status"] = "converting"
            row["info"] = "in progress"
            row["quality"] = cur.get("quality", "")
            if cur.get("tier"):
                row["tier"] = cur["tier"]
        elif is_done:
            row["status"] = "done"
            row["info"] = "completed"
            # exact: orig from plan, new from disk
            new_b = None
            try:
                new_b = os.path.getsize(dest)
            except OSError:
                try:
                    new_b = os.path.getsize(path)
                except OSError:
                    new_b = None
            orig_b = size if decision != "DONE" else None
            cv = conv.get(dest) or conv.get(path)
            if cv:                 # durable stats win: exact original captured at conversion time
                orig_b = cv["orig"]
                if new_b is None:
                    new_b = cv["new"]
            lg = log_done.get(base)
            if (orig_b is None or new_b is None) and lg:
                orig_b = orig_b if orig_b else lg["orig"]
                new_b = new_b if new_b else lg["new"]
            if orig_b and new_b and new_b <= orig_b:
                saved_b = orig_b - new_b
                row.update(new_size=new_b, new_h=human(new_b),
                           saved=saved_b, saved_h=human(saved_b),
                           reduction=round(saved_b / orig_b * 100, 1),
                           size=orig_b, size_h=human(orig_b))
                reclaimed += saved_b
                orig_done += orig_b
                new_done += new_b
                ratios.append(new_b / orig_b)
            elif lg:
                row.update(new_size=lg["new"], new_h=human(lg["new"]),
                           saved=lg["saved"], saved_h=human(lg["saved"]),
                           reduction=round(lg["saved"] / lg["orig"] * 100, 1)
                           if lg["orig"] else None)
                reclaimed += lg["saved"]
                orig_done += lg["orig"]
                new_done += lg["new"]
                if lg["orig"]:
                    ratios.append(lg["new"] / lg["orig"])
        elif is_fail:
            row["status"] = "failed"
            row["info"] = "see log"
        elif decision == "CONVERT":
            row["status"] = "queued"
            queued_orig += size
        else:
            row["status"] = "skipped"

        files.append(row)

    # --- Authoritative savings + done rows from converted.tsv ---
    # plan.tsv is regenerated (and shrinks) on every rescan and may no longer list
    # already-converted files, so NEVER derive all-time savings from it. converted.tsv
    # is the durable per-file record (original size captured at conversion time); sum
    # the totals straight from it and surface any done file the plan no longer shows.
    reclaimed = orig_done = new_done = 0
    ratios = []
    by_name = {r["name"]: r for r in files}
    for dest, cv in conv.items():
        o, n = cv["orig"], cv["new"]
        if not (o and n and n <= o):
            continue
        saved_b = o - n
        reclaimed += saved_b
        orig_done += o
        new_done += n
        ratios.append(n / o)
        name = os.path.basename(dest)
        r = by_name.get(name)
        if r is None:
            r = {"name": name, "tier": tier_of(name), "quality": "", "info": ""}
            files.append(r)
            by_name[name] = r
        r.update(status="done", info="completed",
                 size=o, size_h=human(o), new_size=n, new_h=human(n),
                 saved=saved_b, saved_h=human(saved_b),
                 reduction=round(saved_b / o * 100, 1))

    # current encode progress
    prog = parse_progress()
    cur_out = {}
    if cur_src:
        dur = float(cur.get("duration") or 0)
        # ffmpeg writes out_time_us=N/A at the very start of an encode -> guard the
        # float() (N/A is truthy, so a bare `or 0` fallback never fires).
        def _f(v):
            try:
                return float(v)
            except (TypeError, ValueError):
                return 0.0
        out_us = _f(prog.get("out_time_us")) or _f(prog.get("out_time_ms"))
        out_s = out_us / 1_000_000 if out_us else 0
        pct = min(100, out_s / dur * 100) if dur else 0
        try:
            spd = float(prog.get("speed", "").rstrip("x"))
        except ValueError:
            spd = 0
        eta = (dur - out_s) / spd if spd > 0 and dur else 0
        elapsed = time.time() - float(cur.get("start") or time.time())
        cur_out = {
            "base": cur.get("base", ""), "human": human(cur.get("size", 0)),
            "tier": cur.get("tier", ""), "quality": cur.get("quality", ""),
            "pct": round(pct, 1), "frame": prog.get("frame", "0"),
            "fps": prog.get("fps", "0"), "speed": prog.get("speed", "?"),
            "out_time": time.strftime("%H:%M:%S", time.gmtime(out_s)) if out_s else "00:00:00",
            "dur": time.strftime("%H:%M:%S", time.gmtime(dur)) if dur else "?",
            "eta_min": round(eta / 60, 1) if eta else None,
            "elapsed_min": round(elapsed / 60, 1),
            "scratch_size": human(scratch_size(cur.get("base", ""))),
        }

    n_done = sum(1 for r in files if r["status"] == "done")
    n_queued = sum(1 for r in files if r["status"] == "queued")
    n_conv = sum(1 for r in files if r["status"] == "converting")
    n_fail = sum(1 for r in files if r["status"] == "failed")
    n_skip = sum(1 for r in files if r["status"] == "skipped")
    workload = n_done + n_queued + n_conv

    avg_ratio = sum(ratios) / len(ratios) if ratios else None
    # projected savings on the queued backlog using the observed avg ratio
    projected_remaining = queued_orig * (1 - avg_ratio) if avg_ratio else 0
    projected_total = reclaimed + projected_remaining
    avg_reduction = round((1 - avg_ratio) * 100, 1) if avg_ratio else None

    # ALL Plex libraries: video libs (movie/show) get plan-based direct-play health;
    # music libs get track counts (managed by the Ruby music pass, not the video plan).
    libs = plex_libraries()
    for lib in libs:
        if lib.get("type") in ("movie", "show"):
            rp = lib["realpath"].rstrip("/") + "/"
            d = q = c = sk = fl = 0
            for decision, detail, size, path in plan_rows:
                if not path.startswith(rp):
                    continue
                base = os.path.basename(path); stem = base.rsplit(".", 1)[0]
                dest = os.path.join(os.path.dirname(path), stem + ".mkv")
                if dest in done_set or path in done_set or decision == "DONE": d += 1
                elif path in fail_set: fl += 1
                elif path == cur_src: c += 1
                elif decision == "CONVERT": q += 1
                else: sk += 1
            tot = d + q + c + sk + fl; ready = d + sk
            lib.update(kind="video", total=tot, done=d, queued=q, converting=c, skipped=sk,
                       failed=fl, ready=ready, needs=q + c,
                       health=round(ready / tot * 100, 1) if tot else None)
        else:
            lib.update(kind="music", status=music_status(), **music_counts(lib["realpath"]))

    free, total = drive_free()
    return {
        "batch_running": batch_running(),
        "encoder_running": encoder_running(),
        "current": cur_out,
        "files": files,
        "libraries": libs,
        "system": system_status(),
        "summary": {
            "total": len(files),
            "done": n_done, "queued": n_queued, "converting": n_conv,
            "failed": n_fail, "skipped": n_skip,
            "progress_pct": round(n_done / workload * 100, 1) if workload else 0,
            "reclaimed": reclaimed, "reclaimed_h": human(reclaimed),
            "orig_done_h": human(orig_done), "new_done_h": human(new_done),
            "avg_reduction": avg_reduction,
            "queued_orig_h": human(queued_orig),
            "projected_remaining_h": human(projected_remaining),
            "projected_total": projected_total,
            "projected_total_h": human(projected_total),
            "drive_free": human(free), "drive_total": human(total),
            "drive_pct": round((total - free) / total * 100, 1) if total else 0,
        },
        "ts": int(time.time()),
    }


PAGE = r"""<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Ruby · Plex Optimiser</title>
<style>
 :root{--bg:#0f1115;--panel:#161a22;--line:#262c38;--line2:#1c212b;--mut:#8b95a7;--accent:#e0234e}
 *{box-sizing:border-box}
 body{font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;margin:0;background:var(--bg);color:#e6e6e6}
 header{padding:14px 22px;background:var(--panel);border-bottom:1px solid var(--line);position:sticky;top:0;z-index:5}
 h1{font-size:17px;margin:0 0 3px} .sub{color:var(--mut);font-size:12px}
 .wrap{padding:18px 22px;max-width:none;margin:0 auto}
 .layout{display:grid;grid-template-columns:1fr 2fr;gap:18px;align-items:start}
 .left{display:flex;flex-direction:column;gap:12px;min-width:0}
 .right{min-width:0}
 @media(max-width:980px){.layout{grid-template-columns:1fr}}
 .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px}
 .card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px 16px}
 .card .n{font-size:22px;font-weight:600} .card .n small{font-size:13px;color:var(--mut);font-weight:400}
 .card .l{color:var(--mut);font-size:11px;text-transform:uppercase;letter-spacing:.04em;margin-top:2px}
 .card.hl{background:#10241d;border-color:#1d4d3c}
 .card.hl .n{color:#2bd47a}
 .pbar{height:10px;background:#0c151c;border-radius:6px;overflow:hidden;margin-top:6px}
 .pbar>i{display:block;height:100%;background:linear-gradient(90deg,#2bd4a8,#1f9bd1);width:0;transition:width .6s}
 .cur{background:#13202b;border:1px solid #1d3a4d;border-radius:12px;padding:16px 18px;margin-bottom:20px}
 .bar{height:18px;background:#0c151c;border-radius:9px;overflow:hidden;margin:8px 0}
 .bar>i{display:block;height:100%;background:linear-gradient(90deg,#2bd4a8,#1f9bd1);width:0;transition:width .6s}
 .row{display:flex;gap:18px;flex-wrap:wrap;color:#9fb0c3;font-size:12px}
 .toolbar{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-bottom:10px}
 .chips{display:flex;gap:6px;flex-wrap:wrap}
 .chip{font-size:12px;padding:4px 11px;border-radius:20px;border:1px solid var(--line);background:var(--panel);color:#c6cfdd;cursor:pointer;user-select:none}
 .chip.on{background:#1f9bd1;border-color:#1f9bd1;color:#04121b;font-weight:600}
 .chip .c{opacity:.7;margin-left:4px}
 input[type=search]{flex:1;min-width:180px;background:var(--panel);border:1px solid var(--line);border-radius:8px;color:#e6e6e6;padding:7px 11px;font-size:13px}
 select{background:var(--panel);border:1px solid var(--line);border-radius:8px;color:#e6e6e6;padding:7px 9px;font-size:13px}
 table{width:100%;border-collapse:collapse;font-size:13px}
 th{text-align:left;color:var(--mut);font-weight:500;padding:7px 8px;border-bottom:1px solid var(--line);font-size:11px;text-transform:uppercase;cursor:pointer;white-space:nowrap}
 th.num,td.num{text-align:right}
 td{padding:6px 8px;border-bottom:1px solid var(--line2);vertical-align:top}
 tr:hover td{background:#141923}
 .tag{font-size:11px;padding:2px 8px;border-radius:20px;font-weight:600}
 .converting{background:#13384a;color:#5fd0ff} .queued{background:#2a2f3a;color:#c6cfdd}
 .done{background:#16341f;color:#6fe39a} .skipped{background:#2a2620;color:#caa86b} .failed{background:#3a1a1a;color:#ff8b8b}
 .tier{font-size:10px;color:var(--mut);border:1px solid var(--line);border-radius:4px;padding:1px 5px;margin-left:6px}
 .save{color:#6fe39a} .red{color:#9fb0c3;font-size:12px}
 .dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px}
 .on{background:#2bd47a}.off{background:#ff6b6b}
 .muted{color:#6b7588} .count{color:var(--mut);font-size:12px;margin-left:auto}
 .sech{color:var(--mut);font-size:11px;text-transform:uppercase;letter-spacing:.05em;margin:16px 0 8px}
 .libs{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:12px;margin-bottom:6px}
 .lib{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px 16px}
 .libtop{display:flex;gap:8px;align-items:baseline;flex-wrap:wrap;margin-bottom:6px}
 .libtop b{font-size:15px}
 .gov{display:flex;gap:18px;flex-wrap:wrap;align-items:center;background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px 16px;margin-bottom:6px}
 .gov .big{font-size:15px;font-weight:600}
 .pill{font-size:12px;padding:3px 10px;border-radius:20px;font-weight:600}
 .pill.run{background:#16341f;color:#6fe39a} .pill.pause{background:#3a2e14;color:#ffcf6b} .pill.wait{background:#3a1a1a;color:#ff8b8b} .pill.off{background:#2a2f3a;color:#c6cfdd}
 .settings{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:8px 16px;margin-bottom:8px}
 .settings summary{cursor:pointer;color:#c6cfdd;font-weight:600;padding:4px 0}
 .setrow{display:flex;gap:12px;align-items:center;margin:9px 0;flex-wrap:wrap}
 .setrow>span.lbl{flex:1;min-width:300px;color:#9fb0c3}
 .setrow input[type=text]{background:var(--bg);border:1px solid var(--line);border-radius:6px;color:#e6e6e6;padding:6px 9px;min-width:150px}
 button{background:var(--accent);border:0;border-radius:8px;color:#fff;padding:8px 16px;font-weight:600;cursor:pointer}
 button.ctrl{padding:4px 12px;font-size:12px;border-radius:7px;margin-left:6px}
 button.ctrl.alt{background:#2b3242;color:#e6e6e6}
 button:hover{filter:brightness(1.1)}
 /* keep the wide data table inside its own horizontal scroll instead of blowing out the page */
 .tablewrap{overflow-x:auto;-webkit-overflow-scrolling:touch;border-radius:8px}
 /* ---- phones / small screens ---- */
 @media(max-width:600px){
  .wrap{padding:12px 12px}
  header{padding:12px 14px}
  h1{font-size:16px}
  .cur{font-size:13px}
  .cards{grid-template-columns:repeat(auto-fit,minmax(104px,1fr));gap:8px}
  .card{padding:11px 12px}
  .card .n{font-size:18px}
  .syscards .card .n,#syscards .card .n{font-size:16px}
  .libs{grid-template-columns:1fr}
  .gov{gap:10px 16px;padding:10px 12px}
  /* stack the toolbar: full-width search + sort, wrap chips */
  .toolbar{gap:8px}
  input[type=search]{flex:1 1 100%;min-width:0;padding:9px 11px}
  select{flex:1 1 100%}
  .count{margin-left:0}
  /* larger touch targets */
  .chip{padding:7px 13px;font-size:13px}
  button.ctrl{padding:6px 12px}
  /* table: tighter cells, hide the low-value Info column (still scrollable) */
  table{font-size:12px}
  th,td{padding:6px 7px}
  th.info,td.info{display:none}
  .tier{display:inline-block;margin-left:0;margin-top:2px}
 }
 @media(max-width:380px){
  .cards{grid-template-columns:1fr 1fr}
 }
</style></head><body>
<header><h1>💎 Ruby <span style="color:var(--mut);font-weight:400">— Plex Optimiser</span></h1>
<div class=sub>by Andrew Marsh &nbsp;·&nbsp; <span id=live></span> &nbsp;·&nbsp; auto-refresh 3s &nbsp;·&nbsp; <span id=ts></span>
<button id=btnpause class=ctrl>⏸ Pause</button><button id=btnrefresh class="ctrl alt">↻ Rescan</button><span id=ctrlmsg class=muted></span>
&nbsp;·&nbsp; <span id=who></span><a href="/logout" style="color:var(--accent)">logout</a></div></header>
<div class=wrap>
 <div class=cur id=cur></div>
 <div class=layout>
  <div class=left>
   <div class=cards id=cards></div>
   <div class=sech>Server hardware</div>
   <div class="cards" id=syscards></div>
   <div class=sech>Plex libraries — Ruby health</div>
   <div class=libs id=libs></div>
 <details class=settings id=settingsbox>
  <summary>⚙️ Settings — tune Ruby &amp; the Plex-first governor</summary>
  <div id=settings></div>
  <div class=setrow style="border-top:1px solid var(--line);padding-top:10px;margin-top:6px">
   <label><input type=checkbox id=setrestart checked> apply now (restart Ruby — a mid-file encode restarts; original is safe)</label>
   <button id=savebtn>Save settings</button>
   <span id=savemsg class=muted></span>
  </div>
 </details>
  </div>
  <div class=right>
 <div class=toolbar>
  <div class=chips id=chips></div>
  <input type=search id=q placeholder="Search filename…">
  <select id=sort>
   <option value=name>Sort: Name</option>
   <option value=size>Sort: Original size</option>
   <option value=saved>Sort: Space saved</option>
   <option value=reduction>Sort: Reduction %</option>
   <option value=status>Sort: Status</option>
  </select>
  <span class=count id=count></span>
 </div>
 <div class=tablewrap>
 <table>
  <thead><tr>
   <th data-s=status>Status</th><th data-s=name>File</th>
   <th class=num data-s=size>Original</th><th class=num data-s=saved>New</th>
   <th class=num data-s=saved>Saved</th><th class=num data-s=reduction>Reduction</th>
   <th class=info>Info</th>
  </tr></thead>
  <tbody id=rows></tbody>
 </table>
 </div>
  </div>
 </div>
</div>
<script>
const STAT=["converting","queued","done","skipped","failed"];
let filter=new Set(["converting","queued","done","failed"]); // skipped hidden by default
let data=null, sortKey="status", sortDir=1;
function esc(s){return (s||'').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
const order={converting:0,queued:1,failed:2,done:3,skipped:4};

function render(){
 if(!data) return;
 const s=data.summary;
 document.getElementById('live').innerHTML=
  `<span class="dot ${data.batch_running?'on':'off'}"></span>batch ${data.batch_running?'running':'stopped'}`+
  ` &nbsp; <span class="dot ${data.encoder_running?'on':'off'}"></span>encoder ${data.encoder_running?'active':'idle'}`;
 document.getElementById('ts').textContent='updated '+new Date(data.ts*1000).toLocaleTimeString();
 {const bp=document.getElementById('btnpause'); if(bp){bp.dataset.run=data.batch_running?'1':'0'; bp.textContent=data.batch_running?'⏸ Pause':'▶ Play';}}

 document.getElementById('cards').innerHTML=
  `<div class=card><div class=n>${s.progress_pct}<small>%</small></div><div class=l>Progress (${s.done}/${s.done+s.queued+s.converting})</div><div class=pbar><i style="width:${s.progress_pct}%"></i></div></div>`+
  `<div class="card hl"><div class=n>${s.reclaimed_h}</div><div class=l>Space reclaimed</div></div>`+
  `<div class="card hl"><div class=n>${s.projected_total_h}</div><div class=l>Projected total savings</div></div>`+
  `<div class=card><div class=n>${s.avg_reduction!=null?s.avg_reduction+'<small>%</small>':'—'}</div><div class=l>Avg reduction</div></div>`+
  `<div class=card><div class=n>${s.queued_orig_h}</div><div class=l>Queued backlog</div></div>`+
  `<div class=card><div class=n>${s.drive_free}<small> / ${s.drive_total}</small></div><div class=l>Drive free (${s.drive_pct}% used)</div></div>`;

 const c=data.current, cd=document.getElementById('cur');
 if(c&&c.base){
  cd.style.display='block';
  cd.innerHTML=`<b>Now encoding:</b> ${esc(c.base)} <span class=muted>(${c.human})</span>`+
   `${c.tier?`<span class=tier>${esc(c.tier)} ${esc(c.quality||'')}</span>`:''}`+
   `<div class=bar><i style="width:${c.pct}%"></i></div>`+
   `<div class=row><span>${c.pct}% &nbsp; ${c.out_time}/${c.dur}</span><span>fps ${c.fps}</span>`+
   `<span>speed ${c.speed}</span><span>frame ${c.frame}</span><span>elapsed ${c.elapsed_min}m</span>`+
   `<span>${c.eta_min!=null?'eta ~'+c.eta_min+'m':''}</span><span>output ${c.scratch_size}</span></div>`;
 } else cd.style.display='none';

 // server hardware as individual stat cards
 const sys=data.system||{}, h=sys.host||{}, px=sys.plex||{}, gv=sys.governor||{};
 const sev=(v,y,r)=> (v==null||v<0)?'#1f9bd1':(v>=r?'#ff6b6b':(v>=y?'#e0b33a':'#2bd47a'));
 const card=(val,unit,label,bar,col)=>`<div class=card><div class=n>${val}${unit?`<small>${unit}</small>`:''}</div><div class=l>${label}</div>`+(bar!=null?`<div class=pbar><i style="width:${Math.max(0,Math.min(100,bar))}%;background:${col}"></i></div>`:'')+`</div>`;
 const gpu=gv.gpu_busy, tgt=gv.target_pct, gpok=(gpu!=null&&gpu>=0);
 const govval=gv.enabled===false?'off':(tgt!=null?tgt+'%':'—');
 const govlbl=gv.enabled===false?'Governor off':((tgt!=null&&tgt<100)?'Ruby throttled (Plex first)':'Ruby full speed');
 document.getElementById('syscards').innerHTML=
  card(h.cpu!=null?h.cpu:'—','%','CPU',h.cpu!=null?h.cpu:null,sev(h.cpu,60,85))+
  card(gpok?gpu:'—','%','iGPU',gpok?gpu:null,sev(gpok?gpu:null,70,90))+
  card(h.mem!=null?h.mem:'—','%',`RAM ${h.mem_used_h||''} / ${h.mem_total_h||''}`,h.mem!=null?h.mem:null,sev(h.mem,70,90))+
  card(h.temp!=null?h.temp:'—','°C','CPU temp',null,null)+
  card(px.streams||0,'',`Plex streams${px.transcodes?` · ${px.transcodes} transcoding`:''}`,null,null)+
  card(govval,'',govlbl,null,null)+
  (sys.disks||[]).map(d=>card(d.pct!=null?d.pct:'—','%',`${esc(d.label)} · ${d.free_h} free / ${d.total_h}`,d.pct,sev(d.pct,75,90))).join('');

 // per-library health
 const lb=document.getElementById('libs');
 if(data.libraries&&data.libraries.length){
  lb.innerHTML=data.libraries.map(L=>{
   const head=`<div class=libtop><b>${esc(L.title||L.path)}</b>`+
    `<span class=tier>${esc(L.type||'')} · §${esc(String(L.key||''))}</span></div>`+
    `<div class=muted style="font-size:11px;margin:-4px 0 6px">${esc(L.realpath||L.path||'')}</div>`;
   if(L.kind==='music'){
    const s=L.status;
    const tot=s?s.total:(L.tracks||0), good=s?s.good:0;
    const hp=(s&&tot)?Math.round(good/tot*1000)/10:null;
    const col=hp==null?'#8b95a7':(hp>=90?'#2bd47a':hp>=60?'#e0b33a':'#ff6b6b');
    let line = s
      ? `<span style="color:${col};font-weight:600">${hp}% good</span>`+
        `<span style="color:#6fe39a">✓ ${s.good} done</span>`+
        `<span style="color:#e0b33a">⚖ ${s.need_gain} need leveling</span>`+
        (s.need_convert?`<span style="color:#ff8b8b">⤳ ${s.need_convert} need convert</span>`:'')
      : `<span class=muted>analysis pending (music pass runs every 3h)…</span>`;
    return `<div class=lib>${head}`+
     `<div class=pbar><i style="width:${hp||0}%;background:${col}"></i></div>`+
     `<div class=row style="margin-top:6px">${line}`+
     `<span class=muted>🎵 ${L.tracks||0} tracks · ${L.lossless||0} lossless / ${L.lossy||0} lossy</span></div></div>`;
   }
   const hp=L.health, col=hp==null?'#8b95a7':(hp>=90?'#2bd47a':hp>=60?'#e0b33a':'#ff6b6b');
   return `<div class=lib>${head}`+
    `<div class=pbar><i style="width:${hp||0}%;background:${col}"></i></div>`+
    `<div class=row style="margin-top:6px"><span style="color:${col};font-weight:600">${hp==null?'—':hp+'% direct-play ready'}</span>`+
    `<span>${L.total} files</span><span>✓ ${L.done} optimised</span><span>• ${L.skipped} already ok</span>`+
    `<span>⏳ ${L.needs} to do</span>${L.failed?(`<span style="color:#ff8b8b">✗ ${L.failed}</span>`):''}</div></div>`;
  }).join('');
 } else lb.innerHTML='<div class=muted>No libraries discovered yet (waiting on Plex / first plan scan)…</div>';

 // chips with live counts
 const cnt={}; STAT.forEach(k=>cnt[k]=0);
 data.files.forEach(f=>cnt[f.status]=(cnt[f.status]||0)+1);
 document.getElementById('chips').innerHTML=STAT.map(k=>
  `<span class="chip ${filter.has(k)?'on':''}" data-k=${k}>${k}<span class=c>${cnt[k]||0}</span></span>`).join('');
 document.querySelectorAll('.chip').forEach(el=>el.onclick=()=>{
  const k=el.dataset.k; filter.has(k)?filter.delete(k):filter.add(k); render();});

 // filter + search + sort
 const q=document.getElementById('q').value.toLowerCase();
 let rows=data.files.filter(f=>filter.has(f.status) && (!q||f.name.toLowerCase().includes(q)));
 const key=sortKey;
 rows.sort((a,b)=>{
  let r;
  if(key==='name') r=a.name.toLowerCase()<b.name.toLowerCase()?-1:1;
  else if(key==='status') r=(order[a.status]-order[b.status])||(a.name.toLowerCase()<b.name.toLowerCase()?-1:1);
  else r=((a[key]||0)-(b[key]||0));
  return r*sortDir;
 });
 document.getElementById('count').textContent=`${rows.length} shown · ${data.summary.total} total`;
 document.getElementById('rows').innerHTML=rows.map(f=>
  `<tr><td><span class="tag ${f.status}">${f.status}</span></td>`+
  `<td>${esc(f.name)}${f.tier?`<span class=tier>${esc(f.tier)}${f.quality?' '+esc(f.quality):''}</span>`:''}</td>`+
  `<td class=num>${f.size_h}</td>`+
  `<td class=num>${f.new_h||'<span class=muted>—</span>'}</td>`+
  `<td class="num save">${f.saved_h||'<span class=muted>—</span>'}</td>`+
  `<td class=num>${f.reduction!=null?'<span class=red>'+f.reduction+'%</span>':'<span class=muted>—</span>'}</td>`+
  `<td class="muted info">${esc(f.info)}</td></tr>`).join('');
}

// header sort
document.querySelectorAll('th[data-s]').forEach(th=>th.onclick=()=>{
 const k=th.dataset.s;
 if(sortKey===k) sortDir*=-1; else {sortKey=k; sortDir=(k==='name'||k==='status')?1:-1;}
 render();
});
document.getElementById('q').oninput=render;
document.getElementById('sort').onchange=e=>{sortKey=e.target.value;sortDir=(sortKey==='name'||sortKey==='status')?1:-1;render();};

async function loadCfg(){
 try{const r=await(await fetch('/api/config')).json();
  document.getElementById('who').textContent=r.user?(r.user+' · '):'';
  document.getElementById('settings').innerHTML=r.spec.map(s=>{
   const v=r.values[s.key];
   if(s.kind==='bool') return `<label class=setrow><input type=checkbox data-k="${s.key}" ${v?'checked':''}> <span class=lbl>${esc(s.label)}</span></label>`;
   return `<label class=setrow><span class=lbl>${esc(s.label)}</span><input type=text data-k="${s.key}" value="${esc(String(v))}"></label>`;
  }).join('');
 }catch(e){}
}
document.getElementById('savebtn').onclick=async()=>{
 const values={};
 document.querySelectorAll('#settings [data-k]').forEach(el=>{
  values[el.dataset.k]= el.type==='checkbox' ? (el.checked?1:0) : el.value;
 });
 const restart=document.getElementById('setrestart').checked;
 const m=document.getElementById('savemsg'); m.textContent='saving…';
 try{const r=await(await fetch('/api/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({values,restart})})).json();
  m.textContent=r.ok?('✓ saved'+(r.restarted?' · Ruby restarting':' · applies next run')):'error';
 }catch(e){m.textContent='error';}
};
loadCfg();

async function ctrl(action){
 const m=document.getElementById('ctrlmsg');
 m.textContent=' '+({pause:'pausing…',play:'starting…',rescan:'rescanning…'}[action]||'…');
 try{const r=await(await fetch('/api/control',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action})})).json();
  m.textContent=' '+(r.ok?({pause:'paused',play:'started',rescan:'rescan started'}[action]):'error');
 }catch(e){m.textContent=' error';}
 setTimeout(tick,1500);
}
document.getElementById('btnpause').onclick=()=>ctrl(document.getElementById('btnpause').dataset.run==='1'?'pause':'play');
document.getElementById('btnrefresh').onclick=()=>ctrl('rescan');

async function tick(){
 try{data=await (await fetch('/api/status')).json();}catch(e){return}
 render();
}
tick(); setInterval(tick,3000);
</script></body></html>"""


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, body, ctype="application/json", code=200, headers=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or []):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _redirect(self, loc, headers=None):
        self.send_response(303)
        self.send_header("Location", loc)
        self.send_header("Content-Length", "0")
        for k, v in (headers or []):
            self.send_header(k, v)
        self.end_headers()

    def _user(self):
        c = self.headers.get("Cookie")
        if not c:
            return None
        try:
            jar = SimpleCookie(c)
        except Exception:
            return None
        return check_token(jar[COOKIE].value) if COOKIE in jar else None

    def do_GET(self):
        if self.path.startswith("/login"):
            self._send(LOGIN_PAGE.replace("%ERR%", ""), "text/html; charset=utf-8"); return
        if self.path.startswith("/logout"):
            self._redirect("/login", [("Set-Cookie", "%s=; Path=/; Max-Age=0" % COOKIE)]); return
        if not self._user():
            if self.path.startswith("/api/"):
                self._send({"error": "auth required"}, code=401)
            else:
                self._redirect("/login")
            return
        if self.path.startswith("/api/status"):
            self._send(build_status())
        elif self.path.startswith("/api/config"):
            self._send({"values": read_config(), "user": self._user(),
                        "spec": [{"key": k, "kind": t, "label": l} for k, t, _, l in CONFIG_SPEC]})
        else:
            self._send(PAGE, "text/html; charset=utf-8")

    def do_POST(self):
        if self.path.startswith("/login"):
            n = int(self.headers.get("Content-Length", 0) or 0)
            form = parse_qs((self.rfile.read(n) or b"").decode("utf-8", "replace"))
            u = form.get("username", [""])[0].strip()
            p = form.get("password", [""])[0]
            if pam_auth(u, p):
                self._redirect("/", [("Set-Cookie",
                    "%s=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=%d" % (COOKIE, make_token(u), SESSION_TTL))])
            else:
                time.sleep(1.0)  # slow brute-force
                self._send(LOGIN_PAGE.replace("%ERR%", "Invalid username or password"),
                           "text/html; charset=utf-8", code=401)
            return
        if not self._user():
            self._send({"error": "auth required"}, code=401); return
        if self.path.startswith("/api/config"):
            n = int(self.headers.get("Content-Length", 0) or 0)
            try:
                payload = json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                payload = {}
            saved = write_config(payload.get("values", payload))
            restarted = restart_ruby() if payload.get("restart") else False
            self._send({"ok": True, "values": saved, "restarted": restarted})
        elif self.path.startswith("/api/control"):
            n = int(self.headers.get("Content-Length", 0) or 0)
            try:
                payload = json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                payload = {}
            cmds = {
                "pause":  ["systemctl", "stop", "ruby.service"],
                "play":   ["systemctl", "start", "ruby.service"],
                "rescan": ["systemctl", "start", "--no-block", "ruby-rescan.service"],
            }
            act = payload.get("action")
            if act in cmds:
                try:
                    subprocess.run(cmds[act], timeout=25, capture_output=True)
                    ok = True
                except Exception:
                    ok = False
                self._send({"ok": ok, "action": act})
            else:
                self._send({"ok": False, "error": "bad action"}, code=400)
        else:
            self._send({"ok": False, "error": "unknown endpoint"}, code=404)


if __name__ == "__main__":
    print(f"Dashboard on http://0.0.0.0:{PORT}/")
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
