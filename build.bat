@echo off

if not exist build\ mkdir build\

goto :build
-vet includes the following flags:
     -vet-unused
     -vet-unused-variables
     -vet-unused-imports
     -vet-shadowing
     -vet-using-stmt
:build

set BUILD_FLAGS=-vet -vet-using-param -vet-shadowing -vet-cast -strict-style -debug
odin build game -build-mode:dll -out:build\game.dll %BUILD_FLAGS% >nul 2>&1
odin build main -out:build\odinmade.exe %BUILD_FLAGS%

