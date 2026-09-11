from pathlib import Path

path = Path('src/pluto-dl.ps1')
text = path.read_text(encoding='utf-8')
old = '''$mEpisode = [regex]::Match($combined, '\\bE(?:pisode|p\\.?)?\\s*0*(\\d+)\\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
if ($mEpisode.Success) { $episode = [int]$mEpisode.Groups[1].Value }'''
new = '''if ($null -eq $episode) {
    $mEpisode = [regex]::Match($combined, '\\bE(?:pisode|p\\.?)?\\s*0*(\\d+)\\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($mEpisode.Success) { $episode = [int]$mEpisode.Groups[1].Value }
}'''
if old not in text:
    raise RuntimeError('episode inference block not found')
path.write_text(text.replace(old, new, 1), encoding='utf-8')
