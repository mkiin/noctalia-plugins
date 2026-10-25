# Noctalia plugins

A personal [Noctalia](https://github.com/noctalia-dev/noctalia) plugin source repo.

## Plugins

| Plugin | Description |
| --- | --- |
| `mkiin/wallpaper-picker` | Image + video wallpaper picker with a Noctalia v4-style UI and palette-synced favorites. |

## Install

```sh
noctalia msg plugins source add mkiin git https://github.com/mkiin/noctalia-plugins
```

Then enable a plugin from **Settings → Plugins** (or add it to `plugins.enabled`).

## Checks

Run `stylua --check wallpaper-picker/*.luau`,
`luau-lsp analyze --defs=noctalia.d.luau wallpaper-picker/*.luau`, and
`noctalia plugins lint` before publishing. CI runs these checks and the
wallpaper transition test on pushes and pull requests. `.luaurc` enables every
Luau lint as an error except `FunctionUnused`: Noctalia calls entry-point
functions outside Luau's call graph, so that rule reports false positives.
