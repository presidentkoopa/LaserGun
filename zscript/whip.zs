// =====================================================================
// THE LASH -- a rope of light with weight, that hangs, drags and cracks.
//
// WHAT THE FIRST VERSION GOT WRONG, because it is the whole design:
//
//   It stored where the tip had BEEN and drew chords between old samples.
//   Stand still and every sample is identical, so the whip was a straight
//   line pointing forward -- "its default state is firing forward like a
//   laser cannon", exactly. It was a TRAIL, and a trail has no mass. It
//   could not hang, could not drag, could not overshoot, could not crack.
//
// THIS IS A ROPE. Nine point masses, each remembering its previous
// position, linked at a fixed length. Gravity pulls them down, constraint
// passes hold the links together, and the far end lags behind your hand
// because it genuinely has weight rather than because it is replaying a
// buffer.
//
// AND IT STILL NEEDS NO MOMENTUM TRACKING FROM THE ENGINE. In verlet, the
// difference between a point's current and previous position IS its
// velocity -- there is nowhere to put an engine-supplied one even if it
// existed. Moving the anchor makes the rest follow, and how hard depends
// on how fast you moved it. That is the whole of "reacts to my hand".
//
// KNOWN LIMIT, worth stating rather than discovering: ZScript ticks at
// 35Hz, so a very fast flick is sampled coarsely and the crack is softer
// than it would be at frame rate. Fixing that properly means sampling the
// hand pose natively -- the same work that would give grenade throwing.
//
// SLOTS 8-15, clear of the Lance (0-5) and the Buckler (16-63).
// =====================================================================

class LNC_Whip : Weapon
{
	// ---- the rope --------------------------------------------------------
	const WHP_CHORDS  = 8;
	const WHP_POINTS  = WHP_CHORDS + 1;
	const WHP_SEG     = 22.0;      // link length; total reach ~176 units
	const WHP_SLOT_BASE = 8;

	// FRAME-GLOBAL and shared with the Lance and Buckler, so all three must
	// ask for the same number or whoever writes last shrinks the others out
	// of existence. Covers the Buckler's top slot (63).
	//
	// Sixty-four costs nothing for the slots nobody fills: the shader breaks
	// out of its loop at the live count and every surviving beam gets a
	// bounding-sphere reject before the real solve, so an empty slot is free
	// and a distant one is nearly free.
	const BEAM_COUNT_SHARED = 64;

	// Gravity, expressed PER TIC. The solver divides it down for the substeps
	// below; position verlet is exact for constant acceleration, so
	// g/(N*N) per substep lands in precisely the same place as g once.
	const WHP_GRAVITY = 0.85;

	// SUBSTEPS, and this is half of why the lash can be cracked at all.
	//
	// Script runs at 35Hz, so a hard flick of the hand is two or three
	// samples and the solver saw it as one big teleport of the grip. A
	// teleport is not a swing: the rope got a position correction where it
	// should have got momentum, and most of the energy of the flick simply
	// never entered the system.
	//
	// Running the solve three times a tic against an anchor walked from last
	// tic's position to this one turns that teleport back into travel. It
	// also means an impulse gets 3 x WHP_PASSES = 12 chances to propagate per
	// tic, which is more than the eight links, so a crack started at the grip
	// reaches the tip inside the same tic instead of a quarter second later.
	const WHP_SUBSTEPS = 3;

	// Damping, PER SUBSTEP rather than per tic -- three of these compound
	// each tic, so 0.980 is about 0.94 a tic and 0.992 is about 0.976.
	// (Stated as substep values on purpose: ZScript has no pow(), so deriving
	// them from a per-tic figure would need a hardcoded root anyway.)
	//
	// THE TIP IS DAMPED LESS THAN THE GRIP. A uniformly damped rope bleeds
	// the crack away exactly where it is supposed to be arriving.
	const WHP_DAMP     = 0.980;
	const WHP_DAMP_TIP = 0.992;

	// HOW MUCH LIGHTER THE TIP IS THAN THE GRIP -- see InvMass. This is the
	// number that decides whether the thing cracks or just flops.
	const WHP_TIP_LIGHT = 6.0;

	// Constraint passes. One pass only propagates a correction across a
	// single link, so a chain of eight needs several before the far end
	// stops visibly stretching. Four looks solid and costs little.
	const WHP_PASSES  = 4;

	// The crack: how hard the outer half is thrown forward on the trigger.
	const WHP_LASH_PUSH = 26.0;

	// Heat, so the Lash climbs the same ladder as the Lance and shows the
	// same colours for the same strength.
	const WHP_HEAT_MAX  = 100.0;
	const WHP_HEAT_RISE = 26.0;
	const WHP_HEAT_FALL = 34.0;

	const WHP_DAMAGE_PER_SEC = 150.0;
	const WHP_HIT_RADIUS     = 22.0;

	// WHERE THE LASH LEAVES THE HANDLE. AttackPos is the controller in VR
	// and the EYE on a desktop, so the anchor has to be pushed out to the
	// emitter either way or the rope hangs off your face.
	const WHP_EMIT_FWD   = 20.0;
	const WHP_EMIT_RIGHT = 9.0;
	const WHP_EMIT_UP    = -7.0;

	Vector3 pt[WHP_POINTS];
	Vector3 ptPrev[WHP_POINTS];
	Vector3 anchorPrev;            // last tic's grip, so substeps can walk to it
	bool ropeReady;

	double heat;
	double burn;

	Default
	{
		Tag "Lash";
		Weapon.SelectionOrder 1070;
		Weapon.SlotNumber 6;
		Weapon.AmmoUse 0;
		Weapon.AmmoGive1 0;
		Weapon.AmmoType1 "";
		+WEAPON.AMMO_OPTIONAL;
		+WEAPON.NOALERT;
		+WEAPON.NOHANDSWITCH;
		// OFF HAND. Without this the Lash is a second mainhand weapon, shares
		// the hand with the Lance, and is invisible until you select it.
		+WEAPON.OFFHANDWEAPON;
		Inventory.PickupMessage "You got the Lash!";
		Inventory.Icon "WHPGA0";
	}

	// Same ladder as the Lance, through the same shared accessor, so a core
	// found for one raises both and the colours always agree.
	clearscope int Tier() const { return LNC_Lance.ArsenalTier(owner); }

	clearscope double HeatFrac() const { return clamp(heat / WHP_HEAT_MAX, 0.0, 1.0); }

	clearscope int Band() const
	{
		int t = Tier();
		return clamp(int(HeatFrac() * t), 0, t - 1);
	}

	double LashDPS() const
	{
		switch (Band())
		{
			case 0:  return 60.0;
			case 1:  return 95.0;
			case 2:  return 150.0;
			case 3:  return 235.0;
			case 4:  return 370.0;
			case 5:  return 580.0;
			default: return 900.0;
		}
	}

	// ---- the simulation --------------------------------------------------

	// HOW HEAVY EACH POINT IS -- returned as INVERSE mass, so a bigger number
	// means a lighter point that moves further for the same correction.
	//
	// THIS IS THE WHOLE REASON A WHIP CRACKS. A whip is not a uniform rope:
	// it tapers, so there is less and less mass per unit length toward the
	// tip. Momentum traveling down it keeps entering lighter material, and
	// conservation forces it to speed up -- which is how the tip of a real
	// whip goes supersonic while the hand throwing it never moves faster than
	// an arm can swing.
	//
	// The solver used to split every correction fifty-fifty, which is a chain
	// of identical links: an impulse arrived at the tip no faster than it left
	// the grip, so there was nothing to crack. Squared rather than linear
	// because a linear taper barely registers over eight links.
	//
	// Point 0 returns zero -- infinite mass, the hand, which the rope may
	// never move. That also removes the old i == 0 special case: a weight of
	// zero against a positive one hands the entire correction to the far
	// point on its own.
	static double InvMass(int i)
	{
		if (i <= 0) return 0.0;
		double t = double(i) / double(WHP_POINTS - 1);
		return 1.0 + WHP_TIP_LIGHT * t * t;
	}

	void StepRope(Vector3 anchor, Vector3 aim, Actor pawn, bool lashing)
	{
		if (!ropeReady)
		{
			// Born hanging off the emitter rather than at the world origin,
			// or the first tic snaps a whip clean across the map.
			for (int i = 0; i < WHP_POINTS; i++)
			{
				pt[i] = anchor + aim * (WHP_SEG * i);
				ptPrev[i] = pt[i];
			}
			anchorPrev = anchor;
			ropeReady = true;
		}

		// THE CRACK. Holding the trigger shoves the outer half forward along
		// the aim, which the constraints then have to resolve -- so the lash
		// straightens, overshoots and recoils on its own. Nothing scripts the
		// motion; it falls out of throwing energy at a rope.
		if (lashing)
		{
			for (int i = WHP_POINTS / 2; i < WHP_POINTS; i++)
			{
				double f = double(i) / double(WHP_POINTS - 1);
				pt[i] = pt[i] + aim * (WHP_LASH_PUSH * f * f);
			}
		}

		double floorZ = pawn ? pawn.floorz : -32768.0;

		// Per substep. Verlet is exact for constant acceleration, so N steps
		// of g/(N*N) land in the same place as one step of g.
		double gsub = WHP_GRAVITY / double(WHP_SUBSTEPS * WHP_SUBSTEPS);

		for (int s = 1; s <= WHP_SUBSTEPS; s++)
		{
			// THE GRIP TRAVELS INSTEAD OF TELEPORTING. Walking the anchor from
			// where the hand was last tic to where it is now is what converts
			// a 35Hz flick back into motion the rope can actually pick up.
			Vector3 hand = anchorPrev + (anchor - anchorPrev) * (double(s) / double(WHP_SUBSTEPS));

			// INTEGRATE. (pos - prev) is the velocity, so carrying it forward
			// and adding gravity is the entire physics.
			for (int i = 1; i < WHP_POINTS; i++)
			{
				double t = double(i) / double(WHP_POINTS - 1);
				double damp = WHP_DAMP + (WHP_DAMP_TIP - WHP_DAMP) * t;

				Vector3 vel = (pt[i] - ptPrev[i]) * damp;
				ptPrev[i] = pt[i];
				pt[i] = pt[i] + vel - (0, 0, gsub);

				// DRAGS ON THE FLOOR. Clamped rather than bounced, and
				// horizontal speed is scrubbed on contact, so a slack lash
				// lies on the ground and slithers instead of skating.
				if (pt[i].Z < floorZ + 1.0)
				{
					// UNPACK, EDIT, STORE BACK -- and it has to be done this
					// way. ZScript cannot assign to ONE COMPONENT of a vector
					// that lives in an array: that needs an address for the
					// element, and the VM dies with "REGT_ADDROF not
					// implemented for vectors" the first time it runs.
					// Assigning a whole vector is fine, so the two points come
					// out into locals, get edited there, and go back entire.
					Vector3 p  = pt[i];
					Vector3 pp = ptPrev[i];

					p.Z = floorZ + 1.0;
					pp.X += (p.X - pp.X) * 0.5;
					pp.Y += (p.Y - pp.Y) * 0.5;

					pt[i]     = p;
					ptPrev[i] = pp;
				}
			}

			// CONSTRAIN. Several passes, because one pass only carries a
			// correction across a single link.
			for (int pass = 0; pass < WHP_PASSES; pass++)
			{
				pt[0] = hand;                     // the hand always wins
				for (int i = 0; i < WHP_CHORDS; i++)
				{
					Vector3 d = pt[i + 1] - pt[i];
					double len = d.Length();
					if (len < 0.0001) { d = aim; len = 1.0; }
					double diff = (len - WHP_SEG) / len;

					// SPLIT BY INVERSE MASS, NOT DOWN THE MIDDLE. The lighter
					// of the two points takes more of the correction, so an
					// impulse accelerates as it runs out the taper. That is
					// the crack. At i == 0 the grip's weight is zero and the
					// far point takes all of it, which is what the old
					// special case did by hand.
					double wa = InvMass(i), wb = InvMass(i + 1);
					double wsum = wa + wb;
					if (wsum < 1e-9) continue;

					pt[i]     = pt[i]     + d * (diff * (wa / wsum));
					pt[i + 1] = pt[i + 1] - d * (diff * (wb / wsum));
				}
			}
		}

		anchorPrev = anchor;
	}

	void DrawLash()
	{
		int band = Band();
		Color col = LNC_Lance.BandColor(band);
		double step = double(band);

		level.SetBeamCount(BEAM_COUNT_SHARED, 0.30, 1.0);

		for (int i = 0; i < WHP_CHORDS; i++)
		{
			// Thick at the grip, thin at the tip. The taper is what makes the
			// far end read as fast-moving rather than as a rope.
			double t = double(i) / double(WHP_CHORDS - 1);
			double thick = (0.9 + 0.35 * step) * (1.0 - 0.70 * t);
			double soft  = (1.4 + 0.55 * step) * (1.0 - 0.50 * t);
			double inten = (0.55 + 0.14 * step) * (1.0 - 0.40 * t);

			level.SetBeam(WHP_SLOT_BASE + i, pt[i], pt[i + 1], thick, soft, col, inten);
		}
	}

	void ClearLash()
	{
		for (int i = 0; i < WHP_CHORDS; i++)
			level.SetBeam(WHP_SLOT_BASE + i, (0,0,0), (0,0,0), 0.01, 0.01, 0, 0.0);
	}

	// ---- damage ----------------------------------------------------------
	//
	// Does not trace. A whip does not stop at the first thing it touches, it
	// sweeps THROUGH a crowd -- so this walks nearby actors and asks how far
	// each is from the rope, which is a point-to-segment distance done eight
	// times per candidate.
	void BurnAlong(Actor src)
	{
		if (!src) return;

		burn += LashDPS() / 35.0;
		int whole = int(burn);
		if (whole <= 0) return;
		burn -= whole;

		let it = BlockThingsIterator.Create(src, WHP_SEG * WHP_CHORDS + WHP_HIT_RADIUS + 48.0);
		while (it.Next())
		{
			let mo = it.thing;
			if (!mo || mo == src) continue;
			if (!mo.bShootable || mo.health <= 0 || mo.bCorpse) continue;

			Vector3 target = (mo.Pos.X, mo.Pos.Y, mo.Pos.Z + mo.height * 0.5);
			double best = 1e9;
			for (int i = 0; i < WHP_CHORDS; i++)
			{
				double d = SegDist(target, pt[i], pt[i + 1]);
				if (d < best) best = d;
			}

			if (best <= WHP_HIT_RADIUS + mo.radius)
			{
				// DMG_NO_PAIN, or a continuous source pins a monster in its
				// pain state forever and it never acts again.
				mo.DamageMobj(src, src, whole, 'Hitscan', DMG_NO_PAIN);
			}
		}
	}

	static double SegDist(Vector3 p, Vector3 a, Vector3 b)
	{
		Vector3 ab = b - a;
		double len2 = ab dot ab;
		if (len2 < 0.0001) return (p - a).Length();
		double t = clamp(((p - a) dot ab) / len2, 0.0, 1.0);
		return (p - (a + ab * t)).Length();
	}

	// ---- per tic ---------------------------------------------------------

	action void A_LashTick(bool lashing)
	{
		let w = LNC_Whip(invoker);
		if (!w || !self || !player) return;

		double ca = cos(angle), sa = sin(angle);
		double cp = cos(pitch), sp = sin(pitch);
		Vector3 fwd   = (ca * cp, sa * cp, -sp);
		Vector3 right = (sa, -ca, 0);

		bool offhand = (player.OffhandWeapon == w);
		Vector3 hand = offhand ? OffhandPos : AttackPos;

		Vector3 anchor;
		if (OverrideAttackPosDir)
			anchor = hand + fwd * WHP_EMIT_FWD;
		else
			anchor = hand + fwd * WHP_EMIT_FWD + right * WHP_EMIT_RIGHT + (0, 0, 1) * WHP_EMIT_UP;

		if (lashing) w.heat = min(WHP_HEAT_MAX, w.heat + WHP_HEAT_RISE / 35.0);

		w.StepRope(anchor, fwd, self, lashing);
		w.DrawLash();
		if (lashing) w.BurnAlong(self);
	}

	override void DoEffect()
	{
		Super.DoEffect();
		if (!owner) return;

		bool up = owner.health > 0 && owner.player
			&& (owner.player.ReadyWeapon == self || owner.player.OffhandWeapon == self);
		if (!up)
		{
			ClearLash();
			ropeReady = false;      // re-hang from the emitter next time it is out
			burn = 0;
			return;
		}

		if (heat > 0) heat = max(0.0, heat - WHP_HEAT_FALL / 35.0);
	}

	States
	{
	Spawn:
		WHPG A -1;
		Stop;

	Ready:
		// Drawn every tic, firing or not -- a lash hanging slack from your
		// hand IS its resting state, and that is the whole point of giving it
		// weight. Making it appear only on the trigger would be a beam again.
		WHPG A 1 A_LashTick(false);
		WHPG A 0 A_WeaponReady(WRF_NOSECONDARY);
		Loop;

	Deselect:
		WHPG A 1 A_LashLower;
		Loop;

	Select:
		WHPG A 1 A_Raise;
		Loop;

	Fire:
		WHPG A 1 A_LashTick(true);
		WHPG A 0 A_ReFire;
		Goto Ready;
	}

	action void A_LashLower()
	{
		let w = LNC_Whip(invoker);
		if (w) { w.ClearLash(); w.ropeReady = false; }
		A_Lower();
	}
}
