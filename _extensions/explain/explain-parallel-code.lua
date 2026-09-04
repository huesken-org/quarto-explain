local pandoc = pandoc

local _latex = dofile(pandoc.path.directory(PANDOC_SCRIPT_FILE) .. "/latex-util.lua")
local _explain = dofile(pandoc.path.directory(PANDOC_SCRIPT_FILE) .. "/explain-util.lua")

-- Two code blocks side by side, the explanation underneath:
--
--   ::: {.explain-parallel-code}
--   ```{.py filename="Worker 1"}
--   ```
--   ```{.py filename="Worker 2"}
--   ```
--   :::: {lines1="2" lines2="2"}
--   Explain
--   ::::
--   :::
--
-- `lines1`/`lines2` drive `code-line-numbers` on the respective block; a missing
-- one means no highlight on that side for that step. `layout=` sets the column
-- widths (default "[0.5, 0.5]").
--
-- `.intro` and `.comment` work as in explain-code.lua; see explain-util.lua.

local function explain_parallel_code(el)
	if not el.classes:includes("explain-parallel-code") then
		return nil
	end

	local layout = el.attributes["layout"] or "[0.5, 0.5]"
	local is_reveal = quarto.doc.is_format("revealjs")

	local code_blocks = {}
	local intro_block = nil
	local explanations = {}

	for _, block in ipairs(el.content) do
		if block.t == "Para" and #block.content == 0 then
			-- skip blank paragraphs between blocks
		elseif block.t == "CodeBlock" then
			table.insert(code_blocks, block)
		elseif block.t == "Div" then
			if block.classes:includes("intro") then
				intro_block = block
			else
				table.insert(explanations, {
					lines1  = block.attributes["lines1"],
					lines2  = block.attributes["lines2"],
					content = block.content,
					is_comment = block.classes:includes("comment"),
					attr = block.attr,
				})
			end
		else
			-- bare paragraph / other block → unstyled explanation step
			table.insert(explanations, {
				lines1  = nil,
				lines2  = nil,
				content = pandoc.Blocks({ block }),
			})
		end
	end

	if #code_blocks < 2 then
		error("explain-parallel-code: need exactly two code blocks, found " .. #code_blocks)
	end
	if #explanations == 0 then
		error("explain-parallel-code: no explanation steps found")
	end

	local code1 = code_blocks[1]
	local code2 = code_blocks[2]
	local steps, comments = _explain.partition(explanations)

	-- latex: both listings with line numbers, the explanations as a list. Each
	-- step names the lines of both sides — on paper nothing else says what
	-- "here" refers to. The block's `filename` is its name, or the configurable
	-- left/right wording.
	if quarto.doc.is_format("latex") then
		local name1 = code1.attributes["filename"] or _explain.labels.left
		local name2 = code2.attributes["filename"] or _explain.labels.right

		local content = pandoc.List()
		if intro_block then
			content:insert(_explain.intro_div(intro_block))
		end
		content:insert(_latex.numbered(code1))
		content:insert(_latex.numbered(code2))

		local items = pandoc.List()
		for _, exp in ipairs(steps) do
			local refs = {}
			if exp.lines1 and exp.lines1 ~= "" then
				table.insert(refs, name1 .. " " .. _latex.lines_label(exp.lines1, _explain.labels))
			end
			if exp.lines2 and exp.lines2 ~= "" then
				table.insert(refs, name2 .. " " .. _latex.lines_label(exp.lines2, _explain.labels))
			end
			items:insert(_latex.labelled(exp.content, _latex.joined_ref(table.concat(refs, " · "))))
		end
		content:insert(pandoc.BulletList(items))
		for _, exp in ipairs(comments) do
			content:insert(_explain.comment_div(exp))
		end

		return pandoc.Div(content, pandoc.Attr("", { "explain-print" }))
	end

	_explain.add_css()

	-- Build code-line-numbers="seg1|seg2|..." for each block independently.
	-- Prepend intro as step 0 (no highlights) on revealjs.
	local parts1, parts2 = {}, {}
	local control_entries = {}

	if intro_block and is_reveal then
		table.insert(parts1, "")
		table.insert(parts2, "")
		table.insert(control_entries, _explain.intro_step(intro_block))
	end

	-- `.hide-code` leaves the step sequence and becomes its own `.r-stack` layer.
	local hide_code = {}
	for _, exp in ipairs(is_reveal and explanations or steps) do
		if _explain.is_hide_code(exp) then
			table.insert(hide_code, exp)
		else
			table.insert(parts1, exp.lines1 or "")
			table.insert(parts2, exp.lines2 or "")
			table.insert(control_entries, _explain.control_entry(exp))
		end
	end

	code1.attributes["code-line-numbers"] = table.concat(parts1, "|")
	code2.attributes["code-line-numbers"] = table.concat(parts2, "|")

	local step_control = pandoc.Div(control_entries, pandoc.Attr("", { "step-control" }))

	local layout_div = pandoc.Div(
		{ code1, code2 },
		pandoc.Attr("", {}, { { "layout", layout }, { "layout-valign", "top" } })
	)

	local stepper_body = { layout_div, step_control }
	if #hide_code > 0 then
		local body = pandoc.Div(stepper_body, pandoc.Attr("", {}))
		stepper_body = { _explain.hide_code_stack(body, hide_code, control_entries, el.attributes["gravity"]) }
	end
	local stepper = pandoc.Div(stepper_body, pandoc.Attr("", { "stepper" }))

	if is_reveal then
		return stepper
	end
	return _explain.website_wrap(stepper, intro_block, comments)
end

-- Two passes so the configured wording is settled before the first div is
-- processed: within a single filter table the order of Meta and Div is not
-- guaranteed.
return {
	{ Meta = _explain.read_meta },
	{ Div = explain_parallel_code },
}
