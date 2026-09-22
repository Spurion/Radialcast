# RadialCast

A radial spell wheel on middle mouse. Hold it, flick toward a spell, release to cast.

## Features

- **Three spell rings:** Base, Shift, and Ctrl. Hold a modifier while the wheel is open to swap instantly.
- **Drag and drop setup** straight from your spellbook, bags, or macros.
- **Cooldown swipes and timers** on every slot.
- **Per-character layouts** that persist across reloads.
- **Combat casting (beta):** hover a slot and click with your choice of left, right, back, or forward mouse button.

## Setup

1. Drop the `RadialCast` folder into `Interface/AddOns`.
2. Restart the game. WoW only detects new addon folders at launch, so `/reload` won't pick it up the first time.
3. Type `/rcast` to open settings.
4. Drag your spells onto the ring and hit **Save**.

## Commands

| Command | Description |
|---|---|
| `/rcast` | Open settings and the layout editor |
| `/rcast enable` / `/rcast disable` | Turn everything on or off |
| `/rcast enable <rings>` / `/rcast disable <rings>` | Turn specific rings on or off, e.g. `/rcast disable shift,ctrl` |
| `/rcast status` | See which rings are active |
| `/rcast reset` | Clear all rings (asks to confirm) |

Ring names: `base`, `shift`, `ctrl`.

## Combat Casting (BETA)

- Hold middle mouse, hover a slot, and click to cast. Pick the button in `/rcast` under **Cast with**: Left, Right, Back, or Forward.
- Shift and Ctrl still swap rings live in combat.
- The combat wheel opens at a fixed screen position, adjustable in `/rcast`.
- **Limitation:** WoW locks addon buttons during combat, so the wheel's slots stay clickable (invisibly) at that position for the whole fight. Clicking one with your cast button casts it even when the wheel is closed. Other mouse buttons pass through normally.
- **Why not flick-and-release?** That needs secure code this client can't currently run. Out of combat, flick-and-release works as normal.
- Combat casting can be turned off in `/rcast`.

Combat casting is still in beta, so let me know if you run into anything.