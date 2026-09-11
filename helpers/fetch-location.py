#!/usr/bin/env python3
"""Secure location fetch with timeout/byte caps and atomic nofollow cache write."""
import sys
import os
import json
import pathlib
import tempfile
import subprocess
import re
import time
import stat
import urllib.request
import urllib.error

MAX_BYTES = 512 * 1024  # 512 KiB for location services
TIMEOUT = 5
LOCATION_MAX_BYTES = 64 * 1024

def fail(msg):
    print(f"fetch-location: {msg}", file=sys.stderr)
    sys.exit(1)

def validate_cache_path(p):
    if not isinstance(p, str) or not p:
        fail("cache path invalid")
    if "\n" in p or "\r" in p or "\0" in p:
        fail("cache path invalid chars")
    home = os.environ.get("HOME") or str(pathlib.Path.home())
    expected_prefix = os.path.join(home, ".cache", "omarchy", "pot-head") + os.sep
    if not (p == os.path.join(home, ".cache", "omarchy", "pot-head", "location.json") or p.startswith(expected_prefix)):
        fail(f"cache path must be under {expected_prefix}")
    if ".." in pathlib.Path(p).parts:
        fail("cache path contains ..")
    return p

def ensure_parent_secure(path):
    parent = os.path.dirname(path)
    try:
        pathlib.Path(parent).mkdir(parents=True, exist_ok=True)
    except Exception as e:
        fail(f"mkdir parent failed: {e}")
    uid = os.getuid()
    p = pathlib.Path(parent)
    home = os.environ.get("HOME") or str(pathlib.Path.home())
    for cur in [p] + list(p.parents):
        cur_str = str(cur)
        if cur_str == home or cur_str.startswith(os.path.join(home, ".cache")):
            try:
                st = os.lstat(cur_str)
                if stat.S_ISLNK(st.st_mode):
                    fail(f"parent component is symlink: {cur_str}")
                if not stat.S_ISDIR(st.st_mode):
                    fail(f"parent component not directory: {cur_str}")
                if st.st_uid != uid:
                    fail(f"parent component not owned by user: {cur_str}")
            except FileNotFoundError:
                continue
            except SystemExit:
                raise
            except Exception as e:
                fail(f"parent check failed {cur}: {e}")
        if cur_str == home:
            break

def atomic_write_json(path, obj):
    data = json.dumps(obj).encode('utf-8')
    if len(data) > LOCATION_MAX_BYTES:
        fail("location json too large")
    ensure_parent_secure(path)
    uid = os.getuid()
    try:
        st = os.lstat(path)
        if stat.S_ISLNK(st.st_mode):
            fail(f"destination is symlink: {path}")
        if not stat.S_ISREG(st.st_mode):
            fail(f"destination not regular file: {path}")
        if st.st_uid != uid:
            fail(f"destination not owned: {path}")
    except FileNotFoundError:
        pass
    parent = os.path.dirname(path)
    fd = -1
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=parent, prefix=".pot-head-loc-")
        os.fchmod(fd, 0o600)
        os.write(fd, data)
        os.fsync(fd)
        os.close(fd)
        fd = -1
        st_tmp = os.lstat(tmp)
        if not stat.S_ISREG(st_tmp.st_mode) or stat.S_ISLNK(st_tmp.st_mode):
            fail("tmp not regular file")
        if st_tmp.st_uid != uid:
            fail("tmp not owned")
        os.rename(tmp, path)
        tmp = None
        os.chmod(path, 0o600)
    finally:
        if fd >= 0:
            try: os.close(fd)
            except: pass
        if tmp is not None:
            try: os.unlink(tmp)
            except: pass

def fetch_with_cap(url, data=None, headers=None, timeout=TIMEOUT):
    # Helper for beaconDB, ipinfo, ip-api with byte cap
    headers = headers or {}
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            cl = resp.headers.get("Content-Length")
            if cl is not None:
                try:
                    if int(cl) > MAX_BYTES:
                        raise ValueError("content length exceeds cap")
                except:
                    pass
            raw = resp.read(MAX_BYTES + 1)
            if len(raw) > MAX_BYTES:
                raise ValueError("response exceeds cap")
            return raw.decode('utf-8', errors='replace')
    except Exception as e:
        # bubble up for caller to handle fallback
        raise

def main():
    # argv: [locationCache] optional
    location_cache = None
    if len(sys.argv) >= 2:
        location_cache = sys.argv[1]
        validate_cache_path(location_cache)
    elif len(sys.argv) != 1:
        fail(f"usage: {sys.argv[0]} [locationCache]")

    lat = None
    lon = None
    acc = None
    src = 'none'

    # 1) GeoClue2 - robust with accuracy & retries
    try:
        names = subprocess.check_output(['busctl', 'list'], text=True, timeout=2)
        if 'org.freedesktop.GeoClue2' in names:
            out = subprocess.check_output(['gdbus', 'call', '--system', '--dest', 'org.freedesktop.GeoClue2', '--object-path', '/org/freedesktop/GeoClue2/Manager', '--method', 'org.freedesktop.GeoClue2.Manager.GetClient'], text=True, timeout=4)
            m = re.search(r"'([^']+)'", out)
            if m:
                client = m.group(1)
                subprocess.check_output(['gdbus', 'call', '--system', '--dest', 'org.freedesktop.GeoClue2', '--object-path', client, '--method', 'org.freedesktop.DBus.Properties.Set', 'org.freedesktop.GeoClue2.Client', 'DesktopId', '<"pot-head">'], text=True, timeout=2)
                subprocess.check_output(['gdbus', 'call', '--system', '--dest', 'org.freedesktop.GeoClue2', '--object-path', client, '--method', 'org.freedesktop.DBus.Properties.Set', 'org.freedesktop.GeoClue2.Client', 'AccuracyLevel', '<uint32 6>'], text=True, timeout=2)
                subprocess.check_output(['gdbus', 'call', '--system', '--dest', 'org.freedesktop.GeoClue2', '--object-path', client, '--method', 'org.freedesktop.GeoClue2.Client.Start'], text=True, timeout=3)
                for attempt in range(3):
                    time.sleep(1.8)
                    try:
                        loc = subprocess.check_output(['gdbus', 'call', '--system', '--dest', 'org.freedesktop.GeoClue2', '--object-path', client, '--method', 'org.freedesktop.GeoClue2.Client.GetLocation'], text=True, timeout=3)
                        m2 = re.search(r"'([^']+)'", loc)
                        if m2 and ('0' not in loc or '/' in loc):
                            locPath = m2.group(1)
                            if locPath and locPath != '/org/freedesktop/GeoClue2/Location/0':
                                props = subprocess.check_output(['gdbus', 'call', '--system', '--dest', 'org.freedesktop.GeoClue2', '--object-path', locPath, '--method', 'org.freedesktop.DBus.Properties.GetAll', 'org.freedesktop.GeoClue2.Location'], text=True, timeout=3)
                                lm = re.search(r"'Latitude':\s*<([^>]+)>", props)
                                lom = re.search(r"'Longitude':\s*<([^>]+)>", props)
                                am = re.search(r"'Accuracy':\s*<([^>]+)>", props)
                                if lm: lat = float(lm.group(1))
                                if lom: lon = float(lom.group(1))
                                if am: acc = float(am.group(1))
                                if lat and lon and lat != 0:
                                    src = 'geoclue'
                                    break
                    except:
                        pass
                subprocess.check_output(['gdbus', 'call', '--system', '--dest', 'org.freedesktop.GeoClue2', '--object-path', client, '--method', 'org.freedesktop.GeoClue2.Client.Stop'], text=True, timeout=2)
    except Exception as e:
        pass

    # 2) WiFi triangulate via nmcli + BeaconDB (only if accurate)
    if lat is None or lon is None or (acc is not None and acc > 1000):
        try:
            aps = []
            out = subprocess.check_output(['nmcli', '-t', '-f', 'BSSID,SIGNAL', 'device', 'wifi', 'list', '--rescan', 'no'], text=True, timeout=4)
            for line in out.strip().split(chr(10)):
                if not line.strip():
                    continue
                m = re.match(r'(.+):(-?\d+)$', line)
                if m:
                    bssid_esc, sig = m.group(1), m.group(2)
                    bssid = bssid_esc.replace('\\:', ':')
                    try: sig = int(sig)
                    except: continue
                    aps.append({'macAddress': bssid, 'signalStrength': sig})
            if len(aps) >= 2:
                payload = json.dumps({'wifiAccessPoints': aps[:20]}).encode()
                data = fetch_with_cap('https://beacondb.net/v1/geolocate', data=payload, headers={'Content-Type': 'application/json'}, timeout=5)
                j = json.loads(data)
                if j.get('location') and j.get('fallback') != 'ipf' and j.get('accuracy', 99999) < 5000:
                    lat = j['location']['lat']
                    lon = j['location']['lng']
                    acc = j.get('accuracy', 100)
                    src = 'beacondb-wifi'
        except:
            pass

    # 2b) Weather manual location - ~/.local/state/omarchy/settings/weather.json as failsafe
    if lat is None or lon is None or (acc is not None and acc > 500):
        try:
            import pathlib
            wpath = pathlib.Path.home() / '.local/state/omarchy/settings/weather.json'
            if wpath.exists():
                # read with byte cap
                raw = wpath.read_text()
                if len(raw) > 64*1024:
                    raise ValueError("weather json too large")
                wj = json.loads(raw)
                if 'latitude' in wj and 'longitude' in wj and wj['latitude'] is not None:
                    wlat = float(wj['latitude'])
                    wlon = float(wj['longitude'])
                    if wlat and wlon:
                        if lat is None or lon is None or (acc is None or acc > 5):
                            lat = wlat
                            lon = wlon
                            acc = 5
                            src = 'weather-manual'
        except:
            pass

    # 3) IP fallback
    if lat is None or lon is None or (acc is not None and acc > 2000):
        best = None
        candidates = []
        try:
            data = fetch_with_cap('https://ipinfo.io/json', timeout=4)
            j = json.loads(data)
            loc = j.get('loc', '')
            if loc:
                la, lo = loc.split(',')
                candidates.append((float(la), float(lo), 5000, 'ipinfo'))
        except:
            pass
        try:
            data = fetch_with_cap('http://ip-api.com/json/?fields=lat,lon,accuracy', timeout=4)
            j = json.loads(data)
            if 'lat' in j and 'lon' in j:
                a = j.get('accuracy', 5000)
                if a is None: a = 5000
                candidates.append((float(j['lat']), float(j['lon']), float(a), 'ip-api'))
        except:
            pass
        if candidates:
            candidates.sort(key=lambda x: x[2])
            if lat is None or lon is None:
                lat, lon, acc, src = candidates[0]
            else:
                if candidates[0][2] < (acc or 99999):
                    lat, lon, acc, src = candidates[0]
                elif lat is None:
                    lat, lon, acc, src = candidates[0]

    res = {'lat': lat, 'lon': lon, 'accuracy': acc, 'source': src}
    print(json.dumps(res))
    # Atomic cache write if location found and cache path provided
    if location_cache and lat is not None and lon is not None:
        try:
            atomic_write_json(location_cache, res)
        except Exception as e:
            print(f"cache write failed: {e}", file=sys.stderr)

if __name__ == "__main__":
    main()
