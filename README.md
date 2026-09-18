# OmaMullvad

![OmaMullvad preview](preview.gif)

Mullvad VPN controls for the Omarchy Quattro bar.

- Connect and disconnect from the bar or panel
- Search relays and choose a specific server
- Save up to nine favourite locations
- Filter by provider, ownership, and IP version
- Configure DNS, anti-censorship, LAN sharing, and lockdown mode
- Launch apps outside the VPN
- View Mullvad relay cities on a world map

OmaMullvad follows the active Omarchy theme. The stock Omarchy bar is supported; replacement bars without access to the plugin service show an unavailable indicator. Shibumi service compatibility has not been verified.

## Install

```bash
omarchy plugin add https://github.com/kallupx/oma-mullvad.git --enable
```

OmaMullvad targets Mullvad VPN 2026.4. Install Mullvad separately and ensure its daemon is running, then refresh the panel. The embedded AUR installation launcher has been removed; this plugin does not install packages or start the daemon.

## Controls

- Left-click: open the panel
- Right-click: connect or disconnect
- Middle-click: refresh

The panel has Overview, Locations, Advanced, and Excluded Apps pages. It is fully keyboard-accessible.

## Hotkeys

OmaMullvad does not add keybindings automatically. Example `~/.config/hypr/bindings.lua` entries:

```lua
o.bind("SUPER + SHIFT + V", "Toggle Mullvad", "omarchy-shell io.github.kallupx.oma-mullvad toggleTunnel")
o.bind("SUPER + ALT + V", "Next Mullvad favourite", "omarchy-shell io.github.kallupx.oma-mullvad nextFavorite")
o.bind("SUPER + SHIFT + ALT + V", "OmaMullvad panel", "omarchy-shell io.github.kallupx.oma-mullvad toggle")
```

## Uninstall

```bash
omarchy plugin remove io.github.kallupx.oma-mullvad
```

## Privacy

Account numbers are sent to `mullvad account login` over standard input and are never stored. OmaMullvad stores only favourites and recent locations; Mullvad remains responsible for VPN settings.

## Verify

```bash
bash test/ci-local
```

The local gate requires Node.js, Quickshell, Cage, Qt QML lint and Omarchy. It runs the CLI contract and QML service/UI/scoped-settings probes through verified inert mocks in isolated homes and runtimes. It does not exercise the live VPN or launch desktop applications. UI probes cover component helpers and signals, not physical keyboard or pointer input.

CI runs this gate against Omarchy v4.0.3 and v4.0.4. Test-directory consolidation, remaining cross-feature validation and release metadata are deferred to the third PR in the planned series.

## License

MIT © 2026 kallupx; portions © 2026 HalmyLyseas

The map uses public-domain [Natural Earth](https://www.naturalearthdata.com/) data. Relay locations come from the Mullvad CLI.
