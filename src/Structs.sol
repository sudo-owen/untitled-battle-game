// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {MOVE_LANES_PER_MON} from "./Constants.sol";
import {MonStateIndexName, MoveClass, StatBoostType, Type} from "./Enums.sol";
import {IEngineHook} from "./IEngineHook.sol";
import {IRuleset} from "./IRuleset.sol";
import {IEffect} from "./effects/IEffect.sol";
import {ITeamRegistry} from "./game-layer/ITeamRegistry.sol";
import {IMatchmaker} from "./matchmaker/IMatchmaker.sol";
import {IRandomnessOracle} from "./rng/IRandomnessOracle.sol";

// Used by DefaultMatchmaker
struct ProposedBattle {
    address p0;
    uint96 p0TeamIndex;
    bytes32 p0TeamHash;
    address p1;
    uint96 p1TeamIndex;
    ITeamRegistry teamRegistry;
    IRandomnessOracle rngOracle;
    IRuleset ruleset;
    address moveManager;
    IMatchmaker matchmaker;
    IEngineHook[] engineHooks;
}

// Used by CPU.startCustomBattle: bundles phantom team-config writes with battle start.
// p1 (= the CPU calling startCustomBattle) and p1TeamIndex (= uint16(uint160(p0)))
// are derived inside the CPU contract, so they're omitted here. p0TeamHash is
// unused in the phantom flow.
struct CustomBattleProposal {
    address p0;
    uint96 p0TeamIndex;
    uint256[] monIndices;
    uint8[] facetIds;
    uint8[] moveSelections;
    ITeamRegistry teamRegistry;
    IRandomnessOracle rngOracle;
    IRuleset ruleset;
    address moveManager;
    IMatchmaker matchmaker;
    IEngineHook[] engineHooks;
    uint8 battleMode; // BATTLE_MODE_* (SINGLES or DOUBLES; Multi seats don't fit this shape)
}

// Used by CPU.startCustomMultiBattle: the 4-seat (Multi) analog of CustomBattleProposal —
// bundles the phantom-config writes for every CPU seat with the battle start. seatConfigs
// aligns with (p1, p2, p3); a config is applied only when the registry whitelists that seat
// (its team index is then forced to p0's phantom key), and an empty monIndices skips the
// write (seat already configured). The caller (p0) is the only allowed human seat.
struct SeatPhantomConfig {
    uint256[] monIndices;
    uint8[] facetIds;
    uint8[] moveSelections;
}

struct CustomMultiBattleProposal {
    address p0;
    uint96 p0TeamIndex;
    address p1;
    uint96 p1TeamIndex;
    address p2;
    uint96 p2TeamIndex;
    address p3;
    uint96 p3TeamIndex;
    SeatPhantomConfig[3] seatConfigs;
    ITeamRegistry teamRegistry;
    IRandomnessOracle rngOracle;
    IRuleset ruleset;
    address moveManager;
    IMatchmaker matchmaker;
    IEngineHook[] engineHooks;
}

// Used by SignedMatchmaker
struct BattleOffer {
    Battle battle;
    uint256 pairHashNonce;
    uint8 battleMode; // BATTLE_MODE_* — part of the signed offer so both players agree on it
}

// Used by Engine to initialize a battle's parameters. p2/p3 are Multi's second seats
// (side 0 / side 1 respectively), zero in singles and doubles. Canonical seat order for
// rotation and views is [p0, p2, p1, p3] (side-major) — NOT the struct field order.
struct Battle {
    address p0;
    uint96 p0TeamIndex;
    address p1;
    uint96 p1TeamIndex;
    address p2;
    uint96 p2TeamIndex;
    address p3;
    uint96 p3TeamIndex;
    ITeamRegistry teamRegistry;
    IRandomnessOracle rngOracle;
    IRuleset ruleset;
    address moveManager;
    IMatchmaker matchmaker;
    IEngineHook[] engineHooks;
}

// Multi's second seats, stored per battle key (fresh every battle — no recycling hygiene
// needed); written only when battleMode == MULTI so singles/doubles pay nothing.
// Packs into 2 slots: (p2, p2TeamIndex, cpuSeatMask) and (p3, p3TeamIndex).
struct MultiSeatData {
    address p2;
    uint16 p2TeamIndex;
    uint8 cpuSeatMask; // canonical-order bits [p0, p2, p1, p3]; from the registry at battle start
    address p3;
    uint16 p3TeamIndex;
}

// Packed into 1 storage slot (8 + 16 = 24 bits)
// packedMoveIndex: lower 7 bits = moveIndex (0-127), bit 7 = isRealTurn (1 = real, 0 = not set)
struct MoveDecision {
    uint8 packedMoveIndex;
    uint16 extraData;
}

// Stored by the Engine, tracks immutable battle data and battle state.
// Slot 0 — IMMUTABLE during play (only written at startBattle):
//   p1 (160) + p0TeamIndex (16) + p1TeamIndex (16) = 192 bits used.
// Slot 1 — EVERY per-turn mutation lands here, so a single SSTORE/turn covers all of them:
//   p0 (160) + winnerIndex (8) + playerSwitchForTurnFlag (8) +
//   activeMonIndex (16) + lastExecuteTimestamp (40) + turnId (16) = 248 bits (8 bits slack).
//   turnId narrowed uint64->uint16 (65,535 turns is far beyond any real game); timestamp
//   uint48->uint40 (year 36800 cap) to make room in slot 1.
struct BattleData {
    address p1;
    uint16 p0TeamIndex;
    uint16 p1TeamIndex;
    // Mirror of `BattleConfig.moveManager == BUILTIN_DUAL_SIGNED_MANAGER`, set at startBattle
    // (moveManager is only ever written there, so the mirror cannot desync). Lets the built-in
    // buffer's pure staging tx (submitTurnMoves) skip its only battleConfig access — a cold
    // sentinel SLOAD (~2.2k per stage tx). Lives in slot 0's spare bits.
    bool usesBuiltinManager;
    // Mirrors of BattleConfig.battleMode, set at startBattle. Let the built-in buffer's staging
    // txs route v1-vs-slot submissions and pick the seat rotation off the BattleData slot they
    // already read (isMultiMode additionally gates the multiSeats lookup).
    bool isTwoSlotMode;
    bool isMultiMode;
    // Slot-1 active lanes for 2-slot modes: [side0 slot1: bits 0-7 | side1 slot1: bits 8-15],
    // EMPTY_ACTIVE_LANE = no mon. Singles battles init it to 0 and never touch it, keeping the
    // legacy activeMonIndex packing byte-identical; lives in slot 0's remaining spare bits.
    uint16 activeMonExt;
    address p0;
    uint8 winnerIndex; // 2 = uninitialized (no winner), 0 = p0 winner, 1 = p1 winner
    // Singles: 0/1 = that side switches, 2 = both act. 2-slot modes: 2 = full turn, else
    // 0x80 | (4-bit absolute-slot mask) = only masked slots act (forced switches).
    uint8 playerSwitchForTurnFlag;
    uint16 activeMonIndex; // Packed: lower 8 bits = side0 slot0, upper 8 bits = side1 slot0
    uint40 lastExecuteTimestamp; // Written at end of every execute() — packed in slot 1 with turnId
    uint16 turnId;
    // Built-in dual-signed buffer (BUILTIN_DUAL_SIGNED_MANAGER battles): per-turn entries staged via
    // submitTurnMoves but not yet drained. Fills slot 1's last 8 free bits — no new storage slot. The
    // executed-turn count is `turnId` itself (buffering does not execute), so the next valid submit id
    // is `turnId + numBuffered`. Reset to 0 each battle by startBattle's BattleData reinit.
    uint8 numBuffered;
}

// Stored by the Engine for a battle, is overwritten after a battle is over
struct BattleConfig {
    uint96 packedP0EffectsCount; // 6 (PLAYER_EFFECT_BITS) bits for up to 16 mons for p0
    IRandomnessOracle rngOracle;
    uint96 packedP1EffectsCount;
    // Slot 2 — 256 bits exactly:
    address moveManager; // 160 — privileged role that can set moves for players outside of execute() call
    uint8 globalEffectsLength; //   8
    uint8 teamSizes; //   8 — Packed: lower 4 bits = p0 team size, upper 4 bits = p1 team size
    uint8 engineHooksLength; //   8
    uint16 koBitmaps; //  16 — Packed: lower 8 bits = p0 KO bitmap, upper 8 bits = p1 KO bitmap
    uint40 startTimestamp; //  40 — battle start time; overflows in year ~36825 (shrunk from uint48 for slot-2 packing)
    uint8 inlineRegenFlags; //   8 — INLINE_REGEN_* bits (rest / round-end halves)
    uint8 globalKVCount; //   8 — live entry count in the current battle's globalKV key buffer
    // Per-mon stat-boost source counts, 4 bits per mon (max 15 sources/mon — distinct callers).
    // MUST reset every startBattle (recycled keys); rides the slot-2 consolidated write.
    uint32 p0BoostCounts; //  32
    uint104 p0Salt;
    uint104 p1Salt;
    // OR of every player (per-mon) effect's stepsBitmap added this battle. Lets the hot step
    // pipelines (PreDamage / AfterDamage / OnUpdateMonState) skip the whole _runEffects shell when
    // NO player effect listens at that step — e.g. battles without a Dreamcatcher (OnUpdateMonState)
    // or Adaptor (PreDamage) listener, which is the common case. Over-approximate: never cleared on
    // removal (safe — at worst runs a pipeline that finds nothing, as today). Packs into slot 3.
    uint16 playerEffectStepsUnion; //  16
    // OR of every engine hook's stepsBitmap, set once at startBattle (hooks cannot be added
    // mid-battle). Gates the per-round hook loops: prod battles always carry the gacha hook,
    // which is OnBattleEnd-only, so without this gate every turn pays two pointless
    // engineHooks[i].stepsBitmap probes (~2.2k/turn — measured in ProdPvPGasBenchmark).
    // Packs into slot 3 with the salts + player union; p0Move/p1Move shift to the next slot
    // (which also makes the game-over move-slot clear a single-slot write).
    uint16 engineHookStepsUnion; //  16
    // BATTLE_MODE_* (0 = singles). Rides slot 3's spare bits so the per-turn mode gate
    // piggybacks on the engineHookStepsUnion SLOAD; rewritten every startBattle (recycled
    // storage must never leak a previous battle's mode).
    uint8 battleMode; //   8
    // Per-mon exclusive-status lanes: one 4-bit class nibble per mon, laneIndex = side*8 +
    // monIndex (stride 8 = the Engine's hard team-size cap, NOT MONS_PER_TEAM). 0 = no status.
    // Engine-owned: set in _addEffectInternal, cleared in _removeEffectAtSlot / startBattle's
    // consolidated reset. Rides slot 3 so both writes coalesce with SSTOREs already paid.
    uint64 monStatusLanes; //  64
    uint32 p1BoostCounts; //  32 — see p0BoostCounts; rides slot 3
    MoveDecision p0Move;
    MoveDecision p1Move;
    // Stored at startBattle so Engine.getBattle can passthrough to level/exp/facet getters.
    ITeamRegistry teamRegistry;
    mapping(uint256 index => StoredMon) p0Team;
    mapping(uint256 index => StoredMon) p1Team;
    mapping(uint256 index => MonState) p0States;
    mapping(uint256 index => MonState) p1States;
    mapping(uint256 => EffectInstance) globalEffects;
    mapping(uint256 => EffectInstance) p0Effects;
    mapping(uint256 => EffectInstance) p1Effects;
    mapping(uint256 => EngineHookInstance) engineHooks;
    // Stat-boost sources: ONE packed word per source (StatBoostLib layout — key/perm/5 lanes),
    // slot = monIndex * 16 + i, valid for i < that mon's 4-bit count in p{0,1}BoostCounts.
    // No reset needed on recycled keys: words are only read below the (reset) count.
    mapping(uint256 => bytes32) p0BoostWords;
    mapping(uint256 => bytes32) p1BoostWords;
    // Exact OR of live EffectInstance.stepsBitmap values for each player mon.
    // Lane index = side*8 + monIndex; one uint16 lane per mon fills one word exactly.
    // Appended after mappings so existing BattleConfig mapping roots remain stable.
    uint256 playerEffectStepsByMon;
}

struct EffectInstance {
    IEffect effect; // 160 bits
    uint16 stepsBitmap; // 16 bits - packs with effect in slot 0 (bit i = runs at EffectStep(i))
    // High 80 bits carry Engine's offset-tagged compact data, or zero for slot-1 fallback.
    bytes32 data; // 256 bits in slot 1
}

struct EngineHookInstance {
    IEngineHook hook; // 160 bits (packed with stepsBitmap in slot 0)
    uint16 stepsBitmap; // 16 bits - packs with hook in slot 0 (bit i = runs at EngineHookStep(i))
    // 80 bits unused in slot 0
}

// View struct for getBattle - contains array instead of mapping for memory return
struct BattleConfigView {
    IRandomnessOracle rngOracle;
    address moveManager;
    uint24 globalEffectsLength;
    uint96 packedP0EffectsCount; // 6 bits per mon (up to 16 mons)
    uint96 packedP1EffectsCount;
    uint8 teamSizes;
    uint40 startTimestamp; // Needed client-side for the getGlobalKV freshness gate
    uint104 p0Salt;
    uint104 p1Salt;
    uint16 p0TeamIndex;
    uint16 p1TeamIndex;
    uint64 monStatusLanes; // Per-mon exclusive-status class nibbles (see BattleConfig)
    uint256 playerEffectStepsByMon; // Exact uint16 lifecycle-step union per mon
    MoveDecision p0Move;
    MoveDecision p1Move;
    EffectInstance[] globalEffects;
    bytes32[][] p0StatBoosts; // Per-mon packed stat-boost source words (StatBoostLib layout)
    bytes32[][] p1StatBoosts;
    EffectInstance[][] p0Effects; // Returns effects per mon in team
    EffectInstance[][] p1Effects;
    Mon[][] teams;
    MonState[][] monStates;
    GlobalKVEntry[] globalKVEntries; // Live globalKV entries for the current battle
    TeamLevelInfo p0Levels;
    TeamLevelInfo p1Levels;
}

// Three parallel arrays of length MONS_PER_TEAM, indexed identically.
struct TeamLevelInfo {
    uint256[] monIds;
    uint256[] exp;
    uint256[] levels;
}

// Per-mon stat adjustment from an active Facet. Engine applies deltas after the validator
// runs against base stats.
struct StatDelta {
    int16 hp;
    int16 atk;
    int16 spAtk;
    int16 def;
    int16 spDef;
    int16 speed;
}

// Returned in BattleConfigView.globalKVEntries; value is packed [timestamp << 192 | value].
struct GlobalKVEntry {
    uint64 key;
    bytes32 value;
}

struct MonStats {
    uint32 hp;
    uint32 stamina;
    uint32 speed;
    uint32 attack;
    uint32 defense;
    uint32 specialAttack;
    uint32 specialDefense;
    Type type1;
    Type type2;
}

struct Mon {
    MonStats stats;
    uint256 ability; // Lower 160 bits = address for external abilities, or packed inline data if upper bits set
    uint256[] moves; // Lower 160 bits = address for external moves, or packed inline data if upper bits set
}

// Engine-internal storage shape for a snapshotted team mon. Mirrors `Mon` but stores moves as a
// fixed-size lane array: no dynamic-array length slot (one fewer fresh SSTORE per mon per battle)
// and no per-access length-check SLOAD + keccak indirection on the per-turn hot path — 6 slots
// per mon instead of 7. Unused lanes are ZERO-FILLED at startBattle (this storage is recycled
// across battles, so a stale lane from the previous occupant must never leak in as a playable
// move); readers treat a zero lane as "no move here" (silent skip), matching the old
// out-of-bounds semantics. The public `Mon` struct remains the ABI type everywhere —
// Engine.getBattle rebuilds Mon[] views from StoredMon, deriving the moves array length by
// dropping trailing zero lanes (zero move words are not valid playable moves).
struct StoredMon {
    MonStats stats;
    uint256 ability;
    uint256[MOVE_LANES_PER_MON] moves;
}

struct MonState {
    int32 hpDelta;
    int32 staminaDelta;
    int32 speedDelta;
    int32 attackDelta;
    int32 defenceDelta;
    int32 specialAttackDelta;
    int32 specialDefenceDelta;
    bool isKnockedOut; // Is either 0 or 1
    bool shouldSkipTurn; // Used for effects to skip turn, or when moves become invalid (outside of user control)
}

// Used for Commit manager
struct PlayerDecisionData {
    uint16 numMovesRevealed;
    uint16 lastCommitmentTurnId;
    uint96 lastMoveTimestamp;
    bytes32 moveHash;
}

struct RevealedMove {
    uint8 moveIndex;
    uint16 extraData;
    uint104 salt;
}

// Used for StatBoosts
struct StatBoostToApply {
    MonStateIndexName stat;
    uint8 boostPercent;
    StatBoostType boostType;
}

struct StatBoostUpdate {
    MonStateIndexName stat;
    uint32 oldStat;
    uint32 newStat;
}

// Batch context for external callers (e.g. DefaultValidator) to avoid multiple SLOADs
struct BattleContext {
    uint96 startTimestamp;
    address p0;
    address p1;
    uint8 winnerIndex; // 2 = uninitialized (no winner), 0 = p0 winner, 1 = p1 winner
    uint64 turnId;
    uint8 playerSwitchForTurnFlag;
    uint8 p0ActiveMonIndex;
    uint8 p1ActiveMonIndex;
    address moveManager;
}

// Batch context for damage calculation to reduce external calls (7 -> 1)
struct DamageCalcContext {
    uint8 attackerMonIndex;
    uint8 defenderMonIndex;
    // Attacker stats (base + delta for physical and special)
    uint32 attackerAttack;
    int32 attackerAttackDelta;
    uint32 attackerSpAtk;
    int32 attackerSpAtkDelta;
    // Defender stats (base + delta for physical and special)
    uint32 defenderDef;
    int32 defenderDefDelta;
    uint32 defenderSpDef;
    int32 defenderSpDefDelta;
    // Defender types for type effectiveness
    Type defenderType1;
    Type defenderType2;
}

// Bundled move metadata returned by IMoveSet.getMeta. Batches the separate
// getters (moveType / moveClass / priority / stamina / basePower) into
// one staticcall. MoveSlotLib.decodeMeta handles both inline moves (pure bit ops) and
// external moves (one getMeta call) uniformly.
struct MoveMeta {
    Type moveType;
    MoveClass moveClass;
    uint32 priority;
    uint32 stamina;
    uint32 basePower; // 0 for moves that don't deal damage
}

// Batched context for the registry's onBattleEnd hook — replaces the older split of
// getPlayersForBattle + getWinner + getKOBitmap×2.
struct BattleEndContext {
    address p0;
    address p1;
    address winner; // address(0) = draw; in Multi this is the winning SIDE's lead (p0/p1)
    uint16 p0TeamIndex;
    uint16 p1TeamIndex;
    uint8 p0KOBitmap; // full side bitmap (8 bits in Multi; seat quarters at [4q, 4q+4))
    uint8 p1KOBitmap;
    uint8 p0ActiveMonIndex;
    uint8 p1ActiveMonIndex;
    uint64 turnId;
    // Multi seats (zero outside MULTI battles)
    bool isMultiMode;
    address p2;
    address p3;
    uint16 p2TeamIndex;
    uint16 p3TeamIndex;
    uint8 p0ActiveMonExtIndex; // slot-1 lanes (the p2/p3 seats' active slots)
    uint8 p1ActiveMonExtIndex;
}
