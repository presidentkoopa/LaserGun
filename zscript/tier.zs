// =====================================================================
// THE LADDER -- how a Lance gets stronger.
//
// One counter, LNC_LanceTier, held by the PLAYER. The weapon reads it
// (LNC_Lance.Tier) and it decides how many rungs the heat climb passes
// through. Both hands share it, because two Lances at different power
// would be unreadable -- you would have to remember which hand was which
// mid-fight.
//
// YOU ALWAYS START AT THE BOTTOM. A tier-7 Lance still begins every
// trigger pull cold, blue and doing 60 DPS. What the tier buys is how far
// the SAME ten-second hold can climb -- one flat band at tier 1, seven
// gear changes at tier 7. The upgrade raises the ceiling, never the floor.
//
// That is what makes a pickup feel like a different weapon instead of a
// bigger number: the shape of the burst changes, not its starting point.
// =====================================================================

// The counter itself. Amount IS the tier.
class LNC_LanceTier : Inventory
{
	Default
	{
		Inventory.MaxAmount 7;      // must match LNC_Lance.LNC_MAX_TIER
		+INVENTORY.UNDROPPABLE
		+INVENTORY.UNTOSSABLE
		+INVENTORY.KEEPDEPLETED
	}
}


// ---------------------------------------------------------------------
// LNC_LanceCore -- the pickup that climbs the ladder.
//
// NOT A WEAPON, deliberately. If it were a Weapon you would end up with a
// second Lance in your inventory doing nothing, GZDoom would try to switch
// to it, and the "one gun that grows" idea would be quietly replaced by
// "several identical guns". It is an item whose entire job is to add a
// rung -- and to hand you the gun itself if you somehow do not have one.
//
// It uses the Lance's own pickup sprite so it reads as a laser weapon
// lying on the floor, which is what it is: you are stripping the emitter
// out of a dead soldier's rifle and welding it into yours.
// ---------------------------------------------------------------------
class LNC_LanceCore : CustomInventory
{
	Default
	{
		Inventory.PickupSound "lnc/charge";
		+INVENTORY.ALWAYSPICKUP
		+FLOATBOB
		Radius 20;
		Height 16;
		Scale 0.8;
		Inventory.PickupMessage "";   // set per-case in TryPickup
	}

	// SLOW SPIN. MODELDEF can place a model and lay it on its side but has no
	// way to animate a rotation, so the turn is done here. Two degrees a tic
	// is a full revolution every six seconds -- unmistakably moving, never
	// distracting, and it catches the light on a different face as it goes.
	//
	// Combined with FLOATBOB it reads as an item rather than as scenery,
	// which matters for something that drops 2% of the time and must not be
	// walked past.
	override void Tick()
	{
		Super.Tick();
		angle += 2.0;
	}

	States
	{
	Spawn:
		// PLAS A is a placeholder frame the MODELDEF binds the Bolter mesh
		// to -- what is actually drawn is the gun. Bright so it stays
		// visible on a dark floor, which is where it will usually land.
		PLAS A -1 Bright;
		Stop;
	Pickup:
		TNT1 A 0 A_LanceCorePickup();
		Stop;
	}

	action void A_LanceCorePickup()
	{
		if (!self) return;

		// No Lance yet? This IS the Lance. First one found arms you at tier
		// 1 rather than being a wasted pickup -- and it means the weapon can
		// be found in the world instead of only being given at spawn.
		bool hadGun = CountInv("LNC_Lance") > 0;
		if (!hadGun)
		{
			A_GiveInventory("LNC_Lance", 1);
			A_GiveInventory("LNC_LanceOffhand", 1);
		}

		int before = CountInv("LNC_LanceTier");
		if (before < LNC_Lance.LNC_MAX_TIER)
			A_GiveInventory("LNC_LanceTier", 1);
		int after = CountInv("LNC_LanceTier");

		// Seat the offhand as well, or the second gun sits in the backpack.
		if (!hadGun && player)
		{
			let off = Weapon(FindInventory("LNC_LanceOffhand"));
			if (off) player.OffhandWeapon = off;
		}

		// TELL THE PLAYER WHAT CHANGED, and in the terms that matter -- the
		// tier number, not "you got a thing". A silent upgrade to an
		// invisible counter is indistinguishable from a bug.
		if (!hadGun)
			A_Print("LANCE ACQUIRED -- tier 1 of 7");
		else if (after > before)
			A_Print(String.Format("LANCE UPGRADED -- tier %d of %d",
				after, LNC_Lance.LNC_MAX_TIER));
		else
			A_Print("LANCE ALREADY AT MAXIMUM TIER");
	}
}


// ---------------------------------------------------------------------
// LNC_DropHandler -- 2% of dead humanoids leave a Lance core.
//
// WHY A HANDLER RATHER THAN DropItem. DropItem has to be declared on each
// monster class, which means editing every humanoid in whatever mod is
// loaded and silently missing every one added later. A death event sees
// everything that dies, in any mod, forever.
//
// WHAT COUNTS AS A HUMANOID, and this is a heuristic rather than a list
// for the same reason. A hardcoded set of class names would cover stock
// Doom's four zombies and nothing else -- not RS_Main's tiered variants,
// not another mod's soldiers. Instead: monster-sized, ground-bound, and
// not a boss.
//
//   radius <= 24        a zombieman is 20, an imp 20, a demon 30
//   height <= 64        rules out the tall heavies
//   not FLOAT           rules out cacodemons and lost souls
//   health <= 200       rules out anything boss-shaped that slipped through
//
// It will occasionally admit something arguable. That is the right failure
// direction for a 2% drop: a slightly wrong monster dropping a core is
// invisible, while missing every modded soldier is a dead mechanic.
// ---------------------------------------------------------------------
class LNC_DropHandler : EventHandler
{
	// Two percent, as asked. Rolled per kill out of 1000 rather than 100 so
	// the number can be tuned in tenths without changing the code shape.
	const LNC_DROP_PERMILLE = 20;

	override void WorldThingDied(WorldEvent e)
	{
		let victim = e.Thing;
		if (!victim || !victim.bIsMonster) return;
		if (!IsHumanoid(victim)) return;
		if (Random(1, 1000) > LNC_DROP_PERMILLE) return;

		// Spawned a little above the corpse so it does not end up inside the
		// floor on sloped or raised geometry, and given a small upward hop so
		// it visibly drops rather than appearing.
		// Actor.Spawn, not bare Spawn: an EventHandler is not an Actor, so
		// the unqualified name is not in scope here.
		let core = Actor.Spawn("LNC_LanceCore",
			(victim.Pos.X, victim.Pos.Y, victim.Pos.Z + 8));
		if (core)
		{
			core.Vel.Z = 2.5;
			core.Vel.X = FRandom(-1.0, 1.0);
			core.Vel.Y = FRandom(-1.0, 1.0);
		}
	}

	private bool IsHumanoid(Actor a)
	{
		if (a.bFLOAT || a.bNOGRAVITY) return false;
		if (a.radius > 24.0) return false;
		if (a.height > 64.0) return false;
		if (a.SpawnHealth() > 200) return false;
		return true;
	}
}
