// =====================================================================
// THE LANCE -- a real beam weapon for the UZDXREMA engine fork.
//
// Standalone extraction of RS_Main's RS_LaserGun. Descends from plain
// Weapon and does its own damage, so it drops into any mod.
//
// WHAT MAKES IT A BEAM AND NOT A FAST HITSCAN. The engine fork draws it by
// lighting every pixel by its distance from the segment -- Level.SetBeam,
// FORK_CHANGES.md section 13. It is not a sprite and not a chain of puffs:
// continuous at any length, wrapping floor/wall/ceiling as one unbroken
// object, visible hanging in the air, correctly vanishing behind walls, and
// the surfaces near it brighten because they ARE near it.
//
// AND IT DOES NOT FIRE. There are no shots. The beam is ON, and while it is
// on it deposits energy at a RATE -- damage is accumulated per tic as a real
// number and spent when it builds a whole point. No hitscans, no puffs, no
// cadence, no impact stutter.
//
// ---------------------------------------------------------------------
// NO AMMO. HEAT IS THE ONLY RESOURCE.
//
// Heat runs 0 to 100. Holding the trigger drives it up at 25/second, so a
// continuous hold reaches 100 in four seconds. Off the trigger it falls at
// 12.5/second -- half speed, so short bursts are nearly free and long holds
// commit. Touch 100 and the weapon locks out for a flat five seconds and
// comes back stone cold.
//
// FIVE BANDS, each a flat damage rate:
//
//     heat     DPS     what it is
//     0-20      80     the sweeping band
//     20-40    140
//     40-60    240
//     60-80    420
//     80-100   750     the boss band
//
// Roughly x1.75 per rung, x9.4 end to end.
//
// WHY THIS CUTS FODDER LIKE A SHOTGUN BUT MAKES BOSSES A SIEGE, and it is
// not two systems -- it is one curve read from both ends:
//
//   A zombieman is 20hp and dies in a quarter second in band 1. An imp is
//   60hp, three quarters of a second. You never leave the bottom band, so
//   sweeping a room of fodder costs almost NO HEAT -- the gun is still cold
//   when the room is empty. That is the shotgun feeling: point, they fall,
//   move on.
//
//   A Baron is 1000hp. Band 1 would need twelve and a half seconds and you
//   cook off at four, so band 1 CANNOT kill it -- the weapon physically
//   cannot brute-force a boss from cold. You have to climb, and climbing
//   means holding, and holding is the thing that overheats you.
//
//   A full four-second hold from cold to cook-off delivers about 1300
//   damage, of which the top band alone is 600. So nearly half a full
//   burn's output lives in the last four fifths of a second, and reaching
//   it costs you the five-second lockout if you misjudge by a hair.
//
// A Cyberdemon at 4000hp is three full burns and two lockouts: roughly
// twenty-five seconds of committed, exposed, cannot-move-freely fire. Which
// is the whole point, because the beam is also a flare that tells the room
// exactly where you are standing.
// ---------------------------------------------------------------------
//
// TWO HANDS, TWO BEAMS. LNC_Lance is mainhand and LNC_LanceOffhand is
// offhand. Each owns its own beam slot and its own heat, so firing one
// never disturbs the other -- which is why stopping releases only its own
// slot rather than calling ClearBeams(). Alternating hands is a real
// technique: one cools while the other burns.
//
// ENGINE DEPENDENCY, stated plainly: Level.SetBeam / SetBeamCount /
// SetBeamLook are natives of this fork, and the tracked-hand positions
// (AttackPos / OffhandPos / OverrideAttackPosDir) come from its VR lineage.
// On stock GZDoom this file does not compile. That is the deal.
// =====================================================================

class LNC_Lance : Weapon
{
	// HEAT IS THE WEAPON, and it is the only resource. Everything visible
	// and everything damaging derives from it. A double rather than an int
	// because the rates are per-second and the bands need to be crossed
	// smoothly, not in whole-number jumps.
	double heat;          // 0 .. LNC_HEAT_MAX

	// Tics remaining in the post-cook-off lockout. Counted down in DoEffect
	// so it runs whether or not the weapon is selected -- switching hands to
	// dodge your own cooldown would defeat the entire cost.
	int lockTics;

	bool firing;          // was the beam live last tic, for edge detection

	// Fractional damage carried between tics. Doom's damage is an integer
	// event but a beam's damage is a rate; this is where the remainder
	// lives so the rate comes out exact rather than truncated to nothing.
	double burn;

	// GEAR-CHANGE PUNCH. Crossing into a new band is the most important
	// thing that happens to this weapon while you hold it, and a colour
	// swap alone is easy to miss when you are looking at what you are
	// killing. Band changes therefore flash: the whole beam goes white and
	// fat for a few tics. Reads in peripheral vision, which is where you
	// actually are.
	int lastBand;
	int flashTics;

	// ---- the heat model, all of it -------------------------------------
	const LNC_HEAT_MAX  = 100.0;
	const LNC_HEAT_RISE = 25.0;    // per second firing -> 4.0s cold to max
	const LNC_HEAT_FALL = 12.5;    // per second idle   -> 8.0s max to cold
	const LNC_LOCKOUT   = 175;     // tics -- a flat 5.0 seconds

	const LNC_RANGE     = 2200.0;

	// THE SYNTHETIC MUZZLE. In VR the tracked controller is a real world
	// position; on a desktop the weapon is a screen overlay with no world
	// position at all, so the point the beam appears to leave has to be
	// built relative to the eye. These three are the tuning knobs: right and
	// up put the beam at the gun in the corner rather than in the middle of
	// your face, forward keeps its halo off the camera.
	const LNC_MUZZLE_FWD   = 16.0;
	const LNC_MUZZLE_RIGHT = 10.0;
	const LNC_MUZZLE_UP    = -8.0;

	Default
	{
		Tag "Lance";
		Weapon.SelectionOrder 1080;
		Weapon.SlotNumber 6;

		// NO AMMO, AT ALL. Not zero-cost ammo -- no ammo type. Heat is the
		// only thing that stops you firing, which is what makes it the only
		// thing worth thinking about.
		Weapon.AmmoUse 0;
		Weapon.AmmoGive1 0;
		Weapon.AmmoType1 "";

		Inventory.PickupMessage "You got the Lance!";
		Inventory.Icon "PLASA0";
		+WEAPON.NOHANDSWITCH;
		+WEAPON.AMMO_OPTIONAL;
		+WEAPON.NOALERT;

		// Where the beam leaves the gun in VR. Stock property of this fork's
		// Weapon class; the engine's own laser sight reads it too, so setting
		// it here moves both together. COMPONENT ORDER IS NOT XYZ --
		// hw_weapon.cpp applies .Y along FORWARD and .X sideways.
		Weapon.LaserBeamOffset (0.0, 22.0, 0.0);
	}

	// 0 at stone cold, 1 at cook-off. Drives every visual.
	clearscope double Charge() const
	{
		return clamp(heat / LNC_HEAT_MAX, 0.0, 1.0);
	}

	// Heat as the 0-100 number, for a HUD or a readout.
	clearscope int HeatPercent() const
	{
		return int(clamp(heat, 0.0, LNC_HEAT_MAX) + 0.5);
	}

	// Which of the five bands, 0-4. Exposed because the visuals step with
	// it as well -- the beam should look like it changed gear, not merely
	// like it got slightly brighter.
	clearscope int Band() const
	{
		if (heat < 20.0) return 0;
		if (heat < 40.0) return 1;
		if (heat < 60.0) return 2;
		if (heat < 80.0) return 3;
		return 4;
	}

	// FLAT WITHIN EACH BAND, as specified. Not a smooth curve: the steps are
	// the point. You should be able to FEEL the gear change -- a smooth ramp
	// gives you no moment to recognise, so there is nothing to aim for and
	// nothing to hold at.
	//
	// x1.75 per rung. See the header for why this shape splits fodder from
	// bosses without needing a second system to do it.
	double DPS() const
	{
		switch (Band())
		{
			case 0:  return 80.0;
			case 1:  return 140.0;
			case 2:  return 240.0;
			case 3:  return 420.0;
			default: return 750.0;
		}
	}

	// ---- BEAM SLOT BUDGET ----------------------------------------------
	//
	// Eight slots exist, level-global, and each one costs a per-pixel
	// segment test across the whole screen -- twice, once for surface
	// lighting and once for the glow in the air. So they are a budget, not
	// a free ceiling, and this weapon spends all of it:
	//
	//     0        mainhand core beam
	//     1        offhand core beam
	//     2,3,4    mainhand helix
	//     5,6,7    offhand helix
	//
	// Three chords is a coarse helix -- each spans 120 degrees of the turn
	// -- but chords are exactly what a beam slot IS, and three rotating
	// ones read as a twisting ribbon wrapped round the core rather than as
	// a triangle. Splitting them evenly rather than giving one hand a finer
	// spiral keeps the two hands identical, which matters more.
	int BeamSlot()
	{
		if (owner && owner.player && owner.player.OffhandWeapon == self) return 1;
		return 0;
	}

	int HelixBase() { return BeamSlot() == 1 ? 5 : 2; }
	const LNC_HELIX_CHORDS = 3;

	// ---- the spiral -----------------------------------------------------
	//
	// A helix around the beam axis, drawn as a chain of straight chords --
	// the Quake 2 railgun trick, except these are real lights that brighten
	// the walls they pass, not a sprite trail.
	//
	// Consecutive chords share endpoints, so the polyline is CONTINUOUS: no
	// gaps to read as beads. It faceted rather than curved, which at this
	// thickness and glow is invisible.
	//
	// THE BASIS IS BUILT FROM THE AXIS AND NOTHING ELSE. No hand matrices,
	// no cvars, no engine conventions to mirror -- just "any two directions
	// perpendicular to this line". Getting it wrong can only make the
	// spiral wobble; it cannot move the core beam, which is drawn from
	// `from` and `to` directly and never touches this.
	void DrawHelix(Vector3 a, Vector3 b, double radius, double turns,
		double phase, Color col, double thick, double soft, double inten)
	{
		Vector3 axis = b - a;
		double len = axis.Length();
		if (len < 2.0) return;
		axis /= len;

		// Any perpendicular will do. Cross with world up unless the beam IS
		// world up, in which case cross with something else.
		Vector3 u = ((0, 0, 1) cross axis);
		if (u dot u < 1e-6) u = ((1, 0, 0) cross axis);
		double ul = u.Length();
		if (ul < 1e-6) return;
		u /= ul;
		Vector3 v = (axis cross u);      // unit by construction: both unit, perpendicular

		int base = HelixBase();
		for (int i = 0; i < LNC_HELIX_CHORDS; i++)
		{
			double t0 = double(i) / LNC_HELIX_CHORDS;
			double t1 = double(i + 1) / LNC_HELIX_CHORDS;
			double a0 = phase + turns * 360.0 * t0;
			double a1 = phase + turns * 360.0 * t1;

			Vector3 p0 = a + axis * (len * t0) + (u * cos(a0) + v * sin(a0)) * radius;
			Vector3 p1 = a + axis * (len * t1) + (u * cos(a1) + v * sin(a1)) * radius;

			level.SetBeam(base + i, p0, p1, thick, soft, col, inten);
		}
	}

	void ClearHelix()
	{
		int base = HelixBase();
		for (int i = 0; i < LNC_HELIX_CHORDS; i++)
			level.SetBeam(base + i, (0, 0, 0), (0, 0, 0), 0.01, 0.01, 0, 0.0);
	}

	// ---- colour ---------------------------------------------------------
	//
	// Five bands, five genuinely different colours rather than five steps
	// along one ramp -- the band is information and it should be readable at
	// a glance, in peripheral vision, while you are looking at something
	// else. A blue beam and an orange beam are not the same weapon.
	//
	// Blue to cyan to white is "cold and building"; gold to furnace-red is
	// "this is about to cost you". The core carries the heat, and the helix
	// carries the contrast against it.
	Color CoreColor() const
	{
		switch (Band())
		{
			case 0:  return 0x1E6BFF;   // deep electric blue
			case 1:  return 0x00E5FF;   // cyan
			case 2:  return 0xEAFFFF;   // hard white, faintly cold
			case 3:  return 0xFFD21E;   // gold
			default: return 0xFF3C00;   // furnace
		}
	}

	// Deliberately NOT a lighter version of the core. The spiral should be a
	// separate object wrapped around the beam, and the only way three thin
	// chords read as separate at speed is if they are a different colour.
	// The top band's magenta on furnace-red is the loudest thing the weapon
	// ever does, which is correct: it is also the most dangerous.
	Color HelixColor() const
	{
		switch (Band())
		{
			case 0:  return 0x9FD8FF;   // pale blue
			case 1:  return 0xC8FFF4;   // pale aqua
			case 2:  return 0xFFE79A;   // warm gold against the white core
			case 3:  return 0xFF7A18;   // orange against gold
			default: return 0xFF00B4;   // magenta against furnace
		}
	}

	// ---- the beam ------------------------------------------------------
	//
	// Called once per tic while the trigger is down. Traces, draws, burns.
	action void A_LanceBeam()
	{
		let w = LNC_Lance(invoker);
		if (!w || !self || !player) return;

		// Heat climbs from the very first tic. There is no free window --
		// with no ammo, heat is the only cost the weapon has, so nothing
		// about firing may be free.
		w.heat += LNC_HEAT_RISE / 35.0;

		if (w.heat >= LNC_HEAT_MAX)
		{
			w.Overheat(self);
			return;
		}

		// WHERE IT ENDS -- and this trace does NO damage.
		//
		// TRF_THRUACTORS on purpose: the beam is DRAWN to the wall behind
		// whatever it is burning through, not stopped short at the first
		// monster. The damage trace below is a separate question.
		//
		// TRF_USEWEAPON is what makes it a weapon ray rather than a head
		// ray: without it P_LineTrace ignores the tracked hand and traces
		// from body yaw/pitch at eye height. TRF_ISOFFHAND only when this
		// copy is the offhand, or it would trace from the other controller.
		int trf = TRF_THRUACTORS | TRF_USEWEAPON;
		if (w.BeamSlot() == 1) trf |= TRF_ISOFFHAND;

		// player.viewheight is still needed: P_LineTrace only reaches for
		// AttackPos when OverrideAttackPosDir is set, and otherwise falls
		// through to `fromPos = t1->PosAtZ(startz)` built from this offset.
		// Drop it and that branch starts the trace at the FLOOR.
		FLineTraceData d;
		bool hit = LineTrace(angle, LNC_RANGE, pitch, trf, player.viewheight, data: d);

		bool offhand = w.BeamSlot() == 1;
		Vector3 from = offhand ? OffhandPos : AttackPos;

		// THE DIRECTION COMES FROM THE TRACE, NOT FROM A SECOND CALCULATION.
		// HitDir is the unit direction P_LineTrace actually travelled, filled
		// unconditionally. Reconstructing it independently is a bug this
		// weapon has shipped twice; the second time it drew the beam at
		// ninety degrees to the gun. Normalised defensively because "is this
		// unit length" was the unchecked assumption under both.
		Vector3 dir = d.HitDir;
		double dirLen = dir.Length();
		dir = (dirLen > 0.001) ? dir / dirLen : (0, 0, 0);

		// ON A MISS, d.HitLocation IS THE MAP ORIGIN (0,0,0), NOT "NO
		// ANSWER" -- P_LineTrace zeroes its struct and only fills the field
		// through the successful branch. Firing at open sky would otherwise
		// aim the beam at world origin.
		Vector3 to;
		if (hit)                        to = d.HitLocation;
		else if (dir dot dir > 1e-8)    to = from + dir * LNC_RANGE;
		else { w.Release(self); return; }

		// THE BEAM LEAVES THE BARREL. `from` is the controller in VR and the
		// EYE on a desktop (VRMode::SetUp's else branch sets AttackPos to
		// PosAtZ(shootz)) -- and on a desktop the gun is a screen overlay
		// with no world position, so the muzzle has to be built: eye, pushed
		// forward, right and down to where the weapon is actually drawn.
		// Plain degree trig on the body angles, which are the aim. Doom
		// convention: angle 0 is +X, 90 is +Y, positive pitch looks DOWN.
		Vector3 drawFrom;
		double hitDist = (to - from).Length();

		if (OverrideAttackPosDir)
		{
			double frac = (hitDist > 0.001)
				? clamp(w.LaserBeamOffset.Y / hitDist, 0.0, 0.5) : 0.0;
			drawFrom = from + (to - from) * frac;
		}
		else
		{
			double ca = cos(angle), sa = sin(angle);
			double cp = cos(pitch), sp = sin(pitch);
			Vector3 fwd   = (ca * cp, sa * cp, -sp);
			Vector3 right = (sa, -ca, 0);
			drawFrom = from
				+ fwd * min(LNC_MUZZLE_FWD, hitDist * 0.5)
				+ right * LNC_MUZZLE_RIGHT
				+ (0, 0, 1) * LNC_MUZZLE_UP;
		}

		// ---- shape ---------------------------------------------------------
		double charge = w.Charge();
		int band = w.Band();

		// THE GEAR CHANGE. Crossing a band is the event that matters most
		// while the trigger is down, so it gets its own punch rather than
		// relying on you noticing a colour swap in your periphery.
		if (band != w.lastBand)
		{
			if (band > w.lastBand) w.flashTics = 5;
			w.lastBand = band;
		}
		double flash = w.flashTics > 0 ? double(w.flashTics) / 5.0 : 0.0;
		if (w.flashTics > 0) w.flashTics--;

		// THE BEAM STEPS WITH THE BAND, not smoothly with heat. The damage
		// changes in gears, so the look changes in gears -- a beam that grew
		// imperceptibly would give you nothing to read, and reading it is
		// how you know when to let go. Within a band it still creeps a
		// little so it never looks frozen.
		double step = double(band);
		double thick = 1.2 + 0.95 * step + 0.30 * charge + 2.2 * flash;
		double soft  = 1.5 + 1.15 * step + 0.40 * charge + 2.6 * flash;

		// INTENSITY STAYS UNDER 1.0 UNTIL THE TOP BAND. The fork's beam doc
		// notes the air glow feeds bloom by itself "since a core burning past
		// white is exactly what the bloom pass thresholds for". So the screen
		// only blooms out in band 5, where it is the warning rather than the
		// weapon's baseline appearance -- and for the few tics of a gear
		// change, where blowing out IS the announcement.
		double inten = 0.34 + 0.17 * step + 0.55 * flash;

		// The colour IS the gauge; you read your heat off the beam without
		// looking away from what you are killing. Washed toward white for the
		// duration of a gear change.
		Color col = LNC_Lance.LerpCol(w.CoreColor(), 0xFFFFFF, flash);

		// FRAME-GLOBAL, BOTH OF THESE. SetBeamCount's glow term and every
		// SetBeamLook value cover EVERY beam in the scene -- they are single
		// vec4s in the viewpoint block, not arrays. If a second beam user
		// ever exists, these want one owner rather than each actor stomping
		// the others every tic.
		// EIGHT, because the helix lives in the upper six. Unused slots are
		// zeroed on release rather than left holding stale endpoints, or a
		// holstered hand's spiral would keep being drawn.
		level.SetBeamCount(8, 0.28, 1.0);

		level.SetBeamLook(
			0.45 + 0.55 * charge,         // air glow

			// SCROLL SPEED is irrelevant while depth is zero, but kept
			// non-zero so turning depth back on does not also need this.
			6.0,

			// SCROLL DEPTH: ZERO, AND IT STAYS ZERO.
			//
			// This is the beading. main.fp does
			//     bright *= 1.0 + uBeamFX.y * sin(along * 0.06 - timer*speed)
			// and that sine is the ONLY periodic term in the entire beam
			// shader -- BeamLightAt, the surface half, is pure distance
			// falloff with nothing repeating in it. Wavelength is
			// 2*pi/0.06 ~= 105 world units, so across a room it is about ten
			// bright/dark bands: (gun) -0-0-0-0-0-. Reducing it only made
			// them fainter, which is not the same as a beam. A capital-ship
			// lance is one solid unbroken bar, and the shader draws exactly
			// that the moment this is switched off. The engine skips the
			// whole block on zero, so this is genuinely off, not small.
			0.0,

			0.45 - 0.30 * charge,         // taper, slackening as it heats
			1.2 + 0.35 * step);           // impact flare, stepping with band

		level.SetBeam(w.BeamSlot(), drawFrom, to, thick, soft, col, inten);

		// ---- THE SPIRAL -----------------------------------------------------
		//
		// Not present in band 0. That is deliberate and it is the single best
		// thing about it: a cold beam is one clean thin line, and the spiral
		// APPEARS the moment you gear up. So the weapon visibly grows a
		// second component rather than merely getting brighter, and you can
		// see at a glance whether the thing in your hands is the sweeping
		// tool or the boss-killer.
		//
		// It tightens, widens and spins faster with every band. At the top it
		// is a magenta braid whipping around a furnace-red core, which is
		// exactly as subtle as a weapon that is two thirds of a second from
		// cooking off should be.
		if (band > 0)
		{
			// Spin is in degrees per tic and steps hard with the band, so
			// gearing up is audible in the eye as well: the whole spiral
			// jumps to a new speed.
			double spin  = Level.maptime * (7.0 + 5.0 * step);
			double radius = 1.8 + 1.15 * step + 3.0 * flash;
			double turns  = 0.85 + 0.30 * step;

			w.DrawHelix(drawFrom, to, radius, turns, spin,
				LNC_Lance.LerpCol(w.HelixColor(), 0xFFFFFF, flash),
				0.45 + 0.22 * step,               // thin: it is a filament
				0.70 + 0.45 * step + 1.2 * flash, // but it glows generously
				0.30 + 0.14 * step + 0.5 * flash);
		}
		else
		{
			w.ClearHelix();
		}

		// THE VOLUMETRIC LAYER -- the air around the beam, not the beam.
		//
		// SetBeam draws a line that lights the room. SetVolumetricBeam is a
		// different system: a raymarched cone that makes the air itself glow.
		// Aimed straight down the beam with a pencil-thin cone it stops being
		// a bright line and becomes something displacing atmosphere.
		//
		// MAINHAND ONLY. Unlike the eight beam slots this is a SINGLE global
		// on the level, so two hands would overwrite each other every tic and
		// flicker. The offhand still has its own real beam in slot 1.
		//
		// DUST IS ZERO. Motes are, definitionally, points of light, and
		// points of light along the beam are the exact thing being hunted out
		// of this weapon. If it comes back it comes back as atmosphere in the
		// ROOM, never as texture on the bar.
		if (!offhand)
		{
			Vector3 vseg = to - drawFrom;
			double vlen = vseg.Length();
			if (vlen > 1.0)
			{
				level.SetVolumetricBeam(
					drawFrom, vseg / vlen, col,
					0.25 + 0.30 * charge,     // inner cone half-angle, degrees
					1.10 + 1.40 * charge,     // outer
					vlen,                     // exactly the segment
					0.28 + 0.40 * charge,     // density
					1.6,                      // falloff, tight near the lens
					0.0,                      // dust: see above
					0.045,
					0.0);
			}
		}

		// Started once on the trigger edge and pitched every tic after, so
		// the approaching cook-off is audible before it is visible -- you are
		// usually looking at what you are burning, not at the beam.
		if (!w.firing)
		{
			A_StartSound("lnc/charge", CHAN_WEAPON, 0, 0.7);
			A_StartSound("lnc/loop", CHAN_5, CHANF_LOOPING, 0.8, ATTN_NORM);
			w.firing = true;
		}
		A_SoundPitch(CHAN_5, 0.85 + 0.55 * charge);

		// ---- the burn --------------------------------------------------
		//
		// NO SHOTS. The beam is on, and while it is on it deposits energy at
		// a rate. The rate is accumulated as a real number and spent when it
		// builds a whole point, so the fiction is continuous and only the
		// bookkeeping is not.
		//
		// A SECOND TRACE, without TRF_THRUACTORS, so it stops at the first
		// thing in the way -- the drawing trace above deliberately passes
		// through actors to reach the wall behind them, which is right for
		// the picture and wrong for the damage.
		int dtrf = TRF_USEWEAPON;
		if (offhand) dtrf |= TRF_ISOFFHAND;
		FLineTraceData hitData;
		LineTrace(angle, LNC_RANGE, pitch, dtrf, player.viewheight, data: hitData);

		Actor victim = hitData.HitActor;
		if (!victim || !victim.bShootable)
		{
			// Nothing in the beam. Drop the remainder rather than banking it,
			// or sweeping onto a target would hand it a stored-up lump.
			w.burn = 0;
			return;
		}

		w.burn += w.DPS() / 35.0;
		int whole = int(w.burn);
		if (whole <= 0) return;
		w.burn -= whole;

		// DMG_NO_PAIN, or a held beam pins a monster in its pain state
		// permanently and it never acts again -- which trivialises every
		// fight and looks broken besides. It still bleeds and still dies.
		victim.DamageMobj(self, self, whole, 'Hitscan', DMG_NO_PAIN);

		if (Random(0, 11) == 0)
			A_StartSound("lnc/sizzle", CHAN_AUTO, CHANF_DEFAULT, 0.3);
	}

	// Trigger released, or the state machine left Fire. Put the beam away.
	action void A_LanceStop()
	{
		let w = LNC_Lance(invoker);
		if (!w) return;
		w.Release(self);
	}

	// Releases only THIS hand's slot rather than calling ClearBeams, or
	// firing the mainhand would blink the offhand's beam out every tic.
	void Release(Actor who)
	{
		if (firing)
		{
			// CHAN_5, MATCHING THE LOOP. Stopping a different channel than
			// the loop was started on leaves it running forever.
			if (who) who.A_StopSound(CHAN_5);
			firing = false;
		}
		level.SetBeam(BeamSlot(), (0, 0, 0), (0, 0, 0), 0.01, 0.01, 0, 0.0);

		// This hand's three helix chords too. The count stays at 8 once
		// anything has fired, so a slot left holding real endpoints would go
		// on being drawn after the trigger came up.
		ClearHelix();

		// The volumetric layer is a single global with no slot to zero, so it
		// must be switched off explicitly -- and only by the hand that
		// claimed it, or the offhand releasing would kill the mainhand's.
		if (BeamSlot() == 0)
			level.ClearVolumetricBeam();

		// Heat is NOT reset. That is the whole pulse-fire technique: the band
		// you climbed to survives the release and only bleeds off with time.
		burn = 0;
	}

	void Overheat(Actor who)
	{
		Release(who);
		heat = LNC_HEAT_MAX;
		lockTics = LNC_LOCKOUT;
		if (who) who.A_StartSound("lnc/cookoff", CHAN_WEAPON, 0, 1.0);
	}

	// COOK-OFF IS A FLAT FIVE SECONDS AND THEN STONE COLD, rather than a
	// slow bleed down from 100. A bleed would let you cook off and go
	// straight back to band 4, which makes overheating nearly free; a hard
	// reset means the mistake costs you the entire climb as well as the five
	// seconds.
	//
	// Ordinary cooling is half the rise rate -- 8 seconds from full -- so
	// short bursts cost almost nothing and long holds genuinely commit.
	//
	// COUNTED IN DoEffect so it runs whether or not the weapon is selected.
	// Switching to your other hand while this one cools is intended (that is
	// the two-hand rhythm), but switching AWAY must not pause the timer, or
	// the lockout would be free.
	override void DoEffect()
	{
		Super.DoEffect();

		// SAFETY: the beam lives in a level-global slot, so anything that
		// ends a trigger pull without running the Beam state's exit -- dying
		// mid-burst, a forced swap, a telefrag -- would leave a live segment
		// hanging in the world with a looping sound under it. The state
		// machine cannot cover those; DoEffect runs regardless.
		if (firing && owner)
		{
			bool stillUp = owner.health > 0 && owner.player
				&& (owner.player.ReadyWeapon == self
					|| owner.player.OffhandWeapon == self);
			if (!stillUp) Release(owner);
		}

		if (lockTics > 0)
		{
			lockTics--;
			heat = LNC_HEAT_MAX;              // pinned, and the HUD should say so
			if (lockTics <= 0) heat = 0.0;    // then all the way back
			return;
		}

		if (!firing && heat > 0.0)
		{
			heat = max(0.0, heat - LNC_HEAT_FALL / 35.0);
		}
	}

	static Color LerpCol(int a, int b, double t)
	{
		t = clamp(t, 0.0, 1.0);
		int ar = (a >> 16) & 255, ag = (a >> 8) & 255, ab = a & 255;
		int br = (b >> 16) & 255, bg = (b >> 8) & 255, bb = b & 255;
		return Color(255,
			int(ar + (br - ar) * t),
			int(ag + (bg - ag) * t),
			int(ab + (bb - ab) * t));
	}

	States
	{
	Spawn:
		PLAS A -1;
		Stop;

	Ready:
		PLSC A 1 A_WeaponReady(WRF_NOSECONDARY);
		Loop;

	Deselect:
		TNT1 A 0 A_LanceStop();
		PLSC A 1 A_Lower;
		Loop;

	Select:
		PLSC A 1 A_Raise;
		Loop;

	// No ammo check. Heat is the only gate.
	Fire:
		TNT1 A 0 A_JumpIf(invoker.lockTics > 0, "Overheated");
		Goto Beam;

	// ONE TIC PER LOOP. The beam is re-traced and re-drawn every tic, which
	// is what makes it track as you turn rather than lagging behind the
	// crosshair like a spawned object would.
	Beam:
		PLSF A 1 Bright A_LanceBeam();
		TNT1 A 0 A_ReFire("Beam");
		TNT1 A 0 A_LanceStop();
		Goto Ready;

	// SHORTER THAN THE LOCKOUT, DELIBERATELY -- 28 tics against 175. Holding
	// the trigger through a cook-off cycles this rather than sitting in one
	// long uninterruptible pose, so the gun returns to Ready often enough to
	// be DESELECTED. The punishment is "you have no beam", not "you have no
	// inputs" -- and swapping to your other hand while this one cools is the
	// intended answer, not an exploit.
	Overheated:
		TNT1 A 0 A_LanceStop();
		TNT1 A 0 A_StartSound("lnc/empty", CHAN_AUTO, 0, 0.6);
		PLSC C 28;
		Goto Ready;
	}
}

// The offhand copy. Same weapon; the flag is what puts it in the other hand,
// which in turn is what BeamSlot() reads to claim beam slot 1. Its heat is
// its own -- alternating hands so one cools while the other burns is the
// intended rhythm of dual-wielding these.
class LNC_LanceOffhand : LNC_Lance
{
	Default
	{
		Tag "Lance (offhand)";
		Weapon.SelectionOrder 1079;
		+WEAPON.OFFHANDWEAPON;
	}
}

// =====================================================================
// LNC_Startup -- you spawn holding both of them.
//
// Registered from MAPINFO's gameinfo block rather than by replacing the
// player class, so this pk3 still steals nothing from whatever else is
// loaded: no weapon slot taken, no existing actor overridden.
// =====================================================================
class LNC_Startup : EventHandler
{
	override void PlayerEntered(PlayerEvent e)
	{
		let pmo = players[e.PlayerNumber].mo;
		if (!pmo) return;

		// Two separate classes: the offhand copy is what claims beam slot 1,
		// so you need both to dual-wield. No ammo -- there is none.
		pmo.A_GiveInventory("LNC_Lance", 1);
		pmo.A_GiveInventory("LNC_LanceOffhand", 1);

		// Seat them in both hands rather than leaving the offhand in the
		// backpack waiting to be selected.
		let p = players[e.PlayerNumber];
		let main = Weapon(pmo.FindInventory("LNC_Lance"));
		let off  = Weapon(pmo.FindInventory("LNC_LanceOffhand"));
		if (main) p.PendingWeapon = main;
		if (off)  p.OffhandWeapon = off;
	}
}
