// Wires up every .stepper on the page. Each stepper is scoped to its own
// element, so several can coexist without interfering.
//
// Layout (website): the stepped content sits on top, below it the .step-control
// showing exactly one explanation, below that a nav bar with prev/next and a
// "3 / 5" position readout. The nav bar is built here rather than in Lua so the
// filters stay free of presentation markup.
//
// Stepping dispatches a `set-choice` CustomEvent (detail = step index) on the
// stepper element; the stepper listens for it and toggles each .step based on
// its data-show-from / data-hide-from range (show-from inclusive, hide-from
// exclusive: visible while show-from <= current < hide-from).
//
// Videos carrying data-play-on="P" (e.g. manim section clips) are driven by
// stepper-video.js, which the deck's controller shares.
//
// The accessible names of the two buttons are the only wording this script
// produces. They come from data-prev-label / data-next-label on the .stepper
// element (set from the `stepper:` metadata by stepper.lua); the defaults below
// apply when the document configures nothing.
(function () {
	var DEFAULT_PREV_LABEL = "Previous step";
	var DEFAULT_NEXT_LABEL = "Next step";

	function buildNav(stepper, total) {
		var nav = document.createElement("div");
		nav.className = "step-nav";

		var prev = document.createElement("button");
		prev.type = "button";
		prev.className = "step-prev";
		prev.textContent = "‹";
		prev.setAttribute("aria-label", stepper.dataset.prevLabel || DEFAULT_PREV_LABEL);

		var next = document.createElement("button");
		next.type = "button";
		next.className = "step-next";
		next.textContent = "›";
		next.setAttribute("aria-label", stepper.dataset.nextLabel || DEFAULT_NEXT_LABEL);

		var position = document.createElement("span");
		position.className = "step-position";
		// Announce the step change only; aria-live on the control would repeat
		// the whole explanation.
		position.setAttribute("aria-live", "polite");
		position.textContent = "1 / " + total;

		nav.appendChild(prev);
		nav.appendChild(next);
		nav.appendChild(position);

		return { nav: nav, prev: prev, next: next, position: position };
	}

	function initStepper(stepper) {
		var steps = stepper.querySelectorAll(".step");
		var choices = stepper.querySelectorAll(".step-choice");
		var videos = stepper.querySelectorAll("video[data-play-on]");
		var current = 0;

		var total = choices.length;
		var control = stepper.querySelector(".step-control");
		var nav = null;

		// A stepper with a single explanation has nothing to step through.
		if (control && total > 1) {
			nav = buildNav(stepper, total);
			control.parentNode.insertBefore(nav.nav, control.nextSibling);

			nav.prev.addEventListener("click", function () {
				go(current - 1);
			});
			nav.next.addEventListener("click", function () {
				go(current + 1);
			});
		}

		function go(index) {
			if (index < 0 || index >= total) return;
			stepper.dispatchEvent(new CustomEvent("set-choice", { detail: index }));
		}

		function update() {
			steps.forEach(function (el) {
				var from = el.dataset.showFrom !== undefined ? parseInt(el.dataset.showFrom) : -Infinity;
				var hideFrom = el.dataset.hideFrom !== undefined ? parseInt(el.dataset.hideFrom) : Infinity;
				el.style.display = current >= from && current < hideFrom ? "" : "none";
			});
			choices.forEach(function (c) {
				c.classList.toggle("active", parseInt(c.dataset.step) === current);
			});
			if (nav) {
				nav.position.textContent = current + 1 + " / " + total;
				nav.prev.disabled = current === 0;
				nav.next.disabled = current === total - 1;
			}
			window.stepperUpdateVideos(videos, current);
		}

		stepper.addEventListener("set-choice", function (e) {
			current = e.detail;
			update();
		});

		update();
	}

	function init() {
		document.querySelectorAll(".stepper").forEach(initStepper);
	}

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", init);
	} else {
		init();
	}
})();
