-- Copyright (C) 2026 Deepak Srivastav
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Audiobookshelf integration.
--
-- MVP scope:
--   * Stream Media tile
--   * API-key configuration
--   * library/item browsing
--   * multi-file audiobook downloads into the Audiobooks player library
--   * local-copy deletion without deleting the ABS item
--   * download-only management; playback and progress sync are handled elsewhere
--
-- Downloads use one ABS audio-file endpoint per file. The download URL uses
-- ABS's legacy ?token= media compatibility accepted by many installations;
-- deployments that disable it need an authenticated native download helper.

plugin.define({
    id = "community.audiobookshelf",
    name = "Audiobookshelf",
    version = "0.1.0",
    api_min = 16,
})

local SD_ROOT = plugin.sd_root()
-- The Audiobooks player scans this root. Keep ABS downloads in its
-- Author/Title or Author/Series/Title layout so they appear automatically.
local DOWNLOAD_ROOT = SD_ROOT .. "/Audiobooks"
local STATE_KEY = "audiobookshelf.state"
local URL_KEY = "audiobookshelf.url"
local TOKEN_KEY = "audiobookshelf.api_key"
local USERNAME_KEY = "audiobookshelf.username"
local PASSWORD_KEY = "audiobookshelf.password"
local JSON_LIMIT = 524288
local PAGE_SIZE = 50
local ICON_SOURCE = SD_ROOT .. "/.plugin-assets/Audiobookshelf/audiobookshelf.png"
local ICON_SOURCE_SELECTED = SD_ROOT .. "/.plugin-assets/Audiobookshelf/audiobookshelf_s.png"
local ICON_PATH = "stream_media/audiobookshelf_row.png"
local ICON_PATH_SELECTED = "stream_media/audiobookshelf_row_s.png"
local HAS_DOWNLOAD_PROGRESS = plugin.has_capability("network.http.download_progress")
local active_download = nil
local show_downloaded

local function toast(message)
    plugin.show_toast(tostring(message or "Audiobookshelf request failed"))
end

-- The plugin API does not expose Wi-Fi state directly. Match Discover's
-- behavior by turning the HTTP connection failures that normally mean Wi-Fi
-- is disabled or unavailable into an actionable toast.
-- This error classification and message are adapted from
-- Discover plugin: https://github.com/Starnished66/compas-plugins/blob/main/plugins/Discover/Discover.lua
local CONNECTION_ERRORS = {
    dns = true,
    dns_failure = true,
    resolve_failed = true,
    connect_failed = true,
    connect_timeout = true,
    timeout = true,
}

local function friendly_request_error(err)
    local error_code = tostring(err or ""):lower()
    if CONNECTION_ERRORS[error_code] then
        return "No internet connection -- check Wi-Fi and try again"
    end
    return tostring(err or "Audiobookshelf request failed")
end

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function stored(key, fallback)
    local value = plugin.storage.get(key)
    return value == nil and fallback or value
end

local function url_encode(value)
    return (tostring(value or ""):gsub("([^%w%._%-])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function base_url()
    return trim(stored(URL_KEY, "")):gsub("/+$", "")
end

local function api_url(path)
    return base_url() .. "/api" .. path
end

local function api_headers()
    local token = plugin.secrets.get(TOKEN_KEY)
    local headers = { ["Accept"] = "application/json" }
    if token and token ~= "" then
        headers.Authorization = "Bearer " .. token
    end
    return headers
end

local function decode(body)
    if not body or body == "" then return nil end
    local value = plugin.json_decode(body, { max_input_bytes = JSON_LIMIT })
    return type(value) == "table" and value or nil
end

local function request(method, path, body, callback)
    -- GET calls may omit the request body and pass the callback as argument 3.
    if callback == nil and type(body) == "function" then
        callback, body = body, nil
    end
    if type(callback) ~= "function" then
        toast("Audiobookshelf request callback is missing")
        return
    end
    if base_url() == "" then
        callback(nil, "Configure the Audiobookshelf URL first")
        return
    end
    local options = {
        url = api_url(path),
        method = method or "GET",
        headers = api_headers(),
        verify_tls = true,
        connect_timeout_ms = 10000,
        read_timeout_ms = 20000,
        total_timeout_ms = 60000,
        max_response_bytes = JSON_LIMIT,
    }
    if body then
        options.body = plugin.json_encode(body)
        options.content_type = "application/json"
    end
    local handle = plugin.http_request(options, function(status, response, err)
        if err then callback(nil, friendly_request_error(err)); return end
        if status < 200 or status >= 300 then
            callback(nil, "Audiobookshelf HTTP " .. tostring(status))
            return
        end
        local value = decode(response)
        if not value and response ~= "" then
            callback(nil, "Audiobookshelf returned invalid JSON")
            return
        end
        callback(value or {}, nil)
    end)
    if not handle then callback(nil, friendly_request_error("Could not start Audiobookshelf request")) end
end

local function load_json(key, fallback)
    local value = decode(stored(key, ""))
    return value or fallback
end

local function save_json(key, value)
    return plugin.storage.set(key, plugin.json_encode(value))
end

local function state()
    return load_json(STATE_KEY, { items = {}, libraries = {} })
end

local function item_state(id)
    local s = state()
    s.items[id] = s.items[id] or {}
    return s, s.items[id]
end

local function safe_name(value)
    value = trim(value):gsub("[/%c\\:*?<>|]", "_"):gsub("%s+", " ")
    if value == "" then value = "book" end
    return value:sub(1, 120)
end

local function display_name(value, max_bytes)
    value = tostring(value or "")
    if #value <= max_bytes then return value end
    local shortened = value:sub(1, max_bytes - 3)
    -- Avoid leaving a partial UTF-8 continuation sequence before the dots.
    while #shortened > 0 do
        local byte = shortened:byte(#shortened)
        if not byte or byte < 128 or byte > 191 then break end
        shortened = shortened:sub(1, -2)
    end
    return shortened .. "..."
end

-- Audiobooks recognizes series books as Author/Series/Title. ABS normally
-- returns `media.metadata.series` as an array of { name, sequence } objects,
-- but older/server-specific responses may expose seriesName or a string, so
-- accept those shapes without changing the normal Author/Title layout.
local function series_name(item)
    local metadata = item and item.media and item.media.metadata or {}
    local series = metadata.series
    if type(series) == "table" then
        local first = series[1]
        if type(first) == "table" then return trim(first.name or first.seriesName or "") end
        if type(first) == "string" then return trim(first) end
    elseif type(series) == "string" then
        return trim(series)
    end
    return trim(metadata.seriesName or item.seriesName or "")
end

local function mkdir(path)
    return plugin.mkdir(path) or plugin.list_dir(path) ~= nil
end

local function is_local(id)
    local _, item = item_state(id)
    return item.downloaded == true and type(item.files) == "table" and #item.files > 0
end

local function refresh_item(id, callback)
    request("GET", "/items/" .. url_encode(id) .. "?expanded=1", function(item, err)
        if item and item.id then
            local s, local_item = item_state(id)
            local_item.title = item.media and item.media.metadata and item.media.metadata.title or item.title or id
            local_item.remote = item
            save_json(STATE_KEY, s)
        end
        callback(item, err)
    end)
end

local function delete_item(id, replace_handle)
    local s, item = item_state(id)
    local files = item.files or {}
    if #files == 0 then
        toast("Book is not downloaded")
        show_downloaded(replace_handle)
        return
    end
    local present = {}
    for _, file in ipairs(files) do
        local parent, basename = (file.path or ""):match("^(.*)/([^/]+)$")
        if parent and basename then
            for _, entry in ipairs(plugin.list_dir(parent) or {}) do
                if type(entry) == "table" and entry.name == basename then present[file] = true; break end
            end
        end
    end
    local book_dir = item.dir
    if not book_dir or book_dir == "" then
        local path = item.path or (files[1] and files[1].path)
        book_dir = path and path:match("^(.*)/[^/]+$") or nil
    end
    local function remove_empty_book_dir()
        if book_dir and book_dir:sub(1, #SD_ROOT + 1) == SD_ROOT .. "/"
            and book_dir ~= DOWNLOAD_ROOT then
            os.remove(book_dir) -- Succeeds only when the book folder is empty.
        end
    end
    local any_audio_found = false
    for _, file in ipairs(files) do
        if present[file] then any_audio_found = true; break end
    end
    if not any_audio_found then
        -- A leftover book folder or cover image is not a local audiobook.
        -- Clear the stale record when none of its recorded audio files exist.
        if item.cover and item.cover ~= "" then os.remove(item.cover) end
        remove_empty_book_dir()
        item.files, item.path, item.downloaded, item.cover = {}, "", false, nil
        save_json(STATE_KEY, s)
        toast("Missing audio files entry cleared")
        show_downloaded(replace_handle)
        return
    end
    local failed = false
    for _, file in ipairs(files) do
        if present[file] and file.path and file.path ~= "" and not os.remove(file.path) then failed = true end
    end
    if item.cover and item.cover ~= "" then os.remove(item.cover) end
    remove_empty_book_dir()
    item.files, item.path, item.downloaded = {}, "", false
    item.cover = nil
    save_json(STATE_KEY, s)
    toast(failed and "Local entry cleared; some files remain" or "Local copy deleted")
    show_downloaded(replace_handle)
end

local function update_download_progress(active)
    if not plugin.has_capability("ui.progress") then return false end
    local file = active.files[active.index]
    local audio_count = #active.files
    local total_count = audio_count + 1 -- include the cover-art transfer
    local completed = active.index - 1
    local current_fraction = 0
    local message = "Preparing download"
    if active.cover_downloading then
        completed = audio_count
        message = "File " .. tostring(total_count) .. " of " .. tostring(total_count) .. ": cover art"
    elseif file then
        message = "File " .. tostring(active.index) .. " of " .. tostring(total_count) .. ": "
            .. display_name(file.name, 48)
    end
    if active.download_handle and HAS_DOWNLOAD_PROGRESS then
        local snapshot = plugin.get_download_progress(active.download_handle)
        if snapshot and snapshot.total and snapshot.total > 0 then
            current_fraction = math.max(0, math.min(1, snapshot.downloaded / snapshot.total))
        end
    end
    local fraction = math.max(0, math.min(1, (completed + current_fraction) / total_count))
    if active.progress_handle and plugin.update_progress(active.progress_handle, message, fraction) then return true end
    if active.progress_handle then active.progress_handle = nil end
    if active.progress_attempted then return active.use_plugin_progress == true end
    active.progress_attempted = true
    active.progress_handle = plugin.show_progress("Audiobookshelf download", message, fraction)
    active.use_plugin_progress = active.progress_handle ~= nil
    return active.use_plugin_progress
end

local function close_download_progress(active)
    if active and active.progress_handle then
        plugin.close_progress(active.progress_handle)
        active.progress_handle = nil
    end
end

local function finish_download(active, cover_err)
    if active.progress_handle then
        plugin.update_progress(active.progress_handle, cover_err and "Download complete (cover unavailable)" or "Download complete", 1)
    end
    close_download_progress(active)
    active_download = nil
    local s, local_item = item_state(active.id)
    local_item.files = active.saved_files
    local_item.downloaded = true
    local_item.path = active.saved_files[1] and active.saved_files[1].path or ""
    local_item.title = active.title
    local_item.series = active.series or ""
    local_item.dir = active.dir
    if cover_err then
        local_item.cover = nil
    else
        local_item.cover = active.dir .. "/cover.jpg"
    end
    save_json(STATE_KEY, s)
    toast(cover_err and "Download complete (cover unavailable)" or "Download complete")
end

local function download_next(active)
    update_download_progress(active)
    local file = active.files[active.index]
    if not file then
        if active.cover_attempted then
            finish_download(active)
            return
        end
        active.cover_attempted = true
        local token = plugin.secrets.get(TOKEN_KEY)
        if not token or token == "" then
            finish_download(active, "missing token")
            return
        end
        active.cover_downloading = true
        update_download_progress(active)
        local cover_url = api_url("/items/" .. url_encode(active.id) .. "/cover")
            .. "?token=" .. url_encode(token)
        local cover_path = active.dir .. "/cover.jpg"
        local handle, start_err = plugin.download_file_async(cover_url, cover_path, true, function(_, cover_err)
            active.download_handle = nil
            active.cover_downloading = false
            if cover_err then
                finish_download(active, friendly_request_error(cover_err))
            else
                finish_download(active)
            end
        end, not active.use_plugin_progress)
        if not handle then
            active.download_handle = nil
            active.cover_downloading = false
            finish_download(active, start_err or "could not start cover download")
        else
            active.download_handle = handle
            update_download_progress(active)
        end
        return
    end
    local path = active.dir .. "/" .. safe_name(file.name)
    local token = plugin.secrets.get(TOKEN_KEY)
    local url = api_url("/items/" .. url_encode(active.id) .. "/file/" .. url_encode(file.ino) .. "/download")
        .. "?token=" .. url_encode(token)
    local handle, start_err = plugin.download_file_async(url, path, true, function(_, err)
        active.download_handle = nil
        if err then
            close_download_progress(active)
            active_download = nil
            toast("Download failed: " .. friendly_request_error(err))
            return
        end
        active.saved_files[#active.saved_files + 1] = {
            path = path, name = file.name, duration = file.duration,
        }
        active.index = active.index + 1
        download_next(active)
    end, not active.use_plugin_progress)
    if not handle then
        active.download_handle = nil
        close_download_progress(active)
        active_download = nil
        toast(friendly_request_error(start_err or "Could not start download"))
    else
        active.download_handle = handle
        update_download_progress(active)
    end
end

local function download_item(item)
    if active_download then toast("A download is already active"); return end
    local id = tostring(item.id or "")
    local files = item.media and item.media.audioFiles or {}
    if #files == 0 then toast("Audiobookshelf returned no audio files"); return end
    local metadata = item.media and item.media.metadata or {}
    local title = metadata.title or item.title or id
    local authors = metadata.authors
    local author = metadata.authorName or metadata.author
    if (not author or author == "") and type(authors) == "table" then
        local first = authors[1]
        author = type(first) == "table" and (first.name or first.author) or first
    end
    if not author or trim(author) == "" then author = "Audiobookshelf" end
    author = safe_name(author)
    local book_title = safe_name(title)
    local raw_series = series_name(item)
    local series = raw_series ~= "" and safe_name(raw_series) or ""
    local author_dir = DOWNLOAD_ROOT .. "/" .. author
    local base_dir = author_dir .. "/" .. book_title
    if series ~= "" then base_dir = author_dir .. "/" .. series .. "/" .. book_title end
    if not mkdir(DOWNLOAD_ROOT) or not mkdir(author_dir) then
        toast("Could not create Audiobooks library folder"); return
    end
    local s, local_item = item_state(id)
    local old_dir = local_item.dir
    if (not old_dir or old_dir == "") and local_item.path then
        old_dir = local_item.path:match("^(.*)/[^/]+$")
    end
    if old_dir and old_dir:sub(1, #DOWNLOAD_ROOT + 1) ~= DOWNLOAD_ROOT .. "/" then old_dir = nil end

    local function directory_owned_by_other(path)
        for other_id, other in pairs(s.items) do
            if other_id ~= id then
                local other_dir = other.dir
                if (not other_dir or other_dir == "") and other.path then
                    other_dir = other.path:match("^(.*)/[^/]+$")
                end
                if other_dir == path then return true end
            end
        end
        return false
    end
    local function directory_has_entries(path)
        local entries = plugin.list_dir(path)
        return type(entries) == "table" and #entries > 0
    end
    local dir
    for attempt = 1, 100 do
        local candidate = attempt == 1 and base_dir or (base_dir .. " (" .. attempt .. ")")
        if not directory_owned_by_other(candidate)
            and (candidate == old_dir or not directory_has_entries(candidate)) then
            dir = candidate
            break
        end
    end
    if not dir then
        toast("Too many books with this title; clear a duplicate folder first")
        return
    end

    -- Migrate this book's existing folder to the current Author/Series/Title
    -- layout when series metadata becomes available or changes.
    if old_dir and old_dir ~= dir and plugin.list_dir(old_dir) ~= nil then
        local moved, move_err = os.rename(old_dir, dir)
        if not moved then
            toast("Could not rename existing book folder: " .. tostring(move_err or "rename failed"))
            return
        end
        for _, saved_file in ipairs(local_item.files or {}) do
            if saved_file.path and saved_file.path:sub(1, #old_dir + 1) == old_dir .. "/" then
                saved_file.path = dir .. saved_file.path:sub(#old_dir + 1)
            end
        end
        if local_item.path and local_item.path:sub(1, #old_dir + 1) == old_dir .. "/" then
            local_item.path = dir .. local_item.path:sub(#old_dir + 1)
        end
        if local_item.cover and local_item.cover:sub(1, #old_dir + 1) == old_dir .. "/" then
            local_item.cover = dir .. local_item.cover:sub(#old_dir + 1)
        end
        local_item.dir = dir
        save_json(STATE_KEY, s)
    end
    if not mkdir(dir) then
        toast("Could not create Audiobooks library folder"); return
    end
    local token = plugin.secrets.get(TOKEN_KEY)
    if not token or token == "" then toast("Configure Audiobookshelf login or API key first"); return end
    local normalized = {}
    for index, file in ipairs(files) do
        local metadata = file.metadata or file
        local name = metadata.relPath or metadata.filename or metadata.path or ("part-" .. index .. ".m4b")
        name = name:match("([^/\\\\]+)$") or name
        local ino = tostring(file.ino or "")
        if ino == "" then
            toast("Audiobookshelf file has no identifier")
            return
        end
        normalized[#normalized + 1] = {
            ino = ino,
            -- Keep the ABS file order stable for the local audiobook library.
            name = string.format("%04d - %s", index, safe_name(name)),
            duration = tonumber(file.duration) or 0,
        }
    end
    active_download = {
        id = id, title = title, series = series, dir = dir, files = normalized, saved_files = {}, index = 1,
        progress_handle = nil, progress_attempted = false, use_plugin_progress = false, download_handle = nil,
    }
    download_next(active_download)
end

local function open_item(item, replace_handle)
    local id = tostring(item.id or "")
    local title = item.media and item.media.metadata and item.media.metadata.title or item.title or id
    local rows = {}
    if is_local(id) then
        rows[#rows + 1] = "Delete local copy"
        rows[#rows + 1] = "Download again"
    else
        rows[#rows + 1] = "Download"
    end
    rows[#rows + 1] = "Refresh metadata"
    local item_handle
    item_handle = plugin.show_list(title, rows, function(index)
        if rows[index] == "Delete local copy" then delete_item(id, item_handle)
        elseif rows[index] == "Download" or rows[index] == "Download again" then download_item(item)
        elseif rows[index] == "Refresh metadata" then refresh_item(id, function(_, err)
            toast(err or "Metadata refreshed")
        end) end
    end, replace_handle and { replace = replace_handle } or nil)
end

local function fetch_library(library)
    local path = "/libraries/" .. url_encode(library.id) .. "/items?limit=" .. PAGE_SIZE .. "&page=0&sort=name"
    request("GET", path, function(data, err)
        if err then toast(err); return end
        local rows, items = {}, data.results or data.items or {}
        for _, item in ipairs(items) do
            local id = tostring(item.id or "")
            if id ~= "" then
                local title = item.media and item.media.metadata and item.media.metadata.title or item.title or id
                rows[#rows + 1] = title .. (is_local(id) and " [saved]" or "")
            end
        end
        if #rows == 0 then toast("No audiobooks found"); return end
        local list_handle
        list_handle = plugin.show_list(library.name or "Audiobookshelf", rows, function(index)
            local item = items[index]
            if item then refresh_item(tostring(item.id), function(full, refresh_err)
                if refresh_err then toast(refresh_err) else open_item(full or item, list_handle) end
            end) end
        end)
    end)
end

local function fetch_libraries()
    request("GET", "/libraries", function(data, err)
        if err then toast(err); return end
        local libraries = data.libraries or data
        local rows, usable = {}, {}
        for _, library in ipairs(libraries or {}) do
            if library.mediaType == nil or library.mediaType == "book" then
                usable[#usable + 1] = library
                rows[#rows + 1] = library.name or library.id or "Library"
            end
        end
        if #rows == 0 then toast("No audiobook libraries found"); return end
        plugin.show_list("Audiobookshelf Libraries", rows, function(index)
            fetch_library(usable[index])
        end)
    end)
end

show_downloaded = function(replace_handle)
    local s = state()
    local rows, ids = {}, {}
    for id, item in pairs(s.items) do
        if is_local(id) then
            ids[#ids + 1] = id
            rows[#rows + 1] = tostring(item.title or id)
        end
    end
    if #rows == 0 then
        toast("No downloaded books")
        plugin.show_list("Downloaded", { "No downloaded books" }, function() end,
            replace_handle and { replace = replace_handle } or nil)
        return
    end
    local list_handle
    list_handle = plugin.show_list("Downloaded", rows, function(index)
        refresh_item(ids[index], function(item, err)
            if err then toast(err) else open_item(item or { id = ids[index] }, list_handle) end
        end)
    end, replace_handle and { replace = replace_handle } or nil)
end

local function configure_url()
    local ok, err = plugin.show_text_input("Audiobookshelf URL", stored(URL_KEY, ""), false, function(value)
        value = trim(value):gsub("/+$", "")
        plugin.storage.set(URL_KEY, value)
        toast("Server URL saved")
    end)
    if not ok then toast(err or "Text input unavailable") end
end

local function login_with_credentials(username, password)
    if base_url() == "" then toast("Configure the Audiobookshelf URL first"); return end
    local options = {
        url = base_url() .. "/login",
        method = "POST",
        headers = { ["Accept"] = "application/json" },
        body = plugin.json_encode({ username = username, password = password }),
        content_type = "application/json",
        verify_tls = true,
        connect_timeout_ms = 10000,
        read_timeout_ms = 20000,
        total_timeout_ms = 60000,
        max_response_bytes = JSON_LIMIT,
    }
    plugin.http_request(options, function(status, response, err)
        if err then toast(friendly_request_error(err)); return end
        if status < 200 or status >= 300 then
            toast("Audiobookshelf login failed (HTTP " .. tostring(status) .. ")")
            return
        end
        local data = decode(response)
        local token = data and data.user and data.user.token
        if not token or token == "" then toast("Audiobookshelf returned no session token"); return end
        plugin.secrets.set(TOKEN_KEY, token)
        plugin.storage.set(USERNAME_KEY, username)
        plugin.secrets.set(PASSWORD_KEY, password)
        toast("Audiobookshelf login successful")
    end)
end

local function configure_login()
    local ok, err = plugin.show_text_input("Audiobookshelf username", stored(USERNAME_KEY, ""), false, function(username)
        username = trim(username)
        if username == "" then toast("Username is required"); return end
        local password_ok, password_err = plugin.show_text_input("Audiobookshelf password", nil, true, function(password)
            if not password or password == "" then toast("Password is required"); return end
            login_with_credentials(username, password)
        end)
        if not password_ok then toast(password_err or "Password input unavailable") end
    end)
    if not ok then toast(err or "Username input unavailable") end
end

local function configure_key()
    local ok, err = plugin.show_text_input("Audiobookshelf API key", "", true, function(value)
        plugin.secrets.set(TOKEN_KEY, value)
        toast("API key saved")
    end)
    if not ok then toast(err or "Text input unavailable") end
end

local function settings()
    plugin.show_settings_list("Audiobookshelf Settings", {
        { type = "row", label = "Server URL", on_select = configure_url },
        { type = "row", label = "Login with username/password", on_select = configure_login },
        { type = "row", label = "API key (advanced)", on_select = configure_key },
        { type = "row", label = "Test connection", on_select = function()
            request("GET", "/me", function(_, err) toast(err or "Connection successful") end)
        end },
        { type = "row", label = "Sign out / clear token", on_select = function()
            plugin.secrets.delete(TOKEN_KEY)
            plugin.secrets.delete(PASSWORD_KEY)
            plugin.storage.delete(USERNAME_KEY)
            toast("Audiobookshelf credentials cleared")
        end },
    })
end

local function open_home()
    plugin.show_list("Audiobookshelf", {
        "Libraries",
        "Downloaded",
        "Settings",
    }, function(index)
        if index == 1 then fetch_libraries()
        elseif index == 2 then show_downloaded()
        elseif index == 3 then settings() end
    end)
end

if not plugin.has_capability("network.http.async")
    or not plugin.has_capability("network.http.download")
    or not HAS_DOWNLOAD_PROGRESS then
    plugin.show_toast("Audiobookshelf needs HTTP download progress support")
    return
end

plugin.set_interval(1, function()
    if active_download then update_download_progress(active_download) end
end)

-- Stream Media tiles use theme-relative assets. Install both states into the
-- writable theme override so the supplied plugin asset can be used by the
-- native tile grid.
pcall(plugin.set_icon, ICON_PATH, ICON_SOURCE)
pcall(plugin.set_icon, ICON_PATH_SELECTED, ICON_SOURCE_SELECTED)
plugin.register_stream_media_tile("Audiobookshelf", open_home, ICON_PATH)
