# ReShade Preset Doctor

A Windows PowerShell tool that checks what a ReShade preset actually needs — shaders, includes, textures and related files — so you can keep a clean ReShade install instead of copying an entire creator-provided `reshade-shaders` folder for every preset.

It shows what is **missing**, what looks **different or duplicated**, and what is already **OK**. It does not install, replace or modify your ReShade files.

## Run

### Run directly from GitHub

Open **PowerShell** and paste:

```powershell
irm https://raw.githubusercontent.com/shythorn/ReShade-Preset-Doctor/main/ReShadePresetDoctor.ps1 | iex
```

This runs the latest script directly from this repository.

### Or download it

Download `ReShadePresetDoctor.ps1` from the **[Releases page](https://github.com/shythorn/ReShade-Preset-Doctor/releases)**, then right-click it and choose **Run with PowerShell**.

If Windows blocks a downloaded copy, open the file's **Properties**, enable **Unblock** if shown, then run it again.

## How to use

1. Select a ReShade preset, or drag its `.ini` file onto the window.
2. Preset Doctor will try to find the matching `ReShade.ini` automatically.
3. If needed, select the correct `ReShade.ini` manually — especially when the preset is stored outside the game folder.
4. Optionally select the preset creator's original pack as a **Reference** folder.
5. Click **SCAN PRESET** and check anything marked **MISSING** or **WARN**.

Double-click a found file in the results to show it in File Explorer. You can also save the scan as a text report.

## What it checks

- Enabled techniques and their required `.fx` shaders
- Older presets that do not include `@Shader.fx` in the technique list
- Recursive `.fxh` include dependencies
- Texture references used by shaders (`PNG`, `JPG`, `JPEG`, `BMP`, `TGA`, `DDS`, `CUBE`)
- ReShade `EffectSearchPaths` and `TextureSearchPaths`
- Missing search folders
- Duplicate files with the same name
- Same-name files with different SHA-256 hashes
- Optional comparison with a creator/reference folder
- Installed `.addon`, `.addon32` and `.addon64` files
- Recent error-like entries in `ReShade.log`

## Results

- **MISSING** — a file the preset appears to need could not be found.
- **WARN** — something needs attention, such as conflicting duplicates, a different reference copy, a possible texture reference or a ReShade log error.
- **OK** — the required file was found.
- **INFO** — useful information that cannot always be tied to a definite problem.

Results start with the most important items first.

## Reference folder

The **Reference** field is optional, but useful when a preset creator includes their own shaders or textures.

Point it at the creator's original preset/package folder and Preset Doctor will find matching filenames and compare them to your installed copies using SHA-256 hashes. This can reveal cases where you already have `MultiLUT.png`, `SomeShader.fx`, or another file with the same name, but the creator's version is actually different.

Without a reference copy, Preset Doctor can confirm that a file exists, but it cannot know whether it is exactly the version the preset creator used. Normal ReShade preset files do not store hashes for their shader and texture dependencies.

## Keeping a clean ReShade install

A lot of presets are distributed with a complete `reshade-shaders` folder. Copying the whole folder works, but over time it can leave you with unused files, duplicate shaders, old versions, modified files and conflicts between presets.

A cleaner workflow is:

1. Install ReShade normally.
2. Install the shader packages you normally use through the ReShade installer.
3. Load the preset and scan it with Preset Doctor.
4. Investigate **MISSING** and **WARN** results.
5. Only copy creator-provided shaders or textures when they are actually needed, modified, custom or version-specific.

This is especially useful if you keep a lot of presets installed and want to avoid your ReShade folders turning into a collection of files from every preset pack you have tried.

## Limitations

Preset Doctor is a static dependency checker; it does not run ReShade's shader compiler. Unusual `#if` blocks, macros or generated filenames can occasionally make a dependency appear when it is not active, or hide one from the scan.

ReShade presets also do not have standardized metadata for required external add-ons, so installed add-ons are shown for information only. Preset Doctor cannot reliably tell which add-ons a preset requires.

The tool is a checker, not an installer: it does not download shaders, copy reference files, overwrite anything or guarantee that a preset will look exactly like the creator's screenshots.

## License

ReShade Preset Doctor is released under the [MIT License](LICENSE).

ReShade Preset Doctor is an independent utility and is not affiliated with the ReShade project.
