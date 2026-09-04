// Playback of the videos a stepper drives — clips carrying `data-play-on="P"`.
// Shared by both controllers, so the deck and the page agree:
//
//   step <  play-on : rewound to the start, paused
//   step == play-on : played from the start
//   step >  play-on : parked on the final frame, paused
//
// Visibility is not touched here — that is the fragments' job on the slides and
// the stepper's on the website. The caller passes the videos it already holds.
(function () {
	// Seeking throws while no metadata is loaded; nothing to do about it.
	function seek(v, t) {
		try {
			v.currentTime = t;
		} catch (e) {}
	}

	window.stepperUpdateVideos = function (videos, step) {
		videos.forEach(function (v) {
			var playOn = parseInt(v.dataset.playOn, 10);
			if (step === playOn) {
				seek(v, 0);
				// Nor is an autoplay refusal.
				var p = v.play();
				if (p && p.catch) {
					p.catch(function () {});
				}
			} else if (step < playOn) {
				v.pause();
				seek(v, 0);
			} else {
				v.pause();
				// readyState >= 1 is exactly "duration is known".
				if (v.readyState >= 1) {
					seek(v, v.duration);
				}
			}
		});
	};
})();
