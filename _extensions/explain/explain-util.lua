-- Shared building blocks of the explain-* filters. A module, not a filter: the
-- filters load it with `dofile`.
--
-- `.comment` is an explanation step that leaves the step sequence:
--   * revealjs: an ordinary step at its place in the source
--   * website/latex: pulled below the block, outside the steps
--
-- Its other classes and attributes are kept on the generated div, so another
-- filter of yours can find and fill it.

local M = {}

-- Every word these filters write themselves, settable from the `explain:`
-- metadata block. `line`/`lines` label the LaTeX line references ("Line 6",
-- "Lines 8–9"); `left`/`right` name the two listings of
-- `.explain-parallel-code` there when a block has no `filename`.
M.labels = {
	line = "Line",
	lines = "Lines",
	left = "left",
	right = "right",
}

local LABEL_KEYS = {
	["line-label"] = "line",
	["lines-label"] = "lines",
	["left-label"] = "left",
	["right-label"] = "right",
}

-- Runs as each filter's own first pass: within one filter table the order of
-- Meta and Div is not guaranteed.
function M.read_meta(meta)
	local opts = meta["explain"]
	if not opts then
		return
	end
	for key, field in pairs(LABEL_KEYS) do
		local value = opts[key]
		if value ~= nil then
			M.labels[field] = pandoc.utils.stringify(value)
		end
	end
end

-- `|` separates the steps in `mark-steps`, so a `|` in the search text (`||`)
-- has to be escaped. `code-mark` unescapes it again.
function M.escape_pipes(s)
	return (s:gsub("|", "\\|"))
end

-- Called once a construct is actually present, so a document without one gets
-- no CSS. Nothing to do for LaTeX — pandoc discards the dependency anyway.
function M.add_css()
	if quarto.doc.is_format("latex") then
		return
	end
	quarto.doc.add_html_dependency({
		name = "explain",
		version = "0.1.0",
		stylesheets = { "explain.css" },
	})
	if quarto.doc.is_format("revealjs") then
		quarto.doc.add_html_dependency({
			name = "explain-revealjs",
			version = "0.1.0",
			stylesheets = { "explain-revealjs.css" },
		})
	end
end

-- Split explanation steps from `.comment`s, keeping the order within each.
function M.partition(explanations)
	local steps, comments = {}, {}
	for _, exp in ipairs(explanations) do
		table.insert(exp.is_comment and comments or steps, exp)
	end
	return steps, comments
end

-- Instructions to us; must not reach the HTML as data attributes.
local CONTROL_ATTRS = {
	lines = true,
	lines1 = true,
	lines2 = true,
	mark = true,
	section = true,
}

-- Likewise for classes.
local CONTROL_CLASSES = {
	comment = true,
	["hide-code"] = true,
}

-- `.hide-code` — only meaningful on RevealJS, see `hide_code_stack`.
function M.is_hide_code(exp)
	return exp.is_comment and exp.attr.classes:includes("hide-code")
end

-- A `.comment` as a div, carrying the author's classes and attributes.
function M.comment_div(exp)
	local classes = pandoc.List({ "explain-comment" })
	for _, c in ipairs(exp.attr.classes) do
		if not CONTROL_CLASSES[c] then
			classes:insert(c)
		end
	end
	-- An ordered list of pairs, not a Lua table: `pairs` over a table has no
	-- defined order, so the attributes would come out shuffled differently on
	-- every run. Iterating the AttributeList with `ipairs` keeps the order the
	-- author wrote.
	local attributes = pandoc.List()
	for _, kv in ipairs(exp.attr.attributes) do
		if not CONTROL_ATTRS[kv[1]] then
			attributes:insert({ kv[1], kv[2] })
		end
	end
	return pandoc.Div(exp.content, pandoc.Attr(exp.attr.identifier, classes, attributes))
end

-- A `.comment` as a `.step-control` entry. The wrapper is mandatory:
-- `stepper.lua` makes a step out of a div or a para, and would drop anything
-- else the comment contains.
function M.comment_step(exp)
	return pandoc.Div({ M.comment_div(exp) }, pandoc.Attr("", {}))
end

-- One explanation as a `.step-control` entry. The wrapper div keeps a
-- multi-block explanation together as one step.
function M.control_entry(exp)
	if exp.is_comment then
		return M.comment_step(exp)
	end
	return pandoc.Div(exp.content, pandoc.Attr("", {}))
end

-- The `.intro` as step 0 of the caption sequence (reveal) …
function M.intro_step(intro_block)
	return pandoc.Div(intro_block.content, pandoc.Attr("", {}))
end

-- … and as the div above the construct (website, LaTeX).
function M.intro_div(intro_block)
	return pandoc.Div(intro_block.content, pandoc.Attr("", { "intro" }))
end

-- Website shape: intro above the stepper, `.comment`s below, both outside it.
-- Returns the stepper alone when there is neither, so the common case gains no
-- wrapper div.
function M.website_wrap(stepper, intro_block, comments)
	if not intro_block and #comments == 0 then
		return stepper
	end
	local out = pandoc.List()
	if intro_block then
		out:insert(M.intro_div(intro_block))
	end
	out:insert(stepper)
	for _, exp in ipairs(comments) do
		out:insert(M.comment_div(exp))
	end
	return pandoc.Div(out)
end

-- The manim block of a construct, as opposed to any other code block.
function M.is_manim_block(block)
	return block.t == "CodeBlock"
		and block.classes:includes("python")
		and block.classes:includes("manim")
end

-- `.hide-code`: give a large output the full width, but on the **same** slide,
-- so title, footnotes and notes survive. Layout and `.hide-code` comments become
-- layers of one `.r-stack`, which stacks them into a single grid cell.
--
-- The first layer sits one fragment past the last caption step: with C entries
-- the last is at C-2 (see `build_control_reveal`), so C-1 is free. `stepper.lua`
-- turns the `show-from`/`hide-from` below into reveal fragments.
--
-- `gravity` pins the layers to an edge instead of centring them; the default
-- `top` stops short code floating in a box spanned by a long output.
function M.hide_code_stack(layout_div, hide_code, control_entries, gravity)
	local n = math.max(#control_entries - 1, 0)
	local classes = pandoc.List({ "r-stack" })
	gravity = gravity or "top"
	if gravity ~= "center" then
		classes:insert("gravity-" .. gravity)
	end
	local layers = pandoc.List()
	layers:insert(pandoc.Div({ layout_div }, pandoc.Attr("", { "step" }, {
		{ "hide-from", tostring(n + 1) },
	})))
	for i, exp in ipairs(hide_code) do
		-- Ordered pairs, so the generated HTML is byte-stable across runs.
		local attrs = pandoc.List({ { "show-from", tostring(n + i) } })
		if i < #hide_code then
			attrs:insert({ "hide-from", tostring(n + i + 1) })
		end
		layers:insert(pandoc.Div({ M.comment_div(exp) }, pandoc.Attr("", { "step" }, attrs)))
	end
	return pandoc.Div(layers, pandoc.Attr("", classes))
end

return M
