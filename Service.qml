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

  // helper paths - resolved relative to this file, argv-based invocation (no shell)
  readonly property string helperFetch: {
    var u = Qt.resolvedUrl("./helpers/fetch-dispensaries.py")
    var s = String(u)
    if (s.indexOf("file://") === 0) s = s.slice(7)
    return s
  }
  readonly property string helperLocation: {
    var u = Qt.resolvedUrl("./helpers/fetch-location.py")
    var s = String(u)
    if (s.indexOf("file://") === 0) s = s.slice(7)
    return s
  }
  readonly property string helperWriteLocation: {
    var u = Qt.resolvedUrl("./helpers/write-location-cache.py")
    var s = String(u)
    if (s.indexOf("file://") === 0) s = s.slice(7)
    return s
  }

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
    // Fixed argv, no shell construction, avoids quoting injection - absolute trusted binary
    cacheProc.command = ["/usr/bin/mkdir", "-p", cacheDir]
    cacheProc.running = true
  }

  function fetchDispensaries() {
    // Fixed argv helper replaces shell-constructed curl + /tmp fixed paths + python heredoc.
    // Helper validates apiUrl/geoApiUrl/appToken (no quote/newline, https only), enforces
    // timeout (10s) and byte cap (5 MiB) before parsing, uses private randomized temp
    // files in cacheDir with nofollow owner/type checks and atomic rename.
    fetchProc.command = ["/usr/bin/python3", helperFetch, apiUrl, geoApiUrl, appToken, dispensaryCache]
    fetchProc.running = true
  }

  function loadCachedDispensaries() {
    // Fixed argv python reader with byte cap - absolute trusted binary, no shell, descriptor-relative nofollow read.
    // Falls back to [] if missing/unreadable. Uses O_NOFOLLOW via dir_fd to avoid symlink follow.
    cacheReadProc.command = ["/usr/bin/python3", "-c", "import os,sys,stat\np=sys.argv[1]\nimport pathlib\ntry:\n d=os.path.dirname(p); b=os.path.basename(p)\n fd=os.open(d, os.O_DIRECTORY|os.O_NOFOLLOW)\n try:\n  fd2=os.open(b, os.O_RDONLY|os.O_NOFOLLOW, dir_fd=fd)\n  try:\n   data=os.read(fd2, 2097152)\n   sys.stdout.write(data.decode())\n  finally:\n   os.close(fd2)\n finally:\n  os.close(fd)\nexcept Exception:\n print('[]')\n", "--", dispensaryCache]
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
    // fetch helper already atomically wrote to cache via nofollow+rename; just reload
    loadCachedDispensaries()
    try {
      var now = new Date().toISOString()
      lastFetchTime = now
      console.log("pot-head: fetched dispensaries at " + now + " " + txt.slice(0,200))
    } catch(e) {}
  }

  function fetchLocation() {
    locationStatus = "locating"
    locationError = ""
    // Fixed argv helper - no bash -c heredoc. Helper validates locationCache path, enforces
    // byte/time caps for all network calls (BeaconDB, ipinfo), and atomically caches result
    // via randomized staging + nofollow checks before printing JSON. Absolute trusted binary.
    locationProc.command = ["/usr/bin/python3", helperLocation, locationCache]
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
        // helperLocation already atomically cached via staging+rename; keep explicit write
        // as backup using fixed argv helper that validates json and path, no heredoc.
        // Use helperWriteLocation with argv separation - JSON passed as argv, not shell. Absolute trusted binary.
        try {
          var jstr = JSON.stringify(j)
          if (jstr.length < 65536) {
            cacheLocationProc.command = ["/usr/bin/python3", helperWriteLocation, locationCache, jstr]
            cacheLocationProc.running = true
          }
        } catch(e2) { console.log("pot-head: cache write helper error " + e2) }
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
    navProc.command = ["/usr/bin/xdg-open", url]
    navProc.running = true
  }

  function openSite(dispensary) {
    var url = dispensary && dispensary.website ? String(dispensary.website).trim() : ""
    if (!url) {
      console.log("pot-head: no website for " + (dispensary ? dispensary.name : ""))
      return
    }
    if (url.indexOf("http") !== 0) url = "https://" + url
    siteProc.command = ["/usr/bin/xdg-open", url]
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
