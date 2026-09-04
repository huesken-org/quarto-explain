-- Shared building blocks of the LaTeX branches.
--
-- Not a filter but a module: the explain-* filters load it via `dofile`, so the
-- line references are labelled the same way everywhere.

local M = {}

-- "8-9" -> "Lines 8–9", "3,7-9" -> "Lines 3, 7–9", "6" -> "Line 6"
--
-- `labels` carries the words to use (see `explain-util.lua`, where they are read
-- from the document metadata) — they are language dependent, the rest of the
-- formatting is not.
function M.lines_label(spec, labels)
	local parts = {}
	for part in spec:gmatch("[^,]+") do
		part = part:gsub("^%s+", ""):gsub("%s+$", "")
		table.insert(parts, (part:gsub("%s*%-%s*", "–")))
	end
	local text = table.concat(parts, ", ")
	local plural = #parts > 1 or spec:find("%-")
	return (plural and labels.lines or labels.line) .. " " .. text
end

-- The bold line reference that opens an explanation on paper: "**Line 6** — ".
-- Returns an empty list for a step without a line reference, so the caller can
-- hand the result straight to `labelled`.
function M.line_ref(spec, labels)
	if not spec or spec == "" then
		return {}
	end
	return { pandoc.Strong({ pandoc.Str(M.lines_label(spec, labels)) }), pandoc.Str(" — ") }
end

-- The same, for a reference that names several listings ("left Line 1 · right
-- Line 1"): the caller has already joined the parts.
function M.joined_ref(text)
	if text == "" then
		return {}
	end
	return { pandoc.Strong({ pandoc.Str(text) }), pandoc.Str(" — ") }
end

-- Prepare code for the listing: the stepper's segment syntax is meaningless on
-- paper (and would multiply the block via line-highlight); real line numbers for
-- the explanations to refer to take its place.
function M.numbered(code_block)
	code_block.attributes["code-line-numbers"] = nil
	if not code_block.classes:includes("numberLines") then
		code_block.classes:insert("numberLines")
	end
	return code_block
end

-- An explanation step as a list item: `label` (inlines) is prepended to the
-- first paragraph so it does not become a block of its own.
function M.labelled(blocks, label)
	blocks = pandoc.Blocks(blocks)
	if #label == 0 then
		return blocks
	end
	if #blocks > 0 and (blocks[1].t == "Para" or blocks[1].t == "Plain") then
		local inlines = pandoc.List(label)
		inlines:extend(blocks[1].content)
		blocks[1] = pandoc.Para(inlines)
	else
		blocks:insert(1, pandoc.Para(label))
	end
	return blocks
end

return M
