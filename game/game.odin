package game

import "core:math"

MAX_CONTROLLERS :: 5
MAX_BUTTONS :: 12

kilobytes :: proc(value: $T) -> T {
    return value * 1024
}

megabytes :: proc(value: $T) -> T {
    return kilobytes(value) * 1024
}

gigabytes :: proc(value: $T) -> T {
    return megabytes(value) * 1024
}

terabytes :: proc(value: $T) -> T {
    return gigabytes(value) * 1024
}

/*
   NOTE: Services that the game provides to the platform layer
   (this may expand in the future - sound on separate thread, etc.)

   Game needs FOUR things:
   - Timing
   - Keyboard/controller input
   - Bitmap buffer to use
   - Sound buffer to use
*/

Game_Update_And_Render :: #type proc(^Thread_Context, ^Memory, ^Input, ^Frame_Buffer)
Game_Get_Sound_Samples :: #type proc(^Thread_Context, ^Memory, ^Sound_Output_Buffer)

Frame_Buffer :: struct {
    // NOTE: Pixels are always 32 bits wide, memory order BB GG RR XX
    memory: []byte,
    width, height, pitch,
    bytes_per_pixel: int,
}

Sound_Output_Buffer :: struct {
    samples_per_second, sample_count: int,
    samples: []i16,
}

Button_State :: struct {
    half_transition_count: int,
    ended_down: bool,
}

Controller_Input :: struct {
    is_connected, is_analog: bool,
    stick_average_x, stick_average_y: f32,
    using _: struct #raw_union {
        buttons: [MAX_BUTTONS]Button_State,
        using _: struct {
            move_up: Button_State,
            move_down: Button_State,
            move_left: Button_State,
            move_right: Button_State,
            action_up: Button_State,
            action_down: Button_State,
            action_left: Button_State,
            action_right: Button_State,
            left_shoulder: Button_State,
            right_shoulder: Button_State,
            start: Button_State,
            // NOTE: The back button is our "terminator" button,
            // do not add more buttons below it
            back: Button_State,
        },
    },
}

Input :: struct {
    mouse_buttons: [5]Button_State,
    mouse_x, mouse_y, mouse_z: int,
    seconds_to_advance_over_update: f32,
    controllers: [MAX_CONTROLLERS]Controller_Input,
}

State :: struct {
    t_sine: f32,
}

Memory :: struct {
    is_initialized: bool,
    permanent_storage_size,
    transient_storage_size: u64,
    permanent_storage,
    transient_storage: []byte,
}

Thread_Context :: struct {
    placeholder: int,
}

output_sound :: proc (game_state: ^State, sound_buffer: ^Sound_Output_Buffer, tone_hz: int) {
    tone_volume := 3000
    wave_period := sound_buffer.samples_per_second / tone_hz

    samples := sound_buffer.samples
    for i in 0..<sound_buffer.sample_count {
        sample_value: i16
        sine_value := math.sin(game_state.t_sine)
        sample_value = i16(sine_value * f32(tone_volume))

        samples[i * 2] = sample_value
        samples[i * 2 + 1] = sample_value

        game_state.t_sine += 2 * math.PI * 1 / f32(wave_period)

        if game_state.t_sine > 2 * math.PI {
            game_state.t_sine -= 2 * math.PI
        }
    }
}

draw_rectangle :: proc(buffer: ^Frame_Buffer,
                       f_min_x, f_min_y,
                       f_max_x, f_max_y: f32,
                       color: u32) {
    min_x := int(math.round(f_min_x))
    min_y := int(math.round(f_min_y))
    max_x := int(math.round(f_max_x))
    max_y := int(math.round(f_max_y))

    if min_x < 0 { min_x = 0 }
    if min_y < 0 { min_y = 0 }
    if max_x > buffer.width { max_x = buffer.width }
    if max_y > buffer.height { max_y = buffer.height }

    offset := min_x * buffer.bytes_per_pixel + min_y * buffer.pitch
    pixels := transmute([]u32)(buffer.memory[offset:])
    for _, y in min_y..<max_y {
        for _, x in min_x..<max_x{
            pixels[y * buffer.width + x] = color
        }
    }
}

@(export)
game_update_and_render :: proc(thread: ^Thread_Context, memory: ^Memory, input: ^Input, frame_buffer: ^Frame_Buffer) {
    assert(&input.controllers[0].buttons[MAX_BUTTONS - 1] == &input.controllers[0].back)
    assert(size_of(State) <= memory.permanent_storage_size)

    game_state := (^State)(raw_data(memory.permanent_storage))
    // NOTE: Start doing something interesting with the game state!
    _ = game_state

    if !memory.is_initialized {
        memory.is_initialized = true
    }

    for controller in input.controllers {
        if controller.is_connected {
            if controller.is_analog {
                // NOTE: Use analog movement tuning
            } else {
                // NOTE: Use digital movement tuning
            }
        }
    }

    // NOTE: Fill the frame buffer with "hideous" purple
    draw_rectangle(frame_buffer,
                   0, 0,
                   f32(frame_buffer.width),
                   f32(frame_buffer.height),
                   0x00FF00FF)
}

// NOTE: This proc cannot take longer than 1ms or so
@(export)
game_get_sound_samples :: proc(thread: ^Thread_Context, memory: ^Memory, sound_buffer: ^Sound_Output_Buffer) {
    game_state := (^State)(raw_data(memory.permanent_storage))

    output_sound(game_state, sound_buffer, 262)
}
