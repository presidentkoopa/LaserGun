// =====================================================================
// BURNING DEATHS -- what the Lance leaves behind.
//
// WHY THIS IS A SYSTEM AND NOT A SPRITE SET, which is the whole design
// decision and worth stating before the code:
//
//   There are no drawn "creature burning to death" animations in the art
//   source. There is a large library of FLAME EFFECTS (FLAMES/, ~550
//   files) and a lot of gore fatalities, but nothing showing a specific
//   monster catching fire and collapsing. Drawing them would mean one
//   animation per monster per rotation -- hundreds of frames -- and every
//   new monster added later would need its own set or would quietly not
//   burn.
//
//   So the fire is applied to the monster instead of drawn into it. The
//   victim plays its OWN death animation, and flames are layered over and
//   around it. That works on every monster in the game today, every
//   monster added tomorrow, and every modded monster from any other pk3,
//   for free.
//
// WHERE THE VARIETY COMES FROM, since a burn that always looks identical
// is worse than no burn at all. Five independent rolls, so two burns are
// essentially never the same:
//
//   1. WHICH FLAME SET      five 14-16 frame sets, rolled per flame
//   2. MIRRORED OR NOT      half the flames are flipped horizontally
//   3. WHERE                 scattered across the victim's own radius and
//                            height, so a Baron burns across a Baron and a
//                            zombie across a zombie
//   4. WHEN                  each flame starts on its own delay and lives
//                            its own length
//   5. HOW BIG               scale rolled per flame AND scaled to the
//                            victim, so a big thing burns bigger
//
//   Plus six scream takes in two $random groups, so a room full of
//   burning zombies is a chorus rather than one sound played six times.
//
// =====================================================================

// ---------------------------------------------------------------------
// LNC_Flame -- one tongue of fire. Cosmetic, weightless, harmless.
//
// FIVE SUBCLASSES, one per art set, because a sprite name cannot be
// chosen at runtime -- states are compiled. Rolling a CLASS is how you
// roll a look. They are otherwise identical and share all behaviour.
//
// RANDOM MIRRORING is done with negative X scale rather than +XFLIP: the
// flag flips about the sprite's own axis, while a negative scale flips
// about the actor's origin, which is what keeps a flipped flame sitting
// where it was placed instead of jumping sideways.
// ---------------------------------------------------------------------
class LNC_FlameBase : Actor
{
	Default
	{
		+NOBLOCKMAP
		+NOGRAVITY
		+NOINTERACTION
		+FORCEXYBILLBOARD
		-ALLOWPARTICLES
		RenderStyle "Add";
		Alpha 0.92;
		Scale 0.5;
	}

	// Roll the look. Called by the pyre right after spawning.
	//
	// `sizeScale` comes from the victim: a Cyberdemon's flames are simply
	// bigger than a zombie's, which is what stops a boss burning like a
	// campfire and a zombie like a bonfire.
	void SetupFlame(double sizeScale)
	{
		double s = FRandom(0.34, 0.62) * sizeScale;
		Scale.Y = s;
		// HALF ARE MIRRORED. One roll, and it doubles the apparent number of
		// distinct flames for nothing.
		Scale.X = (Random(0, 1) == 0) ? s : -s;
		Alpha = FRandom(0.75, 1.0);

		// Drift upward slowly. Fire rises, and a completely static flame
		// pinned to a corpse reads as a decal rather than a fire.
		Vel.Z = FRandom(0.15, 0.65);
		Vel.X = FRandom(-0.12, 0.12);
		Vel.Y = FRandom(-0.12, 0.12);
	}

	// Fade out over the actor's life rather than snapping off at the last
	// frame. Fire does not stop, it dies down.
	override void Tick()
	{
		Super.Tick();
		if (Alpha > 0.02) Alpha -= 0.012;
	}
}

class LNC_Flame1 : LNC_FlameBase
{ States { Spawn: FLME ABCDEFGHIJKLMN 3 Bright; Stop; } }

class LNC_Flame2 : LNC_FlameBase
{ States { Spawn: FIR3 ABCDEFGHIJKLMNOP 3 Bright; Stop; } }

class LNC_Flame3 : LNC_FlameBase
{ States { Spawn: FIR5 ABCDEFGHIJKLMNOP 3 Bright; Stop; } }

class LNC_Flame4 : LNC_FlameBase
{ States { Spawn: FIR6 ABCDEFGHIJKLMNOP 3 Bright; Stop; } }

class LNC_Flame5 : LNC_FlameBase
{ States { Spawn: CFCF ABCDEFGHIJKLMNOP 3 Bright; Stop; } }


// ---------------------------------------------------------------------
// LNC_Ash -- what is left. Two sets, three frames each, mirrored at
// random, so a battlefield is scattered with visibly different marks
// rather than one stamp repeated.
//
// It settles rather than appearing: a corpse that flashes into a neat
// pile of ash looks like a bug. It fades IN over half a second while the
// last flames are still dying.
// ---------------------------------------------------------------------
class LNC_AshBase : Actor
{
	Default
	{
		+NOBLOCKMAP
		+NOINTERACTION
		+DONTSPLASH
		Alpha 0.0;
		Scale 0.6;
		RenderStyle "Translucent";
	}

	int settle;

	void SetupAsh(double sizeScale)
	{
		double s = FRandom(0.5, 0.8) * sizeScale;
		Scale.Y = s;
		Scale.X = (Random(0, 1) == 0) ? s : -s;
	}

	override void Tick()
	{
		Super.Tick();
		if (settle < 18)
		{
			settle++;
			Alpha = settle / 18.0 * 0.85;
		}
	}
}

class LNC_Ash1 : LNC_AshBase
{ States { Spawn: ASHY ABC 8; ASHY C -1; Stop; } }

class LNC_Ash2 : LNC_AshBase
{ States { Spawn: ASHZ ABC 8; ASHZ C -1; Stop; } }


// ---------------------------------------------------------------------
// LNC_Pyre -- the thing that actually burns a corpse.
//
// Spawned at a victim when the Lance kills it. Lives a few seconds,
// throwing flames the whole time, then leaves ash and expires.
//
// SPAWNED RATHER THAN ATTACHED, deliberately: an actor that only spawns
// other actors cannot break the victim, cannot interfere with its death
// animation, and cannot leave a monster in a bad state if something goes
// wrong. If the pyre fails, a monster simply dies normally.
// ---------------------------------------------------------------------
class LNC_Pyre : Actor
{
	Default
	{
		+NOBLOCKMAP
		+NOGRAVITY
		+NOINTERACTION
		RenderStyle "None";
	}

	// Copied off the victim at spawn so the pyre matches its size even
	// after the corpse has finished animating and shrunk or moved.
	double vicRadius;
	double vicHeight;
	double sizeScale;
	int    life;
	int    screamsLeft;

	// Set up from whatever was killed. Radius and height drive both the
	// spread and the flame scale, so this reads correctly on anything from
	// a Lost Soul to a Cyberdemon without a per-monster table.
	void SetupPyre(Actor victim)
	{
		vicRadius = max(8.0, victim.radius);
		vicHeight = max(16.0, victim.height);

		// A zombie is radius 20 -- call that 1.0 -- and a Cyberdemon is 40.
		// Clamped so nothing tiny burns invisibly and nothing huge fills the
		// screen.
		sizeScale = clamp(vicRadius / 20.0, 0.7, 2.6);

		// Bigger things burn longer, because a bigger fire takes longer to
		// go out and because a boss death deserves more screen time.
		life = int(70 + vicRadius * 1.6);

		// TWO OR THREE SCREAMS, not one per tic and not a fixed count. A
		// burning thing cries out more than once, but a room of them must
		// not become a wall of noise.
		screamsLeft = Random(2, 3);
	}

	override void PostBeginPlay()
	{
		Super.PostBeginPlay();
		A_StartSound("lnc/burn/loop", CHAN_BODY, CHANF_LOOPING, 0.55, ATTN_NORM);
	}

	States
	{
	Spawn:
		TNT1 A 1 NoDelay A_PyreTick();
		Wait;
	}

	action void A_PyreTick()
	{
		let p = LNC_Pyre(self);
		if (!p) { Destroy(); return; }

		p.life--;

		// THE FLAMES. Two or three a tic early on, thinning out as the fire
		// dies -- a burn that emits at a constant rate looks mechanical, and
		// the tail is where it reads as going out rather than being switched
		// off.
		double phase = clamp(double(p.life) / 70.0, 0.0, 1.0);
		int count = (FRandom(0, 1) < phase) ? Random(1, 3) : Random(0, 1);

		for (int i = 0; i < count; i++)
		{
			// WHICH SET -- one of five, rolled per flame rather than per
			// pyre, so a single corpse burns with several different fires at
			// once and no two pyres share a signature.
			Class<Actor> cls;
			switch (Random(0, 4))
			{
				case 0:  cls = "LNC_Flame1"; break;
				case 1:  cls = "LNC_Flame2"; break;
				case 2:  cls = "LNC_Flame3"; break;
				case 3:  cls = "LNC_Flame4"; break;
				default: cls = "LNC_Flame5"; break;
			}

			// WHERE -- scattered through the victim's own volume, biased low
			// because fire sits on a body rather than hovering over it.
			double ang = FRandom(0, 360);
			double rad = FRandom(0, p.vicRadius * 0.85);
			double zof = FRandom(0, p.vicHeight * 0.75);

			let f = LNC_FlameBase(Spawn(cls,
				p.Pos + (cos(ang) * rad, sin(ang) * rad, zof)));
			if (f) f.SetupFlame(p.sizeScale);
		}

		// THE SCREAMS. Spread across the first half of the burn and rolled
		// from a $random group, so six takes across two voices means a pile
		// of burning zombies is a chorus rather than one sound repeated.
		if (p.screamsLeft > 0 && Random(0, 22) == 0)
		{
			p.screamsLeft--;
			A_StartSound(Random(0, 1) == 0 ? "lnc/burn/scream1" : "lnc/burn/scream2",
				CHAN_VOICE, CHANF_DEFAULT, FRandom(0.75, 1.0), ATTN_NORM);
			A_SoundPitch(CHAN_VOICE, FRandom(0.88, 1.12));
		}

		if (p.life <= 0)
		{
			p.A_StopSound(CHAN_BODY);

			// WHAT IS LEFT. Two ash sets, mirrored at random, settling in
			// rather than appearing.
			let a = LNC_AshBase(Spawn(Random(0, 1) == 0 ? "LNC_Ash1" : "LNC_Ash2",
				(p.Pos.X, p.Pos.Y, p.Pos.Z)));
			if (a) a.SetupAsh(p.sizeScale);

			p.Destroy();
		}
	}
}


// ---------------------------------------------------------------------
// LNC_BurnHandler -- lights the fire.
//
// A WORLD EVENT HANDLER rather than code inside the weapon, because the
// weapon does not know when something DIES -- it only knows it dealt
// damage, and the killing point is exactly where the burn belongs. This
// also means any future source of Lance damage burns correctly with no
// extra wiring.
//
// THE INFLICTOR TEST is what keeps this from setting fire to everything.
// A monster killed by a shotgun must not burn, so the handler checks the
// damage source is a player holding a Lance. Not perfect -- a player who
// switches hands in the same tic could theoretically be misread -- but the
// failure mode is a spurious fire, not a broken monster.
// ---------------------------------------------------------------------
class LNC_BurnHandler : EventHandler
{
	override void WorldThingDied(WorldEvent e)
	{
		let victim = e.Thing;
		if (!victim || !victim.bIsMonster) return;

		// Already burning? Do not stack pyres -- a monster killed by two
		// beams at once would otherwise get two, and double the flames and
		// double the screams.
		if (victim.CountInv("LNC_Burned") > 0) return;

		let src = e.Inflictor ? e.Inflictor : victim.target;
		if (!IsLanceKill(e)) return;

		victim.A_GiveInventory("LNC_Burned", 1);

		let pyre = LNC_Pyre(Actor.Spawn("LNC_Pyre",
			(victim.Pos.X, victim.Pos.Y, victim.Pos.Z)));
		if (pyre) pyre.SetupPyre(victim);
	}

	// Was this kill the Lance's? The burn damage is applied with the player
	// as both source and inflictor (DamageMobj(self, self, ...)), so the
	// test is "a player killed it and the hand they are holding is a
	// Lance".
	private bool IsLanceKill(WorldEvent e)
	{
		let killer = e.Thing ? e.Thing.target : null;
		if (!killer || !killer.player) return false;

		let p = killer.player;
		if (p.ReadyWeapon   is "LNC_Lance") return true;
		if (p.OffhandWeapon is "LNC_Lance") return true;
		return false;
	}
}

// Marker so a corpse is never set alight twice.
class LNC_Burned : Inventory
{
	Default
	{
		Inventory.MaxAmount 1;
		+INVENTORY.UNDROPPABLE
		+INVENTORY.UNTOSSABLE
	}
}
