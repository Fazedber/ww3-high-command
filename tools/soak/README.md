# Soak test (Studio only, never shipped)

1. `JEV_KEY=... node tools/soak/jev-policy.mjs` asks TypeSafe Jev for an action
   distribution per coarse game-state bucket and writes `policy.json`
   (the key is read from the environment only; never commit it).
2. `node tools/soak/mkauto.cjs` embeds the policy into `AutoPlay.rbxmx`.
3. In Studio: import `AutoPlay.rbxmx` into ReplicatedStorage, start a
   multiplayer playtest, start a match, then on each client run
   `require(game.ReplicatedStorage.AutoPlay).start(1.0)`.
   Read `require(game.ReplicatedStorage.AutoPlay).stats` and the server's
   `_G.OpenFront.perf` (tick cost) afterwards.

Every 7th decision sends a malformed intent to probe server validation.
