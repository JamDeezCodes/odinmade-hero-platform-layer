#!/bin/bash

mkdir -p build
BUILD_FLAGS="-vet -vet-using-param -vet-shadowing -vet-cast -strict-style -debug"
odin build game -build-mode:dll -out:build/game.dylib $BUILD_FLAGS
