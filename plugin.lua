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

-- Given a set of full layer paths and a target leaf name, returns the deduplicated
-- filename stem: scene + longest-common-prefix-of-all-paths + leafName.
local function commonPrefixFilename(paths, leafName, scene, sep)
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
    local parts = { scene }
    for i = 1, prefixLen do table.insert(parts, paths[1][i]) end
    table.insert(parts, leafName)
    return table.concat(parts, sep)
end

-- Exports a single layer over a frame range as a trimmed PNG.
-- The layer is temporarily renamed to a sentinel name so ExportSpriteSheet's
-- `layer` filter matches exactly one layer regardless of name collisions.
-- pcall ensures the original name and tag are always restored on failure.
-- Sprite:newTag uses 1-indexed frame numbers (Lua convention).
local function exportLayerPNG(layer, outputPath, fromFrame, toFrame, spr)
    local origName = layer.name
    local sentinel = "__wb_export_target__"
    layer.name = sentinel
    local tag = spr:newTag(fromFrame, toFrame)
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
            ignoreEmpty     = false,
            splitLayers     = false,
            listLayers      = false,
            listTags        = false,
            listSlices      = false,
        }
    end)
    spr:deleteTag(tag)
    layer.name = origName
    return app.fs.isFile(outputPath)
end

-- Writes the JSON layout manifest file.
-- Image paths in the JSON are filenames only (no directory, no extension).
-- Layout.lua resolves them relative to the JSON's own location at runtime.
local function writeManifest(scene, entries, outputDir)
    -- Sort keys for stable, diffable output
    local keys = {}
    for k in pairs(entries) do table.insert(keys, k) end
    table.sort(keys)

    local layerLines = {}
    for _, key in ipairs(keys) do
        local e = entries[key]
        local mask  = e.mask  and ',\n      "mask": true' or ""
        local scale = e.scale and string.format(',\n      "scale": [%d, %d]', e.scale[1], e.scale[2]) or ""
        table.insert(layerLines, string.format(
            '    "%s": {\n      "path": "%s",\n      "x": %d,\n      "y": %d,\n      "z": %d%s%s\n    }',
            key, e.filename, e.x, e.y, e.z, mask, scale
        ))
    end

    local json = '{\n  "layers": {\n' .. table.concat(layerLines, ',\n') .. '\n  }\n}\n'

    local manifestPath = app.fs.joinPath(outputDir, scene .. ".json")
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

local function run(plugin)
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
        id    = "outputPath",
        label = "Output:",
        text  = plugin.preferences.outputPath or ".",
    }
    dlg:entry{
        id    = "separator",
        label = "Separator:",
        text  = plugin.preferences.separator or "-",
    }
    dlg:separator{}
    dlg:slider{
        id    = "fromFrame",
        label = "From frame:",
        min   = 1,
        max   = nFrames,
        value = math.min(plugin.preferences.fromFrame or 1, nFrames),
    }
    dlg:slider{
        id    = "toFrame",
        label = "To frame:",
        min   = 1,
        max   = nFrames,
        value = math.min(plugin.preferences.toFrame or nFrames, nFrames),
    }
    dlg:separator{}
    dlg:check{
        id       = "deleteExisting",
        text     = "Delete existing images in folder",
        selected = plugin.preferences.deleteExisting ~= false,
    }
    dlg:separator{}
    dlg:button{ id = "ok", text = "Export", focus = true }
    dlg:button{ id = "cancel", text = "Cancel" }
    dlg:show()

    if not dlg.data.ok then return end

    plugin.preferences.deleteExisting = dlg.data.deleteExisting
    plugin.preferences.outputPath     = dlg.data.outputPath
    plugin.preferences.separator      = dlg.data.separator
    plugin.preferences.fromFrame      = dlg.data.fromFrame
    plugin.preferences.toFrame        = dlg.data.toFrame

    local relPath   = dlg.data.outputPath
    local outputDir = (relPath == "" or relPath == ".")
        and spriteDir
        or  app.fs.joinPath(spriteDir, relPath)

    local sep       = dlg.data.separator ~= "" and dlg.data.separator or "-"
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
            local fname = commonPrefixFilename(paths, leafName, scene, sep)
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
        local fname = commonPrefixFilename(allPaths, baseName, scene, sep)
        for _, p in ipairs(allPaths) do
            sharedFilenames[table.concat(p, "-")] = fname
        end
        for _, p in ipairs(group.lefts) do
            leftInstanceKeys[table.concat(p, "-")] = true
        end
    end

    local exported      = 0
    local warnings      = {}
    local manifest      = {}
    local pathIndex     = {}   -- baseKey → occurrence count (handles true path collisions)
    local exportedFiles = {}   -- filename → true/false
    local pendingLeft   = {}   -- left-instance entries deferred until after right exports

    -- Wrap all layer renames in a single transaction so one Undo call below can
    -- revert them all, restoring the document to its pre-export state (no dirty flag).
    app.transaction("White Block Export", function()
        for i, layer in ipairs(leaves) do
            local path = getPath(layer)

            if not shouldSkip(path) then
                local asMask  = layer.name:lower():sub(-#"mask") == "mask"
                local baseKey = table.concat(path, "-")
                pathIndex[baseKey] = (pathIndex[baseKey] or 0) + 1
                local idx = pathIndex[baseKey]
                local key = idx == 1 and baseKey or (baseKey .. "-" .. idx)

                local filename
                if sharedFilenames[baseKey] then
                    filename = sharedFilenames[baseKey]
                else
                    local nameParts = { scene }
                    for _, p in ipairs(path) do table.insert(nameParts, p) end
                    filename = table.concat(nameParts, sep)
                    if idx > 1 then filename = filename .. sep .. idx end
                end
                local outputPath = app.fs.joinPath(outputDir, filename .. ".png")

                local cx, cy = getCenter(layer, frame)
                if cx == nil then
                    table.insert(warnings, "Empty layer skipped: " .. layer.name)
                elseif leftInstanceKeys[baseKey] then
                    -- Defer: capture position now, add manifest entry after right is exported.
                    table.insert(pendingLeft, {
                        key = key, filename = filename,
                        x = cx, y = cy, z = total - i + 1, mask = asMask,
                    })
                else
                    -- Export the PNG only once per unique filename.
                    if exportedFiles[filename] == nil then
                        local ok = exportLayerPNG(layer, outputPath, fromFrame, toFrame, spr)
                        exportedFiles[filename] = ok
                        if ok then
                            exported = exported + 1
                        else
                            table.insert(warnings, "Export failed: " .. layer.name)
                        end
                    end
                    if exportedFiles[filename] then
                        manifest[key] = {
                            filename = filename,
                            x = cx, y = cy,
                            z = total - i + 1,
                            mask = asMask,
                        }
                    end
                end
            end
        end

        -- Add deferred left-instance entries now that their right counterparts are exported.
        for _, e in ipairs(pendingLeft) do
            if exportedFiles[e.filename] then
                manifest[e.key] = {
                    filename = e.filename,
                    x = e.x, y = e.y, z = e.z,
                    mask  = e.mask,
                    scale = { -1, 1 },
                }
            end
        end
    end)

    -- Undo the transaction to restore the document to its pre-export state,
    -- clearing the dirty flag so the user is not prompted to save.
    app.command.Undo()

    local manifestPath = writeManifest(scene, manifest, outputDir)

    local summary = string.format("Exported %d layers.\nManifest: %s",
        exported, manifestPath and app.fs.fileName(manifestPath) or "FAILED")
    if #warnings > 0 then
        summary = summary .. "\n\nWarnings:\n• " .. table.concat(warnings, "\n• ")
    end
    app.alert(summary)
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
