# Mullvad VPN for the Omarchy bar

![Mullvad VPN preview](preview.gif)

Mullvad VPN controls for the Omarchy Quattro bar.

- Connect and disconnect from the bar or panel
- Search relays and choose a specific server
- Save up to nine favourite locations
- Filter by provider, ownership, and IP version
- Configure DNS, anti-censorship, LAN sharing, and lockdown mode
- Launch apps outside the VPN
- View Mullvad relay cities on a world map

This plugin follows the active Omarchy theme and works with the stock bar and Shibumi.

## Install

This fork is not on the Omarchy plugin marketplace yet (no public repository
exists for it). Until then, install it as a manual clone into the plugins
folder:

```bash
git clone <this-repo> ~/.config/omarchy/plugins/halmylyseas.mullvad
```

Then enable and load it:

```bash
omarchy plugin enable halmylyseas.mullvad --section right
omarchy restart shell
```

This plugin targets Mullvad VPN 2026.4. If Mullvad is missing, the panel can install the AUR package `mullvad-vpn-bin` after confirmation.

## Controls

- Left-click: open the panel
- Right-click: connect or disconnect
- Middle-click: refresh

The panel has Overview, Locations, Advanced, and Excluded Apps pages. It is fully keyboard-accessible.

## Hotkeys

This plugin does not add keybindings automatically. Example `~/.config/hypr/bindings.lua` entries:

```lua
o.bind("SUPER + SHIFT + V", "Toggle Mullvad", "omarchy-shell halmylyseas.mullvad toggleTunnel")
o.bind("SUPER + ALT + V", "Next Mullvad favourite", "omarchy-shell halmylyseas.mullvad nextFavorite")
o.bind("SUPER + SHIFT + ALT + V", "Mullvad panel", "omarchy-shell halmylyseas.mullvad toggle")
```

## Uninstall

```bash
omarchy plugin remove halmylyseas.mullvad
```

## Privacy

Account numbers are sent to `mullvad account login` over standard input and are never stored. This plugin stores only favourites and recent locations; Mullvad remains responsible for VPN settings.

## Verify

```bash
node --test
node tests/cli-contract.mjs
omarchy plugin validate .
```

The CLI contract check is read-only.

## Credits

Forked from [kallupx/oma-mullvad](https://github.com/kallupx/oma-mullvad), the
original OmaMullvad plugin. This fork keeps its upstream history (`upstream`
remote) and intends to upstream fixes back via PR where they apply.

## License

MIT © 2026 kallupx, © 2026 HalmyLyseas

The map uses public-domain [Natural Earth](https://www.naturalearthdata.com/) data. Relay locations come from the Mullvad CLI.
