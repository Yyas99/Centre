#!/bin/bash
# Double-click this in Finder to recompile and relaunch Centre. Output is also saved to build.log.
cd "$(dirname "$0")" && chmod +x centre && ./centre build 2>&1 | tee build.log
