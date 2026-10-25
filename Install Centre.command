#!/bin/bash
# Double-click in Finder: build Centre from this folder and install it in /Applications. Output also goes to build.log.
cd "$(dirname "$0")" && chmod +x centre && ./centre install
