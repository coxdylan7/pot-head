#!/usr/bin/python3
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
import secrets
def open_trusted_base(home_path):
    # Open HOME with O_DIRECTORY|O_NOFOLLOW and validate
    try:
        fd = os.open(home_path, os.O_DIRECTORY | os.O_NOFOLLOW)
    except Exception as e:
        fail(f"open HOME failed: {e}")
    try:
        st = os.fstat(fd)
    except Exception as e:
        try: os.close(fd)
        except: pass
        fail(f"fstat HOME failed: {e}")
    if not stat.S_ISDIR(st.st_mode):
        try: os.close(fd)
        except: pass
        fail(f"HOME not directory: {home_path}")
    if stat.S_ISLNK(st.st_mode):
        try: os.close(fd)
        except: pass
        fail(f"HOME is symlink: {home_path}")
    if st.st_uid != os.getuid():
        try: os.close(fd)
        except: pass
        fail(f"HOME not owned: {home_path}")
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        try: os.close(fd)
        except: pass
        fail(f"HOME writable by group/other: {home_path} mode {oct(st.st_mode)}")
    return fd

def ensure_parent_descriptor_relative(home_fd, home_path, parent_path):
    # parent_path is absolute, must be under home_path
    if not parent_path.startswith(home_path + os.sep):
        fail(f"parent not under HOME: {parent_path}")
    rel = os.path.relpath(parent_path, home_path)  # e.g. .config/hypr
    parts = rel.split(os.sep)
    cur_fd = home_fd
    cur_path = home_path
    # We will walk components, opening each descriptor-relatively, creating if needed via mkdirat
    # To avoid leaking fds, we keep current fd and open next, then close previous when moving deeper
    # But we need to keep home_fd open for caller? We'll duplicate.
    # Instead, we will use home_fd as base and walk with new fds, closing intermediate.
    # For simplicity, we dup home_fd to start
    try:
        cur_fd_dup = os.dup(home_fd)
    except Exception as e:
        fail(f"dup HOME fd failed: {e}")
    cur_fd = cur_fd_dup
    cur_path = home_path
    for comp in parts:
        if not comp or comp == ".":
            continue
        if comp == ".." or "/" in comp or "\n" in comp or "\0" in comp:
            try: os.close(cur_fd)
            except: pass
            fail(f"invalid component: {comp}")
        # Try to open next component with O_NOFOLLOW
        next_path = os.path.join(cur_path, comp)
        try:
            next_fd = os.open(comp, os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=cur_fd)
            # Validate opened dir
            try:
                st = os.fstat(next_fd)
            except Exception as e:
                try: os.close(next_fd)
                except: pass
                try: os.close(cur_fd)
                except: pass
                fail(f"fstat component failed {next_path}: {e}")
            if not stat.S_ISDIR(st.st_mode):
                try: os.close(next_fd)
                except: pass
                try: os.close(cur_fd)
                except: pass
                fail(f"component not directory: {next_path}")
            if stat.S_ISLNK(st.st_mode):
                try: os.close(next_fd)
                except: pass
                try: os.close(cur_fd)
                except: pass
                fail(f"component is symlink: {next_path}")
            if st.st_uid != os.getuid():
                try: os.close(next_fd)
                except: pass
                try: os.close(cur_fd)
                except: pass
                fail(f"component not owned: {next_path}")
            if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                try: os.close(next_fd)
                except: pass
                try: os.close(cur_fd)
                except: pass
                fail(f"component writable by group/other: {next_path} mode {oct(st.st_mode)}")
            # Success, move to next
            try: os.close(cur_fd)
            except: pass
            cur_fd = next_fd
            cur_path = next_path
        except FileNotFoundError:
            # Need to create directory descriptor-relatively via mkdirat
            try:
                os.mkdir(comp, 0o700, dir_fd=cur_fd)
            except FileExistsError:
                # Raced, try open again
                try:
                    next_fd = os.open(comp, os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=cur_fd)
                    st = os.fstat(next_fd)
                    if st.st_uid != os.getuid() or st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                        try: os.close(next_fd)
                        except: pass
                        try: os.close(cur_fd)
                        except: pass
                        fail(f"raced component not owned/writable: {next_path}")
                    try: os.close(cur_fd)
                    except: pass
                    cur_fd = next_fd
                    cur_path = next_path
                    continue
                except Exception as e:
                    try: os.close(cur_fd)
                    except: pass
                    fail(f"mkdir raced open failed {next_path}: {e}")
            except Exception as e:
                try: os.close(cur_fd)
                except: pass
                fail(f"mkdir component failed {next_path}: {e}")
            # After mkdir, open it
            try:
                next_fd = os.open(comp, os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=cur_fd)
            except Exception as e:
                try: os.close(cur_fd)
                except: pass
                fail(f"open after mkdir failed {next_path}: {e}")
            # Validate and chmod via fd (fchmod) to 0o700
            try:
                st = os.fstat(next_fd)
                if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
                    try: os.close(next_fd)
                    except: pass
                    try: os.close(cur_fd)
                    except: pass
                    fail(f"new component not owned/dir: {next_path}")
                # Ensure perms 0o700 via fchmod
                try:
                    os.fchmod(next_fd, 0o700)
                except Exception as e:
                    try: os.close(next_fd)
                    except: pass
                    try: os.close(cur_fd)
                    except: pass
                    fail(f"fchmod failed {next_path}: {e}")
            except Exception as e:
                try: os.close(next_fd)
                except: pass
                try: os.close(cur_fd)
                except: pass
                fail(f"fstat new component failed {next_path}: {e}")
            try: os.close(cur_fd)
            except: pass
            cur_fd = next_fd
            cur_path = next_path
        except OSError as e:
            # Any other error (e.g., symlink encountered, ELOOP)
            try: os.close(cur_fd)
            except: pass
            fail(f"open component failed {next_path}: {e}")
    # cur_fd is now the parent directory fd, pinned
    return cur_fd


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
    home = os.environ.get("HOME") or str(pathlib.Path.home())
    home_fd = open_trusted_base(home)
    try:
        dir_fd = ensure_parent_descriptor_relative(home_fd, home, parent)
        try:
            os.fchmod(dir_fd, 0o700)
        except Exception as e:
            fail(f"fchmod parent failed: {e}")
    except Exception as e:
        try: os.close(home_fd)
        except: pass
        fail(f"ensure parent failed: {e}")
    try:
        # Use pinned FD check
        try:
            st = os.fstat(dir_fd)
        except Exception as e:
            fail(f"fstat parent failed: {e}")
        if not stat.S_ISDIR(st.st_mode):
            fail(f"parent not directory: {parent}")
        if stat.S_ISLNK(st.st_mode):
            fail(f"parent is symlink: {parent}")
        if st.st_uid != os.getuid():
            fail(f"parent not owned: {parent}")
        if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            fail(f"parent writable by group/other: {parent} mode {oct(st.st_mode)}")
        uid = os.getuid()
        home = os.environ.get("HOME") or str(pathlib.Path.home())
        for cur in [pathlib.Path(parent)] + list(pathlib.Path(parent).parents):
            cur_str = str(cur)
            if cur_str == home or cur_str.startswith(os.path.join(home, ".cache")):
                try:
                    st2 = os.lstat(cur_str)
                    if stat.S_ISLNK(st2.st_mode):
                        fail(f"parent component is symlink: {cur_str}")
                    if not stat.S_ISDIR(st2.st_mode):
                        fail(f"parent component not directory: {cur_str}")
                    if st2.st_uid != uid:
                        fail(f"parent component not owned: {cur_str}")
                    if st2.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                        fail(f"parent component writable by group/other: {cur_str} mode {oct(st2.st_mode)}")
                except FileNotFoundError:
                    continue
                except SystemExit:
                    raise
                except Exception as e:
                    fail(f"parent check failed {cur}: {e}")
            if cur_str == home:
                break
    finally:
        try: os.close(dir_fd)
        except: pass
    # Legacy lstat checks for .cache components already done via pinned FD above
    uid = os.getuid()
    p2 = pathlib.Path(parent)
    home = os.environ.get("HOME") or str(pathlib.Path.home())
    for cur in [p2] + list(p2.parents):
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
    parent = os.path.dirname(path)
    base = os.path.basename(path)
    home = os.environ.get("HOME") or str(pathlib.Path.home())
    home_fd = open_trusted_base(home)
    try:
        dir_fd = ensure_parent_descriptor_relative(home_fd, home, parent)
        try:
            os.fchmod(dir_fd, 0o700)
        except Exception as e:
            fail(f"fchmod parent failed: {e}")
    except Exception as e:
        try: os.close(home_fd)
        except: pass
        fail(f"ensure parent failed: {e}")
    try:
        # pinned FD check
        try:
            st = os.fstat(dir_fd)
        except Exception as e:
            fail(f"fstat parent failed: {e}")
        if not stat.S_ISDIR(st.st_mode):
            fail(f"parent not directory: {parent}")
        if stat.S_ISLNK(st.st_mode):
            fail(f"parent is symlink: {parent}")
        if st.st_uid != os.getuid():
            fail(f"parent not owned: {parent}")
        if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            fail(f"parent writable by group/other: {parent}")
        uid = os.getuid()
        try:
            st = os.stat(base, dir_fd=dir_fd, follow_symlinks=False)
            if stat.S_ISLNK(st.st_mode):
                fail(f"destination is symlink: {path}")
            if not stat.S_ISREG(st.st_mode):
                fail(f"destination not regular file: {path}")
            if st.st_uid != uid:
                fail(f"destination not owned: {path}")
            if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                fail(f"destination writable by group/other: {path}")
        except FileNotFoundError:
            pass
        tmp_name = f".pot-head-loc-{__import__('secrets').token_hex(8)}"
        try:
            fd = os.open(tmp_name, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=dir_fd)
        except Exception as e:
            fail(f"create tmp failed: {e}")
        try:
            n = os.write(fd, data)
            if n != len(data):
                fail("short write")
            os.fsync(fd)
            os.close(fd)
            fd = -1
            try:
                st_tmp = os.stat(tmp_name, dir_fd=dir_fd, follow_symlinks=False)
                if not stat.S_ISREG(st_tmp.st_mode) or stat.S_ISLNK(st_tmp.st_mode):
                    fail("tmp not regular file")
                if st_tmp.st_uid != uid:
                    fail("tmp not owned")
                if st_tmp.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                    fail("tmp writable by group/other")
            except Exception as e:
                fail(f"tmp check failed: {e}")
            try:
                os.rename(tmp_name, base, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
            except TypeError as e:
                fail(f"rename with dir_fd not supported, failing closed: {e}")
            except Exception as e:
                fail(f"rename failed: {e}")
            tmp_name = None
            try:
                os.chmod(base, 0o600, dir_fd=dir_fd)
            except Exception as e:
                fail(f"chmod final failed: {e}")
        finally:
            if fd >= 0:
                try: os.close(fd)
                except: pass
            if tmp_name is not None:
                try: os.unlink(tmp_name, dir_fd=dir_fd)
                except: pass
    finally:
        try: os.close(dir_fd)
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
        names = subprocess.check_output(['/usr/bin/busctl', 'list'], text=True, timeout=2)
        if 'org.freedesktop.GeoClue2' in names:
            out = subprocess.check_output(['/usr/bin/gdbus', 'call', '--system', '--dest', 'org.freedesktop.GeoClue2', '--object-path', '/org/freedesktop/GeoClue2/Manager', '--method', 'org.freedesktop.GeoClue2.Manager.GetClient'], text=True, timeout=4)
            m = re.search(r"'([^']+)'", out)
            if m:
                client = m.group(1)
                subprocess.check_output(['/usr/bin/gdbus', 'call', '--system', '--dest', 'org.freedesktop.GeoClue2', '--object-path', client, '--method', 'org.freedesktop.DBus.Properties.Set', 'org.freedesktop.GeoClue2.Client', 'DesktopId', '<"pot-head">'], text=True, timeout=2)
                subprocess.check_output(['/usr/bin/gdbus', 'call', '--system', '--dest', 'org.freedesktop.GeoClue2', '--object-path', client, '--method', 'org.freedesktop.DBus.Properties.Set', 'org.freedesktop.GeoClue2.Client', 'AccuracyLevel', '<uint32 6>'], text=True, timeout=2)
                subprocess.check_output(['/usr/bin/gdbus', 'call', '--system', '--dest', 'org.freedesktop.GeoClue2', '--object-path', client, '--method', 'org.freedesktop.GeoClue2.Client.Start'], text=True, timeout=3)
                for attempt in range(3):
                    time.sleep(1.8)
                    try:
                        loc = subprocess.check_output(['/usr/bin/gdbus', 'call', '--system', '--dest', 'org.freedesktop.GeoClue2', '--object-path', client, '--method', 'org.freedesktop.GeoClue2.Client.GetLocation'], text=True, timeout=3)
                        m2 = re.search(r"'([^']+)'", loc)
                        if m2 and ('0' not in loc or '/' in loc):
                            locPath = m2.group(1)
                            if locPath and locPath != '/org/freedesktop/GeoClue2/Location/0':
                                props = subprocess.check_output(['/usr/bin/gdbus', 'call', '--system', '--dest', 'org.freedesktop.GeoClue2', '--object-path', locPath, '--method', 'org.freedesktop.DBus.Properties.GetAll', 'org.freedesktop.GeoClue2.Location'], text=True, timeout=3)
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
                subprocess.check_output(['/usr/bin/gdbus', 'call', '--system', '--dest', 'org.freedesktop.GeoClue2', '--object-path', client, '--method', 'org.freedesktop.GeoClue2.Client.Stop'], text=True, timeout=2)
    except Exception as e:
        pass

    # 2) WiFi triangulate via nmcli + BeaconDB (only if accurate)
    if lat is None or lon is None or (acc is not None and acc > 1000):
        try:
            aps = []
            out = subprocess.check_output(['/usr/bin/nmcli', '-t', '-f', 'BSSID,SIGNAL', 'device', 'wifi', 'list', '--rescan', 'no'], text=True, timeout=4)
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
                # read with byte cap, nofollow via O_NOFOLLOW
                try:
                    wdir = str(wpath.parent)
                    wbase = wpath.name
                    wfd = os.open(wdir, os.O_DIRECTORY|os.O_NOFOLLOW)
                    try:
                        wfd2 = os.open(wbase, os.O_RDONLY|os.O_NOFOLLOW, dir_fd=wfd)
                        try:
                            raw = os.read(wfd2, 64*1024).decode()
                        finally:
                            os.close(wfd2)
                    finally:
                        os.close(wfd)
                except Exception:
                    raw = ''
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
