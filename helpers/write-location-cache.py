#!/usr/bin/python3
"""Atomically write location JSON with nofollow checks - descriptor-relative hardening."""
import sys, os, json, pathlib, tempfile, stat, secrets

MAX_BYTES = 64 * 1024

def fail(msg):
    print(f"write-location-cache: {msg}", file=sys.stderr)
    sys.exit(1)

def validate_cache_path(p):
    home = os.environ.get("HOME") or str(pathlib.Path.home())
    expected_prefix = os.path.join(home, ".cache", "omarchy", "pot-head") + os.sep
    if not (p == os.path.join(home, ".cache", "omarchy", "pot-head", "location.json") or p.startswith(expected_prefix)):
        fail(f"cache path must be under {expected_prefix}")
    if ".." in pathlib.Path(p).parts or "\n" in p or "\r" in p or "\0" in p:
        fail("invalid path")
    return p

def ensure_parent_secure_pinned(parent_fd, parent_path):
    try:
        st = os.fstat(parent_fd)
    except Exception as e:
        fail(f"fstat parent failed: {e}")
    if not stat.S_ISDIR(st.st_mode):
        fail(f"parent not directory: {parent_path}")
    if stat.S_ISLNK(st.st_mode):
        fail(f"parent is symlink: {parent_path}")
    if st.st_uid != os.getuid():
        fail(f"parent not owned: {parent_path}")
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        fail(f"parent writable by group/other: {parent_path} mode {oct(st.st_mode)}")
    uid = os.getuid()
    home = os.environ.get("HOME") or str(pathlib.Path.home())
    p = pathlib.Path(parent_path)
    for cur in [p] + list(p.parents):
        cur_str = str(cur)
        if cur_str == home or cur_str.startswith(os.path.join(home, ".cache")):
            try:
                st2 = os.lstat(cur_str)
                if stat.S_ISLNK(st2.st_mode):
                    fail(f"parent is symlink: {cur_str}")
                if not stat.S_ISDIR(st2.st_mode):
                    fail(f"parent not dir: {cur_str}")
                if st2.st_uid != uid:
                    fail(f"parent not owned: {cur_str}")
                if st2.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                    fail(f"parent writable by group/other: {cur_str} mode {oct(st2.st_mode)}")
            except FileNotFoundError:
                continue
            except SystemExit:
                raise
            except Exception as e:
                fail(f"parent check failed {cur}: {e}")
        if cur_str == home:
            break

def atomic_write(path, data_bytes):
    parent = os.path.dirname(path)
    base = os.path.basename(path)
    try:
        pathlib.Path(parent).mkdir(parents=True, exist_ok=True)
        os.chmod(parent, 0o700)
    except Exception as e:
        fail(f"mkdir parent failed: {e}")
    try:
        dir_fd = os.open(parent, os.O_DIRECTORY | os.O_NOFOLLOW)
    except Exception as e:
        fail(f"open parent dir failed: {e}")
    try:
        ensure_parent_secure_pinned(dir_fd, parent)
        uid = os.getuid()
        try:
            st = os.stat(base, dir_fd=dir_fd, follow_symlinks=False)
            if stat.S_ISLNK(st.st_mode):
                fail(f"dest is symlink: {path}")
            if not stat.S_ISREG(st.st_mode):
                fail(f"dest not regular: {path}")
            if st.st_uid != uid:
                fail(f"dest not owned: {path}")
            if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                fail(f"dest writable by group/other: {path}")
        except FileNotFoundError:
            pass
        tmp_name = f".pot-head-loc-{secrets.token_hex(8)}"
        try:
            fd = os.open(tmp_name, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=dir_fd)
        except Exception as e:
            fail(f"create tmp failed: {e}")
        try:
            n = os.write(fd, data_bytes)
            if n != len(data_bytes):
                fail("short write")
            os.fsync(fd)
            os.close(fd)
            fd = -1
            try:
                st_tmp = os.stat(tmp_name, dir_fd=dir_fd, follow_symlinks=False)
                if not stat.S_ISREG(st_tmp.st_mode) or stat.S_ISLNK(st_tmp.st_mode):
                    fail("tmp not regular")
                if st_tmp.st_uid != uid:
                    fail("tmp not owned")
                if st_tmp.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                    fail("tmp writable by group/other")
            except Exception as e:
                fail(f"tmp check failed: {e}")
            try:
                os.rename(tmp_name, base, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
            except TypeError:
                tmp_abs = os.path.join(parent, tmp_name)
                os.rename(tmp_abs, path)
            tmp_name = None
            try:
                os.chmod(base, 0o600, dir_fd=dir_fd)
            except:
                os.chmod(path, 0o600)
        finally:
            if fd >= 0:
                try: os.close(fd)
                except: pass
            if tmp_name is not None:
                try: os.unlink(tmp_name, dir_fd=dir_fd)
                except: pass
                try: os.unlink(os.path.join(parent, tmp_name))
                except: pass
    finally:
        try: os.close(dir_fd)
        except: pass

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
    try:
        lat = float(obj["lat"])
        lon = float(obj["lon"])
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            fail("lat/lon out of range")
    except:
        fail("invalid lat/lon")
    data = json.dumps(obj).encode('utf-8')
    atomic_write(cache, data)
    print(f"wrote {cache}")

if __name__ == "__main__":
    main()
