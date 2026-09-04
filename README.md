# quarto-explain

> [!NOTE]
> Built with AI

These Quarto extensions are how I built slides for presenting and a website
as well as a latex document for self studing from one source.

They allow stepping through a code block (or two in parallel), a manim animation
or both combined while giving explanations on each step.

> [!WARNING]
> Built for my own presentations. Fit for that, not promised to
> fit anything else.

On slides, the code and/or the manim animations are stepped through, highlighting
the current code lines and marking relevent keywords in the code while showing
explanations next to or below the code.

On the website, a pure code block is displayed with numberings next to the relevant lines
and the explanations in a list below (similar to quartos
[Code Annotation](https://quarto.org/docs/authoring/code-annotation.html)
but allowing multiple steps to reference the same line).

Manim animations as well as the manim-code combinations are shown in a "stepper"
where one can step through the animatins and explanations using buttons.

In latex (printable documents) the code is shown similar to the website with
explanations and line numbers below the code, while the animations are
converted to a still image of the last frame and shown has figures.

I use this normally with a "slides first" mindset, meaning I design explanations to
work best on slides and treat the website/latex as an additional benefit allowing me
to give the students a version of the slides that is slightly better for self study.

## Extensions

| Extension | Job |
|---|---|
| `explain` | the four constructs `.explain-code`, `.explain-parallel-code`, `.explain-manim`, `.explain-code-manim` |
| `stepper` | turns the generated `.stepper` structure into reveal fragments or the button stepper; also offers `.r-stack-fragments` |
| `manim` | runs `{.python .manim}` blocks and embeds the section videos |
| `code-mark` | draws a box around *part* of a code line |

## Example

`example/` uses all four, every construct at least once, in all three targets.
Published on every push to `main`:
**<https://huesken-org.github.io/quarto-explain/>**

```bash
cd example
quarto render                    # home + index + localised
quarto render --profile manim    # separately: needs manim
```

## Installation

```bash
quarto add huesken-org/quarto-explain
```

Then in `_quarto.yml` — **the order matters**:

```yaml
filters:
  - path: explain
    at: pre-ast
  - path: manim
    at: pre-ast
  - path: stepper
    at: pre-ast
  - path: code-mark
    at: pre-ast
```

- `explain` before `manim`: it sets `section-fragments` on the manim block.
- `stepper` before `code-mark`: it consumes the `.stepper` structure the others
  build.
- `code-mark` last, and after any filter of yours that changes the *displayed*
  code: it searches what the reader sees.
- `at: pre-ast` for all four. After Quarto's own filters a block with
  `filename=` is wrapped in a `.code-with-filename` div and no longer a
  `CodeBlock`.

The extensions bring their own CSS and JS.

## `explain`

One or two content blocks, then one div per explanation step. What a step
highlights is in its attributes.

### `.explain-code`

````markdown
::: {.explain-code}
```{.py}
total = 0
for row in rows:
    total += row.amount
```

:::: {.intro}
Optional preliminary note.
::::

:::: {lines="1" mark="total"}
Start at zero.
::::

:::: {lines="2-3"}
Add up every row.
::::
:::
````

| Output | Result |
|---|---|
| RevealJS | code left, steps right; `lines=` becomes `code-line-numbers="\|1\|2-3"` |
| Website | an *annotated* block: numbered badges on the lines, explanations below |
| LaTeX | listing with line numbers, below it “**Line 1** — Start at zero.” as a list |

| Attribute/class | Effect |
|---|---|
| `lines="3-5,7"` | lines of the step; without it the step highlights nothing |
| `mark="text"` | mark part of a line (see `code-mark`) |
| `layout="[0.5, 0.5]"` | column ratio (RevealJS) |
| `.below` | code on top at full width, explanations underneath |
| `gravity="top\|center\|bottom"` | layer alignment with `.hide-code` |

Quarto's own code annotations cannot express this: they bind one annotation to
one line, in ascending order, while a step here may mark several
non-contiguous lines and two steps may share a line.

### `.explain-parallel-code`

Two code blocks side by side, explanation underneath, `lines1=`/`lines2=` per
step — for what happens simultaneously on both sides.

### `.explain-manim` and `.explain-code-manim`

A manim animation instead of (or next to) the code block; `section="name"` binds
a step to a section of the scene. `.explain-code-manim` drives both from one
step with `lines=`, `mark=` and `section=`; its second code block may be in any
language.

In LaTeX each step gets the still frame of its own section above the text.

### `.intro` and `.comment`

Two child divs, in all four constructs:

| | RevealJS | Website / LaTeX |
|---|---|---|
| `.intro` | step 0, no highlight | a div above the block |
| `.comment` | an ordinary step where it stands | pulled below the block |

`.comment` keeps its other classes and attributes. `.comment .hide-code` hides
the code while the comment shows, leaving it the full width (slides only).

## `stepper`

````markdown
::: {.stepper}
```{.py code-line-numbers="1|2|1-2"}
a = 1
b = 2
```

:::: {.step-control}
First a.

Then b.

Both.
::::
:::
````

Becomes reveal fragments or a button-driven stepper. A `.step` div is bound to a
step index with `show-from`/`hide-from` and may sit at any depth. You rarely
write this by hand — `explain` produces it.

### `.r-stack-fragments`

The same overlapping stack, on its own — for anything that should occupy one
spot on the slide and change as you advance.

````markdown
::: {.r-stack-fragments}
::: {}
First, and it fades out.
:::

::: {}
Replaces it.
:::
:::
````

A child div becomes one layer and keeps its classes and attributes; any other
block is wrapped in one. Outside revealjs the layers simply follow one another.

| Attribute/class | Effect |
|---|---|
| `fragment-index="N"` | index of the first layer, to join a sequence already under way (default 0) |
| `gravity="top\|center\|bottom"` | which edge the layers align to (default `center`) |
| `.no-transition` | instant switch instead of the cross-fade |

## `manim`

Runs `{.python .manim}` blocks with `manim --save_sections` and embeds the
section videos as steps. Cached content-hashed under `manim_renders/<hash>/` in
the project root (gitignore it) — identical code is never rendered twice.

| Option | Effect |
|---|---|
| `section-fragments="a\|b\|c"` | fragment index per section (set by `explain-manim`) |
| `only-section="name"` | emit only this section (LaTeX, set by `explain-manim`) |
| metadata `manim-static-frames: true` | embed the last frame instead of the video, for the PDF print (needs `ffmpeg`) |

**Limit:** a manim block *outside* an `explain` construct yields `.step` divs
that nobody turns into fragments — `stepper` only reaches inside a `.stepper`
div. Wrap it in `::: {.stepper}` yourself.

## `code-mark`

`lines=` can only take whole lines; `mark=` points at a spot inside one:

````markdown
```{.py mark="row.amount"}
total += row.amount
```
````

| Spec | Meaning |
|---|---|
| `mark="text"` | every occurrence in the block |
| `mark="5:text"` | only in line 5 of the **displayed** code |
| `mark="1:one;5:other"` | several specs, separated by `;` |
| `mark="a\\; b"` | a `;` in the search text — **two** backslashes, pandoc eats one |

The search is literal and checked **at build time**: a typo aborts the render
instead of quietly producing an unmarked slide.

In `.explain-code` the mark belongs on the step, not on the block:

```markdown
:::: {lines="5" mark="row.amount"}
One field of the row.
::::
```

Those are collected into one `mark-steps` attribute whose `|`-segments line up
with `code-line-numbers` — one mark per step on the slides, merged on the
website, where everything shows at once.

The box is drawn at runtime by `code-mark.js`: a hit regularly runs across
several syntax-highlighting spans, which a filter cannot see. LaTeX gets
nothing.

## Configurable wording

Every word the extensions write themselves, set from the document or project
metadata. Defaults are English.

```yaml
explain:
  line-label: "Zeile"     # LaTeX: "Zeile 6"       (default "Line")
  lines-label: "Zeilen"   # LaTeX: "Zeilen 8–9"    (default "Lines")
  left-label: "links"     # LaTeX, .explain-parallel-code: the two listings
  right-label: "rechts"   #   when they have no `filename=`

stepper:
  prev-label: "Vorheriger Schritt"  # website: aria-label of the nav buttons
  next-label: "Nächster Schritt"
```

## Bundled assets

Attached only when a construct is actually present, so a document without one
gets no CSS:

| File | when |
|---|---|
| `explain/explain.css` | every HTML target, with an `explain-*` block |
| `explain/explain-revealjs.css` | RevealJS (`.below`) |
| `explain/explain-code.css` + `.js` | website: the annotated block |
| `stepper/stepper.css` + `.js` | website: the button stepper |
| `stepper/stepper-revealjs.css` + `.js` | RevealJS, incl. `gravity` and `.no-transition` |
| `stepper/stepper-video.js` | both HTML targets: video playback |
| `manim/manim.css` | every HTML target, with a manim block |
| `code-mark/code-mark.css` + `.js` | every HTML target, when something is marked |

## Tests

```bash
tests/run.sh                  # all cases
tests/run.sh manim latex      # only cases matching a pattern
tests/run.sh --update         # rewrite expected.txt (check the diff!)
```

Golden-file tests: each case under `tests/cases/` is an `input.qmd` naming its
own format and filter chain; compared is a recording of exit code, rendered
content, attached assets and warnings. `manim` and `ffmpeg` do not really run —
`tests/bin/` holds stubs — so the suite needs only quarto and runs in seconds.

`tests/fragment-order.js` additionally replays the *runtime* fragment sort in
jsdom: which step a code highlight appears on is settled by Quarto's
line-highlight plugin and reveal, not by the emitted HTML, so the golden files
are blind to it. Needs node with jsdom (`npm install --prefix tests`); skipped
otherwise.

When changing something: add a case, `--update`, read the diff, commit it.
