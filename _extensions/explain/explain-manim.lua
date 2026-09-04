local pandoc = pandoc

local _explain = dofile(pandoc.path.directory(PANDOC_SCRIPT_FILE) .. "/explain-util.lua")

-- A manim animation with one explanation per section:
--
--   :::: {.explain-manim}
--   ```{.python .manim}
--   <manim-code>
--   ```
--   ::: {section="start"}
--   <text>
--   :::
--   ::::
--
-- Becomes a `.stepper`: the animation (driven by `section-fragments`) beside the
-- explanations, which become `.step-control` entries. `stepper.lua` turns those
-- into reveal fragments or the button stepper.
--
-- Layout by target:
--   * revealjs: a Quarto layout div (`layout=`, default "[0.5, 0.5]"); `.below`
--       stacks instead — animation on top at full width.
--   * website: animation on top, control underneath.
--   * latex: no stepper and no video — each step gets the still frame of its own
--       section above its text.
--
-- `.intro` and `.comment` work as in explain-code.lua; see explain-util.lua.

local function explain_manim(el)
	if not el.classes:includes("explain-manim") then
		return nil
	end

	local layout = el.attributes["layout"] or "[0.5, 0.5]"
	local is_reveal = quarto.doc.is_format("revealjs")

	local manim_block = nil
	local intro_block = nil
	local explanations = {} -- list of {section, content}

	for _, block in ipairs(el.content) do
		if block.t == "Para" and #block.content == 0 then
			-- skip blank paragraphs
		elseif _explain.is_manim_block(block) then
			manim_block = block
		elseif block.t == "Div" then
			if block.classes:includes("intro") then
				intro_block = block
			else
				table.insert(explanations, {
					section = block.attributes["section"],
					content = block.content,
					is_comment = block.classes:includes("comment"),
					attr = block.attr,
				})
			end
		else
			table.insert(explanations, {
				section = nil,
				content = pandoc.Blocks({ block }),
			})
		end
	end

	if not manim_block then
		error("explain-manim: no .python.manim code block found")
	end
	if #explanations == 0 then
		error("explain-manim: no explanation steps found")
	end

	local steps, comments = _explain.partition(explanations)

	-- Build section-fragments="start|main||end" from section attributes.
	-- Prepend intro as step 0 (empty section) on revealjs.
	local sections = {}
	local control_entries = {}

	if intro_block and is_reveal then
		table.insert(sections, "")
		table.insert(control_entries, _explain.intro_step(intro_block))
	end

	-- `.hide-code` leaves the step sequence and becomes its own `.r-stack` layer.
	local hide_code = {}
	for _, exp in ipairs(is_reveal and explanations or steps) do
		if _explain.is_hide_code(exp) then
			table.insert(hide_code, exp)
		else
			table.insert(sections, exp.section or "")
			table.insert(control_entries, _explain.control_entry(exp))
		end
	end

	-- latex: the manim block is copied per step and restricted with
	-- `only-section`, so each step gets the still frame of its own section. Same
	-- content means the same hash, so manim still runs only once.
	if quarto.doc.is_format("latex") then
		local out = pandoc.List()
		if intro_block then
			out:insert(_explain.intro_div(intro_block))
		end
		for _, exp in ipairs(steps) do
			local step = pandoc.List()
			if exp.section and exp.section ~= "" then
				local copy = manim_block:clone()
				copy.attributes["only-section"] = exp.section
				step:insert(copy)
			end
			for _, b in ipairs(exp.content) do
				step:insert(b)
			end
			out:insert(pandoc.Div(step, pandoc.Attr("", { "manim-step" })))
		end
		for _, exp in ipairs(comments) do
			out:insert(_explain.comment_div(exp))
		end
		return pandoc.Div(out, pandoc.Attr("", { "explain-manim-print" }))
	end

	_explain.add_css()

	manim_block.attributes["section-fragments"] = table.concat(sections, "|")

	local anim_col = pandoc.Div(manim_block, pandoc.Attr("", { "explain-manim-animation" }))

	local step_control = pandoc.Div(control_entries, pandoc.Attr("", { "step-control" }))

	local layout_div
	if is_reveal and el.classes:includes("below") then
		-- `.below`: animation on top at full width — for wide scenes that would
		-- be too small in half a slide. `layout=` is dropped.
		layout_div = pandoc.Div({ anim_col, step_control }, pandoc.Attr("", { "explain-below" }))
	elseif is_reveal then
		layout_div = pandoc.Div(
			{ anim_col, step_control },
			pandoc.Attr("", {}, { layout = layout })
		)
	else
		-- website: animation on top, control underneath. Side by side, the taller
		-- column dictated the height and looked lopsided once the prose outgrew
		-- the animation.
		layout_div = pandoc.Div({ anim_col, step_control })
	end

	local stepper_body = { layout_div }
	if #hide_code > 0 then
		stepper_body = { _explain.hide_code_stack(layout_div, hide_code, control_entries, el.attributes["gravity"]) }
	end
	local stepper = pandoc.Div(stepper_body, pandoc.Attr("", { "stepper" }))

	if is_reveal then
		return stepper
	end
	return _explain.website_wrap(stepper, intro_block, comments)
end

return { Div = explain_manim }
