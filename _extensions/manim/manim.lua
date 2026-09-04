local RENDERS_DIR = "manim_renders"

-- Filesystem base for the renders. Pandoc's CWD is the directory of the *source
-- file*, so a relative "manim_renders" would land next to a nested .qmd instead
-- of in the project root the generated URLs point at.
local function renders_root()
	local project = os.getenv("QUARTO_PROJECT_DIR")
	if project and project ~= "" then
		return project:gsub("/+$", "") .. "/" .. RENDERS_DIR
	end
	return RENDERS_DIR
end

-- Path prefix from the current document up to the project root, where
-- manim_renders lives: one "../" per directory of depth, "" at the root.
local function project_relative_prefix()
	local project = os.getenv("QUARTO_PROJECT_DIR")
	local input = (quarto and quarto.doc and quarto.doc.input_file)
		or (PANDOC_STATE and PANDOC_STATE.input_files and PANDOC_STATE.input_files[1])
	if not project or not input then
		return ""
	end
	project = project:gsub("/+$", "")
	local rel = input
	if input:sub(1, #project + 1) == project .. "/" then
		rel = input:sub(#project + 2)
	end
	local dir = rel:match("(.*)/[^/]*$") or ""
	local prefix = ""
	for _ in dir:gmatch("[^/]+") do
		prefix = prefix .. "../"
	end
	return prefix
end

-- Two outputs cannot do video and get the last frame of each section instead:
-- the PDF print of the deck (Chromium plays nothing while printing; switched on
-- with `manim-static-frames`) and the LaTeX target (always).
local static_frames = false

local function is_latex()
	return quarto.doc.is_format("latex")
end

-- `manim.css` stacks the section videos. `.no-transition` belongs to the
-- stepper stylesheet, which is always attached where the rule matters — those
-- steps only become fragments once stepper.lua has converted them. Called once
-- a block has actually rendered, so a document without one gets no CSS.
local function add_css()
	quarto.doc.add_html_dependency({
		name = "manim",
		version = "0.1.0",
		stylesheets = { "manim.css" },
	})
end

local function exists(path)
	local f = io.open(path, "r")
	if f then
		f:close()
		return true
	end
	return false
end

-- The last frame of a section video as a PNG next to it, returned
-- project-relative (nil if ffmpeg is missing or fails). Cached like the renders:
-- the directory is content-hashed, so a changed video has a different one.
local function last_frame(video_name, sections_dir, rel_base)
	local png_name = (video_name:gsub("%.mp4$", "")) .. "-last.png"
	local png_fs = sections_dir .. "/" .. png_name

	if not exists(png_fs) then
		local video_fs = sections_dir .. "/" .. video_name
		-- `-sseof -0.3` seeks to just before the end, `-update 1` writes every
		-- further frame into the same file — what remains is the last one.
		-- (`-update` is an output option, so it has to come after the `-i`.)
		local ffmpeg = "ffmpeg -y -nostdin -loglevel error "
		os.execute(ffmpeg .. "-sseof -0.3 -i '" .. video_fs .. "' -update 1 '" .. png_fs .. "' 2>/dev/null")

		-- For very short clips the seek to the end fails; then decode the whole
		-- video instead.
		if not exists(png_fs) then
			os.execute(ffmpeg .. "-i '" .. video_fs .. "' -update 1 '" .. png_fs .. "' 2>/dev/null")
		end
	end

	if exists(png_fs) then
		return rel_base .. "/" .. png_name
	end
	return nil
end

-- Cache key of a scene. 16 hex characters is plenty to keep the scenes of one
-- project apart, and short enough to stay readable in a URL.
local function hash_content(content)
	return pandoc.utils.sha1(content):sub(1, 16)
end

local function find_sections_json(render_dir)
	local pipe = io.popen("find '" .. render_dir .. "'/media/videos/main -type f -name '*.json' 2>/dev/null | head -1")
	local path = pipe:read("*l")
	pipe:close()
	if path and path ~= "" then
		return path
	end
	return nil
end

local function render_manim(el)
	local is_reveal = quarto.doc.is_format("revealjs")
	local code = el.text
	local hash = hash_content(code)
	-- render_dir = path on disk, rel_dir = the same place project-relative
	-- (the base for the src URLs).
	local render_dir = renders_root() .. "/" .. hash
	local rel_dir = RENDERS_DIR .. "/" .. hash

	pandoc.system.make_directory(render_dir, true)

	local src = render_dir .. "/main.py"
	local f = io.open(src, "w")
	f:write(code)
	f:close()

	local sections_json = find_sections_json(render_dir)

	if not sections_json then
		local project_dir = os.getenv("QUARTO_PROJECT_DIR") or "."
		local cmd = 'sh -c "cd \'' .. render_dir .. '\' && PYTHONPATH=\'' .. project_dir .. '\' manim --save_sections main.py" 2>&1'
		os.execute(cmd)
		sections_json = find_sections_json(render_dir)
	end

	if not sections_json then
		return pandoc.CodeBlock("Error: manim rendering failed or produced no sections")
	end

	local jf = io.open(sections_json, "r")
	local json_content = jf:read("*all")
	jf:close()

	local sections = pandoc.json.decode(json_content)

	-- `find` echoes the path back with render_dir as its prefix; for the src URL
	-- we need the same place project-relative.
	local sections_dir = sections_json:match("(.+)/[^/]+$")
	local sections_path = rel_dir .. sections_dir:sub(#render_dir + 1)
	local frag_index = -1

	local section_frag_map = {}
	local sf_attr = el.attributes["section-fragments"]
	if sf_attr then
		local idx = -1
		for entry in (sf_attr .. "|"):gmatch("([^|]*)|") do
			if entry ~= "" then
				section_frag_map[entry] = idx
			end
			idx = idx + 1
		end
	end

	local videos = {}
	for _, section in ipairs(sections) do
		local name = section["name"] or ""
		-- find out the correct fragment index
		local frag_override = name:match("^(-?%d+)$")
		if frag_override then
			frag_index = tonumber(frag_override)
		elseif section_frag_map[name] ~= nil then
			frag_index = section_frag_map[name]
		end

		table.insert(videos, {
			name = name,
			frag_index = frag_index,
			video = section["video"],
			width = section["width"],
			height = section["height"],
		})

		-- next fragment
		frag_index = frag_index + 1
	end

	local children = {}
	local prefix = project_relative_prefix()

	-- LaTeX cannot do video: each section becomes its last frame. `only-section`
	-- restricts that to one section, so `explain-manim` can put the matching
	-- image next to each step.
	if is_latex() then
		local only = el.attributes["only-section"]
		local imgs = pandoc.List()
		for i = 1, #videos do
			if not only or only == "" or videos[i]["name"] == only then
				local png_rel = last_frame(videos[i]["video"], sections_dir, prefix .. sections_path)
				if png_rel then
					imgs:insert(pandoc.Para({
						pandoc.Image({}, png_rel, "", pandoc.Attr("", {}, { width = "100%" })),
					}))
				end
			end
		end
		if #imgs == 0 then
			-- Better to fail loudly than to silently print an empty page: the
			-- LaTeX writer would discard raw HTML without a word.
			error("manim: no still frame for the LaTeX target (is ffmpeg installed?)")
		end
		return pandoc.Div(imgs, pandoc.Attr("", { "manim-frames" }))
	end

	add_css()

	-- Each section video becomes a `.step` in an r-stack. Visibility is the
	-- stepper's job (show-from / hide-from -> fragments); `data-play-on` tells
	-- the script when to play. Coordinates are stepper steps (= fragment + 1).
	--
	-- Every video stays in place rather than being hidden at the next step
	-- (`stack`), which is what stops the flicker: a freshly revealed <video>
	-- paints nothing until a frame is decoded, and on revealjs the fragment
	-- cross-fade made both layers semi-transparent at once. Since the sections
	-- are gapless, video N+1 covers video N with a congruent still image, so
	-- there is nothing to see until it paints. `.manim-stack` does the same
	-- overlaying on the website, `.no-transition` removes the cross-fade.
	--
	-- Stacking needs ascending order: a numeric section name can reset the
	-- fragment index, and a jump backwards would put the wrong video on top.
	local stack = true
	for i = 2, #videos do
		if videos[i]["frag_index"] <= videos[i - 1]["frag_index"] then
			stack = false
		end
	end

	for i = 1, #videos do
		local video_rel = prefix .. sections_path .. "/" .. videos[i]["video"]
		local show_from = videos[i]["frag_index"] + 1

		-- Ordered pairs, so the generated HTML is byte-stable across runs.
		local attrs = pandoc.List({ { "show-from", tostring(show_from) } })
		if i < #videos and not stack then
			attrs:insert({ "hide-from", tostring(videos[i + 1]["frag_index"] + 1) })
		end

		-- From the sections JSON: reserves the box and aspect ratio before the
		-- clip loads, so revealing a step does not reflow the page.
		local size = ""
		local style = ""
		local w = tonumber(videos[i]["width"])
		local h = tonumber(videos[i]["height"])
		if w and h then
			size = ' width="' .. math.floor(w) .. '" height="' .. math.floor(h) .. '"'
		end
		-- `height: auto` is what keeps the aspect ratio: without it the height
		-- attribute stays the CSS height while the width is capped to the column,
		-- so the clip letterboxes inside a far too tall box and pushes the slide
		-- over its own height. The website additionally fills its container.
		if is_reveal then
			style = ' style="height: auto;"'
		else
			style = ' style="width: 100%; height: auto;"'
		end

		-- For printing, the last frame as an <img>; without ffmpeg the video
		-- stays and the render still goes through.
		local raw = nil
		if static_frames then
			local png_rel = last_frame(videos[i]["video"], sections_dir, prefix .. sections_path)
			if png_rel then
				raw = '<img src="' .. png_rel .. '" alt=""' .. size .. style .. ">"
			end
		end

		-- The URL must go in a <source> child, not video[src]: Quarto copies
		-- files made during the render only when it finds them referenced in the
		-- finished HTML, and it scans source[src] and img[src], not video[src].
		-- (`resources:` does not help — Quarto resolves the glob before the
		-- render, while manim_renders/ appears during it.)
		if not raw then
			raw = '<video muted playsinline preload="auto" data-play-on="'
				.. show_from
				.. '"'
				.. size
				.. style
				.. '><source src="'
				.. video_rel
				.. '" type="video/mp4"></video>'
		end
		local step_classes = { "step" }
		if stack and is_reveal then
			table.insert(step_classes, "no-transition")
		end

		local step = pandoc.Div(
			{ pandoc.Plain({ pandoc.RawInline("html", raw) }) },
			pandoc.Attr("", step_classes, attrs)
		)

		table.insert(children, step)
	end

	local stack_classes = { "r-stack" }
	if stack then
		table.insert(stack_classes, "manim-stack")
	end

	return pandoc.Div(children, pandoc.Attr("", stack_classes))
end

-- Two passes: within one filter table the order of Meta and CodeBlock is not
-- guaranteed.
return {
	{
		Meta = function(meta)
			local flag = meta["manim-static-frames"]
			if type(flag) == "boolean" then
				static_frames = flag
			elseif flag ~= nil then
				static_frames = pandoc.utils.stringify(flag) == "true"
			end
		end,
	},
	{
		CodeBlock = function(el)
			if el.classes:includes("python") and el.classes:includes("manim") then
				return render_manim(el)
			end
		end,
	},
}
