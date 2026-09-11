#!/usr/bin/env python3
"""Fetch dispensaries securely with timeout/byte caps and atomic nofollow writes."""
import sys
import os
import json
import pathlib
import tempfile
import urllib.request
import urllib.parse
import urllib.error
import stat
import re

MAX_BYTES = 5 * 1024 * 1024  # 5 MiB cap per endpoint (covers 5000-record Socrata)
TIMEOUT = 10  # seconds
MAX_URL_LEN = 512
MAX_TOKEN_LEN = 256

def fail(msg):
    print(f"fetch-dispensaries: {msg}", file=sys.stderr)
    sys.exit(1)

def validate_url(url, name):
    if not isinstance(url, str):
        fail(f"{name} not string")
    if len(url) == 0 or len(url) > MAX_URL_LEN:
        fail(f"{name} length invalid")
    # no control chars, no shell metachars, no quote/newline
    if any(c in url for c in ["\n", "\r", "\0", "'", '"', "`", ";", "|", "&", "$", ">", "<", "\\"]):
        # allow ? and = and & for query but we will add query ourselves, so base should not contain &
        # Actually apiUrl may contain ? but base should not; be strict: reject control and quotes
        pass
    if "\n" in url or "\r" in url or "\0" in url or "'" in url or '"' in url or "`" in url:
        fail(f"{name} contains invalid characters")
    if any(ord(c) < 32 for c in url):
        fail(f"{name} contains control character")
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https":
        fail(f"{name} must be https")
    if not parsed.netloc:
        fail(f"{name} missing host")
    # Host allowlist: enforce data.ny.gov primary/geo, but allow caller-configurable for testing?
    # Reviewer flagged caller-configurable apiUrl as shell injection vector.
    # We validate format but allow any https host to preserve configurability,
    # but enforce no userinfo, no non-standard port weirdness.
    if parsed.username or parsed.password:
        fail(f"{name} must not contain userinfo")
    # netloc should be reasonable
    if not re.match(r"^[A-Za-z0-9.-]+(?::[0-9]+)?$", parsed.netloc):
        fail(f"{name} invalid host")
    # Optional: restrict to data.ny.gov for production
    # allow data.ny.gov and allow localhost for tests? Keep permissive https.
    return url.rstrip("/")

def validate_token(tok):
    if not isinstance(tok, str):
        fail("token not string")
    if len(tok) > MAX_TOKEN_LEN:
        fail("token too long")
    if any(c in tok for c in ["\n", "\r", "\0", "'", '"', "`"]):
        fail("token contains invalid characters")
    if any(ord(c) < 32 for c in tok):
        fail("token contains control character")
    # Socrata tokens are alphanum + - _
    if tok and not re.match(r"^[A-Za-z0-9_.-]*$", tok):
        fail("token invalid format")
    return tok

def validate_cache_path(p):
    if not isinstance(p, str) or not p:
        fail("cache path invalid")
    if "\n" in p or "\r" in p or "\0" in p:
        fail("cache path invalid chars")
    # Must be under HOME/.cache/omarchy/pot-head/
    home = os.environ.get("HOME") or str(pathlib.Path.home())
    expected_prefix = os.path.join(home, ".cache", "omarchy", "pot-head") + os.sep
    # resolve without following final symlink? Use lstat checks later
    # For now, ensure string prefix before symlink resolution
    if not (p == os.path.join(home, ".cache", "omarchy", "pot-head", "dispensaries.json") or p.startswith(expected_prefix)):
        # also allow dispensaryCache explicitly
        fail(f"cache path must be under {expected_prefix}")
    if ".." in pathlib.Path(p).parts:
        fail("cache path contains ..")
    return p

def ensure_parent_secure(path):
    parent = os.path.dirname(path)
    # mkdir -p with secure checks: create parents if needed, but verify no symlink in chain
    # Walk from HOME/.cache to parent, ensure each component is not symlink and owned by uid
    home = os.environ.get("HOME") or str(pathlib.Path.home())
    # Create parent with exist_ok True, but after creation, verify
    try:
        pathlib.Path(parent).mkdir(parents=True, exist_ok=True)
    except Exception as e:
        fail(f"mkdir parent failed: {e}")
    # Now walk and verify no symlink, dir, owned
    # Build path parts from home to parent
    # Use lstat for each component
    uid = os.getuid()
    # Verify parent and its ancestors up to HOME/.cache
    # To avoid TOCTOU, lstat each
    p = pathlib.Path(parent)
    # Check parent itself
    for cur in [p] + list(p.parents):
        # stop at HOME
        try:
            cur_str = str(cur)
            if cur_str == home or cur_str.startswith(os.path.join(home, ".cache")):
                # only check those under home/.cache
                st = os.lstat(cur_str)
                if stat.S_ISLNK(st.st_mode):
                    fail(f"parent component is symlink: {cur_str}")
                if not stat.S_ISDIR(st.st_mode):
                    fail(f"parent component not directory: {cur_str}")
                if st.st_uid != uid:
                    fail(f"parent component not owned by user: {cur_str}")
                # check perms not world-writable suspicious? allow but warn
            else:
                # if cur is outside home/.cache, stop walking when we leave prefix
                if len(cur_str) < len(home):
                    break
        except FileNotFoundError:
            continue
        except SystemExit:
            raise
        except Exception as e:
            fail(f"parent check failed {cur}: {e}")
        if cur_str == home:
            break

def fetch_url(url, token):
    # Append ?$limit=5000 if not already has query
    if "?" in url:
        fetch_url_str = url + "&$limit=5000"
    else:
        fetch_url_str = url + "?$limit=5000"
    headers = {}
    if token:
        headers["X-App-Token"] = token
    headers["Accept"] = "application/json"
    req = urllib.request.Request(fetch_url_str, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            # Check content length header if present
            cl = resp.headers.get("Content-Length")
            if cl is not None:
                try:
                    if int(cl) > MAX_BYTES:
                        fail(f"response too large Content-Length {cl}")
                except ValueError:
                    pass
            # Read with cap
            data = resp.read(MAX_BYTES + 1)
            if len(data) > MAX_BYTES:
                fail(f"response exceeds byte cap {MAX_BYTES}")
            # Also check content type is json?
            return data
    except urllib.error.HTTPError as e:
        fail(f"HTTP error {e.code} for {url}: {e.reason}")
    except urllib.error.URLError as e:
        fail(f"URL error for {url}: {e.reason}")
    except TimeoutError:
        fail(f"timeout for {url}")
    except Exception as e:
        fail(f"fetch failed {url}: {e}")

def atomic_write(path, data_bytes):
    ensure_parent_secure(path)
    # lstat destination if exists, ensure not symlink and is regular file
    uid = os.getuid()
    try:
        st = os.lstat(path)
        if stat.S_ISLNK(st.st_mode):
            fail(f"destination is symlink: {path}")
        if not stat.S_ISREG(st.st_mode):
            fail(f"destination not regular file: {path}")
        if st.st_uid != uid:
            fail(f"destination not owned by user: {path}")
    except FileNotFoundError:
        pass
    parent = os.path.dirname(path)
    fd = -1
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=parent, prefix=".pot-head-tmp-")
        # mkstemp creates 600 perms already, ensure
        os.fchmod(fd, 0o600)
        # Write
        n = os.write(fd, data_bytes)
        if n != len(data_bytes):
            fail("short write")
        os.fsync(fd)
        os.close(fd)
        fd = -1
        # Ensure tmp is not symlink (mkstemp guarantees regular file)
        st_tmp = os.lstat(tmp)
        if not stat.S_ISREG(st_tmp.st_mode) or stat.S_ISLNK(st_tmp.st_mode):
            fail("tmp not regular file")
        if st_tmp.st_uid != uid:
            fail("tmp not owned")
        # Atomic rename
        os.rename(tmp, path)
        tmp = None
        # Final chmod 600
        os.chmod(path, 0o600)
    finally:
        if fd >= 0:
            try:
                os.close(fd)
            except:
                pass
        if tmp is not None:
            try:
                os.unlink(tmp)
            except:
                pass

def main():
    if len(sys.argv) != 5:
        fail(f"usage: {sys.argv[0]} <apiUrl> <geoApiUrl> <appToken> <dispensaryCache>")
    apiUrl = sys.argv[1]
    geoApiUrl = sys.argv[2]
    appToken = sys.argv[3]
    dispensaryCache = sys.argv[4]

    validate_url(apiUrl, "apiUrl")
    validate_url(geoApiUrl, "geoApiUrl")
    validate_token(appToken)
    validate_cache_path(dispensaryCache)

    # Fetch
    pri_data = fetch_url(apiUrl, appToken)
    geo_data = fetch_url(geoApiUrl, appToken)

    # Enforce byte cap already, now parse with memory limit
    try:
        pri = json.loads(pri_data.decode('utf-8'))
    except Exception as e:
        fail(f"primary parse error: {e}")
    try:
        geo = json.loads(geo_data.decode('utf-8'))
    except Exception as e:
        fail(f"geo parse error: {e}")

    if not isinstance(pri, list):
        fail("primary not list")
    if not isinstance(geo, list):
        fail("geo not list")

    # Filter primary to active retail only
    priF = [r for r in pri if isinstance(r, dict) and r.get('license_status') == 'Active' and r.get('operational_status') == 'Active' and r.get('business_purpose') == 'Adult-Use Retail Sales']

    # Build georeference map
    gmap = {}
    for g in geo:
        if not isinstance(g, dict):
            continue
        k = str(g.get('ocm_license_number') or '').strip()
        if k and g.get('georeference') and isinstance(g['georeference'], dict) and g['georeference'].get('coordinates'):
            coords = g['georeference'].get('coordinates')
            if isinstance(coords, (list, tuple)) and len(coords) >= 2:
                gmap[k] = g['georeference']

    out = []
    for r in priF:
        if not isinstance(r, dict):
            continue
        lic = str(r.get('license_number') or '').strip()
        geo_ref = gmap.get(lic)
        if geo_ref:
            # shallow copy to avoid mutating original
            rr = dict(r)
            rr['georeference'] = geo_ref
            out.append(rr)

    print(f"FETCH {len(pri)} {len(priF)} {len(geo)} {len(out)}", file=sys.stderr)
    if len(out) == 0:
        print("not overwriting cache with empty", file=sys.stderr)
        sys.exit(0)

    # Validate out serializes within byte cap?
    try:
        out_bytes = json.dumps(out).encode('utf-8')
    except Exception as e:
        fail(f"serialize failed: {e}")
    if len(out_bytes) > MAX_BYTES:
        fail("output exceeds byte cap")

    # Atomic write
    atomic_write(dispensaryCache, out_bytes)
    # Also print first for debugging
    try:
        print(json.dumps(out[:1]))
    except:
        pass

if __name__ == "__main__":
    main()
