// Draws the red box around the pieces of text named in `mark="…"`.
//
// The filter (code-mark.lua) has already checked the search text at build time
// and left the attribute as `data-mark` on the outer `div.sourceCode`. What is
// left is the wrapping, in the DOM:
//
//   <span id="cb1-5"> … Rows <span class="op">-</span> <span class="dv">1</span> … </span>
//
// A hit therefore regularly runs across several token spans and cannot be put
// into *one* element. It is split into one wrapper per text node instead; the
// first gets `code-mark-start`, the last `code-mark-end`. Together with the
// edges from code-mark.css that reads as one continuous box.
//
// On slides this runs **after** Quarto's line-highlight plugin: that clones the
// whole <code> node once per `|` step, and the clones sit in step order in the
// DOM. `data-mark-steps` hangs off exactly that: one mark per step, in the same
// segmentation as `code-line-numbers`. From `.explain-code` it comes for free —
// there `mark=` sits on the explanation step.

(function () {
	// Splits at `sep`, but not at an occurrence escaped with `\`.
	// Both separators show up in real code (`;` in a for head, `|` in `||`);
	// to mark one, write `\;` or `\|`. See code-mark.lua.
	function splitEscaped(s, sep) {
		var out = [];
		var buf = "";
		for (var i = 0; i < s.length; i++) {
			var c = s.charAt(i);
			if (c === "\\" && s.charAt(i + 1) === sep) {
				buf += sep;
				i++;
			} else if (c === sep) {
				out.push(buf);
				buf = "";
			} else {
				buf += c;
			}
		}
		out.push(buf);
		return out;
	}

	// "5:Rows - 1" -> {line: 5, needle: "Rows - 1"} · "Rows - 1" -> {line: null, …}
	function parseSpec(spec) {
		return splitEscaped(spec, ";")
			.map(function (part) {
				var m = /^\s*(\d+)\s*:(.*)$/.exec(part);
				if (m) return { line: parseInt(m[1], 10), needle: m[2] };
				return { line: null, needle: part.replace(/^\s+/, "") };
			})
			.filter(function (e) {
				return e.needle !== "";
			});
	}

	function textNodes(root) {
		var out = [];
		var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
		var n;
		while ((n = walker.nextNode())) {
			// The line numbers hang off an empty <a> as ::before — its text nodes
			// (if any) are not part of the code.
			if (!(n.parentNode && n.parentNode.tagName === "A")) out.push(n);
		}
		return out;
	}

	// Wraps every occurrence of `needle` below `root`.
	function wrapOccurrences(root, needle) {
		var nodes = textNodes(root);
		if (!nodes.length) return;

		var text = nodes
			.map(function (n) {
				return n.nodeValue;
			})
			.join("");

		var hits = [];
		var from = 0;
		var at;
		while ((at = text.indexOf(needle, from)) !== -1) {
			hits.push([at, at + needle.length]);
			from = at + needle.length;
		}
		if (!hits.length) return;

		// Start offset of each node within the joined text.
		var starts = [];
		var pos = 0;
		nodes.forEach(function (n) {
			starts.push(pos);
			pos += n.nodeValue.length;
		});

		// Back to front, so the splits do not shift the offsets of the hits that
		// are still pending.
		hits.reverse().forEach(function (hit) {
			var hs = hit[0];
			var he = hit[1];
			for (var i = nodes.length - 1; i >= 0; i--) {
				var ns = starts[i];
				var ne = ns + nodes[i].nodeValue.length;
				if (ne <= hs || ns >= he) continue; // node outside the hit

				var node = nodes[i];
				var localStart = Math.max(hs - ns, 0);
				var localEnd = Math.min(he - ns, node.nodeValue.length);

				var mid = node;
				if (localEnd < mid.nodeValue.length) mid.splitText(localEnd);
				if (localStart > 0) mid = mid.splitText(localStart);

				var span = document.createElement("span");
				span.className = "code-mark";
				if (ns + localStart === hs) span.classList.add("code-mark-start");
				if (ns + localEnd === he) span.classList.add("code-mark-end");
				mid.parentNode.insertBefore(span, mid);
				span.appendChild(mid);
			}
		});
	}

	function lineSpans(code) {
		return Array.prototype.filter.call(code.children, function (el) {
			return el.tagName === "SPAN" && /^cb\d+-\d+/.test(el.id || "");
		});
	}

	function applyTo(code, entries) {
		if (code.dataset.codeMarkDone) return;
		code.dataset.codeMarkDone = "1";
		var lines = lineSpans(code);
		entries.forEach(function (e) {
			if (e.line) {
				if (lines[e.line - 1]) wrapOccurrences(lines[e.line - 1], e.needle);
			} else {
				wrapOccurrences(code, e.needle);
			}
		});
	}

	function run() {
		// Collect first, then apply once per <code>: a block can carry both
		// `data-mark` (valid for every step) and `data-mark-steps`, and wrapping
		// twice would nest the hits.
		var byCode = new Map();
		function add(code, entries) {
			if (!code || !entries.length) return;
			byCode.set(code, (byCode.get(code) || []).concat(entries));
		}

		// On the whole block: valid for every step.
		document.querySelectorAll("div.sourceCode[data-mark]").forEach(function (div) {
			var entries = parseSpec(div.getAttribute("data-mark"));
			div.querySelectorAll("pre code").forEach(function (code) {
				add(code, entries);
			});
		});

		// Per step: the i-th <code> is the i-th step. If that step is missing from
		// the DOM (because the line-highlight plugin did not clone at all, say),
		// the mark is skipped silently — it would have no home.
		document.querySelectorAll("div.sourceCode[data-mark-steps]").forEach(function (div) {
			var steps = splitEscaped(div.getAttribute("data-mark-steps"), "|");
			var codes = div.querySelectorAll("pre code");
			steps.forEach(function (step, i) {
				add(codes[i], parseSpec(step));
			});
		});

		byCode.forEach(function (entries, code) {
			applyTo(code, entries);
		});
	}

	function start() {
		if (window.Reveal && typeof window.Reveal.on === "function") {
			if (window.Reveal.isReady && window.Reveal.isReady()) run();
			else window.Reveal.on("ready", run);
		} else {
			run();
		}
	}

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", start);
	} else {
		start();
	}
})();
