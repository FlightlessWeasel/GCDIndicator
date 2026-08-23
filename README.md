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