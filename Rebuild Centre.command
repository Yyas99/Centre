#!/bin/bash
# Double-click this in Finder to recompile and relaunch Centre. The build script saves its output to build.log.
cd "$(dirname "$0")" && chmod +x centre && ./centre build
