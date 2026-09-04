-- Highlights **part of a code line** — a red box around a piece of text.
--
--     ```{.go mark="Rows - 1"}
--     ```{.go mark="5:Rows - 1"}                  -- search line 5 only
--     ```{.go mark="1:(col int);5:Rows - 1"}      -- several, separated by ;
--
-- Inside `.explain-code` the mark belongs on the explanation step rather than on
-- the block; `explain-code.lua` collects those and leaves a `mark-steps` here —
-- one mark per step, separated by `|`, in the same segmentation as
-- `code-line-numbers`:
--
--     :::: {lines="5" mark="Rows - 1"}
--     We count from the bottom up.
--     ::::
--
-- Without this there is no way to point at *this* spot: `code-line-numbers` and
-- the `lines="…"` steps of `.explain-code` can only take whole lines, and so can
-- Quarto's `code-annotations` (the issue asking for less, #11154, is closed as
-- "not planned").
--
-- Why the box is drawn at runtime instead of here: pandoc produces the syntax
-- highlighting itself, a filter only ever sees the raw code text. The token
-- spans a mark has to run across (`fmt` `.` `Errorf` are three spans) come into
-- existence after us. In the DOM, wrapping them is a standard problem — that is
-- what code-mark.js does.
--
-- So this filter does three things:
--   1. It checks **at build time** that the text is there at all. A typo in
--      `mark=` would otherwise stay silent.
--   2. It attaches the JS and CSS, but only when something is actually marked.
--   3. For LaTeX it removes the attributes again; there is no `data-*` there.

-- Quarto hands pandoc a temporary intermediate file, so `PANDOC_STATE.input_files`
-- points into /tmp. `quarto.doc.input_file` knows the real path but is not there
-- in every version — hence the fallback.
local function input_file()
	local ok, path = pcall(function()
		return quarto.doc.input_file
	end)
	if ok and type(path) == "string" and path ~= "" then
		return path
	end
	if PANDOC_STATE ~= nil and PANDOC_STATE.input_files ~= nil and #PANDOC_STATE.input_files > 0 then
		return PANDOC_STATE.input_files[1]
	end
	return "<unknown file>"
end

-- Aborts the render with a readable message.
local function fail(el, reason, hint)
	local first_line = (el.text:match("^%s*([^\n]+)") or ""):match("^%s*(.-)%s*$")
	local spec = el.attributes["mark"] or el.attributes["mark-steps"] or ""
	io.stderr:write("\n")
	io.stderr:write("=== code-mark: " .. reason .. " ===\n")
	io.stderr:write("  File       : " .. input_file() .. "\n")
	io.stderr:write("  Code block : " .. first_line .. "\n")
	io.stderr:write("  mark       : " .. spec .. "\n")
	io.stderr:write("\n  " .. hint .. "\n\n")
	os.exit(1)
end

-- Splits at `sep`, but not at an occurrence escaped with `\`.
--
-- Needed because both separators show up in real code: `;` in the head of a
-- classic `for` loop, `|` in every `||`. A `\` before anything else stays a `\` —
-- each level unescapes only its own separator, so the two (first `|`, then `;`)
-- do not get in each other's way.
--
-- Of the two, only `;` is visible to authors, and in a .qmd it needs **two**
-- backslashes (`\\;`): pandoc's attribute parser eats one. The `|` is only ever
-- split in the internally generated `mark-steps`, which never passes that parser
-- — explain-code.lua escapes it there itself.
local function split_escaped(s, sep)
	local out = {}
	local buf = {}
	local i = 1
	while i <= #s do
		local c = s:sub(i, i)
		if c == "\\" and s:sub(i + 1, i + 1) == sep then
			table.insert(buf, sep)
			i = i + 2
		elseif c == sep then
			table.insert(out, table.concat(buf))
			buf = {}
			i = i + 1
		else
			table.insert(buf, c)
			i = i + 1
		end
	end
	table.insert(out, table.concat(buf))
	return out
end

-- "5:Rows - 1" -> { line = 5, needle = "Rows - 1" }
-- "Rows - 1"   -> { line = nil, needle = "Rows - 1" }
local function parse_entry(part)
	local line, rest = part:match("^%s*(%d+)%s*:(.*)$")
	if line then
		return { line = tonumber(line), needle = rest }
	end
	return { line = nil, needle = (part:gsub("^%s+", "")) }
end

local function split_lines(text)
	local out = {}
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		table.insert(out, line)
	end
	-- the fence contributes an empty trailing line
	if out[#out] == "" then
		table.remove(out)
	end
	return out
end

-- Checks one `mark` spec against the displayed code.
local function validate(cb, spec, lines)
	for _, part in ipairs(split_escaped(spec, ";")) do
		if part:match("%S") then
			local e = parse_entry(part)
			if e.needle == "" then
				fail(cb, "empty search text", "Expected `mark=\"text\"` or `mark=\"line:text\"`.")
			end

			local haystack
			if e.line then
				if lines[e.line] == nil then
					fail(cb, "no line " .. e.line .. " (the block has " .. #lines .. ")",
						"Line numbers count the **displayed** code, like `lines=` in `.explain-code`.")
				end
				haystack = lines[e.line]
			else
				haystack = cb.text
			end

			if not haystack:find(e.needle, 1, true) then
				fail(cb, "text not found: " .. e.needle,
					"The search is literal, not a pattern. A typo, or did the code change?\n" ..
					"  A `;` that belongs to the search text is written `\\\\;` in the .qmd — two backslashes,\n" ..
					"  pandoc eats one while reading the attribute. A `|` needs nothing.\n" ..
					"  Without this check the slide would simply come out unmarked, and you would\n" ..
					"  find out while presenting.")
			end
		end
	end
end

function CodeBlock(cb)
	local spec = cb.attributes["mark"]
	local steps = cb.attributes["mark-steps"]
	if (spec == nil or spec == "") and (steps == nil or steps == "") then
		return nil
	end

	if quarto.doc.is_format("latex") then
		cb.attributes["mark"] = nil
		cb.attributes["mark-steps"] = nil
		return cb
	end

	local lines = split_lines(cb.text)

	if spec and spec ~= "" then
		validate(cb, spec, lines)
	end
	if steps and steps ~= "" then
		for _, step in ipairs(split_escaped(steps, "|")) do
			validate(cb, step, lines)
		end
	end

	quarto.doc.add_html_dependency({
		name = "code-mark",
		version = "0.1.0",
		scripts = { "code-mark.js" },
		stylesheets = { "code-mark.css" },
	})

	-- Quarto turns the unknown attributes into `data-mark` and `data-mark-steps`
	-- on the outer `div.sourceCode` by itself — which is exactly where
	-- code-mark.js looks for them.
	return cb
end
