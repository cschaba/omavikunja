.pragma library

// Vikunja API v2 client. docs/ARCHITECTURE.md, decisions 2 and 3, says why it
// is shaped like this.
//
// Everything above send() is a pure function of its arguments: it builds a
// request or reads a response, touches no network and no QML, and runs
// unchanged under node (tests/lib/load-vikunja.js). send() is the only I/O.
// The four calls at the bottom — info, currentUser, openTasks, projects — glue
// the two together and are what the widget uses.
//
// A request is {method, url, headers}. A response is what send() hands back:
// {status, body, aborted, timedOut}; status 0 means no HTTP answer at all.
// A parse result is {ok: true, value} or {ok: false, error}, and every error
// is {kind, status, code, message} — see makeError for the kinds.
//
// The token lives only in request.headers. It is never put into a message,
// and every message passes through redact() on its way out regardless.

var API_PATH = "/api/v2"
var MIN_VERSION = [2, 4, 0]

// Vikunja's default max_items_per_page. A server set lower caps the page and
// says so in total_pages, which the walk follows either way.
var PER_PAGE = 50

// A server that misreports total_pages must not keep the widget paging
// forever. 50 pages of 50 is far beyond a task list anyone reads in a bar.
var MAX_PAGES = 50

// What Vikunja sends for "no due date" — Go's zero time, not null.
var NO_DATE_PREFIX = "0001-01-01"

var MESSAGE_LIMIT = 200

// --- errors ------------------------------------------------------------------

// kind is one of
//   config       serverUrl or apiToken missing or unusable
//   network      no HTTP answer: DNS, refused, TLS, offline
//   timeout      no answer in time
//   aborted      the caller cancelled the request
//   unsupported  the server has no API v2 (older than 2.4.0, or not Vikunja)
//   auth         401, or Vikunja's invalid-token code
//   forbidden    403 — usually a token without the needed scope
//   notFound     404 on anything but /info
//   rateLimited  429
//   server       5xx
//   client       any other 4xx
//   parse        a 2xx whose body is not what the API documents
function makeError(kind, status, code, message) {
  return {
    kind: kind,
    status: status || 0,
    code: code || 0,
    message: redact(String(message || ""))
  }
}

// Belt and braces: nothing here ever puts the token into a message, but a
// server might echo a header back, and a message is what ends up on screen.
function redact(text) {
  return String(text)
    .replace(/Bearer\s+\S+/gi, "Bearer [token]")
    .replace(/tk_[A-Za-z0-9]+/g, "[token]")
}

function fail(error) {
  return { ok: false, error: error }
}

function succeed(value) {
  return { ok: true, value: value }
}

function clip(text) {
  text = String(text).replace(/\s+/g, " ").trim()
  return text.length > MESSAGE_LIMIT ? text.slice(0, MESSAGE_LIMIT - 1) + "…" : text
}

// The server's own words about an error. v1 answers {code, message}; v2's
// error body is unverified and may be an RFC 9457 problem document
// ({title, detail, errors}), so both are read. Never the raw body: a proxy's
// HTML error page is not a message.
function serverDetail(json) {
  if (!json || typeof json !== "object") return { code: 0, text: "" }
  var code = typeof json.code === "number" ? json.code : 0
  var text = json.message || json.detail || json.title || ""
  if (!text && Array.isArray(json.errors) && json.errors.length > 0)
    text = json.errors[0] && (json.errors[0].message || json.errors[0].detail) || ""
  return { code: code, text: clip(text) }
}

function parseJson(text) {
  try {
    return { ok: true, value: JSON.parse(text) }
  } catch (e) {
    return { ok: false }
  }
}

// Any non-2xx response, or a transport failure, as one error.
function toError(response) {
  response = response || {}
  var status = response.status || 0

  if (response.aborted) return makeError("aborted", 0, 0, "The request was cancelled.")
  if (response.timedOut) return makeError("timeout", 0, 0, "Vikunja did not answer in time.")
  if (status === 0) return makeError("network", 0, 0, "Could not reach the Vikunja server.")

  var parsed = parseJson(response.body)
  var detail = serverDetail(parsed.ok ? parsed.value : null)
  var suffix = detail.text ? ": " + detail.text : "."

  // Vikunja's code 11 is "missing, malformed, expired or otherwise invalid
  // token" — an auth failure whatever status it came with.
  if (status === 401 || detail.code === 11)
    return makeError("auth", status, detail.code, "Vikunja rejected the API token (HTTP " + status + ")" + suffix)
  if (status === 403)
    return makeError("forbidden", status, detail.code, "The API token is not allowed to do this (HTTP 403)" + suffix)
  if (status === 404)
    return makeError("notFound", status, detail.code, "Not found (HTTP 404)" + suffix)
  if (status === 429)
    return makeError("rateLimited", status, detail.code, "Vikunja is rate limiting requests (HTTP 429). Try again in a minute.")
  if (status >= 500)
    return makeError("server", status, detail.code, "The Vikunja server failed (HTTP " + status + ")" + suffix)
  return makeError("client", status, detail.code, "Vikunja refused the request (HTTP " + status + ")" + suffix)
}

// 2xx with a JSON object body, or the error that says why not.
function readObject(response) {
  if (!response || !(response.status >= 200 && response.status < 300)) return fail(toError(response))
  var parsed = parseJson(response.body)
  if (!parsed.ok || !parsed.value || typeof parsed.value !== "object" || Array.isArray(parsed.value))
    return fail(makeError("parse", response.status, 0, "Vikunja sent a response that is not a JSON object."))
  return succeed(parsed.value)
}

// --- configuration and URLs --------------------------------------------------

// The base every request starts from: no trailing slash, and no /api/v1 or
// /api/v2 either — Vikunja's settings page shows the API URL with /api/v1 on
// the end, and that is exactly what gets pasted into a config file.
function serverBase(serverUrl) {
  return String(serverUrl || "").trim().replace(/\/+$/, "").replace(/\/api\/v[12]$/, "").replace(/\/+$/, "")
}

function apiUrl(serverUrl, path, query) {
  var url = serverBase(serverUrl) + API_PATH + path
  var parts = []
  for (var i = 0; i < (query || []).length; i++)
    parts.push(encodeURIComponent(query[i][0]) + "=" + encodeURIComponent(query[i][1]))
  return parts.length ? url + "?" + parts.join("&") : url
}

// null when config can make the request, otherwise the error to show. The
// messages name the field, never its value.
function checkConfig(config, needsToken) {
  config = config || {}
  var base = serverBase(config.serverUrl)
  if (!base) return makeError("config", 0, 0, "No Vikunja server URL is configured (serverUrl).")
  if (!/^https?:\/\/[^\s\/?#]+/i.test(base))
    return makeError("config", 0, 0, "The server URL must start with http:// or https:// (serverUrl).")
  if (needsToken) {
    var token = config.apiToken
    if (typeof token !== "string" || token.length === 0)
      return makeError("config", 0, 0, "No Vikunja API token is configured (apiToken).")
    // A newline in a header value is header injection; whitespace in a token
    // is a paste gone wrong. Either way it must not reach setRequestHeader.
    if (/\s/.test(token))
      return makeError("config", 0, 0, "The API token contains whitespace (apiToken).")
  }
  return null
}

function request(method, url, token) {
  var headers = { "Accept": "application/json" }
  if (token) headers["Authorization"] = "Bearer " + token
  return { method: method, url: url, headers: headers }
}

// For a log line or an error: method and URL, never the headers.
function describeRequest(req) {
  return req ? req.method + " " + req.url : ""
}

// /info needs no auth, and gets no token: until it has answered, nothing says
// the URL is a Vikunja server at all.
function infoRequest(config) {
  return request("GET", apiUrl(config.serverUrl, "/info"), null)
}

function currentUserRequest(config) {
  return request("GET", apiUrl(config.serverUrl, "/user"), config.apiToken)
}

// Every open task the user can see, soonest due first. "No due date" sorts
// after every dated task.
function openTasksRequest(config, page) {
  return request("GET", apiUrl(config.serverUrl, "/tasks", [
    ["filter", "done=false"],
    ["sort_by", "due_date"],
    ["order_by", "asc"],
    ["page", page || 1],
    ["per_page", PER_PAGE]
  ]), config.apiToken)
}

function projectsRequest(config, page) {
  return request("GET", apiUrl(config.serverUrl, "/projects", [
    ["page", page || 1],
    ["per_page", PER_PAGE]
  ]), config.apiToken)
}

// --- responses ---------------------------------------------------------------

// "v2.6.0-378-gce2c0822" → [2, 6, 0]. null for what is not a version at all —
// Vikunja Cloud reports a bare commit hash.
function parseVersion(text) {
  var m = /^v?(\d+)\.(\d+)\.(\d+)/.exec(String(text || "").trim())
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null
}

function versionAtLeast(version, minimum) {
  for (var i = 0; i < 3; i++) {
    if (version[i] !== minimum[i]) return version[i] > minimum[i]
  }
  return true
}

function unsupported(status, why) {
  return makeError("unsupported", status, 0,
    "This server does not offer Vikunja API v2" + (why ? " (" + why + ")" : "") +
    ". OmaVikunja needs Vikunja " + MIN_VERSION.join(".") + " or newer.")
}

// GET /api/v2/info → {version, frontendUrl, maxItemsPerPage}.
//
// A pre-2.4.0 server has no /api/v2 route. Depending on what sits in front of
// it that is a 404, or a 200 carrying the web app's index.html, so every
// "this is not v2's /info" answer reads as unsupported rather than as a
// parse error.
function parseInfo(response, serverUrl) {
  if (response && response.status === 404) return fail(unsupported(404, "HTTP 404 on " + API_PATH + "/info"))
  var read = readObject(response)
  if (!read.ok) {
    return read.error.kind === "parse" ? fail(unsupported(response.status, "the answer is not JSON")) : read
  }
  var json = read.value
  if (typeof json.version !== "string" || !json.version)
    return fail(unsupported(response.status, "no version in the answer"))

  var version = parseVersion(json.version)
  if (version && !versionAtLeast(version, MIN_VERSION))
    return fail(unsupported(response.status, "it reports " + json.version))

  // Documented to end with "/", which the web links rely on. A server with no
  // public URL configured may send it empty; the server URL is the best guess.
  var frontend = typeof json.frontend_url === "string" && json.frontend_url ? json.frontend_url : serverBase(serverUrl)
  if (frontend && frontend.charAt(frontend.length - 1) !== "/") frontend += "/"

  return succeed({
    version: json.version,
    frontendUrl: frontend,
    maxItemsPerPage: typeof json.max_items_per_page === "number" ? json.max_items_per_page : 0
  })
}

// GET /api/v2/user → {id, username, name, defaultProjectId, quickAddMagicMode}.
// defaultProjectId is null when unset: Vikunja sends 0.
function parseCurrentUser(response) {
  var read = readObject(response)
  if (!read.ok) return read
  var json = read.value
  if (typeof json.id !== "number")
    return fail(makeError("parse", response.status, 0, "Vikunja's user answer has no user id."))
  var settings = json.settings || {}
  var frontend = settings.frontend_settings || {}
  return succeed({
    id: json.id,
    username: json.username || "",
    name: json.name || "",
    defaultProjectId: settings.default_project_id > 0 ? settings.default_project_id : null,
    quickAddMagicMode: typeof frontend.quick_add_magic_mode === "string" ? frontend.quick_add_magic_mode : null
  })
}

// One page of any v2 list → {items, page, totalPages, total}. items are the
// raw objects; the per-type functions below make them into something the UI
// reads.
function parseEnvelope(response) {
  var read = readObject(response)
  if (!read.ok) return read
  var json = read.value
  if (!Array.isArray(json.items))
    return fail(makeError("parse", response.status, 0, "Vikunja sent a list without items — is this API v2?"))
  return succeed({
    items: json.items,
    page: typeof json.page === "number" ? json.page : 1,
    totalPages: typeof json.total_pages === "number" ? json.total_pages : 1,
    total: typeof json.total === "number" ? json.total : json.items.length
  })
}

// The ISO string as Vikunja sent it, or null for "no due date".
function normaliseDueDate(value) {
  if (typeof value !== "string" || !value) return null
  if (value.indexOf(NO_DATE_PREFIX) === 0) return null
  return value
}

function normaliseTask(raw) {
  raw = raw || {}
  return {
    id: raw.id,
    title: typeof raw.title === "string" ? raw.title : "",
    done: raw.done === true,
    dueDate: normaliseDueDate(raw.due_date),
    projectId: typeof raw.project_id === "number" ? raw.project_id : 0,
    priority: typeof raw.priority === "number" ? raw.priority : 0
  }
}

// Raw project objects → {id: title}. Negative ids are saved filters, which
// the projects list returns alongside real projects; no task belongs to one.
function projectTitles(items) {
  var titles = {}
  for (var i = 0; i < (items || []).length; i++) {
    var p = items[i]
    if (!p || typeof p.id !== "number" || p.id <= 0) continue
    titles[p.id] = typeof p.title === "string" ? p.title : ""
  }
  return titles
}

// --- transport ---------------------------------------------------------------

// The only function that does I/O. Calls callback(response) exactly once and
// returns {abort}. Tests replace it.
//
// Qt's XMLHttpRequest is driven through onreadystatechange alone; whether it
// supports onload/onerror and the timeout property is unverified, so timeout
// is set where it exists and a caller that needs a hard limit pairs the call
// with a QML Timer and abort().
function send(req, callback, timeoutMs) {
  var xhr = new XMLHttpRequest()
  var finished = false
  var aborted = false
  var timedOut = false

  function finish() {
    if (finished) return
    finished = true
    callback({
      status: aborted || timedOut ? 0 : xhr.status,
      body: aborted || timedOut ? "" : xhr.responseText,
      aborted: aborted,
      timedOut: timedOut
    })
  }

  xhr.onreadystatechange = function () {
    if (xhr.readyState === 4) finish()
  }
  xhr.open(req.method, req.url)
  for (var name in req.headers) xhr.setRequestHeader(name, req.headers[name])
  if (timeoutMs > 0) {
    xhr.timeout = timeoutMs
    xhr.ontimeout = function () {
      timedOut = true
      finish()
    }
  }
  xhr.send()

  return {
    abort: function () {
      if (finished) return
      aborted = true
      xhr.abort()
      finish()
    }
  }
}

// --- calls -------------------------------------------------------------------
//
// Each takes the parsed config.json ({serverUrl, apiToken}) and a node-style
// callback(error, value), and returns {abort}. When the config is unusable the
// callback runs before the call returns.

var NOTHING_TO_ABORT = { abort: function () {} }

function single(config, needsToken, req, parse, callback) {
  var problem = checkConfig(config, needsToken)
  if (problem) {
    callback(problem, null)
    return NOTHING_TO_ABORT
  }
  return send(req(config), function (response) {
    var result = parse(response)
    if (result.ok) callback(null, result.value)
    else callback(result.error, null)
  })
}

// Every page of a v2 list, one request at a time, then all raw items at once.
function allPages(config, req, callback) {
  var problem = checkConfig(config, true)
  if (problem) {
    callback(problem, null)
    return NOTHING_TO_ABORT
  }
  var items = []
  var current = null

  // The next page is requested from inside the previous one's callback, so
  // `current` is always the request in flight and aborting it ends the walk.
  function fetch(page) {
    current = send(req(config, page), function (response) {
      var result = parseEnvelope(response)
      if (!result.ok) return callback(result.error, null)
      items = items.concat(result.value.items)
      // An empty page ends the walk as well: a page past the end is empty,
      // whatever total_pages claimed.
      var more = page < result.value.totalPages && result.value.items.length > 0 && page < MAX_PAGES
      if (more) fetch(page + 1)
      else callback(null, items)
    })
  }
  fetch(1)

  return {
    abort: function () {
      current.abort()
    }
  }
}

// → {version, frontendUrl, maxItemsPerPage}; an "unsupported" error on a
// server without API v2.
function info(config, callback) {
  return single(config, false, infoRequest, function (response) {
    return parseInfo(response, config.serverUrl)
  }, callback)
}

// → {id, username, name, defaultProjectId, quickAddMagicMode}
function currentUser(config, callback) {
  return single(config, true, currentUserRequest, parseCurrentUser, callback)
}

// → [{id, title, done, dueDate, projectId, priority}], soonest due first.
function openTasks(config, callback) {
  return allPages(config, openTasksRequest, function (error, items) {
    callback(error, error ? null : items.map(normaliseTask))
  })
}

// → {projectId: title}
function projects(config, callback) {
  return allPages(config, projectsRequest, function (error, items) {
    callback(error, error ? null : projectTitles(items))
  })
}
