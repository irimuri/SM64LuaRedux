-- SM64 Lua Redux, Powerful SM64 TASing utility

-- Core is heavily modified InputDirection lua by:
-- Author: MKDasher
-- Hacker: Eddio0141
-- Special thanks to Pannenkoek2012 and Peter Fedak for angle calculation support.
-- Also thanks to MKDasher to making the code very clean
-- Other contributors:
--	Madghostek, Xander, galoomba, ShadoXFM, Lemon, Manama, tjk

assert(emu.atloadstate, "emu.atloadstate missing")

-- forward-compat lua 5.4 shims
if not math.pow then
    math.pow = function(x, y)
        return x ^ y
    end
end
if not math.atan2 then
    math.atan2 = math.atan
end

--1.1.7+ shim: atupdatescreen no longer allows you to use d2d
if emu.atdrawd2d then
    print("Applied atdrawd2d shim")
    emu.atupdatescreen = emu.atdrawd2d
end

function swap(arr, index_1, index_2)
    local tmp = arr[index_2]
    arr[index_2] = arr[index_1]
    arr[index_1] = tmp
end

function expand_rect(t)
    return {
        x = t[1],
        y = t[2],
        width = t[3],
        height = t[4],
    }
end

function dictlen(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

folder = debug.getinfo(1).source:sub(2):match("(.*\\)")
res_path = folder .. "res\\"
views_path = folder .. "views\\"
core_path = folder .. "core\\"
lib_path = folder .. "lib\\"
processors_path = folder .. "processors\\"

dofile(lib_path .. "mupen-lua-ugui.lua")
dofile(lib_path .. "mupen-lua-ugui-ext.lua")
dofile(lib_path .. "linq.lua")
json = dofile(lib_path .. "json.lua")
dofile(res_path .. "base_style.lua")
dofile(core_path .. "Settings.lua")
dofile(core_path .. "Formatter.lua")
dofile(core_path .. "Drawing.lua")
dofile(core_path .. "Memory.lua")
dofile(core_path .. "Joypad.lua")
dofile(core_path .. "Angles.lua")
dofile(core_path .. "Engine.lua")
dofile(core_path .. "MoreMaths.lua")
dofile(core_path .. "Actions.lua")
dofile(core_path .. "WorldVisualizer.lua")
dofile(core_path .. "MiniVisualizer.lua")
dofile(core_path .. "Lookahead.lua")
dofile(core_path .. "Timer.lua")
dofile(core_path .. "RNGToIndex.lua")
dofile(core_path .. "IndexToRNG.lua")
dofile(core_path .. "Ghost.lua")
dofile(core_path .. "VarWatch.lua")
dofile(core_path .. "Presets.lua")
Hotkeys = dofile(core_path .. "Hotkeys.lua")
Addresses = dofile(core_path .. "Addresses.lua")

Memory.initialize()
Joypad.update()
VarWatch_update()
Drawing.size_up()
Presets.restore()
Presets.apply(Presets.persistent.current_index)

local views = {
    dofile(views_path .. "TAS.lua"),
    dofile(views_path .. "Settings.lua"),
    dofile(views_path .. "Timer.lua"),
    dofile(views_path .. "Experiments.lua"),
    dofile(views_path .. "RNG.lua"),
    dofile(views_path .. "Ghost.lua"),
}

local processors = {
    dofile(processors_path .. "Walk.lua"),
    dofile(processors_path .. "Swimming.lua"),
    dofile(processors_path .. "Wallkicker.lua"),
    dofile(processors_path .. "Grind.lua"),
    dofile(processors_path .. "Framewalk.lua"),
}

local mouse_wheel = 0

-- Reading memory in at_input returns stale data from previous frame, so we read it in atvi
-- However, we use this flag to prevent reading multiple times per frame, as it is very expensive
local new_frame = true

-- Amount of updatescreen invocations, used for throttling repaints during ff
local paints = 0

-- Whether the current paint cycle is being skipped
paint_skipped = false

-- Flag keeping track of whether atinput has fired for one time
local first_input = true

local keys = input.get()
local last_keys = input.get()

function at_input()
    if first_input then
        if Settings.autodetect_address then
            Settings.address_source_index = Memory.find_matching_address_source_index()
        end
        first_input = false
    end
    -- frame stage 1: set everything up
    new_frame = true
    Joypad.update()
    Engine.input()

    if Settings.override_rng then
        if Settings.override_rng_use_index then
            memory.writeword(0x80B8EEE0, get_value(Settings.override_rng_value))
        else
            memory.writeword(0x80B8EEE0, Settings.override_rng_value)
        end
    end

    -- frame stage 2: let domain code loose on everything, then perform transformations or inspections (e.g.: swimming, rng override, ghost)
    -- TODO: make this into a priority callback system?
    Timer.update()
    Lookahead.update()

    for i = 1, #processors, 1 do
        Joypad.input = processors[i].process(Joypad.input)
    end

    Joypad.send()
    Ghost.update()
end

function at_update_screen()
    paints = paints + 1
    paint_skipped = (paints % Settings.repaint_throttle) ~= 0 and emu.get_ff and emu.get_ff()

    -- Throttle repaints in ff
    if paint_skipped then
        return
    end

    if d2d and d2d.clear then
        d2d.clear(0, 0, 0, 0)
    end

    last_keys = ugui.internal.deep_clone(keys)
    keys = input.get()

    if dictlen(input.diff(keys, last_keys)) > 0 then
        Hotkeys.on_key_down(keys)
    end

    ugui.begin_frame({
        mouse_position = {
            x = keys.xmouse,
            y = keys.ymouse,
        },
        wheel = mouse_wheel,
        is_primary_down = keys.leftclick,
        held_keys = keys,
    })

    mouse_wheel = 0

    WorldVisualizer.draw()
    MiniVisualizer.draw()

    BreitbandGraphics.fill_rectangle({
        x = Drawing.initial_size.width,
        y = 0,
        width = Drawing.size.width - Drawing.initial_size.width,
        height = Drawing.size.height
    }, Presets.styles[Settings.active_style_index].theme.background_color)

    views[Settings.tab_index].draw()

    -- navigation and presets

    Settings.tab_index = ugui.carrousel_button({
        uid = -5000,
        rectangle = grid_rect(0, 15, 8, 1),
        items = lualinq.select_key(views, "name"),
        selected_index = Settings.tab_index,
    })

    for i = 1, #Presets.persistent.presets, 1 do
        local prev = Presets.persistent.current_index == i
        local now = ugui.toggle_button({
            uid = -5000 - 5 * i,

            rectangle = grid_rect(i - 1, 16, 1, 1),
            text = i,
            is_checked = Presets.persistent.current_index == i
        })

        if now and not prev then
            Presets.apply(i)
        end
    end

    if ugui.button({
            uid = -6000,

            rectangle = grid_rect(6, 16, 2, 1),
            text = "Reset"
        }) then
        Presets.reset(Presets.persistent.current_index)
        Presets.apply(Presets.persistent.current_index)
    end

    ugui.end_frame()
end

function at_vi()
    if new_frame then
        Memory.update_previous()
        Memory.update()
        VarWatch_update()
        new_frame = false
    end

    Engine.vi()
end

function at_loadstate()
    -- Previous state is now messed up, since it's not the actual previous frame but some other game state
    -- What do we do at this point, leave it like this and let the engine calculate wrong diffs, or copy current state to previous one?
    Memory.update_previous()
    Memory.update()
    VarWatch_update()
end

emu.atloadstate(at_loadstate)
emu.atinput(at_input)
emu.atupdatescreen(at_update_screen)
emu.atvi(at_vi)
emu.atstop(function()
    Presets.save()
    Drawing.size_down()
    BreitbandGraphics.free()
    ugui_ext.free()
end)
emu.atwindowmessage(function(hwnd, msg_id, wparam, lparam)
    if msg_id == 522 then                         -- WM_MOUSEWHEEL
        -- high word (most significant 16 bits) is scroll rotation in multiples of WHEEL_DELTA (120)
        local scroll = math.floor(wparam / 65536) --(wparam & 0xFFFF0000) >> 16
        if scroll == 120 then
            mouse_wheel = 1
        elseif scroll == 65416 then -- 65536 - 120
            mouse_wheel = -1
        end
    end
end)
