local pandoc = pandoc

local _latex = dofile(pandoc.path.directory(PANDOC_SCRIPT_FILE) .. "/latex-util.lua")
local _explain = dofile(pandoc.path.directory(PANDOC_SCRIPT_FILE) .. "/explain-util.lua")

-- An animation and a code block side by side, one step driving both:
--
--   :::: {.explain-code-manim}
--   ```{.python .manim}
--   <manim-code>
--   ```
--   ```{.py}
--   <code>          -- any language; the block that is not the manim block
--   ```
--   ::: {lines="1" section="start"}
--   <text>
--   :::
--   ::::
--
-- Becomes a `.stepper`: the animation (driven by `section-fragments`) and the
-- code (driven by `code-line-numbers`) in a layout div, the explanations in a
-- `.step-control` below. `mark=` works on a step as it does in explain-code.
--
-- latex: the listing once with line numbers, then per step the still frame of
-- its section above the text.
--
-- `.intro` and `.comment` work as in explain-code.lua; see explain-util.lua.

local function explain_code_manim(el)
	if not el.classes:includes("explain-code-manim") then
		return nil
	end

	local layout = el.attributes["layout"] or "[0.5, 0.5]"
	local is_reveal = quarto.doc.is_format("revealjs")

	local manim_block = nil
	local code_block = nil
	local intro_block = nil
	local explanations = {} -- list of {lines, section, mark, content}

	for _, block in ipairs(el.content) do
		if block.t == "Para" and #block.content == 0 then
			-- skip blank paragraphs between blocks
		elseif _explain.is_manim_block(block) then
			manim_block = block
		elseif block.t == "CodeBlock" then
			-- whatever language: the block that is not the manim block
			code_block = block
		elseif block.t == "Div" then
			if block.classes:includes("intro") then
				intro_block = block
			else
				table.insert(explanations, {
					lines = block.attributes["lines"],
					section = block.attributes["section"],
					mark = block.attributes["mark"],
					content = block.content,
					is_comment = block.classes:includes("comment"),
					attr = block.attr,
				})
			end
		else
			-- bare paragraph or other block — treat as an unstyled explanation step
			table.insert(explanations, { content = pandoc.Blocks({ block }) })
		end
	end

	if not manim_block then
		error("explain-code-manim: no .python.manim code block found")
	end
	if not code_block then
		error("explain-code-manim: no code block found beside the manim block")
	end
	if #explanations == 0 then
		error("explain-code-manim: no explanation steps found")
	end

	-- The manim block is copied per step and restricted with `only-section`;
	-- same content means the same hash, so manim still runs only once.
	if quarto.doc.is_format("latex") then
		local steps, comments = _explain.partition(explanations)
		local content = pandoc.List()
		if intro_block then
			content:insert(_explain.intro_div(intro_block))
		end
		content:insert(_latex.numbered(code_block))

		for _, exp in ipairs(steps) do
			local step = pandoc.List()
			if exp.section and exp.section ~= "" then
				local copy = manim_block:clone()
				copy.attributes["only-section"] = exp.section
				step:insert(copy)
			end
			local label = _latex.line_ref(exp.lines, _explain.labels)
			for _, b in ipairs(_latex.labelled(exp.content, label)) do
				step:insert(b)
			end
			content:insert(pandoc.Div(step, pandoc.Attr("", { "manim-step" })))
		end

		-- As on the website: `.comment`s after the steps.
		for _, exp in ipairs(comments) do
			content:insert(_explain.comment_div(exp))
		end

		return pandoc.Div(content, pandoc.Attr("", { "explain-print" }))
	end

	_explain.add_css()

	-- Build section-fragments and code-line-numbers from step attributes.
	-- Prepend intro as step 0 (empty section, no lines) on revealjs.
	local sections = {}
	local lines = {}
	local mark_parts = {}
	local control_entries = {}

	if intro_block and is_reveal then
		table.insert(sections, "")
		table.insert(lines, "")
		table.insert(mark_parts, "")
		table.insert(control_entries, _explain.intro_step(intro_block))
	end

	local steps, comments = _explain.partition(explanations)

	-- `.hide-code` leaves the step sequence and becomes its own `.r-stack` layer.
	local hide_code = {}
	local has_mark = false
	for _, exp in ipairs(is_reveal and explanations or steps) do
		if _explain.is_hide_code(exp) then
			table.insert(hide_code, exp)
		else
			table.insert(sections, exp.section or "")
			table.insert(lines, exp.lines or "")
			table.insert(mark_parts, _explain.escape_pipes(exp.mark or ""))
			has_mark = has_mark or (exp.mark ~= nil and exp.mark ~= "")
			table.insert(control_entries, _explain.control_entry(exp))
		end
	end

	manim_block.attributes["section-fragments"] = table.concat(sections, "|")
	code_block.attributes["code-line-numbers"] = table.concat(lines, "|")

	-- One mark per step, in the same `|` segmentation as code-line-numbers: the
	-- block is cloned per step on both HTML targets, and code-mark.js takes the
	-- i-th clone.
	if has_mark then
		code_block.attributes["mark-steps"] = table.concat(mark_parts, "|")
	end

	local step_control = pandoc.Div(control_entries, pandoc.Attr("", { "step-control" }))

	local layout_div = pandoc.Div({
		pandoc.Div(manim_block, pandoc.Attr("", { "explain-code-manim-animation" })),
		pandoc.Div(code_block, pandoc.Attr("", { "explain-code-manim-code" })),
	}, pandoc.Attr("", {}, { layout = layout }))

	local stepper_content = { layout_div, step_control }

	-- Animation, code and explanations as one layer, the outputs as further ones.
	if #hide_code > 0 then
		local body = pandoc.Div({ layout_div, step_control }, pandoc.Attr("", {}))
		stepper_content = { _explain.hide_code_stack(body, hide_code, control_entries, el.attributes["gravity"]) }
	end

	-- website: hang the `.comment`s below the stepper instead of making them steps.
	if not is_reveal then
		for _, exp in ipairs(comments) do
			table.insert(stepper_content, _explain.comment_div(exp))
		end
	end

	local stepper = pandoc.Div(stepper_content, pandoc.Attr("", { "stepper" }))

	-- website: place intro div above the stepper (outside it).
	if intro_block and not is_reveal then
		return pandoc.Div({ _explain.intro_div(intro_block), stepper })
	end

	return stepper
end

-- Two passes so the configured wording is settled before the first div is
-- processed: within a single filter table the order of Meta and Div is not
-- guaranteed.
return {
	{ Meta = _explain.read_meta },
	{ Div = explain_code_manim },
}
