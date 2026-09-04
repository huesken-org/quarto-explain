#!/usr/bin/env bash
#
# Golden-file tests for the four extensions in this repo.
#
# A case is a directory under tests/cases/ with an `input.qmd` that names its
# output format and filter chain itself:
#
#     format: revealjs
#     filters: [explain, manim, stepper]
#
# That order is the only one that works: `explain` builds the `.stepper`
# structure and sets `section-fragments` on the manim block, `manim` turns those
# into the section steps, `stepper` translates everything into fragments or the
# button stepper.
#
# Rendering happens with quarto in a scratch directory; what is compared is a
# recording of exit code, rendered content, attached assets and warnings.
#
# The content is the part a reader sees: `<main>` for html, the slides div for
# RevealJS, the whole file for everything else (LaTeX). Quarto's head and script
# trappings stay out. The asset list shows which CSS and JS files the filters
# requested.
#
# manim is **not** actually run: tests/bin/ comes first on PATH and holds stubs
# for `manim` and `ffmpeg` that create exactly the files the filter looks for
# (sections JSON, videos, still frames). That way the cases run in seconds and
# without a Python toolchain — what is checked is the filter, not manim.
#
# A last check runs outside that scheme: tests/fragment-order.js replays the
# runtime fragment sort in jsdom, because the order a viewer steps through is
# settled by Quarto's line-highlight plugin and reveal, not by the HTML the
# filters emit — the golden files are blind to it. It needs node with jsdom
# (`npm install --prefix tests`) and is skipped when that is missing.
#
#   tests/run.sh                  all cases
#   tests/run.sh manim latex      only cases whose name contains a pattern
#   tests/run.sh --update         rewrite expected.txt from the recording
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

command -v quarto >/dev/null || {
	printf 'quarto not on PATH\n' >&2
	exit 2
}

export PATH="$HERE/bin:$PATH"

update=0 patterns=()
for arg in "$@"; do
	case "$arg" in
	--update) update=1 ;;
	-*)
		sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
		exit 2
		;;
	*) patterns+=("$arg") ;;
	esac
done

# the part a reader sees — without quarto's head and script trappings
content() {
	local file=$1
	case "$file" in
	*.html)
		if grep -q '<div class="slides">' "$file"; then
			awk '/<div class="slides">/,/^    <\/div>$/' "$file"
		else
			awk '/<main/,/<\/main>/' "$file"
		fi |
			# quarto puts a MathJax style block into every speaker note; drop the
			# block, but keep whatever follows the closing tag
			sed -E '/<style type="text\/css">/,/<\/style>/{ /<\/style>/!d; s#^.*</style>##; }'
		;;
	*) cat "$file" ;;
	esac
}

pass=0 fail=0 failed=()

for dir in "$HERE"/cases/*/; do
	dir=${dir%/}
	name=${dir##*/}

	if [[ ${#patterns[@]} -gt 0 ]]; then
		hit=0
		for p in "${patterns[@]}"; do [[ "$name" == *"$p"* ]] && hit=1; done
		[[ $hit == 1 ]] || continue
	fi
	work=$(mktemp -d)
	cp -r "$HERE/../_extensions" "$dir/input.qmd" "$work/"

	(cd "$work" && QUARTO_PROJECT_DIR="$work" quarto render input.qmd) >"$work/out" 2>"$work/err"
	rc=$?
	rendered=$(ls "$work"/input.* 2>/dev/null | grep -v '\.qmd$' | head -1)

	{
		printf -- '--- exit %d\n' "$rc"
		printf -- '--- content %s\n' "${rendered##*/}"
		[[ -n $rendered ]] && content "$rendered"
		printf -- '--- assets\n'
		# LC_ALL=C: the runner's locale is not the developer's, and the two
		# disagree about where a `-` sorts
		[[ -n $rendered ]] && grep -oE '(explain|stepper|manim|code-mark)[a-z-]*\.(css|js)' "$rendered" | LC_ALL=C sort -u
		printf -- '--- warnings\n'
		# a failed render explains itself; a good one reports only its warning
		# and error lines — quarto's own `(W)`/`(E)` and the `ERROR` line with
		# which a Lua filter reports a broken construct without aborting the
		# run
		if [[ $rc == 0 ]]; then
			grep -E '^(\((W|E)\)|ERROR|WARNING)' "$work/err"
		else
			cat "$work/err"
		fi
	} | sed -E \
		-e 's/\x1b\[[0-9;]*m//g' \
		-e "s#$work#TMP#g" \
		-e "s#$HERE#TESTS#g" \
		-e 's#manim_renders/[0-9a-f]{16}#manim_renders/HASH#g' >"$work/actual"

	[[ $update == 1 ]] && cp "$work/actual" "$dir/expected.txt"

	if diff -u "$dir/expected.txt" "$work/actual" >"$work/diff" 2>&1; then
		printf 'PASS %s\n' "$name"
		pass=$((pass + 1))
	else
		printf 'FAIL %s\n' "$name"
		sed 's/^/     /' "$work/diff"
		fail=$((fail + 1))
		failed+=("$name")
	fi
	rm -rf "$work"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail == 0 ]] || {
	printf 'failed: %s\n' "${failed[*]}"
	exit 1
}

# The fragment order a viewer experiences is settled at runtime, by Quarto's
# line-highlight plugin and reveal's fragment sort — the golden files cannot see
# it. fragment-order.js replays that in jsdom; it needs node, so the golden
# suite above stays runnable with nothing but quarto and this part is skipped
# when jsdom is missing.
if [[ ${#patterns[@]} -eq 0 ]] && (cd "$HERE" && node -e 'require("jsdom")') 2>/dev/null; then
	printf '\nfragment order\n'
	work=$(mktemp -d)
	cp -r "$HERE/../_extensions" "$HERE/fragment-order/input.qmd" "$work/"
	if (cd "$work" && QUARTO_PROJECT_DIR="$work" quarto render input.qmd) >"$work/out" 2>&1; then
		node "$HERE/fragment-order.js" "$work/input.html" || {
			rm -rf "$work"
			exit 1
		}
	else
		printf 'FAIL could not render the fragment-order fixture\n'
		cat "$work/out"
		rm -rf "$work"
		exit 1
	fi
	rm -rf "$work"
else
	printf '\nfragment order: skipped (needs node with jsdom)\n'
fi
