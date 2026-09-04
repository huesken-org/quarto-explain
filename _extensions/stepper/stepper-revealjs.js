// Stepper controller for revealjs. Visibility is handled by reveal fragments;
// this only fixes the code-highlight fragment indices and drives video playback
// (the playback itself is in stepper-video.js, shared with the website).
//
// Reveal's fragment index f starts at -1, so the stepper step is f + 1.
function startStepperController() {
	if (typeof Reveal === "undefined") {
		return;
	}

	function currentStep() {
		var f = Reveal.getIndices().f;
		if (f === undefined || f === null || isNaN(f)) {
			f = -1;
		}
		return f + 1;
	}

	// Give the code-highlight fragments the indices they should have.
	//
	// Quarto's line-highlight plugin clones the <code> element once per `|`
	// segment and numbers the clones from the `data-fragment-index` of the
	// *code* element — which nothing ever sets, since a CodeBlock attribute
	// lands on the wrapping div. Finding none, the plugin removes the index from
	// every clone, and reveal sorts unindexed fragments **after** all indexed
	// ones: the captions then played first and the highlights followed.
	//
	// `data-code-fragment-index` on the div (from stepper.lua) says where the
	// block's first highlight step belongs. Apply it to the clones, then let
	// reveal sort again.
	function indexCodeFragments() {
		var changed = false;
		document.querySelectorAll("div.sourceCode[data-code-fragment-index]").forEach(function (div) {
			var index = parseInt(div.dataset.codeFragmentIndex, 10);
			if (isNaN(index)) {
				return;
			}
			div.querySelectorAll("pre code.fragment").forEach(function (code) {
				code.setAttribute("data-fragment-index", index);
				index += 1;
				changed = true;
			});
		});
		return changed;
	}

	function videosOf(slide) {
		return slide ? slide.querySelectorAll("video[data-play-on]") : [];
	}

	function updateVideos(slide) {
		window.stepperUpdateVideos(videosOf(slide), currentStep());
	}

	// Buffer the clips of the incoming slide so their duration is known for the
	// "jump to the final frame" case. Only a video that is not there yet needs
	// the nudge — load() would discard what is buffered and fetch again.
	function preload(slide) {
		videosOf(slide).forEach(function (v) {
			if (v.readyState < 1) {
				v.load();
			}
		});
	}

	// Run `fn` once the deck is up — also when that already happened.
	//
	// This controller registers at DOMContentLoaded, but reveal is long done by
	// then: `initialize()` ends in `plugins.load(…).then(start)`, so start()
	// runs as a microtask right after Quarto's inline init script, and start()
	// dispatches `ready` from a `setTimeout(…, 1)`. On a deck with markup left
	// to parse after that script, the 1 ms timer wins the race against
	// DOMContentLoaded: a listener added here never runs, and nothing renumbers
	// the highlight clones. Reveal then sorts
	// them after every indexed fragment — the code highlights only start once
	// the captions are through. Measured on a 49-slide chapter deck: the clones
	// sat at index 4..7 while the captions had 0..3.
	//
	// `isReady()` is set synchronously in start(), before that timer, so it is
	// the reliable side of the race.
	function whenReady(fn) {
		if (typeof Reveal.isReady === "function" && Reveal.isReady()) {
			fn({ currentSlide: Reveal.getCurrentSlide() });
		} else {
			Reveal.on("ready", fn);
		}
	}

	whenReady(function (e) {
		// Either way the plugins are initialised, so the clones exist.
		if (indexCodeFragments()) {
			Reveal.sync();
		}
		preload(e.currentSlide);
		updateVideos(e.currentSlide);
	});
	Reveal.on("slidechanged", function (e) {
		videosOf(e.previousSlide).forEach(function (v) {
			v.pause();
		});
		preload(e.currentSlide);
		updateVideos(e.currentSlide);
	});
	Reveal.on("fragmentshown", function () {
		updateVideos(Reveal.getCurrentSlide());
	});
	Reveal.on("fragmenthidden", function () {
		updateVideos(Reveal.getCurrentSlide());
	});
}

// Same reasoning as `whenReady()` above, one level up: waiting for an event that
// has already fired means waiting forever. Quarto puts this script in the
// <head>, so today DOMContentLoaded is still ahead of us — but a deferred or
// async load would not be, and then nothing would run at all.
if (document.readyState === "loading") {
	document.addEventListener("DOMContentLoaded", startStepperController);
} else {
	startStepperController();
}
