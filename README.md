# The Lance

A real beam weapon for the **UZDXREMA** engine fork.

Not a sprite. Not a chain of puffs. Not a stretched quad. The beam is a
*segment light* — the engine lights every pixel by its distance from the
line, so it is continuous at any length, wraps floor/wall/ceiling as one
unbroken object, hangs visibly in the air, correctly disappears behind
walls, feeds bloom on its own, and lights the surfaces near it because they
**are** near it. Nothing is spawned to fake any of that.

---

## Requires the fork

This will **not** run on stock GZDoom. It does not compile there.

It needs two things stock GZDoom does not have:

| Needs | For |
|---|---|
| `Level.SetBeam` / `SetBeamCount` / `SetBeamLook` | drawing the beam at all |
| `AttackPos` / `OffhandPos` / `OverrideAttackPosDir` / `Weapon.LaserBeamOffset` | tracked-hand aim and the muzzle origin |

The first group is UZDXREMA's own (see `FORK_CHANGES.md` §13). The second
comes from its VR lineage.

## Load it

```bash
doomxr.exe -iwad doom2.wad -file RS_Lance
```

Loads as a loose directory or zipped as a `.pk3`. It replaces nothing and
touches no existing class, so it drops into other mods without conflict.

To get it in-game:

```bash
give LNC_Lance
```

`LNC_LanceOffhand` is the same weapon flagged for the other hand — give
both and you dual-wield, each holding its own beam.

---

## How it plays

Everything the weapon does — damage, rate of fire, colour, width,
brightness, sound pitch, even how long the next trigger pull takes to spin
up — comes from one number: **charge**, which is heat over the cook-off
threshold, 0 to 1.

| | cold | mid | edge |
|---|---|---|---|
| damage × | 0.40 | 1.32 | **3.00** |
| cadence | every 4 tics | 3 | **2** |
| ≈ DPS | 14 | 62 | **210** |

**Holding ramps you up.** The curve is back-loaded (`c^1.5`) so the top is
somewhere you have to commit to reach. A linear ramp would hand out most of
the payoff in the first second and make tapping optimal, which would defeat
the point of a sustained weapon.

**Releasing keeps it.** Heat bleeds at half the rate it builds, so a short
pulse costs almost none of the ramp. Pulse the trigger to sit just under
cook-off and hold peak damage indefinitely — at the price of never being
able to relax.

**Re-pulling costs.** Every pull pays a spin-up before it damages anything.
But the spin-up *shortens* with charge — 14 tics cold, 3 hot — because a
hot emitter relights fast. That is what makes pulsing rewarding rather than
merely tedious.

**Cooking off hurts.** Past 1.0 the beam cuts and the weapon vents, locked,
all the way back to stone cold — about 2.8 seconds of holding a dead gun.
After four seconds of white glare you are standing in a black room, which
is a worse punishment than any number going down.

The colour ramp is the gauge: cold blue-white → hard white → amber → a bad
orange. There is deliberately no meter. White owns the broad middle where
the weapon is comfortable; the last third is where it visibly stops being.

**The real cost** is that firing is a tactical disclosure. In a dark map you
can see twenty metres. The moment you pull the trigger there is a line of
white light hanging in the air lighting the corridor, and you standing in
it. The damage is balanced knowing that.

---

## Tuning

| Where | What |
|---|---|
| `Weapon.LaserBeamOffset (0, 22, 0)` | how far down the barrel the beam starts. **`Y` is forward, not `X`** — see below. |
| `LNC_DAMAGE` | base damage before the charge ramp |
| `LNC_OVERHEAT` / `LNC_HEATRATE` | how long a full hold lasts (280 ÷ 2 = 140 tics = 4.0s) |
| `LNC_COOLRATE` / `LNC_VENTRATE` | how fast heat bleeds normally / after a cook-off |
| `LNC_SPINUP` | the cold spin-up, scaled down by charge in `SpinupNeeded()` |
| `thick` / `soft` / `inten` in `A_LanceBeam` | how fat and how bright |

### Two things that will bite you

**`LaserBeamOffset` is not XYZ.** The engine builds its offset as
`(laser_y + weap.Y, laser_x + weap.X, laser_z + weap.Z)` and then applies
`.X` along *forward*, `.Y` along *side*, `.Z` along *up*. So in an authored
offset it is **Y that means forward** and X that means sideways. The code
mirrors this exactly so that the beam and the engine's own VR laser sight
emit from one point. Do not tidy it without changing the engine to match.

**`SetBeamLook` and the glow term of `SetBeamCount` are frame-global.**
They are single vec4s in the viewpoint block, not arrays. Every beam on
screen shares them and the last caller each tic wins. Per beam you only get
start, end, thickness, softness, colour and intensity. If you add a second
beam user, those globals want one owner rather than every actor stomping the
others.

There are **8 beam slots** total. This weapon uses slot 0 for the mainhand
and slot 1 for the offhand, so two Lances never fight over one. Each active
slot costs a per-pixel segment test across the whole screen, twice — once
for surface lighting, once for the glow in the air — so the count is a real
budget, not a free ceiling.

---

## Differences from the RS_Main version

Extracted from RS_Main's `RS_LaserGun`. The beam, the heat model, the
damage ramp and the muzzle origin are identical. What was removed is
RS_Main, not the weapon:

- Damage goes through a direct `LineAttack` instead of RS_Main's attack-slot
  assembly — so no affix axes, no shot keywords, no GunBonsai tracking, no
  crit or condition system.
- Base damage is a constant rather than rolled from a tier table, so the
  weapon has no hidden per-instance state.
- Two classes instead of six. RS_Main carries six tier variants; here there
  is just a mainhand and an offhand.
- No HUD heat readout. RS_Main puts it in the status bar's magazine row,
  which a drop-in weapon has no business hijacking. The colour ramp is the
  gauge.
- The impact puff is self-contained rather than deriving from RS_Main's
  material-resolving puff base.

## Credits

Bolter model and skin, plasma foley, and the beam renderer are all from the
RS_Main / UZDXREMA project.
