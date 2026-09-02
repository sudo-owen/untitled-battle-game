# CLAUDE.md

## How to Work

**Constraints first, then design.** Before proposing any solution, identify the hard constraints (language semantics, type system, inheritance, runtime behavior). If the approach conflicts with a constraint, don't propose it. Zero band-aid attempts — if it doesn't fit cleanly, the design is wrong. Redesign, don't force.

**Measure before deducing.** When debugging, add one targeted diagnostic and look at the data. Don't build chains of reasoning from assumptions about what the code "should" do. If the first theory doesn't match observations, measure — don't generate more theories from the same unverified premises.

**Fix at the right layer.** Don't patch symptoms. If a fix requires callers to know implementation details, it's at the wrong layer. If the same pattern needs 3+ special cases, the abstraction is wrong.

## Project Overview

**chomp.** (Credibly Hackable On-chain Monster PvP) is an on-chain turn-based PvP battling game inspired by Pokemon Showdown. Built on Solidity using the Foundry framework, it features an extensible battle engine where users can create custom moves, monsters ("mons"), effects, abilities, and hooks.

**License:** AGPL-3.0
**Solidity version:** ^0.8.34

## Quick Start

```bash
forge install        # Install dependencies (forge-std)
forge build          # Compile contracts
FOUNDRY_PROFILE=fast forge test           # Run all tests
FOUNDRY_PROFILE=fast forge test -vvv      # Run tests with verbose output
```

Engine edits invalidate most of the production-profile dependency graph. For correctness-only
iteration, use the separate fast profile and a narrow path; it keeps via-IR (required by Engine)
but disables optimization/build-info, enables sparse compilation, and uses a separate cache:

```bash
FOUNDRY_PROFILE=fast forge test --match-path test/EngineTest.sol
```

Always use `profile.fast` for correctness, regression, and full-suite test gates. Use the default
profile only for explicit gas comparisons and snapshots; the fast profile disables snapshot
emission so an accidental gas-test run cannot overwrite production-profile numbers.

## Repository Structure

```
chomp/
├── src/                    # Solidity source contracts
│   ├── Engine.sol          # Core battle engine (main entry point)
│   ├── IEngine.sol         # Engine interface
│   ├── Structs.sol         # All shared data structures
│   ├── Enums.sol           # All shared enums (Type, MoveClass, EffectStep, etc.)
│   ├── Constants.sol       # Global constants (move indices, battle modes, slots/targeting, sentinels)
│   ├── DefaultRuleset.sol  # Configures initial global effects for battles
│   ├── IRuleset.sol        # Ruleset interface
│   ├── IEngineHook.sol     # Hook interface for battle lifecycle events
│   ├── abilities/          # Ability interface (IAbility.sol)
│   ├── commit-manager/     # External commit-reveal move managers (singles only; the dual-signed
│   │                       #   per-turn buffer and all 2-slot flows now live in the Engine)
│   │   ├── DefaultCommitManager.sol  # Classic 2-player commit/reveal (base class) (deprecated)
│   │   ├── SignedCommitManager.sol   # EIP-712 single-tx dual-signed moves (deployed manager) (deprecated)
│   │   ├── SignedCommitLib.sol       # Shared signed-commit helpers
│   │   └── ICommitManager.sol
│   ├── cpu/                # PvE host (on-chain CPU decision-making removed; moves come from the client)
│   │   ├── CPU.sol                # Self-registering matchmaker + one-tx config-and-start bundles
│   │   │                          #   (startCustomBattle / startCustomMultiBattle)
│   │   └── CPUMoveManager.sol     # Relays client-computed CPU moves through the Engine
│   ├── effects/            # Effect system (status effects, battlefield)
│   │   ├── IEffect.sol     # Effect interface with lifecycle hooks
│   │   ├── BasicEffect.sol
│   │   ├── StaminaRegen.sol
│   │   ├── status/         # Status effects (Blessed, Burn, Frostbite, Panic, Sleep, Zap) + StatusEffect marker base + IStatusEffect (onReapply)
│   │   ├── battlefield/    # Battlefield effects (Overclock)
│   ├── game-layer/         # Team / mon registry, gacha, exp, facets, quests, gifts
│   │   ├── GachaTeamRegistry.sol   # Concrete leaf: composes the abstracts below
│   │   ├── MonOwnership.sol        # monsOwned set + ownership view/check helpers
│   │   ├── MonRegistry.sol         # Owner-managed mon catalog (stats / moves / abilities / metadata)
│   │   ├── PlayerProfile.sol       # Packed playerData slot, CPU/whitelist flags, assigner allowlist
│   │   ├── PackedTeamStore.sol     # Bit-packed team CRUD (4 teams per slot, 16 slots per player)
│   │   ├── Facets.sol              # 12-facet ± stat tradeoff system (abstract)
│   │   ├── MonExp.sol              # Packed exp, level curve, level-up facet draws, assignExp
│   │   ├── Quests.sol              # Daily quest pool + packed predicate evaluator (abstract)
│   │   ├── ReturnerGift.sol        # Daily-return points + exp gift contract (assigner)
│   │   ├── ITeamRegistry.sol       # Public read/write surface that the leaf exposes
│   │   ├── IGachaPointsAssigner.sol / IExpAssigner.sol  # Owner-allowlisted off-band grants
│   │   └── IPhantomTeamRegistry.sol  # CPU-relayer entry for writing user phantom team configs
│   ├── hooks/              # Engine hooks (e.g. SimplePM)
│   ├── lib/                # Utility libraries: ECDSA, EIP712, Ownable, EnumerableSetLib,
│   │                       # MappingAllocator, MerkleProofLib, Multicall3, RNGLib, StaminaRegenLogic,
│   │                       # StatBoostLib, SwitchTargetLib, TargetLib (slot/target helpers),
│   │                       # ValidatorLogic (pure validation helpers; the external IValidator is gone)
│   ├── matchmaker/         # Battle matchmaking
│   │   ├── DefaultMatchmaker.sol     # Propose/accept/confirm (DEPRECATED, singles, test-only)
│   │   ├── SignedMatchmaker.sol      # EIP-712 startGame — production; all modes, party/open seats
│   │   ├── BattleOfferLib.sol        # Shared offer-hash + seat helpers (battleMode is signed)
│   │   └── IMatchmaker.sol           # Bare marker interface (auth gate; validateMatch removed)
│   ├── mons/               # Individual mon implementations (one dir per mon)
│   │   ├── <monname>/      # Lowercase dir: 4 move .sol files + 1 ability .sol (+ optional libs)
│   │   ├── aurox/          # e.g. BullRush.sol, GildedRecovery.sol, IronWall.sol, UpOnly.sol, ...
│   │   ├── embursa/        # e.g. HeatBeacon.sol, SetAblaze.sol, Tinderclaws.sol, ...
│   │   └── ...             # ~13 mons total; see drool/mons.csv for the full roster
│   ├── moves/              # Move system
│   │   ├── IMoveSet.sol               # Move interface (move() + bundled getMeta()→MoveMeta)
│   │   ├── StandardAttack.sol         # Base attack implementation
│   │   ├── StandardAttackFactory.sol
│   │   ├── StandardAttackStructs.sol  # ATTACK_PARAMS struct
│   │   ├── AttackCalculator.sol       # Damage calc (delegates to Engine dispatch)
│   │   └── MoveSlotLib.sol            # Inline move-word packing (moveType/class/priority/stamina/basePower)
│   ├── rng/                # Randomness oracle interfaces + DefaultRandomnessOracle
│   │                       # (IRandomnessOracle for battles, IGachaRNG for the gacha)
│   └── types/              # Type effectiveness calculator (TypeCalculator + TypeCalcLib)
├── test/                   # Foundry test suite
│   ├── abstract/BattleHelper.sol  # Shared test helper (battle setup, commit-reveal)
│   ├── mocks/              # Mock contracts for testing
│   ├── effects/            # Effect-specific tests
│   ├── mons/               # Per-mon integration tests
│   ├── moves/              # Move system tests
│   ├── EngineTest.sol      # Core engine tests
│   ├── EngineGasTest.sol   # Gas benchmarks
│   └── *.sol               # Other test files
├── script/                 # Foundry deployment scripts
│   ├── EngineAndPeriphery.s.sol  # Deploy engine + periphery contracts
│   ├── mons/               # One deploy script per mon (auto-generated by processing/)
│   │   └── Setup<Mon>.s.sol      # <Mon>Deploy abstract recipe + Setup<Mon> broadcast runner
│   ├── DeployData.sol      # Shared {name, address} return shape parsed by deploy.py
│   ├── SetupCPU.s.sol      # Deploy CPU players
│   ├── cpu-teams.json      # CPU team source of truth (edit via processing/editData.py)
│   └── Surgery.s.sol       # Maintenance/upgrade script
├── processing/             # Python build scripts
│   ├── generateSolidity.py          # Generate script/mons/Setup<Mon>.s.sol from CSV data
│   ├── generateSetupCPU.py          # Generate SetupCPU.s.sol team config from cpu-teams.json
│   ├── editData.py                  # Local visual editor: mon stats, move rows, CPU teams (writes + resyncs)
│   ├── csvTable.py                  # Quote-preserving CSV read/write for drool/*.csv
│   ├── validateMoves.py             # Validate move contracts match CSV data
│   ├── validateEffectBitmaps.py     # Validate IEffect contracts set ALWAYS_APPLIES_BIT correctly
│   ├── deploy.py                    # Full deployment pipeline orchestrator
│   ├── deploy_addresses.py          # Inline ability/move address packing for the deploy pipeline
│   ├── buildTypeChart.py            # Build type effectiveness chart
│   ├── buildDamageGifs.py           # Render damage-preview GIFs
│   ├── buildMonGifs.py              # Slice horizontal sprite sheets back into GIFs
│   ├── createAddressAndABIs.py      # Extract deployed addresses + ABIs
│   ├── generateMonsTypeScript.py    # Generate TypeScript mon data
│   ├── generateEventLayouts.py      # Generate generated/eventLayouts.ts (GachaEvent bit layout)
│   ├── generateEip712Meta.py        # Generate generated/eip712Meta.ts (typehash strings + domains)
│   ├── createMonSpritesheets.py     # Generate mon spritesheets
│   ├── createAttackSpritesheets.py  # Generate attack spritesheets
│   ├── packMoves.py                 # Pack move data for distribution
│   ├── inputToEnv.py                # Parse forge output to .env
│   └── removeUnusedImports.py       # Clean up unused Solidity imports
├── transpiler/             # Solidity-to-TypeScript/Rust transpiler (Python; run via `python3 -m transpiler`)
│   ├── sol2ts.py           # TypeScript backend driver (not directly runnable — use `-m transpiler`)
│   ├── sol2rs.py           # Rust backend driver (`--target rust`)
│   ├── lexer/              # Tokenizer
│   ├── parser/             # AST construction
│   ├── type_system/        # Type registry
│   ├── codegen/            # TypeScript code generation
│   ├── codegen_rs/         # Rust code generation
│   ├── runtime/            # TypeScript runtime library
│   ├── runtime-rs/, strategies-rs/  # Hand-written Rust crates (rsynced into rs-output/)
│   ├── dependency_resolver/ # Dependency resolution
│   └── test_transpiler.py  # Transpiler unit tests (the TS integration tests live in munch)
├── drool/                  # Game data (CSV) and sprite assets — data only; the Tauri viewer it
│   │                       #   used to host was replaced by processing/editData.py
│   ├── mons.csv            # Mon stats (HP, attack, speed, types, etc.)
│   ├── moves.csv           # Move definitions (power, stamina, accuracy, etc.)
│   ├── abilities.csv       # Ability definitions
│   ├── types.csv           # Type chart data
│   ├── type-metadata.csv   # Per-type display fields (kanji, colours, abbreviations)
│   └── imgs/               # Sprites (front/back/mini GIFs, spritesheets)
├── docs/                   # Design docs and notes
├── snapshots/              # Foundry gas snapshots (JSON)
├── lib/                    # Git submodules (forge-std)
└── foundry.toml            # Foundry configuration
```

## Architecture

### Battle Modes

Every battle runs in one of three modes (a `uint8` in `BattleConfig.battleMode`, mirrored onto
`BattleData` as `isTwoSlotMode`/`isMultiMode` at start):

| Mode | Const | Actives / side | Controllers |
|------|-------|----------------|-------------|
| Singles | `BATTLE_MODE_SINGLES` (0) | 1 | p0 vs p1 |
| Doubles | `BATTLE_MODE_DOUBLES` (1) | 2 (slots 0 & 1) | one controller per side (p0 drives both of side 0's slots) |
| Multi | `BATTLE_MODE_MULTI` (2) | 2 | 4 seats, one per slot (p0, p1, p2, p3) |

- **Singles** keeps the legacy storage layout byte-identical (slot-1 lanes are never touched).
- **Doubles / Multi** are the "2-slot" family. In **Multi**, each side's 8-mon roster is the
  concatenation of its two seats' 4-mon teams at a fixed stride-4 partition (seat 0 → roster
  `[0..3]`, seat 1 → `[4..7]`); the extra seats live in `multiSeats[battleKey]` (`MultiSeatData`).
- **Canonical seat order is `[p0, p2, p1, p3]`** (side-major) — used by `getSeats`, seat rotation,
  and the `cpuSeatMask`. This is NOT the `Battle` struct field order.
- `startBattle()` starts a singles battle; `startBattleWithMode(battle, mode)` validates the mode
  byte and the p2/p3 invariant (Multi requires both non-zero; Singles/Doubles forbid them). Battle
  keys derive from `computeBattleKey(p0, p1)` (Singles/Doubles) or `computePartyKey(p0, p1, p2, p3)`
  (Multi).

### Slots & Targeting

- **Absolute slot** = `side*2 + slotIndex` (0,1 = side 0; 2,3 = side 1). `activesPacked` carries one
  8-bit lane per absolute slot holding that slot's active roster index (`EMPTY_ACTIVE_LANE = 0xFF`).
  Slot-0 lanes live in `BattleData.activeMonIndex`, slot-1 lanes in `activeMonExt`. Moves and
  effects resolve targets from `activesPacked` via `TargetLib` — no calls back into the Engine.
- A move's 16-bit wire `extraData` splits `[targetBits 4 | payload 12]`: the top nibble is a bitmask
  over absolute slots (the chosen target), the low 12 bits are the move's own payload (team indices,
  ModalBolt modes, …). The Engine strips the nibble before invoking the move.
- A move's target domain is **not** declared in Solidity: its `move()` either resolves a defender
  from `targetBits` (slot-targeting) or ignores it (self-buffs, global setups, or payload-targeted
  moves like Sneak Attack). `drool/moves.csv`'s `TargetSpec` column is the authoritative client-facing
  metadata (→ TS `Move.targetSpec`), and `validateMoves.py` checks each move's `targetBits` behavior
  against it. **Singles ignores the nibble** — targeting is implied (the opposing active).

### Core Battle Flow

1. **Matchmaking**: production battles use `SignedMatchmaker.startGame(offer, openSeatsMask,
   seatSigs)` — one EIP-712 `BattleOffer` whose `battleMode` is part of the signed struct, with
   open-seat / SeatFill support for party (Multi) games. (`DefaultMatchmaker` is deprecated,
   singles-only, test-suite-only.) PvE battles are opened by the player calling
   `CPU.startCustomBattle` / `startCustomMultiBattle` — one tx that writes the phantom opponent team
   config and starts the battle.
2. **Battle Start**: `Engine.startBattle(WithMode)` snapshots teams (validated against the
   `ITeamRegistry` snapshot + a per-seat 4-mon length check), gates every seat through matchmaker
   authorization, and stores mode / seat data. Validation is fully inline — there is no external
   `IValidator`.
3. **Move submission** (one path per battle, chosen by `moveManager`):
   - **Built-in dual-signed buffer** (default PvP): `moveManager == BUILTIN_DUAL_SIGNED_MANAGER`
     (`0x5165`) routes through the Engine's own buffer — `submitTurnMoves` / `submitSlotTurnMoves`
     stage a signature-checked turn; `executeBuffered` drains it.
   - **External commit manager** (`SignedCommitManager`): singles single-tx `executeWithDualSignedMoves`.
   - **2-slot turns**: `executeWithSlotMoves(key, side0Packed, side1Packed)` (one packed word per
     side); whole-game replays via `executeBatchedTurns` / `executeBatchedSlotTurns`.
4. **Turn Resolution**:
   - **Singles**: RNG from both salts → priority player (higher move priority; effective speed
     tie-break; `rng % 2` on a full tie) → RoundStart effects → priority move → AfterMove / stamina
     → other move → (turn 0: switch-in abilities) → RoundEnd effects. A KO locks the winner
     immediately at the KO site.
   - **2-slot (Doubles / Multi)**: a greedy dynamic scheduler makes up to 4 picks, each choosing the
     un-acted live slot with the highest (locked priority, live speed, fresh jitter). KO'd actives
     don't act, and KOs never cancel remaining actions — only game-over returns early. Empty lanes
     act only on turn 0 (send-ins).
   - **Effects** run at their lifecycle hooks (RoundStart, PreDamage, AfterDamage, AfterMove,
     RoundEnd, …); `PreDamage` lets mon-local effects mutate the in-flight damage via
     `getPreDamage` / `setPreDamage`.
   - **Forced switches** are encoded in `playerSwitchForTurnFlag`: singles uses `0`/`1` (that side
     switches) vs `2` (both act); 2-slot uses `0x80 | slotMask` (only the masked KO'd slots switch)
     vs `2` (full turn).
5. **Battle End**: when a full side is KO'd, on timeout (`end()` after `MAX_BATTLE_DURATION`), or via
   `forfeit(battleKey)` (concede — the opposing side's lead is credited; grants no gacha rewards).

### Key Interfaces

| Interface | Purpose |
|-----------|---------|
| `IEngine` | Core battle engine - state mutation, battle management |
| `IMoveSet` | Move contract - `move()` (slot-targeted), `getMeta()`→`MoveMeta`, `priority()`, `stamina()`, `moveType()`, `moveClass()` |
| `IEffect` | Effect lifecycle - `onRoundStart()`, `onPreDamage()`, `onAfterDamage()`, `onRemove()`, etc. (all take `activesPacked`) |
| `IAbility` | Mon ability - `activateOnSwitch()` |
| `IRuleset` | Initial battle configuration (global effects) |
| `ICommitManager` | External commit-reveal move management (singles only) |
| `IMatchmaker` | Bare marker interface — the Engine's matchmaker authorization gate |
| `ITeamRegistry` | Combined team CRUD + mon catalog + exp/level + facet getters (implemented by `GachaTeamRegistry` via its abstract bases) |
| `IGachaPointsAssigner` / `IExpAssigner` | Owner-allowlisted off-band grants of points / exp (e.g. `ReturnerGift`) |
| `IPhantomTeamRegistry` | CPU-relayer entry for writing a user's phantom team config from a whitelisted CPU |
| `IEngineHook` | Battle lifecycle hooks (OnBattleStart, OnRoundStart, OnRoundEnd, OnBattleEnd) |
| `IRandomnessOracle` / `IGachaRNG` | RNG sources, scoped by consumer |

### Move System

Moves implement `IMoveSet`. Most standard attacks extend `StandardAttack`, which takes `ATTACK_PARAMS`:

```solidity
ATTACK_PARAMS({
    BASE_POWER: 50,
    STAMINA_COST: 2,
    ACCURACY: 100,
    PRIORITY: DEFAULT_PRIORITY,    // DEFAULT_PRIORITY = 3
    MOVE_TYPE: Type.Fire,
    EFFECT_ACCURACY: 30,
    MOVE_CLASS: MoveClass.Physical,
    CRIT_RATE: DEFAULT_CRIT_RATE,  // 5
    VOLATILITY: DEFAULT_VOL,       // 10
    NAME: "Tinderclaws",
    EFFECT: IEffect(address(0))
})
```

These are packed into inline move words (see `MoveSlotLib`) rather than deployed as separate
contracts. `StandardAttack`'s base `move()` resolves the defender
from `targetBits`; a move's client-facing target domain lives in `moves.csv`'s `TargetSpec` column,
not in Solidity.

**Inline moves.** A move with a `src/mons/<mon>/<Move>.json` file is packed inline instead of
deployed. The file holds only `{"effect": "<EffectContract>" | null}` — every packed field
(`basePower`, `staminaCost`, `moveType`, `moveClass`, priority offset, and `EFFECT_ACCURACY` from
the `Constants` column) is read from the move's `moves.csv` row by
`packMoves.inline_params_from_csv`, so the CSV is the single source of truth and can't drift from
the deployed word. `validateMoves.py` checks each inline row is *representable* (accuracy 100,
priority offset 0-3, power ≤ 255, stamina ≤ 15, no constants besides `EFFECT_ACCURACY`) rather than
comparing it against a second copy. The same CSV-sourced packing is mirrored in
`sims/src/util/inline-pack.ts` and `transpiler/strategies-rs/src/roster.rs`.

Custom moves implement `IMoveSet` directly for complex behavior. The current interface is
`move(engine, battleKey, attackerPlayerIndex, attackerMonIndex, targetBits, activesPacked,
extraData, rng)` plus the metadata getters (`priority`/`stamina`/`moveType`/`moveClass`) and the
bundled `getMeta()`→`MoveMeta` (`{moveType, moveClass, priority, stamina, basePower}`).
Moves resolve targets from `targetBits` + `activesPacked` via `TargetLib` (they no longer receive a
defender index), and deal damage through `engine.dispatchStandardAttack` / `dispatchCustomAttack`
(both take `targetBits`).

`getMeta().basePower` means **damage on the turn the move is cast**, and it is the only basePower
source — there is no separate getter to probe. A move whose damage is deferred (Q5, King's Respite)
or conditional must report `0` even when it holds a `BASE_POWER` constant for the eventual hit: the
off-chain CPU treats a nonzero quote as this-turn damage and a zero quote as "simulate it", so
advertising nominal power makes the CPU throw the move away on turns it does nothing.

### Effect System

Effects implement `IEffect` with a bitmap (`getStepsBitmap()`) indicating which lifecycle steps they
run at:
- `OnApply` (0x01), `RoundStart` (0x02), `RoundEnd` (0x04), `OnRemove` (0x08)
- `OnMonSwitchIn` (0x10), `OnMonSwitchOut` (0x20)
- `AfterDamage` (0x40), `AfterMove` (0x80), `OnUpdateMonState` (0x100), `PreDamage` (0x200)

`PreDamage` runs before damage is applied — subscribed effects read the in-flight value via
`engine.getPreDamage()` and mutate it via `engine.setPreDamage(int32)`, composing in effect-array
order (e.g. `Adaptor` halves matching damage). `AfterDamage`, `AfterMove`, `OnUpdateMonState`, and
`PreDamage` currently run **only on mon-local effects** (global effects skip them). Every lifecycle
hook now receives `activesPacked` so effects can resolve slots via `TargetLib` without calling back
into the Engine.

Effects can be per-mon (local; `targetIndex` = the owning player index) or global (battlefield-wide;
side index `2`). The `StaminaRegen` effect is a global default that regenerates 1 stamina per turn.

#### Opt-in fresh hook context (gas path)

Before adding an Engine getter inside a lifecycle hook, check whether the value is already available
in that hook's packed context. `getStepsBitmap()` returns `uint32`: the low 16 bits are lifecycle
subscriptions and the corresponding high 16 bits request fresh context. For example, an
`AfterMove` listener (`0x80`) requests context with `0x0080_0000`, so a typical bitmap is
`0x0080_8080` (`AfterMove` context + `ALWAYS_APPLIES_BIT` + `AfterMove`). Legacy effects that only
return low bits remain compatible.

Supported layouts, decoded through `TargetLib`:

- `OnApply`: the target mon's max HP via `hookMonMaxHp(context)`. This request is consumed before
  installation and is not persisted as a recurring context capability.
- `AfterMove`: current 24-bit move words via `hookMoveWordAt(context, absSlot)` and acted bits via
  `hookSlotActed(context, absSlot)`.
- `AfterDamage`: the damaged mon's finalized KO state via `hookMonIsKnockedOut(context)`.
- `PreDamage`: current signed in-flight damage via `hookPreDamage(context)`.
- `RoundEnd`: current status classes via `hookStatusClass(context, side, monIndex)`.
- `OnUpdateMonState`: the changed mon's max HP and normalized signed HP delta via
  `hookMonMaxHp(context)` / `hookMonHpDelta(context)`.

Snapshots are built immediately before each requesting callback, after earlier effects in the same
pass, so hooks must not cache them across calls. Context replaces read-only callbacks; mutations
still go through Engine functions. Prefer it when a hook would otherwise call an Engine getter, and
add a mutation-order regression when an earlier hook can change the observed value.

The stored effect header currently collapses any nonzero high-half request to one capability bit.
Consequently, a multi-hook effect receives every context supported for each hook it subscribes to,
even if it requested only one step. Benchmark multi-hook migrations: an unused builder at a frequent
hook can outweigh the removed callback. Ordinary `IMoveSet.move()` execution does not yet receive
these lifecycle layouts; only moves/abilities that also register as effects can use them in their
effect hooks. Ordinary tagged deployed moves may separately opt into supported move context through
metadata capabilities: `@move-context: status-lanes` makes the deployment generator set
`MOVE_CONTEXT_STATUS_LANES`, and `move()` can then use `TargetLib.hookStatusClass`. Keep these
capabilities generic; do not add address-specific Engine dispatch.

For ordinary moves/effects outside a supported packed hook context, use the narrowest typed bundled
getter matching the data shape. In particular, overheal clamps should call
`getMonHpState(battleKey, player, mon)` for `(maxHp, hpDelta)` rather than making separate
`getMonValueForBattle(Hp)` and `getMonStateForBattle(Hp)` external calls. Do not add raw-slot or
large generic snapshot APIs; add a new bundle only when multiple mechanics share the exact shape.

### Stat Boosts (inlined into the Engine)

Stat modifiers are **not** a separate effect contract — they are native Engine functions:
`addStatBoost` / `removeStatBoost` / `clearAllStatBoosts`
(declared in `IEngine`). Moves, abilities, and shared effects (`BurnStatus`, `FrostbiteStatus`,
`Overclock`, `UpOnly`, `Tinderclaws`, …) call `engine.addStatBoost(...)` directly during `execute`.
The packing/aggregation math lives in `src/lib/StatBoostLib.sol`. (Historically this was an external
`StatBoosts` effect that the Engine called back into ~10–15× per application; inlining removed those
round-trips.)

How it works:
- Each boost **source** is one packed word in a dedicated per-mon boost store
  (`p0BoostWords`/`p1BoostWords`; 4-bit counts in `p0/p1BoostCounts`; the aggregate is recomputed
  from the words on every change) — NOT an effect-list entry, so effect passes never iterate boost sources.
  Sources are keyed by `msg.sender`, so each move/ability/effect
  stacks independently and can remove its own boost. Boosts are **multiplicative** per source; `Temp`
  boosts are dropped on switch-out by a direct `_inlineStatBoostSwitchOut` call in `_handleSwitch`,
  `Perm` ones persist.
- Boosts apply only to the 5 stat deltas: `Speed`, `Attack`, `Defense`, `SpecialAttack`,
  `SpecialDefense`. There is **no globalKV snapshot** — the Engine telescopes off the live `monState`
  delta (`new boosted − base − currentDelta`) and fires `OnUpdateMonState` like any other delta write.
- **Ownership invariant:** the stat-boost system is the *sole* writer of those 5 deltas. External
  `updateMonState` calls with `Speed`..`SpecialDefense` **revert with `StatRequiresStatBoost`** — to
  change a stat you must go through `add`/`removeStatBoost`, never `updateMonState`. (`Hp`, `Stamina`,
  `IsKnockedOut`, `ShouldSkipTurn` remain writable via `updateMonState`.)

### Type System

15 types: Yin, Yang, Earth, Liquid, Fire, Metal, Ice, Nature, Lightning, Faith, Air, Math, Cyber, Cosmic, None. Type effectiveness is calculated by `ITypeCalculator`.

### Gacha & Progression System

`GachaTeamRegistry` (points, exp, facets, quests, rolling) is documented in `src/game-layer/CLAUDE.md`, which loads automatically when working under that directory.

### Storage Architecture

- `BattleData` and `BattleConfig` are stored per battle key (derived from player addresses)
- `MonState` tracks deltas from base stats (hpDelta, staminaDelta, etc.). The 5 stat deltas are written only by the inlined stat-boost path (see "Stat Boosts"); other deltas via `updateMonState`.
- Effects stored in per-mon mappings with stride-based indexing (64 slots per mon). Stat-boost sources live in dedicated per-mon boost-word mappings (`p0/p1BoostWords` + packed counts), not the effect mappings.
- Heavy use of bit packing for gas efficiency (KO bitmaps, effect counts, active mon indices)
- Battle mode is a `uint8` in `BattleConfig.battleMode` (mirrored to `BattleData.isTwoSlotMode`/`isMultiMode`). Slot-0 active lanes pack into `BattleData.activeMonIndex` (side 0 = low byte, side 1 = high byte); 2-slot modes add slot-1 lanes in `activeMonExt`. Multi's extra seats (p2/p3) live in `multiSeats[battleKey]` (`MultiSeatData`), written only when `battleMode == MULTI`.
- Transient storage used for per-transaction state (`battleKeyForWrite`, `tempRNG`, in-flight `PreDamage`)
- `GachaTeamRegistry`'s storage is the union of its abstract bases; each base owns its own mappings/constants so the leaf is integration-only. Reordering the inheritance list would shift slot layout — keep the order in `GachaTeamRegistry.sol` stable across deploys.

## Development Conventions

### Solidity Style

- AGPL-3.0 license header on all files
- Pragma: `^0.8.0`
- Imports: Use named imports (`import {Foo} from "path"`) - `sort_imports = true` in formatter
- Optimizer: 10000 runs with via-IR enabled (bounded to cap deployed bytecode size; runs above ~1e6 saturate)
- Constants: `SCREAMING_SNAKE_CASE` (though lint excludes this check)
- Move indices: 0-3 for regular moves (stored +1 to avoid zero ambiguity), 125 = switch, 126 = no-op
- State sentinel: `CLEARED_MON_STATE_SENTINEL = type(int32).max - 1`

### Mon Directory Conventions

Each mon lives in `src/mons/<monname>/` (lowercase). A typical directory contains:
- **4 move contracts** — one `.sol` file per move, `PascalCase` matching the move name (e.g., "Bull Rush" → `BullRush.sol`)
- **1 ability contract** — `PascalCase.sol` matching the ability name (e.g., `UpOnly.sol`)
- **Optional library files** — shared logic between moves in the same mon (e.g., `NineNineNineLib.sol`, `HeatBeaconLib.sol`)

Each mon has exactly one test file at `test/mons/<MonName>Test.sol` (PascalCase + "Test", e.g., `AuroxTest.sol`). Tests extend `BattleHelper`.

The CSV files in `drool/` are the source of truth for mon stats, move parameters, and ability assignments. The Solidity contracts must match these values — run `python processing/validateMoves.py` to verify.

### Testing Patterns

- Tests extend `BattleHelper` (in `test/abstract/`) which provides:
  - `_startBattle()`: Full battle setup with matchmaker propose/accept/confirm
  - `_commitRevealExecuteForAliceAndBob()`: Execute a turn with commit-reveal
  - `ALICE` = `address(0x1)`, `BOB` = `address(0x2)`
- Per-mon tests in `test/mons/` test specific move interactions
- Mock contracts in `test/mocks/` for isolated testing
- Gas benchmarks in `EngineGasTest.sol` and `InlineEngineGasTest.sol` with JSON snapshots

### Development Approach

When implementing new features or refactors, follow a test-first approach:
1. Write tests that specify the desired behavior
2. Run to verify the tests fail (confirming they test new behavior)
3. Implement the changes
4. Run to verify the tests pass

### Adding a New Mon, Move, Ability, or Effect

The step-by-step workflow (CSV data, which move/ability contract pattern to choose, effect bitmap rules) is in the `add-game-content` skill (`.claude/skills/add-game-content/SKILL.md`) — invoke it when adding new game content.

## Build & Deploy Pipeline

Processing scripts, the Solidity-to-TS/Rust transpiler, deployment order, and CI/CD are documented in the `deploy-chomp` skill (`.claude/skills/deploy-chomp/SKILL.md`) — invoke it for codegen, validation, transpiling, or deployment tasks.

## Key Data Files

| File | Purpose |
|------|---------|
| `drool/mons.csv` | Mon stats: Id, Name, HP, Attack, Defense, SpAtk, SpDef, Speed, Type1, Type2, Flavor |
| `drool/moves.csv` | Move data: Name, Mon, Power, Stamina, Accuracy, Priority, Type, Class, DevDescription, UserDescription, InputType, UnlockLevel, Constants, TargetSpec |
| `drool/abilities.csv` | Ability assignments: Name, Mon, Effect |
| `drool/types.csv` | Type effectiveness chart |

CSV-to-code mapping notes:
- **Priority** in `moves.csv` is a signed offset from `DEFAULT_PRIORITY` (3). So `0` = default, `1` = faster, `-1` = slower.
- **Power** can be `?` for variable-power custom moves (Tier 3/4 implementations)
- **InputType** (`none` / `self-mon` / `opponent-mon` / `mode-select`) is client-facing metadata for the move-input UI (generated into the TS `MoveInputType`); it no longer maps to any Solidity enum
- **TargetSpec** (kebab-case: `opponent-slot` / `self-only` / `none` / `any-other-slot` / `ally-slot` / `any-subset`; blank = `any-other-slot`) is the authoritative client-facing target domain (generated into the TS `MoveTargetSpec`) — there is no Solidity enum. `validateMoves.py` validates it behaviorally: a slot-targeting spec must consume the `targetBits` nibble in `move()`, self-only/none must ignore it
- **Type2** is `"NA"` for single-type mons

## Known Issues / Gotchas

- If a move forces a switch before the other player acts, the new mon will still try to execute its move (Engine skips if stamina is insufficient)
- If an effect calls `dealDamage()` and triggers `AfterDamage`, it can cause infinite loops - avoid dealing damage in `onAfterDamage` hooks
- RNG reuse: `StandardAttack` uses the same RNG for both accuracy and effect chance, making them correlated rather than independent
- Malicious p0 can modify mon moves between commit and battle start - mitigate via team registry or adding move indices to integrity hash
- Forced-switch turns (KO replacements) run with `tempRNG == 0` in every flow — switch-in effects/abilities that consume rng (currently only PreemptiveShock's damage variance) roll a fixed constant on those turns. Deliberate for now; if chance-on-switch-in mechanics land, derive a fair value (e.g. persist the previous turn's rng and use `keccak(prevRng, turnId)`) rather than the switcher's own salt (grindable) or the stale batched rng (diverges between batched and per-turn flows)
- `MAX_BATTLE_DURATION` is 1 hour, enforced in `Engine.end()` (once elapsed, anyone can end a stale battle, awarding p0). There is no external validator anymore and no per-turn timeout currently wired in — `ValidatorLogic.validateTimeoutLogic` exists but is dormant
- DefaultMatchmaker (deprecated, test-suite-only) leaks/strands MappingAllocator pool keys on re-proposals and open-proposal cycles — documented won't-fix in its contract header; do not promote it back to production without fixing

## Gas Optimization Notes

- Storage bit-packing throughout (BattleData, BattleConfig, KO bitmaps, effect counts)
- Batch context structs (`BattleContext`, `DamageCalcContext`, `BattleEndContext`, `MoveMeta`) to reduce external calls / SLOADs
- Effect step bitmaps avoid calling effects at steps they don't use
- `MappingAllocator` for efficient storage slot management
- Transient storage for per-call state to avoid unnecessary SLOADs/SSTOREs
- Optimizer runs set to 10000 with via-IR; deploy gas, not EIP-170, is the binding size constraint
