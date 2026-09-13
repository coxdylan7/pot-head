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
        try: os.close(home_fd)
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
