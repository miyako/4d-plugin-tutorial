# 4D Plugin Development Guide

A comprehensive reference for building a 4D plugin from scratch in C/C++. This document captures the full workflow, conventions, caveats, and tips needed to create, build, test, and ship a 4D plugin on macOS and Windows.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Project Setup](#project-setup)
3. [SDK Integration](#sdk-integration)
4. [Plugin Entry Points](#plugin-entry-points)
5. [manifest.json — Command Definitions](#manifestjson--command-definitions)
6. [constants.xlf — Constant Definitions](#constantsxlf--constant-definitions)
7. [C/C++ Implementation](#cc-implementation)
8. [Xcode Project (macOS)](#xcode-project-macos)
9. [Visual Studio Project (Windows)](#visual-studio-project-windows)
10. [4D Test Project](#4d-test-project)
11. [Automated Testing with tool4d](#automated-testing-with-tool4d)
12. [GitHub Actions CI/CD](#github-actions-cicd)
13. [GitHub Actions — Release Workflow](#github-actions--release-workflow)
14. [README Template](#readme-template)
15. [Common Pitfalls](#common-pitfalls)
16. [Step-by-Step Checklist](#step-by-step-checklist)

---

## Architecture Overview

A 4D plugin is a native dynamic library loaded by the 4D runtime at startup:

| Platform | File Type | Extension | Loader |
|---|---|---|---|
| macOS | Bundle (`.bundle`) | None | `dlopen` |
| Windows | DLL | `.4DX` | `LoadLibrary` |

### Execution Flow

```
4D starts
  → scans Plugins folder
  → loads library (dlopen / LoadLibrary)
  → finds exported symbol `FourDPackex`
  → calls FourDPackex(callback_address)
  → plugin stores callback in global `gCall4D`
  → 4D calls `PluginMain(selector, params)` for each:
      - Plugin command call (selector = command index, 1-based)
      - Plugin area event (eAE_Idle to eAE_DesignInit)
      - Plugin event (kNotifyDemoPlugins to kInitPlugin)
```

### Key Rules

- The plugin may **only** call SDK entry points during a `PluginMain` cycle.
- It may **not** call the runtime from a different thread or unrelated execution cycle.
- Exception: some functions like `PA_FreezeProcess` / `PA_UnfreezeProcess` that do require a language context.
- For system calls that require the main thread, use `PA_RunInMainProcess`.
- 4D data types are **opaque structures** — always convert to/from C types via SDK utilities.

---

## Project Setup

### Repository Structure

```
project-root/
├── .github/
│   └── workflows/
│       ├── test.yml              # CI test workflow (tag + manual)
│       ├── bump-version.yml      # Version bump + tag push
│       └── release.yml           # Build, sign, notarize & release
├── .gitignore
├── 4D-Plugin-SDK/                # Git submodule
├── VERSION                       # Semantic version file (e.g. "1.0.0")
├── README.md
└── {plugin-name}/                # e.g., "example/"
    ├── CMakeLists.txt            # Cross-platform build (CMake)
    ├── {name}-4dplugin.cpp       # Plugin implementation
    ├── {name}-4dplugin.h         # Plugin header
    ├── manifest.json             # Command definitions
    ├── constants.xlf             # Constant definitions
    └── {name}-test/              # 4D test project
        ├── Plugins/              # Built plugin output (gitignored)
        ├── Project/
        │   ├── {name}.4DProject
        │   └── Sources/
        │       ├── Methods/
        │       │   ├── test_all.4dm
        │       │   └── test_{command}.4dm
        │       └── folders.json
        ├── Resources/
        └── Settings/
```

### VERSION File

Create a `VERSION` file in the project root containing the semantic version:

```
1.0.0
```

This file is the single source of truth for the version number, used by `bump-version.yml` to tag releases.

### .gitignore

```
{name}/{name}-test/Data/*
{name}/{name}-test/Project/DerivedData/*
{name}/{name}-test/userPreferences.*
{name}/{name}-test/Plugins/
{name}/cmake-build/
{name}/build/
**/xcuserdata/
*.vcxproj.user
.DS_Store
```

---

## SDK Integration

### Add as Git Submodule

```bash
git submodule add https://github.com/4d/4D-Plugin-SDK.git 4D-Plugin-SDK
```

Using a submodule (not a plain clone) because:
- Pins to a specific SDK commit for reproducible builds
- Keeps the repo lightweight (no duplicated history)
- Easy updates via `git submodule update --remote`
- Anyone cloning gets the SDK with `--recurse-submodules`

### Key SDK Files

Located in `4D-Plugin-SDK/4D Plugin API/`:

| File | Purpose |
|---|---|
| `4DPluginAPI.h` | SDK function declarations |
| `4DPluginAPI.c` | SDK function implementations (must be compiled into plugin) |
| `4DPluginAPI.def` | Windows module definition file (exports `FourDPackex`) |
| `EntryPoints.h` | Runtime callback function declarations |
| `PublicTypes.h` | Public types, area events, plugin events |
| `PrivateTypes.h` | Internal types |
| `Flags.h` | Feature flags |

### Critical: `4DPluginAPI.c` Must Be Compiled

The SDK source file `4DPluginAPI.c` **must** be compiled and linked into the plugin. It contains:
- The `FourDPackex` entry point (the symbol 4D searches for at load time)
- The `gCall4D` global (callback table populated by 4D)
- All SDK wrapper functions

Without it, the plugin will not be recognized by 4D.

---

## Plugin Entry Points

### `FourDPackex` (exported symbol)

- The **sole exported symbol** from the plugin DLL/bundle.
- Called **once** when 4D loads the plugin.
- Receives the callback address to the 4D runtime.
- Defined in `4DPluginAPI.c` and exported via `4DPluginAPI.def` (Windows) or dynamic symbol visibility (macOS).

### `PluginMain(selector, params)`

- The dispatcher function called by 4D for each interaction.
- `selector` is the 1-based command index from `manifest.json`.
- The developer implements a `switch` on `selector` to route to command functions.

```c
void PluginMain(PA_long32 selector, PA_PluginParameters params) {
    switch(selector) {
        case 1:
            my_first_command(params);
            break;
        case 2:
            my_second_command(params);
            break;
    }
}
```

### Historical Note

In earlier versions, `FourdPack` (without `Ex`) was the entry point for ANSI string mode. Modern 4D is fully unicode — always use `FourDPackex`.

---

## manifest.json — Command Definitions

```json
{
    "name": "{plugin-name}",
    "id": 20000,
    "commands": [
        {
            "theme": "{group-name}",
            "syntax": "{command_name}(&T;&L):T",
            "threadSafe": true
        }
    ]
}
```

### Fields

| Field | Description |
|---|---|
| `name` | Plugin identity. Must be unique across all installed plugins. If duplicates exist, none load. |
| `id` | 15001–32767 (below 15000 is reserved by 4D). Legacy field, not functionally important. |
| `theme` | Groups commands in the 4D IDE (design mode). |
| `threadSafe` | Developer's guarantee that the code is thread-safe. Enables use in preemptive 4D processes. A `threadSafe:false` command used in a preemptive process causes a runtime/compiler error. |

### Syntax Tokens

The syntax string describes expected parameter types by position and optionally a return value.

Format: `command_name({params}):{return_type}`
- Arguments separated by semicolons: `&T;&L;&R`
- Return type after closing parenthesis: `):T`
- Maximum 25 arguments

| Token | 4D Type | SDK Getter | SDK Setter |
|---|---|---|---|
| `&T` | Text | `PA_GetStringParameter` | `PA_ReturnString` |
| `&L` | Longint | `PA_GetLongParameter` | `PA_ReturnLong` |
| `&R` | Real | `PA_GetDoubleParameter` | `PA_ReturnDouble` |
| `&D` | Date | `PA_GetDateParameter` | `PA_ReturnDate` |
| `&H` | Time | `PA_GetTimeParameter` | `PA_ReturnTime` |
| `&I` | Integer | `PA_GetShortParameter` | `PA_ReturnShort` |
| `&O` | BLOB | `PA_GetBlobParameter` | `PA_ReturnBlob` |
| `&P` | Picture | `PA_GetPictureParameter` | `PA_ReturnPicture` |
| `&Y` | Array | `PA_GetVariableParameter` | — |
| `&J` | Object | `PA_GetObjectParameter` | `PA_ReturnObject` |
| `&C` | Collection | `PA_GetCollectionParameter` | `PA_ReturnCollection` |
| `&Z` | Pointer | `PA_GetPointerParameter` | — |
| `&8` | Double (deprecated) | — | — |
| `&S` | String (deprecated) | — | — |
| `&U` | UTXT (deprecated) | — | — |

### Command Order Matters

The order of commands in the `commands` array determines the `selector` number passed to `PluginMain`:
- First command → selector 1
- Second command → selector 2
- etc.

### Naming Rules (shared with constants)

- Up to 31 ANSI characters
- Case insensitive
- Must not start with a number
- May contain spaces between words (but discouraged)
- May not contain operators
- Must not clash with 4D reserved identifiers (command names, built-in constants)

### Omitted Parameters

When a 4D caller omits a trailing parameter, the plugin receives the **default value for that type** (0 for Longint, empty string for Text, etc.). This allows optional parameters without special syntax.

---

## constants.xlf — Constant Definitions

```xml
<?xml version="1.0" encoding="UTF-8" standalone="no" ?>
<xliff version="1.0" xmlns:d4="http://www.4d.com/d4-ns">
<header>
    <note>{plugin-name}</note>
</header>
<group resname="themes">
    <trans-unit id="{theme-id}" resname="{theme-id}" translate="no">
        <source>{Theme Display Name}</source>
    </trans-unit>
</group>
<group restype="x-4DK#" d4:groupName="{theme-id}">
    <trans-unit d4:value="{value}" id="{constant-id}">
        <source>{constant_name}</source>
    </trans-unit>
</group>
</xliff>
```

### Value Types

- Numeric values are inferred if no suffix
- Explicit type suffixes: `:L` (Longint), `:R` (Real), `:S` (Text)
- Example: `"42:S"` is the text string "42", not the number 42

### Order Matters

The order of constants determines their internal token code (similar to commands).

---

## C/C++ Implementation

### Header File Pattern

```c
#ifndef {NAME}_4DPLUGIN_H
#define {NAME}_4DPLUGIN_H

#include "4DPluginAPI.h"
#include <time.h>
#include <string.h>

static void {command_name}(PA_PluginParameters params);

#endif
```

### Implementation Pattern

```c
#include "{name}-4dplugin.h"

void PluginMain(PA_long32 selector, PA_PluginParameters params) {
    switch(selector) {
        case 1:
            {command_name}(params);
            break;
    }
}

static void {command_name}(PA_PluginParameters params) {
    // Get parameters (1-indexed)
    PA_Unistring *textParam = PA_GetStringParameter(params, 1);
    PA_long32 longParam = PA_GetLongParameter(params, 2);

    // Access string data
    PA_Unichar *chars = PA_GetUnistring(textParam);
    PA_long32 len = PA_GetUnistringLength(textParam);
    // Note: textParam is owned by the runtime — do NOT dispose it

    // Build result (PA_Unichar = unsigned short = UTF-16)
    PA_Unichar result[1024];
    // ... populate result ...
    result[resultLen] = 0; // null-terminate

    // Return value
    PA_ReturnString(params, result);
}
```

### String Handling

- `PA_Unichar` is `unsigned short` (16-bit, UTF-16).
- On macOS, `wchar_t` is 32-bit, so you **cannot** use `L"string"` literals for `PA_Unichar`.
- For ASCII prefixes, widen manually: `result[i] = (PA_Unichar)ascii_char;`
- `PA_GetStringParameter` returns a runtime-owned pointer — do **not** call `PA_DisposeUnistring` on it.
- For dynamically created strings, use `PA_CreateUnistring` and `PA_DisposeUnistring`.

### Platform-Specific Code

Use `#ifdef _WIN32` for Windows-specific code:

```c
// Example: localtime_s (Windows) vs localtime (POSIX)
#ifdef _WIN32
    localtime_s(&local, &now);
#else
    local = *localtime(&now);
#endif
```

MSVC treats many standard C functions as deprecated (`localtime`, `strcpy`, etc.). Use the `_s` variants on Windows to avoid build errors.

---

## Xcode Project (macOS)

### Project Type

- **Product type**: `com.apple.product-type.bundle` (creates a `.bundle`)
- **Wrapper extension**: `bundle`

### Source Files

1. `{name}-4dplugin.cpp` — added to **Sources** build phase
2. `4DPluginAPI.c` from SDK — via **PBXFileSystemSynchronizedRootGroup**
   - Must set `explicitFileTypes` to compile `.c` as C++: `4DPluginAPI.c = sourcecode.cpp.cpp`
   - **Critical**: must add `fileSystemSynchronizedGroups` to the native target, otherwise the SDK source won't compile

### Frameworks

- **CoreGraphics.framework** must be linked (SDK uses `CGContextScaleCTM` and `CGContextTranslateCTM` in QuickDraw/Quartz axis functions)

### Resource Files

- `manifest.json` and `constants.xlf` go in the **Copy Bundle Resources** build phase
- They end up in `{name}.bundle/Contents/Resources/`

### Build Configuration (xcconfig)

Debug xcconfig:
```
CONFIGURATION_BUILD_DIR = $(PROJECT_DIR)/$(PROJECT_NAME)-test/Plugins
```

Release xcconfig (same for testing purposes):
```
CONFIGURATION_BUILD_DIR = $(PROJECT_DIR)/$(PROJECT_NAME)-test/Plugins
```

Set `baseConfigurationReference` on the respective `XCBuildConfiguration` to point to each xcconfig file.

### Code Signing for CI

In CI (GitHub Actions), disable code signing:
```
xcodebuild ... CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

### Verifying the Build

Check exported symbols with `nm`:
```bash
nm -g path/to/example.bundle/Contents/MacOS/example
```

Expected symbols:
- `_FourDPackex` — entry point
- `_PluginMain` — command dispatcher
- `_gCall4D` — callback table

If `_gCall4D` and `_FourDPackex` are missing, `4DPluginAPI.c` is not being compiled/linked.

---

## Visual Studio Project (Windows)

### Project Type

- **ConfigurationType**: `DynamicLibrary` (only for x64; Win32 and ARM64 are `Application` placeholders)
- **Target extension**: `.4DX`

### Compiler Settings (x64)

- **Character set**: Unicode
- **Runtime library**: `/MTd` (Debug), `/MT` (Release) — static CRT
- **Include path**: `$(SolutionDir)..\4D-Plugin-SDK\4D Plugin API`
- **Conformance mode**: true

### Linker Settings (x64)

- **Module definition file**: `$(SolutionDir)..\4D-Plugin-SDK\4D Plugin API\4DPluginAPI.def`
  - This exports `FourDPackex` without needing `__declspec(dllexport)` in source code

### Output Path

```xml
<OutDir>$(SolutionDir)$(ProjectName)-test\Plugins\$(ProjectName)\Contents\Windows64</OutDir>
```

Set for both Debug|x64 and Release|x64.

### Post-Build Event (resource copy)

```xml
<PostBuildEvent>
  <Command>xcopy /Y "$(ProjectDir)manifest.json" "$(OutDir)..\Resources\"
xcopy /Y "$(ProjectDir)constants.xlf" "$(OutDir)..\Resources\"</Command>
</PostBuildEvent>
```

### Plugin Folder Structure (Windows)

```
Plugins/
  {plugin-name}/
    Contents/
      Windows64/
        {plugin-name}.4DX
      Resources/
        manifest.json
        constants.xlf
```

---

## 4D Test Project

### Structure

```
{name}-test/
├── Project/
│   ├── {name}.4DProject          # Project anchor file
│   └── Sources/
│       ├── Methods/
│       │   ├── test_all.4dm      # Test runner for CI
│       │   └── test_{cmd}.4dm    # Individual test methods
│       └── folders.json          # Virtual explorer folders
├── Plugins/                      # Built plugin output
├── Resources/
└── Settings/
```

### .4DProject File

```json
{
    "$comment": "The project file serves as an anchor to locate other project files",
    "compatibilityVersion": 2101
}
```

Version encoding:
- `2101` → 4D v21.1
- `2120` → 4D v21 R2
- `21A0` → 4D v21 R10

### Test Methods

#### Individual test (`test_{command}.4dm`)

```4d
//%attributes = {"invisible":true,"preemptive":"capable"}

// Test explicit behavior
ASSERT(my_command("input"; my_constant_a)="expected output")

// Test edge cases
ASSERT(my_command(""; my_constant_a)="expected for empty")
ASSERT(my_command("日本語"; my_constant_a)="expected for unicode")

/*
    Test dynamic/conditional behavior.
    Use block comments for multi-line explanations.
*/
var $var : Type
// ... conditional test logic ...
```

Key points:
- `//%attributes` is a JSON comment for method metadata
- `"preemptive":"capable"` must match `threadSafe: true` in manifest
- `"invisible":true` hides the method from end users
- `ASSERT` prompts a dialog on failure; in headless mode, this aborts the process
- The IDE auto-adds command token suffixes (e.g., `ASSERT:C1129`) — do not add them manually when editing `.4dm` files
- Use `//` for line comments, `/* */` for block comments
- 4D time literals: `?03:00:00?`
- 4D conditional: `Case of / : (condition) / Else / End case`

#### Test runner (`test_all.4dm`)

```4d
//%attributes = {"invisible":true}
If (Application info.headless)

    test_{command1}
    test_{command2}

    LOG EVENT(Into system standard outputs; "PASS"; Information message)

End if
```

**Note on command token suffixes**: You may see suffixes like `:C1129` after command names (e.g., `ASSERT:C1129`) in `.4dm` files. These are added automatically by the 4D IDE to disambiguate between English and French command names. **You do not need to add them yourself** — tool4d is fixed to English coding and resolves plain command names without suffixes. When generating `.4dm` files programmatically, just use the plain English names (e.g., `ASSERT`, `LOG EVENT`, `Current time`).

- Guards with `Application info.headless` — only runs in CLI mode (tool4d)
- Calls all individual test methods
- Outputs "PASS" to stdout on success
- If any `ASSERT` fails in headless mode: dialog → auto-abort → process exits with non-zero code → "PASS" is never printed

#### Virtual Explorer Folders (`folders.json`)

```json
{
    "Tests": {
        "methods": [
            "test_all",
            "test_{command}"
        ]
    },
    "trash": {}
}
```

---

## 4D Test Project Boilerplate

When creating a 4D test project from scratch (without the 4D IDE), the following files are required. Replace `{name}` with the plugin name throughout.

### Directory Structure

```
{name}-test/
├── Project/
│   ├── {name}.4DProject
│   └── Sources/
│       ├── Methods/
│       │   ├── test_all.4dm
│       │   └── test_{command}.4dm
│       ├── catalog.4DCatalog
│       ├── catalog_editor.json
│       ├── folders.json
│       ├── menus.json
│       ├── roles.json
│       └── settings.4DSettings
├── Resources/
└── Settings/
    └── backup.4DSettings
```

### File Templates

#### `{name}.4DProject`

```json
{
    "$comment": "The project file serves as an anchor to locate other project files",
    "compatibilityVersion": 2101
}
```

Set `compatibilityVersion` to match your target 4D version. See [version encoding](#automated-testing-with-tool4d).

#### `catalog.4DCatalog`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE base SYSTEM "http://www.4d.com/dtd/2007/base.dtd" >
<base name="{name}" uuid="{GENERATE-A-UUID}" collation_locale="en-gb">
    <schema name="DEFAULT_SCHEMA"/>
    <base_extra>
        <journal_file journal_file_enabled="false"/>
    </base_extra>
</base>
```

Generate a unique UUID (32 hex characters, uppercase) for each project.

#### `catalog_editor.json`

```json
{
    "tables": {}
}
```

#### `folders.json`

```json
{
    "Tests": {
        "methods": [
            "test_all",
            "test_{command}"
        ]
    },
    "trash": {}
}
```

#### `menus.json`

```json
{
    "bars": [
        {
            "id": 1,
            "name": "Menu Bar",
            "items": [
                {"link": 32001},
                {"link": 32002}
            ]
        }
    ],
    "menus": [
        {
            "link": 32001,
            "title": ":xliff:CommonMenuFile",
            "items": [
                {
                    "title": ":xliff:CommonMenuItemQuit",
                    "shortcutAccel": true,
                    "shortcutKey": "Q",
                    "action": "quit"
                }
            ]
        },
        {
            "link": 32002,
            "title": ":xliff:CommonMenuEdit",
            "items": [
                {
                    "title": ":xliff:CommonMenuItemUndo",
                    "shortcutAccel": true,
                    "shortcutKey": "Z",
                    "action": "undo"
                },
                {"title": "(-", "isSeparator": true},
                {
                    "title": ":xliff:CommonMenuItemCut",
                    "shortcutAccel": true,
                    "shortcutKey": "X",
                    "action": "cut"
                },
                {
                    "title": ":xliff:CommonMenuItemCopy",
                    "shortcutAccel": true,
                    "shortcutKey": "C",
                    "action": "copy"
                },
                {
                    "title": ":xliff:CommonMenuItemPaste",
                    "shortcutAccel": true,
                    "shortcutKey": "V",
                    "action": "paste"
                },
                {
                    "title": ":xliff:CommonMenuItemSelectAll",
                    "shortcutAccel": true,
                    "shortcutKey": "A",
                    "action": "selectAll"
                }
            ]
        }
    ]
}
```

#### `roles.json`

```json
{
    "forceLogin": false,
    "restrictedByDefault": false,
    "privileges": [],
    "roles": [],
    "permissions": {
        "allowed": [
            {
                "applyTo": "ds",
                "type": "datastore",
                "read": [],
                "create": [],
                "update": [],
                "drop": [],
                "execute": [],
                "promote": []
            }
        ]
    }
}
```

#### `settings.4DSettings`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<preferences stamp="2">
    <com.4d>
        <compiler>
            <options target="all"/>
        </compiler>
    </com.4d>
</preferences>
```

#### `backup.4DSettings`

```xml
<?xml version="1.0" encoding="UTF-8" standalone="no" ?>
<Preferences4D xmlns="http://www.4d.com/namespace/reserved/2004/backup">
  <Backup>
    <Settings>
      <Scheduler>
        <Frequency>Never</Frequency>
      </Scheduler>
    </Settings>
  </Backup>
</Preferences4D>
```

---

## Automated Testing with tool4d

### What is tool4d?

- A CLI version of 4D designed for CI/CD
- **No license activation required**
- Must match the `compatibilityVersion` of the test project

### Running Tests

```bash
/path/to/tool4d --dataless --startup-method=test_all --project=/path/to/{name}.4DProject
```

| Flag | Description |
|---|---|
| `--dataless` | No data file (empty data path). Suitable for tests that don't need records. |
| `--startup-method` | 4D method to execute at startup |
| `--project` | Path to the `.4DProject` file |

### Exit Behavior

- **PASS**: stdout contains "PASS", exit code 0
- **FAIL**: ASSERT triggers a dialog → headless auto-abort → non-zero exit code, no "PASS" output

### Download URLs

```
https://resources-download.4d.com/release/{branch}/{version}/latest/{platform}/tool4d_{suffix}.tar.xz
```

| Parameter | Examples |
|---|---|
| branch | `21.x`, `20.x` |
| version | `21.1`, `21 R2` |
| platform | `win`, `mac` |
| suffix | `win`, `x86_64`, `arm64` |

No authentication required for download.

---

## GitHub Actions CI/CD

### `test.yml` — Build & Test (CMake)

This workflow builds the plugin using CMake on both platforms and runs tests with tool4d. Triggered on tag push or manual dispatch.

```yaml
name: Build and Test

on:
  push:
    tags:
      - '*'
  workflow_dispatch:

jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        include:
          - os: macos-latest
            platform: mac
            tool4d_archive: tool4d_arm64.tar.xz
          - os: windows-latest
            platform: win
            tool4d_archive: tool4d_win.tar.xz

    runs-on: ${{ matrix.os }}

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Parse 4D version from .4DProject
        id: version
        shell: bash
        run: |
          compat=$(cat {name}/{name}-test/Project/{name}.4DProject | python3 -c "
          import sys, json
          data = json.load(sys.stdin)
          print(data['compatibilityVersion'])
          ")
          major=${compat:0:2}
          minor_raw=${compat:2:2}
          minor_dec=$((10#$minor_raw))
          if [ $minor_dec -lt 10 ]; then
            version="${major}.${minor_dec}"
          else
            r_version=$((minor_dec / 10))
            version="${major} R${r_version}"
          fi
          branch="${major}.x"
          echo "branch=${branch}" >> $GITHUB_OUTPUT
          echo "version=${version}" >> $GITHUB_OUTPUT

      - name: Download tool4d
        shell: bash
        run: |
          url="https://resources-download.4d.com/release/${{ steps.version.outputs.branch }}/${{ steps.version.outputs.version }}/latest/${{ matrix.platform }}/${{ matrix.tool4d_archive }}"
          curl "${url}" -o tool4d.tar.xz -sL
          tar xJf tool4d.tar.xz

      - name: Build plugin (macOS)
        if: runner.os == 'macOS'
        shell: bash
        run: |
          cd {name}
          mkdir -p cmake-build && cd cmake-build
          cmake .. -DCMAKE_BUILD_TYPE=Release
          cmake --build .

      - name: Build plugin (Windows)
        if: runner.os == 'Windows'
        shell: pwsh
        run: |
          cd {name}
          mkdir cmake-build; cd cmake-build
          cmake .. -A x64
          cmake --build . --config Release

      - name: Run tests (macOS)
        if: runner.os == 'macOS'
        shell: bash
        run: |
          tool4d.app/Contents/MacOS/tool4d \
            --dataless \
            --startup-method=test_all \
            --project=$(pwd)/{name}/{name}-test/Project/{name}.4DProject

      - name: Run tests (Windows)
        if: runner.os == 'Windows'
        shell: pwsh
        run: >
          ./tool4d/tool4d.exe --dataless --startup-method=test_all
          --project="$((Get-Location).Path)\{name}\{name}-test\Project\{name}.4DProject"
```

---

## GitHub Actions — Release Workflow

### `bump-version.yml` — Version Bump & Tag

Reads/writes a `VERSION` file in the project root. On manual dispatch, bumps the version, commits, and pushes a `vX.Y.Z` tag that triggers `release.yml`.

```yaml
name: Bump version

on:
  workflow_dispatch:
    inputs:
      mode:
        type: choice
        description: Semantic version bump
        options:
          - patch
          - minor
          - major
        default: patch
        required: true

permissions:
  contents: write

jobs:
  bump:
    runs-on: ubuntu-latest
    steps:
      - name: checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: bump VERSION
        id: bump
        run: |
          set -euo pipefail
          CURRENT=$(cat VERSION)
          if [ -z "$CURRENT" ]; then
            echo "Could not read VERSION file" >&2
            exit 1
          fi

          IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
          case "${{ inputs.mode }}" in
            major) MAJOR=$((MAJOR+1)); MINOR=0; PATCH=0 ;;
            minor) MINOR=$((MINOR+1)); PATCH=0 ;;
            patch) PATCH=$((PATCH+1)) ;;
          esac
          NEW="${MAJOR}.${MINOR}.${PATCH}"

          echo "Bumping ${CURRENT} -> ${NEW}"
          echo "$NEW" > VERSION

          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add VERSION
          git commit -m "chore: bump version to ${NEW}"
          git tag "v${NEW}"
          git push origin HEAD:"${GITHUB_REF_NAME}"
          git push origin "v${NEW}"

          echo "version=${NEW}" >> "$GITHUB_OUTPUT"

      - name: summary
        run: echo "### Bumped to v${{ steps.bump.outputs.version }} — release.yml will pick up the pushed tag." >> "$GITHUB_STEP_SUMMARY"
```

### `release.yml` — Build, Sign, Notarize & Release

Builds the plugin for both platforms using CMake, codesigns + notarizes the macOS binary, merges Windows + macOS into a single cross-platform `.bundle`, and publishes a GitHub Release.

```yaml
name: Build & Release

on:
  push:
    tags:
      - 'v*.*.*'
  workflow_dispatch:
    inputs:
      tag:
        description: Existing tag to build (e.g. v2.3.0)
        required: true

permissions:
  contents: write

env:
  PRODUCT_NAME: {name}
  MACOS_DEPLOYMENT_TARGET: '10.13'

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false

jobs:

  version:
    runs-on: ubuntu-latest
    outputs:
      tag: ${{ steps.set.outputs.tag }}
      version: ${{ steps.set.outputs.version }}
    steps:
      - id: set
        run: |
          TAG="${{ inputs.tag || github.ref_name }}"
          echo "tag=${TAG}" >> "$GITHUB_OUTPUT"
          echo "version=${TAG#v}" >> "$GITHUB_OUTPUT"

  build-windows:
    name: Build Windows (x64)
    needs: version
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ needs.version.outputs.tag }}
          submodules: recursive

      - name: build with CMake
        shell: pwsh
        run: |
          cd ${{ env.PRODUCT_NAME }}
          mkdir cmake-build; cd cmake-build
          cmake .. -A x64
          cmake --build . --config Release

      - name: upload windows binaries
        uses: actions/upload-artifact@v4
        with:
          name: windows-binaries
          path: |
            ${{ env.PRODUCT_NAME }}/${{ env.PRODUCT_NAME }}-test/Plugins/${{ env.PRODUCT_NAME }}/Contents/Windows64/${{ env.PRODUCT_NAME }}.4DX
          if-no-files-found: error

  build-macos:
    name: Build macOS, package, sign, notarize & release
    needs: [version, build-windows]
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ needs.version.outputs.tag }}
          submodules: recursive

      - name: download windows binaries
        uses: actions/download-artifact@v4
        with:
          name: windows-binaries
          path: winbuild

      - name: import Developer ID certificate
        env:
          CERT_BASE64: ${{ secrets.APPLE_DEVELOPER_ID_CERTIFICATE }}
          CERT_PASSWORD: ${{ secrets.APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD }}
          KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }}
        run: |
          set -euo pipefail
          KEYCHAIN_PATH="$RUNNER_TEMP/build.keychain-db"
          CERT_PATH="$RUNNER_TEMP/certificate.p12"

          echo -n "$CERT_BASE64" | base64 --decode -o "$CERT_PATH"

          security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
          security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
          security import "$CERT_PATH" -P "$CERT_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
          security list-keychain -d user -s "$KEYCHAIN_PATH" login.keychain
          security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

          echo "KEYCHAIN_PATH=$KEYCHAIN_PATH" >> "$GITHUB_ENV"

      - name: store notarytool credentials
        env:
          APPLE_ID: ${{ secrets.NOTARYTOOL_APPLE_ID }}
          TEAM_ID: ${{ secrets.NOTARYTOOL_TEAM_ID }}
          APP_PASSWORD: ${{ secrets.NOTARYTOOL_PASSWORD }}
        run: |
          xcrun notarytool store-credentials "notarytool-profile" \
            --apple-id "$APPLE_ID" \
            --team-id "$TEAM_ID" \
            --password "$APP_PASSWORD" \
            --keychain "$KEYCHAIN_PATH"

      - name: build macOS plugin (universal)
        run: |
          cd ${{ env.PRODUCT_NAME }}
          mkdir -p cmake-build && cd cmake-build
          cmake .. -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="${{ env.MACOS_DEPLOYMENT_TARGET }}"
          cmake --build .

      - name: verify universal binary
        run: |
          set -euo pipefail
          BIN="${{ env.PRODUCT_NAME }}/${{ env.PRODUCT_NAME }}-test/Plugins/${{ env.PRODUCT_NAME }}.bundle/Contents/MacOS/${{ env.PRODUCT_NAME }}"
          lipo -info "$BIN"
          lipo -info "$BIN" | grep -q "arm64" && lipo -info "$BIN" | grep -q "x86_64"

      - name: merge Windows binaries into the bundle
        run: |
          set -euo pipefail
          BUNDLE="${{ env.PRODUCT_NAME }}/${{ env.PRODUCT_NAME }}-test/Plugins/${{ env.PRODUCT_NAME }}.bundle"
          mkdir -p "$BUNDLE/Contents/Windows64"
          cp "winbuild/${{ env.PRODUCT_NAME }}.4DX" "$BUNDLE/Contents/Windows64/${{ env.PRODUCT_NAME }}.4DX"
          echo "BUNDLE_PATH=$BUNDLE" >> "$GITHUB_ENV"

      - name: codesign
        run: |
          set -euo pipefail
          IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
            | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')
          echo "Signing with: $IDENTITY"
          codesign --verbose --deep --timestamp --force --options=runtime \
            --sign "$IDENTITY" "$BUNDLE_PATH"
          codesign --verify --deep --strict --verbose=2 "$BUNDLE_PATH"

      - name: package, notarize & staple
        run: |
          set -euo pipefail
          VERSION="${{ needs.version.outputs.version }}"
          ZIP_PATH="${{ env.PRODUCT_NAME }}-${VERSION}.zip"
          DMG_PATH="${{ env.PRODUCT_NAME }}-${VERSION}.dmg"

          ditto -c -k --keepParent "$BUNDLE_PATH" "$ZIP_PATH"
          hdiutil create -format UDBZ -volname "${{ env.PRODUCT_NAME }}" -srcfolder "$BUNDLE_PATH" "$DMG_PATH"

          xcrun notarytool submit "$ZIP_PATH" --keychain-profile "notarytool-profile" --keychain "$KEYCHAIN_PATH" --wait
          xcrun notarytool submit "$DMG_PATH" --keychain-profile "notarytool-profile" --keychain "$KEYCHAIN_PATH" --wait
          xcrun stapler staple "$DMG_PATH"

          echo "ZIP_PATH=$ZIP_PATH" >> "$GITHUB_ENV"
          echo "DMG_PATH=$DMG_PATH" >> "$GITHUB_ENV"

      - name: create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ needs.version.outputs.tag }}
          name: ${{ needs.version.outputs.tag }}
          files: |
            ${{ env.ZIP_PATH }}
            ${{ env.DMG_PATH }}
```

### Required GitHub Secrets for Release

The `release.yml` workflow requires the following repository secrets configured in **Settings → Secrets and variables → Actions**:

| Secret | Description |
|---|---|
| `APPLE_DEVELOPER_ID_CERTIFICATE` | Base64-encoded `.p12` Developer ID Application certificate. Export from Keychain Access, then encode: `base64 -i certificate.p12 \| pbcopy` |
| `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` file |
| `KEYCHAIN_PASSWORD` | Arbitrary password for the temporary keychain created on the runner (can be any random string) |
| `NOTARYTOOL_APPLE_ID` | Your Apple ID email address (used for notarization) |
| `NOTARYTOOL_TEAM_ID` | Your Apple Developer Team ID (10-character alphanumeric, visible in Apple Developer portal) |
| `NOTARYTOOL_PASSWORD` | App-specific password generated at [appleid.apple.com](https://appleid.apple.com/account/manage) → Sign-In and Security → App-Specific Passwords |

**Note:** The `test.yml` and `bump-version.yml` workflows do NOT require any secrets. Only `release.yml` needs them for code signing and notarization.

### CI Caveats

- **`fail-fast: false`** — run both platforms independently so you see all failures
- **CMake on Windows** — use `pwsh` shell; do NOT hardcode `-G "Visual Studio 17 2022"` — use `-A x64` alone so CMake auto-detects the installed VS version (runners update frequently)
- **Universal binary** — pass `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"` for release builds
- **Submodules** — use `submodules: recursive` in checkout action
- **Version management** — `bump-version.yml` reads/writes a `VERSION` file, not project files

---

## README Template

Generate a `README.md` in the project root with the following structure. Replace `{name}`, `{description}`, command signatures, and examples with the actual plugin details.

````markdown
# {name}

{description}

## Requirements

- 4D v21.1 or later (compatible with the `compatibilityVersion` in `.4DProject`)

## Installation

Download the latest release from the [Releases](../../releases) page.

### macOS & Windows (single download)

1. Download the `.zip` from the release
2. Extract to get the `{name}.bundle` folder
3. Copy the `.bundle` into your 4D application's **Plugins** folder (or your database's **Plugins** folder)
4. Restart 4D

### macOS only (notarized DMG)

1. Download the `.dmg` from the release
2. Mount it and copy the `.bundle` into your **Plugins** folder
3. Restart 4D

## Commands

### `{CommandName}`

```4d
// Syntax from manifest.json, e.g.:
$result:={CommandName}($arg1; $arg2)
```

| Parameter | Type | Description |
|---|---|---|
| `$arg1` | Text | Description of first argument |
| `$result` | Text | Description of return value |

**Example:**

```4d
$result:={CommandName}("example input")
ASSERT($result="expected output")
```

{repeat for each command}

## Constants

{if the plugin defines constants in constants.xlf, list them here}

| Constant | Type | Value | Description |
|---|---|---|---|
| `Constant Name` | Longint | 1 | Description |

## Building from Source

### Prerequisites

- CMake 3.20+
- Xcode (macOS) or Visual Studio 2022 (Windows)

### Clone

```bash
git clone --recurse-submodules https://github.com/{owner}/{repo}.git
cd {repo}
```

### Build (macOS)

```bash
cd {name}
mkdir -p cmake-build && cd cmake-build
cmake .. -DCMAKE_BUILD_TYPE=Release
cmake --build .
```

### Build (Windows)

```pwsh
cd {name}
mkdir cmake-build; cd cmake-build
cmake .. -A x64
cmake --build . --config Release
```

### Run Tests

Requires [tool4d](https://developer.4d.com/docs/Admin/cli/) (free, no license needed):

```bash
/path/to/tool4d --dataless --startup-method=test_all --project=$(pwd)/{name}-test/Project/{name}.4DProject
```

## CI/CD

This project uses GitHub Actions for automated testing and releases:

| Workflow | Trigger | Purpose |
|---|---|---|
| `test.yml` | Tag push / manual | Build & test on macOS + Windows |
| `bump-version.yml` | Manual | Bump `VERSION`, commit, push tag |
| `release.yml` | `v*.*.*` tag | Build, sign, notarize, GitHub Release |

### Required Secrets (for `release.yml` only)

Configure these in **Settings → Secrets and variables → Actions**:

| Secret | Description |
|---|---|
| `APPLE_DEVELOPER_ID_CERTIFICATE` | Base64-encoded `.p12` Developer ID Application certificate |
| `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password for the `.p12` export |
| `KEYCHAIN_PASSWORD` | Arbitrary password for the CI runner's temporary keychain |
| `NOTARYTOOL_APPLE_ID` | Apple ID email for notarization |
| `NOTARYTOOL_TEAM_ID` | Apple Developer Team ID (10-char alphanumeric) |
| `NOTARYTOOL_PASSWORD` | App-specific password from [appleid.apple.com](https://appleid.apple.com/account/manage) |

## License

{license}
````

---

## Common Pitfalls

### 1. Plugin not recognized by 4D (macOS)

**Symptom**: `nm -g` shows only `_PluginMain`, missing `_FourDPackex` and `_gCall4D`.

**Cause**: `4DPluginAPI.c` is not being compiled. The SDK's `PBXFileSystemSynchronizedRootGroup` is not associated with the build target.

**Fix**: Add `fileSystemSynchronizedGroups` to the `PBXNativeTarget` section of the pbxproj.

### 2. Linker errors for CoreGraphics (macOS)

**Symptom**: `Undefined symbols: _CGContextScaleCTM, _CGContextTranslateCTM`

**Cause**: SDK uses CoreGraphics functions in `PA_UseQuartzAxis` / `PA_UseQuickdrawAxis`.

**Fix**: Link `CoreGraphics.framework` in the Xcode project.

### 3. `localtime` deprecation (Windows)

**Symptom**: MSVC error: `'localtime': This function or variable may be unsafe`

**Fix**: Use `localtime_s` on Windows with `#ifdef _WIN32`.

### 4. `msbuild` not found in CI

**Symptom**: `msbuild: command not found` in GitHub Actions.

**Cause**: `microsoft/setup-msbuild` adds msbuild to PATH for PowerShell, not bash.

**Fix**: Use `shell: pwsh` for the Windows build step.

### 5. Duplicate plugin names

**Symptom**: Plugin not loaded, no error message.

**Cause**: Another plugin with the same `name` in manifest.json is installed.

**Fix**: Ensure the `name` field is unique.

### 6. wchar_t size mismatch

**Pitfall**: Using `L"string"` for `PA_Unichar` buffers.

**Why**: `PA_Unichar` is `unsigned short` (16-bit). On macOS, `wchar_t` is 32-bit. `L"string"` produces 32-bit characters on macOS.

**Fix**: Widen ASCII manually: `result[i] = (PA_Unichar)ascii_char;`

### 7. CRT mismatch with third-party libraries (Windows)

**Symptom**: `error LNK2038: mismatch detected for 'RuntimeLibrary': value 'MD_DynamicRelease' doesn't match value 'MT_StaticRelease'`

**Cause**: The plugin uses static CRT (`/MT`) but a third-party library added via `add_subdirectory` defaults to dynamic CRT (`/MD`).

**Fix**: Set `CMAKE_MSVC_RUNTIME_LIBRARY` globally **before** `add_subdirectory` so all targets use the same CRT:

```cmake
if(WIN32)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>" CACHE STRING "" FORCE)
endif()
```

### 8. CMake generator mismatch on CI (Windows)

**Symptom**: `Visual Studio 17 2022 could not find any instance of Visual Studio`

**Cause**: GitHub runner images update frequently; `windows-latest` may ship VS 2026 while the workflow hardcodes VS 2022.

**Fix**: Omit `-G` and use only `-A x64`. CMake auto-detects the installed VS version:

```cmake
cmake .. -A x64
```

---

## Step-by-Step Checklist

Given a plugin specification (name, commands, constants, behavior):

### 1. Repository Setup
- [ ] Create repository
- [ ] Add `4D-Plugin-SDK` as git submodule
- [ ] Add any third-party library dependencies as git submodules
- [ ] Create `VERSION` file with initial version `1.0.0`
- [ ] Create `.gitignore`
- [ ] Commit

### 2. Project Files
- [ ] Create `{name}/` directory
- [ ] Create `{name}-4dplugin.h` with function declarations
- [ ] Create `{name}-4dplugin.cpp` with `PluginMain` stub and empty command functions
- [ ] Create `manifest.json` with command syntax
- [ ] Create `constants.xlf` with constant definitions

### 3. CMakeLists.txt
- [ ] Create `{name}/CMakeLists.txt` using the template
- [ ] Add third-party library via `add_subdirectory` if applicable
- [ ] Set include directories for third-party headers
- [ ] Link third-party libraries to the plugin target

### 4. 4D Test Project
- [ ] Create blank 4D project in `{name}-test/`
- [ ] Set `compatibilityVersion` in `.4DProject`
- [ ] Create `folders.json` with "Tests" virtual folder
- [ ] Create test methods with ASSERT statements
- [ ] Create `test_all.4dm` runner method
- [ ] Run tests locally with tool4d

### 5. C/C++ Implementation
- [ ] Implement command functions using SDK getters/setters
- [ ] Handle platform differences with `#ifdef _WIN32`
- [ ] Build on both platforms (or at least macOS for initial validation)
- [ ] Run tests

### 6. GitHub Actions Workflows
- [ ] Create `.github/workflows/test.yml` (CMake build + tool4d tests)
- [ ] Create `.github/workflows/bump-version.yml` (version bump + tag)
- [ ] Create `.github/workflows/release.yml` (build, sign, notarize, release)
- [ ] Verify CI passes

### 7. Documentation
- [ ] Create `README.md` using the template (see [README Template](#readme-template))
- [ ] Document required GitHub Secrets for release workflow

---

## Reference: Reusable GitHub Action for tool4d

For more complex setups, see: https://github.com/miyako/4D/blob/v1/.github/actions/tool4d-download/action.yml

This action handles:
- Platform detection (Windows/macOS)
- Architecture selection (x86_64/arm64)
- Version-specific URL formatting
- Download and extraction

---

## CMake-Based Project Generation (Recommended for Automation)

Instead of manually crafting Xcode `.pbxproj` and Visual Studio `.vcxproj` files, use CMake to generate both from a single `CMakeLists.txt`. This is the **recommended approach for agents** since CMake files are plain text and easy to generate programmatically.

### CMakeLists.txt Template

Place this in the `{name}/` directory alongside the source files:

```cmake
cmake_minimum_required(VERSION 3.20)

# Set the plugin name — change this for your project
set(PLUGIN_NAME "{name}" CACHE STRING "Plugin name")

project(${PLUGIN_NAME} LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_C_STANDARD 17)

# --- SDK paths ---
set(SDK_DIR "${CMAKE_SOURCE_DIR}/../4D-Plugin-SDK/4D Plugin API")

# --- Static CRT on Windows (MUST be set before add_subdirectory for third-party libs) ---
if(WIN32)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>" CACHE STRING "" FORCE)
endif()

# --- Source files ---
set(PLUGIN_SOURCES
    ${PLUGIN_NAME}-4dplugin.cpp
    "${SDK_DIR}/4DPluginAPI.c"
)

set(PLUGIN_HEADERS
    ${PLUGIN_NAME}-4dplugin.h
    "${SDK_DIR}/4DPluginAPI.h"
    "${SDK_DIR}/EntryPoints.h"
    "${SDK_DIR}/PublicTypes.h"
    "${SDK_DIR}/PrivateTypes.h"
    "${SDK_DIR}/Flags.h"
)

set(PLUGIN_RESOURCES
    manifest.json
    constants.xlf
)

# --- Platform-specific target setup ---
if(APPLE)
    # macOS: create a .bundle
    add_library(${PLUGIN_NAME} MODULE ${PLUGIN_SOURCES} ${PLUGIN_HEADERS} ${PLUGIN_RESOURCES})

    set_target_properties(${PLUGIN_NAME} PROPERTIES
        BUNDLE TRUE
        BUNDLE_EXTENSION "bundle"
        MACOSX_BUNDLE_GUI_IDENTIFIER "com.4d.${PLUGIN_NAME}"
        MACOSX_BUNDLE_BUNDLE_VERSION "1.0"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0"
    )

    # Copy resources into the bundle
    set_source_files_properties(${PLUGIN_RESOURCES} PROPERTIES
        MACOSX_PACKAGE_LOCATION Resources
    )

    # Link CoreGraphics (required by SDK for Quartz axis functions)
    find_library(COREGRAPHICS_FRAMEWORK CoreGraphics REQUIRED)
    target_link_libraries(${PLUGIN_NAME} PRIVATE ${COREGRAPHICS_FRAMEWORK})

    # Output to test project Plugins folder
    set_target_properties(${PLUGIN_NAME} PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/${PLUGIN_NAME}-test/Plugins"
        LIBRARY_OUTPUT_DIRECTORY_DEBUG "${CMAKE_SOURCE_DIR}/${PLUGIN_NAME}-test/Plugins"
        LIBRARY_OUTPUT_DIRECTORY_RELEASE "${CMAKE_SOURCE_DIR}/${PLUGIN_NAME}-test/Plugins"
    )

elseif(WIN32)
    # Windows: create a DLL with .4DX extension
    add_library(${PLUGIN_NAME} SHARED ${PLUGIN_SOURCES} ${PLUGIN_HEADERS})

    set_target_properties(${PLUGIN_NAME} PROPERTIES
        SUFFIX ".4DX"
        # Module definition file exports FourDPackex
        LINK_FLAGS "/DEF:\"${SDK_DIR}/4DPluginAPI.def\""
    )

    # Static CRT linkage
    set_property(TARGET ${PLUGIN_NAME} PROPERTY
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>"
    )

    # Output to test project Plugins folder (Windows structure)
    set(PLUGIN_OUT_DIR "${CMAKE_SOURCE_DIR}/${PLUGIN_NAME}-test/Plugins/${PLUGIN_NAME}/Contents/Windows64")
    set(RESOURCE_OUT_DIR "${CMAKE_SOURCE_DIR}/${PLUGIN_NAME}-test/Plugins/${PLUGIN_NAME}/Contents/Resources")

    set_target_properties(${PLUGIN_NAME} PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${PLUGIN_OUT_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_DEBUG "${PLUGIN_OUT_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_RELEASE "${PLUGIN_OUT_DIR}"
    )

    # Post-build: copy resources
    add_custom_command(TARGET ${PLUGIN_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory "${RESOURCE_OUT_DIR}"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_SOURCE_DIR}/manifest.json"
            "${CMAKE_SOURCE_DIR}/constants.xlf"
            "${RESOURCE_OUT_DIR}"
        COMMENT "Copying manifest.json and constants.xlf to Resources"
    )
endif()

# --- Common settings ---
target_include_directories(${PLUGIN_NAME} PRIVATE "${SDK_DIR}")

# Compile 4DPluginAPI.c as C++
set_source_files_properties("${SDK_DIR}/4DPluginAPI.c" PROPERTIES LANGUAGE CXX)

# Unicode charset
target_compile_definitions(${PLUGIN_NAME} PRIVATE UNICODE _UNICODE)
```

### Building with CMake

**macOS:**
```bash
cd {name}
mkdir -p cmake-build && cd cmake-build
cmake .. -DCMAKE_BUILD_TYPE=Debug
cmake --build .
```

**Windows:**
```pwsh
cd {name}
mkdir cmake-build; cd cmake-build
cmake .. -A x64
cmake --build . --config Debug
```

### CI/CD with CMake

See the full workflow templates in [GitHub Actions CI/CD](#github-actions-cicd) and [GitHub Actions — Release Workflow](#github-actions--release-workflow). CMake eliminates the need for `microsoft/setup-msbuild` since it finds the compiler automatically.

### Advantages for Automation

- Single `CMakeLists.txt` generates both platform projects
- Plain text format — easy to generate and modify programmatically
- No need to manage Xcode object IDs or MSBuild XML
- Adding source files requires editing one place, not two project files
- Cross-platform build commands are simple and well-documented
