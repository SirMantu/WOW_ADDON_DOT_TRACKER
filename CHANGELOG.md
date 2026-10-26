# Changelog

## 1.0.4

### Added
- Entry "DotTrackerMinMax" in the game menu (Escape → Options → AddOns) with version, author, a list of all slash commands (`/dt`, `/dt test`, `/dt debug`), copyable links to GitHub and CurseForge and a button that opens the addon options.
- The .toc now has the correct title, description and version.

## 1.0.3

### Fixed
- Mind control: the Lua taint error "Frame:GetScaledRect(): Can't measure restricted regions" (blamed on DotTrackerMinMax) no longer appears when a DoT-affected enemy is mind controlled and changes faction. The text, skull and health bar segment are no longer created as children of Blizzard's nameplate frames. They live on `UIParent` and are only anchored to the nameplate. The health bar width is read with `pcall`, so a restricted bar is skipped instead of causing an error.
- Mind control: a mind controlled enemy is friendly and is no longer shown. Its DoT data is kept, so the display returns when it turns hostile again.
- Mind control: a mind controlled or possessed unit in the pet slot no longer counts as your pet for "Only enemies I attacked". Its attacks, and attacks on it, no longer mark enemies as attacked.

## 1.0.2

### Added
- Four sliders in the options window: horizontal and vertical offset of the text and skull, text size and skull size. Values are saved.
- "Test" button in the options window, same as `/dt test` (adds fake DoTs to your target for 30 seconds).

### Changed
- Default position of the text and skull moved to the left so they no longer overlap the floating damage text.
- The login message is gone. Instead, one chat hint per session appears the first time a DoT is tracked while enemy nameplates are off, naming your actual key binding for "Display Enemy Nameplates".

### Documentation
- README describes the sliders and the test button.

## 1.0.1

### Added
- Track DoTs cast by other players on enemies (option "Track DoTs of other players", on by default). Each caster is tracked separately and all damage is summed into one value.
- Lookup table `DOT_LOOKUP` with 22 Classic DoTs (Warlock, Warrior, Rogue, Hunter, Druid, Priest, Mage, Shaman), using base durations without talents.
- Option "Track only enemies I attacked" (off by default): only shows enemies that you or your pet have attacked.

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
