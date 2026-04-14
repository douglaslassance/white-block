# White Block

An [Aseprite](https://www.aseprite.org/) extension design to facilitate workflows for game development.

## Installation

Run `install.sh` from the project root. It symlinks the extension files into the Aseprite extensions folder. Alternatively, copy `plugin.lua` and `package.json` directly into your Aseprite extensions folder.

## Usage

1. Open Aseprite.
2. Go to **File → Scripts → White Block**

## Features

### Layout export

- Exports visible layers as individually trimmed PNG files
- Generates a JSON layout manifest with canvas-space positions for each layer
- **Hierarchy mode**: Nests child positions relative to their parent group's center
- **Instance layers** (`-instance`): Deduplicates shared images across multiple occurrences
- **Directional instances** (`-left-instance` / `-right-instance`): Shares one PNG and records a mirror transform
- **Text layers** (`-text`): Produces position-only manifest entries with no image export
- **Mask layers** (`-mask`): Exports at fixed canvas size instead of trimmed bounds
- **Preview layers** (`-preview`): Skipped entirely during export
- **Animation support**: Duplicate-frame detection and image table filename generation
- **Configurable settings**: Padding, filename prefix, separator character, and frame range
- Persists export settings between sessions