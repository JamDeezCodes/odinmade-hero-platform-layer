# Odinmade Hero Platform Layer

A platform layer inspired by Casey Muratori's [Handmade Hero series](https://www.youtube.com/watch?v=Ee3EtYb8d1o), written in the Odin programming language.

You may use this repo to quickly start making games the "Handmade" way with sound output, hot code reloading, and gameplay input/state recording/playback all working out of the box.

### Setup

Install the [Odin](https://odin-lang.org/docs/install/) programming language.

This project uses Odin's [vendored SDL2 package](https://pkg.odin-lang.org/vendor/sdl2/) and the implementation follows [Handmade Penguin](https://davidgow.net/handmadepenguin/default.html).

### Build and Run Odinmade Hero

Execute the build script and run the executable on Windows:
```cmd
.\build.bat & .\build\odinmade.exe
```

Execute the build script and run the executable on Darwin:
```bash
sh build.sh && build/odinmade.bin
```

### Hot Code Reloading

Using this project as a template for your own game lets you change code in the `game` package and hot reload it while the game is running by simply recompiling the game code as
a shared library, bearing in mind that if you change the layout of the game's state, you can only add new members to the end of the `game.State` struct, otherwise, you'll probably
have to restart the executable. Hot reloading likely won't work if, for example, you need to modify any of the platform code to change how input to the game is processed or how the
memory you're passing to the game code is laid out. Generally, hot reloading will be useful for changing things that are specific to your game's logic on the fly, not for how your
game interfaces with the operating system.

To hot reload, build and run the `main` package, then open up `game.odin` in the `game` package. Down in the `game_update_and_render` proc, modify the call to draw a rectangle
so that instead of rendering a hideous purple, we render a pretty cyan instead:
```diff
// NOTE: Fill the frame buffer with "hideous" purple
draw_rectangle(frame_buffer,
               0, 0,
               f32(frame_buffer.width),
               f32(frame_buffer.height),
-              0x00FF00FF)
+              0x0000FFFF)
```

Rebuild the game with the corresponding `build_game` script for your OS, and watch the frame buffer change instantaneously from being filled with hideous purple to pretty cyan!

### Game Input/State Recording/Playback

To record and play back game input and game state, simply start the game and hit "L" on your keyboard. Record some gameplay and hit "L" again to start playing back the input
and state you recorded. Hit "L" a final time to cease playback.

### TODO
* Linux build instructions/scripts

