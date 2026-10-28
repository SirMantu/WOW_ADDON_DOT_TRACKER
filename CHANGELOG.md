# Changelog

## 1.0.7

### Added
- **Warning button:** while the enemy health bars (nameplates) are turned off, a red warning button appears at the bottom right of the screen (`WARNING_OFFSET_X`, `WARNING_OFFSET_Y`). Hovering it explains that DotTrackerMinMax will not work correctly without the health bars. A click turns them on again (it changes the game setting `nameplateShowEnemies`; not possible during combat) and removes the warning. A right-click opens the options. The button can be turned off with the option "Red warning button while enemy health bars are off" (Display tab) and is not shown when "Show on the enemy nameplates" is off.

## 1.0.6

### Added
- MIT license: new file `LICENSE` (copyright Manuel Metzger), `## X-License: MIT` in the .toc, and the license is included in the CurseForge package (`license-output` in `.pkgmeta`) and in the zip made by `release.py`.
- Option "Show on the enemy nameplates" (Display tab, on by default). When it is off, the addon never touches the nameplates and shows everything only in the target display. Use it if you still get Lua taint errors.
- **Color per debuff:** the damage bar no longer uses "enemy survives" and "lethal" colors. It is now made of the single ticks still to come, in the order they land (the next tick is at the right end), and every tick has the color of its debuff. So you can see which DoT does how much. The default colors are the table `DEBUFF_COLORS` (22 debuffs). A thin line separates the ticks (option "Show lines between the ticks").
- New tab "Debuffs" in the options window with one color field per debuff, in two columns. "Reset colors" and "Reset all settings" restore the default debuff colors.
- Option "Also show the damage bar on the target frame": the damage bar is drawn on the health bar of the game's target frame too. Off by default.
- Option "Simple mode": the damage bar is drawn as one plain bar in the "simple mode bar color". The colored ticks, glass effect, flash and the calculations behind them (tick schedule) are skipped. Off by default.
- Tick flash: every tick that takes life away makes the part of the damage bar it removes (shown at the right end, where the life was lost) light up in white for a moment (0.1 seconds, `BAR_FLASH_SECONDS`, color `BAR_FLASH_COLOR`) and then disappear at once. Ticks in quick succession add up. There is no effect when the bar disappears completely, for example when the enemy dies.

### Changed
- The time to death on the skull is shown as a plain number without the "s", for example `6`, in red with a thick black outline, so it is easy to read on the white skull. The color can be changed with the new color field "Time to death color" on the Colors tab (default constant `TTD_COLOR`). The opacity of the color picker has no effect on it.
- The options window now has tabs (Display, Bar, Colors, Debuffs, Layout, Tracking), and the settings are sorted into groups with headings. The window is much lower than before (410 pixels instead of about 730). The buttons "Test" and "Reset all settings" stay at the bottom on every tab.
- The damage bar on the target frame is now 2 pixels shorter at the top and bottom (`TARGET_FRAME_INSET`).
- New defaults for the position and size of the text and skull: horizontal offset -94, vertical offset -75, text size 20, skull size 55. They apply to new installations and to "Reset all settings".

### Fixed
- Mind control: the Lua taint error "Can't measure restricted regions" came back when mind control ended on an enemy. The text, skull and damage bar are now only anchored to a nameplate while they show something. Everything that is not shown is cut loose from the nameplate at once, and the addon reacts to `UNIT_FACTION` right away.
- The damage bar on the nameplate of your target was hidden, because the target's nameplate is drawn above the others. The bar of the target now uses a higher frame strata.

## 1.0.5

### Added
- **Two bar colors:** the DoT damage bar is purple while the enemy survives the DoTs and black when the DoTs are lethal (0 or less life left).
- **Tick lines:** thin lines on the damage bar, one per tick still to come, in the order the ticks land.
- **Glass effect:** a gradient (lighter at the top, darker at the bottom) gives the bar depth.
- **Time to death:** when the DoTs are lethal, the seconds until the enemy dies are shown directly on the skull, for example `6`. The font size follows the skull size.
- The skull is bigger by default (55 instead of 32). Users who still had the old default size get the new one.
- Options: checkboxes for tick lines, glass effect and time to death.
- Three color fields in the options window (non-lethal bar color, lethal bar color, tick line color). A click opens the game's color picker, including opacity. The colors are saved, and a "Reset colors" button restores the defaults.
- The target display (shown when your target has no visible nameplate) now has all elements: besides the text, skull and time to death it shows a small health bar with the damage bar, tick lines and glass effect.
- Option "Also show current life": the number above the enemy and in the target display now shows the current life and the life after all DoTs, for example `1200 -> 350`. On by default.
- "Reset all settings" button in the options window: restores all checkboxes, sliders and colors to their defaults. It needs a second click within 4 seconds to confirm. The minimap button position is kept.

### Changed
- The damage bar is no longer black. Colors and sizes can also be changed with the constants `BAR_COLOR_NONLETHAL`, `BAR_COLOR_LETHAL`, `BAR_TICK_COLOR`, `BAR_GLASS_TOP_ALPHA`, `BAR_GLASS_BOTTOM_ALPHA`, `BAR_MAX_TICKS` and `BAR_INSET`.

### Fixed
- The segment is now aligned exactly with the health bar. It took the width of the bar in the nameplate's scale but was drawn in the scale of the screen, so it was too wide or too narrow.
- The segment no longer overlaps the border at the top and bottom of the health bar (`BAR_INSET`, 2 pixels).

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
