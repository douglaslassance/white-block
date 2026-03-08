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

-- Exports a single layer over a frame range as a trimmed PNG.
-- The layer is temporarily renamed to a sentinel name so ExportSpriteSheet's
-- `layer` filter matches exactly one layer regardless of name collisions.
-- pcall ensures the original name and tag are always restored on failure.
-- Sprite:newTag uses 1-indexed frame numbers (Lua convention).
local function exportLayerPNG(layer, outputPath, fromFrame, toFrame, spr, padding)
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
            borderPadding   = padding or 0,
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

-- Writes the JSON layout manifest to manifestPath.
-- Each entry's path is already the correct relative path from the JSON to the image.
local function writeManifest(entries, manifestPath)
    -- Sort keys for stable, diffable output
    local keys = {}
    for k in pairs(entries) do table.insert(keys, k) end
    table.sort(keys)

    local layerLines = {}
    for _, key in ipairs(keys) do
        local e = entries[key]
        local mask    = e.mask    and ',\n      "mask": true' or ""
        local scale   = e.scale   and string.format(',\n      "scale": [%d, %d]', e.scale[1], e.scale[2]) or ""
        local padding = e.padding and string.format(',\n      "padding": %d', e.padding) or ""
        table.insert(layerLines, string.format(
            '    "%s": {\n      "path": "%s",\n      "x": %d,\n      "y": %d,\n      "z": %d%s%s%s\n    }',
            key, e.path, e.x, e.y, e.z, mask, scale, padding
        ))
    end

    local json = '{\n  "layers": {\n' .. table.concat(layerLines, ',\n') .. '\n  }\n}\n'

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

local PREFS_VERSION <const> = 3

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
        id       = "deleteExisting",
        text     = "Delete Existing Images in Folder",
        selected = plugin.preferences.deleteExisting ~= false,
        tooltip  = "Remove all PNG files in the output folder before exporting.",
    }
    dlg:separator{}
    dlg:button{
        text    = "Restore Defaults",
        onclick = function()
            dlg:modify{ id = "jsonOutput",  text = "./{sprite}.json" }
            dlg:modify{ id = "outputPath",  text = "."               }
            dlg:modify{ id = "prefix",         text     = ""             }
            dlg:modify{ id = "separator",      text     = "-"            }
            dlg:modify{ id = "padding",        value    = 1              }
            dlg:modify{ id = "fromFrame",      value    = 1              }
            dlg:modify{ id = "toFrame",        value    = nFrames        }
            dlg:modify{ id = "deleteExisting", selected = true           }
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
        local f = filename .. ".png"
        if outputDir == jsonDir then return f end
        local jd = jsonDir:gsub("\\", "/")
        local od = outputDir:gsub("\\", "/")
        if od:sub(1, #jd + 1) == jd .. "/" then
            return od:sub(#jd + 2) .. "/" .. f
        end
        return od .. "/" .. f  -- absolute fallback for unrelated trees
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
            local fname = commonPrefixFilename(paths, leafName, prefix, sep)
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
                    local nameParts = prefix ~= "" and { prefix } or {}
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
                        key = key, filename = filename, path = makeImagePath(filename),
                        x = cx, y = cy, z = total - i + 1, mask = asMask,
                        padding = padding > 0 and padding or nil,
                    })
                else
                    -- Export the PNG only once per unique filename.
                    if exportedFiles[filename] == nil then
                        local ok = exportLayerPNG(layer, outputPath, fromFrame, toFrame, spr, padding)
                        exportedFiles[filename] = ok
                        if ok then
                            exported = exported + 1
                        else
                            table.insert(warnings, "Export failed: " .. layer.name)
                        end
                    end
                    if exportedFiles[filename] then
                        manifest[key] = {
                            path    = makeImagePath(filename),
                            x = cx, y = cy,
                            z = total - i + 1,
                            mask    = asMask,
                            padding = padding > 0 and padding or nil,
                        }
                    end
                end
            end
        end

        -- Add deferred left-instance entries now that their right counterparts are exported.
        for _, e in ipairs(pendingLeft) do
            if exportedFiles[e.filename] then
                manifest[e.key] = {
                    path    = e.path,
                    x = e.x, y = e.y, z = e.z,
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

    local manifestPath = writeManifest(manifest, jsonPath)

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
