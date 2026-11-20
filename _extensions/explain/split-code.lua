local pandoc = pandoc

local _explain = dofile(pandoc.path.directory(PANDOC_SCRIPT_FILE) .. "/explain-util.lua")

-- A plain code block with a `<split>` marker line (see explain-util.lua):
--
--   ```{.go filename="counter.go" startFrom="10"}
--   func Inc() { … }
--   // <split>
--   func Report() { … }
--   ```
--
-- revealjs: the two halves side by side in a layout div (`split-layout=` on the
--           block, default "[0.5, 0.5]"); the right one continues the line
--           numbers of the left
-- website / latex: one block, the marker line removed
--
-- Runs after the four explain-* filters: `.explain-code` handles its own
-- marker, so what reaches this filter with a marker in it sits somewhere a split
-- means nothing — a block those filters have already turned into steps (it
-- carries `code-line-numbers`) is rejected rather than cut apart after the fact.

local function split_code(block)
	local probe = block:clone()
	local n = _explain.take_split(probe)
	if not n then
		return nil
	end

	if block.attributes["code-line-numbers"] then
		_explain.fail_split(block, "`<split>` is only supported in a plain code block and in `.explain-code`",
			"Remove the marker, or use two code blocks in `.explain-parallel-code`.")
	end
	if block.classes:includes("run") then
		-- go-cell and similar runners come later and would execute two fragments.
		_explain.fail_split(block, "`<split>` in an executed (`.run`) block",
			"Show a copy of the code with the marker and run the original in a hidden block.")
	end

	local layout = probe.attributes["split-layout"] or "[0.5, 0.5]"
	probe.attributes["split-layout"] = nil

	if not quarto.doc.is_format("revealjs") then
		return probe
	end

	local left, right = _explain.split_at(probe, n)
	return pandoc.Div({ left, right }, pandoc.Attr("", { "split-code" }, {
		{ "layout", layout },
		{ "layout-valign", "top" },
	}))
end

return {
	{ CodeBlock = split_code },
}
