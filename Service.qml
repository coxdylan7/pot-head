import QtQuick
import Quickshell
import Quickshell.Io
import "PotHead.js" as Pot

Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "djc.pot-head"
  readonly property var pluginEntry: Pot.pluginEntry(shell, pluginId)

  // config
  readonly property string apiUrl: Pot.configStr(pluginEntry, "apiUrl", "https://data.ny.gov/resource/jskf-tt3q.json")
  readonly property string geoApiUrl: Pot.configStr(pluginEntry, "geoApiUrl", "https://data.ny.gov/resource/gttd-5u6y.json")
  readonly property string appToken: Pot.configStr(pluginEntry, "appToken", "")
  readonly property int updateMinutes: Pot.configInt(pluginEntry, "updateMinutes", 360)
  readonly property int locationPollSeconds: Pot.configInt(pluginEntry, "locationPollSeconds", 300)
  readonly property int maxResults: Pot.configInt(pluginEntry, "maxResults", 6)
  readonly property string units: Pot.configStr(pluginEntry, "units", "mi")
  readonly property string locationOverrideLat: Pot.configStr(pluginEntry, "locationOverrideLat", "")
  readonly property string locationOverrideLon: Pot.configStr(pluginEntry, "locationOverrideLon", "")

  readonly property string homeDir: Quickshell.env("HOME") || "~"
  readonly property string cacheDir: homeDir + "/.cache/omarchy/pot-head"
  readonly property string dispensaryCache: cacheDir + "/dispensaries.json"
  readonly property string locationCache: cacheDir + "/location.json"

  // state
  property double lat: NaN
  property double lon: NaN
  property double accuracy: NaN
  property string locationStatus: "idle" // idle, locating, found, error
  property string locationError: ""
  property var dispensaries: [] // normalized + georeference
  property string lastFetchError: ""
  property string lastFetchTime: ""

  property var closest: null
  property var next5: []
  property bool hasLocation: isFinite(effectiveLat()) && isFinite(effectiveLon())

  // internal
  property string pendingDispensaryFetch: ""
  property string pendingGeoFetch: ""
  property int fetchAttempt: 0

  function isFiniteNumber(v) { return typeof v === "number" && isFinite(v) }

  function effectiveLat() {
    var ov = Pot.configFloat(pluginEntry, "locationOverrideLat", NaN)
    if (isFinite(ov)) return ov
    var s = Pot.configStr(pluginEntry, "locationOverrideLat", "")
    var n = Number(s)
    if (s !== "" && isFinite(n)) return n
    return lat
  }
  function effectiveLon() {
    var ov = Pot.configFloat(pluginEntry, "locationOverrideLon", NaN)
    if (isFinite(ov)) return ov
    var s = Pot.configStr(pluginEntry, "locationOverrideLon", "")
    var n = Number(s)
    if (s !== "" && isFinite(n)) return n
    return lon
  }

  function recomputeClosest() {
    var elat = effectiveLat()
    var elon = effectiveLon()
    if (!isFinite(elat) || !isFinite(elon) || dispensaries.length === 0) {
      closest = null
      next5 = []
      return
    }
    var sorted = Pot.sortByDistance(dispensaries, elat, elon, units)
    if (sorted.length === 0) {
      closest = null
      next5 = []
      return
    }
    var n = Math.max(1, Math.min(10, maxResults))
    closest = sorted[0]
    next5 = sorted.slice(1, n)
  }

  function ensureCacheDir() {
    cacheProc.command = ["bash", "-c", "mkdir -p '" + cacheDir + "'"]
    cacheProc.running = true
  }

  function fetchDispensaries() {
    var tokenOpt = appToken.length > 0 ? " -H 'X-App-Token: " + appToken + "' " : " "
    var cmd = "mkdir -p '" + cacheDir + "'; "
      + "curl -s" + tokenOpt + " '" + apiUrl + "?$limit=5000' > /tmp/pot-head-primary.json; "
      + "curl -s" + tokenOpt + " '" + geoApiUrl + "?$limit=5000' > /tmp/pot-head-geo.json; "
      + "python3 - << 'PY'\n"
      + "import json, pathlib\n"
      + "pathlib.Path('" + cacheDir + "').mkdir(parents=True, exist_ok=True)\n"
      + "try:\n"
      + "  pri = json.loads(pathlib.Path('/tmp/pot-head-primary.json').read_text())\n"
      + "except Exception as e:\n"
      + "  print('primary parse error', e)\n"
      + "  pri=[]\n"
      + "try:\n"
      + "  geo = json.loads(pathlib.Path('/tmp/pot-head-geo.json').read_text())\n"
      + "except Exception as e:\n"
      + "  print('geo parse error', e)\n"
      + "  geo=[]\n"
      + "# filter primary to active retail only\n"
      + "priF=[r for r in pri if r.get('license_status')=='Active' and r.get('operational_status')=='Active' and r.get('business_purpose')=='Adult-Use Retail Sales']\n"
      + "gmap={}\n"
      + "for g in geo:\n"
      + "  k=str(g.get('ocm_license_number') or '').strip()\n"
      + "  if k and g.get('georeference') and g['georeference'].get('coordinates'):\n"
      + "    gmap[k]=g['georeference']\n"
      + "out=[]\n"
      + "for r in priF:\n"
      + "  lic=str(r.get('license_number') or '').strip()\n"
      + "  geo_ref=gmap.get(lic)\n"
      + "  if geo_ref:\n"
      + "    r['georeference']=geo_ref\n"
      + "    out.append(r)\n"
      + "print('FETCH', len(pri), len(priF), len(geo), len(out))\n"
      + "pathlib.Path('" + dispensaryCache + "').write_text(json.dumps(out))\n"
      + "if out:\n"
      + "  print(json.dumps(out[:1]))\n"
      + "PY\n"
    fetchProc.command = ["bash", "-c", cmd]
    fetchProc.running = true
  }

  function loadCachedDispensaries() {
    cacheReadProc.command = ["bash", "-c", "cat '" + dispensaryCache + "' 2>/dev/null || echo '[]'"]
    cacheReadProc.running = true
  }

  function handleCacheRead() {
    var txt = cacheReadProc.collected
    cacheReadProc.collected = ""
    try {
      var arr = JSON.parse(txt)
      if (Array.isArray(arr)) {
        var norm = []
        for (var i = 0; i < arr.length; i++) {
          var d = Pot.normalizeDispensary(arr[i])
          if (isFinite(d.lat) && isFinite(d.lon)) norm.push(d)
        }
        dispensaries = norm
        lastFetchError = ""
        console.log("pot-head: loaded " + norm.length + " dispensaries from cache")
        recomputeClosest()
      }
    } catch(e) {
      console.log("pot-head: cache parse error " + e)
    }
  }

  function handleFetch() {
    var txt = fetchProc.collected
    fetchProc.collected = ""
    // fetchProc already wrote to cache via python; just reload
    loadCachedDispensaries()
    try {
      var now = new Date().toISOString()
      lastFetchTime = now
      // notify via console
      console.log("pot-head: fetched dispensaries at " + now)
    } catch(e) {}
  }

  function fetchLocation() {
    locationStatus = "locating"
    locationError = ""
    // Try Geoclue via gdbus, then fallback to ipinfo
    // We do a bash pipeline: try geoclue, if fails -> ipinfo
    var cmd = "python3 - << 'PY'\n"
      + "import subprocess, json, sys\n"
      + "import re\n"
      + "lat=None; lon=None; acc=None; src='none'\n"
      + "try:\n"
      + "  out=subprocess.check_output(['gdbus','call','--system','--dest','org.freedesktop.GeoClue2','--object-path','/org/freedesktop/GeoClue2/Manager','--method','org.freedesktop.GeoClue2.Manager.GetClient'], text=True, timeout=3)\n"
      + "  m=re.search(r\"'([^']+)'\", out)\n"
      + "  if m:\n"
      + "    client=m.group(1)\n"
      + "    subprocess.check_output(['gdbus','call','--system','--dest','org.freedesktop.GeoClue2','--object-path',client,'--method','org.freedesktop.DBus.Properties.Set','org.freedesktop.GeoClue2.Client','DesktopId','<\"pot-head\">'], text=True, timeout=2)\n"
      + "    subprocess.check_output(['gdbus','call','--system','--dest','org.freedesktop.GeoClue2','--object-path',client,'--method','org.freedesktop.GeoClue2.Client.Start'], text=True, timeout=2)\n"
      + "    import time; time.sleep(1.5)\n"
      + "    loc=subprocess.check_output(['gdbus','call','--system','--dest','org.freedesktop.GeoClue2','--object-path',client,'--method','org.freedesktop.GeoClue2.Client.GetLocation'], text=True, timeout=3)\n"
      + "    m2=re.search(r\"'([^']+)'\", loc)\n"
      + "    if m2:\n"
      + "      locPath=m2.group(1)\n"
      + "      props=subprocess.check_output(['gdbus','call','--system','--dest','org.freedesktop.GeoClue2','--object-path',locPath,'--method','org.freedesktop.DBus.Properties.GetAll','org.freedesktop.GeoClue2.Location'], text=True, timeout=3)\n"
      + "      lm=re.search(r\"'Latitude':\\s*<([^>]+)>\", props)\n"
      + "      lom=re.search(r\"'Longitude':\\s*<([^>]+)>\", props)\n"
      + "      am=re.search(r\"'Accuracy':\\s*<([^>]+)>\", props)\n"
      + "      if lm: lat=float(lm.group(1))\n"
      + "      if lom: lon=float(lom.group(1))\n"
      + "      if am: acc=float(am.group(1))\n"
      + "      if lat and lon: src='geoclue'\n"
      + "except Exception as e:\n"
      + "  pass\n"
      + "if lat is None or lon is None:\n"
      + "  try:\n"
      + "    import urllib.request\n"
      + "    data=urllib.request.urlopen('https://ipinfo.io/json', timeout=4).read().decode()\n"
      + "    j=json.loads(data)\n"
      + "    loc=j.get('loc','')\n"
      + "    if loc:\n"
      + "      la,lo=loc.split(',')\n"
      + "      lat=float(la); lon=float(lo); acc=5000; src='ipinfo'\n"
      + "  except Exception as e:\n"
      + "    pass\n"
      + "res={'lat':lat,'lon':lon,'accuracy':acc,'source':src}\n"
      + "print(json.dumps(res))\n"
      + "PY\n"
    locationProc.command = ["bash", "-c", cmd]
    locationProc.collected = ""
    locationProc.running = true
  }

  function handleLocation() {
    var txt = locationProc.collected
    locationProc.collected = ""
    try {
      // find last JSON object containing lat
      var m = txt.match(/\{[^}]*"lat"[^}]*\}/)
      if (!m) m = txt.match(/\{[\s\S]*\}/)
      var j = m ? JSON.parse(m[0]) : JSON.parse(txt.trim().split("\n").pop())
      if (j && isFinite(j.lat) && isFinite(j.lon)) {
        lat = Number(j.lat)
        lon = Number(j.lon)
        accuracy = Number(j.accuracy || NaN)
        locationStatus = "found"
        locationError = ""
        // cache
        cacheLocationProc.command = ["bash", "-c", "mkdir -p '" + cacheDir + "' && cat > '" + locationCache + "' <<'EOF'\\n" + JSON.stringify(j) + "\\nEOF\\n"]
        cacheLocationProc.running = true
        console.log("pot-head: location " + lat + "," + lon + " via " + j.source)
        recomputeClosest()
      } else {
        locationStatus = "error"
        locationError = "No fix"
        console.log("pot-head: location failed " + txt.slice(0,200))
      }
    } catch(e) {
      locationStatus = "error"
      locationError = String(e).slice(0,80)
      console.log("pot-head: location parse error " + e + " txt:" + txt.slice(0,200))
    }
  }

  function openNavigation(dispensary) {
    if (!dispensary || !isFinite(dispensary.lat) || !isFinite(dispensary.lon)) {
      console.log("pot-head: no coords for navigation")
      return
    }
    var url = "https://www.google.com/maps/dir/?api=1&destination=" + dispensary.lat + "," + dispensary.lon
    // also support OSM: https://www.openstreetmap.org/directions?engine=osrm_car&route=" + lat + "," + lon + ";" + dispensary.lat + "," + dispensary.lon
    navProc.command = ["xdg-open", url]
    navProc.running = true
  }

  function openSite(dispensary) {
    var url = dispensary && dispensary.website ? String(dispensary.website).trim() : ""
    if (!url) {
      console.log("pot-head: no website for " + (dispensary ? dispensary.name : ""))
      return
    }
    if (url.indexOf("http") !== 0) url = "https://" + url
    siteProc.command = ["xdg-open", url]
    siteProc.running = true
  }

  // processes
  Process {
    id: cacheProc
  }
  Process {
    id: fetchProc
    property string collected: ""
    stdout: SplitParser { onRead: function(data){ fetchProc.collected += data + "\n" } }
    stderr: SplitParser { onRead: function(data){ fetchProc.collected += data + "\n" } }
    onExited: function(code, status){ root.handleFetch() }
  }
  Process {
    id: cacheReadProc
    property string collected: ""
    stdout: SplitParser { onRead: function(data){ cacheReadProc.collected += data + "\n" } }
    onExited: function(code, status){ root.handleCacheRead() }
  }
  Process {
    id: locationProc
    property string collected: ""
    stdout: SplitParser { onRead: function(data){ locationProc.collected += data + "\n" } }
    stderr: SplitParser { onRead: function(data){ locationProc.collected += data + "\n" } }
    onExited: function(code, status){ root.handleLocation() }
  }
  Process { id: cacheLocationProc }
  Process { id: navProc }
  Process { id: siteProc }

  // timers
  Timer {
    id: fetchTimer
    interval: root.updateMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: root.fetchDispensaries()
  }
  Timer {
    id: locationTimer
    interval: root.locationPollSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.fetchLocation()
  }

  // init
  Component.onCompleted: {
    root.loadCachedDispensaries()
    root.fetchDispensaries()
  }

  // recompute when location or dispensaries change
  onLatChanged: root.recomputeClosest()
  onLonChanged: root.recomputeClosest()
  onDispensariesChanged: root.recomputeClosest()
}
