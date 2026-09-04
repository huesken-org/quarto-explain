# Example

A working Quarto project using all four extensions, every construct at least
once. Published on every push to `main`:
<https://huesken-org.github.io/quarto-explain/>.

| File | Shows |
|---|---|
| `home.qmd` | the landing page, linking every rendering |
| `index.qmd` | the tour — `explain`, `stepper`, `code-mark` |
| `localised.qmd` | the six configurable labels, set to German |
| `manim.qmd` | the manim constructs — needs manim |

## Rendering

```bash
cd example
quarto render                        # home + index + localised

pip install -r requirements.txt      # manim, pinned
quarto render --profile manim        # adds manim.qmd to the render set
```

Everything lands in `_output/`, which *is* the published site:

| | revealjs | html | pdf |
|---|---|---|---|
| `home.qmd` | — | `index.html` | — |
| `index.qmd` | `slides.html` | `website.html` | `handout.pdf` |
| `localised.qmd` | — | `localised-website.html` | `localised-handout.pdf` |
| `manim.qmd` | `manim-slides.html` | `manim-website.html` | `manim-handout.pdf` |

Open the deck and the website side by side — the same source, read two ways.

The pdf target needs LaTeX. Without it, `--to latex` writes the `.tex` and stops.

## Notes

`_extensions` is a symlink to this repo's, so the example exercises the working
tree. In your own project you would `quarto add huesken-org/quarto-explain`
instead; the `filters:` block in `_quarto.yml` is the same either way.

`manim.qmd` is not in the default `render:` list, so a plain `quarto render`
needs no Python. `_quarto-manim.yml` is a profile that adds it back — rendering
it through the profile rather than as a loose file matters, because only inside
the project does it inherit the filters, land in `_output/`, and get its videos
copied along.

Renders are cached content-hashed under `manim_renders/`; CI restores that cache
instead of re-rendering. The pdf also needs `ffmpeg` — LaTeX cannot play video,
so each step gets the still frame of its section.

## Publishing

`.github/workflows/pages.yml` runs both render commands on every push to `main`
and deploys `example/_output`. Needs **Settings → Pages → Source: GitHub
Actions** enabled once.
