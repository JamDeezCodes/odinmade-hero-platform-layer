#!/bin/bash

mkdir -p build
# -vet includes the following flags:
#      -vet-unused
#      -vet-unused-variables
#      -vet-unused-imports
#      -vet-shadowing
#      -vet-using-stmt
BUILD_FLAGS="-vet -vet-using-param -vet-shadowing -vet-cast -strict-style -debug"
odin build game -build-mode:dll -out:build/game.dylib $BUILD_FLAGS
odin build main -out:build/odinmade.bin $BUILD_FLAGS
