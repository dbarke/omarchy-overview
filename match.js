.pragma library

// Fuzzy matching for window search. Every query word has to match the
// window's title, app or workspace, as a substring or failing that as an
// in-order subsequence; substrings, word starts and the app name score higher.

function norm(s) { return String(s || "").toLowerCase() }

// Best score of one word against one field, or -1.
function wordScore(word, field) {
  if (!field) return -1
  var i = field.indexOf(word)
  if (i === 0) return 100
  if (i > 0) return /[\s\-_.\/:·]/.test(field.charAt(i - 1)) ? 80 : 60
  // Subsequence: every letter in order, tighter spans score more.
  var pos = -1, first = -1
  for (var k = 0; k < word.length; k++) {
    pos = field.indexOf(word.charAt(k), pos + 1)
    if (pos < 0) return -1
    if (first < 0) first = pos
  }
  return Math.max(1, 40 - (pos - first - word.length))
}

// fields: { title, app, workspace }. Returns -1 when a word matches nothing.
function score(query, fields) {
  var words = norm(query).split(/\s+/).filter(function(w) { return w.length })
  var total = 0
  for (var i = 0; i < words.length; i++) {
    var w = words[i]
    var app = wordScore(w, norm(fields.app))
    var best = Math.max(wordScore(w, norm(fields.title)),
                        app < 0 ? -1 : app + 10,
                        wordScore(w, norm(fields.workspace)))
    if (best < 0) return -1
    total += best
  }
  return total
}

// windows: entries with title/app/workspace and focus (0 = most recent).
// No query keeps most-recent-first; otherwise best match first.
function filter(windows, query) {
  if (!norm(query).trim()) return windows.slice()
  var scored = []
  for (var i = 0; i < windows.length; i++) {
    var s = score(query, windows[i])
    if (s >= 0) scored.push({ w: windows[i], s: s })
  }
  scored.sort(function(a, b) { return b.s - a.s || a.w.focus - b.w.focus })
  return scored.map(function(x) { return x.w })
}
