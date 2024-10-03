/*
   TODO:

   - Save game locations
   - Get a handle to our own executable
   - Asset loading path
   - Threading
   - Raw input (support multiple keyboards if possible with SDL)
   - Sleep
   - Clipcursor (for multimonitor support)
   - Fullscreen support
   - Control cursor visibility
   - QueryCancelAutoplay with SDL?
   - sdl.WindowEventID HIDDEN/FOCUS_LOST/LEAVE/etc.
   - Blit speed improvments (can SDL's renderer be sped up?)
   - Hardware acceleration (OpenGL/Direct3D/Vulkan)
   - International WASD support

   NOTE: This list is not comprehensive
*/

package main

import "core:fmt"
import "core:c"
import "core:mem"
import "core:os"
import "core:io"
import "core:dynlib"
import "core:path/filepath"
import "base:intrinsics"
import sdl "vendor:sdl2"
import g "../game"

// NOTE: Our "back buffer" is represented by OffscreenBuffer.memory, which the game will draw pixels into
Offscreen_Buffer :: struct
{
    texture: ^sdl.Texture,
    rect: sdl.Rect,
    // NOTE: Pixels are always 32 bits wide, memory order BB GG RR XX
    memory: []byte,
    width, height, pitch,
    bytes_per_pixel: int,
}

Debug_Time_Marker :: struct {
    output_play_cursor,
    output_write_cursor,
    output_location,
    output_byte_count,
    expected_flip_play_cursor,
    flip_play_cursor,
    flip_write_cursor: int,
}

Window_Dimension :: struct {
    x, y, width, height: int,
}

Audio_Ring_Buffer :: struct {
    size: int,
    write_cursor: int,
    play_cursor: int,
    data: []byte,
}

Sound_Output :: struct {
    samples_per_second: int,
    running_sample_index: u32,
    bytes_per_sample: int,
    buffer_size: int,
    safety_bytes: int,
}

Game_Code :: struct {
    lib: dynlib.Library,
    lib_last_write_time: os.File_Time,
    // IMPORTANT: Always check to see if these are nil when calling
    update_and_render: g.Game_Update_And_Render,
    get_sound_samples: g.Game_Get_Sound_Samples,
}

Recorded_Input :: struct {
    input_count: int,
    input_stream: []g.Input,
}

Replay_Buffer :: struct {
    path: string,
    handle: io.Stream,
}

State :: struct {
    total_size: u64,
    game_memory_block: []byte,
    replay_buffers: [4]Replay_Buffer,
    recording_handle,
    playback_handle: io.Stream,
    input_recording_index,
    input_playing_index: int,
    build_path: string,
}

global_running: bool
global_pause: bool
global_back_buffer: Offscreen_Buffer
global_ring_buffer: Audio_Ring_Buffer
global_perf_count_frequency: u64

CHANNELS :: 2
SAMPLES :: 512
LEFT_DEADZONE :: 7849
RIGHT_DEADZONE :: 8689
MAX_CONTROLLER_HANDLES :: g.MAX_CONTROLLERS - 1

controller_handles: [MAX_CONTROLLER_HANDLES]^sdl.GameController
rumble_handles: [MAX_CONTROLLER_HANDLES]^sdl.Haptic

copy_entire_file :: proc(source_name, target_name: string) {
    if data, read_ok := os.read_entire_file(source_name); read_ok {
        defer delete(data)

        if write_ok := os.write_entire_file(target_name, data); !write_ok {
            // TODO: Logging
            fmt.printfln("Failed to copy file during write! Source: {0} Target: {1}",
                         source_name,
                         target_name)
        }
    } else {
        // TODO: Logging
        fmt.printfln("Failed to copy file during read! Source: {0} Target: {1}",
                     source_name,
                     target_name)
    }
}

get_last_write_time :: proc(filename: string) -> os.File_Time {
    result: os.File_Time

    if last_write_time, err := os.last_write_time_by_name(filename); err != os.ERROR_NONE {
        // TODO: Logging
        fmt.printfln("Failed to fetch last write time for {0}: {1}!", filename, err)
    } else {
        result = last_write_time
    }

    return result
}

shared_lib_ext :: proc() -> string {
    result: string

    #partial switch ODIN_OS {
    case .Darwin:
        result = "dylib"
    case .Windows:
        result = "dll"
    case .Linux:
        result = "so"
    }

    return result
}

load_game_code :: proc(lib_path, temp_lib_path: string) -> (Game_Code, bool) {
    result: Game_Code; result_ok: bool

    result.lib_last_write_time = get_last_write_time(lib_path)

    copy_entire_file(lib_path, temp_lib_path)

    if _, ok := dynlib.initialize_symbols(&result, temp_lib_path, "game_", "lib"); !ok {
        fmt.println("Failed to initialize symbols from game code!")
    }

    result_ok = (result.update_and_render != nil && result.get_sound_samples != nil)

    if !result_ok {
        // TODO: Logging
        fmt.println("Failed to load required game code procedures!")
        dynlib.unload_library(result.lib)
        result = {}; result_ok = false
    }

    return result, result_ok
}

unload_game_code :: proc(game_code: ^Game_Code) {
    if game_code.lib != nil {
        if ok := dynlib.unload_library(game_code.lib); ok {
            game_code.lib = nil
        }
    }

    game_code.update_and_render = nil
    game_code.get_sound_samples = nil
}

audio_callback :: proc "c" (user_data: rawptr, data: [^]u8, length: c.int) {
    ring_buffer := (^Audio_Ring_Buffer)(user_data)

    buffer_size := int(length)
    region_1_size := buffer_size
    region_2_size: int

    if ring_buffer.play_cursor + buffer_size > ring_buffer.size {
        region_1_size = ring_buffer.size - ring_buffer.play_cursor
        region_2_size = buffer_size - region_1_size
    }

    mem.copy(data, &ring_buffer.data[ring_buffer.play_cursor], int(region_1_size))
    mem.copy(&data[region_1_size], raw_data(ring_buffer.data), int(region_2_size))
    ring_buffer.play_cursor = (ring_buffer.play_cursor + buffer_size) % ring_buffer.size
    ring_buffer.write_cursor = (ring_buffer.play_cursor + buffer_size) % ring_buffer.size
}

init_audio :: proc(samples_per_second, buffer_size: int) -> sdl.AudioDeviceID {
    audio := sdl.AudioSpec {
        freq = c.int(samples_per_second),
        format = sdl.AUDIO_S16LSB,
        channels = CHANNELS,
        samples = SAMPLES,
        callback = audio_callback,
        userdata = &global_ring_buffer,
    }

    global_ring_buffer.size = buffer_size
    global_ring_buffer.data = make([]byte, buffer_size)

    device_id := sdl.OpenAudioDevice(nil, false, &audio, nil, false)

    fmt.printfln("Initialized audio device at frequency {0} Hz, {1} Channels: {2}",
                 audio.freq,
                 audio.channels,
                 sdl.GetAudioDeviceStatus(device_id))

    if audio.format != sdl.AUDIO_S16LSB {
        fmt.println("Oopsie! We didn't get AUDIO_S16LSB as our sample format!")
        sdl.CloseAudio()
    }

    return device_id
}

fill_sound_buffer :: proc(sound_output: ^Sound_Output,
                          byte_to_lock, bytes_to_write: int,
                          source_buffer: ^g.Sound_Output_Buffer) {
    region_1 := global_ring_buffer.data[byte_to_lock:]
    region_1_size := bytes_to_write

    if region_1_size + byte_to_lock > sound_output.buffer_size {
        region_1_size = sound_output.buffer_size - byte_to_lock
    }

    region_2 := global_ring_buffer.data
    region_2_size := bytes_to_write - region_1_size

    assert(region_1_size + region_2_size == bytes_to_write)

    region_1_sample_count := region_1_size / sound_output.bytes_per_sample
    dest_sample := transmute([]i16)region_1
    source_sample := source_buffer.samples
    for i in 0..<region_1_sample_count {
        dest_sample[i * 2] = source_sample[i * 2]
        dest_sample[i * 2 + 1] = source_sample[i * 2 + 1]
        sound_output.running_sample_index += 1
    }

    region_2_sample_count := region_2_size / sound_output.bytes_per_sample
    dest_sample = transmute([]i16)region_2
    source_sample = source_sample[region_1_sample_count * 2:]
    for i in 0..<region_2_sample_count {
        dest_sample[i * 2] = source_sample[i * 2]
        dest_sample[i * 2 + 1] = source_sample[i * 2 + 1]
        sound_output.running_sample_index += 1
    }
}

get_window_dimension :: proc(window: ^sdl.Window) -> Window_Dimension {
    result: Window_Dimension

    x, y, width, height: c.int
    sdl.GetWindowSize(window, &width, &height)
    sdl.GetWindowPosition(window, &x, &y)

    result.x = int(x)
    result.y = int(y)
    result.width = int(width)
    result.height = int(height)

    return result
}

resize_texture :: proc(buffer: ^Offscreen_Buffer, renderer: ^sdl.Renderer, width, height: int) {
    if buffer.texture != nil {
        sdl.DestroyTexture(buffer.texture)
    }

    if buffer.memory != nil {
        delete(buffer.memory)
    }

    buffer.width = width
    buffer.height = height
    buffer.bytes_per_pixel = 4
    buffer_memory_size := buffer.width * buffer.height * buffer.bytes_per_pixel
    buffer.memory = make([]byte, buffer_memory_size)
    buffer.pitch = buffer.width * buffer.bytes_per_pixel
    buffer.rect = sdl.Rect{
        0, 0,
        c.int(buffer.width), c.int(buffer.height),
    }

    buffer.texture = sdl.CreateTexture(renderer, .ARGB8888, .STREAMING, c.int(buffer.width), c.int(buffer.height))
}

update_window :: proc(window: ^sdl.Window, renderer: ^sdl.Renderer, buffer: ^Offscreen_Buffer) {
    if sdl.UpdateTexture(buffer.texture, nil, raw_data(buffer.memory), c.int(buffer.pitch)) != 0 {
        // TODO: Handle failure to update texture
    }

    // NOTE: For prototyping purposes, we're going to always blit 1:1 pixels
    // to make sure we don't introduce artifacts with stretching while learning
    // to code the renderer (maybe SDL's renderer already compensates for this,
    // since we don't see any weird artifacting when the SDL texture shrinks down)
    if sdl.RenderCopy(renderer, buffer.texture, nil, &buffer.rect) != 0 {
        // TODO: Handle failure to copy texture
    }

    sdl.RenderPresent(renderer)
}

handle_event :: proc(state: ^State, event: ^sdl.Event, keyboard_controller: ^g.Controller_Input, input: ^g.Input) {
    window := sdl.GetWindowFromID(event.window.windowID)

    #partial switch event.window.type {
    case .QUIT:
        fmt.println("SDL_QUIT")
        global_running = false
    case .KEYUP:
        fallthrough
    case .KEYDOWN:
        key_code := event.key.keysym.sym
        is_down := event.key.state == sdl.PRESSED
        was_down: bool

        if event.key.state == sdl.RELEASED {
            was_down = true
        } else if event.key.repeat != 0 {
            was_down = true
        }

        if event.key.repeat == 0 {
            #partial switch key_code {
            case .W:
                process_keyboard_message(&keyboard_controller.move_up, is_down)
            case .A:
                process_keyboard_message(&keyboard_controller.move_left, is_down)
            case .S:
                process_keyboard_message(&keyboard_controller.move_down, is_down)
            case .D:
                process_keyboard_message(&keyboard_controller.move_right, is_down)
            case .Q:
                process_keyboard_message(&keyboard_controller.left_shoulder, is_down)
            case .E:
                process_keyboard_message(&keyboard_controller.right_shoulder, is_down)
            case .UP:
                process_keyboard_message(&keyboard_controller.action_up, is_down)
            case .LEFT:
                process_keyboard_message(&keyboard_controller.action_left, is_down)
            case .DOWN:
                process_keyboard_message(&keyboard_controller.action_down, is_down)
            case .RIGHT:
                process_keyboard_message(&keyboard_controller.action_right, is_down)
            case .ESCAPE:
                process_keyboard_message(&keyboard_controller.start, is_down)
            case .SPACE:
                process_keyboard_message(&keyboard_controller.back, is_down)
            case .P:
                when ODIN_DEBUG {
                    if is_down {
                        global_pause = !global_pause
                    }
                }
            case .L:
                if is_down {
                    if state.input_playing_index == 0 {
                        if state.input_recording_index == 0 {
                            begin_recording_input(state, 1)
                        } else {
                            end_recording_input(state)
                            begin_input_playback(state, 1)
                        }
                    } else {
                        end_input_playback(state)
                    }
                }
            case .F4:
                alt_key_was_down := event.key.keysym.mod == sdl.KMOD_ALT

                if alt_key_was_down {
                    global_running = false
                }
            }
        }
    case .WINDOWEVENT:
        #partial switch event.window.event {
        case .CLOSE:
            fmt.println("SDL_WINDOWEVENT_CLOSE")
            global_running = false
        case .RESIZED:
            fmt.printfln("SDL_WINDOWEVENT_RESIZED ({0}, {1})", event.window.data1, event.window.data2)
        case .FOCUS_GAINED:
            fmt.println("SDL_WINDOWEVENT_FOCUS_GAINED")
            if false {
                sdl.SetWindowOpacity(window, 1)
            }
        case .FOCUS_LOST:
            fmt.println("SDL_WINDOWEVENT_FOCUS_LOST")
            if false {
                sdl.SetWindowOpacity(window, 0.25)
            }
        case .EXPOSED:
            renderer := sdl.GetRenderer(window)
            update_window(window, renderer, &global_back_buffer)
        }
    case .MOUSEWHEEL:
        // TODO
    }
}

open_game_controllers :: proc() {
    max_joysticks := sdl.NumJoysticks()
    controller_index := 0
    for joystick_index in 0..<max_joysticks {
        if !sdl.IsGameController(joystick_index) do continue
        if controller_index >= MAX_CONTROLLER_HANDLES do break

        controller_handles[controller_index] = sdl.GameControllerOpen(joystick_index)
        rumble_handles[controller_index] = sdl.HapticOpen(joystick_index)

        rumble_did_init := sdl.HapticRumbleInit(rumble_handles[controller_index]) != 0
        if rumble_handles[controller_index] != nil && rumble_did_init {
            sdl.HapticClose(rumble_handles[controller_index])
            rumble_handles[controller_index] = nil
        }

        controller_index += 1
    }
}

close_game_controllers :: proc() {
    for controller, index in controller_handles {
        if controller != nil {
            if rumble_handles[index] != nil do sdl.HapticClose(rumble_handles[index])

            sdl.GameControllerClose(controller)
        }
    }
}

process_keyboard_message :: proc(new_state: ^g.Button_State, is_down: bool) {
    if new_state.ended_down != is_down {
        new_state.ended_down = is_down
        new_state.half_transition_count += 1
    }
}

process_controller_button :: proc(old_state: ^g.Button_State,
                                  new_state: ^g.Button_State,
                                  value: bool) {
    new_state.ended_down = value
    new_state.half_transition_count += new_state.ended_down == old_state.ended_down ? 1 : 0
}

process_stick_value :: proc(stick_value, deadzone_threshold: int, flip := false) -> f32 {
    result: f32

    joystick_min := -sdl.JOYSTICK_AXIS_MIN
    joystick_max := sdl.JOYSTICK_AXIS_MAX
    value := stick_value

    if flip {
        joystick_min = sdl.JOYSTICK_AXIS_MAX
        joystick_max = -sdl.JOYSTICK_AXIS_MIN
        value = -value
    }

    if value < -LEFT_DEADZONE {
        result = f32(value + deadzone_threshold) / f32(joystick_min - deadzone_threshold)
    } else if value > LEFT_DEADZONE {
        result = f32(value - deadzone_threshold) / f32(joystick_max - deadzone_threshold)
    }

    return result
}

get_monitor_refresh_rate :: proc(window: ^sdl.Window) -> int {
    mode: sdl.DisplayMode
    display_index := sdl.GetWindowDisplayIndex(window)
    result := 60

    if sdl.GetDesktopDisplayMode(display_index, &mode) == 0 {
        if mode.refresh_rate > 0 {
            result = int(mode.refresh_rate)
        }
    }

    return result
}

get_seconds_elapsed :: proc(start, end: u64) -> f32 {
    result := f32(end - start) / f32(global_perf_count_frequency)

    return result
}

debug_sync_display :: proc(back_buffer: ^Offscreen_Buffer,
                           markers: []Debug_Time_Marker,
                           current_marker: ^Debug_Time_Marker,
                           sound_output: ^Sound_Output,
                           target_seconds_per_frame: f32) {
    pad_x := 16
    pad_y := 16
    line_height := 64

    c := f32(back_buffer.width - 2 * pad_y) / f32(sound_output.buffer_size)

    for marker in markers {
        assert(marker.output_play_cursor < sound_output.buffer_size)
        assert(marker.output_write_cursor < sound_output.buffer_size)
        assert(marker.output_location < sound_output.buffer_size)
        assert(marker.output_byte_count < sound_output.buffer_size)
        assert(marker.flip_play_cursor < sound_output.buffer_size)
        assert(marker.flip_write_cursor < sound_output.buffer_size)

        play_color := u32(0xFFFFFFFF)
        write_color := u32(0xFFFF0000)
        expected_flip_color := u32(0xFFFFFF00)
        play_window_color := u32(0xFFFF00FF)

        top := pad_y
        bottom := pad_y + line_height
        if marker == current_marker^ {
            top += line_height + pad_y
            bottom += line_height + pad_y

            first_top := top

            debug_draw_sound_buffer_marker(back_buffer, sound_output, c, pad_x, top, bottom,
                                           marker.output_play_cursor, play_color)
            debug_draw_sound_buffer_marker(back_buffer, sound_output, c, pad_x, top, bottom,
                                           marker.output_write_cursor, write_color)

            top += line_height + pad_y
            bottom += line_height + pad_y

            debug_draw_sound_buffer_marker(back_buffer, sound_output, c, pad_x, top, bottom,
                                           marker.output_location, play_color)
            debug_draw_sound_buffer_marker(back_buffer, sound_output, c, pad_x, top, bottom,
                                           marker.output_location + marker.output_byte_count, write_color)

            top += line_height + pad_y
            bottom += line_height + pad_y

            debug_draw_sound_buffer_marker(back_buffer, sound_output, c, pad_x, first_top, bottom,
                                           marker.expected_flip_play_cursor, expected_flip_color)
        }

        debug_draw_sound_buffer_marker(back_buffer, sound_output, c, pad_x, top, bottom,
                                       marker.flip_play_cursor, play_color)
        debug_draw_sound_buffer_marker(back_buffer, sound_output, c, pad_x, top, bottom,
                                       marker.flip_play_cursor + SAMPLES * sound_output.bytes_per_sample, play_window_color)
        debug_draw_sound_buffer_marker(back_buffer, sound_output, c, pad_x, top, bottom,
                                       marker.flip_write_cursor, write_color)
    }
}

debug_draw_sound_buffer_marker :: proc(back_buffer: ^Offscreen_Buffer,
                                       sound_output: ^Sound_Output,
                                       c: f32,
                                       pad_x, top, bottom, value: int,
                                       color: u32) {
    x := pad_x + int(c * f32(value))

    debug_draw_vertical(back_buffer, x, top, bottom, color)
}

debug_draw_vertical :: proc(back_buffer: ^Offscreen_Buffer,
                            x, _top, _bottom: int, color: u32) {
    top := _top
    bottom := _bottom

    if top <= 0 {
        top = 0
    }

    if bottom > back_buffer.height {
        bottom = back_buffer.height
    }

    if x >= 0 && x < back_buffer.width {
        offset := x * back_buffer.bytes_per_pixel + top * back_buffer.pitch

        pixel := back_buffer.memory[offset:]

        for _ in top..<bottom {
            (transmute([]u32)pixel)[0] = color
            pixel = pixel[back_buffer.pitch:]
        }
    }
}

mode :: proc() -> int {
    mode: int = 0

    when ODIN_OS == .Linux || ODIN_OS == .Darwin {
        // NOTE(justasd): 644 (owner read, write; group read; others read)
        mode = os.S_IRUSR | os.S_IWUSR | os.S_IRGRP | os.S_IROTH
    }

    return mode
}

get_input_path :: proc(state: ^State, input_stream: bool, slot_index: int) -> string {
    result := fmt.tprintf("{0}/loop_edit_{1}_{2}.omi",
                          state.build_path,
                          slot_index,
                          input_stream ? "input" : "state")

    return result
}

begin_recording_input :: proc(state: ^State, input_recording_index: int) {
    assert(input_recording_index < len(state.replay_buffers))
    replay_buffer := state.replay_buffers[input_recording_index]

    state.input_recording_index = input_recording_index

    path := get_input_path(state, true, input_recording_index)
    flags := os.O_WRONLY | os.O_CREATE | os.O_TRUNC
    if handle, err := os.open(path, flags, mode()); err == os.ERROR_NONE {
        state.recording_handle = os.stream_from_handle(handle)
    } else {
        // TODO: Logging
    }

    if _, err := io.write_at(replay_buffer.handle, state.game_memory_block, 0);
       err != .None {
        // TODO: Logging
    }
}

end_recording_input :: proc(state: ^State) {
    if err := io.close(state.recording_handle); err != .None {
        // TODO: Logging
    }

    state.input_recording_index = 0
}

begin_input_playback :: proc(state: ^State, input_playing_index: int) {
    assert(input_playing_index < len(state.replay_buffers))
    replay_buffer := state.replay_buffers[input_playing_index]

    state.input_playing_index = input_playing_index

    path := get_input_path(state, true, input_playing_index)
    if handle, err := os.open(path, os.O_RDONLY); err == os.ERROR_NONE {
        state.playback_handle = os.stream_from_handle(handle)
    } else {
        // TODO: Logging
    }

    if _, err := io.read_at(replay_buffer.handle, state.game_memory_block, 0);
       err != .None {
        // TODO: Logging
    }
}

end_input_playback :: proc(state: ^State) {
    if err := io.close(state.playback_handle); err != .None {
        // TODO: Logging
    }

    state.input_playing_index = 0
}

record_input :: proc(state: ^State, new_input: ^g.Input) {
    if _, err := io.write_ptr(state.recording_handle,
                              new_input,
                              size_of(new_input^)); err != .None {
        // TODO: Logging
    }
}

play_back_input :: proc(state: ^State, new_input: ^g.Input) {
    if _, err := io.read_ptr(state.playback_handle,
                             new_input,
                             size_of(new_input^)); err == .EOF {
        // NOTE: We've hit the end of the stream, go back to the beginning
        playing_index := state.input_playing_index
        end_input_playback(state)
        begin_input_playback(state, playing_index)

        if _, err = io.read_ptr(state.playback_handle,
                                new_input,
                                size_of(new_input^)); err != .None {
            // TODO: Logging
        }
    }
}

main :: proc() {
    global_perf_count_frequency = sdl.GetPerformanceFrequency()

    state: State
    state.build_path = filepath.dir(os.args[0])
    ext := shared_lib_ext()
    source_lib_path := fmt.tprintf("{0}/game.{1}", state.build_path, ext)
    temp_lib_path := fmt.tprintf("{0}/game_temp.{1}", state.build_path, ext)

    if sdl.Init({.VIDEO, .GAMECONTROLLER, .HAPTIC, .AUDIO}) != 0 {
        // TODO: Logging
        panic("Failed to initialize SDL!")
    }
    defer sdl.Quit()

    open_game_controllers()
    defer close_game_controllers()

    window: ^sdl.Window
    window = sdl.CreateWindow("Odinmade Hero", 1280, 30, 1280, 720, {.RESIZABLE})
    defer sdl.DestroyWindow(window)

    if window == nil {
        // TODO: Logging
        panic("Failed to create window!")
    }

    monitor_refresh_hz := get_monitor_refresh_rate(window)
    game_update_hz := f32(monitor_refresh_hz / 2)
    target_seconds_per_frame := 1 / f32(game_update_hz)

    renderer := sdl.CreateRenderer(window, -1, {.PRESENTVSYNC})
    defer sdl.DestroyRenderer(renderer)

    if renderer == nil {
        // TODO: Logging
        panic("Failed to create renderer!")
    }

    dim := Window_Dimension { 0, 0, 960, 540 }
    resize_texture(&global_back_buffer, renderer, dim.width, dim.height)

    sound_output: Sound_Output
    sound_output.samples_per_second = 48000
    sound_output.bytes_per_sample = size_of(i16) * 2
    sound_output.buffer_size = sound_output.samples_per_second * sound_output.bytes_per_sample
    sound_output.safety_bytes =
        int(f32(sound_output.samples_per_second * sound_output.bytes_per_sample) /
            game_update_hz)

    when ODIN_DEBUG {
        sound_output.safety_bytes = sound_output.safety_bytes * 3
    } else {
        sound_output.safety_bytes = sound_output.safety_bytes / 3
    }

    // NOTE: Odin initializes the entire buffer to zero, so clearing it isn't necessary
    audio_device_id := init_audio(sound_output.samples_per_second, sound_output.buffer_size)
    defer sdl.CloseAudioDevice(audio_device_id)

    sdl.PauseAudioDevice(audio_device_id, false)

    samples := make([]i16, sound_output.buffer_size)
    defer delete(samples)

    game_memory: g.Memory
    game_memory.permanent_storage_size = g.megabytes(u64(64))
    game_memory.transient_storage_size = g.gigabytes(u64(1))

    state.total_size = game_memory.permanent_storage_size + game_memory.transient_storage_size
    state.game_memory_block = make([]byte, state.total_size)
    game_memory.permanent_storage = state.game_memory_block
    game_memory.transient_storage = game_memory.permanent_storage[game_memory.permanent_storage_size:]
    defer delete(game_memory.permanent_storage)

    /*
       NOTE: Rather than doing memory mapped files for the replay buffer, we simply
       write and read the game state straight out to/from the handle. This is closer
       to Casey's original implementation and seems to perform about as fast
    */
    for &replay_buffer, replay_index in state.replay_buffers {
        replay_buffer.path = get_input_path(&state, false, replay_index)
        flags := os.O_RDWR | os.O_CREATE | os.O_TRUNC

        if handle, err := os.open(replay_buffer.path, flags, mode()); err == os.ERROR_NONE  {
            replay_buffer.handle = os.stream_from_handle(handle)
        } else {
            // TODO: Logging
        }
    }

    if samples == nil || game_memory.permanent_storage == nil || game_memory.transient_storage == nil {
        // TODO: Logging
        panic("Failed to initialized game memory!")
    }

    input: [2]g.Input
    new_input := &input[0]
    old_input := &input[1]

    new_input.seconds_to_advance_over_update = target_seconds_per_frame

    last_counter := sdl.GetPerformanceCounter()

    when ODIN_DEBUG {
        debug_time_marker_index: int
        debug_time_markers := make([]Debug_Time_Marker, 30)
        defer delete(debug_time_markers)
    }

    sound_is_valid: bool
    flip_wall_clock: u64
    last_cycle_count := intrinsics.read_cycle_counter()

    game, game_ok := load_game_code(source_lib_path, temp_lib_path)
    defer unload_game_code(&game)

    if !game_ok {
        // TODO: Logging
        panic("Failed to load game code!")
    }

    global_running = true
    for global_running {
        if last_write_time := get_last_write_time(source_lib_path);
           last_write_time > game.lib_last_write_time {
            unload_game_code(&game)

            if game, game_ok = load_game_code(source_lib_path, temp_lib_path); !game_ok {
                // TODO: Logging
                panic("Failed to reload game code!")
            }
        }

        old_keyboard_controller := &old_input.controllers[0]
        new_keyboard_controller := &new_input.controllers[0]
        // TODO: We can't zero everything because the up/down state will be wrong
        new_keyboard_controller^ = {}
        new_keyboard_controller.is_connected = true

        for &new_button, index in new_keyboard_controller.buttons {
            new_button.ended_down = old_keyboard_controller.buttons[index].ended_down
        }

        event: sdl.Event
        for sdl.PollEvent(&event) {
            handle_event(&state, &event, new_keyboard_controller, new_input)
        }

        if global_pause do continue

        x, y: c.int
        // NOTE: If we prefer to "confine" the mouse to the inside of the window, we can simply
        // switch to using sdl.GetMouseState() and drop the adjustments with the window dimension
        button_state := sdl.GetGlobalMouseState(&x, &y)
        dim = get_window_dimension(window)
        new_input.mouse_x = int(x - c.int(dim.x))
        new_input.mouse_y = int(y - c.int(dim.y))
        new_input.mouse_z = 0 // TODO: Support mousewheel, especially for 3D
        new_input.mouse_buttons[0].ended_down = bool(button_state & sdl.BUTTON_LMASK)
        new_input.mouse_buttons[1].ended_down = bool(button_state & sdl.BUTTON_MMASK)
        new_input.mouse_buttons[2].ended_down = bool(button_state & sdl.BUTTON_RMASK)
        new_input.mouse_buttons[3].ended_down = bool(button_state & sdl.BUTTON_X1MASK)
        new_input.mouse_buttons[4].ended_down = bool(button_state & sdl.BUTTON_X2MASK)

        for controller, index in controller_handles {
            our_index := index + 1
            old_controller := &old_input.controllers[our_index]
            new_controller := &new_input.controllers[our_index]

            if controller != nil && sdl.GameControllerGetAttached(controller) {
                new_controller.is_connected = true
                new_controller.is_analog = old_controller.is_analog

                stick_x := int(sdl.GameControllerGetAxis(controller, .LEFTX))
                stick_y := int(sdl.GameControllerGetAxis(controller, .LEFTY))

                // TODO: This is a square deadzone, check whether the deadzone is "round"
                // and show how to do round deadzone processing
                new_controller.stick_average_x = process_stick_value(stick_x, LEFT_DEADZONE)
                new_controller.stick_average_y = process_stick_value(stick_y, LEFT_DEADZONE, true)

                if new_controller.stick_average_x != 0 ||
                   new_controller.stick_average_y != 0 {
                    new_controller.is_analog = true
                }

                if sdl.GameControllerGetButton(controller, .DPAD_UP) > 0 {
                    new_controller.stick_average_y = 1
                    new_controller.is_analog = false
                }

                if sdl.GameControllerGetButton(controller, .DPAD_DOWN) > 0 {
                    new_controller.stick_average_y = -1
                    new_controller.is_analog = false
                }

                if sdl.GameControllerGetButton(controller, .DPAD_LEFT) > 0 {
                    new_controller.stick_average_x = -1
                    new_controller.is_analog = false
                }

                if sdl.GameControllerGetButton(controller, .DPAD_RIGHT) > 0 {
                    new_controller.stick_average_x = 1
                    new_controller.is_analog = false
                }

                threshold: f32 = 0.5
                process_controller_button(&old_controller.move_left, &new_controller.move_left,
                                          new_controller.stick_average_x < -threshold)
                process_controller_button(&old_controller.move_right, &new_controller.move_right,
                                          new_controller.stick_average_x > threshold)
                process_controller_button(&old_controller.move_down, &new_controller.move_down,
                                          new_controller.stick_average_y < -threshold)
                process_controller_button(&old_controller.move_up, &new_controller.move_up,
                                          new_controller.stick_average_y > threshold)

                process_controller_button(&old_controller.action_down, &new_controller.action_down,
                                          sdl.GameControllerGetButton(controller, .A) > 0)
                process_controller_button(&old_controller.action_left, &new_controller.action_left,
                                          sdl.GameControllerGetButton(controller, .B) > 0)
                process_controller_button(&old_controller.action_right, &new_controller.action_right,
                                          sdl.GameControllerGetButton(controller, .X) > 0)
                process_controller_button(&old_controller.action_up, &new_controller.action_up,
                                          sdl.GameControllerGetButton(controller, .Y) > 0)
                process_controller_button(&old_controller.left_shoulder, &new_controller.left_shoulder,
                                          sdl.GameControllerGetButton(controller, .LEFTSHOULDER) > 0)
                process_controller_button(&old_controller.right_shoulder, &new_controller.right_shoulder,
                                          sdl.GameControllerGetButton(controller, .RIGHTSHOULDER) > 0)
                process_controller_button(&old_controller.start, &new_controller.start,
                                          sdl.GameControllerGetButton(controller, .START) > 0)
                process_controller_button(&old_controller.back, &new_controller.back,
                                          sdl.GameControllerGetButton(controller, .BACK) > 0)

                // TODO: Make haptics platform independent
                b_button := new_controller.action_left.ended_down
                if b_button {
                    if rumble_handles[index] != nil {
                        sdl.HapticRumblePlay(rumble_handles[index], 0.5, 2000)
                    }
                }
            } else {
                // TODO: This controller is not plugged in
                new_controller.is_connected = false
            }
        }

        thread: g.Thread_Context

        frame_buffer := g.Frame_Buffer {
            global_back_buffer.memory,
            global_back_buffer.width,
            global_back_buffer.height,
            global_back_buffer.pitch,
            global_back_buffer.bytes_per_pixel,
        }

        if state.input_recording_index > 0 {
            record_input(&state, new_input)
        }

        if state.input_playing_index > 0 {
            play_back_input(&state, new_input)
        }

        if game.update_and_render != nil {
            game.update_and_render(&thread, &game_memory, new_input, &frame_buffer)
        }

        audio_wall_clock := sdl.GetPerformanceCounter()
        from_begin_to_audio_seconds := get_seconds_elapsed(flip_wall_clock, audio_wall_clock)

        {
            /* NOTE:

               Here is how sound output computation works.

               We define a safety value that is the number of samples we think our game
               update loop may vary by, say up to 2ms.

               When we wake up to write audio, we will look and see what the play cursor
               position is and we will forecast ahead where we think the play cursor will
               be on the next frame boundary.

               We will then look to see if the write cursor is before that by at least our
               safety value. If it is, the target fill position is that frame boundary plus
               one frame. This gives us perfect audio sync in the case of a card with low
               enough latency.

               If the write cursor is _after_ that safety margin, then we assume we can
               never sync audio perfectly, so we will write one frame's worth of audio plus
               the safety margin's worth of guard samples (1ms or whatever we think the
               variability of our frame computation is)
           */

            sdl.LockAudioDevice(audio_device_id)
            defer sdl.UnlockAudioDevice(audio_device_id)

            play_cursor := global_ring_buffer.play_cursor
            write_cursor := global_ring_buffer.write_cursor

            if !sound_is_valid  {
                sound_output.running_sample_index = u32(write_cursor / sound_output.bytes_per_sample)
                sound_is_valid = true
            }

            byte_to_lock :=
                (int(sound_output.running_sample_index) * sound_output.bytes_per_sample) %
                sound_output.buffer_size

            expected_sound_bytes_per_frame :=
                int(f32(sound_output.samples_per_second * sound_output.bytes_per_sample) /
                    game_update_hz)

            seconds_left_until_flip := target_seconds_per_frame - from_begin_to_audio_seconds
            expected_bytes_until_flip := u32((seconds_left_until_flip / target_seconds_per_frame) *
                f32(expected_sound_bytes_per_frame))

            expected_frame_boundary_byte := play_cursor + int(expected_bytes_until_flip)

            safe_write_cursor := write_cursor
            if safe_write_cursor < play_cursor {
                safe_write_cursor += sound_output.buffer_size
            }
            assert(safe_write_cursor >= play_cursor)
            safe_write_cursor += sound_output.safety_bytes

            low_latency := safe_write_cursor < expected_frame_boundary_byte

            target_cursor: int
            if low_latency {
                target_cursor = expected_frame_boundary_byte + expected_sound_bytes_per_frame
            } else {
                target_cursor = write_cursor + expected_sound_bytes_per_frame + sound_output.safety_bytes
            }
            target_cursor = target_cursor % sound_output.buffer_size

            bytes_to_write: int
            if byte_to_lock > target_cursor {
                bytes_to_write = sound_output.buffer_size - byte_to_lock
                bytes_to_write += target_cursor
            } else {
                bytes_to_write = target_cursor - byte_to_lock
            }

            sound_buffer := g.Sound_Output_Buffer {
                sound_output.samples_per_second,
                bytes_to_write / sound_output.bytes_per_sample,
                samples,
            }

            if game.get_sound_samples != nil {
                game.get_sound_samples(&thread, &game_memory, &sound_buffer)
            }

            when ODIN_DEBUG {
                marker := &debug_time_markers[debug_time_marker_index]
                marker.output_play_cursor = play_cursor
                marker.output_write_cursor = write_cursor
                marker.output_location = byte_to_lock
                marker.output_byte_count = bytes_to_write
                marker.expected_flip_play_cursor = expected_frame_boundary_byte
            }

            when ODIN_DEBUG {
                unwrapped_write_cursor := write_cursor

                if unwrapped_write_cursor < play_cursor {
                    unwrapped_write_cursor += sound_output.buffer_size
                }

                audio_latency_bytes := unwrapped_write_cursor - play_cursor
                audio_latency_seconds := (f32(audio_latency_bytes) / f32(sound_output.bytes_per_sample)) /
                                         f32(sound_output.samples_per_second)

                fmt.printfln("BTL: {0}, TC: {1}, BTW: {2} - PC: {3}, WC: {4}, DELTA: {5} ({6}s)",
                             byte_to_lock,
                             target_cursor,
                             bytes_to_write,
                             play_cursor,
                             write_cursor,
                             audio_latency_bytes,
                             audio_latency_seconds)
            }

            fill_sound_buffer(&sound_output, byte_to_lock, bytes_to_write, &sound_buffer)
        }

        // TODO: Not tested yet, probably buggy
        seconds_elapsed_for_frame := get_seconds_elapsed(last_counter, sdl.GetPerformanceCounter())
        if seconds_elapsed_for_frame < target_seconds_per_frame {
            // NOTE: sdl.Delay() sleeps too long on macos and pops the assert, so feed it two fewer milliseconds
            duration := (1000 * (target_seconds_per_frame - seconds_elapsed_for_frame)) - 2

            if duration > 0 {
                sdl.Delay(u32(duration))
            }

            test_seconds_elapsed_for_frame := get_seconds_elapsed(last_counter, sdl.GetPerformanceCounter())

            if test_seconds_elapsed_for_frame < target_seconds_per_frame {
                // TODO: Log missed sleep here
            }

            for seconds_elapsed_for_frame < target_seconds_per_frame {
                // Wait to hit target seconds per frame
                seconds_elapsed_for_frame = get_seconds_elapsed(last_counter, sdl.GetPerformanceCounter())
            }
        } else {
            // TODO: Missed frame rate
            // TODO: Logging
        }

        end_counter := sdl.GetPerformanceCounter()

        when ODIN_DEBUG {
            current_marker: ^Debug_Time_Marker
            if debug_time_marker_index > 0 {
                current_marker = &debug_time_markers[debug_time_marker_index - 1]
            } else {
                current_marker = &debug_time_markers[len(debug_time_markers) - 1]
            }

            debug_sync_display(&global_back_buffer,
                               debug_time_markers,
                               current_marker,
                               &sound_output,
                               target_seconds_per_frame)
        }

        update_window(window, renderer, &global_back_buffer)

        flip_wall_clock = sdl.GetPerformanceCounter()

        when ODIN_DEBUG {
            sdl.LockAudioDevice(audio_device_id)
            defer sdl.UnlockAudioDevice(audio_device_id)

            assert(debug_time_marker_index < len(debug_time_markers))

            marker := &debug_time_markers[debug_time_marker_index]

            debug_time_marker_index += 1

            if debug_time_marker_index == len(debug_time_markers) {
                debug_time_marker_index = 0
            }

            marker.flip_play_cursor = global_ring_buffer.play_cursor
            marker.flip_write_cursor = global_ring_buffer.write_cursor
        }

        temp := new_input
        new_input = old_input
        old_input = temp

        end_cycle_count := intrinsics.read_cycle_counter()

        when ODIN_DEBUG {
            ms_per_frame := 1000 * get_seconds_elapsed(last_counter, end_counter)

            counter_elapsed := end_counter - last_counter
            fps := f32(global_perf_count_frequency) / f32(counter_elapsed)

            cycles_elapsed := end_cycle_count - last_cycle_count
            mcpf := f32(cycles_elapsed) / (1000 * 1000)

            fmt.printfln("ms/frame: %.2fms, %.2f fps, %.2fmc/f", ms_per_frame, fps, mcpf)
        }

        last_cycle_count = end_cycle_count
        last_counter = end_counter
    }
}
