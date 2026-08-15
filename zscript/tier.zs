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

	// NO SPIN. There was a two-degree-a-tic turn here to catch the light and
	// keep the core from reading as scenery, but the Bolter mesh is not
	// centred on its origin -- so turning the actor swung the whole gun round
	// in a wide circle instead of rotating it in place, which looks like a
	// bug rather than an item. FLOATBOB alone is enough to mark it as
	// something to pick up.
	//
	// If it ever wants to turn again, the fix is a centred pivot on the mesh
	// or a MODELDEF offset, not an angle on the actor.

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

	// THREE OUTCOMES, IN ORDER OF WHAT THE PLAYER HAS.
	//
	//   no Lance at all   -> you found the gun. Mainhand, tier 1.
	//   one Lance         -> you found a SECOND one. It goes in your off
	//                        hand, AND the pair steps up a tier.
	//   two Lances        -> nothing left to hold it in, so it is stripped
	//                        for parts: tier only.
	//
	// THE SECOND PICKUP IS THE DUAL-WIELD UNLOCK, and it is deliberately the
	// same item rather than a separate one. Finding another Lance and ending
	// up holding two Lances is the obvious reading; making dual-wield a
	// distinct pickup would mean explaining why one laser gun grants a hand
	// and another does not. It also makes the second core the single biggest
	// upgrade in the run -- a whole extra beam AND a rung -- which is the
	// right shape for a mid-run power spike.
	action void A_LanceCorePickup()
	{
		if (!self) return;

		bool hadMain = CountInv("LNC_Lance") > 0;
		bool hadOff  = CountInv("LNC_LanceOffhand") > 0;

		int before = CountInv("LNC_LanceTier");

		if (!hadMain)
		{
			// Found the weapon itself. Tier 1, one hand.
			A_GiveInventory("LNC_Lance", 1);
			if (before < 1) A_GiveInventory("LNC_LanceTier", 1);
			A_Print("LANCE ACQUIRED -- tier 1 of 7");
			return;
		}

		// Everything past the first pickup buys a rung.
		if (before < LNC_Lance.LNC_MAX_TIER)
			A_GiveInventory("LNC_LanceTier", 1);
		int after = CountInv("LNC_LanceTier");

		if (!hadOff)
		{
			// THE SECOND GUN. Seated into the offhand here rather than left
			// in the backpack -- an offhand weapon that has to be manually
			// selected reads as not having been given at all.
			//
			// THIS TAKES THE LASH'S HAND. Both are offhand weapons and there
			// is only one offhand, so seating the second Lance displaces the
			// whip. That is the right default -- the second gun is the power
			// spike and doubles your damage on a single target -- but it must
			// not happen silently, or a whip that was hanging there a moment
			// ago has simply vanished with no explanation. Hence the second
			// line: the Lash is not gone, it is in the other pocket.
			A_GiveInventory("LNC_LanceOffhand", 1);
			bool hadLash = CountInv("LNC_Whip") > 0;
			if (player)
			{
				let off = Weapon(FindInventory("LNC_LanceOffhand"));
				if (off) player.OffhandWeapon = off;
			}
			A_Print(String.Format(
				"SECOND LANCE -- dual wield, tier %d of %d",
				after, LNC_Lance.LNC_MAX_TIER));
			if (hadLash)
				A_Print("The Lash is stowed -- slot 6 to bring it back");
			return;
		}

		// TELL THE PLAYER WHAT CHANGED, in the terms that matter -- the tier
		// number, not "you got a thing". A silent bump to an invisible
		// counter is indistinguishable from a bug.
		if (after > before)
			A_Print(String.Format("LANCE UPGRADED -- tier %d of %d",
				after, LNC_Lance.LNC_MAX_TIER));
		else
			A_Print("LANCE ALREADY AT MAXIMUM TIER");
	}
}


// ---------------------------------------------------------------------
// LNC_DropHandler -- dead humanoids leave a Lance core, less and less often
// the more of them you are carrying. See DropPermille for the curve.
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
	// HOW LIKELY A CORE IS, GIVEN HOW MANY YOU ALREADY HAVE. Per mille, so it
	// tunes in tenths of a percent without changing the shape of the code.
	//
	// IT FALLS AWAY HARD, AND THAT IS THE POINT. A flat rate makes every rung
	// cost the same, which means the first one is a chore and the last one is
	// a formality -- the curve is the progression, not the numbers on it. The
	// first core should feel like it merely happened to you; the last should
	// be something you can feel yourself grinding toward. Roughly halving at
	// each step gives that without any single step reading as a wall:
	//
	//     have   chance    ~kills     what it feels like
	//     1      12.0%     8          you barely had to try
	//     2       7.0%     14
	//     3       4.0%     25
	//     4       2.2%     45         the halfway wall
	//     5       1.2%     83
	//     6       0.6%     166        the last rung, and it should hurt
	//     7       never    --         nothing left to buy
	//
	// About 340 kills end to end: an episode, not a map.
	//
	// NOTHING DROPS AT MAX TIER. A pickup that cannot do anything is worse
	// than no pickup -- it teaches you to stop reading them.
	static int DropPermille(int held)
	{
		switch (held)
		{
			case 1:  return 120;
			case 2:  return 70;
			case 3:  return 40;
			case 4:  return 22;
			case 5:  return 12;
			case 6:  return 6;
			default: return 0;
		}
	}

	// WHOSE LADDER DECIDES THE ODDS -- the killer's, so in co-op the player
	// who is behind keeps their own better rate instead of being throttled by
	// whoever is furthest ahead.
	//
	// Falls back to 1, the most generous rate, when the killer cannot be
	// identified. That is the right failure direction: the cost of guessing
	// wrong is a slightly early core, not a mechanic that quietly stops.
	private int CoresHeld(Actor victim)
	{
		let killer = victim.target;
		if (killer && killer.player)
			return clamp(killer.CountInv("LNC_LanceTier"), 1, LNC_Lance.LNC_MAX_TIER);
		return 1;
	}

	override void WorldThingDied(WorldEvent e)
	{
		let victim = e.Thing;
		if (!victim || !victim.bIsMonster) return;
		if (!IsHumanoid(victim)) return;

		int chance = DropPermille(CoresHeld(victim));
		if (chance <= 0) return;                       // maxed: nothing to buy
		if (Random(1, 1000) > chance) return;

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
