# Changelog

All notable changes to Earned: Self Found. Versions follow
[Semantic Versioning](https://semver.org): MAJOR for changes that break saved
data or the witness protocol, MINOR for new features, PATCH for fixes.

## [Unreleased]

## [1.0.0] - 2026-09-29

First release.

### Rules
- Immediate disqualification for completing a trade where anything changes
  hands, bidding on / buying out / listing an auction, taking items or gold
  from mail sent by another player, and guild bank or Warband bank
  withdrawals.
- Runs are marked Unverified for play time the addon didn't see (checked
  against `/played`) or when installed on a character that already had play
  time.
- Warning banner above trade, auction, mail and bank windows.

### Tracking
- Deaths, kills, quests, levels, trades, auction house activity, mail.
- Gold ledger: income by source (looted gold, quests, vendor sales,
  mail/auctions, other) and spending by category (vendor, repairs, training,
  flights, fees, given away).
- Net worth: gold plus the vendor value of bags, equipped items and bank, with
  peak value.
- Items looted, sold and destroyed.

### Integrity
- Hash-chained event log and a seal over all saved data; editing the saved
  file outside the game disqualifies the run.
- Witnesses: players running the addon in the same guild or group exchange
  status heartbeats every minute and keep records of each other. Sharing is
  always on.
- Crash recovery: play time lost to a game crash is recovered when witnesses
  heard from the addon right up until the crash. Each recovery lists the
  witnesses who confirmed it.
- Griefing protection: other players can never disqualify you or make you
  Unverified. Witness claims are recorded by name and shown in Verify with how
  many witnesses back them. Messages from players outside your guild or group
  are ignored.
- Shareable reports with a checksum, and a Verify tool that cross-checks a
  report against your own witness records.

### Interface
- Native-style window with Overview, Ledger, Log and Witnesses tabs.
- Minimap button, addon compartment entry, player tooltip status, `/sf`.
