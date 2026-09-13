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

-- Line names: a line of code may end in a comment `<line=name>`, and `lines=`
-- (`lines1=`/`lines2=`) may then use the name in place of numbers:
--
--     ```{.go}
--     row := b.freeRow(col)  // <line=find>
--     if row < 0 {           // <line=full>
--         return ErrColumnFull
--     }                      // <line=full>
--     ```
--     :::: {lines="full,2"}
--
-- A name stands for every line carrying it. The comment is removed from the
-- displayed code, together with the whitespace in front of it — before
-- `code-mark` searches the code and before anything counts lines.
--
-- How the comment is written depends on the language, taken from the code
-- block's first class. A language missing from the table accepts every syntax
-- listed here.

local LINE_COMMENT = {
	["//"] = { "c", "cpp", "cs", "csharp", "d", "dart", "fsharp", "go", "groovy", "java",
		"javascript", "js", "jsx", "kotlin", "objectivec", "php", "rust", "scala", "swift",
		"ts", "tsx", "typescript", "zig" },
	["#"] = { "bash", "cmake", "dockerfile", "elixir", "julia", "make", "makefile", "nim",
		"perl", "powershell", "py", "python", "r", "ruby", "sh", "shell", "toml", "yaml", "yml", "zsh" },
	["--"] = { "ada", "elm", "haskell", "lua", "sql" },
	["%"] = { "erlang", "latex", "matlab", "prolog", "tex" },
	[";"] = { "asm", "clojure", "commonlisp", "ini", "lisp", "scheme" },
}

local BLOCK_COMMENT = {
	{ "/*", "*/", { "css", "less", "scss" } },
	{ "<!--", "-->", { "html", "markdown", "md", "svg", "xml" } },
	{ "(*", "*)", { "ocaml", "pascal" } },
}

-- language -> list of { open, close }; `close` is "" for a line comment
local COMMENT_SYNTAX = {}
local ALL_SYNTAX = {}
for open, langs in pairs(LINE_COMMENT) do
	table.insert(ALL_SYNTAX, { open, "" })
	for _, lang in ipairs(langs) do
		COMMENT_SYNTAX[lang] = { { open, "" } }
	end
end
for _, entry in ipairs(BLOCK_COMMENT) do
	table.insert(ALL_SYNTAX, { entry[1], entry[2] })
	for _, lang in ipairs(entry[3]) do
		COMMENT_SYNTAX[lang] = { { entry[1], entry[2] } }
	end
end
-- Longest first, so `--` wins over a shorter opener that is a prefix of the
-- text; sorted at all because `pairs` above has no defined order.
table.sort(ALL_SYNTAX, function(a, b)
	if #a[1] ~= #b[1] then
		return #a[1] > #b[1]
	end
	return a[1] < b[1]
end)

local NAME = "[%w_%-]+"

local function pattern_escape(s)
	return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- Quarto hands pandoc a temporary intermediate file, so `PANDOC_STATE.input_files`
-- points into /tmp. `quarto.doc.input_file` knows the real path but is not there
-- in every version — hence the fallback. (Same as in code-mark.lua.)
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

-- Aborts the render with a readable message, in the shape code-mark uses.
local function fail_lines(code_block, reason, spec, hint)
	local first_line = (code_block.text:match("^%s*([^\n]+)") or ""):match("^%s*(.-)%s*$")
	io.stderr:write("\n")
	io.stderr:write("=== explain: " .. reason .. " ===\n")
	io.stderr:write("  File       : " .. input_file() .. "\n")
	io.stderr:write("  Code block : " .. first_line .. "\n")
	if spec then
		io.stderr:write("  lines      : " .. spec .. "\n")
	end
	io.stderr:write("\n  " .. hint .. "\n\n")
	os.exit(1)
end

local function language_of(code_block)
	return code_block.classes[1] and code_block.classes[1]:lower() or nil
end

-- Removes the `<line=name>` comments from `code_block.text` (in place) and
-- returns the names: name -> ascending list of line numbers. Aborts on a
-- `<line=…>` that stays behind because its comment syntax does not fit the
-- language — it would otherwise end up on the slide.
function M.take_line_names(code_block)
	local lang = language_of(code_block)
	local syntaxes = (lang and COMMENT_SYNTAX[lang]) or ALL_SYNTAX

	local names = {}
	local out = {}
	local n = 0
	local text = code_block.text
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		n = n + 1
		for _, syntax in ipairs(syntaxes) do
			local pattern = "^(.-)%s*" .. pattern_escape(syntax[1]) .. "%s*<line=(" .. NAME .. ")>%s*"
				.. pattern_escape(syntax[2]) .. "%s*$"
			local code, name = line:match(pattern)
			if code then
				line = code
				names[name] = names[name] or {}
				table.insert(names[name], n)
				break
			end
		end
		if line:match("<line=" .. NAME .. ">%s*%S*%s*$") then
			local expected = {}
			for _, syntax in ipairs(syntaxes) do
				table.insert(expected, "`" .. syntax[1] .. " <line=name>" .. (syntax[2] ~= "" and " " .. syntax[2] or "") .. "`")
			end
			fail_lines(code_block, "line " .. n .. ": `<line=…>` not recognised", nil,
				"Expected a comment at the end of the line: " .. table.concat(expected, " or ")
				.. "\n  (language: " .. (lang or "none") .. "). Otherwise it would stay in the displayed code.")
		end
		table.insert(out, line)
	end
	code_block.text = table.concat(out, "\n")
	return names
end

-- {2, 3, 4, 7} -> "2-4,7"
local function as_ranges(numbers)
	local parts = {}
	local i = 1
	while i <= #numbers do
		local j = i
		while j < #numbers and numbers[j + 1] == numbers[j] + 1 do
			j = j + 1
		end
		table.insert(parts, i == j and tostring(numbers[i]) or (numbers[i] .. "-" .. numbers[j]))
		i = j + 1
	end
	return table.concat(parts, ",")
end

-- Replaces the names in a `lines=` spec by their line numbers: "full,2" ->
-- "3-4,2". Numbers and ranges pass through untouched, nil stays nil.
function M.resolve_lines(spec, names, code_block)
	if not spec or spec == "" then
		return spec
	end
	local parts = {}
	for part in spec:gmatch("[^,]+") do
		local token = part:match("^%s*(.-)%s*$")
		if token:match("^%d+$") or token:match("^%d+%s*%-%s*%d+$") then
			table.insert(parts, token)
		elseif names[token] then
			table.insert(parts, as_ranges(names[token]))
		elseif token ~= "" then
			local known = {}
			for name in pairs(names) do
				table.insert(known, name)
			end
			table.sort(known)
			fail_lines(code_block, "unknown line name: " .. token, spec,
				"A name is defined by a comment `<line=" .. token .. ">` at the end of a line of this block.\n"
				.. "  Names in this block: " .. (#known > 0 and table.concat(known, ", ") or "none"))
		end
	end
	return table.concat(parts, ",")
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
