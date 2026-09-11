function pluginEntry(shell, pluginId) {
  var cfg = shell ? shell.shellConfig : null
  var list = cfg && Array.isArray(cfg.plugins) ? cfg.plugins : []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && String(list[i].id || "") === pluginId) return list[i]
  }
  return {}
}

function configStr(entry, key, fallback) {
  var v = entry[key]
  return typeof v === "string" && v.length > 0 ? v : fallback
}

function configInt(entry, key, fallback) {
  var v = entry[key]
  var n = Number(v)
  return isFinite(n) && n >= 0 ? Math.round(n) : fallback
}

function configFloat(entry, key, fallback) {
  var v = entry[key]
  var n = Number(v)
  return isFinite(n) ? n : fallback
}

// Haversine in miles
function haversineMiles(lat1, lon1, lat2, lon2) {
  var toRad = Math.PI / 180
  var dLat = (lat2 - lat1) * toRad
  var dLon = (lon2 - lon1) * toRad
  var a = Math.sin(dLat/2) * Math.sin(dLat/2) +
          Math.cos(lat1 * toRad) * Math.cos(lat2 * toRad) *
          Math.sin(dLon/2) * Math.sin(dLon/2)
  var c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a))
  var R = 3959 // miles
  return R * c
}

function formatDistance(miles, units) {
  if (!isFinite(miles)) return "--"
  if (units === "km") {
    var km = miles * 1.60934
    return km < 10 ? km.toFixed(1) : Math.round(km).toString()
  }
  return miles < 10 ? miles.toFixed(1) : Math.round(miles).toString()
}

function estimateMinutes(miles, mph) {
  if (!isFinite(miles)) return -1
  var speed = isFinite(mph) && mph > 0 ? mph : 25
  return Math.max(1, Math.round((miles / speed) * 60))
}

function normalizeDispensary(raw) {
  // raw may be from jskf-tt3q or gttd-5u6y, normalize to common shape
  var lon = null, lat = null
  if (raw.georeference && raw.georeference.coordinates && raw.georeference.coordinates.length >= 2) {
    lon = Number(raw.georeference.coordinates[0])
    lat = Number(raw.georeference.coordinates[1])
  }
  // jskf-tt3q has no georeference; caller will join
  return {
    id: String(raw.license_number || raw.ocm_license_number || raw.external_tpid || ""),
    license: String(raw.license_number || raw.ocm_license_number || ""),
    name: String(raw.dba || raw.dba_name || raw.entity_name || raw.legal_name || "Dispensary"),
    entity: String(raw.entity_name || raw.legal_name || ""),
    address: String(raw.address_line_1 || raw.physical_address || ""),
    address2: String(raw.address_line_2 || ""),
    city: String(raw.city || raw.physical_city || ""),
    state: String(raw.state || raw.physical_state || "NY"),
    zip: String(raw.zip_code || raw.physical_zip || ""),
    county: String(raw.county || raw.physical_county || ""),
    website: String(raw.business_website || ""),
    hours: String(raw.hours_of_operation || ""),
    lat: lat,
    lon: lon,
    raw: raw
  }
}

function buildAddress(d) {
  var parts = []
  if (d.address) parts.push(d.address)
  if (d.address2) parts.push(d.address2)
  var cityStateZip = [d.city, d.state, d.zip].filter(function(s){return s && s.length>0}).join(", ")
  // but we want "city, NY zip"
  var line = d.city ? (d.city + (d.state ? ", " + d.state : "") + (d.zip ? " " + d.zip : "")) : (d.state + " " + d.zip)
  if (d.city || d.state) parts.push(line.trim())
  return parts.join(", ")
}

function parseHoursForToday(hoursStr) {
  if (!hoursStr || typeof hoursStr !== "string" || hoursStr.trim().length === 0) return { today: "", openNow: null, raw: "" }
  var raw = hoursStr.trim()
  // Try to find today's segment: e.g. "Mon: 10:00 AM - 08:00 PM; Tues: ..."
  // Normalize: get day name
  var days = ["Sun","Mon","Tues","Wed","Thurs","Fri","Sat"]
  var todayIdx = new Date().getDay()
  var todayAbbrs = [ ["Sun","Sunday"], ["Mon","Monday"], ["Tues","Tue","Tuesday"], ["Wed","Wednesday"], ["Thurs","Thu","Thursday"], ["Fri","Friday"], ["Sat","Saturday"] ]
  var candidates = todayAbbrs[todayIdx]
  var lower = raw.toLowerCase()
  var todaySegment = ""
  // Split by ; or |
  var parts = raw.split(/;\s*|\|\s*/g)
  for (var i = 0; i < parts.length; i++) {
    var p = parts[i]
    var pl = p.toLowerCase()
    for (var j = 0; j < candidates.length; j++) {
      if (pl.indexOf(candidates[j].toLowerCase()) !== -1) { todaySegment = p.trim(); break }
    }
    if (todaySegment) break
  }
  if (!todaySegment) {
    // fallback: if no day found, return raw truncated
    return { today: raw.length > 60 ? raw.slice(0,60) + "…" : raw, openNow: null, raw: raw }
  }
  // Try to parse open/close times to determine openNow
  var m = todaySegment.match(/(\d{1,2}):?(\d{2})?\s*(AM|PM|A\.M\.|P\.M\.)?\s*-\s*(\d{1,2}):?(\d{2})?\s*(AM|PM|A\.M\.|P\.M\.|)/i)
  var openNow = null
  if (m) {
    try {
      var now = new Date()
      var nowMin = now.getHours()*60 + now.getMinutes()
      function toMin(hStr, mStr, ap) {
        var h = parseInt(hStr,10)
        var mm = mStr ? parseInt(mStr,10) : 0
        var apu = String(ap||"").toUpperCase().replace(/\./g,"")
        if (apu === "PM" && h < 12) h += 12
        if (apu === "AM" && h === 12) h = 0
        return h*60+mm
      }
      var openMin = toMin(m[1], m[2], m[3])
      var closeMin = toMin(m[4], m[5], m[6] || m[3]) // if close ap missing, assume same as open
      // Handle overnight (close < open)
      if (closeMin < openMin) closeMin += 24*60
      // If close is 12AM next day, treat as 24h
      openNow = nowMin >= openMin && nowMin < closeMin
    } catch(e) { openNow = null }
  }
  // Clean todaySegment: remove day prefix
  var cleaned = todaySegment.replace(/^[A-Za-z]+\s*:?\s*/,"").trim()
  return { today: cleaned || todaySegment, openNow: openNow, raw: raw }
}

function parseWeeklyHours(hoursStr) {
  if (!hoursStr || typeof hoursStr !== "string" || hoursStr.trim().length === 0) return []
  var raw = hoursStr.trim()
  var parts = raw.split(/;\s*|\|\s*/g)
  var todayIdx = new Date().getDay()
  // Map day abbreviations to index for isToday check
  var dayMap = { "sun":0, "sunday":0, "mon":1, "monday":1, "tues":2, "tue":2, "tuesday":2, "wed":3, "wednesday":3, "thurs":4, "thu":4, "thursday":4, "fri":5, "friday":5, "sat":6, "saturday":6 }
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var p = parts[i].trim()
    if (!p) continue
    var m = p.match(/^\s*([A-Za-z]+)\s*:?\s*(.*)$/)
    var dayLabel = ""
    var hoursPart = p
    if (m) {
      dayLabel = m[1]
      hoursPart = m[2].trim() || "Closed"
      // Normalize day label to 3 letters
      var dl = dayLabel.toLowerCase()
      if (dl.indexOf("tues")===0) dayLabel = "Tue"
      else if (dl.indexOf("thurs")===0) dayLabel = "Thu"
      else dayLabel = dayLabel.slice(0,3)
      // Capitalize
      dayLabel = dayLabel.charAt(0).toUpperCase() + dayLabel.slice(1,2).toLowerCase() + (dayLabel.length>2 ? dayLabel.slice(2).toLowerCase() : "")
      if (dayLabel.toLowerCase() === "tues") dayLabel = "Tue"
      if (dayLabel.toLowerCase() === "thurs") dayLabel = "Thu"
    }
    var isToday = false
    if (dayLabel) {
      var dkey = dayLabel.toLowerCase()
      if (dayMap[dkey] !== undefined && dayMap[dkey] === todayIdx) isToday = true
      // Handle Tues/Thu variations
      if (!isToday) {
        // Check full raw part for today match as fallback
        var pl = p.toLowerCase()
        var todayAbbrs = [ ["sun","sunday"], ["mon","monday"], ["tues","tue","tuesday"], ["wed","wednesday"], ["thurs","thu","thursday"], ["fri","friday"], ["sat","saturday"] ]
        var cands = todayAbbrs[todayIdx]
        for (var k=0;k<cands.length;k++) if (pl.indexOf(cands[k])!==-1) { isToday=true; break }
      }
    }
    out.push({ day: dayLabel || "Day", hours: hoursPart, isToday: isToday, raw: p })
  }
  // If we couldn't split (no ;), ensure at least one entry
  if (out.length===0 && raw) out.push({ day: "", hours: raw, isToday: false, raw: raw })
  return out
}

function sortByDistance(list, lat, lon, units) {
  var out = []
  for (var i = 0; i < list.length; i++) {
    var d = list[i]
    if (!isFinite(d.lat) || !isFinite(d.lon) || !isFinite(lat) || !isFinite(lon)) continue
    var mi = haversineMiles(lat, lon, d.lat, d.lon)
    var copy = {}
    for (var k in d) copy[k] = d[k]
    copy.distanceMi = mi
    copy.distance = formatDistance(mi, units)
    copy.etaMin = estimateMinutes(mi, 25)
    copy._mi = mi
    out.push(copy)
  }
  out.sort(function(a,b){ return a._mi - b._mi })
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    pluginEntry: pluginEntry,
    configStr: configStr,
    configInt: configInt,
    configFloat: configFloat,
    haversineMiles: haversineMiles,
    formatDistance: formatDistance,
    estimateMinutes: estimateMinutes,
    normalizeDispensary: normalizeDispensary,
    buildAddress: buildAddress,
    parseHoursForToday: parseHoursForToday,
    parseWeeklyHours: parseWeeklyHours,
    sortByDistance: sortByDistance
  }
}
