// Do the code highlights and the explanations advance together?
//
// The golden files cannot see this. They record the HTML the filters emit, but
// the fragment order a viewer experiences is settled at runtime, by Quarto's
// line-highlight plugin (which clones the <code> element once per `|` segment)
// and by reveal's own fragment sort. A mismatch between the two — reveal sorts
// fragments without an explicit index *after* every indexed one — once made the
// whole caption stack play before the first code highlight, with the emitted
// HTML looking perfectly correct.
//
// So this replays that runtime, in jsdom: the deck's **own** bundled plugin, the
// `indexCodeFragments()` from the shipped stepper-revealjs.js, and reveal's sort
// algorithm. Then it asserts the thing that actually matters — every step that
// moves a code highlight also moves a caption, and vice versa.
//
//   node tests/fragment-order.js <rendered-deck.html> …
//
// Run by tests/run.sh when jsdom is available; skipped when it is not, so the
// golden suite keeps needing nothing but quarto.
const fs = require("fs");
const path = require("path");
const { JSDOM } = require("jsdom");

const CONTROLLER = path.join(__dirname, "../_extensions/stepper/stepper-revealjs.js");

// The plugin Quarto copied next to the deck, so this never depends on where
// quarto itself is installed.
function bundledPlugin(deckPath) {
	const dir = path.dirname(deckPath);
	const hits = [];
	(function walk(d, depth) {
		if (depth > 6) return;
		for (const e of fs.readdirSync(d, { withFileTypes: true })) {
			const p = path.join(d, e.name);
			if (e.isDirectory()) walk(p, depth + 1);
			else if (e.name === "line-highlight.js") hits.push(p);
		}
	})(dir, 0);
	if (!hits.length) throw new Error("no bundled line-highlight.js next to " + deckPath);
	return hits[0];
}

// reveal.js Fragments.sort(): fragments carrying data-fragment-index are grouped
// by it, fragments without one are appended after all of them, then the groups
// are renumbered without gaps.
function sort(fragments) {
	let ordered = [];
	const unordered = [];
	const sorted = [];
	Array.from(fragments).forEach((f) => {
		if (f.hasAttribute("data-fragment-index")) {
			const i = parseInt(f.getAttribute("data-fragment-index"), 10);
			(ordered[i] = ordered[i] || []).push(f);
		} else {
			unordered.push([f]);
		}
	});
	ordered = ordered.concat(unordered);
	let index = 0;
	ordered.forEach((group) => {
		group.forEach((f) => {
			sorted.push(f);
			f.setAttribute("data-fragment-index", index);
		});
		index += 1;
	});
	return sorted;
}

// `entry` picks how the controller is started, because it has two ways in and a
// regression could hide in either: "late" is the original bug — the script runs
// while parsing and waits for DOMContentLoaded, which arrives long after reveal
// is ready — and "afterwards" is the deferred/async case the readyState guard
// covers, where DOMContentLoaded is already gone when the script first runs.
function check(deckPath, entry) {
	const dom = new JSDOM(fs.readFileSync(deckPath, "utf8"), { runScripts: "outside-only" });
	const { window } = dom;
	global.window = window;
	global.document = window.document;

	window.eval(fs.readFileSync(bundledPlugin(deckPath), "utf8"));

	const slides = Array.from(window.document.querySelectorAll("section.slide"));
	slides.forEach((slide) => {
		window.QuartoLineHighlight().init({
			getRevealElement: () => slide,
			getConfig: () => ({}),
			on: () => {},
		});
	});

	// Run the shipped controller **whole**, in the timing that used to defeat
	// it: reveal is already ready when DOMContentLoaded arrives, so a listener
	// added to `ready` would never fire again. That is the real failure mode —
	// indexCodeFragments() was always correct, it just never got called — and a
	// test that lifts the function out of the file cannot see it.
	window.stepperUpdateVideos = function () {};
	window.HTMLMediaElement.prototype.load = function () {};
	window.Reveal = {
		isReady: () => true,
		getCurrentSlide: () => slides[0] || null,
		getIndices: () => ({ f: -1 }),
		sync: () => {},
		on: () => {},
	};
	// jsdom has already finished parsing, so "loading" has to be put back to
	// replay the case where the script runs while the document is still coming in.
	Object.defineProperty(window.document, "readyState", {
		configurable: true,
		get: () => (entry === "late" ? "loading" : "complete"),
	});
	window.eval(fs.readFileSync(CONTROLLER, "utf8"));
	if (entry === "late") {
		window.document.dispatchEvent(new window.Event("DOMContentLoaded"));
	}

	let failed = 0;
	let checked = 0;
	slides.forEach((slide) => {
		const title = ((slide.querySelector("h2") || {}).textContent || "(untitled)").trim() + " [" + entry + "]";
		const steps = {};
		sort(slide.querySelectorAll(".fragment")).forEach((f) => {
			const i = f.getAttribute("data-fragment-index");
			(steps[i] = steps[i] || []).push(f.tagName === "CODE" ? "code" : "caption");
		});
		const keys = Object.keys(steps).sort((a, b) => a - b);
		if (!keys.some((k) => steps[k].includes("code"))) return; // nothing to pair up
		checked += 1;

		const outOfStep = keys.filter((k) => {
			const both = steps[k].includes("code") && steps[k].includes("caption");
			return !both;
		});
		if (outOfStep.length === 0) {
			console.log("PASS " + title);
			return;
		}
		failed += 1;
		console.log("FAIL " + title);
		keys.forEach((k) => console.log("       step " + (Number(k) + 1) + ": " + steps[k].join(" + ")));
	});

	if (checked === 0) {
		console.log("no slide in " + path.basename(deckPath) + " pairs code with captions");
	}
	return failed;
}

let failed = 0;
process.argv.slice(2).forEach((deck) => {
	["late", "afterwards"].forEach((entry) => {
		failed += check(deck, entry);
	});
});
if (failed > 0) {
	console.log("\n" + failed + " slide(s) out of step");
	process.exit(1);
}
console.log("\ncode highlights and explanations advance together");
