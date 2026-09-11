#!/usr/bin/env python3
"""Atomically write location JSON with nofollow checks."""
import sys, os, json, pathlib, tempfile, stat

MAX_BYTES = 64 * 1024

def fail(msg):
    print(f"write-location-cache: {msg}", file=sys.stderr)
    sys.exit(1)

def validate_cache_path(p):
    home = os.environ.get("HOME") or str(pathlib.Path.home())
    expected_prefix = os.path.join(home, ".cache", "omarchy", "pot-head") + os.sep
    if not (p == os.path.join(home, ".cache", "omarchy", "pot-head", "location.json") or p.startswith(expected_prefix)):
        fail(f"cache path must be under {expected_prefix}")
    if ".." in pathlib.Path(p).parts or "\n" in p or "\r" in p:
        fail("invalid path")
    return p

def ensure_parent_secure(path):
    parent = os.path.dirname(path)
    pathlib.Path(parent).mkdir(parents=True, exist_ok=True)
    uid = os.getuid()
    p = pathlib.Path(parent)
    home = os.environ.get("HOME") or str(pathlib.Path.home())
    for cur in [p] + list(p.parents):
        cur_str = str(cur)
        if cur_str == home or cur_str.startswith(os.path.join(home, ".cache")):
            try:
                st = os.lstat(cur_str)
                if stat.S_ISLNK(st.st_mode):
                    fail(f"parent is symlink: {cur_str}")
                if not stat.S_ISDIR(st.st_mode):
                    fail(f"parent not dir: {cur_str}")
                if st.st_uid != uid:
                    fail(f"parent not owned: {cur_str}")
            except FileNotFoundError:
                continue
        if cur_str == home:
            break

def main():
    if len(sys.argv) != 3:
        fail(f"usage: {sys.argv[0]} <locationCache> <jsonString>")
    cache = sys.argv[1]
    jstr = sys.argv[2]
    validate_cache_path(cache)
    if len(jstr) > MAX_BYTES:
        fail("json too large")
    try:
        obj = json.loads(jstr)
    except Exception as e:
        fail(f"invalid json: {e}")
    if not isinstance(obj, dict) or "lat" not in obj or "lon" not in obj:
        fail("json missing lat/lon")
    # ensure lat/lon are numbers
    try:
        lat = float(obj["lat"])
        lon = float(obj["lon"])
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            fail("lat/lon out of range")
    except:
        fail("invalid lat/lon")
    data = json.dumps(obj).encode('utf-8')
    ensure_parent_secure(cache)
    uid = os.getuid()
    try:
        st = os.lstat(cache)
        if stat.S_ISLNK(st.st_mode):
            fail("dest is symlink")
        if not stat.S_ISREG(st.st_mode):
            fail("dest not regular")
        if st.st_uid != uid:
            fail("dest not owned")
    except FileNotFoundError:
        pass
    parent = os.path.dirname(cache)
    fd = -1
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=parent, prefix=".pot-head-loc-")
        os.fchmod(fd, 0o600)
        os.write(fd, data)
        os.fsync(fd)
        os.close(fd); fd=-1
        st_tmp = os.lstat(tmp)
        if not stat.S_ISREG(st_tmp.st_mode) or stat.S_ISLNK(st_tmp.st_mode):
            fail("tmp not regular")
        os.rename(tmp, cache)
        tmp=None
        os.chmod(cache, 0o600)
    finally:
        if fd>=0:
            try: os.close(fd)
            except: pass
        if tmp:
            try: os.unlink(tmp)
            except: pass

if __name__ == "__main__":
    main()
