# Keybindings Lookup

An Omarchy shell bar-widget that puts a searchable, favoritable reference of
your Hyprland keybindings one click away — no more opening `SUPER + K` and
scrolling to find the one you half-remember.

## Features

- **Two tabs**: *Favorites* (your own curated shortlist) and *Defaults*
  (every keybinding Hyprland currently has registered, same source as
  `omarchy menu keybindings`)
- **Live search** — type any words and it filters to bindings that match all
  of them, in any order, across both the key combo and the action name
- **Star to favorite** — tap the star on any row in Defaults to pin it to
  Favorites; tap again to unpin
- **Reorder favorites** — up/down arrows on each row in the Favorites tab let
  you arrange them however you like; the order is saved
- **6 rows visible, scrolls for more** — the popup stays compact instead of
  growing into a wall of text
- Read-only: clicking a row never executes the binding, it's a reference
  only

## Requirements

- [Omarchy](https://omarchy.org/) with the Quickshell-based bar (default
  install)
- Nothing else — no extra dependencies. It shells out to the `omarchy` CLI
  that already ships with every Omarchy install.

## Installation

```bash
omarchy plugin add https://github.com/Bagareal/omarchy-keybindings-lookup.git --enable
```

Or install first and enable later:

```bash
omarchy plugin add https://github.com/Bagareal/omarchy-keybindings-lookup.git
omarchy plugin enable bagareal.keybindings
```

To place it at a specific spot on the bar:

```bash
omarchy plugin enable bagareal.keybindings --before omarchy.agents
```

## What it reads and writes

For transparency, since Omarchy plugins run unsandboxed:

- **Reads**: runs `omarchy menu keybindings --print` to list your current
  Hyprland keybindings. Nothing else on your system is touched.
- **Writes**: your favorited keybindings and their order, as a plain JSON
  array, to `~/.local/state/omarchy/settings/bagareal-keybindings-favorites.json`.
  That's the only file this plugin ever writes.

## License

MIT — see [LICENSE](LICENSE).
