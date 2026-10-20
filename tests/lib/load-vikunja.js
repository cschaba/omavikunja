// Loads Vikunja.js under node, the way QML sees it: one script, its top-level
// functions as the module's API.
//
//   const vikunja = require("./tests/lib/load-vikunja.js")()
//   vikunja.parseEnvelope({ status: 200, body: "{\"items\": []}" })
//
// `.pragma library` is QML-only syntax, so it is blanked out (not removed, to
// keep line numbers in stack traces). The file runs in its own vm context, so
// replacing send() for a test is an assignment and touches nothing else:
//
//   vikunja.send = (req, callback) => { callback({ status: 200, body: "…" }); return { abort() {} } }
//
// Values that come back are from that other context's realm: an array from it
// is not deepStrictEqual to an array literal here, because the prototypes
// differ. Compare through JSON.stringify.
//
// Not executable on purpose: CI runs every executable in tests/.

"use strict"

const fs = require("fs")
const path = require("path")
const vm = require("vm")

module.exports = function loadVikunja() {
  const file = path.join(__dirname, "..", "..", "Vikunja.js")
  const source = fs.readFileSync(file, "utf8").replace(/^\.pragma library$/m, "")
  const context = vm.createContext({})
  vm.runInContext(source, context, { filename: file })
  return context
}
