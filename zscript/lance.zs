// =====================================================================
// THE LANCE -- a real beam weapon for the UZDXREMA engine fork.
//
// Standalone extraction of RS_Main's RS_LaserGun. Same weapon, same feel,
// none of RS_Main: no affix system, no attack-profile assembly, no
// GunBonsai bridge, no stat rolls, no shared FX catalog. It descends from
// plain Weapon and does its own damage, so it drops into any mod.
//
// WHAT MAKES IT A BEAM AND NOT A FAST HITSCAN. The engine fork draws it by
// lighting every pixel by its distance from the segment -- Level.SetBeam,
// FORK_CHANGES.md section 13. So it is not a sprite and not a chain of
// puffs: it is continuous at any length, it wraps floor/wall/ceiling as
// one unbroken object, it is visible hanging in the air, it correctly
// vanishes behind walls, and the surfaces near it brighten because they
// ARE near it. Nothing extra is spawned to fake any of that.
//
// AND THAT IS THE WEAPON'S REAL COST. In a dark map you can see twenty
// metres; the moment you fire, a line of white light hangs in the air
// lighting the corridor and you standing in it. Pulling the trigger is a
// tactical disclosure. The damage is balanced knowing that.
//
// ONE CURVE. Everything -- damage, rate of fire, colour, width,
// brightness, sound pitch, even how long the next pull takes to spin up --
// is derived from CHARGE, which is heat/LNC_OVERHEAT, 0 to 1.
//
//   HOLDING RAMPS YOU UP.  0.4x damage cold, 3.0x at the edge of overheat,
//                          on a back-loaded curve, and the cadence tightens
//                          from every 4 tics to every 2. Together: about
//                          14 DPS the instant the beam bites, about 210 at
//                          the top.
//
//   RELEASING KEEPS IT.    Heat bleeds at half the rate it builds, so a
//                          short pulse costs almost none of the ramp.
//                          Pulse the trigger to sit just under cook-off
//                          and hold peak damage indefinitely.
//
//   RE-PULLING COSTS.      Every pull pays a spin-up before it damages
//                          anything -- but the spin-up SHORTENS with charge
//                          (14 tics cold, 3 hot), because a hot emitter
//                          relights fast.
//
//   COOKING OFF HURTS.     Past 1.0 the beam cuts and the weapon vents,
//                          locked, all the way back to stone cold.
//
// TWO HANDS, TWO BEAMS. LNC_Lance is mainhand and LNC_LanceOffhand is
// offhand. Each owns its own beam slot, so firing one never disturbs the
// other -- which is why stopping releases only its own slot rather than
// calling ClearBeams().
//
// ENGINE DEPENDENCY, stated plainly: Level.SetBeam / SetBeamCount /
// SetBeamLook are natives of this fork, and the tracked-hand positions
// (AttackPos / OffhandPos / OverrideAttackPosDir) come from its VR
// lineage. On stock GZDoom this file does not compile. That is the deal.
// =====================================================================

class LNC_Lance : Weapon
{
	// heat IS THE WEAPON. Everything visible and everything damaging is
	// derived from it. It survives a trigger release on purpose; that is
	// the entire pulse-fire technique.
	int heat;

	// Tics THIS pull has been held. Unlike heat this does reset on
	// release, because it exists only to time the spin-up, which is a
	// per-pull commitment cost rather than a property of the weapon.
	int held;

	bool locked;      // cooked off: refuses to fire until stone cold
	bool firing;      // was the beam live last tic, for edge detection

	// HEAT UNITS, not tics -- the two rates differ, so a tic count could
	// not express both. 280 at +2/tic is a 4.0s hold from cold to
	// cook-off.
	const LNC_OVERHEAT = 280;
	const LNC_HEATRATE = 2;     // per tic, trigger down
	const LNC_COOLRATE = 1;     // per tic, trigger up -- half, deliberately
	const LNC_VENTRATE = 3;     // per tic while locked out after a cook-off

	const LNC_SPINUP   = 14;    // 0.4s cold, ~0.1s hot
	const LNC_RANGE    = 2200.0;

	// Base damage per shot before the charge ramp. RS_Main rolls this per
	// weapon instance from its tier tables; standalone it is a constant so
	// the weapon has no hidden state and behaves identically every pickup.
	const LNC_DAMAGE   = 4;

	Default
	{
		Tag "Lance";
		Weapon.SelectionOrder 1080;
		Weapon.SlotNumber 6;
		Weapon.AmmoUse 0;        // spent manually per beam pulse, see A_LanceBeam
		Weapon.AmmoGive1 60;
		Weapon.AmmoType1 "Cell";
		Inventory.PickupMessage "You got the Lance!";
		Inventory.Icon "PLASA0";
		+WEAPON.NOHANDSWITCH;

		// WHERE THE BEAM LEAVES THE GUN. Stock property of this fork's
		// Weapon class; the engine's own VR laser sight reads it too, so
		// setting it here moves both together.
		//
		// COMPONENT ORDER, AND IT IS NOT XYZ: hw_weapon.cpp applies .Y
		// along FORWARD and .X sideways (see the long note in A_LanceBeam).
		// So this is "22 units out along the barrel, dead centre, on axis".
		// THIS IS THE ONE NUMBER TO TUNE if the origin looks wrong.
		Weapon.LaserBeamOffset (0.0, 22.0, 0.0);
	}

	// The one number. 0 = cold, 1 = about to cook off.
	clearscope double Charge() const
	{
		return clamp(double(heat) / double(LNC_OVERHEAT), 0.0, 1.0);
	}

	// A HOT EMITTER RELIGHTS FAST. Without this, pulse-firing would pay the
	// full 0.4s dead window on every pull and the technique the heat model
	// exists to enable would be strictly worse than just holding.
	int SpinupNeeded() const
	{
		return int(LNC_SPINUP * (1.0 - 0.75 * Charge()));
	}

	// DAMAGE, BACK-LOADED. c^1.5 rather than linear so the top of the ramp
	// is somewhere you have to genuinely commit to reach -- a linear curve
	// hands out most of the payoff in the first second, which would make
	// tapping optimal and the sustained beam pointless.
	double DamageMult() const
	{
		double c = Charge();
		return 0.40 + 2.60 * (c * sqrt(c));
	}

	// AND THE RATE CLIMBS TOO. Integer tic steps rather than a smooth
	// function because the cadence is checked against Level.maptime and a
	// fractional interval cannot be. 4 tics = 8.75/s, 2 tics = 17.5/s.
	int FireInterval() const
	{
		double c = Charge();
		if (c < 0.50) return 4;
		if (c < 0.85) return 3;
		return 2;
	}

	// Which beam slot this gun owns. Two hands, two slots, so one hand's
	// beam can never blink the other's out.
	int BeamSlot()
	{
		if (owner && owner.player && owner.player.OffhandWeapon == self) return 1;
		return 0;
	}

	// ---- the beam itself -------------------------------------------------
	//
	// Called once per tic while the trigger is down. Traces, draws, damages.
	action void A_LanceBeam()
	{
		let w = LNC_Lance(invoker);
		if (!w || !self || !player) return;

		w.held++;
		w.heat += LNC_HEATRATE;

		if (w.heat >= LNC_OVERHEAT)
		{
			w.Overheat(self);
			return;
		}

		// WHERE IT ENDS -- and this trace does NO damage.
		//
		// It answers "what is the beam's far end", a geometry question, and
		// hands back the exact direction it used so the damage below can
		// travel the identical ray. Two questions, one trace.
		//
		// TRF_THRUACTORS on purpose: the beam should be drawn to the WALL
		// behind whatever it is burning through, not stop short at the
		// first monster.
		//
		// TRF_USEWEAPON is what makes it a VR weapon rather than a head
		// weapon. Without it, P_LineTrace ignores the tracked hand entirely
		// and traces from `angle`/`pitch` (BODY yaw/pitch) starting at eye
		// height -- so the drawn beam would aim wherever the HEAD looked
		// while the gun model aimed wherever the HAND did. With it,
		// fromPos becomes AttackPos/OffhandPos and the direction comes from
		// the hand's matrix. Passing `angle`/`pitch` UNCHANGED is correct:
		// AttackDir internally subtracts the actor's own body angle/pitch
		// before applying the hand transform, so the subtraction nets to
		// zero and no deviation is added. TRF_ISOFFHAND only when this copy
		// is the offhand Lance, or an offhand shot traces from the mainhand
		// controller.
		int trf = TRF_THRUACTORS | TRF_USEWEAPON;
		if (w.BeamSlot() == 1) trf |= TRF_ISOFFHAND;

		// player.viewheight IS STILL NEEDED even though the VR branch above
		// ignores it. P_LineTrace only reaches for AttackPos/OffhandPos when
		// OverrideAttackPosDir is actually set (a real headset, or
		// vr_override_weap_pos); flat/desktop play falls through to
		// P_LineTrace's OTHER branch, `fromPos = t1->PosAtZ(startz)`, where
		// startz is built from this offset. Drop it and that branch starts
		// the trace at the FLOOR instead of the eye.
		FLineTraceData d;
		bool hit = LineTrace(angle, LNC_RANGE, pitch, trf, player.viewheight, data: d);

		bool offhand = w.BeamSlot() == 1;
		Vector3 from = offhand ? OffhandPos : AttackPos;

		// THE DIRECTION COMES FROM THE TRACE, NOT FROM A SECOND CALCULATION.
		//
		// FLineTraceData.HitDir is trace.HitVector (p_map.cpp:5404), the
		// unit direction P_LineTrace actually travelled -- already through
		// the VR branch that swaps in the tracked hand's matrix. It is
		// filled unconditionally, on a miss as well as a hit.
		//
		// Reconstructing this with AttackDir(self, angle, pitch) instead is
		// a bug that has been written into this weapon twice, and the second
		// time it drew the beam at ninety degrees to where the gun pointed.
		// Any independently-derived direction is a second opinion that can
		// disagree with the trace. Reading HitDir makes the drawn beam and
		// the damage physically incapable of pointing different ways.
		// NORMALIZED DEFENSIVELY. It is only used to build the miss endpoint
		// below, where a non-unit vector would multiply LNC_RANGE into a
		// wildly overshot segment -- and "is this actually unit length" is
		// exactly the assumption that cost two rounds of debugging.
		Vector3 dir = d.HitDir;
		double dirLen = dir.Length();
		dir = (dirLen > 0.001) ? dir / dirLen : (0, 0, 0);

		// ON A MISS, d.HitLocation IS THE MAP ORIGIN (0,0,0), NOT "NO
		// ANSWER". P_LineTrace zeroes its result struct before tracing and
		// only fills HitLocation through the successful branch. A held-open
		// sky would otherwise point the beam at world (0,0,0), which for a
		// player standing any distance from the map origin is a wildly wrong
		// endpoint -- exactly the kind of stray segment that grazes the
		// camera and washes the screen out.
		Vector3 to;
		if (hit)
		{
			to = d.HitLocation;
		}
		else if (dir dot dir > 1e-8)
		{
			to = from + dir * LNC_RANGE;
		}
		else
		{
			// No endpoint and no direction: draw nothing rather than guess.
			w.Release(self);
			return;
		}

		if (dir dot dir < 1e-8)
		{
			Vector3 seg = to - from;
			double segLen = seg.Length();
			if (segLen > 0.001) dir = seg / segLen;
		}

		// ====================================================================
		// THE DRAW ORIGIN IS *NOT* THE TRACE ORIGIN.
		//
		// AttackPos/OffhandPos is the tracked CONTROLLER -- your fist. The
		// gun model extends forward from there, so a beam drawn from that
		// point is born INSIDE the weapon and exits through the barrel,
		// passing lengthwise through the whole model on its way out. Worse,
		// the halo reaches thick + soft*8 world units (main.fp's own
		// bounding reject uses exactly that), which at high charge is ~48
		// units -- most of a player's height. Starting that at arm's length
		// from the eye engulfs the camera and washes the screen white.
		//
		// SLIDE ALONG THE SEGMENT WE ALREADY HAVE. `from` and `to` are both
		// authoritative -- one is the trace's origin, the other its result --
		// so a point between them is on the beam line BY CONSTRUCTION. No
		// direction, no basis vectors, no cvars: nothing that can disagree.
		//
		// LaserBeamOffset.Y IS THE DISTANCE, and Y is not a typo. The engine
		// reads this same property to place its VR laser sight, and
		// hw_weapon.cpp applies the .Y component along FORWARD (it builds
		// totalOffset as (laser_y + weap.Y, ...) and applies .X of that along
		// the forward axis). Keeping the weapon's number in the same field
		// the engine reads means the beam and the sight stay together.
		//
		// AN EARLIER VERSION mirrored the engine's full forward/side/up basis
		// so a sideways offset would work too. It broke: the shot went where
		// the gun pointed and hit correctly, and the DRAWN beam started at
		// that hit point and ran off sideways -- a lateral displacement,
		// which is exactly what the `side` term contributes and nothing else
		// does. Three extra inputs to support an offset that is zero
		// sideways and zero up. This version cannot displace laterally at
		// all, and the clamp keeps it from ever passing the endpoint.
		//
		// The trace is untouched. Only where the beam is DRAWN from moves.
		// ====================================================================
		double hitDist = (to - from).Length();
		double frac = (hitDist > 0.001)
			? clamp(w.LaserBeamOffset.Y / hitDist, 0.0, 0.5)
			: 0.0;
		Vector3 drawFrom = from + (to - from) * frac;

		// ---- shape, and it is all one number --------------------------------
		double charge = w.Charge();

		// THE BLOOM CEILING. The fork's beam doc notes the air glow "feeds
		// bloom without being told to, since a core burning past white is
		// exactly what the bloom pass thresholds for". So intensity stays
		// under 1.0 for the entire working range and only crosses it in the
		// last few percent before cook-off -- at which point the screen
		// washing out IS the warning, rather than the weapon's baseline.
		double thick = 1.1 + 3.4 * charge;
		double soft  = 1.3 + 4.0 * charge;
		double inten = 0.30 + 0.72 * charge;

		// Cold blue-white, to hard white, to amber, to a bad orange. The
		// colour is the heat gauge, and it is what makes the state legible
		// without looking away from the target. White owns the broad middle
		// where the weapon is comfortable; the last third is where it
		// visibly stops being.
		Color col;
		if (charge < 0.35)
			col = LNC_Lance.LerpCol(0xA0C8FF, 0xE8F4FF, charge / 0.35);
		else if (charge < 0.70)
			col = LNC_Lance.LerpCol(0xE8F4FF, 0xFFD070, (charge - 0.35) / 0.35);
		else
			col = LNC_Lance.LerpCol(0xFFD070, 0xFF6020, (charge - 0.70) / 0.30);

		// FRAME-GLOBAL, BOTH OF THESE. SetBeamCount's glow term and every
		// SetBeamLook value cover EVERY beam in the scene, not just this
		// one -- they are single vec4s in the viewpoint block, not arrays.
		// This weapon is the only beam user in a standalone load; if you add
		// another, these become shared state and want one owner rather than
		// each actor stomping the others every tic.
		level.SetBeamCount(2, 0.28, 1.0);

		// Air glow is what makes it a laser rather than a spotlight -- the
		// beam is visible hanging in the air, not just a bright patch where
		// it lands. Scroll matters more than it sounds: a held beam with
		// nothing travelling along it goes static within a second and the
		// eye stops believing it carries anything. Taper slackens as it
		// heats -- a cold beam is tight at the aperture, a hot one has lost
		// its discipline and is nearly parallel-sided.
		level.SetBeamLook(
			0.45 + 0.55 * charge,         // air glow
			5.0 + 11.0 * charge,          // scroll speed
			0.18 + 0.22 * charge,         // scroll depth
			0.45 - 0.30 * charge,         // taper, slackening
			1.2 + 1.40 * charge);         // impact flare

		level.SetBeam(w.BeamSlot(), drawFrom, to, thick, soft, col, inten);

		// THE SOUND RISES WITH THE HEAT. Started once on the trigger edge and
		// pitched every tic after, so the overheat is audible before it is
		// visible -- which matters, because you are usually looking at what
		// you are shooting rather than at the beam.
		if (!w.firing)
		{
			A_StartSound("lnc/charge", CHAN_WEAPON, 0, 0.7);
			A_StartSound("lnc/loop", CHAN_5, CHANF_LOOPING, 0.8, ATTN_NORM);
			w.firing = true;
		}
		A_SoundPitch(CHAN_5, 0.85 + 0.55 * charge);

		// ---- and now the damage ---------------------------------------------
		//
		// NOT EVERY TIC. One LineAttack per tic would spend a cell every tic
		// and land thirty-five hits a second. The cadence tightens with
		// charge instead -- 4 tics cold, 2 at the edge -- which is half the
		// damage ramp; DamageMult() is the other half.
		//
		// KEYED OFF Level.maptime, NOT held. The interval CHANGES during a
		// hold, and `held % interval` against a moving interval either skips
		// a beat or fires twice in a row at the moment it steps down.
		//
		// AND NOTHING AT ALL DURING SPIN-UP. The first tenths of a second are
		// a targeting laser: visible, aimable, and harmless. That is the
		// commitment cost. SpinupNeeded() shortens it as the weapon heats.
		if (w.held <= w.SpinupNeeded()) return;
		if ((Level.maptime % w.FireInterval()) != 0) return;

		if (CountInv("Cell") <= 0)
		{
			w.Release(self);
			A_StartSound("lnc/empty", CHAN_AUTO);
			return;
		}
		A_TakeInventory("Cell", 1);

		// THE DAMAGE TRAVELS THE SAME RAY THE BEAM IS DRAWN ALONG. Passing
		// `angle`/`pitch` unchanged is correct for the same reason it is on
		// the trace above: P_LineAttack's VR branch swaps in the tracked
		// hand's position and direction, and the transform nets to zero for
		// unmodified body angles. LAF_ISOFFHAND picks the correct hand --
		// without it an offhand Lance fires from the mainhand controller.
		int laf = LAF_NORANDOMPUFFZ;
		if (offhand) laf |= LAF_ISOFFHAND;

		int dmg = max(1, int(LNC_DAMAGE * w.DamageMult()));
		LineAttack(angle, LNC_RANGE, pitch, dmg, 'Hitscan', "LNC_LancePuff",
			laf, offsetz: player.viewheight);
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
			// the one the loop was started on leaves a looping sound running
			// forever -- which is exactly what the original did.
			if (who) who.A_StopSound(CHAN_5);
			firing = false;
		}
		level.SetBeam(BeamSlot(), (0, 0, 0), (0, 0, 0), 0.01, 0.01, 0, 0.0);

		// held resets; heat DOES NOT. That one line is the entire pulse-fire
		// technique -- the ramp you built survives the release and only the
		// per-pull spin-up is paid again.
		held = 0;
	}

	void Overheat(Actor who)
	{
		Release(who);
		locked = true;
		heat = LNC_OVERHEAT;
		if (who) who.A_StartSound("lnc/cookoff", CHAN_WEAPON, 0, 1.0);
	}

	// Heat bleeds whenever the trigger is not down, at half the rate it
	// built -- 4.0s to cook from cold, 8.0s to fall all the way back. That
	// asymmetry is what makes short pulses cheap and long ones committing.
	//
	// A COOK-OFF VENTS FASTER but is locked for the whole descent, so it
	// costs about 2.8 seconds of holding a dead gun rather than the 9.3 the
	// bleed rate alone would impose.
	override void DoEffect()
	{
		Super.DoEffect();

		// SAFETY: the beam is drawn into a level-global slot, so anything
		// that ends a trigger pull WITHOUT running the Beam state's exit --
		// dying mid-burst, a forced weapon swap, being telefragged -- would
		// leave a live segment hanging in the world and a looping sound
		// playing under it. The state machine cannot cover those; this can,
		// because DoEffect runs regardless.
		if (firing && owner)
		{
			bool stillUp = owner.health > 0
				&& owner.player
				&& (owner.player.ReadyWeapon == self
					|| owner.player.OffhandWeapon == self);
			if (!stillUp)
				Release(owner);
		}

		if (!firing && heat > 0)
		{
			heat -= locked ? LNC_VENTRATE : LNC_COOLRATE;
			if (heat <= 0) { heat = 0; locked = false; }
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
		PLSC A 1 A_WeaponReady(WRF_ALLOWRELOAD);
		Loop;

	Deselect:
		TNT1 A 0 A_LanceStop();
		PLSC A 1 A_Lower;
		Loop;

	Select:
		PLSC A 1 A_Raise;
		Loop;

	Fire:
		TNT1 A 0 A_JumpIf(invoker.locked, "Overheated");
		TNT1 A 0 A_JumpIf(CountInv("Cell") > 0, "Beam");
		Goto OutOfAmmo;

	// ONE TIC PER LOOP. The beam is re-traced and re-drawn every tic, which
	// is what makes it track as you turn rather than lagging behind the
	// crosshair like a spawned object would.
	Beam:
		PLSF A 1 Bright A_LanceBeam();
		TNT1 A 0 A_ReFire("Beam");
		TNT1 A 0 A_LanceStop();
		Goto Ready;

	// SHORTER THAN THE LOCKOUT, DELIBERATELY. This is 28 tics, but `locked`
	// stays true for the whole vent (~93 tics from a full cook-off). Holding
	// the trigger through a cook-off therefore cycles this animation rather
	// than sitting in one long uninterruptible pose -- which means the gun
	// comes back to Ready promptly enough to be DESELECTED. A 93-tic hard
	// freeze would make an overheat a window where you cannot even switch to
	// your other hand, and the punishment is meant to be "you have no beam",
	// not "you have no inputs".
	Overheated:
		TNT1 A 0 A_LanceStop();
		TNT1 A 0 A_StartSound("lnc/empty", CHAN_AUTO, 0, 0.6);
		PLSC C 28;
		Goto Ready;

	OutOfAmmo:
		TNT1 A 0 A_LanceStop();
		TNT1 A 0 A_StartSound("lnc/empty", CHAN_AUTO);
		Goto Ready;
	}
}

// The offhand copy. Same weapon; the flag is what puts it in the other
// hand, which in turn is what BeamSlot() reads to claim beam slot 1.
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
// RS_LancePuff -- the beam's impact, and it is deliberately almost
// nothing.
//
// A beam lands up to seventeen times a second. An ordinary bullet puff at
// that rate -- with its impact sound, debris, sparks and ricochets -- is
// sixty-odd actors and seventeen sounds per second out of a weapon that is
// meant to read as one silent continuous line of light.
//
// AND THE VISUAL IS THE ENGINE'S, NOT AN ACTOR'S. SetBeamLook's fifth
// parameter is an impact flare that rides the segment's far end, drawn per
// pixel by the same closest-approach solve that draws the beam. The hit is
// therefore ALREADY lit, in the right place, at the right colour, for
// free. A sprite puff on top of that is a second, worse drawing of
// something the engine has already done -- so this contributes a single
// 2-tic ember and gets out of the way.
//
// The sizzle is rolled at 1-in-6 rather than played every hit: at that
// cadence an every-hit sound is not a sound, it is a tone, and it would
// sit on top of the heat loop already running on CHAN_5.
// =====================================================================
class LNC_LancePuff : Actor
{
	Default
	{
		+NOGRAVITY
		+FORCEXYBILLBOARD
		+PUFFONACTORS
		+ALWAYSPUFF
		-ALLOWPARTICLES
		// RailScorch is the stock decal authored for a beam strike rather
		// than a projectile crater, and it is a GROUP, so held fire varies
		// the mark instead of stamping one texture over itself.
		Decal "RailScorch";
		RenderStyle "Add";
		Scale 0.06;
		Alpha 0.9;
	}
	States
	{
	Spawn:
		TNT1 A 0 NoDelay A_LanceImpact();
		PLSF B 2 Bright;
		Stop;
	}

	action void A_LanceImpact()
	{
		if (Random(0, 5) == 0)
			A_StartSound("lnc/sizzle", CHAN_AUTO, CHANF_DEFAULT, 0.35);
	}
}
