@echo off

if not exist build\ mkdir build\

set BUILD_FLAGS=-vet -vet-using-param -vet-shadowing -vet-cast -strict-style -debug
odin build game -build-mode:dll -out:build\game.dll %BUILD_FLAGS% >nul 2>&1
