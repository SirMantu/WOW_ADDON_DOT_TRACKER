# Changelog

## 1.0.1

### Added
- Track DoTs cast by other players on enemies (option "Track DoTs of other players", on by default). Each caster is tracked separately and all damage is summed into one value.
- Lookup table `DOT_LOOKUP` with 22 Classic DoTs (Warlock, Warrior, Rogue, Hunter, Druid, Priest, Mage, Shaman), using base durations without talents.
- Option "Only enemies I attacked" (off by default): only shows enemies that you or your pet have attacked.

### Documentation
- README lists talents, ranks and combo points that can make the estimated tick count wrong (for example Improved Shadow Word: Pain).

### Changed
- Expected crit damage is only applied to your own DoTs, because the crit chance of other players is unknown.
- Duration is read from the aura only for your own DoTs; DoTs of other players use the lookup duration.

## 1.0.0

Initial release.

### Features
- Tracks your own damage over time effects (Corruption, Curse of Agony, Immolate, Siphon Life) from the combat log.
- Shows the remaining HP of an enemy after all of its DoTs have finished, above the nameplate (red when negative).
- Skull icon when the DoTs will kill the enemy.
- Black damage segment on the nameplate health bar showing the DoT damage still to come.
- Fallback display for your target when no nameplate is visible.
- Optional expected crit damage for DoT ticks (`CRIT_MULTIPLIER`).
- Estimates damage per tick from the last non-crit tick and remaining ticks from the aura duration.
- DoT data is discarded on death, expiry, or after 30 seconds without ticks.
- Options window with checkboxes, opened by `/dt` or the draggable minimap button.
- `/dt test` adds fake DoTs to your target, `/dt debug` prints combat log events.
- Requires enemy health bars (nameplates) to be enabled.
