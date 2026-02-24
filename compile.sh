#!/bin/bash

if [ ! -f "$1.m" ]; then
	echo "$1.m does not exist"
	exit 1
fi

set -e

mkdir -p build 

clang -dynamiclib -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) -I fishhook  -framework CoreAudio -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework AudioToolbox -framework UIKit -framework Foundation -o build/$1.dylib $1.m fishhook/fishhook.c
