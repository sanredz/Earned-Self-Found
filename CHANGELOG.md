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
- Witness Record: witnesses remember which hours of your played time they
  heard your addon in. When anyone checks you, all answers are combined into
  a bar ("36 of 42 played hours witnessed by 27 players"), a plain verdict
  (Well / Partly / Barely witnessed) and named flags (saw a
  disqualification, saw you online without Earned). It's calculated by the
  person checking, never self-reported.
- Who was there: witnesses tell you when they saw your level-up or death,
  and your log shows who.
- Chat-command protection: the addon works on a private copy of its data
  that `/run` can't reach, exposes no global handle, and checks every
  `/played` response. A sealed copy is saved every 15 seconds and on every
  violation, so disconnects lose almost nothing.
- Disconnects: idle time after a disconnect (up to 3 minutes, while the
  server keeps the character in the world) is forgiven when gold, level, XP,
  bags and gear are unchanged. Untracked time where the character did change
  counts even when it's short.
- Player profiles: search for any player (with suggestions) or click one to
  see what your addon recorded over time, and ask every other witness in
  your guild and group what theirs recorded. Also `/sf check <name>` and "My
  profile".
- Online without Earned: witnesses record when a player known to run the
  addon is online but their addon sends nothing for 5 minutes. It's shown in
  profiles, the witness list and tooltips.
- Bank watch: if the bank's contents ever differ from how the addon last saw
  them, the bank was used without the addon, and the run becomes Unverified.
- Unforgeable sightings: heartbeats carry a token derived from a per-run
  secret key. Crash recoveries need a sighting that echoes a real token. A
  token-proven disqualification that was lost to a crash is restored.
- `/sf preview` shows the disqualification alert without saving or sharing
  anything.
- Griefing protection: other players can never disqualify you or make you
  Unverified. Witness claims are recorded by name and shown in Verify with how
  many witnesses back them. Messages from players outside your guild or group
  are ignored.
- Shareable reports with a checksum, and a Verify tool that cross-checks a
  report against your own witness records.

### Interface
- Native-style window with Overview, Ledger, Log and Witnesses tabs.
- Minimap button, addon compartment entry, player tooltip status, `/sf`.
