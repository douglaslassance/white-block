-- White Block — Aseprite Extension
-- Exports each visible leaf layer as an individual trimmed PNG and generates
-- a Lua layout manifest with canvas-space center positions for sprite.moveTo().
--
-- Naming:  {scene}-{group}-{subgroup}-{layer}.png  (groups joined with dashes)
-- Rules:
--   Hidden layers are not exported.
--   Layers/groups whose name ends with "preview" are skipped (children too).
--   Layers whose name ends with "mask" are exported and flagged in the manifest.
--   Groups are never exported as composites — only used for naming.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Aseprite throws (not nil) when accessing a field that doesn't exist on userdata.
-- Sprites have no .name, so walking up to the root via layer.parent needs a guard.
local function isLayer(obj)
    local ok = pcall(function() return obj.name end)
    return ok
end

-- Returns the ancestor chain as an ordered array, e.g. {"water", "background"}.
-- Does not include the sprite root.
local function getPath(layer)
    local path = {}
    local cur = layer
    while cur and isLayer(cur) do
        table.insert(path, 1, cur.name)
        cur = cur.parent
    end
    return path
end

-- Returns true only if the layer AND all its ancestor groups are visible.
local function isEffectivelyVisible(layer)
    if not layer.isVisible then return false end
    local parent = layer.parent
    while parent and isLayer(parent) do
        if not parent.isVisible then return false end
        parent = parent.parent
    end
    return true
end

-- Strips instance-related suffixes ("-left-instance", "-right-instance", "-instance",
-- or bare "instance") from a layer name, including any trailing separator dash.
-- Used for image filenames where left/right share the same file.
local function cleanName(name)
    local lname = name:lower()
    if lname:sub(-#"left-instance") == "left-instance" then
        return name:sub(1, #name - #"left-instance"):gsub("%-$", "")
    elseif lname:sub(-#"right-instance") == "right-instance" then
        return name:sub(1, #name - #"right-instance"):gsub("%-$", "")
    elseif lname:sub(-#"instance") == "instance" then
        return name:sub(1, #name - #"instance"):gsub("%-$", "")
    end
    return name
end

-- Strips instance suffixes ("-instance") from a layer name for JSON display,
-- preserving directional prefixes ("left", "right") so mirrored pairs stay distinct.
local function cleanDisplayName(name)
    local lname = name:lower()
    if lname:sub(-#"-instance") == "-instance" then
        return name:sub(1, #name - #"-instance")
    elseif lname:sub(-#"instance") == "instance" then
        return name:sub(1, #name - #"instance"):gsub("%-$", "")
    end
    return name
end

-- Returns true if any component of the path ends with "preview" (case-insensitive).
local function shouldSkip(path)
    for _, part in ipairs(path) do
        if part:lower():sub(-#"preview") == "preview" then return true end
    end
    return false
end

-- Recursively collects visible image leaf layers, top-most first.
-- Iterates in reverse so that the first result is the topmost (highest z) layer.
local function collectLeaves(container, result)
    result = result or {}
    for i = #container.layers, 1, -1 do
        local layer = container.layers[i]
        if layer.isGroup then
            collectLeaves(layer, result)
        elseif layer.isImage and isEffectivelyVisible(layer) then
            table.insert(result, layer)
        end
    end
    return result
end

-- Returns the canvas-space center (x, y) of a layer's trimmed content.
-- Returns nil if the layer has no visible content.
local function getCenter(layer, frame)
    local cel = layer:cel(frame)
    if not cel then return nil end
    local trimRect = cel.image:shrinkBounds()
    if trimRect.width == 0 or trimRect.height == 0 then return nil end
    local cx = math.floor(cel.position.x + trimRect.x + trimRect.width  / 2 + 0.5)
    local cy = math.floor(cel.position.y + trimRect.y + trimRect.height / 2 + 0.5)
    return cx, cy
end

-- Returns the canvas-space bounding box (minX, minY, maxX, maxY) of all visible,
-- non-skipped image leaf descendants of a container for the given frame.
-- Returns nil when the container has no visible content.
local function getGroupBounds(container, frame)
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    local function visit(c)
        for i = 1, #c.layers do
            local layer = c.layers[i]
            if isEffectivelyVisible(layer) and not shouldSkip(getPath(layer)) then
                if layer.isGroup then
                    visit(layer)
                elseif layer.isImage then
                    local cel = layer:cel(frame)
                    if cel then
                        local tr = cel.image:shrinkBounds()
                        if tr.width > 0 and tr.height > 0 then
                            local x1 = cel.position.x + tr.x
                            local y1 = cel.position.y + tr.y
                            local x2 = x1 + tr.width
                            local y2 = y1 + tr.height
                            if x1 < minX then minX = x1 end
                            if y1 < minY then minY = y1 end
                            if x2 > maxX then maxX = x2 end
                            if y2 > maxY then maxY = y2 end
                        end
                    end
                end
            end
        end
    end
    visit(container)
    if minX == math.huge then return nil end
    return minX, minY, maxX, maxY
end

-- Given a set of full layer paths and a target leaf name, returns the deduplicated
-- filename stem: scene + longest-common-prefix-of-all-paths + leafName.
local function commonPrefixFilename(paths, leafName, prefix, sep)
    local maxPrefix = math.huge
    for _, p in ipairs(paths) do maxPrefix = math.min(maxPrefix, #p - 1) end
    local prefixLen = 0
    for i = 1, maxPrefix do
        local allMatch = true
        for _, p in ipairs(paths) do
            if p[i] ~= paths[1][i] then allMatch = false; break end
        end
        if allMatch then prefixLen = i else break end
    end
    local parts = prefix ~= "" and { prefix } or {}
    for i = 1, prefixLen do table.insert(parts, paths[1][i]) end
    table.insert(parts, leafName)
    return table.concat(parts, sep)
end

-- Returns true when two cels contain identical pixel content.
local function celsMatch(cel1, cel2)
    local i1, i2 = cel1.image, cel2.image
    if i1.width ~= i2.width or i1.height ~= i2.height then return false end
    for y = 0, i1.height - 1 do
        for x = 0, i1.width - 1 do
            if i1:getPixel(x, y) ~= i2:getPixel(x, y) then return false end
        end
    end
    return true
end

-- Returns an ordered array of frame numbers in [f1, f2] whose pixel content is
-- unique (i.e. not pixel-equal to any earlier frame already in the list).
local function getUniqueFrames(layer, f1, f2)
    local nums = {}
    local cels = {}
    for f = f1, f2 do
        local cel = layer:cel(f)
        if cel then
            local dup = false
            for _, prev in ipairs(cels) do
                if celsMatch(cel, prev) then dup = true; break end
            end
            if not dup then
                table.insert(nums, f)
                table.insert(cels, cel)
            end
        end
    end
    return nums
end

-- Exports a single layer over a frame range as a trimmed PNG.
-- The layer is temporarily renamed to a sentinel name so ExportSpriteSheet's
-- `layer` filter matches exactly one layer regardless of name collisions.
-- pcall ensures the original name and tag are always restored on failure.
-- Sprite:newTag uses 1-indexed frame numbers (Lua convention).
local function exportLayerPNG(layer, outputPath, fromFrame, toFrame, spr, padding)
    local origName = layer.name
    local sentinel = "__wb_export_target__"

    local uniqueNums = getUniqueFrames(layer, fromFrame, toFrame)
    if #uniqueNums == 0 then return false end

    layer.name = sentinel

    -- When some frames are linked, build a temp sprite containing only unique frames
    -- so the exported strip has no duplicate columns.
    local tmpSpr
    if #uniqueNums < toFrame - fromFrame + 1 then
        tmpSpr = Sprite(spr.width, spr.height, spr.colorMode)
        local tmpLayer = tmpSpr.layers[1]
        tmpLayer.name = sentinel
        while #tmpSpr.frames < #uniqueNums do tmpSpr:newFrame() end
        for i, f in ipairs(uniqueNums) do
            local cel = layer:cel(f)
            tmpSpr:newCel(tmpLayer, i, cel.image, cel.position)
        end
    end

    local target  = tmpSpr or spr
    local tagFrom = tmpSpr and 1             or fromFrame
    local tagTo   = tmpSpr and #uniqueNums   or toFrame
    local tag = target:newTag(tagFrom, tagTo)
    tag.name = "__wb_export__"
    pcall(function()
        app.command.ExportSpriteSheet{
            ui              = false,
            type            = SpriteSheetType.HORIZONTAL,
            textureFilename = outputPath,
            dataFilename    = "",
            layer           = sentinel,
            tag             = "__wb_export__",
            trim            = true,
            innerPadding    = padding or 0,
            ignoreEmpty     = false,
            splitLayers     = false,
            listLayers      = false,
            listTags        = false,
            listSlices      = false,
        }
    end)
    target:deleteTag(tag)
    if tmpSpr then pcall(function() tmpSpr:close() end) end
    layer.name = origName
    return app.fs.isFile(outputPath)
end


-- Serializes a hierarchy node to a JSON string with `indent` levels of indentation.
-- Group nodes carry { name, x, y, children }; image nodes carry { name, image, x, y, ... };
-- text nodes carry { name, x, y }. false entries in children are skipped (pending placeholders).
local function nodeToJson(node, indent)
    local pad      = string.rep("  ", indent)
    local outerPad = indent > 0 and string.rep("  ", indent - 1) or ""
    local parts    = {}
    table.insert(parts, string.format('"name": "%s"', node.name))
    if node.children then
        table.insert(parts, string.format('"x": %d', node.x))
        table.insert(parts, string.format('"y": %d', node.y))
        local childLines = {}
        for _, child in ipairs(node.children) do
            if child then
                table.insert(childLines, pad .. '  ' .. nodeToJson(child, indent + 2))
            end
        end
        if #childLines > 0 then
            table.insert(parts, '"children": [\n' ..
                table.concat(childLines, ',\n') .. '\n' .. pad .. ']')
        else
            table.insert(parts, '"children": []')
        end
    elseif node.image then
        table.insert(parts, string.format('"image": "%s"', node.image))
        table.insert(parts, string.format('"x": %d', node.x))
        table.insert(parts, string.format('"y": %d', node.y))
        if node.mask    then table.insert(parts, '"mask": true') end
        if node.scale   then table.insert(parts, string.format('"scale": [%d, %d]',
            node.scale[1], node.scale[2])) end
        if node.padding then table.insert(parts, string.format('"padding": %d',
            node.padding)) end
    else
        table.insert(parts, string.format('"x": %d', node.x))
        table.insert(parts, string.format('"y": %d', node.y))
    end
    return '{\n' .. pad .. table.concat(parts, ',\n' .. pad) .. '\n' .. outerPad .. '}'
end

-- Writes a hierarchical JSON layout manifest to manifestPath.
-- root is an ordered array of nodes (bottom-to-top).
local function writeHierarchicalManifest(root, manifestPath)
    local lines = {}
    for _, node in ipairs(root) do
        if node then
            table.insert(lines, '    ' .. nodeToJson(node, 3))
        end
    end
    local json = '{\n  "layers": [\n' .. table.concat(lines, ',\n') .. '\n  ]\n}\n'
    local f = io.open(manifestPath, "w")
    if not f then
        app.alert("Could not write manifest to:\n" .. manifestPath)
        return false
    end
    f:write(json)
    f:close()
    return manifestPath
end

-- ---------------------------------------------------------------------------
-- Main export routine
-- ---------------------------------------------------------------------------

local PREFS_VERSION <const> = 4

local function run(plugin)
    -- Clear stale preferences when the schema changes.
    if plugin.preferences.version ~= PREFS_VERSION then
        plugin.preferences = { version = PREFS_VERSION }
    end

    local spr = app.sprite
    if not spr then
        return app.alert("No active sprite.")
    end
    if spr.filename == "" then
        return app.alert("Save the sprite file first so the output path can be determined.")
    end

    local spriteDir = app.fs.filePath(spr.filename)
    local scene     = app.fs.fileTitle(spr.filename)
    local nFrames   = #spr.frames

    local dlg = Dialog("Export Layout")
    dlg:entry{
        id      = "jsonOutput",
        label   = "JSON Output:",
        text    = plugin.preferences.jsonOutput or "./{sprite}.json",
        tooltip = "Path for the JSON manifest, relative to the sprite file. Supports {sprite}.",
    }
    dlg:entry{
        id      = "outputPath",
        label   = "Image Output:",
        text    = plugin.preferences.outputPath or ".",
        tooltip = "Folder for exported images, relative to the sprite file. Supports {sprite}.",
    }
    dlg:entry{
        id      = "prefix",
        label   = "Image Prefix:",
        text    = plugin.preferences.prefix or "",
        tooltip = "Prepended to every exported image filename. Supports {sprite}.",
    }
    dlg:entry{
        id      = "separator",
        label   = "Separator:",
        text    = plugin.preferences.separator or "-",
        tooltip = "Character(s) used to join path components in image filenames.",
    }
    dlg:slider{
        id      = "padding",
        label   = "Padding:",
        min     = 0,
        max     = 16,
        value   = plugin.preferences.padding ~= nil and plugin.preferences.padding or 1,
        tooltip = "Transparent pixels added around each trimmed image.",
    }
    dlg:separator{}
    dlg:slider{
        id      = "fromFrame",
        label   = "From Frame:",
        min     = 1,
        max     = nFrames,
        value   = math.min(plugin.preferences.fromFrame or 1, nFrames),
        tooltip = "First frame to include in the export.",
    }
    dlg:slider{
        id      = "toFrame",
        label   = "To Frame:",
        min     = 1,
        max     = nFrames,
        value   = math.min(plugin.preferences.toFrame or nFrames, nFrames),
        tooltip = "Last frame to include in the export.",
    }
    dlg:separator{}
    dlg:check{
        id       = "groupTransform",
        text     = "Grouping Hierarchy",
        selected = plugin.preferences.groupTransform ~= false,
        tooltip  = "Export a hierarchy where layer groups act as parent transforms. "
                .. "Each group's position is the center of its bounding box; "
                .. "children express their position relative to that center.",
    }
    dlg:check{
        id       = "deleteExisting",
        text     = "Delete Existing Images in Folder",
        selected = plugin.preferences.deleteExisting ~= false,
        tooltip  = "Remove all PNG files in the output folder before exporting.",
    }
    dlg:separator{}
    dlg:button{
        text    = "Restore Defaults",
        onclick = function()
            dlg:modify{ id = "jsonOutput",      text     = "./{sprite}.json" }
            dlg:modify{ id = "outputPath",      text     = "."               }
            dlg:modify{ id = "prefix",          text     = ""                }
            dlg:modify{ id = "separator",       text     = "-"               }
            dlg:modify{ id = "padding",         value    = 1                 }
            dlg:modify{ id = "fromFrame",       value    = 1                 }
            dlg:modify{ id = "toFrame",         value    = nFrames           }
            dlg:modify{ id = "groupTransform",  selected = false             }
            dlg:modify{ id = "deleteExisting",  selected = true              }
        end,
    }
    dlg:button{ id = "ok", text = "Export", focus = true }
    dlg:button{ id = "cancel", text = "Cancel" }
    dlg:show()

    if not dlg.data.ok then return end

    local jsonRel  = dlg.data.jsonOutput:gsub("{sprite}", scene)
    local jsonPath  -- full path to the manifest file
    if jsonRel == "" or jsonRel == "." then
        jsonPath = app.fs.joinPath(spriteDir, scene .. ".json")
    elseif jsonRel:sub(-5) == ".json" then
        jsonPath = app.fs.joinPath(spriteDir, jsonRel)
    else
        jsonPath = app.fs.joinPath(spriteDir, jsonRel, scene .. ".json")
    end
    local jsonDir = app.fs.filePath(jsonPath)

    local relPath   = dlg.data.outputPath:gsub("{sprite}", scene)
    local outputDir = (relPath == "" or relPath == ".")
        and spriteDir
        or  app.fs.joinPath(spriteDir, relPath)

    plugin.preferences.version        = PREFS_VERSION
    plugin.preferences.groupTransform = dlg.data.groupTransform
    plugin.preferences.deleteExisting = dlg.data.deleteExisting
    plugin.preferences.jsonOutput     = dlg.data.jsonOutput
    plugin.preferences.outputPath     = dlg.data.outputPath
    plugin.preferences.prefix         = dlg.data.prefix
    plugin.preferences.separator      = dlg.data.separator
    plugin.preferences.padding        = dlg.data.padding
    plugin.preferences.fromFrame      = dlg.data.fromFrame
    plugin.preferences.toFrame        = dlg.data.toFrame

    local prefix  = dlg.data.prefix:gsub("{sprite}", scene)
    local sep     = dlg.data.separator ~= "" and dlg.data.separator or "-"
    local padding = dlg.data.padding

    -- Returns the path to an image relative to the JSON file location.
    local function makeImagePath(filename)
        local function split(s)
            local t = {}
            for p in s:gsub("\\", "/"):gmatch("[^/]+") do
                if p ~= "." then table.insert(t, p) end
            end
            return t
        end
        local fp, tp = split(jsonDir), split(outputDir)
        local i = 1
        while i <= #fp and i <= #tp and fp[i] == tp[i] do i = i + 1 end
        local parts = {}
        for _ = i, #fp do table.insert(parts, "..") end
        for j = i, #tp do table.insert(parts, tp[j]) end
        local dir = #parts > 0 and table.concat(parts, "/") or "."
        if dir == "." then return filename .. ".png" end
        return dir .. "/" .. filename .. ".png"
    end
    local fromFrame = math.min(dlg.data.fromFrame, dlg.data.toFrame)
    local toFrame   = math.max(dlg.data.fromFrame, dlg.data.toFrame)
    local frame     = fromFrame

    -- Collect valid leaf layers (topmost first → highest z)
    local leaves = collectLeaves(spr)
    local total  = #leaves

    if total == 0 then
        return app.alert("No exportable layers found.")
    end

    if dlg.data.deleteExisting then
        local files = app.fs.listFiles(outputDir)
        for _, name in ipairs(files) do
            if name:sub(-4) == ".png" then
                os.remove(app.fs.joinPath(outputDir, name))
            end
        end
    end

    -- Pre-pass: classify instance layers and compute shared filenames.
    --
    -- "instance" suffix → reusable symbol; all occurrences share one PNG named by
    --   scene + common-prefix-of-all-paths + leaf-name.
    --
    -- "left-instance" / "right-instance" suffix → mirrored pair; only the right
    --   image is exported (using the base name, both suffixes stripped). The left
    --   entry references the same file with scale [-1, 1] applied.
    local sharedFilenames = {}  -- pathKey → filename stem (no extension)
    local leftInstanceKeys = {} -- pathKey → true  (these entries get scale [-1, 1])

    local regularGroups     = {}  -- leafName → { path, ... }
    local directionalGroups = {}  -- baseName → { rights={path,...}, lefts={path,...} }

    for _, layer in ipairs(leaves) do
        local path = getPath(layer)
        if not shouldSkip(path) then
            local name  = path[#path]
            local lname = name:lower()
            if lname:sub(-#"left-instance") == "left-instance" then
                local base = name:sub(1, #name - #"-left-instance")
                if not directionalGroups[base] then
                    directionalGroups[base] = { rights = {}, lefts = {} }
                end
                table.insert(directionalGroups[base].lefts, path)
            elseif lname:sub(-#"right-instance") == "right-instance" then
                local base = name:sub(1, #name - #"-right-instance")
                if not directionalGroups[base] then
                    directionalGroups[base] = { rights = {}, lefts = {} }
                end
                table.insert(directionalGroups[base].rights, path)
            elseif lname:sub(-#"instance") == "instance" then
                if not regularGroups[name] then regularGroups[name] = {} end
                table.insert(regularGroups[name], path)
            end
        end
    end

    -- Regular instances: deduplicate only when the same leaf name appears more than once.
    for leafName, paths in pairs(regularGroups) do
        if #paths > 1 then
            local baseLeafName = cleanName(leafName)
            local fname = commonPrefixFilename(paths, baseLeafName, prefix, sep)
            for _, p in ipairs(paths) do
                sharedFilenames[table.concat(p, "-")] = fname
            end
        end
    end

    -- Directional instances: always deduplicate (left + right share one file).
    -- The exported filename uses the base name (both directional and instance suffixes dropped).
    for baseName, group in pairs(directionalGroups) do
        local allPaths = {}
        for _, p in ipairs(group.rights) do table.insert(allPaths, p) end
        for _, p in ipairs(group.lefts)  do table.insert(allPaths, p) end
        local fname = commonPrefixFilename(allPaths, baseName, prefix, sep)
        for _, p in ipairs(allPaths) do
            sharedFilenames[table.concat(p, "-")] = fname
        end
        for _, p in ipairs(group.lefts) do
            leftInstanceKeys[table.concat(p, "-")] = true
        end
    end

    local groupTransform = dlg.data.groupTransform

    local exported      = 0
    local warnings      = {}
    local exportedFiles = {}   -- filename → true/false
    local pendingLeft   = {}   -- left-instance entries deferred until after right exports

    -- Returns the Playdate image-table suffix ("-table-W-H") when a layer has more
    -- than one unique frame in the export range, otherwise returns "".
    -- W and H are the dimensions of a single frame (trimmed content + padding on each side).
    local function tableSuffix(layer)
        local unique = getUniqueFrames(layer, fromFrame, toFrame)
        if #unique <= 1 then return "" end
        local cel = layer:cel(unique[1])
        if not cel then return "" end
        local tr = cel.image:shrinkBounds()
        if tr.width == 0 or tr.height == 0 then return "" end
        return string.format("-table-%d-%d", tr.width + 2 * padding, tr.height + 2 * padding)
    end

    -- Returns the filename stem for a leaf layer, honouring shared-instance overrides.
    local function makeFilename(path, baseKey)
        if sharedFilenames[baseKey] then return sharedFilenames[baseKey] end
        local nameParts = prefix ~= "" and { prefix } or {}
        for _, p in ipairs(path) do
            local part = cleanName(p)
            if part ~= "" then table.insert(nameParts, part) end
        end
        return table.concat(nameParts, sep)
    end

    -- Exports a leaf PNG once per unique filename (deduped via exportedFiles).
    local function exportLeaf(layer, filename)
        if exportedFiles[filename] ~= nil then return exportedFiles[filename] end
        local outputPath = app.fs.joinPath(outputDir, filename .. ".png")
        local ok = exportLayerPNG(layer, outputPath, fromFrame, toFrame, spr, padding)
        exportedFiles[filename] = ok
        if ok then
            exported = exported + 1
        else
            table.insert(warnings, "Export failed: " .. layer.name)
        end
        return ok
    end

    -- Wrap all layer renames in a single transaction so one Undo call below can
    -- revert them all, restoring the document to its pre-export state (no dirty flag).
    local manifestPath
    if groupTransform then
        -- -----------------------------------------------------------------------
        -- Hierarchical mode: groups become parent transform nodes.
        -- Positions of children are relative to their parent's center.
        -- Output is ordered arrays (bottom-to-top); draw order is implicit.
        -- -----------------------------------------------------------------------

        -- Recursively builds an ordered array of nodes for a container's children.
        -- parentCX/parentCY: canvas-space center of the parent (0,0 at root).
        local function buildHierarchyNode(container, parentCX, parentCY)
            local result = {}
            -- Iterate bottom-to-top (index 1 = bottommost in Aseprite).
            for i = 1, #container.layers do
                local layer = container.layers[i]
                if isEffectivelyVisible(layer) then
                    local path = getPath(layer)
                    if not shouldSkip(path) then
                        if layer.isGroup then
                            local bx1, by1, bx2, by2 = getGroupBounds(layer, frame)
                            if bx1 then
                                local cx = math.floor((bx1 + bx2) / 2 + 0.5)
                                local cy = math.floor((by1 + by2) / 2 + 0.5)
                                table.insert(result, {
                                    name     = cleanDisplayName(layer.name),
                                    x        = cx - parentCX,
                                    y        = cy - parentCY,
                                    children = buildHierarchyNode(layer, cx, cy),
                                })
                            end
                        elseif layer.isImage then
                            local cx, cy = getCenter(layer, frame)
                            if cx then
                                local lname  = layer.name:lower()
                                local isText = lname:sub(-#"text") == "text"
                                if isText then
                                    table.insert(result, {
                                        name = cleanDisplayName(layer.name),
                                        x = cx - parentCX, y = cy - parentCY,
                                    })
                                else
                                    local baseKey  = table.concat(path, "-")
                                    local filename = makeFilename(path, baseKey) .. tableSuffix(layer)
                                    local isMask   = lname:sub(-#"mask") == "mask"
                                    if leftInstanceKeys[baseKey] then
                                        -- Reserve a slot; fill after the right-instance is exported.
                                        local pos = #result + 1
                                        result[pos] = false
                                        table.insert(pendingLeft, {
                                            arr      = result,
                                            pos      = pos,
                                            name     = cleanDisplayName(layer.name),
                                            filename = filename,
                                            imgPath  = makeImagePath(filename),
                                            x = cx - parentCX, y = cy - parentCY,
                                            mask    = isMask or nil,
                                            padding = padding > 0 and padding or nil,
                                        })
                                    else
                                        if exportLeaf(layer, filename) then
                                            table.insert(result, {
                                                name    = cleanDisplayName(layer.name),
                                                image   = makeImagePath(filename),
                                                x = cx - parentCX, y = cy - parentCY,
                                                mask    = isMask or nil,
                                                padding = padding > 0 and padding or nil,
                                            })
                                        end
                                    end
                                end
                            else
                                table.insert(warnings, "Empty layer skipped: " .. layer.name)
                            end
                        end
                    end
                end
            end
            return result
        end

        local hierarchicalManifest
        app.transaction("White Block Export", function()
            hierarchicalManifest = buildHierarchyNode(spr, 0, 0)
            for _, e in ipairs(pendingLeft) do
                if exportedFiles[e.filename] then
                    e.arr[e.pos] = {
                        name    = e.name,
                        image   = e.imgPath,
                        x = e.x, y = e.y,
                        mask    = e.mask,
                        scale   = { -1, 1 },
                        padding = e.padding,
                    }
                end
            end
        end)
        app.command.Undo()
        manifestPath = writeHierarchicalManifest(hierarchicalManifest, jsonPath)
    else
        -- -----------------------------------------------------------------------
        -- Flat mode: one entry per leaf, ordered bottom-to-top.
        -- -----------------------------------------------------------------------
        local manifest  = {}
        local pathIndex = {}   -- baseKey → occurrence count (handles path collisions)
        app.transaction("White Block Export", function()
            -- leaves[1] is topmost; iterate in reverse for bottom-to-top array order.
            for i = total, 1, -1 do
                local layer = leaves[i]
                local path = getPath(layer)
                if not shouldSkip(path) then
                    local lname  = layer.name:lower()
                    local isText = lname:sub(-#"text") == "text"
                    local asMask = lname:sub(-#"mask") == "mask"
                    local baseKey = table.concat(path, "-")
                    pathIndex[baseKey] = (pathIndex[baseKey] or 0) + 1
                    local idx = pathIndex[baseKey]
                    local cleanKey = table.concat((function()
                        local parts = {}
                        for _, p in ipairs(path) do
                            local c = cleanDisplayName(p)
                            if c ~= "" then table.insert(parts, c) end
                        end
                        return parts
                    end)(), "-")
                    local name = idx == 1 and cleanKey or (cleanKey .. "-" .. idx)
                    local cx, cy = getCenter(layer, frame)
                    if cx == nil then
                        table.insert(warnings, "Empty layer skipped: " .. layer.name)
                    elseif isText then
                        table.insert(manifest, {
                            name = name,
                            x = cx, y = cy,
                        })
                    else
                        local filename = makeFilename(path, baseKey) .. tableSuffix(layer)
                        if not sharedFilenames[baseKey] and idx > 1 then
                            filename = filename .. sep .. idx
                        end
                        if leftInstanceKeys[baseKey] then
                            -- Reserve a slot; fill after the right-instance is exported.
                            local pos = #manifest + 1
                            manifest[pos] = false
                            table.insert(pendingLeft, {
                                arr      = manifest,
                                pos      = pos,
                                name     = name,
                                filename = filename,
                                imgPath  = makeImagePath(filename),
                                x = cx, y = cy,
                                mask    = asMask or nil,
                                padding = padding > 0 and padding or nil,
                            })
                        else
                            if exportLeaf(layer, filename) then
                                table.insert(manifest, {
                                    name    = name,
                                    image   = makeImagePath(filename),
                                    x = cx, y = cy,
                                    mask    = asMask or nil,
                                    padding = padding > 0 and padding or nil,
                                })
                            end
                        end
                    end
                end
            end
            -- Fill in deferred left-instance slots.
            for _, e in ipairs(pendingLeft) do
                if exportedFiles[e.filename] then
                    e.arr[e.pos] = {
                        name    = e.name,
                        image   = e.imgPath,
                        x = e.x, y = e.y,
                        mask    = e.mask,
                        scale   = { -1, 1 },
                        padding = e.padding,
                    }
                end
            end
        end)
        -- Undo the transaction to restore the document to its pre-export state,
        -- clearing the dirty flag so the user is not prompted to save.
        app.command.Undo()
        manifestPath = writeHierarchicalManifest(manifest, jsonPath)
    end

    if not manifestPath then
        app.alert("Failed to write manifest.")
    elseif #warnings > 0 then
        app.alert("Warnings:\n• " .. table.concat(warnings, "\n• "))
    end
end

-- ---------------------------------------------------------------------------
-- Extension lifecycle
-- ---------------------------------------------------------------------------

function init(plugin)
    plugin:newMenuGroup{
        id    = "white_block",
        title = "White Block",
        group = "file_scripts",
    }
    plugin:newCommand{
        id        = "ExportSpriteLayers",
        title     = "Export Layout...",
        group     = "white_block",
        onclick   = function() run(plugin) end,
        onenabled = function() return app.sprite ~= nil end,
    }
end

function exit(plugin)
end
