param(
    [Parameter(Position=0)]
    [string]$Preset = ""
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Rows = New-Object System.Collections.ArrayList
$script:HashCache = @{}
$script:ResolveCache = @{}
$script:LastPreset = ""
$script:LastConfig = ""
$script:LastEffectSpecs = @()
$script:LastTextureSpecs = @()
$script:GridView = $null
$script:StatusSortAscending = $true
$script:DarkMode = $true
$script:LastSummarySeverity = "NONE"

function Split-ReShadeList {
    param([string]$Value)
    $items = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }

    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $ch = $Value[$i]
        if ($ch -eq ',') {
            if (($i + 1) -lt $Value.Length -and $Value[$i + 1] -eq ',') {
                [void]$sb.Append(',')
                $i++
            } else {
                $s = $sb.ToString().Trim()
                if ($s.Length -gt 0) { [void]$items.Add($s) }
                [void]$sb.Clear()
            }
        } else {
            [void]$sb.Append($ch)
        }
    }
    $tail = $sb.ToString().Trim()
    if ($tail.Length -gt 0) { [void]$items.Add($tail) }
    return @($items)
}

function Get-IniValueAnySection {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $escaped = [Regex]::Escape($Key)
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match ("^\s*" + $escaped + "\s*=(.*)$")) {
            return $Matches[1].Trim()
        }
    }
    return $null
}

function Get-IniValueSection {
    param([string]$Path, [string]$Section, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $current = ""
    $sectionFound = $false
    $escapedKey = [Regex]::Escape($Key)

    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*\[(.+?)\]\s*$') {
            $current = $Matches[1].Trim()
            $sectionFound = ($current -ieq $Section)
            continue
        }
        if ($sectionFound -and $line -match ("^\s*" + $escapedKey + "\s*=(.*)$")) {
            return $Matches[1].Trim()
        }
    }
    return $null
}

function Get-FullPathSafe {
    param([string]$Base, [string]$PathText)
    if ([string]::IsNullOrWhiteSpace($PathText)) { return $null }
    $p = [Environment]::ExpandEnvironmentVariables($PathText.Trim().Trim('"'))
    try {
        if ([IO.Path]::IsPathRooted($p)) {
            return [IO.Path]::GetFullPath($p)
        }
        return [IO.Path]::GetFullPath((Join-Path $Base $p))
    } catch {
        return $null
    }
}

function Convert-ToSearchSpecs {
    param([string]$Value, [string]$Base, [string[]]$Fallbacks)

    $rawItems = @()
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $rawItems = @(Split-ReShadeList $Value)
    } else {
        $rawItems = @($Fallbacks)
    }

    $specs = New-Object System.Collections.ArrayList
    foreach ($raw in $rawItems) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $text = $raw.Trim().Trim('"').Replace('/', '\')
        $recursive = $false

        if ($text -match '\\\*\*\\\*$') {
            $recursive = $true
            $text = $text.Substring(0, $text.Length - 4)
        } elseif ($text -match '\\\*\*$') {
            $recursive = $true
            $text = $text.Substring(0, $text.Length - 3)
        } elseif ($text -eq '**') {
            $recursive = $true
            $text = '.'
        }

        $full = Get-FullPathSafe $Base $text
        if ($null -eq $full) { continue }

        [void]$specs.Add([PSCustomObject]@{
            Raw       = $raw
            Root      = $full.TrimEnd('\')
            Recursive = $recursive
            Exists    = (Test-Path -LiteralPath $full -PathType Container)
        })
    }
    return @($specs)
}

function Find-ReShadeConfig {
    param([string]$PresetPath)

    $dir = Split-Path -Parent $PresetPath
    $probe = $dir
    for ($level = 0; $level -lt 5 -and -not [string]::IsNullOrWhiteSpace($probe); $level++) {
        $exact = Join-Path $probe "ReShade.ini"
        if (Test-Path -LiteralPath $exact -PathType Leaf) { return $exact }

        try {
            $candidates = @(Get-ChildItem -LiteralPath $probe -File -Filter "*.ini" -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -ne $PresetPath })
            foreach ($c in $candidates) {
                $e = Get-IniValueSection $c.FullName "GENERAL" "EffectSearchPaths"
                $t = Get-IniValueSection $c.FullName "GENERAL" "TextureSearchPaths"
                if ($null -ne $e -or $null -ne $t) { return $c.FullName }
            }
        } catch {}

        $parent = Split-Path -Parent $probe
        if ($parent -eq $probe) { break }
        $probe = $parent
    }
    return $null
}

function Get-HashSafe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    if ($script:HashCache.ContainsKey($Path)) { return $script:HashCache[$Path] }
    try {
        $h = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
        $script:HashCache[$Path] = $h
        return $h
    } catch {
        $script:HashCache[$Path] = ""
        return ""
    }
}

function Add-Result {
    param(
        [string]$Status,
        [string]$Type,
        [string]$Item,
        [string]$FoundAt = "",
        [string]$Details = "",
        [string]$Hash = ""
    )
    [void]$script:Rows.Add([PSCustomObject]@{
        Status  = $Status
        Type    = $Type
        Item    = $Item
        FoundAt = $FoundAt
        Details = $Details
        SHA256  = $Hash
    })
}

function Resolve-FromSpecs {
    param(
        [string]$Requested,
        $Specs,
        [string]$CachePrefix
    )
    if ([string]::IsNullOrWhiteSpace($Requested)) { return @() }

    $cacheKey = $CachePrefix + "|" + $Requested.ToLowerInvariant()
    if ($script:ResolveCache.ContainsKey($cacheKey)) {
        return @($script:ResolveCache[$cacheKey])
    }

    $req = $Requested.Trim().Trim('"').Replace('/', '\')
    $results = New-Object System.Collections.ArrayList

    try {
        if ([IO.Path]::IsPathRooted($req) -and (Test-Path -LiteralPath $req -PathType Leaf)) {
            [void]$results.Add([IO.Path]::GetFullPath($req))
            $script:ResolveCache[$cacheKey] = @($results)
            return @($results)
        }
    } catch {}

    foreach ($spec in $Specs) {
        if (-not $spec.Exists) { continue }

        $direct = Join-Path $spec.Root $req
        if (Test-Path -LiteralPath $direct -PathType Leaf) {
            $full = [IO.Path]::GetFullPath($direct)
            if (-not ($results -contains $full)) { [void]$results.Add($full) }
        }

        if ($spec.Recursive) {
            $leaf = Split-Path -Leaf $req
            if ([string]::IsNullOrWhiteSpace($leaf)) { continue }
            try {
                $found = @(Get-ChildItem -LiteralPath $spec.Root -Recurse -File -Filter $leaf -ErrorAction SilentlyContinue)
                foreach ($f in $found) {
                    $ok = $true
                    if ($req.Contains('\')) {
                        $fullNorm = $f.FullName.Replace('/', '\')
                        $ok = $fullNorm.EndsWith($req, [StringComparison]::OrdinalIgnoreCase)
                    }
                    if ($ok -and -not ($results -contains $f.FullName)) {
                        [void]$results.Add($f.FullName)
                    }
                }
            } catch {}
        }
    }

    $script:ResolveCache[$cacheKey] = @($results)
    return @($results)
}

function Resolve-Include {
    param([string]$Requested, [string]$SourceFile, $EffectSpecs)

    $results = New-Object System.Collections.ArrayList
    $local = Join-Path (Split-Path -Parent $SourceFile) $Requested
    if (Test-Path -LiteralPath $local -PathType Leaf) {
        [void]$results.Add([IO.Path]::GetFullPath($local))
    }

    foreach ($p in @(Resolve-FromSpecs $Requested $EffectSpecs "include")) {
        if (-not ($results -contains $p)) { [void]$results.Add($p) }
    }
    return @($results)
}

function Describe-CandidateConflict {
    param([string[]]$Candidates)

    if ($Candidates.Count -le 1) { return "" }

    $hashes = New-Object System.Collections.ArrayList
    foreach ($p in $Candidates) {
        $h = Get-HashSafe $p
        if (-not [string]::IsNullOrWhiteSpace($h) -and -not ($hashes -contains $h)) {
            [void]$hashes.Add($h)
        }
    }

    if ($hashes.Count -gt 1) {
        return "Multiple matching files have DIFFERENT hashes. Search-path/version conflict possible. First match is shown."
    }
    return "Multiple matching files exist, but their SHA-256 hashes match."
}

function Add-ResolvedFileResult {
    param(
        [string]$Type,
        [string]$Item,
        [string[]]$Candidates,
        [string]$MissingDetails = ""
    )

    if ($Candidates.Count -eq 0) {
        Add-Result "MISSING" $Type $Item "" $MissingDetails ""
        return $null
    }

    $chosen = $Candidates[0]
    $conflict = Describe-CandidateConflict $Candidates
    $status = "OK"
    $details = ""
    if (-not [string]::IsNullOrWhiteSpace($conflict)) {
        if ($conflict -like "*DIFFERENT*") { $status = "WARN" }
        $details = $conflict
    }
    Add-Result $status $Type $Item $chosen $details (Get-HashSafe $chosen)
    return $chosen
}

function Find-LegacyTechniqueFiles {
    param([string]$Technique, $EffectSpecs)

    $matches = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($spec in $EffectSpecs) {
        if (-not $spec.Exists) { continue }
        try {
            if ($spec.Recursive) {
                $files = @(Get-ChildItem -LiteralPath $spec.Root -Recurse -File -Filter "*.fx" -ErrorAction SilentlyContinue)
            } else {
                $files = @(Get-ChildItem -LiteralPath $spec.Root -File -Filter "*.fx" -ErrorAction SilentlyContinue)
            }
            foreach ($f in $files) {
                if ($seen.ContainsKey($f.FullName)) { continue }
                $seen[$f.FullName] = $true
                try {
                    $content = [IO.File]::ReadAllText($f.FullName)
                    $pattern = '(?im)\btechnique(?:10|11)?\s+' + [Regex]::Escape($Technique) + '\b'
                    if ($content -match $pattern) { [void]$matches.Add($f.FullName) }
                } catch {}
            }
        } catch {}
    }
    return @($matches)
}

function Get-CommentStrippedText {
    param([string]$Path)
    try {
        $text = [IO.File]::ReadAllText($Path)
        $text = [Regex]::Replace($text, '(?s)/\*.*?\*/', '')
        $text = [Regex]::Replace($text, '(?m)//.*$', '')
        return $text
    } catch {
        return ""
    }
}

function Scan-ShaderTree {
    param(
        [string[]]$RootShaders,
        $EffectSpecs,
        $TextureSpecs
    )

    $queue = New-Object System.Collections.Queue
    foreach ($root in $RootShaders) {
        if (-not [string]::IsNullOrWhiteSpace($root)) { $queue.Enqueue($root) }
    }

    $visited = @{}
    $reportedIncludes = @{}
    $reportedTextures = @{}

    while ($queue.Count -gt 0) {
        $source = [string]$queue.Dequeue()
        if ($visited.ContainsKey($source)) { continue }
        $visited[$source] = $true

        $text = Get-CommentStrippedText $source
        if ([string]::IsNullOrWhiteSpace($text)) {
            Add-Result "WARN" "Shader read" (Split-Path -Leaf $source) $source "Could not read this shader for dependency inspection." ""
            continue
        }

        $includeMatches = [Regex]::Matches($text, '(?im)^\s*#\s*include\s*[<"]([^>"]+)[>"]')
        foreach ($m in $includeMatches) {
            $inc = $m.Groups[1].Value.Trim()
            if ([string]::IsNullOrWhiteSpace($inc)) { continue }

            $reportKey = ($source + "|" + $inc).ToLowerInvariant()
            if ($reportedIncludes.ContainsKey($reportKey)) { continue }
            $reportedIncludes[$reportKey] = $true

            $candidates = @(Resolve-Include $inc $source $EffectSpecs)
            if ($candidates.Count -eq 0) {
                Add-Result "MISSING" "Include (.fxh)" $inc $source "Referenced by shader. Static scan cannot know whether this line is inside a disabled #if branch." ""
            } else {
                $chosen = $candidates[0]
                $conflict = Describe-CandidateConflict $candidates
                $status = "OK"
                if ($conflict -like "*DIFFERENT*") { $status = "WARN" }
                Add-Result $status "Include (.fxh)" $inc $chosen ("Used by: " + (Split-Path -Leaf $source) + $(if($conflict){" | " + $conflict}else{""})) (Get-HashSafe $chosen)
                $queue.Enqueue($chosen)
            }
        }

        $strongTextureMatches = [Regex]::Matches($text, '(?is)\bsource\s*=\s*"([^"]+\.(?:png|jpe?g|bmp|tga|dds|cube))"')
        $strong = @{}
        foreach ($m in $strongTextureMatches) {
            $tex = $m.Groups[1].Value.Trim()
            if ([string]::IsNullOrWhiteSpace($tex)) { continue }
            $strong[$tex.ToLowerInvariant()] = $true

            $reportKey = ($source + "|" + $tex).ToLowerInvariant()
            if ($reportedTextures.ContainsKey($reportKey)) { continue }
            $reportedTextures[$reportKey] = $true

            $candidates = @(Resolve-FromSpecs $tex $TextureSpecs "texture")
            if ($candidates.Count -eq 0) {
                Add-Result "MISSING" "Texture" $tex $source "Texture source annotation found in shader. Could be conditional if controlled by preprocessor code." ""
            } else {
                $chosen = $candidates[0]
                $conflict = Describe-CandidateConflict $candidates
                $status = "OK"
                if ($conflict -like "*DIFFERENT*") { $status = "WARN" }
                Add-Result $status "Texture" $tex $chosen ("Used by: " + (Split-Path -Leaf $source) + $(if($conflict){" | " + $conflict}else{""})) (Get-HashSafe $chosen)
            }
        }

        # Catch image filenames hidden in macros or helper code, but mark them as heuristic.
        $possibleTextureMatches = [Regex]::Matches($text, '"([^"]+\.(?:png|jpe?g|bmp|tga|dds|cube))"')
        foreach ($m in $possibleTextureMatches) {
            $tex = $m.Groups[1].Value.Trim()
            if ([string]::IsNullOrWhiteSpace($tex)) { continue }
            if ($strong.ContainsKey($tex.ToLowerInvariant())) { continue }

            $reportKey = ("possible|" + $source + "|" + $tex).ToLowerInvariant()
            if ($reportedTextures.ContainsKey($reportKey)) { continue }
            $reportedTextures[$reportKey] = $true

            $candidates = @(Resolve-FromSpecs $tex $TextureSpecs "texture")
            if ($candidates.Count -eq 0) {
                Add-Result "WARN" "Possible texture" $tex $source "Image filename appears in shader code, but not directly as source=... . Check if a macro/preprocessor branch actually uses it." ""
            } else {
                $chosen = $candidates[0]
                $conflict = Describe-CandidateConflict $candidates
                $status = "INFO"
                if ($conflict -like "*DIFFERENT*") { $status = "WARN" }
                Add-Result $status "Possible texture" $tex $chosen ("Heuristic reference in: " + (Split-Path -Leaf $source) + $(if($conflict){" | " + $conflict}else{""})) (Get-HashSafe $chosen)
            }
        }
    }
}

function Inventory-Addons {
    param([string]$ConfigPath, [string]$BaseDir)

    $addonPathValue = $null
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath)) {
        $addonPathValue = Get-IniValueSection $ConfigPath "ADDON" "AddonPath"
    }

    if ([string]::IsNullOrWhiteSpace($addonPathValue)) {
        $addonDir = $BaseDir
    } else {
        $addonDir = Get-FullPathSafe $BaseDir $addonPathValue
    }

    if ($null -eq $addonDir -or -not (Test-Path -LiteralPath $addonDir -PathType Container)) {
        Add-Result "INFO" "Add-ons" "(none inventoried)" "" "Preset INI files do not standardly declare which ReShade add-ons they require. Add-on folder was not found." ""
        return
    }

    $addons = @(Get-ChildItem -LiteralPath $addonDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @(".addon", ".addon32", ".addon64") })

    if ($addons.Count -eq 0) {
        Add-Result "INFO" "Add-ons" "(none found)" $addonDir "No external add-ons found here. This is only an inventory; the preset itself does not tell us what add-ons it needs." ""
    } else {
        foreach ($a in $addons) {
            Add-Result "INFO" "Installed add-on" $a.Name $a.FullName "Inventory only. A normal preset does not contain standardized add-on dependency metadata." (Get-HashSafe $a.FullName)
        }
    }
}

function Add-LogWarnings {
    param([string]$BaseDir)
    $log = Join-Path $BaseDir "ReShade.log"
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { return }

    try {
        $lines = @(Get-Content -LiteralPath $log -ErrorAction Stop |
            Where-Object { $_ -match '(?i)\b(error|failed|could not|not found|unable)\b' } |
            Select-Object -Last 40)
        foreach ($line in $lines) {
            Add-Result "WARN" "ReShade.log" "Runtime warning/error" $log $line.Trim() ""
        }
    } catch {}
}

function Find-ReferenceMatches {
    param([string]$ReferenceRoot, [string]$LocalPath)

    if ([string]::IsNullOrWhiteSpace($ReferenceRoot) -or -not (Test-Path -LiteralPath $ReferenceRoot -PathType Container)) {
        return @()
    }
    $leaf = Split-Path -Leaf $LocalPath
    if ([string]::IsNullOrWhiteSpace($leaf)) { return @() }
    try {
        return @(Get-ChildItem -LiteralPath $ReferenceRoot -Recurse -File -Filter $leaf -ErrorAction SilentlyContinue)
    } catch {
        return @()
    }
}

function Compare-WithReference {
    param([string]$ReferenceRoot)

    if ([string]::IsNullOrWhiteSpace($ReferenceRoot)) { return }
    if (-not (Test-Path -LiteralPath $ReferenceRoot -PathType Container)) {
        Add-Result "WARN" "Reference comparison" "Reference folder" $ReferenceRoot "Folder does not exist." ""
        return
    }

    $snapshot = @($script:Rows)
    foreach ($row in $snapshot) {
        if ([string]::IsNullOrWhiteSpace($row.FoundAt)) { continue }
        if (-not (Test-Path -LiteralPath $row.FoundAt -PathType Leaf)) { continue }
        if ($row.Type -notin @("Required shader", "Legacy technique shader", "Include (.fxh)", "Texture", "Possible texture", "Installed add-on")) { continue }

        $refs = @(Find-ReferenceMatches $ReferenceRoot $row.FoundAt)
        if ($refs.Count -eq 0) { continue }

        $localHash = Get-HashSafe $row.FoundAt
        $matching = @()
        $different = @()
        foreach ($r in $refs) {
            $rh = Get-HashSafe $r.FullName
            if ($rh -eq $localHash) { $matching += $r.FullName } else { $different += $r.FullName }
        }

        if ($matching.Count -gt 0) {
            Add-Result "OK" "Reference hash" (Split-Path -Leaf $row.FoundAt) $row.FoundAt ("Matches reference copy: " + $matching[0]) $localHash
        } elseif ($different.Count -gt 0) {
            Add-Result "WARN" "Reference hash" (Split-Path -Leaf $row.FoundAt) $row.FoundAt ("LOCAL FILE DIFFERS from reference copy: " + $different[0]) $localHash
        }
    }
}

function Invoke-PresetScan {
    param(
        [string]$PresetPath,
        [string]$ConfigOverride,
        [string]$ReferenceRoot
    )

    $script:Rows.Clear()
    $script:HashCache = @{}
    $script:ResolveCache = @{}

    if ([string]::IsNullOrWhiteSpace($PresetPath) -or -not (Test-Path -LiteralPath $PresetPath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show("Choose a valid ReShade preset INI file.", "Preset not found",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return $false
    }

    $PresetPath = [IO.Path]::GetFullPath($PresetPath)
    $presetDir = Split-Path -Parent $PresetPath

    $config = $ConfigOverride
    if ([string]::IsNullOrWhiteSpace($config) -or -not (Test-Path -LiteralPath $config -PathType Leaf)) {
        $config = Find-ReShadeConfig $PresetPath
    }

    $configBase = $presetDir
    if (-not [string]::IsNullOrWhiteSpace($config)) {
        $config = [IO.Path]::GetFullPath($config)
        $configBase = Split-Path -Parent $config
        Add-Result "OK" "Configuration" (Split-Path -Leaf $config) $config "Using EffectSearchPaths / TextureSearchPaths from this config." (Get-HashSafe $config)
    } else {
        Add-Result "WARN" "Configuration" "ReShade.ini not found" $presetDir "Using fallback paths: game folder and .\reshade-shaders\Shaders/Textures. Select ReShade.ini manually if yours is elsewhere." ""
    }

    $effectValue = $null
    $textureValue = $null
    if (-not [string]::IsNullOrWhiteSpace($config)) {
        $effectValue = Get-IniValueSection $config "GENERAL" "EffectSearchPaths"
        $textureValue = Get-IniValueSection $config "GENERAL" "TextureSearchPaths"
    }

    $effectFallback = @(".\", ".\reshade-shaders\Shaders\**")
    $textureFallback = @(".\", ".\reshade-shaders\Textures\**")

    $effectSpecs = @(Convert-ToSearchSpecs $effectValue $configBase $effectFallback)
    $textureSpecs = @(Convert-ToSearchSpecs $textureValue $configBase $textureFallback)

    $script:LastPreset = $PresetPath
    $script:LastConfig = $config
    $script:LastEffectSpecs = $effectSpecs
    $script:LastTextureSpecs = $textureSpecs

    foreach ($s in $effectSpecs) {
        if (-not $s.Exists) {
            Add-Result "WARN" "Effect search path" $s.Raw $s.Root "Configured path does not exist." ""
        }
    }
    foreach ($s in $textureSpecs) {
        if (-not $s.Exists) {
            Add-Result "WARN" "Texture search path" $s.Raw $s.Root "Configured path does not exist." ""
        }
    }

    $techValue = Get-IniValueAnySection $PresetPath "Techniques"
    if ([string]::IsNullOrWhiteSpace($techValue)) {
        Add-Result "MISSING" "Preset" "Techniques=" $PresetPath "This file does not contain a Techniques list, so it may not be a ReShade preset." ""
        return $true
    }

    $tokens = @(Split-ReShadeList $techValue)
    if ($tokens.Count -eq 0) {
        Add-Result "INFO" "Preset" "No enabled techniques" $PresetPath "Techniques= is empty." ""
    }

    $rootShaders = New-Object System.Collections.ArrayList
    foreach ($token in $tokens) {
        $t = $token.Trim()
        if ($t.Length -eq 0) { continue }

        $at = $t.IndexOf('@')
        if ($at -ge 0 -and $at -lt ($t.Length - 1)) {
            $techName = $t.Substring(0, $at).Trim()
            $fx = $t.Substring($at + 1).Trim()
            $candidates = @(Resolve-FromSpecs $fx $effectSpecs "effect")
            $chosen = Add-ResolvedFileResult "Required shader" ($techName + " @ " + $fx) $candidates "Enabled by the preset, but the .fx file was not found in ReShade's effect search paths."
            if ($null -ne $chosen -and -not ($rootShaders -contains $chosen)) {
                [void]$rootShaders.Add($chosen)
            }
        } else {
            $legacy = $t
            $candidates = @(Find-LegacyTechniqueFiles $legacy $effectSpecs)
            if ($candidates.Count -eq 0) {
                Add-Result "MISSING" "Legacy technique" $legacy "" "Preset does not name its .fx file and no shader declaring this technique was found." ""
            } else {
                $chosen = Add-ResolvedFileResult "Legacy technique shader" $legacy $candidates "Could not resolve legacy technique."
                if ($null -ne $chosen -and -not ($rootShaders -contains $chosen)) {
                    [void]$rootShaders.Add($chosen)
                }
            }
        }
    }

    if ($rootShaders.Count -gt 0) {
        Scan-ShaderTree @($rootShaders) $effectSpecs $textureSpecs
    }

    Inventory-Addons $config $configBase
    Add-LogWarnings $configBase
    Compare-WithReference $ReferenceRoot

    Add-Result "INFO" "Limit" "Conditional compilation" "" "This is a static checker. #if / macro-controlled dependencies may be over-reported or under-reported in unusual shaders. ReShade.log is also scanned when present." ""
    Add-Result "INFO" "Limit" "Modified creator textures" "" "A local file can be proven present and hashed, but the checker cannot know what hash the preset creator intended unless you give it a reference folder containing the creator's files." ""
    Add-Result "INFO" "Limit" "Required add-ons" "" "Normal ReShade preset INIs do not contain standardized required-add-on metadata. Installed add-ons can be inventoried, but required ones cannot be inferred reliably from the preset alone." ""

    return $true
}

function Export-Report {
    param([string]$Destination)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("ReShade Preset Doctor Report")
    [void]$lines.Add("Generated: " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
    [void]$lines.Add("Preset: " + $script:LastPreset)
    [void]$lines.Add("Config: " + $script:LastConfig)
    [void]$lines.Add("")
    [void]$lines.Add("STATUS`tTYPE`tITEM`tFOUND AT`tDETAILS`tSHA256")
    foreach ($r in $script:Rows) {
        $detail = ($r.Details -replace "`t", " " -replace "`r?`n", " ")
        [void]$lines.Add(($r.Status + "`t" + $r.Type + "`t" + $r.Item + "`t" + $r.FoundAt + "`t" + $detail + "`t" + $r.SHA256))
    }
    [IO.File]::WriteAllLines($Destination, @($lines), [Text.UTF8Encoding]::new($true))
}

# GUI

$form = New-Object System.Windows.Forms.Form
$form.Text = "ReShade Preset Doctor v1.2"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(1180, 760)
$form.MinimumSize = New-Object System.Drawing.Size(900, 600)
$form.AllowDrop = $true

$font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Font = $font

$title = New-Object System.Windows.Forms.Label
$title.Text = "ReShade Preset Doctor v1.2"
$title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 16)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(14, 12)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "Checks what a ReShade preset needs so you can install it cleanly without copying an entire reshade-shaders folder."
$subtitle.AutoSize = $true
$subtitle.Location = New-Object System.Drawing.Point(16, 45)
$form.Controls.Add($subtitle)

$btnTheme = New-Object System.Windows.Forms.Button
$btnTheme.Anchor = "Top,Right"
$btnTheme.Text = "Light mode"
$btnTheme.Location = New-Object System.Drawing.Point(1040, 12)
$btnTheme.Size = New-Object System.Drawing.Size(110, 30)
$form.Controls.Add($btnTheme)

$lblPreset = New-Object System.Windows.Forms.Label
$lblPreset.Text = "Preset:"
$lblPreset.AutoSize = $true
$lblPreset.Location = New-Object System.Drawing.Point(16, 78)
$form.Controls.Add($lblPreset)

$txtPreset = New-Object System.Windows.Forms.TextBox
$txtPreset.Anchor = "Top,Left,Right"
$txtPreset.Location = New-Object System.Drawing.Point(85, 75)
$txtPreset.Size = New-Object System.Drawing.Size(875, 24)
$form.Controls.Add($txtPreset)

$btnPreset = New-Object System.Windows.Forms.Button
$btnPreset.Anchor = "Top,Right"
$btnPreset.Text = "Browse..."
$btnPreset.Location = New-Object System.Drawing.Point(972, 73)
$btnPreset.Size = New-Object System.Drawing.Size(90, 28)
$form.Controls.Add($btnPreset)

$lblConfig = New-Object System.Windows.Forms.Label
$lblConfig.Text = "ReShade.ini:"
$lblConfig.AutoSize = $true
$lblConfig.Location = New-Object System.Drawing.Point(16, 110)
$form.Controls.Add($lblConfig)

$txtConfig = New-Object System.Windows.Forms.TextBox
$txtConfig.Anchor = "Top,Left,Right"
$txtConfig.Location = New-Object System.Drawing.Point(85, 107)
$txtConfig.Size = New-Object System.Drawing.Size(875, 24)
$txtConfig.ForeColor = [Drawing.Color]::DimGray
$form.Controls.Add($txtConfig)

$btnConfig = New-Object System.Windows.Forms.Button
$btnConfig.Anchor = "Top,Right"
$btnConfig.Text = "Browse..."
$btnConfig.Location = New-Object System.Drawing.Point(972, 105)
$btnConfig.Size = New-Object System.Drawing.Size(90, 28)
$form.Controls.Add($btnConfig)

$lblRef = New-Object System.Windows.Forms.Label
$lblRef.Text = "Reference:"
$lblRef.AutoSize = $true
$lblRef.Location = New-Object System.Drawing.Point(16, 142)
$form.Controls.Add($lblRef)

$txtRef = New-Object System.Windows.Forms.TextBox
$txtRef.Anchor = "Top,Left,Right"
$txtRef.Location = New-Object System.Drawing.Point(85, 139)
$txtRef.Size = New-Object System.Drawing.Size(875, 24)
$txtRef.ForeColor = [Drawing.Color]::DimGray
$txtRef.Text = ""
$form.Controls.Add($txtRef)

$btnRef = New-Object System.Windows.Forms.Button
$btnRef.Anchor = "Top,Right"
$btnRef.Text = "Folder..."
$btnRef.Location = New-Object System.Drawing.Point(972, 137)
$btnRef.Size = New-Object System.Drawing.Size(90, 28)
$form.Controls.Add($btnRef)

$hintRef = New-Object System.Windows.Forms.Label
$hintRef.Text = "Optional: compare against the preset creator's files to spot modified or different copies."
$hintRef.AutoSize = $true
$hintRef.ForeColor = [Drawing.Color]::DimGray
$hintRef.Location = New-Object System.Drawing.Point(85, 165)
$form.Controls.Add($hintRef)

$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Text = "SCAN PRESET"
$btnScan.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$btnScan.Location = New-Object System.Drawing.Point(16, 192)
$btnScan.Size = New-Object System.Drawing.Size(150, 36)
$form.Controls.Add($btnScan)

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = "Save report..."
$btnExport.Location = New-Object System.Drawing.Point(176, 196)
$btnExport.Size = New-Object System.Drawing.Size(110, 30)
$btnExport.Enabled = $false
$form.Controls.Add($btnExport)

$summary = New-Object System.Windows.Forms.Label
$summary.AutoSize = $true
$summary.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$summary.Location = New-Object System.Drawing.Point(305, 201)
$summary.Text = "No scan yet."
$form.Controls.Add($summary)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(16, 238)
$grid.Anchor = "Top,Bottom,Left,Right"
$grid.Size = New-Object System.Drawing.Size(1135, 455)
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToOrderColumns = $true
$grid.AutoSizeRowsMode = "DisplayedCells"
$grid.RowHeadersVisible = $false
$grid.SelectionMode = "FullRowSelect"
$grid.MultiSelect = $false
$grid.AutoGenerateColumns = $false
$form.Controls.Add($grid)

# Short hover help for fields that may be unfamiliar to new users.
$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 10000
$toolTip.InitialDelay = 400
$toolTip.ReshowDelay = 100
$toolTip.ShowAlways = $true

$toolTip.SetToolTip($txtPreset, "The ReShade preset INI you want to check.")
$toolTip.SetToolTip($btnPreset, "Choose the ReShade preset INI you want to check.")
$toolTip.SetToolTip($txtConfig, "Usually detected automatically. If not, choose the ReShade.ini from the game where this preset will be used.")
$toolTip.SetToolTip($btnConfig, "Choose the game's ReShade.ini if it was not detected automatically.")
$toolTip.SetToolTip($txtRef, "Optional. Choose the preset creator's original pack if you want to compare matching shader and texture files.")
$toolTip.SetToolTip($btnRef, "Optional: choose the preset creator's folder for file comparison.")
$toolTip.SetToolTip($btnScan, "Check the preset against the shaders, includes, textures, search paths, and related files ReShade can see.")
$toolTip.SetToolTip($btnExport, "Save the current scan results as a text report.")
$toolTip.SetToolTip($grid, "Results are sorted by importance. Double-click a found file to show it in File Explorer.")

$colStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colStatus.Name = "Status"
$colStatus.HeaderText = "Status"
$colStatus.DataPropertyName = "Status"
$colStatus.Width = 75
$colStatus.SortMode = "Programmatic"
[void]$grid.Columns.Add($colStatus)

$colType = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colType.Name = "Type"
$colType.HeaderText = "Type"
$colType.DataPropertyName = "Type"
$colType.Width = 130
[void]$grid.Columns.Add($colType)

$colItem = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colItem.Name = "Item"
$colItem.HeaderText = "Item"
$colItem.DataPropertyName = "Item"
$colItem.Width = 220
[void]$grid.Columns.Add($colItem)

$colFound = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colFound.Name = "FoundAt"
$colFound.HeaderText = "Found at / referenced by"
$colFound.DataPropertyName = "FoundAt"
$colFound.Width = 330
[void]$grid.Columns.Add($colFound)

$colDetails = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colDetails.Name = "Details"
$colDetails.HeaderText = "Details"
$colDetails.DataPropertyName = "Details"
$colDetails.AutoSizeMode = "Fill"
[void]$grid.Columns.Add($colDetails)

function Update-SummaryColor {
    if ($script:DarkMode) {
        switch ($script:LastSummarySeverity) {
            "MISSING" { $summary.ForeColor = [Drawing.Color]::LightCoral }
            "WARN"    { $summary.ForeColor = [Drawing.Color]::Khaki }
            "OK"      { $summary.ForeColor = [Drawing.Color]::LightGreen }
            default   { $summary.ForeColor = [Drawing.Color]::Gainsboro }
        }
    } else {
        switch ($script:LastSummarySeverity) {
            "MISSING" { $summary.ForeColor = [Drawing.Color]::DarkRed }
            "WARN"    { $summary.ForeColor = [Drawing.Color]::DarkGoldenrod }
            "OK"      { $summary.ForeColor = [Drawing.Color]::DarkGreen }
            default   { $summary.ForeColor = [Drawing.Color]::Black }
        }
    }
}

function Apply-Theme {
    if ($script:DarkMode) {
        $form.BackColor = [Drawing.Color]::FromArgb(30, 30, 30)

        foreach ($lbl in @($title, $subtitle, $lblPreset, $lblConfig, $lblRef)) {
            $lbl.ForeColor = [Drawing.Color]::Gainsboro
            $lbl.BackColor = [Drawing.Color]::Transparent
        }

        $hintRef.ForeColor = [Drawing.Color]::Silver
        $hintRef.BackColor = [Drawing.Color]::Transparent

        foreach ($tb in @($txtPreset, $txtConfig, $txtRef)) {
            $tb.BackColor = [Drawing.Color]::FromArgb(37, 37, 38)
            $tb.ForeColor = [Drawing.Color]::Gainsboro
            $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        }

        foreach ($btn in @($btnPreset, $btnConfig, $btnRef, $btnScan, $btnExport, $btnTheme)) {
            $btn.UseVisualStyleBackColor = $false
            $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $btn.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(80, 80, 80)
            $btn.BackColor = [Drawing.Color]::FromArgb(45, 45, 48)
            $btn.ForeColor = [Drawing.Color]::Gainsboro
        }

        $grid.EnableHeadersVisualStyles = $false
        $grid.BackgroundColor = [Drawing.Color]::FromArgb(30, 30, 30)
        $grid.GridColor = [Drawing.Color]::FromArgb(65, 65, 65)
        $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $grid.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(45, 45, 48)
        $grid.ColumnHeadersDefaultCellStyle.ForeColor = [Drawing.Color]::Gainsboro
        $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(55, 55, 58)
        $grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = [Drawing.Color]::White
        $grid.DefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(37, 37, 38)
        $grid.DefaultCellStyle.ForeColor = [Drawing.Color]::Gainsboro
        $grid.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(0, 92, 153)
        $grid.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::White

        $btnTheme.Text = "Light mode"
    } else {
        $form.BackColor = [Drawing.SystemColors]::Control

        foreach ($lbl in @($title, $subtitle, $lblPreset, $lblConfig, $lblRef)) {
            $lbl.ForeColor = [Drawing.Color]::Black
            $lbl.BackColor = [Drawing.Color]::Transparent
        }

        $hintRef.ForeColor = [Drawing.Color]::DimGray
        $hintRef.BackColor = [Drawing.Color]::Transparent

        foreach ($tb in @($txtPreset, $txtConfig, $txtRef)) {
            $tb.BackColor = [Drawing.SystemColors]::Window
            $tb.ForeColor = [Drawing.SystemColors]::WindowText
            $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
        }

        foreach ($btn in @($btnPreset, $btnConfig, $btnRef, $btnScan, $btnExport, $btnTheme)) {
            $btn.UseVisualStyleBackColor = $true
            $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
            $btn.BackColor = [Drawing.SystemColors]::Control
            $btn.ForeColor = [Drawing.SystemColors]::ControlText
        }

        $grid.EnableHeadersVisualStyles = $true
        $grid.BackgroundColor = [Drawing.SystemColors]::AppWorkspace
        $grid.GridColor = [Drawing.SystemColors]::ControlDark
        $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
        $grid.DefaultCellStyle.BackColor = [Drawing.Color]::White
        $grid.DefaultCellStyle.ForeColor = [Drawing.Color]::Black
        $grid.DefaultCellStyle.SelectionBackColor = [Drawing.SystemColors]::Highlight
        $grid.DefaultCellStyle.SelectionForeColor = [Drawing.SystemColors]::HighlightText

        $btnTheme.Text = "Dark mode"
    }

    Update-SummaryColor
    $grid.Invalidate()
    $form.Invalidate()
}

function Refresh-Grid {
    $table = New-Object System.Data.DataTable
    [void]$table.Columns.Add("Status")
    [void]$table.Columns.Add("Severity", [int])
    [void]$table.Columns.Add("Type")
    [void]$table.Columns.Add("Item")
    [void]$table.Columns.Add("FoundAt")
    [void]$table.Columns.Add("Details")
    [void]$table.Columns.Add("SHA256")

    foreach ($r in $script:Rows) {
        $row = $table.NewRow()
        $row.Status = $r.Status

        switch ($r.Status) {
            "MISSING" { $row.Severity = 0 }
            "WARN"    { $row.Severity = 1 }
            "OK"      { $row.Severity = 2 }
            default   { $row.Severity = 3 }
        }

        $row.Type = $r.Type
        $row.Item = $r.Item
        $row.FoundAt = $r.FoundAt
        $row.Details = $r.Details
        $row.SHA256 = $r.SHA256
        [void]$table.Rows.Add($row)
    }

    $script:GridView = $table.DefaultView
    $script:GridView.Sort = "Severity ASC, Status ASC, Type ASC, Item ASC"
    $grid.DataSource = $script:GridView

    foreach ($c in $grid.Columns) {
        $c.HeaderCell.SortGlyphDirection = [System.Windows.Forms.SortOrder]::None
    }
    $grid.Columns["Status"].HeaderCell.SortGlyphDirection = [System.Windows.Forms.SortOrder]::Ascending
    # Start with the most important results first; the first click reverses the order.
    $script:StatusSortAscending = $false

    $missing = @($script:Rows | Where-Object { $_.Status -eq "MISSING" }).Count
    $warn = @($script:Rows | Where-Object { $_.Status -eq "WARN" }).Count
    $ok = @($script:Rows | Where-Object { $_.Status -eq "OK" }).Count

    if ($missing -gt 0) {
        $summary.Text = "$missing missing  |  $warn warnings  |  $ok OK"
        $script:LastSummarySeverity = "MISSING"
    } elseif ($warn -gt 0) {
        $summary.Text = "No definite missing files  |  $warn warnings  |  $ok OK"
        $script:LastSummarySeverity = "WARN"
    } else {
        $summary.Text = "No missing files found  |  $ok OK"
        $script:LastSummarySeverity = "OK"
    }

    Update-SummaryColor
    $btnExport.Enabled = ($script:Rows.Count -gt 0)
}

function Do-Scan {
    $btnScan.Enabled = $false
    $btnScan.Text = "Scanning..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $ok = Invoke-PresetScan $txtPreset.Text $txtConfig.Text $txtRef.Text
        if ($ok) {
            if ([string]::IsNullOrWhiteSpace($txtConfig.Text) -and -not [string]::IsNullOrWhiteSpace($script:LastConfig)) {
                $txtConfig.Text = $script:LastConfig
            }
            Refresh-Grid
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "The checker hit an unexpected error:`r`n`r`n" + $_.Exception.Message,
            "ReShade Preset Doctor",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnScan.Text = "SCAN PRESET"
        $btnScan.Enabled = $true
    }
}

$btnPreset.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "ReShade preset (*.ini;*.txt)|*.ini;*.txt|All files (*.*)|*.*"
    $dlg.Title = "Choose ReShade preset"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtPreset.Text = $dlg.FileName
        $auto = Find-ReShadeConfig $dlg.FileName
        if ($null -ne $auto) { $txtConfig.Text = $auto }
    }
})

$btnConfig.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "INI files (*.ini)|*.ini|All files (*.*)|*.*"
    $dlg.Title = "Choose ReShade configuration INI"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtConfig.Text = $dlg.FileName
    }
})

$btnRef.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Choose creator/reference folder for SHA-256 comparison"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtRef.Text = $dlg.SelectedPath
    }
})

$btnScan.Add_Click({ Do-Scan })

$btnExport.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = "Text report (*.txt)|*.txt"
    $dlg.FileName = "ReShadePresetDoctor_Report.txt"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Export-Report $dlg.FileName
    }
})


# Keep status colors persistent after sorting and theme changes.
$grid.Add_CellFormatting({
    param($sender, $e)
    if ($e.RowIndex -lt 0) { return }

    $status = [string]$grid.Rows[$e.RowIndex].Cells["Status"].Value

    if ($script:DarkMode) {
        switch ($status) {
            "MISSING" {
                $e.CellStyle.BackColor = [Drawing.Color]::FromArgb(82, 35, 35)
                $e.CellStyle.ForeColor = [Drawing.Color]::FromArgb(255, 180, 180)
            }
            "WARN" {
                $e.CellStyle.BackColor = [Drawing.Color]::FromArgb(78, 65, 26)
                $e.CellStyle.ForeColor = [Drawing.Color]::FromArgb(255, 222, 130)
            }
            "OK" {
                $e.CellStyle.BackColor = [Drawing.Color]::FromArgb(28, 64, 45)
                $e.CellStyle.ForeColor = [Drawing.Color]::FromArgb(170, 235, 190)
            }
            default {
                $e.CellStyle.BackColor = [Drawing.Color]::FromArgb(37, 37, 38)
                $e.CellStyle.ForeColor = [Drawing.Color]::Silver
            }
        }
    } else {
        switch ($status) {
            "MISSING" {
                $e.CellStyle.BackColor = [Drawing.Color]::MistyRose
                $e.CellStyle.ForeColor = [Drawing.Color]::DarkRed
            }
            "WARN" {
                $e.CellStyle.BackColor = [Drawing.Color]::LemonChiffon
                $e.CellStyle.ForeColor = [Drawing.Color]::DarkGoldenrod
            }
            "OK" {
                $e.CellStyle.BackColor = [Drawing.Color]::Honeydew
                $e.CellStyle.ForeColor = [Drawing.Color]::DarkGreen
            }
            default {
                $e.CellStyle.BackColor = [Drawing.Color]::White
                $e.CellStyle.ForeColor = [Drawing.Color]::DimGray
            }
        }
    }
})

# Sort Status by severity instead of alphabetically.
$grid.Add_ColumnHeaderMouseClick({
    param($sender, $e)
    if ($e.ColumnIndex -lt 0) { return }

    $column = $grid.Columns[$e.ColumnIndex]
    if ($column.Name -ne "Status") { return }
    if ($null -eq $script:GridView) { return }

    foreach ($c in $grid.Columns) {
        $c.HeaderCell.SortGlyphDirection = [System.Windows.Forms.SortOrder]::None
    }

    if ($script:StatusSortAscending) {
        $script:GridView.Sort = "Severity ASC, Status ASC, Type ASC, Item ASC"
        $column.HeaderCell.SortGlyphDirection = [System.Windows.Forms.SortOrder]::Ascending
        $script:StatusSortAscending = $false
    } else {
        $script:GridView.Sort = "Severity DESC, Status DESC, Type ASC, Item ASC"
        $column.HeaderCell.SortGlyphDirection = [System.Windows.Forms.SortOrder]::Descending
        $script:StatusSortAscending = $true
    }

    $grid.Invalidate()
})

$btnTheme.Add_Click({
    $script:DarkMode = -not $script:DarkMode
    Apply-Theme
})


$grid.Add_CellDoubleClick({
    param($sender, $e)
    if ($e.RowIndex -lt 0) { return }
    $path = [string]$grid.Rows[$e.RowIndex].Cells["FoundAt"].Value
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Start-Process explorer.exe -ArgumentList "/select,`"$path`""
    } elseif (Test-Path -LiteralPath $path -PathType Container) {
        Start-Process explorer.exe -ArgumentList "`"$path`""
    }
})

$dropHandler = {
    param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $files = @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
        if ($files.Count -gt 0) {
            $candidate = $files[0]
            if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and ([IO.Path]::GetExtension($candidate) -in @(".ini", ".txt"))) {
                $txtPreset.Text = $candidate
                $auto = Find-ReShadeConfig $candidate
                if ($null -ne $auto) { $txtConfig.Text = $auto }
                Do-Scan
            }
        }
    }
}

$dragEnterHandler = {
    param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    } else {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::None
    }
}

$form.Add_DragEnter($dragEnterHandler)
$form.Add_DragDrop($dropHandler)
$grid.AllowDrop = $true
$grid.Add_DragEnter($dragEnterHandler)
$grid.Add_DragDrop($dropHandler)

if (-not [string]::IsNullOrWhiteSpace($Preset) -and (Test-Path -LiteralPath $Preset -PathType Leaf)) {
    $txtPreset.Text = [IO.Path]::GetFullPath($Preset)
    $autoCfg = Find-ReShadeConfig $txtPreset.Text
    if ($null -ne $autoCfg) { $txtConfig.Text = $autoCfg }
    $form.Add_Shown({ Do-Scan })
}

Apply-Theme

[void]$form.ShowDialog()
