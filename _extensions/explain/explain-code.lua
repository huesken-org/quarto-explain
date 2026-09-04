local pandoc = pandoc

local _latex = dofile(pandoc.path.directory(PANDOC_SCRIPT_FILE) .. "/latex-util.lua")
local _explain = dofile(pandoc.path.directory(PANDOC_SCRIPT_FILE) .. "/explain-util.lua")

-- Transforms:
--
--   ::: {.explain-code}
--   ```{.py}
--   <code>
--   ```
--   :::: {.intro}
--   Optional, before step 1
--   ::::
--   :::: {lines="1-5"}
--   Explain
--   ::::
--   :::
--
-- revealjs: a `.stepper` block — the code keeps its classes and gets a
-- `code-line-numbers` built from the `lines=` attributes (missing = empty
-- segment), the explanations become `.step-control` entries, and the two sit
-- side by side in a layout div (`layout=`, default "[0.5, 0.5]"). Each
-- explanation is wrapped in a div so a multi-block one stays a single step.
-- `stepper.lua` turns that into reveal fragments later.
--
-- website: an *annotated* block instead (`render_annotated`) — explain-code.js
-- hangs a numbered badge on every referenced line and links it to the
-- explanation below. Quarto's own code annotations cannot express this: they
-- bind one annotation to one line, in ascending order, while a step here marks
-- several lines, often non-contiguous, and two steps may share a line.
--
-- Two child divs mirror each other:
--
--   .intro    * revealjs: step 0, no highlight
--             * website: a div above the block, outside it
--   .comment  * revealjs: an ordinary step where it stands
--             * website: pulled below the annotations; `lines`/`mark` have no
--               effect there
--
-- Several `.comment`s keep their order. One written among the steps lands in the
-- middle on the slides but at the bottom on the website — write it last if you
-- want it last.

-- All step marks as one `;` list (website). `.comment` is left out — it is not
-- in the annotation list there, so its `mark` has no effect, as for `lines`.
local function collect_marks(explanations)
	local out = {}
	for _, exp in ipairs(explanations) do
		if not exp.is_comment and exp.mark and exp.mark ~= "" then
			table.insert(out, exp.mark)
		end
	end
	if #out == 0 then
		return nil
	end
	return table.concat(out, ";")
end

local comment_div, partition = _explain.comment_div, _explain.partition

-- website: code on top, explanations underneath. Those with `lines=` are
-- numbered and carry that number in data-index; explain-code.js puts the same
-- number on the code lines. Those without stay unnumbered and get `.no-marker`,
-- so the numbering never gains a gap.
local function render_annotated(code_block, explanations, intro_block)
	local steps, comments = partition(explanations)
	local entries = pandoc.List()
	local index = 0

	for _, exp in ipairs(steps) do
		local attr
		if exp.lines and exp.lines ~= "" then
			index = index + 1
			attr = pandoc.Attr("", { "explain-annotation" }, {
				{ "data-lines", exp.lines },
				{ "data-index", tostring(index) },
			})
		else
			attr = pandoc.Attr("", { "explain-annotation", "no-marker" }, {})
		end
		entries:insert(pandoc.Div(exp.content, attr))
	end

	-- Meaningless here, and would duplicate the block.
	code_block.attributes["code-line-numbers"] = nil

	local content = pandoc.List()
	content:insert(code_block)
	content:insert(pandoc.Div(entries, pandoc.Attr("", { "explain-annotations" })))
	-- `.comment`s sit below the annotation list, but still inside the block.
	for _, exp in ipairs(comments) do
		content:insert(comment_div(exp))
	end

	local block = pandoc.Div(content, pandoc.Attr("", { "explain-annotated" }))

	if intro_block then
		return pandoc.Div({ _explain.intro_div(intro_block), block })
	end
	return block
end

-- latex: line numbers on the code, and a list whose entries name the lines
-- ("Line 6") — on paper the number is the only anchor there is.
local function render_latex(code_block, explanations, intro_block)
	local steps, comments = partition(explanations)
	local content = pandoc.List()

	if intro_block then
		content:insert(_explain.intro_div(intro_block))
	end

	content:insert(_latex.numbered(code_block))

	local items = pandoc.List()
	for _, exp in ipairs(steps) do
		items:insert(_latex.labelled(exp.content, _latex.line_ref(exp.lines, _explain.labels)))
	end
	content:insert(pandoc.BulletList(items))

	-- As on the website: `.comment`s after the list, not as a list item.
	for _, exp in ipairs(comments) do
		content:insert(comment_div(exp))
	end

	return pandoc.Div(content, pandoc.Attr("", { "explain-print" }))
end

local function explain_code(el)
	if not el.classes:includes("explain-code") then
		return nil
	end

	local is_reveal = quarto.doc.is_format("revealjs")

	local code_block = nil
	local intro_block = nil
	local explanations = {} -- list of {lines=string|nil, content=Blocks}

	for _, block in ipairs(el.content) do
		if block.t == "Para" and #block.content == 0 then
			-- skip blank paragraphs
		elseif block.t == "CodeBlock" then
			code_block = block
		elseif block.t == "Div" then
			if block.classes:includes("intro") then
				intro_block = block
			else
				table.insert(explanations, {
					lines = block.attributes["lines"],
					mark = block.attributes["mark"],
					content = block.content,
					is_comment = block.classes:includes("comment"),
					attr = block.attr,
				})
			end
		else
			-- bare paragraph or other block — an unstyled explanation step, as in
			-- the other three constructs
			table.insert(explanations, { content = pandoc.Blocks({ block }) })
		end
	end

	if not code_block or #explanations == 0 then
		return nil
	end

	if quarto.doc.is_format("latex") then
		return render_latex(code_block, explanations, intro_block)
	end

	_explain.add_css()

	if not is_reveal then
		quarto.doc.add_html_dependency({
			name = "explain-code",
			version = "0.1.0",
			stylesheets = { "explain-code.css" },
			scripts = { "explain-code.js" },
		})
		-- Everything is shown at once here, so the marks merge into one.
		local marks = collect_marks(explanations)
		if marks then
			local existing = code_block.attributes["mark"]
			code_block.attributes["mark"] = (existing and existing ~= "") and (existing .. ";" .. marks) or marks
		end
		return render_annotated(code_block, explanations, intro_block)
	end

	-- revealjs from here on.
	--
	-- Build "|seg1|seg2|..." from lines attributes; missing lines = empty segment.
	-- The intro becomes step 0 (no highlight).
	local parts = {}
	local mark_parts = {}
	local control_entries = {}

	if intro_block then
		table.insert(parts, "")
		table.insert(mark_parts, "")
		table.insert(control_entries, _explain.intro_step(intro_block))
	end

	-- `.hide-code` leaves the step sequence — no caption entry, no segment — and
	-- becomes its own layer in the `.r-stack` below.
	local hide_code = {}
	local has_mark = false
	for _, exp in ipairs(explanations) do
		if _explain.is_hide_code(exp) then
			table.insert(hide_code, exp)
		else
			table.insert(parts, exp.lines or "")
			table.insert(mark_parts, _explain.escape_pipes(exp.mark or ""))
			has_mark = has_mark or (exp.mark ~= nil and exp.mark ~= "")
			table.insert(control_entries, _explain.control_entry(exp))
		end
	end

	code_block.attributes["code-line-numbers"] = table.concat(parts, "|")

	-- One mark per step, in the same `|` segmentation: the line-highlight plugin
	-- clones the <code> node per segment and code-mark.js takes the i-th clone.
	if has_mark then
		code_block.attributes["mark-steps"] = table.concat(mark_parts, "|")
	end

	local step_control = pandoc.Div(control_entries, pandoc.Attr("", { "step-control" }))

	-- `.below`: code on top at full slide width instead of the 50/50 columns —
	-- for code too wide for half a slide. A plain div suffices; two block
	-- elements stack by themselves. No effect on website and PDF, where the code
	-- is above the explanations anyway.
	local layout_div
	if el.classes:includes("below") then
		layout_div = pandoc.Div({ code_block, step_control }, pandoc.Attr("", { "explain-below" }))
	else
		layout_div = pandoc.Div({ code_block, step_control }, pandoc.Attr("", {}, {
			{ "layout", el.attributes["layout"] or "[0.5, 0.5]" },
			{ "layout-valign", el.attributes["layout-valign"] or "center" },
		}))
	end

	if #hide_code > 0 then
		local stack = _explain.hide_code_stack(layout_div, hide_code, control_entries, el.attributes["gravity"])
		return pandoc.Div({ stack }, pandoc.Attr("", { "stepper" }))
	end

	return pandoc.Div({ layout_div }, pandoc.Attr("", { "stepper" }))
end

-- Two passes so the configured wording is settled before the first div is
-- processed: within a single filter table the order of Meta and Div is not
-- guaranteed.
return {
	{ Meta = _explain.read_meta },
	{ Div = explain_code },
}
