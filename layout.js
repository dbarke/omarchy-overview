.pragma library

// Thumbnail layout for the overview: justified rows, like a photo grid.
//
// Every thumbnail in a row has the same height and keeps its window's aspect
// ratio. Groups (workspaces) are laid out one after another; a group can share
// a row with the previous one, separated by a wider gap, and its label sits
// above its first thumbnail. The largest thumbnail height that still fits the
// area is found by bisection, capped so a lone window doesn't fill the screen.

// groups: [{ label, items: [{ aspect }] }]
// opts: { width, height, gap, groupGap, caption, header, maxHeight }
//   caption: space under each thumbnail for its title
//   header:  space above each row for group labels (0 hides labels)
// Returns { items: [{ group, index, x, y, w, h, row }], headers: [{ label, x, y, w, cont }],
//           rows: [[itemIndex...]], height }
function pack(groups, opts, h) {
  var W = opts.width
  var items = [], headers = [], rows = []
  var row = [], rowX = 0, rowY = 0, rowIndex = 0
  var lineH = opts.header + h + opts.caption

  function flush() {
    if (!row.length) return
    // Centre the finished row.
    var shift = Math.max(0, (W - rowX) / 2)
    for (var i = 0; i < row.length; i++) items[row[i]].x += shift
    for (var j = 0; j < headers.length; j++) if (headers[j].row === rowIndex) headers[j].x += shift
    rows.push(row)
    row = []
    rowX = 0
    rowY += lineH + opts.gap
    rowIndex++
  }

  for (var g = 0; g < groups.length; g++) {
    var group = groups[g]
    for (var k = 0; k < group.items.length; k++) {
      var w = Math.min(W, Math.max(1, group.items[k].aspect * h))
      var th = w < group.items[k].aspect * h ? w / group.items[k].aspect : h
      var sep = row.length ? (k === 0 ? opts.groupGap : opts.gap) : 0
      if (row.length && rowX + sep + w > W) { flush(); sep = 0 }
      var x = rowX + sep
      // Label the group where it starts, and again on a row it wraps onto.
      if (k === 0 || !row.length)
        headers.push({ label: group.label, x: x, y: rowY, w: w, row: rowIndex, group: g, cont: k > 0 })
      items.push({ group: g, index: k, x: x, y: rowY + opts.header + (h - th) / 2, w: w, h: th, row: rowIndex })
      row.push(items.length - 1)
      rowX = x + w
    }
  }
  flush()
  return { items: items, headers: headers, rows: rows, height: Math.max(0, rowY - opts.gap) }
}

function layout(groups, opts) {
  var count = 0
  for (var g = 0; g < groups.length; g++) count += groups[g].items.length
  if (!count) return { items: [], headers: [], rows: [], height: 0 }

  var lo = 8, hi = Math.max(lo, Math.min(opts.maxHeight, opts.height - opts.header - opts.caption))
  if (pack(groups, opts, hi).height <= opts.height) lo = hi
  else for (var i = 0; i < 24; i++) {
    var mid = (lo + hi) / 2
    if (pack(groups, opts, mid).height <= opts.height) lo = mid
    else hi = mid
  }
  var out = pack(groups, opts, Math.floor(lo))
  // Centre the block vertically.
  var dy = Math.max(0, (opts.height - out.height) / 2)
  for (var a = 0; a < out.items.length; a++) out.items[a].y += dy
  for (var b = 0; b < out.headers.length; b++) out.headers[b].y += dy
  return out
}

// Keyboard movement over a layout. dir: "left" | "right" | "up" | "down".
// Left/right walk the reading order; up/down pick the thumbnail in the next
// row whose centre is closest horizontally.
function neighbour(lay, current, dir) {
  var n = lay.items.length
  if (!n) return -1
  if (current < 0 || current >= n) return 0
  if (dir === "right") return (current + 1) % n
  if (dir === "left") return (current - 1 + n) % n
  var item = lay.items[current]
  var r = item.row + (dir === "down" ? 1 : -1)
  if (r < 0 || r >= lay.rows.length) return current
  var cx = item.x + item.w / 2, best = current, bestD = Infinity
  var cand = lay.rows[r]
  for (var i = 0; i < cand.length; i++) {
    var o = lay.items[cand[i]]
    var d = Math.abs(o.x + o.w / 2 - cx)
    if (d < bestD) { bestD = d; best = cand[i] }
  }
  return best
}
