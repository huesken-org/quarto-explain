// Annotated code blocks (website output of explain-code.lua).
//
// The filter emits
//
//   <div class="explain-annotated">
//     <pre class="sourceCode"> … one <span id="cbN-M"> per line … </pre>
//     <div class="explain-annotations">
//       <div class="explain-annotation" data-lines="16-22" data-index="3"> … </div>
//     </div>
//   </div>
//
// and this hangs a numbered badge on every line an annotation refers to, then
// links the two: hovering either highlights the lines belonging to it. A line
// may carry several badges — that, and multi-line steps, is why Quarto's own
// code annotations are not used.

(function () {
	// "16-22", "5,9", "7-10,13-16" -> [16,17,…,22] / [5,9] / …
	function parseLines(spec) {
		var out = [];
		spec.split(",").forEach(function (part) {
			part = part.trim();
			if (!part) return;
			var range = part.match(/^(\d+)\s*-\s*(\d+)$/);
			if (range) {
				var from = parseInt(range[1], 10);
				var to = parseInt(range[2], 10);
				for (var i = Math.min(from, to); i <= Math.max(from, to); i++) out.push(i);
			} else if (/^\d+$/.test(part)) {
				out.push(parseInt(part, 10));
			}
		});
		// Sorted and de-duplicated so the contiguous-run check below holds even
		// for a spec written out of order.
		out.sort(function (a, b) {
			return a - b;
		});
		return out.filter(function (n, i) {
			return i === 0 || out[i - 1] !== n;
		});
	}

	// The per-line spans Quarto emits, in document order. Their ids are
	// "cb<block>-<line>", but we only need the order, so index by position.
	function codeLines(container) {
		var code = container.querySelector("pre.sourceCode > code");
		if (!code) return [];
		return Array.prototype.filter.call(code.children, function (el) {
			return el.tagName === "SPAN" && /^cb\d+-\d+$/.test(el.id);
		});
	}

	// data-explain-for holds a space-separated list, so a line shared by two
	// annotations answers to both. ~= is the attribute selector for exactly that.
	function setActive(container, index, on) {
		container
			.querySelectorAll('[data-explain-for~="' + index + '"]')
			.forEach(function (el) {
				el.classList.toggle("explain-active", on);
			});
		var note = container.querySelector('.explain-annotation[data-index="' + index + '"]');
		if (note) note.classList.toggle("explain-active", on);
	}

	// Hovering either half of a pair — the badge in the code, the text below —
	// highlights both.
	function linkHover(el, container, index) {
		el.addEventListener("mouseenter", function () {
			setActive(container, index, true);
		});
		el.addEventListener("mouseleave", function () {
			setActive(container, index, false);
		});
	}

	function addOwner(el, index) {
		var owners = (el.getAttribute("data-explain-for") || "").split(/\s+/).filter(Boolean);
		if (owners.indexOf(index) === -1) owners.push(index);
		el.setAttribute("data-explain-for", owners.join(" "));
	}

	function initBlock(container) {
		var lines = codeLines(container);
		if (!lines.length) return;

		container.querySelectorAll(".explain-annotation[data-lines]").forEach(function (note) {
			var index = note.getAttribute("data-index");
			var numbers = parseLines(note.getAttribute("data-lines"));

			numbers.forEach(function (n, i) {
				var line = lines[n - 1];
				if (!line) return; // spec points past the end of the block

				line.classList.add("explain-line");
				addOwner(line, index);

				// One badge per contiguous run: 16-22 gets one, "5,9" two.
				if (i > 0 && numbers[i - 1] === n - 1) return;

				var badge = document.createElement("span");
				badge.className = "explain-marker";
				badge.textContent = index;
				badge.setAttribute("data-explain-for", index);
				// The number only means anything with the text below.
				badge.setAttribute("aria-hidden", "true");
				linkHover(badge, container, index);
				line.appendChild(badge);
			});

			linkHover(note, container, index);
		});
	}

	function init() {
		document.querySelectorAll(".explain-annotated").forEach(initBlock);
	}

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", init);
	} else {
		init();
	}
})();
