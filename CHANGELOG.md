# TradeShieldTBC Changelog

## 1.1.11
- Updated CurseForge project ID metadata to 1478379.
- Version bump for auto-update release verification.


## 1.1.9
- Restored classic `zip` packaging step for release workflow reliability.
- Kept `softprops/action-gh-release` + CurseForge upload on tagged releases.

## 1.1.8
- Reverted to `softprops/action-gh-release` for GitHub release creation to match a previously stable workflow pattern.
- Kept Python-based deterministic zip creation and CurseForge upload in `v*` tag workflow.

## 1.1.4
- Added automated CurseForge publishing in the GitHub Actions release pipeline.
- Release workflow now uploads both GitHub release artifact and CurseForge package for `v*` tags.
- Added a conditional guard so CurseForge upload only runs when API token/project secrets are configured.

## 1.1.0
- Added mail risk controls
  - Added mail recipient whitelist (`/ts mailwl add <name>`, `/ts mailwl remove <name>`, `/ts mailwl list`).
  - Risk warnings no longer trigger for whitelisted recipients.
  - Added `/ts mailsound on|off` to independently control mail-risk alert sound.
  - Mail risk checks now skip when no recipient is filled.
- Added minimap affordance with `LibDataBroker-1.1` + `LibDBIcon-1.0`
  - Added minimap icon with lightweight status/command hints in tooltip.
  - Left click prints current status; right click toggles master alert sound.
  - Persistence uses `TradeShieldTBCDB.minimap`.
- Added `CHANGELOG.md`.
  - `/ts status` now includes mail sound + whitelist counts and current sound mode.

## 1.0.1
- Stability and trade checks fixes from the anniversary build:
  - Added mail and trade empty-item detection hardening.
  - Deduplicated repeated mail/trade state updates with retry-based re-check suppression.
  - Added stack-count comparison and same-icon swap detection for trade target changes.
  - Added item count aware swap/reduction checks to reduce false positives.
  - Added player/target warning counters and stable-time strict-mode guard.

- 1.1.1
- Added GitHub Actions release workflow and release zip artifact.

## 1.1.2
- Release pipeline test for Actions-based auto-update.
