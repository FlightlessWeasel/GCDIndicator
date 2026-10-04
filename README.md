# GCDIndicator

A pixel-based status indicator addon for World of Warcraft

## Status Bar Indicators

The top row displays 5 status indicators (left to right):

| Indicator | Color When Active | Color When Inactive |
|-----------|------------------|---------------------|
| **Form/Stance** | Form-specific color | Black (no form) |
| **GCD** | White | Black |
| **Combat** | Red | Black |
| **Aggro** | Orange (has aggro) / Grey (no aggro) | White (no target) |
| **Channeling** | Yellow | Black |

### Form/Stance Colors
- **Bear Form**: Brown
- **Cat Form**: Orange
- **Travel Form**: Blue
- **Moonkin Form**: Purple
- **Tree of Life**: Green
- **Caster Form**: Black

## Resource Bars

Displays resource bars below the status indicators:
- **Health** (green)
- **Rage** (red)
- **Energy** (yellow)
- **Combo Points** (segmented orange)
- And other class resources (mana, focus, holy power, etc.)

## Spell/Item Tracking

Tracks spell and item cooldowns with color-coded indicators:
- **Green**: Ready and in range
- **Red**: Out of range
- **Black**: On cooldown
- **Grey**: Unavailable

## Buff Tracking

Tracks buffs and DoTs with optional pandemic window indicators:
- **Green**: Buff/DoT active
- **Black**: Buff/DoT inactive
- **Pandemic indicator**: Shows when DoT is in refresh window

## Slash Commands

| Command | Description |
|---------|-------------|
| `/gcdopt` | Open options panel |
| `/gcdopt scan` | Rescan action bars for spells |
| `/gcdopt preview` | Toggle preview mode (shows all indicators) |
| `/gcdopt debug` | Toggle debug mode (extra chat logging) |
| `/gcdopt compact` | Toggle compact mode (flow-packed layout, no icons) |
| `/gcdopt minimap` | Toggle the minimap button |
| `/gcdopt items` | List the item catalog and its status |
| `/gcdopt buffs` | List tracked buffs and their status |
| `/gcdopt cdmimport` | Re-import tracked buffs from the Cooldown Manager |
| `/gcdopt range` | Print range-detection debug info for tracked spells |
| `/gcdopt exportbars` | Export every visible bar's position/size (for external tooling) |
| `/gcdopt exportrotation` | Export the current spell/buff catalog as config text (for external tooling) |
| `/gcdi` or `/asconfig` | Enter position config mode (drag to move) |
| `/gcdr` or `/asclear` | Reset position to default |

## Configuration

Use `/gcdopt` to open the options panel where you can:
- Add/remove spells and items to track
- Configure buff tracking with pandemic support
- Manage profiles per spec/character
- Set global range fallback options

## Position

The indicator anchors to the top-left of the screen by default. Use `/gcdi` to enter config mode and drag to reposition. Position is saved per character.

## Local WoW MCP setup (Codex)

This project configures the [Hated WoW MCP server](https://github.com/RdyGaming/hated-wow-mcp) in `.codex/config.toml`. Codex loads project-scoped MCP configuration for trusted projects. The config runs the published package through `npx`, so it does not add a global MCP registration or a copy of the server to this repository.

1. Install Node.js 20 or newer and make sure `npx` is available on your PATH.
2. Open this repository as a trusted project in Codex, then restart Codex so it reads `.codex/config.toml`.
3. Check the connection with `/mcp` in Codex, or run `codex mcp list` from this repository. The server is named `wow`.

The bundled Lua API data works immediately. To enable Blizzard UI source, CVar, icon, atlas, and FileDataID lookups, install Git and run the one-time data sync from a terminal:

```powershell
npx -y hated-wow-mcp sync all
```

The server stores synced data in `%LOCALAPPDATA%\hated-wow-mcp\Cache` on Windows. Run the sync again after game patches. Ask the MCP's `wow_data_status` tool to check which data sets are available. The config defaults to the retail (`mainline`) client; change `WOW_DEFAULT_FLAVOR` in `.codex/config.toml` if this project targets another client.

Codex reads this project's development guidance from `AGENTS.md`. The project-specific `wow-addon-architect` agent is defined in `.codex/agents/wow-addon-architect.toml` for API research and inherits the `wow` MCP connection. Restart Codex after changing either file.
