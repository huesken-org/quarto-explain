local pandoc = pandoc
local quarto = quarto

-- Transforms:
--
--   ::: {.stepper}
--   :::: {.step show-from="1" hide-from="4"}
--   <content>
--   ::::
--   :::: {.step-control}
--   <para0>
--   <para1>
--   ::::
--   :::
--
-- website: a button-driven stepper. Each `.step` keeps its show-from/hide-from
-- as data-* (readable via el.dataset, at any depth), the `.step-control`
-- entries become `.step-choice` divs, and a code block with
-- `code-line-numbers="6|7|8"` is expanded into one `.step` per segment — so you
-- write the code once instead of copying it per step. stepper.css and
-- stepper.js do the rest.
--
-- revealjs: native fragments instead (`render_reveal`). The code block stays
-- whole and reveal's line-highlight plugin clones it, the control becomes an
-- overlapping r-stack, and the remaining `.step` elements become fragments at
-- their show-from.
--
-- latex: everything at once, no stepper.

-- The accessible names of the two nav buttons, settable from the `stepper:`
-- metadata block. nil means "not configured": nothing is written and stepper.js
-- falls back to its own English default.
local labels = { prev = nil, next = nil }

local function read_meta(meta)
	local opts = meta["stepper"]
	if not opts then
		return
	end
	if opts["prev-label"] ~= nil then
		labels.prev = pandoc.utils.stringify(opts["prev-label"])
	end
	if opts["next-label"] ~= nil then
		labels.next = pandoc.utils.stringify(opts["next-label"])
	end
end

-- show-from / hide-from -> data-*. A step is visible while
-- show-from <= current < hide-from (hide-from exclusive).
local function move_attrs(d)
	if not d.classes:includes("step") then
		return d
	end
	if d.attributes["show-from"] then
		d.attributes["data-show-from"] = d.attributes["show-from"]
		d.attributes["show-from"] = nil
	end
	if d.attributes["hide-from"] then
		d.attributes["data-hide-from"] = d.attributes["hide-from"]
		d.attributes["hide-from"] = nil
	end
	return d
end

-- `code-line-numbers="seg0|seg1|..."` -> one `.step` per segment, each a copy
-- of the code pinned to its step index. An empty segment (a leading "|") gives a
-- step with no highlight. nil if the block has no code-line-numbers.
local function expand_code(cb)
	local spec = cb.attributes["code-line-numbers"]
	if not spec then
		return nil
	end

	local steps = pandoc.List()
	local k = 0
	for seg in (spec .. "|"):gmatch("([^|]*)|") do
		seg = seg:gsub("^%s+", ""):gsub("%s+$", "")
		local copy = cb:clone()
		copy.attributes["code-line-numbers"] = nil
		if seg ~= "" then
			copy.attributes["source-line-numbers"] = seg
		end
		steps:insert(pandoc.Div(
			{ copy },
			pandoc.Attr("", { "step" }, {
				{ "data-show-from", tostring(k) },
				{ "data-hide-from", tostring(k + 1) },
			})
		))
		k = k + 1
	end

	return pandoc.Div(steps, pandoc.Attr("", { "steps" }, {}))
end

-- What counts as one entry of a `.step-control`, and what its blocks are:
--
--   * a Para / Plain  -> one entry with that inline content (shorthand)
--   * a Div           -> one entry wrapping the whole div, so it may hold any
--                        block content; wrap a fenced div around anything you
--                        want grouped into one entry
--   * anything else   -> not an entry
--
-- All three render paths ask this one function, so they cannot disagree about
-- how many steps a construct has — a number `explain-*.lua` depends on too.
local function control_children(div)
	local out = pandoc.List()
	for _, blk in ipairs(div.content) do
		if blk.t == "Div" then
			out:insert(pandoc.Blocks({ blk }))
		elseif (blk.t == "Para" or blk.t == "Plain") and #blk.content > 0 then
			out:insert(pandoc.Blocks({ pandoc.Plain(blk.content) }))
		end
	end
	return out
end

-- Rebuild a .step-control div: each entry becomes a .step-choice div carrying
-- its 0-based index in data-step.
local function build_control(div)
	local choices = pandoc.List()
	for i, blocks in ipairs(control_children(div)) do
		choices:insert(pandoc.Div(
			blocks,
			pandoc.Attr("", { "step-choice" }, { { "data-step", tostring(i - 1) } })
		))
	end
	div.content = choices
	return div
end

-- ----------------------------------------------------------------------------
-- revealjs rendering: native fragments instead of buttons.

-- A `.step` -> reveal fragment(s) matching its show-from / hide-from.
--
-- Reveal's fragment index f starts at -1, which is stepper step 0, so
-- step = f + 1 and the step is visible while appear <= f < disappear:
--   appear    = show-from - 1   (-1 = from the start)
--   disappear = hide-from - 1   (nil = never)
--
-- Cases:
--   * visible from the start, forever     -> not a fragment (always visible)
--   * visible from the start, then hidden -> .fragment.fade-out @ disappear
--   * appears, then stays                 -> .fragment @ appear
--   * visible for a single step           -> .fragment.current-visible @ appear
--   * visible across several steps        -> nested: an inner .fragment fades
--                                            the content IN @ appear, the outer
--                                            .fragment.fade-out hides it @ disappear
-- show-from / hide-from are kept as data-* for the (later) script.
local function step_to_fragment(d)
	if not d.classes:includes("step") then
		return d
	end
	local sf = d.attributes["show-from"]
	local hf = d.attributes["hide-from"]
	move_attrs(d)

	local appear = (tonumber(sf) or 0) - 1
	local disappear = hf and (tonumber(hf) - 1) or nil

	if appear < 0 then
		if disappear ~= nil then
			d.classes:insert("fragment")
			d.classes:insert("fade-out")
			d.attributes["data-fragment-index"] = tostring(disappear)
		end
		-- else: always visible, leave as-is
	elseif disappear == nil then
		d.classes:insert("fragment")
		d.attributes["data-fragment-index"] = tostring(appear)
	elseif disappear <= appear + 1 then
		d.classes:insert("fragment")
		d.classes:insert("current-visible")
		d.attributes["data-fragment-index"] = tostring(appear)
	else
		local inner = pandoc.Div(
			d.content,
			pandoc.Attr("", { "fragment" }, { ["data-fragment-index"] = tostring(appear) })
		)
		d.content = { inner }
		d.classes:insert("fragment")
		d.classes:insert("fade-out")
		d.attributes["data-fragment-index"] = tostring(disappear)
	end

	return d
end

-- Keep a code block intact (do not split), but say which fragment its first
-- highlight step belongs to, so the highlights advance together with the
-- captions instead of after them.
--
-- This is *our* attribute, not one Quarto reads: it survives into the HTML as
-- `data-code-fragment-index` on the `div.sourceCode`, and stepper-revealjs.js
-- applies it to the clones that Quarto's line-highlight plugin makes. See the
-- long comment there for why the plugin cannot pick it up by itself.
local function add_code_fragment(cb)
	if cb.attributes["code-line-numbers"] then
		cb.attributes["code-fragment-index"] = "0"
	end
	return cb
end

-- The overlapping-fragment stack, which is what an `.r-stack-fragments` div and
-- a `.step-control` both become: a reveal `r-stack` whose layers replace one
-- another in place. The first layer is visible from the start and fades out, the
-- rest are `current-visible` and appear in turn.
--
-- Fragment indices, counting from `start`: layer 1 shows initially and fades at
-- `start`, layer k>=2 appears at `start + k - 2`. Layers 1 and 2 therefore share
-- an index — layer 1 fading out *is* layer 2 appearing.
--
-- `gravity` pins the layers to an edge of the grid cell instead of centring them
-- (stepper-revealjs.css); `no_transition` swaps reveal's cross-fade for an
-- instant switch, which is what stacked video wants.
local function fragment_stack(children, start, no_transition, gravity)
	for i, child in ipairs(children) do
		local first = i == 1
		child.classes:insert("fragment")
		child.classes:insert(first and "fade-out" or "current-visible")
		if no_transition then
			child.classes:insert("no-transition")
		end
		child.attributes["data-fragment-index"] = tostring(first and start or start + i - 2)
	end
	local classes = pandoc.List({ "r-stack" })
	if gravity and gravity ~= "" and gravity ~= "center" then
		classes:insert("gravity-" .. gravity)
	end
	return pandoc.Div(children, pandoc.Attr("", classes))
end

-- A block as a layer: a Div keeps its own identity (classes, attributes,
-- id), anything else gets a bare wrapper to hang the fragment classes on.
local function as_layer(blocks)
	return blocks[1].t == "Div" and blocks[1] or pandoc.Div(blocks, pandoc.Attr(""))
end

-- Turn a .step-control div into an overlapping caption stack.
local function build_control_reveal(div)
	local children = pandoc.List()
	for _, blocks in ipairs(control_children(div)) do
		children:insert(as_layer(blocks))
	end
	return fragment_stack(children, 0)
end

-- ----------------------------------------------------------------------------
-- `.r-stack-fragments`: lay the children of a div on top of one another and
-- reveal them one at a time.
--
--   ::: {.r-stack-fragments gravity="top"}
--   ::: {}
--   first
--   :::
--   ::: {}
--   replaces it
--   :::
--   :::
--
-- The same overlapping stack the caption column of a stepper uses, offered as an
-- authoring construct: anything that should occupy one spot on the slide and
-- change as you advance — a picture replaced by another, a formula rewritten, an
-- output growing.
--
-- | attribute / class | effect |
-- |---|---|
-- | `fragment-index="N"` | index of the first layer, so the stack can join an existing fragment sequence (default 0) |
-- | `gravity="top\|center\|bottom"` | which edge the layers align to (default `center`, reveal's own) |
-- | `.no-transition` | replace the cross-fade with an instant switch |
--
-- A child div becomes one layer and keeps its classes and attributes; any other
-- block gets wrapped in one. Blank paragraphs between fenced divs are skipped.
local function render_r_stack_fragments(el)
	-- Outside revealjs there are no fragments to stack: the children simply
	-- follow one another. The div is kept (minus the marker class) so an id or a
	-- class of the author's survives into the output.
	if not quarto.doc.is_format("revealjs") then
		local classes = pandoc.List()
		for _, c in ipairs(el.classes) do
			if c ~= "r-stack-fragments" then
				classes:insert(c)
			end
		end
		return pandoc.Div(el.content, pandoc.Attr(el.identifier, classes, el.attributes))
	end

	-- gravity and .no-transition are styled by this stylesheet.
	quarto.doc.add_html_dependency({
		name = "stepper-revealjs",
		version = "0.1.0",
		stylesheets = { "stepper-revealjs.css" },
		scripts = { "stepper-video.js", "stepper-revealjs.js" },
	})

	local children = pandoc.List()
	for _, block in ipairs(el.content) do
		-- skip the blank paragraphs between fenced divs
		if not (block.t == "Para" and #block.content == 0) then
			children:insert(as_layer(pandoc.Blocks({ block })))
		end
	end

	return fragment_stack(
		children,
		tonumber(el.attributes["fragment-index"]) or 0,
		el.classes:includes("no-transition"),
		el.attributes["gravity"]
	)
end

local function render_reveal(el)
	quarto.doc.add_html_dependency({
		name = "stepper-revealjs",
		version = "0.1.0",
		stylesheets = { "stepper-revealjs.css" },
		scripts = { "stepper-video.js", "stepper-revealjs.js" },
	})

	-- Walk the whole subtree so the code block / .step-control / .step elements
	-- are found at any depth (they may be wrapped in a layout div).
	return el:walk({
		CodeBlock = function(cb)
			return add_code_fragment(cb)
		end,
		Div = function(d)
			if d.classes:includes("step-control") then
				return build_control_reveal(d)
			end
			return step_to_fragment(d)
		end,
	})
end

-- ----------------------------------------------------------------------------
-- html (website) rendering: button-driven stepper.

local function render_html(el)
	quarto.doc.add_html_dependency({
		name = "stepper",
		version = "0.1.0",
		stylesheets = { "stepper.css" },
		scripts = { "stepper-video.js", "stepper.js" },
	})

	-- Walk the whole subtree so the code block / .step-control / .step elements
	-- are found at any depth (they may be wrapped in a layout div).
	local out = el:walk({
		CodeBlock = function(cb)
			-- code-line-numbers shorthand: expand into steps (or leave as-is)
			return expand_code(cb) or cb
		end,
		Div = function(d)
			if d.classes:includes("step-control") then
				return build_control(d)
			end
			return move_attrs(d)
		end,
	})

	-- The nav bar is built in the browser, so the button labels travel on the
	-- stepper element. Only written when configured — see `labels`.
	if labels.prev then
		out.attributes["data-prev-label"] = labels.prev
	end
	if labels.next then
		out.attributes["data-next-label"] = labels.next
	end

	return out
end

-- ----------------------------------------------------------------------------
-- latex: everything at once. What matters is what does *not* happen —
-- `expand_code` would print the same code once per highlight segment. Instead:
-- once, with line numbers, and the steps as a list underneath.
local function render_latex(el)
	return el:walk({
		CodeBlock = function(cb)
			if cb.attributes["code-line-numbers"] then
				cb.attributes["code-line-numbers"] = nil
				if not cb.classes:includes("numberLines") then
					cb.classes:insert("numberLines")
				end
			end
			return cb
		end,
		Div = function(d)
			if d.classes:includes("step-control") then
				local items = pandoc.List()
				for _, blocks in ipairs(control_children(d)) do
					-- On paper the entry's own wrapper adds nothing, so a Div
					-- entry contributes its contents rather than itself.
					items:insert(blocks[1].t == "Div" and pandoc.Blocks(blocks[1].content) or blocks)
				end
				return pandoc.BulletList(items)
			end
			if d.classes:includes("step") then
				-- Visibility bounds are meaningless on paper.
				d.attributes["show-from"] = nil
				d.attributes["hide-from"] = nil
			end
			return d
		end,
	})
end

local function stepper(el)
	-- Pandoc applies the filter to inner divs first, so an `.r-stack-fragments`
	-- nested inside a `.stepper` is already an `.r-stack` by the time we get to
	-- the stepper around it.
	if el.classes:includes("r-stack-fragments") then
		return render_r_stack_fragments(el)
	end
	if not el.classes:includes("stepper") then
		return nil
	end

	if quarto.doc.is_format("revealjs") then
		return render_reveal(el)
	end
	if quarto.doc.is_format("latex") then
		return render_latex(el)
	end
	return render_html(el)
end

-- Two passes so the configured wording is settled before the first div is
-- processed: within a single filter table the order of Meta and Div is not
-- guaranteed.
return {
	{ Meta = read_meta },
	{ Div = stepper },
}
