// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "./Constants.sol";

import "./Enums.sol";
import "./Structs.sol";
import "./moves/IMoveSet.sol";

import {IEngine} from "./IEngine.sol";
import {IAbility} from "./abilities/IAbility.sol";
import {SignedCommitLib} from "./commit-manager/SignedCommitLib.sol";
import {EffectCommandLib} from "./effects/EffectCommandLib.sol";
import {IEffectResolver} from "./effects/IEffectResolver.sol";
import {IStatusEffect} from "./effects/status/IStatusEffect.sol";
import {ECDSA} from "./lib/ECDSA.sol";
import {EIP712} from "./lib/EIP712.sol";
import {MappingAllocator} from "./lib/MappingAllocator.sol";
import {StaminaRegenLogic} from "./lib/StaminaRegenLogic.sol";
import {StatBoostLib} from "./lib/StatBoostLib.sol";
import {TargetLib} from "./lib/TargetLib.sol";
import {ValidatorLogic} from "./lib/ValidatorLogic.sol";
import {AttackCalculator} from "./moves/AttackCalculator.sol";
import {IMoveResolver} from "./moves/IMoveResolver.sol";
import {MoveCommandLib} from "./moves/MoveCommandLib.sol";
import {TypeCalcLib} from "./types/TypeCalcLib.sol";

contract Engine is IEngine, MappingAllocator, EIP712 {
    uint256 public immutable DEFAULT_MONS_PER_TEAM;
    uint256 public immutable DEFAULT_MOVES_PER_MON;

    bytes32 public transient battleKeyForWrite; // intended to be used during call stack by other contracts
    bytes32 private transient storageKeyForWrite; // cached storage key to avoid repeated lookups
    // Bitmap tracking which effect lists were modified (for caching effect counts)
    // Bit 0: global effects, Bits 1-8: P0 mons 0-7, Bits 9-16: P1 mons 0-7
    uint256 private transient effectsDirtyBitmap;
    mapping(bytes32 => uint256) public pairHashNonces; // imposes a global ordering across all matches
    mapping(address player => mapping(address maker => bool)) public isMatchmakerFor; // tracks approvals for matchmakers

    mapping(bytes32 => BattleData) private battleData; // These contain immutable data and battle state
    mapping(bytes32 => MultiSeatData) private multiSeats; // Multi's second seats (p2/p3); written only for MULTI battles
    mapping(bytes32 => BattleConfig) private battleConfig; // These exist only throughout the lifecycle of a battle, we reuse these storage slots for subsequent battles
    mapping(bytes32 storageKey => mapping(uint64 => bytes32)) private globalKV; // Value layout: [64 bits timestamp | 192 bits value]
    // Packed key buffer: each slot holds four uint64 keys (lane 0 = bits [0..63], lane 1 = [64..127], etc.).
    // Paired with BattleConfig.globalKVCount to isolate the current battle's live entries from any leftover
    // lanes written by prior battles that shared this storageKey.
    mapping(bytes32 storageKey => mapping(uint256 slotIdx => uint256 packedKeys)) private globalKVKeySlots;
    // Built-in dual-signed buffer: per-turn packed (p0,p1) move projection, keyed by the recycled
    // storageKey (warm nz->nz SSTOREs across battles). Layout per slot matches the executeBatchedTurns
    // entry: [p0Move 8 | p0Extra 16 | p0Salt 104 | p1Move 8 | p1Extra 16 | p1Salt 104]. The live count
    // is BattleData.numBuffered; entries are only ever read in [turnId, turnId+numBuffered).
    mapping(bytes32 storageKey => mapping(uint64 turnId => uint256 packed)) private moveBuffer;
    uint256 public transient tempRNG; // Used to provide RNG during execute() tx
    uint256 private transient koOccurredFlag; // Set when a KO occurs, checked by _handleEffects/_handleMove
    uint256 private transient actedSlotsThisTurnMask; // bit per absolute slot: acted (or acting) this turn
    int32 private transient tempPreDamage; // Running damage during PreDamage hook pipeline; mutated via setPreDamage
    // Current-turn move + salt data exposed to external effects (ZapStatus, SleepStatus, StaminaRegen, etc.).
    // Packed per player into ONE transient slot: [salt: bits 0-103 | encoded move: bits 104-127].
    // The encoded move is always nonzero when populated (it carries IS_REAL_TURN_BIT) and salt is only
    // ever written paired with it, so `packed != 0` is exactly the "transient is populated this call"
    // signal — and the salt read collapses from two transient loads to one.
    uint256 private transient _turnP0Packed;
    uint256 private transient _turnP1Packed;
    // Two-slot action scheduler invalidation. Speed-mutating API chokepoints mark active lanes;
    // the next greedy pick refreshes only those lanes from mon storage.
    uint256 private transient _speedDirtySlots;

    // Errors
    error NoWriteAllowed();
    error WrongCaller();
    error StatRequiresStatBoost();
    error MatchmakerNotAuthorized();
    error MovesNotSet();
    error InvalidBattleConfig();
    error GameAlreadyOver();
    error GameStartsAndEndsSameBlock();
    error NotPlayerInBattle();
    error BattleNotStarted();
    error NotTwoPlayerTurn();
    error NotSinglePlayerTurn();
    // Built-in dual-signed buffer flow (BUILTIN_DUAL_SIGNED_MANAGER battles)
    error NotBuiltInManager();
    error SideWordOverflow();
    error WrongBattleMode();
    error NotCommitter();
    error InvalidSignature();
    error EmptyBuffer();

    // Events
    event BattleStart(bytes32 indexed battleKey, address p0, address p1);
    // 2-slot battles announce their mode; singles keeps the legacy BattleStart shape.
    event SlotBattleStart(bytes32 indexed battleKey, address p0, address p1, uint8 battleMode, address p2, address p3);
    // packedMoves layout (per-lane sentinel: lane bytes all zero == player did not submit):
    //   bits   0-  7  p0 monIndex        (uint8)
    //   bits   8- 15  p0 packedMoveIndex (uint8, 0 = not submitted)
    //   bits  16- 31  p0 extraData       (uint16)
    //   bits  32- 39  p1 monIndex        (uint8)
    //   bits  40- 47  p1 packedMoveIndex (uint8, 0 = not submitted)
    //   bits  48- 63  p1 extraData       (uint16)
    // packedSalts layout:
    //   bits   0-103  p0 salt (uint104)
    //   bits 104-207  p1 salt (uint104)
    event MonMoves(bytes32 indexed battleKey, uint256 packedMoves, uint256 packedSalts);
    event EngineExecute(bytes32 indexed battleKey);
    event BattleComplete(bytes32 indexed battleKey, address winner);
    // CPU one-tx completion (executeBatchedTurns only): winner + every executed turn, for off-chain
    // replay. Replaces the plain BattleComplete on the CPU path (which emits no per-turn events, so this
    // carries the full move list). The built-in PvP drain does NOT use this — it announces moves via
    // MovesSubmitted at submit time and emits only a normal BattleComplete at game over. `payload` is a
    // single packed blob:
    //   bytes  0- 19 : winner address (20 bytes)
    //   bytes 20-  N : 19 bytes per executed turn, big-endian, the low 152 bits of each
    //                  engine turn-entry: [p0Move 8 | p0Extra 16 | p0Salt 104 | p1Move 8 | p1Extra 16]
    // The p1 (CPU) salt is dropped — always 0 on the batched (CPU) path. Moves are RAW indices
    // (consumer applies MOVE_INDEX_OFFSET, matching the MonMoves convention).
    event BattleCompleteWithBatchTurns(bytes32 indexed battleKey, bytes payload);
    // Slot-mode analog (executeBatchedSlotTurns): [winner 20B | 25B/turn], each turn =
    // side-0 wire word low 152 bits (19B) + side-1 word low 48 bits (6B; the CPU-side salt is
    // always 0 on the batched path, so it is dropped).
    event BattleCompleteWithBatchSlotTurns(bytes32 indexed battleKey, bytes payload);
    // Emitted by the built-in dual-signed buffer flow when a turn is staged (submitTurnMoves) or
    // submitted-and-executed (submitTurnMovesAndExecute). Both players' moves are known at submit, so
    // the full per-turn move data is published here in real time and the drain emits NO per-turn events.
    // `packed` IS the buffer word — one compressed data word carrying both players' move index + extra
    // data + salt (turnId is the submission order, derivable from the event sequence):
    //   bits   0-  7 : p0 move index (raw — consumer applies MOVE_INDEX_OFFSET, matching MonMoves)
    //   bits   8- 23 : p0 extraData (uint16)
    //   bits  24-127 : p0 salt (uint104)
    //   bits 128-135 : p1 move index (raw)
    //   bits 136-151 : p1 extraData (uint16)
    //   bits 152-255 : p1 salt (uint104)
    event MovesSubmitted(bytes32 indexed battleKey, bytes32 packed);
    // One wire word per side, same layout executeWithSlotMoves takes and the buffer stores.
    event SlotMovesSubmitted(bytes32 indexed battleKey, uint256 side0Packed, uint256 side1Packed);

    /// @notice Constructor to set default validator config for inline validation
    /// @dev When a battle's validator is address(0), Engine uses inline validation logic with these params
    /// @param _DEFAULT_MONS_PER_TEAM Default mons per team for inline validation
    /// @param _DEFAULT_MOVES_PER_MON Default moves per mon for inline validation
    constructor(uint256 _DEFAULT_MONS_PER_TEAM, uint256 _DEFAULT_MOVES_PER_MON) {
        // Hard cap shared by koBitmaps (8 KO bits/side) and monStatusLanes (8 nibbles/side).
        if (_DEFAULT_MONS_PER_TEAM > 8) {
            revert InvalidBattleConfig();
        }
        DEFAULT_MONS_PER_TEAM = _DEFAULT_MONS_PER_TEAM;
        DEFAULT_MOVES_PER_MON = _DEFAULT_MOVES_PER_MON;
    }

    /// @inheritdoc EIP712
    /// @dev Domain for the built-in dual-signed buffer flow. NOTE: this differs from
    ///      SignedCommitManager's domain, so signatures for the built-in flow must target the Engine
    ///      address (off-chain signers in belch/munch re-target here).
    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "ChompEngine";
        version = "1";
    }

    function updateMatchmakers(address[] memory makersToAdd, address[] memory makersToRemove) external {
        for (uint256 i; i < makersToAdd.length;) {
            isMatchmakerFor[msg.sender][makersToAdd[i]] = true;
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < makersToRemove.length;) {
            isMatchmakerFor[msg.sender][makersToRemove[i]] = false;
            unchecked {
                ++i;
            }
        }
    }

    function startBattle(Battle memory battle) external {
        _startBattle(battle, BATTLE_MODE_SINGLES);
    }

    /// @notice startBattle with an explicit BATTLE_MODE_*; MULTI requires seats p2/p3, other
    ///         modes forbid them.
    function startBattleWithMode(Battle memory battle, uint8 battleMode) external {
        if (battleMode > BATTLE_MODE_MULTI) {
            revert InvalidBattleConfig();
        }
        if (battleMode == BATTLE_MODE_MULTI) {
            if (battle.p2 == address(0) || battle.p3 == address(0)) {
                revert InvalidBattleConfig();
            }
        } else if (battle.p2 != address(0) || battle.p3 != address(0)) {
            revert InvalidBattleConfig();
        }
        _startBattle(battle, battleMode);
    }

    /// @dev Sentinel-clears one side's recycled mon states.
    function _clearMonStates(mapping(uint256 => MonState) storage states, uint256 count) private {
        for (uint256 j = 0; j < count;) {
            MonState storage monState = states[j];
            assembly ("memory-safe") {
                let slot := monState.slot
                let v := sload(slot)
                // Clear only when dirty AND not already the sentinel (skip the same-value SSTORE).
                if iszero(or(iszero(v), eq(v, PACKED_CLEARED_MON_STATE))) {
                    sstore(slot, PACKED_CLEARED_MON_STATE)
                }
            }
            unchecked {
                ++j;
            }
        }
    }

    /// @dev Writes one side's roster into its fixed lanes, zero-filling unused move lanes.
    function _storeTeam(mapping(uint256 => StoredMon) storage lanes, Mon[] memory team, uint256 len) private {
        for (uint256 j = 0; j < len;) {
            StoredMon storage dst = lanes[j];
            Mon memory src = team[j];
            dst.stats = src.stats;
            dst.ability = src.ability;
            // Unrolled on purpose — do NOT rewrite as a loop: a dynamic-index store into a
            // struct-nested fixed array makes via-IR emit an indexed-store helper that costs one
            // extra SLOAD per lane write (+32 per battle, measured); constant indices compile to
            // direct slot stores. Lane count is pinned to MOVE_LANES_PER_MON (= 4, test-asserted).
            uint256 n = src.moves.length;
            dst.moves[0] = n > 0 ? src.moves[0] : 0;
            dst.moves[1] = n > 1 ? src.moves[1] : 0;
            dst.moves[2] = n > 2 ? src.moves[2] : 0;
            dst.moves[3] = n > 3 ? src.moves[3] : 0;
            unchecked {
                ++j;
            }
        }
    }

    function _startBattle(Battle memory battle, uint8 battleMode) internal {
        // The matchmaker authorization gate is the ONLY matchmaker check: each player approving
        // the matchmaker is the trust grant. (The old validateMatch callback added no security —
        // a matchmaker could always return true — and every in-repo matchmaker validates its own
        // offers before calling startBattle, so it was removed.)
        if (
            !isMatchmakerFor[battle.p0][address(battle.matchmaker)]
                || !isMatchmakerFor[battle.p1][address(battle.matchmaker)]
        ) {
            revert MatchmakerNotAuthorized();
        }
        if (battleMode == BATTLE_MODE_MULTI) {
            if (
                !isMatchmakerFor[battle.p2][address(battle.matchmaker)]
                    || !isMatchmakerFor[battle.p3][address(battle.matchmaker)]
            ) {
                revert MatchmakerNotAuthorized();
            }
        }

        // Multi keys off all four sorted seats (D33)
        bytes32 battleKey;
        bytes32 pairHash;
        if (battleMode == BATTLE_MODE_MULTI) {
            (battleKey, pairHash) = computePartyKey(battle.p0, battle.p1, battle.p2, battle.p3);
        } else {
            (battleKey, pairHash) = computeBattleKey(battle.p0, battle.p1);
        }
        pairHashNonces[pairHash] += 1;

        // Get the storage key for the battle config (reusable)
        bytes32 battleConfigKey = _initializeStorageKey(battleKey);
        BattleConfig storage config = battleConfig[battleConfigKey];

        // Get previous team sizes to clear old mon states
        uint256 prevP0Size = config.teamSizes & 0x0F;
        uint256 prevP1Size = config.teamSizes >> 4;

        // Clear previous battle's mon states by setting non-zero values to sentinel
        // MonState packs into a single 256-bit slot (7 x int32 + 2 x bool = 240 bits)
        // We use assembly to read/write the entire slot in one operation
        _clearMonStates(config.p0States, prevP0Size);
        _clearMonStates(config.p1States, prevP1Size);

        // Store the battle config (update fields individually to preserve effects mapping slots).
        // Writes are grouped by storage slot with no calls in between so via-IR coalesces each
        // group into one read-modify-write: slot 0 = packedP0EffectsCount + rngOracle, slot 1 =
        // rngOracle + packedP1EffectsCount. Slot 2's many fields (moveManager, koBitmaps,
        // teamSizes, ...) are deferred to ONE consolidated block after the last external call —
        // the getTeams/ruleset/hook calls are storage barriers that would otherwise split them
        // into ~6 separate RMWs.
        config.packedP0EffectsCount = 0;
        if (address(config.rngOracle) != address(battle.rngOracle)) {
            config.rngOracle = battle.rngOracle;
        }
        config.packedP1EffectsCount = 0;
        if (address(config.teamRegistry) != address(battle.teamRegistry)) {
            config.teamRegistry = battle.teamRegistry;
        }

        // teamIndices narrowed from Battle.uint96; phantom-team writes truncate to match.
        battleData[battleKey] = BattleData({
            p0: battle.p0,
            p1: battle.p1,
            p0TeamIndex: uint16(battle.p0TeamIndex),
            p1TeamIndex: uint16(battle.p1TeamIndex),
            usesBuiltinManager: battle.moveManager == BUILTIN_DUAL_SIGNED_MANAGER,
            isTwoSlotMode: battleMode != BATTLE_MODE_SINGLES,
            isMultiMode: battleMode == BATTLE_MODE_MULTI,
            // Slot-1 lanes start EMPTY in 2-slot modes (turn-0 send-ins fill them); singles
            // writes 0 and never reads the field.
            activeMonExt: battleMode == BATTLE_MODE_SINGLES ? 0 : uint16(0xFFFF),
            winnerIndex: 2, // Initialize to 2 (uninitialized/no winner)
            playerSwitchForTurnFlag: 2, // Set flag to be 2 which means both players act
            activeMonIndex: 0, // Defaults to 0 (both players start with mon index 0)
            turnId: 0,
            lastExecuteTimestamp: 0, // Fresh battleKey per battle, starts at 0
            numBuffered: 0 // Built-in dual-signed buffer starts empty (auto-resets each battle here)
        });

        // Set the team for p0 and p1 in the reusable config storage. Multi concatenates each
        // side's two seat teams into one roster with a FIXED stride-4 partition (seat 0 owns
        // [0..3], seat 1 owns [4..7]) — launch shape requires exactly 4 mons per seat so the
        // side KO mask stays contiguous.
        (Mon[] memory p0Team, Mon[] memory p1Team) =
            battle.teamRegistry.getTeams(battle.p0, battle.p0TeamIndex, battle.p1, battle.p1TeamIndex);
        if (battleMode == BATTLE_MODE_MULTI) {
            // CPU seats (registry whitelisted opponents) shape the committer/revealer rotation:
            // the built-in dual-signed flow rotates over human seats only (D18/D19), so it needs
            // a human on each side. CPU-inclusive parties without one ride a manager instead.
            uint8 cpuSeatMask = (battle.teamRegistry.isWhitelistedOpponent(battle.p0) ? 1 : 0)
                | (battle.teamRegistry.isWhitelistedOpponent(battle.p2) ? 2 : 0)
                | (battle.teamRegistry.isWhitelistedOpponent(battle.p1) ? 4 : 0)
                | (battle.teamRegistry.isWhitelistedOpponent(battle.p3) ? 8 : 0);
            if (
                battle.moveManager == BUILTIN_DUAL_SIGNED_MANAGER
                    && ((cpuSeatMask & 0x3) == 0x3 || (cpuSeatMask & 0xC) == 0xC)
            ) {
                revert InvalidBattleConfig();
            }
            multiSeats[battleKey] = MultiSeatData({
                p2: battle.p2,
                p2TeamIndex: uint16(battle.p2TeamIndex),
                cpuSeatMask: cpuSeatMask,
                p3: battle.p3,
                p3TeamIndex: uint16(battle.p3TeamIndex)
            });
            (Mon[] memory p2Team, Mon[] memory p3Team) =
                battle.teamRegistry.getTeams(battle.p2, battle.p2TeamIndex, battle.p3, battle.p3TeamIndex);
            if (p0Team.length != 4 || p1Team.length != 4 || p2Team.length != 4 || p3Team.length != 4) {
                revert InvalidBattleConfig();
            }
            p0Team = _concatTeams(p0Team, p2Team);
            p1Team = _concatTeams(p1Team, p3Team);
        }

        // Team sizes (packed: lower 4 bits = p0, upper 4 bits = p1) — written with the
        // consolidated slot-2 block below.
        uint256 p0Len = p0Team.length;
        uint256 p1Len = p1Team.length;
        uint8 newTeamSizes = uint8(p0Len) | (uint8(p1Len) << 4);

        // Store teams in the fixed-lane mappings. Lanes past the mon's move count are ZERO-FILLED:
        // this storage is recycled across battles, so without the fill a shorter-moveset mon would
        // inherit the previous battle's move words as playable moves. (Moves past
        // MOVE_LANES_PER_MON are truncated — the lane count matches GAME_MOVES_PER_MON.)
        _storeTeam(config.p0Team, p0Team, p0Len);
        _storeTeam(config.p1Team, p1Team, p1Len);

        // Set the global effects and data to start the game if any.
        // NOTE: inlineRegenFlags AND globalEffectsLength must be (re)written on EVERY branch —
        // config storage is recycled across battles, so a stale value from the previous occupant
        // would otherwise leak into this battle (e.g. inline regen running on top of an external
        // ruleset, or a previous battle's global effect staying live when the new ruleset is empty).
        // A ruleset opts into either half of inline regen by listing a marker address in its effects
        // array; markers are folded into the flags here and never stored or called.
        uint8 newRegenFlags;
        uint8 newGlobalEffectsLength;
        if (address(battle.ruleset) == INLINE_STAMINA_REGEN_RULESET) {
            newRegenFlags = INLINE_REGEN_ALL;
        } else if (address(battle.ruleset) != address(0)) {
            (IEffect[] memory effects, bytes32[] memory data) = battle.ruleset.getInitialGlobalEffects();
            uint256 numEffects = effects.length;
            uint256 stored;
            for (uint256 i = 0; i < numEffects;) {
                IEffect effect = effects[i];
                address effectAddr = address(effect);
                if (effectAddr == INLINE_STAMINA_REGEN_RULESET) {
                    newRegenFlags |= INLINE_REGEN_ALL;
                } else if (effectAddr == INLINE_REST_REGEN_MARKER) {
                    newRegenFlags |= INLINE_REGEN_REST;
                } else {
                    uint32 metadata = effect.getStepsBitmap();
                    _writeEffectInstance(
                        config.globalEffects[stored],
                        effect,
                        uint16(metadata),
                        data[i],
                        uint16(metadata >> EFFECT_CONTEXT_SHIFT)
                    );
                    unchecked {
                        ++stored;
                    }
                }
                unchecked {
                    ++i;
                }
            }
            newGlobalEffectsLength = uint8(stored);
        }

        // Set the engine hooks to start the game if any, folding their bitmaps into the union
        uint256 numHooks = battle.engineHooks.length;
        uint16 hookStepsUnion;
        for (uint256 i; i < numHooks;) {
            IEngineHook hook = battle.engineHooks[i];
            uint16 hookBitmap = hook.getStepsBitmap();
            config.engineHooks[i].hook = hook;
            config.engineHooks[i].stepsBitmap = hookBitmap;
            hookStepsUnion |= hookBitmap;
            unchecked {
                ++i;
            }
        }

        // --- Consolidated BattleConfig slot-2 write ---
        // Every slot-2 field lands here in one contiguous run with no external calls in between,
        // so via-IR coalesces them into a single read-modify-write (they previously cost ~6
        // separate RMWs split across the getTeams/ruleset/hook call barriers). Placed BEFORE
        // validateGameStart and the OnBattleStart hooks so everything an external contract can
        // observe is already written; the view calls above this point (getTeams,
        // getInitialGlobalEffects, getStepsBitmap) could in principle staticcall back and see the
        // previous battle's packed fields — no current contract does, keep it that way.
        if (config.moveManager != battle.moveManager) {
            config.moveManager = battle.moveManager;
        }
        config.koBitmaps = 0;
        config.globalKVCount = 0;
        config.p0BoostCounts = 0;
        config.teamSizes = newTeamSizes;
        config.inlineRegenFlags = newRegenFlags;
        config.globalEffectsLength = newGlobalEffectsLength;
        config.engineHooksLength = uint8(numHooks);
        config.startTimestamp = uint40(block.timestamp);
        // --- Consolidated slot-3 write (salts + both step unions + mode) ---
        // Salts are only written by the legacy setMove storage path and never cleared at game
        // over; reset them so a recycled key cannot leak the previous battle's salts in.
        // battleMode must likewise be rewritten every battle (recycled storage).
        config.p0Salt = 0;
        config.p1Salt = 0;
        config.playerEffectStepsUnion = 0;
        config.engineHookStepsUnion = hookStepsUnion;
        config.battleMode = battleMode;
        config.monStatusLanes = 0;
        config.p1BoostCounts = 0;
        config.playerEffectStepsByMon = 0;

        if ((hookStepsUnion & (1 << uint8(EngineHookStep.OnBattleStart))) != 0) {
            for (uint256 i = 0; i < numHooks;) {
                if ((config.engineHooks[i].stepsBitmap & (1 << uint8(EngineHookStep.OnBattleStart))) != 0) {
                    config.engineHooks[i].hook.onBattleStart(battleKey);
                }
                unchecked {
                    ++i;
                }
            }
        }

        if (battleMode == BATTLE_MODE_SINGLES) {
            emit BattleStart(battleKey, battle.p0, battle.p1);
        } else {
            emit SlotBattleStart(battleKey, battle.p0, battle.p1, battleMode, battle.p2, battle.p3);
        }
    }

    // THE IMPORTANT FUNCTION
    function execute(bytes32 battleKey) external returns (address winner) {
        // Cache storage key in transient storage for the duration of the call
        bytes32 storageKey = _getStorageKey(battleKey);
        storageKeyForWrite = storageKey;
        battleKeyForWrite = battleKey;

        BattleConfig storage config = battleConfig[storageKey];

        // Check that at least one move has been set (isRealTurn is stored in bit 7 of packedMoveIndex)
        if (
            (config.p0Move.packedMoveIndex & IS_REAL_TURN_BIT) == 0
                && (config.p1Move.packedMoveIndex & IS_REAL_TURN_BIT) == 0
        ) {
            revert MovesNotSet();
        }

        // EngineExecute is a per-tx "a turn executed" ping (legacy = one turn per tx). The batched
        // drain runs many turns in one tx, so it emits MonMoves per turn but not this — hence it lives
        // here at the entrypoint, not inside the per-turn _executeInternal body.
        winner = _executeInternal(battleKey, storageKey, true, true, false);
        emit EngineExecute(battleKey);
    }

    /// @notice Combined setMove + setMove + execute for gas optimization
    /// @dev Only callable by moveManager. Sets both moves and executes in one call.
    /// Writes move/salt data to transient storage instead of the per-battle storage slots.
    /// _executeInternal reads from transient when populated and skips the mirror, and
    /// `setMove` during execute also targets transient.
    function executeWithMoves(
        bytes32 battleKey,
        uint8 p0MoveIndex,
        uint104 p0Salt,
        uint16 p0ExtraData,
        uint8 p1MoveIndex,
        uint104 p1Salt,
        uint16 p1ExtraData
    ) external returns (address winner) {
        bytes32 storageKey = _getStorageKey(battleKey);
        storageKeyForWrite = storageKey;

        BattleConfig storage config = battleConfig[storageKey];

        if (msg.sender != config.moveManager) {
            revert WrongCaller();
        }
        battleKeyForWrite = battleKey;

        // Populate transient directly. _executeInternal sees non-zero _turnP0Packed and skips the
        // mirror-from-storage step. No SSTORE happens; transient auto-clears at tx end in prod.
        uint8 p0StoredMoveIndex = p0MoveIndex < SWITCH_MOVE_INDEX ? p0MoveIndex + MOVE_INDEX_OFFSET : p0MoveIndex;
        uint8 p1StoredMoveIndex = p1MoveIndex < SWITCH_MOVE_INDEX ? p1MoveIndex + MOVE_INDEX_OFFSET : p1MoveIndex;
        _turnP0Packed =
            _packTurn((uint256(p0StoredMoveIndex) | uint256(IS_REAL_TURN_BIT)) | (uint256(p0ExtraData) << 8), p0Salt);
        _turnP1Packed =
            _packTurn((uint256(p1StoredMoveIndex) | uint256(IS_REAL_TURN_BIT)) | (uint256(p1ExtraData) << 8), p1Salt);

        winner = _executeInternal(battleKey, storageKey, true, true, false);
        emit EngineExecute(battleKey);
    }

    /// @notice Combined single-player setMove + execute for forced switch turns
    /// @dev Only callable by moveManager. The acting player is inferred from battle.playerSwitchForTurnFlag.
    function executeWithSingleMove(bytes32 battleKey, uint8 moveIndex, uint104 salt, uint16 extraData)
        external
        returns (address winner)
    {
        bytes32 storageKey = _getStorageKey(battleKey);
        storageKeyForWrite = storageKey;

        BattleConfig storage config = battleConfig[storageKey];

        if (msg.sender != config.moveManager) {
            revert WrongCaller();
        }
        battleKeyForWrite = battleKey;

        BattleData storage battle = battleData[battleKey];
        uint256 playerIndex = battle.playerSwitchForTurnFlag;
        if (playerIndex > 1) {
            revert NotSinglePlayerTurn();
        }

        uint8 storedMoveIndex = moveIndex < SWITCH_MOVE_INDEX ? moveIndex + MOVE_INDEX_OFFSET : moveIndex;
        uint256 encoded = (uint256(storedMoveIndex) | uint256(IS_REAL_TURN_BIT)) | (uint256(extraData) << 8);
        if (playerIndex == 0) {
            _turnP0Packed = _packTurn(encoded, salt);
        } else {
            _turnP1Packed = _packTurn(encoded, salt);
        }

        winner = _executeInternal(battleKey, storageKey, true, true, false);
        emit EngineExecute(battleKey);
    }

    function executeBatchedTurns(bytes32 battleKey, uint256[] calldata entries)
        external
        returns (uint64 executed, address winner)
    {
        bytes32 storageKey = _getStorageKey(battleKey);
        storageKeyForWrite = storageKey;
        battleKeyForWrite = battleKey;
        BattleConfig storage config = battleConfig[storageKey];
        if (msg.sender != config.moveManager) {
            revert WrongCaller();
        }
        for (uint256 i = 0; i < entries.length; i++) {
            uint256 entry = entries[i];
            uint8 p0Move = uint8(entry);
            uint16 p0Extra = uint16(entry >> 8);
            uint104 p0Salt = uint104(entry >> 24);
            uint8 p1Move = uint8(entry >> 128);
            uint16 p1Extra = uint16(entry >> 136);
            uint104 p1Salt = uint104(entry >> 152);

            // Live flag read (direct storage, warm after the first sub-turn).
            uint8 flag = battleData[battleKey].playerSwitchForTurnFlag;
            if (flag == 2) {
                uint8 p0Stored = p0Move < SWITCH_MOVE_INDEX ? p0Move + MOVE_INDEX_OFFSET : p0Move;
                uint8 p1Stored = p1Move < SWITCH_MOVE_INDEX ? p1Move + MOVE_INDEX_OFFSET : p1Move;
                _turnP0Packed =
                    _packTurn((uint256(p0Stored) | uint256(IS_REAL_TURN_BIT)) | (uint256(p0Extra) << 8), p0Salt);
                _turnP1Packed =
                    _packTurn((uint256(p1Stored) | uint256(IS_REAL_TURN_BIT)) | (uint256(p1Extra) << 8), p1Salt);
            } else if (flag == 0) {
                uint8 p0Stored = p0Move < SWITCH_MOVE_INDEX ? p0Move + MOVE_INDEX_OFFSET : p0Move;
                _turnP0Packed =
                    _packTurn((uint256(p0Stored) | uint256(IS_REAL_TURN_BIT)) | (uint256(p0Extra) << 8), p0Salt);
                // Clear the non-acting lane and the turn rng: switch-only turns have no fresh
                // rng, and only the batched dispatch can carry stale values into them.
                _turnP1Packed = 0;
                tempRNG = 0;
            } else {
                uint8 p1Stored = p1Move < SWITCH_MOVE_INDEX ? p1Move + MOVE_INDEX_OFFSET : p1Move;
                _turnP1Packed =
                    _packTurn((uint256(p1Stored) | uint256(IS_REAL_TURN_BIT)) | (uint256(p1Extra) << 8), p1Salt);
                _turnP0Packed = 0;
                tempRNG = 0;
            }

            winner = _executeInternal(battleKey, storageKey, false, false, false);
            executed++;
            if (winner != address(0)) {
                break;
            }

            // Between sub-turns only koOccurredFlag needs a reset: the turn lanes are (re)written
            // by the flag dispatch above, forced-switch turns zero tempRNG themselves, the
            // PreDamage pipeline restores tempPreDamage, and a stale dirty bit only costs a safe
            // count re-read. Kept inline here (rather than calling _resetBatchedTurnTransients,
            // which _drainBuffer uses) for the same inliner reason this whole loop body is
            // inlined — see the _executeBatchedEntry note.
            koOccurredFlag = 0;
        }
        // The batched flow emits NO per-turn events (each sub-turn passes emitEvents=false to
        // _executeInternal: no EngineExecute, no MonMoves, and BattleComplete is suppressed in
        // _handleGameOver). Instead, when the game concluded this batch, emit ONE
        // BattleCompleteWithBatchTurns carrying the winner + every executed turn so off-chain
        // indexers get the full replay from a single Engine log (no per-CPU-address subscription).
        // Each turn is the low 152 bits of its entry — the p1 (CPU) salt is always 0 here, so it's
        // dropped — packed big-endian as 19 bytes via bytes19(bytes32(entry << 104)).
        if (winner != address(0)) {
            emit BattleCompleteWithBatchTurns(battleKey, _packBatchPayload(entries, executed, winner));
        }
    }

    /// @dev Packs the BattleCompleteWithBatchTurns payload: [winner 20B | 19B/turn ...]. Each turn is
    ///      the low 152 bits of its entry (p1/CPU salt is always 0 on the batched path, so dropped) —
    ///      `entry << 104` lands those 152 bits in the leading 19 bytes of the stored word. Single
    ///      pre-sized buffer (O(n); encodePacked-accumulate would reallocate+copy each turn -> O(n^2)).
    ///      Allocated with +13 slack so the final 32-byte mstore can never write past the buffer, then
    ///      the real length is set — keeps the block memory-safe.
    function _packBatchPayload(uint256[] calldata entries, uint256 numTurns, address winner)
        private
        pure
        returns (bytes memory payload)
    {
        uint256 len = 20 + numTurns * 19;
        payload = new bytes(len + 13);
        assembly ("memory-safe") {
            let ptr := add(payload, 32)
            mstore(ptr, shl(96, winner)) // winner address in the leading 20 bytes
            ptr := add(ptr, 20)
            let src := entries.offset
            for { let i := 0 } lt(i, numTurns) { i := add(i, 1) } {
                mstore(ptr, shl(104, calldataload(add(src, mul(i, 0x20)))))
                ptr := add(ptr, 19)
            }
            mstore(payload, len) // drop the 13 slack bytes from the visible length
        }
    }

    /// @dev Executes one buffered turn for the built-in PvP drain: flag-dispatch the packed entry into the
    ///      current-turn transients (the non-acting half on a single-player turn is ignored), then
    ///      _executeInternal with (emitMonMoves=false, emitBattleComplete=true). The drain emits NO
    ///      per-turn events — each move was already announced by MovesSubmitted at submit time — only a
    ///      normal BattleComplete at game over. (No per-tx EngineExecute either: the whole drain is one tx;
    ///      EngineExecute is emitted once per legacy execute() tx at the entrypoint.) Single call site
    ///      (_drainBuffer) so the optimizer inlines it. NOTE: executeBatchedTurns (the CPU one-tx path)
    ///      keeps its own inlined copy of this loop body with (false, false) on purpose — CPU has one
    ///      actor, so a single BattleCompleteWithBatchTurns is the right log there, and extracting a
    ///      2-call-site helper stopped the inliner and added ~1M gas across a real replay.
    function _executeBatchedEntry(bytes32 battleKey, bytes32 storageKey, uint256 entry)
        internal
        returns (address winner)
    {
        uint8 p0Move = uint8(entry);
        uint16 p0Extra = uint16(entry >> 8);
        uint104 p0Salt = uint104(entry >> 24);
        uint8 p1Move = uint8(entry >> 128);
        uint16 p1Extra = uint16(entry >> 136);
        uint104 p1Salt = uint104(entry >> 152);

        // Live flag read (direct storage, warm after the first sub-turn).
        uint8 flag = battleData[battleKey].playerSwitchForTurnFlag;
        if (flag == 2) {
            uint8 p0Stored = p0Move < SWITCH_MOVE_INDEX ? p0Move + MOVE_INDEX_OFFSET : p0Move;
            uint8 p1Stored = p1Move < SWITCH_MOVE_INDEX ? p1Move + MOVE_INDEX_OFFSET : p1Move;
            _turnP0Packed = _packTurn((uint256(p0Stored) | uint256(IS_REAL_TURN_BIT)) | (uint256(p0Extra) << 8), p0Salt);
            _turnP1Packed = _packTurn((uint256(p1Stored) | uint256(IS_REAL_TURN_BIT)) | (uint256(p1Extra) << 8), p1Salt);
        } else if (flag == 0) {
            uint8 p0Stored = p0Move < SWITCH_MOVE_INDEX ? p0Move + MOVE_INDEX_OFFSET : p0Move;
            _turnP0Packed = _packTurn((uint256(p0Stored) | uint256(IS_REAL_TURN_BIT)) | (uint256(p0Extra) << 8), p0Salt);
            // Clear the non-acting lane and the turn rng: switch-only turns have no fresh
            // rng, and only the batched dispatch can carry stale values into them.
            _turnP1Packed = 0;
            tempRNG = 0;
        } else {
            uint8 p1Stored = p1Move < SWITCH_MOVE_INDEX ? p1Move + MOVE_INDEX_OFFSET : p1Move;
            _turnP1Packed = _packTurn((uint256(p1Stored) | uint256(IS_REAL_TURN_BIT)) | (uint256(p1Extra) << 8), p1Salt);
            _turnP0Packed = 0;
            tempRNG = 0;
        }

        return _executeInternal(battleKey, storageKey, false, true, false);
    }

    /// @dev Between batched sub-turns only koOccurredFlag needs a reset: the turn lanes are
    ///      (re)written by every entry's dispatch, forced-switch turns zero tempRNG themselves,
    ///      the PreDamage pipeline restores tempPreDamage, and a stale dirty bit only costs a
    ///      safe count re-read.
    function _resetBatchedTurnTransients() internal {
        koOccurredFlag = 0;
    }

    // ---------------------------------------------------------------------
    // Built-in dual-signed buffer flow (BUILTIN_DUAL_SIGNED_MANAGER battles)
    // ---------------------------------------------------------------------

    /// @notice Stage one per-turn dual-signed submission into the Engine's buffer (no execution).
    /// @dev SINGLE-SIG: the committer is msg.sender (no committer signature); the revealer's EIP-712
    ///      signature pins the committer's move hash, so the committer can't change their move and
    ///      can't be impersonated. Requires the battle to use the built-in flow (moveManager sentinel).
    function submitTurnMoves(bytes32 battleKey, uint256 packedMoves, bytes32 r, bytes32 vs) external {
        (bytes32 storageKey, uint256 packed, uint64 turnId, BattleData storage data) =
            _validateAndPackTurn(battleKey, packedMoves, r, vs);
        // Persist for a later drain (this turn executes in a separate tx).
        moveBuffer[storageKey][turnId] = packed;
        data.numBuffered = data.numBuffered + 1;
        // Announce the move now (the drain emits no per-turn events) — one compressed log carrying both
        // players' move indices + extra data + salts.
        emit MovesSubmitted(battleKey, bytes32(packed));
    }

    /// @notice Stage a submission and execute it (plus any earlier buffered turns) in the same tx.
    /// @dev The submitted entry executes in THIS tx, so it never needs to persist: validate it, drain
    ///      any previously-buffered turns from storage, then execute this entry straight from memory —
    ///      skipping the SSTORE + immediate SLOAD round-trip the buffer-then-drain path would pay for it.
    ///      For a 1-turn batch (no prior buffer) this touches `moveBuffer`/`numBuffered` zero times.
    function submitTurnMovesAndExecute(bytes32 battleKey, uint256 packedMoves, bytes32 r, bytes32 vs) external {
        (bytes32 storageKey, uint256 packed,,) = _validateAndPackTurn(battleKey, packedMoves, r, vs);
        // Announce this turn's moves (the drain emits no per-turn events), then drain + execute. Prior
        // buffered turns were already announced at their own submitTurnMoves.
        emit MovesSubmitted(battleKey, bytes32(packed));
        _drainBufferThenExecute(battleKey, storageKey, packed);
    }

    /// @notice Drain every currently buffered turn in one tx. Permissionless — entries were already
    ///         signature-validated at submit.
    function executeBuffered(bytes32 battleKey) external {
        if (battleData[battleKey].isTwoSlotMode) {
            _drainSlotBuffer(battleKey, _getStorageKey(battleKey));
        } else {
            _drainBuffer(battleKey, _getStorageKey(battleKey));
        }
    }

    /// @dev Validate a dual-signed submission (built-in manager, game live, committer == msg.sender,
    ///      revealer EIP-2098 compact signature) and project it onto the packed (p0|p1) buffer-word
    ///      layout. VIEW — no state writes: the caller decides whether to buffer it (SSTORE) or execute
    ///      it now. Returns the resolved `data` pointer so the caller doesn't re-resolve the mapping.
    function _validateAndPackTurn(bytes32 battleKey, uint256 packedMoves, bytes32 r, bytes32 vs)
        internal
        view
        returns (bytes32 storageKey, uint256 packed, uint64 turnId, BattleData storage data)
    {
        data = battleData[battleKey];
        // The builtin-manager flag is mirrored into BattleData slot 0 (already read for p0/p1
        // below) — a pure staging tx otherwise touches battleConfig for nothing but this cold
        // sentinel check (~2.2k saved per submitTurnMoves).
        if (!data.usesBuiltinManager) {
            revert NotBuiltInManager();
        }
        if (data.isTwoSlotMode) {
            revert WrongBattleMode(); // 2-slot battles submit via submitSlotTurnMoves*
        }
        if (data.winnerIndex != 2) {
            revert GameAlreadyOver();
        }
        storageKey = _getStorageKey(battleKey);

        // turnId is NOT submitted — it's the next undrained turn (buffering doesn't execute, so the live
        // turnId is the executed count). The revealer's signature binds this exact id, so a stale or
        // out-of-order submission simply fails recovery below (no separate WrongTurnId check needed).
        turnId = data.turnId + data.numBuffered;

        (address committer, address revealer) = turnId % 2 == 0 ? (data.p0, data.p1) : (data.p1, data.p0);
        if (msg.sender != committer) {
            revert NotCommitter();
        }

        // Decode the committer/revealer halves from the single packed word.
        bytes32 committerMoveHash =
            keccak256(abi.encodePacked(uint8(packedMoves), uint104(packedMoves >> 24), uint16(packedMoves >> 8)));
        {
            SignedCommitLib.DualSignedReveal memory reveal = SignedCommitLib.DualSignedReveal({
                battleKey: battleKey,
                turnId: turnId,
                committerMoveHash: committerMoveHash,
                revealerMoveIndex: uint8(packedMoves >> 128),
                revealerSalt: uint104(packedMoves >> 152),
                revealerExtraData: uint16(packedMoves >> 136)
            });
            bytes32 digest = _hashTypedData(SignedCommitLib.hashDualSignedReveal(reveal));
            if (ECDSA.recover(digest, r, vs) != revealer) {
                revert InvalidSignature();
            }
        }

        // Project (committer, revealer) -> (p0, p1) for the buffer word. packedMoves already holds
        // committer in the low 128 bits, revealer in the high 128 — which IS the buffer (p0|p1) layout on
        // even turns (committer == p0). On odd turns (committer == p1) just swap the two halves.
        packed = turnId % 2 == 0 ? packedMoves : (packedMoves >> 128) | (packedMoves << 128);
    }

    function _drainBuffer(bytes32 battleKey, bytes32 storageKey) internal returns (uint64 executed, address winner) {
        BattleData storage data = battleData[battleKey];
        uint64 startTurn = data.turnId;
        uint256 numBuffered = data.numBuffered;
        if (numBuffered == 0) {
            revert EmptyBuffer();
        }

        storageKeyForWrite = storageKey;
        battleKeyForWrite = battleKey;
        for (uint256 i = 0; i < numBuffered; i++) {
            // Execute directly off the buffer slot. Sub-turns emit no per-turn events (moves were
            // announced via MovesSubmitted at submit), so there's no end-of-drain batch payload to
            // assemble. BattleComplete is emitted by _handleGameOver on the winning turn.
            winner = _executeBatchedEntry(battleKey, storageKey, moveBuffer[storageKey][startTurn + uint64(i)]);
            executed++;
            if (winner != address(0)) {
                break;
            }
            _resetBatchedTurnTransients();
        }
        // Buffer consumed; turnId was advanced per executed turn by _executeInternal.
        data.numBuffered = 0;
    }

    /// @dev Drain any previously-buffered turns (from storage, in order) then execute `currentEntry`
    ///      straight from memory — it's the just-submitted turn that runs in this tx, so it never hits
    ///      storage (no SSTORE on submit, no SLOAD here). If the game ends while draining the prior
    ///      buffer, the current entry is NOT executed (the battle is already over).
    function _drainBufferThenExecute(bytes32 battleKey, bytes32 storageKey, uint256 currentEntry) internal {
        BattleData storage data = battleData[battleKey];
        uint64 startTurn = data.turnId;
        uint256 numBuffered = data.numBuffered;
        storageKeyForWrite = storageKey;
        battleKeyForWrite = battleKey;

        for (uint256 i = 0; i < numBuffered; i++) {
            if (
                _executeBatchedEntry(battleKey, storageKey, moveBuffer[storageKey][startTurn + uint64(i)]) != address(0)
            ) {
                data.numBuffered = 0; // game ended mid-buffer; the current entry does not execute
                return;
            }
            _resetBatchedTurnTransients();
        }
        // Execute the just-submitted entry from memory — no buffer round-trip.
        _executeBatchedEntry(battleKey, storageKey, currentEntry);
        // Only touch numBuffered if there was a prior buffer to clear (1-turn batch leaves it at 0).
        if (numBuffered != 0) {
            data.numBuffered = 0;
        }
    }

    /// @notice One-call buffer reload: the executed-turn count plus every staged-but-undrained buffer
    ///         entry, in turn order — a client resuming mid-battle reads the whole pending buffer in one
    ///         eth_call (`numExecuted`, then `packedTurns`; `packedTurns.length` is the buffered count,
    ///         and `numExecuted + packedTurns.length` is the next turnId to submit). Each word is the
    ///         packed (p0|p1) buffer entry — identical layout to MovesSubmitted's `packed`
    ///         ([p0Move 8 | p0Extra 16 | p0Salt 104 | p1Move 8 | p1Extra 16 | p1Salt 104]) — so the
    ///         consumer reuses one unpack for both.
    function getBufferedTurns(bytes32 battleKey)
        external
        view
        returns (uint64 numExecuted, uint256[] memory packedTurns)
    {
        BattleData storage data = battleData[battleKey];
        if (data.isTwoSlotMode) {
            revert WrongBattleMode(); // use getBufferedSlotTurns
        }
        numExecuted = data.turnId;
        uint256 n = data.numBuffered;
        bytes32 storageKey = _resolveStorageKey(battleKey);
        packedTurns = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            packedTurns[i] = moveBuffer[storageKey][numExecuted + uint64(i)];
        }
    }

    // ---------------------------------------------------------------------
    // Built-in dual-signed buffer flow for 2-slot battles. Per-turn payload = one wire word per
    // side (the executeWithSlotMoves layout, 128 bits each); roles alternate by turnId parity as
    // in the singles flow. A staged turn's two words pack into ONE buffer slot at key turnId
    // (side0 low half, side1 high half) — safe on recycled storage since entries are only read
    // in [turnId, turnId + numBuffered).
    // ---------------------------------------------------------------------

    function submitSlotTurnMoves(
        bytes32 battleKey,
        uint256 committerSidePacked,
        uint256 revealerSidePacked,
        bytes32 r,
        bytes32 vs
    ) external {
        (bytes32 storageKey, uint256 side0, uint256 side1, uint64 turnId, BattleData storage data) =
            _validateAndPackSlotTurn(battleKey, committerSidePacked, revealerSidePacked, r, vs);
        moveBuffer[storageKey][turnId] = side0 | (side1 << 128);
        data.numBuffered = data.numBuffered + 1;
        emit SlotMovesSubmitted(battleKey, side0, side1);
    }

    function submitSlotTurnMovesAndExecute(
        bytes32 battleKey,
        uint256 committerSidePacked,
        uint256 revealerSidePacked,
        bytes32 r,
        bytes32 vs
    ) external {
        (bytes32 storageKey, uint256 side0, uint256 side1,,) =
            _validateAndPackSlotTurn(battleKey, committerSidePacked, revealerSidePacked, r, vs);
        emit SlotMovesSubmitted(battleKey, side0, side1);
        _drainSlotBufferThenExecute(battleKey, storageKey, side0, side1);
    }

    /// @dev VIEW — no state writes: the caller decides whether to buffer or execute, as in
    ///      _validateAndPackTurn.
    function _validateAndPackSlotTurn(
        bytes32 battleKey,
        uint256 committerSidePacked,
        uint256 revealerSidePacked,
        bytes32 r,
        bytes32 vs
    ) internal view returns (bytes32 storageKey, uint256 side0, uint256 side1, uint64 turnId, BattleData storage data) {
        // Side wire words are 128 bits ([m0 8 | e0 16 | m1 8 | e1 16 | salt 80]) so a staged
        // turn's pair packs into ONE buffer slot; wider words would bleed across the halves.
        if (committerSidePacked >> 128 != 0 || revealerSidePacked >> 128 != 0) {
            revert SideWordOverflow();
        }
        data = battleData[battleKey];
        if (!data.usesBuiltinManager) {
            revert NotBuiltInManager();
        }
        if (!data.isTwoSlotMode) {
            revert WrongBattleMode();
        }
        if (data.winnerIndex != 2) {
            revert GameAlreadyOver();
        }
        storageKey = _getStorageKey(battleKey);

        // Same next-undrained-turn derivation as v1; a stale or out-of-order submission fails
        // signature recovery below. Doubles alternates by parity; Multi rotates through the
        // canonical seat order [p0, p2, p1, p3] with the mirror seat revealing (D18) — every
        // player commits once and reveals once per four turns.
        turnId = data.turnId + data.numBuffered;
        address committer;
        address revealer;
        bool committerIsSide0;
        if (data.isMultiMode) {
            // Rotation walks HUMAN seats only (D18/D19), side-major canonical order [p0, p2,
            // p1, p3]: committer = humans[turnId % n], revealer = the opposing side's humans
            // cycled by the same turnId. With no CPU seats this is exactly the mirror rule
            // (t0 A0→B0, t1 A1→B1, t2 B0→A0, t3 B1→A1); with CPU seats their lanes are
            // authored by their side's human (relay trust, D19). Battle start guarantees each
            // side has a human when the built-in manager is used.
            MultiSeatData storage ms = multiSeats[battleKey];
            uint256 cpuSeatMask = ms.cpuSeatMask;
            address[4] memory humans;
            uint256 side0Humans;
            uint256 numHumans;
            for (uint256 i; i < 4; ++i) {
                if (cpuSeatMask & (1 << i) != 0) {
                    continue;
                }
                humans[numHumans++] = _seatAt(data, ms, i);
                if (i < 2) {
                    ++side0Humans;
                }
            }
            uint256 committerCursor = turnId % numHumans;
            committer = humans[committerCursor];
            committerIsSide0 = committerCursor < side0Humans;
            revealer = committerIsSide0
                ? humans[side0Humans + (turnId % (numHumans - side0Humans))]
                : humans[turnId % side0Humans];
        } else {
            committerIsSide0 = turnId % 2 == 0;
            (committer, revealer) = committerIsSide0 ? (data.p0, data.p1) : (data.p1, data.p0);
        }
        if (msg.sender != committer) {
            revert NotCommitter();
        }

        {
            SignedCommitLib.DualSignedSlotReveal memory reveal = SignedCommitLib.DualSignedSlotReveal({
                battleKey: battleKey,
                turnId: turnId,
                committerMovesHash: keccak256(abi.encodePacked(committerSidePacked)),
                revealerSidePacked: revealerSidePacked
            });
            bytes32 digest = _hashTypedData(SignedCommitLib.hashDualSignedSlotReveal(reveal));
            if (ECDSA.recover(digest, r, vs) != revealer) {
                revert InvalidSignature();
            }
        }

        (side0, side1) =
            committerIsSide0 ? (committerSidePacked, revealerSidePacked) : (revealerSidePacked, committerSidePacked);
    }

    /// @dev Canonical seat order [p0, p2, p1, p3] (side-major).
    function _seatAt(BattleData storage data, MultiSeatData storage ms, uint256 canonicalIndex)
        private
        view
        returns (address)
    {
        if (canonicalIndex == 0) {
            return data.p0;
        }
        if (canonicalIndex == 1) {
            return ms.p2;
        }
        if (canonicalIndex == 2) {
            return data.p1;
        }
        return ms.p3;
    }

    /// @dev Both side words always land in the transients; a mask turn's non-acting lanes are
    ///      ignored by the flag, so no per-entry flag dispatch is needed (unlike the v1 drain).
    function _executeBufferedSlotEntry(bytes32 battleKey, bytes32 storageKey, uint256 side0, uint256 side1)
        internal
        returns (address winner)
    {
        _turnP0Packed = _packSideTurn(side0);
        _turnP1Packed = _packSideTurn(side1);
        return _executeInternal(battleKey, storageKey, false, true, true);
    }

    function _drainSlotBuffer(bytes32 battleKey, bytes32 storageKey) internal {
        BattleData storage data = battleData[battleKey];
        uint64 startTurn = data.turnId;
        uint256 numBuffered = data.numBuffered;
        if (numBuffered == 0) {
            revert EmptyBuffer();
        }
        storageKeyForWrite = storageKey;
        battleKeyForWrite = battleKey;
        for (uint256 i = 0; i < numBuffered; i++) {
            uint256 pair = moveBuffer[storageKey][startTurn + uint64(i)];
            address winner =
                _executeBufferedSlotEntry(battleKey, storageKey, pair & ((uint256(1) << 128) - 1), pair >> 128);
            if (winner != address(0)) {
                break;
            }
            _resetBatchedTurnTransients();
        }
        data.numBuffered = 0;
    }

    /// @dev Game over mid-drain skips the just-submitted entry (the battle is already over).
    function _drainSlotBufferThenExecute(bytes32 battleKey, bytes32 storageKey, uint256 side0, uint256 side1) internal {
        BattleData storage data = battleData[battleKey];
        uint64 startTurn = data.turnId;
        uint256 numBuffered = data.numBuffered;
        storageKeyForWrite = storageKey;
        battleKeyForWrite = battleKey;

        for (uint256 i = 0; i < numBuffered; i++) {
            uint256 pair = moveBuffer[storageKey][startTurn + uint64(i)];
            if (
                _executeBufferedSlotEntry(battleKey, storageKey, pair & ((uint256(1) << 128) - 1), pair >> 128)
                    != address(0)
            ) {
                data.numBuffered = 0;
                return;
            }
            _resetBatchedTurnTransients();
        }
        _executeBufferedSlotEntry(battleKey, storageKey, side0, side1);
        if (numBuffered != 0) {
            data.numBuffered = 0;
        }
    }

    /// @notice Buffer reload for 2-slot battles: two wire words per staged turn
    ///         ([2i] = side 0, [2i+1] = side 1), expanded from the packed per-turn slot.
    function getBufferedSlotTurns(bytes32 battleKey)
        external
        view
        returns (uint64 numExecuted, uint256[] memory sideWords)
    {
        BattleData storage data = battleData[battleKey];
        if (!data.isTwoSlotMode) {
            revert WrongBattleMode();
        }
        numExecuted = data.turnId;
        uint256 n = data.numBuffered;
        bytes32 storageKey = _resolveStorageKey(battleKey);
        sideWords = new uint256[](n * 2);
        for (uint256 i = 0; i < n; i++) {
            uint256 pair = moveBuffer[storageKey][numExecuted + uint64(i)];
            sideWords[i * 2] = pair & ((uint256(1) << 128) - 1);
            sideWords[i * 2 + 1] = pair >> 128;
        }
    }

    /// @notice Public resolver for a battle's slot-reused storageKey (the per-battle config slot index).
    ///         Used by tooling/tests to verify slot reuse across battles.
    function getStorageKey(bytes32 battleKey) external view returns (bytes32) {
        return _getStorageKey(battleKey);
    }

    /// @dev Decodes a transient-encoded move (layout: [extraData:16 | packedMoveIndex:8]) into a
    /// MoveDecision. Encoded == 0 means "no current turn move" since packedMoveIndex always has
    /// IS_REAL_TURN_BIT set for a real move.
    function _decodeMove(uint256 encoded) private pure returns (MoveDecision memory m) {
        m.packedMoveIndex = uint8(encoded & 0xFF);
        m.extraData = uint16(encoded >> 8);
    }

    /// @dev Packs a current-turn (encoded move, salt) pair into one transient word:
    /// [salt: bits 0-103 | encoded move: bits 104-127]. Move is unpacked in
    /// _getCurrentTurnMove; salt is unpacked inline at the reveal-hash sites.
    function _packTurn(uint256 encoded, uint104 salt) private pure returns (uint256) {
        return uint256(salt) | (encoded << 104);
    }

    /// @dev Returns the current turn's MoveDecision for `playerIndex`. During an active
    /// execute, reads from transient storage (populated at the start of _executeInternal).
    function _getCurrentTurnMove(BattleConfig storage config, uint256 playerIndex)
        internal
        view
        returns (MoveDecision memory)
    {
        uint256 encoded = (playerIndex == 0 ? _turnP0Packed : _turnP1Packed) >> 104;
        if (encoded != 0) {
            return _decodeMove(encoded);
        }
        return playerIndex == 0 ? config.p0Move : config.p1Move;
    }

    /// @dev Allocation-free current-turn lane with the same transient/storage fallback as
    ///      _getCurrentTurnMove. Used to build fresh external hook context.
    function _currentTurnMoveWord(BattleConfig storage config, uint256 playerIndex) private view returns (uint256) {
        uint256 encoded = (playerIndex == 0 ? _turnP0Packed : _turnP1Packed) >> 104;
        if (encoded != 0) {
            return encoded & 0xFFFFFF;
        }
        return _storedMoveWord(playerIndex == 0 ? config.p0Move : config.p1Move);
    }

    function _storedMoveWord(MoveDecision storage move) private view returns (uint256) {
        return uint256(move.packedMoveIndex) | (uint256(move.extraData) << 8);
    }

    /// @notice Internal execution logic shared by execute() and executeWithMoves()
    /// @dev Two independent event controls. `emitMonMoves`: per-turn MonMoves at the top (legacy
    ///      per-turn execute only — the batched/buffer paths announce moves elsewhere). `emitBattleComplete`:
    ///      the normal BattleComplete on game over (legacy + the PvP buffer drain; the CPU one-tx path
    ///      passes false and emits BattleCompleteWithBatchTurns instead). Combinations in use:
    ///      legacy (true,true), CPU one-tx (false,false), PvP drain (false,true).
    /// @return winner address(0) if the battle is still in progress, otherwise the winning player's address.
    function _executeInternal(
        bytes32 battleKey,
        bytes32 storageKey,
        bool emitMonMoves,
        bool emitBattleComplete,
        bool slotPacked
    ) internal returns (address winner) {
        // Load storage vars
        BattleData storage battle = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKey];

        // Check for game over (winnerIndex and turnId share slot 1: one read)
        uint256 battleWord = _battleWord(battle);
        if (uint8(battleWord >> 160) != 2) {
            revert GameAlreadyOver();
        }

        // Set up turn / player vars
        uint256 turnId = uint16(battleWord >> 232);
        uint256 playerSwitchForTurnFlag = 2;
        uint256 priorityPlayerIndex;

        // battleKeyForWrite is set by every entrypoint next to storageKeyForWrite (once per tx,
        // not per sub-turn). Fresh per-turn acted mask (batched flows run many turns per tx,
        // so auto-clear isn't enough).
        actedSlotsThisTurnMask = 0;

        // Hook loops are gated on the per-battle hook-steps union: prod battles carry the
        // OnBattleEnd-only gacha hook, so without the gate every turn pays per-hook bitmap
        // probes for steps no hook listens at (~2.2k/turn measured). The hook COUNT is read
        // lazily inside each gated branch — prod turns never need it.
        uint16 hookStepsUnion = config.engineHookStepsUnion;
        // Read the mode ADJACENT to the union load (same slot, no call barrier between) so
        // via-IR merges the two into one SLOAD; the hook loop below is a storage barrier that
        // would otherwise force a second slot-3 read for the gate.
        uint8 battleMode = config.battleMode;
        if ((hookStepsUnion & (1 << uint8(EngineHookStep.OnRoundStart))) != 0) {
            uint256 numHooks = config.engineHooksLength;
            for (uint256 i = 0; i < numHooks;) {
                if ((config.engineHooks[i].stepsBitmap & (1 << uint8(EngineHookStep.OnRoundStart))) != 0) {
                    config.engineHooks[i].hook.onRoundStart(battleKey);
                }
                unchecked {
                    ++i;
                }
            }
        }

        // 2-slot battles (Doubles/Multi) take their own turn body from here; the shell above
        // (winner check, round-start hooks) is shared and the tail is duplicated inside.
        // The caller's transient packing must match the mode — a singles-shaped entrypoint on a
        // 2-slot battle (or vice versa) would silently half-execute, so it reverts instead.
        if ((battleMode != BATTLE_MODE_SINGLES) != slotPacked) {
            revert WrongBattleMode();
        }
        if (slotPacked) {
            return _finishSlotTurn(battleKey, config, battle, hookStepsUnion, emitBattleComplete);
        }

        // Emit MonMoves upfront with both players' moves + salts packed into one event.
        // This guarantees clients always receive each player's move + salt, regardless
        // of any early returns (mid-turn KO, shouldSkipTurn, stamina/validator failure)
        // inside _handleMove. Per-lane packedMoveIndex == 0 means that player did not
        // submit (e.g. non-acting side on a switch-only follow-up turn); if both lanes
        // are zero the emit is skipped entirely.
        // Only the legacy per-turn execute path emits MonMoves here. The CPU one-tx path and the PvP
        // buffer drain both pass emitMonMoves=false: CPU carries the replay in BattleCompleteWithBatchTurns,
        // and the PvP path already announced each move via MovesSubmitted at submit time — so re-emitting
        // per-turn MonMoves in the drain would be pure overhead (~1.6k gas/turn).
        // Each player's packed turn word (move + salt + populated flag) is read ONCE here and
        // reused for the populated-detection, the MonMoves emit, and the RNG salts below — this
        // point is after the engine-hook loop, so a hook-driven setMove is still observed, and
        // nothing between here and the salt consumption can rewrite the transient (the flag 0/1
        // branch is mutually exclusive with the RNG block). Execution-time consumers
        // (_handleMove, the AfterMove regen gate) deliberately RE-READ fresh — effects can
        // rewrite the move mid-turn (SleepStatus -> NO_OP).
        uint256 p0Packed = _turnP0Packed;
        uint256 p1Packed = _turnP1Packed;
        // Pre-populated transient (executeWithMoves / buffer paths) vs plain execute() (storage fallback)
        bool cameFromDirectMoveInput = p0Packed != 0 || p1Packed != 0;
        // Allocation-free 24-bit move words: [packedMoveIndex 8 | extraData 16].
        uint256 p0TurnMove = p0Packed != 0 ? (p0Packed >> 104) & 0xFFFFFF : _storedMoveWord(config.p0Move);
        uint256 p1TurnMove = p1Packed != 0 ? (p1Packed >> 104) & 0xFFFFFF : _storedMoveWord(config.p1Move);
        if (emitMonMoves) {
            _emitMonMoves(
                battleKey,
                battle,
                p0TurnMove,
                p1TurnMove,
                p0Packed != 0 ? uint104(p0Packed) : config.p0Salt,
                p1Packed != 0 ? uint104(p1Packed) : config.p1Salt
            );
        }

        // If only a single player has a move to submit, then we don't trigger any effects
        // (Basically this only handles switching mons for now)
        if (battle.playerSwitchForTurnFlag == 0 || battle.playerSwitchForTurnFlag == 1) {
            // Get the player index that needs to switch for this turn
            uint256 playerIndex = battle.playerSwitchForTurnFlag;

            // Run the move (trust that the validator only lets valid single player moves happen as a switch action)
            // Running the move will set the winner flag if valid
            playerSwitchForTurnFlag = _handleMove(battleKey, config, battle, playerIndex, playerSwitchForTurnFlag);
        }
        // Otherwise, we need to run priority calculations and update the game state for both players
        /*
            Flow of battle:
            - Grab moves and calculate pseudo RNG
            - Determine priority player
            - Run round start global effects
            - Run round start targeted effects for p0 and p1
            - Execute priority player's move
            - Check for game over/KO (for switch flag)
                - If game over, just return
            - If KO, skip non priority player's move
            - Execute non priority player's move
            - Check for game over/KO (for switch flag)
                - If game over, just return
            - Run global end of turn effects
            - Check for game over/KO (for switch flag)
                - If game over, just return
            - If not KOed, run the priority player's targeted effects
            - Check for game over/KO (for switch flag)
                - If game over, just return
            - If not KOed, run the non priority player's targeted effects
            - Check for game over/KO (for switch flag)
                - If game over, just return
            - Progress turn index
            - Set player switch for turn flag
        */
        else {
            // Update the temporary RNG to the newest value
            // Inline RNG computation when oracle is address(0) to avoid external call
            uint256 rng;
            uint104 p0TurnSalt = p0Packed != 0 ? uint104(p0Packed) : config.p0Salt;
            uint104 p1TurnSalt = p1Packed != 0 ? uint104(p1Packed) : config.p1Salt;
            if (address(config.rngOracle) == address(0)) {
                rng = uint256(keccak256(abi.encode(p0TurnSalt, p1TurnSalt)));
            } else {
                rng = config.rngOracle.getRNG(bytes32(uint256(p0TurnSalt)), bytes32(uint256(p1TurnSalt)));
            }
            tempRNG = rng;

            // Cache `inlineRegenFlags` once instead of re-reading config slot 2 three times below.
            uint8 inlineRegenFlags = config.inlineRegenFlags;

            // Calculate the priority and non-priority player indices. Use the internal helper
            // with already-resolved config/battle/moves to skip redundant storage re-resolution.
            priorityPlayerIndex = _computePriorityPlayerIndex(config, battle, battleKey, rng, p0TurnMove, p1TurnMove);
            uint256 otherPlayerIndex = 1 - priorityPlayerIndex;

            // Run beginning of round effects. Skip the global-list call when there are no global
            // effects (the inline-regen prod default keeps globalEffectsLength == 0), and skip the
            // per-player calls when no effect anywhere listens at RoundStart (union bit clear) — both
            // avoid the _handleEffects call + its winnerIndex/koOccurredFlag bookkeeping when there is
            // provably nothing to run. Ordering (global, priority, other) is preserved.
            if (config.globalEffectsLength != 0) {
                playerSwitchForTurnFlag = _handleEffects(
                    config,
                    battle,
                    rng,
                    2,
                    2,
                    EffectStep.RoundStart,
                    EffectRunCondition.SkipIfGameOver,
                    playerSwitchForTurnFlag
                );
            }
            if ((config.playerEffectStepsUnion & uint16(1 << uint8(EffectStep.RoundStart))) != 0) {
                playerSwitchForTurnFlag = _handleEffects(
                    config,
                    battle,
                    rng,
                    priorityPlayerIndex,
                    priorityPlayerIndex,
                    EffectStep.RoundStart,
                    EffectRunCondition.SkipIfGameOverOrMonKO,
                    playerSwitchForTurnFlag
                );
                playerSwitchForTurnFlag = _handleEffects(
                    config,
                    battle,
                    rng,
                    otherPlayerIndex,
                    otherPlayerIndex,
                    EffectStep.RoundStart,
                    EffectRunCondition.SkipIfGameOverOrMonKO,
                    playerSwitchForTurnFlag
                );
            }

            // Run priority player's move (NOTE: moves won't run if either mon is KOed)
            actedSlotsThisTurnMask |= 1 << (priorityPlayerIndex << 1);
            playerSwitchForTurnFlag =
                _handleMove(battleKey, config, battle, priorityPlayerIndex, playerSwitchForTurnFlag);

            // If priority mons is not KO'ed, then run the priority player's mon's afterMove hook(s).
            // Union re-read here (not cached from RoundStart): the move just executed may have added an
            // effect that listens at AfterMove.
            if ((config.playerEffectStepsUnion & uint16(1 << uint8(EffectStep.AfterMove))) != 0) {
                playerSwitchForTurnFlag = _handleEffects(
                    config,
                    battle,
                    rng,
                    priorityPlayerIndex,
                    priorityPlayerIndex,
                    EffectStep.AfterMove,
                    EffectRunCondition.SkipIfGameOverOrMonKO,
                    playerSwitchForTurnFlag
                );
            }

            // Always run the global effect's afterMove hook(s)
            if (config.globalEffectsLength != 0) {
                playerSwitchForTurnFlag = _handleEffects(
                    config,
                    battle,
                    rng,
                    2,
                    priorityPlayerIndex,
                    EffectStep.AfterMove,
                    EffectRunCondition.SkipIfGameOver,
                    playerSwitchForTurnFlag
                );
            }

            // Stamina regen decision is encapsulated in _inlineStaminaRegen, which reads the move FRESH
            // — required because effects (SleepStatus) can rewrite the move to a resting NO_OP mid-turn.
            if (inlineRegenFlags & INLINE_REGEN_REST != 0) {
                playerSwitchForTurnFlag = _inlineStaminaRegen(
                    config,
                    EffectStep.AfterMove,
                    priorityPlayerIndex,
                    _unpackActiveMonIndex(battle.activeMonIndex, priorityPlayerIndex),
                    0,
                    0,
                    playerSwitchForTurnFlag
                );
            }

            // Run the non priority player's move
            actedSlotsThisTurnMask |= 1 << (otherPlayerIndex << 1);
            playerSwitchForTurnFlag = _handleMove(battleKey, config, battle, otherPlayerIndex, playerSwitchForTurnFlag);

            // For turn 0 only: wait for both mons to be sent in, then handle the ability activateOnSwitch
            // Happens immediately after both mons are sent in, before any other effects
            if (turnId == 0) {
                uint256 priorityMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, priorityPlayerIndex);
                _activateAbility(
                    config,
                    battleKey,
                    _getTeamMon(config, priorityPlayerIndex, priorityMonIndex).ability,
                    priorityPlayerIndex,
                    priorityMonIndex
                );
                uint256 otherMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, otherPlayerIndex);
                _activateAbility(
                    config,
                    battleKey,
                    _getTeamMon(config, otherPlayerIndex, otherMonIndex).ability,
                    otherPlayerIndex,
                    otherMonIndex
                );
            }

            // If non priority mon is not KOed, then run the non priority player's mon's afterMove hook(s).
            // Union re-read: the non-priority move just executed may have added an AfterMove listener.
            if ((config.playerEffectStepsUnion & uint16(1 << uint8(EffectStep.AfterMove))) != 0) {
                playerSwitchForTurnFlag = _handleEffects(
                    config,
                    battle,
                    rng,
                    otherPlayerIndex,
                    otherPlayerIndex,
                    EffectStep.AfterMove,
                    EffectRunCondition.SkipIfGameOverOrMonKO,
                    playerSwitchForTurnFlag
                );
            }

            // Always run the global effect's afterMove hook(s)
            if (config.globalEffectsLength != 0) {
                playerSwitchForTurnFlag = _handleEffects(
                    config,
                    battle,
                    rng,
                    2,
                    otherPlayerIndex,
                    EffectStep.AfterMove,
                    EffectRunCondition.SkipIfGameOver,
                    playerSwitchForTurnFlag
                );
            }

            if (inlineRegenFlags & INLINE_REGEN_REST != 0) {
                playerSwitchForTurnFlag = _inlineStaminaRegen(
                    config,
                    EffectStep.AfterMove,
                    otherPlayerIndex,
                    _unpackActiveMonIndex(battle.activeMonIndex, otherPlayerIndex),
                    0,
                    0,
                    playerSwitchForTurnFlag
                );
            }

            // Round-end effects. Same guard shape as RoundStart: skip the global call with no global
            // effects, and skip both per-player calls when nothing listens at RoundEnd (union re-read,
            // since the two moves this turn may have applied a RoundEnd status). Ordering preserved.
            if (config.globalEffectsLength != 0) {
                playerSwitchForTurnFlag = _handleEffects(
                    config,
                    battle,
                    rng,
                    2,
                    2,
                    EffectStep.RoundEnd,
                    EffectRunCondition.SkipIfGameOver,
                    playerSwitchForTurnFlag
                );
            }

            if ((config.playerEffectStepsUnion & uint16(1 << uint8(EffectStep.RoundEnd))) != 0) {
                // If priority mon is not KOed, run roundEnd effects for the priority mon
                playerSwitchForTurnFlag = _handleEffects(
                    config,
                    battle,
                    rng,
                    priorityPlayerIndex,
                    priorityPlayerIndex,
                    EffectStep.RoundEnd,
                    EffectRunCondition.SkipIfGameOverOrMonKO,
                    playerSwitchForTurnFlag
                );

                // If non priority mon is not KOed, run roundEnd effects for the non priority mon
                playerSwitchForTurnFlag = _handleEffects(
                    config,
                    battle,
                    rng,
                    otherPlayerIndex,
                    otherPlayerIndex,
                    EffectStep.RoundEnd,
                    EffectRunCondition.SkipIfGameOverOrMonKO,
                    playerSwitchForTurnFlag
                );
            }

            if (inlineRegenFlags & INLINE_REGEN_ROUND_END != 0) {
                uint256 p0Mon = _unpackActiveMonIndex(battle.activeMonIndex, 0);
                uint256 p1Mon = _unpackActiveMonIndex(battle.activeMonIndex, 1);
                playerSwitchForTurnFlag =
                    _inlineStaminaRegen(config, EffectStep.RoundEnd, 0, 0, p0Mon, p1Mon, playerSwitchForTurnFlag);
            }
        }

        // Run the round end hooks (union-gated, same rationale as the RoundStart gate)
        if ((hookStepsUnion & (1 << uint8(EngineHookStep.OnRoundEnd))) != 0) {
            uint256 numHooks = config.engineHooksLength;
            for (uint256 i = 0; i < numHooks;) {
                if ((config.engineHooks[i].stepsBitmap & (1 << uint8(EngineHookStep.OnRoundEnd))) != 0) {
                    config.engineHooks[i].hook.onRoundEnd(battleKey);
                }
                unchecked {
                    ++i;
                }
            }
        }

        // If a winner has been set, handle the game over
        if (battle.winnerIndex != 2) {
            winner = (battle.winnerIndex == 0) ? battle.p0 : battle.p1;
            // Clear storage move slots before _handleGameOver frees the storage key for reuse: a
            // recycled config would otherwise keep this battle's final setMove-written
            // IS_REAL_TURN_BIT, letting anyone drive the next battle's turn 0 via the
            // permissionless execute() with stale moves. Conditional for the same reason as the
            // end-of-turn clear below — transient-path battles never write these slots.
            if (!cameFromDirectMoveInput) {
                config.p0Move.packedMoveIndex = 0;
                config.p1Move.packedMoveIndex = 0;
            }
            // CPU one-tx path (emitBattleComplete=false) suppresses BattleComplete here —
            // executeBatchedTurns emits BattleCompleteWithBatchTurns after the loop with the full turn
            // list. Legacy + the PvP buffer drain (emitBattleComplete=true) emit the normal BattleComplete.
            _handleGameOver(battleKey, winner, emitBattleComplete);
            return winner;
        }

        // End of turn cleanup: advance the turn, store the switch flag and timestamp, and clear
        // the storage move flags for next turn (clear isRealTurn bit by zeroing packedMoveIndex).
        _advanceTurn(battle, playerSwitchForTurnFlag);
        // Clear storage move slots only when they were actually written via setMove (execute() path).
        // executeWithMoves never writes, so the slots stay zero and a clear here would burn ~4.4k on
        // a cold-access SSTORE 0→0.
        if (!cameFromDirectMoveInput) {
            config.p0Move.packedMoveIndex = 0;
            config.p1Move.packedMoveIndex = 0;
        }
    }

    /// @notice Clears transient storage that otherwise persists across multiple execute()/executeWithMoves()
    /// calls within the same transaction. Intended for foundry test harnesses that dispatch multiple turns
    /// in one test function (the EVM's per-tx transient-clear doesn't fire between `vm.prank`-delimited
    /// calls). Zero-cost in production since every call is its own tx and transient auto-clears at tx end.
    /// @dev Also clears `battleKeyForWrite` / `storageKeyForWrite` so view getters that fall back to the
    /// persistent `battleKeyToStorageKey` mapping (e.g. `getBattle` for ended battles) behave the same in
    /// tests as on a fresh-tx production call. Any subsequent `execute()` re-sets both at entry, and the
    /// in-`execute` readers (StatBoosts, etc.) run after that — so this is safe to call between turns.
    /// Note: this loses `setMove`'s `isForCurrentBattle` cache hit (Engine.sol:1454) on the next setMove,
    /// adding one warm SLOAD per call. Production never calls this so the regression is test-only.
    function resetCallContext() external {
        _turnP0Packed = 0;
        _turnP1Packed = 0;
        battleKeyForWrite = bytes32(0);
        storageKeyForWrite = bytes32(0);
        // Per-turn transients that `executeBatchedTurns` resets between sub-turns; cleared here too
        // so each call starts like a fresh tx (these auto-clear at tx end in prod).
        tempRNG = 0;
        koOccurredFlag = 0;
        tempPreDamage = 0;
        effectsDirtyBitmap = 0;
        _speedDirtySlots = 0;
    }

    /// @notice Forcibly end a stalled battle once it has run past MAX_BATTLE_DURATION.
    /// @dev Permissionless. Per-turn inactivity detection has been removed, so this max-duration
    ///      cleanup is the sole on-chain stall-resolution path (a future external resolver can
    ///      declare timeout winners via the validator's `validateTimeout` surface). Called before
    ///      the window elapses it is a silent no-op.
    function end(bytes32 battleKey) external {
        BattleData storage data = battleData[battleKey];
        if (data.winnerIndex != 2) {
            revert GameAlreadyOver();
        }
        bytes32 storageKey = _getStorageKey(battleKey);
        storageKeyForWrite = storageKey;
        BattleConfig storage config = battleConfig[storageKey];
        if (block.timestamp - config.startTimestamp > MAX_BATTLE_DURATION) {
            // Award p0, matching the BattleComplete(p0) event _handleGameOver emits. Setting
            // winnerIndex is required: _handleGameOver itself never writes it, so without this the
            // battle would stay winnerIndex==2 (commit manager would never see it as complete).
            data.winnerIndex = 0;
            // Clear any storage-written move slots (e.g. a lone revealed move on a stalled
            // commit-reveal battle) so the freed key cannot be recycled with a live
            // IS_REAL_TURN_BIT — same hygiene as the game-over path in _executeInternal. Rare
            // cold path; the writes are cheap no-ops when the slots are already clear.
            config.p0Move.packedMoveIndex = 0;
            config.p1Move.packedMoveIndex = 0;
            _handleGameOver(battleKey, data.p0, true);
        }
    }

    /// @notice Concede: the caller's side loses and the opposing side is awarded the win.
    /// @dev In Multi, either seat on a side forfeits for the whole side. Grants no gacha
    ///      rewards (the OnBattleEnd reward gate requires a fully KO'd side), like end().
    function forfeit(bytes32 battleKey) external {
        BattleData storage data = battleData[battleKey];
        if (data.winnerIndex != 2) {
            revert GameAlreadyOver();
        }
        uint256 forfeiterSide;
        if (msg.sender == data.p0) {
            forfeiterSide = 0;
        } else if (msg.sender == data.p1) {
            forfeiterSide = 1;
        } else if (data.isMultiMode && msg.sender == multiSeats[battleKey].p2) {
            forfeiterSide = 0;
        } else if (data.isMultiMode && msg.sender == multiSeats[battleKey].p3) {
            forfeiterSide = 1;
        } else {
            revert NotPlayerInBattle();
        }
        bytes32 storageKey = _getStorageKey(battleKey);
        storageKeyForWrite = storageKey;
        BattleConfig storage config = battleConfig[storageKey];
        data.winnerIndex = uint8((forfeiterSide + 1) % 2);
        // Same freed-key hygiene as end(): no live IS_REAL_TURN_BIT on a recycled config.
        config.p0Move.packedMoveIndex = 0;
        config.p1Move.packedMoveIndex = 0;
        _handleGameOver(battleKey, (forfeiterSide == 0) ? data.p1 : data.p0, true);
    }

    /// @param emitBattleComplete When false (batched path), the plain BattleComplete emit is
    ///        suppressed — `executeBatchedTurns` emits BattleCompleteWithBatchTurns instead so the
    ///        winner + full turn list arrive in one log. Hooks (GachaEvent) + key-free still run.
    function _handleGameOver(bytes32 battleKey, address winner, bool emitBattleComplete) internal {
        bytes32 storageKey = storageKeyForWrite;
        BattleConfig storage config = battleConfig[storageKey];

        if (block.timestamp == config.startTimestamp) {
            revert GameStartsAndEndsSameBlock();
        }

        for (uint256 i = 0; i < config.engineHooksLength;) {
            if ((config.engineHooks[i].stepsBitmap & (1 << uint8(EngineHookStep.OnBattleEnd))) != 0) {
                config.engineHooks[i].hook.onBattleEnd(battleKey);
            }
            unchecked {
                ++i;
            }
        }

        // Free the key used for battle configs so other battles can use it
        _freeStorageKey(battleKey, storageKey);
        if (emitBattleComplete) {
            emit BattleComplete(battleKey, winner);
        }
    }

    /**
     * - Write functions for MonState, Effects, and GlobalKV
     */
    function _updateMonStateInternal(
        uint256 playerIndex,
        uint256 monIndex,
        MonStateIndexName stateVarIndex,
        int32 valueToAdd
    ) internal {
        bytes32 battleKey = battleKeyForWrite;
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        MonState storage monState = _getMonState(config, playerIndex, monIndex);
        if (stateVarIndex == MonStateIndexName.Hp) {
            monState.hpDelta =
                (monState.hpDelta == CLEARED_MON_STATE_SENTINEL) ? valueToAdd : monState.hpDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.Stamina) {
            monState.staminaDelta =
                (monState.staminaDelta == CLEARED_MON_STATE_SENTINEL) ? valueToAdd : monState.staminaDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.Speed) {
            monState.speedDelta =
                (monState.speedDelta == CLEARED_MON_STATE_SENTINEL) ? valueToAdd : monState.speedDelta + valueToAdd;
            if (config.battleMode != BATTLE_MODE_SINGLES) {
                _markActiveMonSpeedDirty(playerIndex, monIndex);
            }
        } else if (stateVarIndex == MonStateIndexName.Attack) {
            monState.attackDelta =
                (monState.attackDelta == CLEARED_MON_STATE_SENTINEL) ? valueToAdd : monState.attackDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.Defense) {
            monState.defenceDelta =
                (monState.defenceDelta == CLEARED_MON_STATE_SENTINEL) ? valueToAdd : monState.defenceDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.SpecialAttack) {
            monState.specialAttackDelta = (monState.specialAttackDelta == CLEARED_MON_STATE_SENTINEL)
                ? valueToAdd
                : monState.specialAttackDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.SpecialDefense) {
            monState.specialDefenceDelta = (monState.specialDefenceDelta == CLEARED_MON_STATE_SENTINEL)
                ? valueToAdd
                : monState.specialDefenceDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.IsKnockedOut) {
            bool newKOState = (valueToAdd % 2) == 1;
            bool wasKOed = monState.isKnockedOut;
            monState.isKnockedOut = newKOState;
            // Update KO bitmap if state changed
            if (newKOState && !wasKOed) {
                _setMonKO(config, playerIndex, monIndex);
                koOccurredFlag = 1;
                // Lock in winner immediately if this KO ends the game
                _checkAndSetWinnerIfGameOver(config, playerIndex);
            } else if (!newKOState && wasKOed) {
                _clearMonKO(config, playerIndex, monIndex);
            }
        } else if (stateVarIndex == MonStateIndexName.ShouldSkipTurn) {
            monState.shouldSkipTurn = (valueToAdd % 2) == 1;
        }

        // Exact per-mon step lane skips abi.encode + the whole effect shell unless THIS mon has an
        // OnUpdateMonState listener. This path is hot for stamina and stat-boost delta writes.
        if (_monListensAt(config, playerIndex, monIndex, EffectStep.OnUpdateMonState)) {
            _runEffectsPipeline(
                config,
                playerIndex,
                monIndex,
                EffectStep.OnUpdateMonState,
                abi.encode(playerIndex, monIndex, stateVarIndex, valueToAdd)
            );
        }
    }

    /// @dev Routes a state-change pipeline (PreDamage / AfterDamage / OnUpdateMonState) to the
    ///      right effect loop: singles derives the mon from the side's active lane (legacy
    ///      behavior); 2-slot battles run the state-changed mon's own list, keeping the caller's
    ///      count gate and the iterated list consistent. Only reached when a listener exists —
    ///      the mode read is a warm slot-3 SLOAD on that rare path.
    function _runEffectsPipeline(
        BattleConfig storage config,
        uint256 playerIndex,
        uint256 monIndex,
        EffectStep round,
        bytes memory extraEffectsData
    ) private {
        if (config.battleMode != BATTLE_MODE_SINGLES) {
            _runEffectsForMon(
                config,
                battleData[battleKeyForWrite],
                tempRNG,
                playerIndex,
                playerIndex,
                monIndex,
                round,
                extraEffectsData,
                type(uint256).max
            );
        } else {
            _runEffects(
                battleKeyForWrite, tempRNG, playerIndex, playerIndex, round, extraEffectsData, type(uint256).max
            );
        }
    }

    function updateMonState(uint256 playerIndex, uint256 monIndex, MonStateIndexName stateVarIndex, int32 valueToAdd)
        external
    {
        if (battleKeyForWrite == bytes32(0)) {
            revert NoWriteAllowed();
        }
        // Speed(2)..SpecialDefense(6) are the stat-boost-owned deltas — reject direct writes so they
        // can only change through add/removeStatBoost (the internal stat-boost path bypasses this by
        // calling _updateMonStateInternal directly). Hp/Stamina/IsKnockedOut/ShouldSkipTurn stay open.
        uint256 idx = uint256(stateVarIndex);
        if (idx >= uint256(MonStateIndexName.Speed) && idx <= uint256(MonStateIndexName.SpecialDefense)) {
            revert StatRequiresStatBoost();
        }
        _updateMonStateInternal(playerIndex, monIndex, stateVarIndex, valueToAdd);
    }

    function _isEffectRegistered(BattleConfig storage config, uint256 playerIndex, uint256 monIndex, address effectAddr)
        internal
        view
        returns (bool)
    {
        uint256 effectCount;
        if (playerIndex == 0) {
            effectCount = _getMonEffectCount(config.packedP0EffectsCount, monIndex);
            for (uint256 i; i < effectCount; i++) {
                uint256 slotIndex = _getEffectSlotIndex(monIndex, i);
                if (address(config.p0Effects[slotIndex].effect) == effectAddr) {
                    return true;
                }
            }
        } else {
            effectCount = _getMonEffectCount(config.packedP1EffectsCount, monIndex);
            for (uint256 i; i < effectCount; i++) {
                uint256 slotIndex = _getEffectSlotIndex(monIndex, i);
                if (address(config.p1Effects[slotIndex].effect) == effectAddr) {
                    return true;
                }
            }
        }
        return false;
    }

    function _inlineAbilityActivation(
        BattleConfig storage config,
        uint256 rawAbilitySlot,
        uint256 playerIndex,
        uint256 monIndex
    ) internal {
        uint8 abilityTypeId = uint8(rawAbilitySlot >> 248);
        address effectAddr = address(uint160(rawAbilitySlot));

        if (abilityTypeId == 1) {
            // Singleton self-register, mon-local:
            // Idempotency check + addEffect(playerIndex, monIndex, effectAddr, bytes32(0))
            if (!_isEffectRegistered(config, playerIndex, monIndex, effectAddr)) {
                _addEffectInternal(playerIndex, monIndex, IEffect(effectAddr), bytes32(0));
            }
        }
    }

    function _activateAbility(
        BattleConfig storage config,
        bytes32 battleKey,
        uint256 rawAbility,
        uint256 playerIndex,
        uint256 monIndex
    ) internal {
        if (rawAbility == 0) {
            return;
        }
        if (rawAbility >> 160 != 0) {
            _inlineAbilityActivation(config, rawAbility, playerIndex, monIndex);
        } else {
            IAbility(address(uint160(rawAbility)))
                .activateOnSwitch(IEngine(address(this)), battleKey, playerIndex, monIndex);
        }
    }

    function _addEffectInternal(uint256 targetIndex, uint256 monIndex, IEffect effect, bytes32 extraData) internal {
        bytes32 battleKey = battleKeyForWrite;
        // Fetch steps bitmap once (reused for the status gate, ALWAYS_APPLIES check, and storage)
        uint32 effectMetadata = effect.getStepsBitmap();
        uint16 stepsBitmap = uint16(effectMetadata);
        uint16 hookContextBitmap = uint16(effectMetadata >> EFFECT_CONTEXT_SHIFT);
        BattleConfig storage config = battleConfig[storageKeyForWrite];

        // Exclusive-status gate (class-bearing player effects only), ahead of any external call:
        // a different status blocks, and a same-class re-apply is a no-op unless HAS_REAPPLY
        // routes it to the existing entry's onReapply. Both blocked paths cost zero external
        // calls; the free-lane path falls through to the normal gate below.
        {
            uint256 statusClass = (stepsBitmap >> STATUS_CLASS_SHIFT) & STATUS_CLASS_MASK;
            if (statusClass != 0 && targetIndex != 2) {
                uint256 lane = (config.monStatusLanes >> _statusLaneShift(targetIndex, monIndex)) & 0xF;
                if (lane != 0) {
                    if (lane == statusClass && (stepsBitmap & HAS_REAPPLY_BIT) != 0) {
                        _reapplyStatus(config, battleKey, targetIndex, monIndex, statusClass);
                    }
                    return;
                }
            }
        }

        // Skip external shouldApply() call if ALWAYS_APPLIES_BIT is set
        bool applies;
        if ((stepsBitmap & ALWAYS_APPLIES_BIT) != 0) {
            applies = true;
        } else {
            applies = effect.shouldApply(IEngine(address(this)), battleKey, extraData, targetIndex, monIndex);
        }

        if (applies) {
            bytes32 extraDataToUse = extraData;
            bool removeAfterRun = false;

            // Check if we have to run an onApply state update (use bitmap instead of external call)
            if ((stepsBitmap & (1 << uint8(EffectStep.OnApply))) != 0) {
                uint256 applyContext = _hookActivesWord(battleData[battleKey]);
                if ((hookContextBitmap & (1 << uint8(EffectStep.OnApply))) != 0 && targetIndex < 2) {
                    // OnApply is executed before the effect is stored, so its exact request bit is
                    // still available. Max HP is immutable for the battle and occupies bits 32..63.
                    applyContext |= uint256(_getTeamMon(config, targetIndex, monIndex).stats.hp) << 32;
                }
                // If so, we run the effect first, and get updated extraData if necessary
                (extraDataToUse, removeAfterRun) = effect.onApply(
                    IEngine(address(this)), battleKey, tempRNG, extraData, targetIndex, monIndex, applyContext
                );
            }
            if (!removeAfterRun) {
                // INVARIANT: every player-effect add folds its bitmap into BOTH routing caches here:
                // the over-approximate battle-wide outer union and this mon's exact lane. A missed
                // update would silently skip a live hook. This is the sole player-effect add chokepoint
                // (stat boosts use their own store).
                // Global effects (targetIndex == 2) are gated by globalEffectsLength instead, not the union.
                if (targetIndex != 2) {
                    config.playerEffectStepsUnion |= stepsBitmap;
                    uint256 stepLaneShift = _effectStepLaneShift(targetIndex, monIndex);
                    config.playerEffectStepsByMon |= uint256(stepsBitmap) << stepLaneShift;
                    // Status-lane set: same slot as the union write, so both coalesce into one
                    // SSTORE. INVARIANT: lane nonzero ⇔ exactly one class-bearing entry on the
                    // mon; the only clears are _removeEffectAtSlot + startBattle's reset.
                    uint256 statusClass = (stepsBitmap >> STATUS_CLASS_SHIFT) & STATUS_CLASS_MASK;
                    if (statusClass != 0) {
                        uint256 laneShift = _statusLaneShift(targetIndex, monIndex);
                        config.monStatusLanes = uint64(
                            (uint256(config.monStatusLanes) & ~(uint256(0xF) << laneShift)) | (statusClass << laneShift)
                        );
                    }
                }

                if (targetIndex == 2) {
                    // Global effects use simple sequential indexing
                    uint256 effectIndex = config.globalEffectsLength;
                    EffectInstance storage effectSlot = config.globalEffects[effectIndex];
                    _writeEffectInstance(effectSlot, effect, stepsBitmap, extraDataToUse, hookContextBitmap);
                    config.globalEffectsLength = uint8(effectIndex + 1);
                    // Set dirty bit 0 for global effects
                    effectsDirtyBitmap |= 1;
                } else if (targetIndex == 0) {
                    // Player effects use per-mon indexing: slot = MAX_EFFECTS_PER_MON * monIndex + count[monIndex]
                    uint256 monEffectCount = _getMonEffectCount(config.packedP0EffectsCount, monIndex);
                    uint256 slotIndex = _getEffectSlotIndex(monIndex, monEffectCount);
                    EffectInstance storage effectSlot = config.p0Effects[slotIndex];
                    _writeEffectInstance(effectSlot, effect, stepsBitmap, extraDataToUse, hookContextBitmap);
                    config.packedP0EffectsCount =
                        _setMonEffectCount(config.packedP0EffectsCount, monIndex, monEffectCount + 1);
                    // Set dirty bit (1 + monIndex) for P0 effects
                    effectsDirtyBitmap |= (1 << (1 + monIndex));
                } else {
                    uint256 monEffectCount = _getMonEffectCount(config.packedP1EffectsCount, monIndex);
                    uint256 slotIndex = _getEffectSlotIndex(monIndex, monEffectCount);
                    EffectInstance storage effectSlot = config.p1Effects[slotIndex];
                    _writeEffectInstance(effectSlot, effect, stepsBitmap, extraDataToUse, hookContextBitmap);
                    config.packedP1EffectsCount =
                        _setMonEffectCount(config.packedP1EffectsCount, monIndex, monEffectCount + 1);
                    // Set dirty bit (9 + monIndex) for P1 effects
                    effectsDirtyBitmap |= (1 << (9 + monIndex));
                }
            }
        }
    }

    /// @dev Same-class re-apply with HAS_REAPPLY set: find the live entry and let it rewrite
    ///      (or remove) itself. The scan is bounded by the mon's short effect list and only
    ///      runs for escalating statuses (Burn) — plain re-applies never get here.
    function _reapplyStatus(
        BattleConfig storage config,
        bytes32 battleKey,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 statusClass
    ) private {
        uint96 packedCounts = targetIndex == 0 ? config.packedP0EffectsCount : config.packedP1EffectsCount;
        uint256 monEffectCount = _getMonEffectCount(packedCounts, monIndex);
        mapping(uint256 => EffectInstance) storage effects = targetIndex == 0 ? config.p0Effects : config.p1Effects;
        uint256 baseSlot = _getEffectSlotIndex(monIndex, 0);
        for (uint256 i; i < monEffectCount;) {
            EffectInstance storage e = effects[baseSlot + i];
            if (
                address(e.effect) != TOMBSTONE_ADDRESS
                    && ((e.stepsBitmap >> STATUS_CLASS_SHIFT) & STATUS_CLASS_MASK) == statusClass
            ) {
                (bytes32 newData, bool removeAfterRun) = IStatusEffect(address(e.effect))
                    .onReapply(
                        IEngine(address(this)),
                        battleKey,
                        tempRNG,
                        _effectData(e),
                        targetIndex,
                        monIndex,
                        _hookActivesWord(battleData[battleKey])
                    );
                if (removeAfterRun) {
                    _removeEffectAtSlot(config, battleKey, targetIndex, monIndex, baseSlot + i);
                } else {
                    _setEffectData(e, newData);
                }
                return;
            }
            unchecked {
                ++i;
            }
        }
    }

    function addEffect(uint256 targetIndex, uint256 monIndex, IEffect effect, bytes32 extraData) external {
        if (battleKeyForWrite == bytes32(0)) {
            revert NoWriteAllowed();
        }
        _addEffectInternal(targetIndex, monIndex, effect, extraData);
    }

    function editEffect(uint256 targetIndex, uint256 effectIndex, bytes32 newExtraData) external {
        bytes32 battleKey = battleKeyForWrite;
        if (battleKey == bytes32(0)) {
            revert NoWriteAllowed();
        }

        // Access the appropriate effects mapping based on targetIndex
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        EffectInstance storage effectInstance;
        if (targetIndex == 2) {
            effectInstance = config.globalEffects[effectIndex];
        } else if (targetIndex == 0) {
            effectInstance = config.p0Effects[effectIndex];
        } else {
            effectInstance = config.p1Effects[effectIndex];
        }

        _setEffectData(effectInstance, newExtraData);
    }

    function removeEffect(uint256 targetIndex, uint256 monIndex, uint256 indexToRemove) public {
        bytes32 battleKey = battleKeyForWrite;
        if (battleKey == bytes32(0)) {
            revert NoWriteAllowed();
        }
        _removeEffectAtSlot(battleConfig[storageKeyForWrite], battleKey, targetIndex, monIndex, indexToRemove);
    }

    /// @dev Bit offset of a mon's 4-bit status-class nibble in monStatusLanes (stride 8/side).
    function _statusLaneShift(uint256 targetIndex, uint256 monIndex) private pure returns (uint256) {
        return ((targetIndex << 3) | monIndex) << 2;
    }

    /// @dev Bit offset of a mon's uint16 exact lifecycle-step union (stride 8/side).
    function _effectStepLaneShift(uint256 targetIndex, uint256 monIndex) private pure returns (uint256) {
        return ((targetIndex << 3) | monIndex) << 4;
    }

    uint16 private constant EFFECT_RESOLVER_METADATA_BIT = uint16(1) << 15;
    uint256 private constant EFFECT_COMPACT_DATA_BITS = 78;
    uint256 private constant EFFECT_COMPACT_DATA_MASK = (uint256(1) << EFFECT_COMPACT_DATA_BITS) - 1;
    uint256 private constant EFFECT_RESOLVER_FLAG = uint256(1) << 254;
    uint256 private constant EFFECT_HOOK_CONTEXT_FLAG = uint256(1) << 255;
    uint256 private constant EFFECT_HEADER_BASE_MASK =
        uint256(type(uint176).max) | EFFECT_RESOLVER_FLAG | EFFECT_HOOK_CONTEXT_FLAG;
    uint256 private constant FRESH_HOOK_CONTEXT_REQUEST = uint256(1) << 255;

    /// @dev Effect header layout: address[0:160], steps[160:176], compact-data marker[176:254],
    /// resolver capability[254], fresh-hook-context capability[255]. A nonzero marker stores
    /// `data + 1`; zero means the full bytes32 lives in slot 1.
    function _effectData(EffectInstance storage effectInstance) private view returns (bytes32 data) {
        uint256 header;
        assembly ("memory-safe") {
            header := sload(effectInstance.slot)
        }
        uint256 encoded = (header >> 176) & EFFECT_COMPACT_DATA_MASK;
        if (encoded != 0) {
            return bytes32(encoded - 1);
        }
        return effectInstance.data;
    }

    function _setEffectData(EffectInstance storage effectInstance, bytes32 data) private {
        uint256 header;
        assembly ("memory-safe") {
            header := sload(effectInstance.slot)
        }
        uint256 raw = uint256(data);
        if (raw < EFFECT_COMPACT_DATA_MASK) {
            header = (header & EFFECT_HEADER_BASE_MASK) | ((raw + 1) << 176);
            assembly ("memory-safe") {
                sstore(effectInstance.slot, header)
            }
        } else {
            if (((header >> 176) & EFFECT_COMPACT_DATA_MASK) != 0) {
                header &= EFFECT_HEADER_BASE_MASK;
                assembly ("memory-safe") {
                    sstore(effectInstance.slot, header)
                }
            }
            effectInstance.data = data;
        }
    }

    function _writeEffectInstance(
        EffectInstance storage effectInstance,
        IEffect effect,
        uint16 stepsBitmap,
        bytes32 data,
        uint16 hookContextBitmap
    ) private {
        uint256 raw = uint256(data);
        uint256 encoded = raw < EFFECT_COMPACT_DATA_MASK ? raw + 1 : 0;
        // OnApply has already run before installation. Do not persist an OnApply-only request as
        // the broad capability flag, which would make multi-hook statuses build unused contexts.
        bool usesResolver = hookContextBitmap & EFFECT_RESOLVER_METADATA_BIT != 0;
        uint16 storedContextBitmap =
            hookContextBitmap & ~uint16((1 << uint8(EffectStep.OnApply)) | EFFECT_RESOLVER_METADATA_BIT);
        uint256 header = uint256(uint160(address(effect))) | (uint256(stepsBitmap) << 160) | (encoded << 176)
            | (usesResolver ? EFFECT_RESOLVER_FLAG : 0) | (storedContextBitmap != 0 ? EFFECT_HOOK_CONTEXT_FLAG : 0);
        assembly ("memory-safe") {
            sstore(effectInstance.slot, header)
        }
        if (encoded == 0) {
            effectInstance.data = data;
        }
    }

    function _effectDataAndHookContext(EffectInstance storage effectInstance)
        private
        view
        returns (bytes32 data, bool needsFreshContext, bool usesResolver)
    {
        uint256 header;
        assembly ("memory-safe") {
            header := sload(effectInstance.slot)
        }
        uint256 encoded = (header >> 176) & EFFECT_COMPACT_DATA_MASK;
        data = encoded == 0 ? effectInstance.data : bytes32(encoded - 1);
        needsFreshContext = header & EFFECT_HOOK_CONTEXT_FLAG != 0;
        usesResolver = header & EFFECT_RESOLVER_FLAG != 0;
    }

    function _monEffectSteps(BattleConfig storage config, uint256 targetIndex, uint256 monIndex)
        private
        view
        returns (uint16)
    {
        return uint16(config.playerEffectStepsByMon >> _effectStepLaneShift(targetIndex, monIndex));
    }

    function _monListensAt(BattleConfig storage config, uint256 targetIndex, uint256 monIndex, EffectStep step)
        private
        view
        returns (bool)
    {
        return _stepsWordListens(config.playerEffectStepsByMon, targetIndex, monIndex, step);
    }

    function _stepsWordListens(uint256 stepsWord, uint256 targetIndex, uint256 monIndex, EffectStep step)
        private
        pure
        returns (bool)
    {
        return ((stepsWord >> _effectStepLaneShift(targetIndex, monIndex)) & (1 << uint8(step))) != 0;
    }

    /// @notice Remove a mon's exclusive status (running its onRemove) and clear its lane.
    /// @param expectedClass 0 = clear any status; nonzero = only a matching class.
    /// @return cleared Whether a status entry was removed.
    function clearMonStatus(uint256 targetIndex, uint256 monIndex, uint256 expectedClass)
        external
        returns (bool cleared)
    {
        if (battleKeyForWrite == bytes32(0)) {
            revert NoWriteAllowed();
        }
        return _clearMonStatus(targetIndex, monIndex, expectedClass);
    }

    function _clearMonStatus(uint256 targetIndex, uint256 monIndex, uint256 expectedClass)
        private
        returns (bool cleared)
    {
        bytes32 battleKey = battleKeyForWrite;
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        uint256 lane = (config.monStatusLanes >> _statusLaneShift(targetIndex, monIndex)) & 0xF;
        if (lane == 0 || (expectedClass != 0 && lane != expectedClass)) {
            return false;
        }
        // Scan the mon's short effect list for the class-bearing entry (cold path; the lane
        // answers the hot existence/identity reads without a scan).
        uint96 packedCounts = targetIndex == 0 ? config.packedP0EffectsCount : config.packedP1EffectsCount;
        uint256 monEffectCount = _getMonEffectCount(packedCounts, monIndex);
        mapping(uint256 => EffectInstance) storage effects = targetIndex == 0 ? config.p0Effects : config.p1Effects;
        uint256 baseSlot = _getEffectSlotIndex(monIndex, 0);
        for (uint256 i; i < monEffectCount;) {
            EffectInstance storage e = effects[baseSlot + i];
            if (
                address(e.effect) != TOMBSTONE_ADDRESS
                    && ((e.stepsBitmap >> STATUS_CLASS_SHIFT) & STATUS_CLASS_MASK) == lane
            ) {
                _removeEffectAtSlot(config, battleKey, targetIndex, monIndex, baseSlot + i);
                return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _removeEffectAtSlot(
        BattleConfig storage config,
        bytes32 battleKey,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 slotIndex
    ) private {
        EffectInstance storage eff;
        if (targetIndex == 2) {
            eff = config.globalEffects[slotIndex];
        } else if (targetIndex == 0) {
            eff = config.p0Effects[slotIndex];
        } else {
            eff = config.p1Effects[slotIndex];
        }

        IEffect effect = eff.effect;
        if (address(effect) == TOMBSTONE_ADDRESS) {
            return;
        }
        uint16 stepsBitmap = eff.stepsBitmap;

        // Status-lane clear (free: stepsBitmap shares the slot just loaded). Cleared before
        // onRemove so a nested add during the hook sees the lane free. This is the SOLE
        // class-bearing removal chokepoint — the direct tombstone writers elsewhere are all
        // stat-boost slots, which never carry class bits.
        if (targetIndex != 2) {
            uint256 statusClass = (stepsBitmap >> STATUS_CLASS_SHIFT) & STATUS_CLASS_MASK;
            if (statusClass != 0) {
                config.monStatusLanes &= ~uint64(uint256(0xF) << _statusLaneShift(targetIndex, monIndex));
            }
        }

        if ((stepsBitmap & (1 << uint8(EffectStep.OnRemove))) != 0) {
            effect.onRemove(
                IEngine(address(this)),
                battleKey,
                _effectData(eff),
                targetIndex,
                monIndex,
                _hookActivesWord(battleData[battleKey])
            );
        }

        eff.effect = IEffect(TOMBSTONE_ADDRESS);
        if (targetIndex == 2) {
            uint256 len = config.globalEffectsLength;
            uint256 newLen = len;
            while (newLen > 0 && address(config.globalEffects[newLen - 1].effect) == TOMBSTONE_ADDRESS) {
                unchecked {
                    --newLen;
                }
            }
            if (newLen != len) {
                config.globalEffectsLength = uint8(newLen);
            }
        } else {
            _compactTrailingTombstones(config, targetIndex, monIndex);
            _rebuildMonEffectSteps(config, targetIndex, monIndex);
        }
    }

    /// @dev Exact-clear the changed mon's step lane after a removal. Removal is cold and already
    ///      scans/compacts this short list; the hot turn and damage paths consume the exact cache.
    function _rebuildMonEffectSteps(BattleConfig storage config, uint256 targetIndex, uint256 monIndex) private {
        uint96 packedCounts = targetIndex == 0 ? config.packedP0EffectsCount : config.packedP1EffectsCount;
        uint256 count = _getMonEffectCount(packedCounts, monIndex);
        mapping(uint256 => EffectInstance) storage effects = targetIndex == 0 ? config.p0Effects : config.p1Effects;
        uint256 baseSlot = _getEffectSlotIndex(monIndex, 0);
        uint16 rebuilt;
        for (uint256 i; i < count;) {
            EffectInstance storage e = effects[baseSlot + i];
            if (address(e.effect) != TOMBSTONE_ADDRESS) {
                rebuilt |= e.stepsBitmap;
            }
            unchecked {
                ++i;
            }
        }
        uint256 shift = _effectStepLaneShift(targetIndex, monIndex);
        uint256 mask = uint256(type(uint16).max) << shift;
        config.playerEffectStepsByMon = (config.playerEffectStepsByMon & ~mask) | (uint256(rebuilt) << shift);
    }

    /// @dev Shrink a mon's packed effect count over any trailing tombstones so the count-gated
    ///      passes (and the all-actives-clean early-out) regain their zero fast path. Only the
    ///      tail can shrink — a live entry above a tombstone pins the count.
    function _compactTrailingTombstones(BattleConfig storage config, uint256 targetIndex, uint256 monIndex) private {
        uint96 packedCounts = targetIndex == 0 ? config.packedP0EffectsCount : config.packedP1EffectsCount;
        mapping(uint256 => EffectInstance) storage effects = targetIndex == 0 ? config.p0Effects : config.p1Effects;
        uint256 count = _getMonEffectCount(packedCounts, monIndex);
        uint256 baseSlot = _getEffectSlotIndex(monIndex, 0);
        uint256 newCount = count;
        while (newCount > 0 && address(effects[baseSlot + newCount - 1].effect) == TOMBSTONE_ADDRESS) {
            unchecked {
                --newCount;
            }
        }
        if (newCount != count) {
            if (targetIndex == 0) {
                config.packedP0EffectsCount = _setMonEffectCount(packedCounts, monIndex, newCount);
            } else {
                config.packedP1EffectsCount = _setMonEffectCount(packedCounts, monIndex, newCount);
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Inlined stat boosts
    //
    // Formerly the standalone `StatBoosts` effect contract. Boost sources live in their own
    // per-mon store — one packed word per source in p0/p1BoostWords, 4-bit counts in
    // p0/p1BoostCounts, aggregate recomputed from the words on every change — NOT in the effect mappings, so effect
    // passes never iterate them; Temp expiry is a direct _inlineStatBoostSwitchOut call in
    // _handleSwitch. Callers (moves, abilities, shared effects) invoke these directly during
    // execute, so the boost-source key is still derived from msg.sender exactly as it was when
    // StatBoosts saw the caller. The math lives in StatBoostLib; here we only touch storage and
    // fire the OnUpdateMonState pipeline via _updateMonStateInternal (matching the legacy path).
    // ---------------------------------------------------------------------------------------------

    /// @notice Apply a stat-boost source keyed by msg.sender (no salt). Merges into an existing
    ///         same-source/same-permanence entry if present.
    function addStatBoost(
        uint256 targetIndex,
        uint256 monIndex,
        StatBoostToApply[] calldata statBoostsToApply,
        StatBoostFlag boostFlag
    ) external {
        if (battleKeyForWrite == bytes32(0)) {
            revert NoWriteAllowed();
        }
        uint168 key = StatBoostLib.generateKeyNoSalt(targetIndex, monIndex, msg.sender);
        _addStatBoostWithKey(targetIndex, monIndex, statBoostsToApply, boostFlag == StatBoostFlag.Perm, key);
    }

    /// @notice Remove the msg.sender-keyed stat-boost source of the given permanence (if any) and
    ///         recompute the mon's boosted stats.
    function removeStatBoost(uint256 targetIndex, uint256 monIndex, StatBoostFlag boostFlag) external {
        if (battleKeyForWrite == bytes32(0)) {
            revert NoWriteAllowed();
        }
        uint168 key = StatBoostLib.generateKeyNoSalt(targetIndex, monIndex, msg.sender);
        _removeStatBoostWithKey(targetIndex, monIndex, key, boostFlag == StatBoostFlag.Perm);
    }

    /// @notice Remove every stat-boost source on a mon and reset its stats to base values.
    function clearAllStatBoosts(uint256 targetIndex, uint256 monIndex) external {
        if (battleKeyForWrite == bytes32(0)) {
            revert NoWriteAllowed();
        }
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        if (_boostCountOf(config, targetIndex, monIndex) == 0) {
            return;
        }
        _setBoostCountOf(config, targetIndex, monIndex, 0);

        // Telescope back to base stats.
        uint32[5] memory baseStats = _getStatBoostBaseStats(config, targetIndex, monIndex);
        _applyBoostedStats(config, targetIndex, monIndex, baseStats, baseStats);
    }

    function _getStatBoostBaseStats(BattleConfig storage config, uint256 targetIndex, uint256 monIndex)
        private
        view
        returns (uint32[5] memory stats)
    {
        MonStats storage monStats = _getTeamMon(config, targetIndex, monIndex).stats;
        stats[0] = monStats.attack;
        stats[1] = monStats.defense;
        stats[2] = monStats.specialAttack;
        stats[3] = monStats.specialDefense;
        stats[4] = monStats.speed;
    }

    // Boost-source store: one packed word per source at slot monIndex * 16 + i (i < the mon's
    // 4-bit count nibble). 15 sources/mon is far above the plausible distinct-caller ceiling.

    function _boostWordsOf(BattleConfig storage config, uint256 targetIndex)
        private
        view
        returns (mapping(uint256 => bytes32) storage)
    {
        return targetIndex == 0 ? config.p0BoostWords : config.p1BoostWords;
    }

    function _boostCountOf(BattleConfig storage config, uint256 targetIndex, uint256 monIndex)
        private
        view
        returns (uint256)
    {
        uint32 packed = targetIndex == 0 ? config.p0BoostCounts : config.p1BoostCounts;
        return (packed >> (monIndex * 4)) & 0xF;
    }

    function _setBoostCountOf(BattleConfig storage config, uint256 targetIndex, uint256 monIndex, uint256 newCount)
        private
    {
        uint256 shift = monIndex * 4;
        if (targetIndex == 0) {
            config.p0BoostCounts = uint32((config.p0BoostCounts & ~(uint256(0xF) << shift)) | (newCount << shift));
        } else {
            config.p1BoostCounts = uint32((config.p1BoostCounts & ~(uint256(0xF) << shift)) | (newCount << shift));
        }
    }

    function _addStatBoostWithKey(
        uint256 targetIndex,
        uint256 monIndex,
        StatBoostToApply[] calldata statBoostsToApply,
        bool isPerm,
        uint168 key
    ) private {
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        uint32[5] memory baseStats = _getStatBoostBaseStats(config, targetIndex, monIndex);
        mapping(uint256 => bytes32) storage words = _boostWordsOf(config, targetIndex);
        uint256 count = _boostCountOf(config, targetIndex, monIndex);
        uint256 baseSlot = monIndex * 16;

        // Find an existing same-key/same-permanence source (header-only reads — no lane unpack).
        bool found;
        uint256 foundIdx;
        bytes32 oldWord;
        for (uint256 i; i < count; ++i) {
            bytes32 w = words[baseSlot + i];
            (bool wPerm, uint168 wKey) = StatBoostLib.unpackBoostHeader(w);
            if (wKey == key && wPerm == isPerm) {
                found = true;
                foundIdx = i;
                oldWord = w;
                break;
            }
        }

        bytes32 newWord;
        if (found) {
            (,, uint8[5] memory ep, uint8[5] memory ec, bool[5] memory em) = StatBoostLib.unpackBoostData(oldWord);
            (uint8[5] memory fp, uint8[5] memory fc, bool[5] memory fm) =
                StatBoostLib.mergeExistingAndNewBoosts(ep, ec, em, statBoostsToApply);
            newWord = StatBoostLib.packBoostDataWithArrays(key, isPerm, fp, fc, fm);
            words[baseSlot + foundIdx] = newWord;
        } else {
            if (count == 15) {
                revert InvalidBattleConfig();
            }
            newWord = StatBoostLib.packBoostData(key, isPerm, statBoostsToApply);
            words[baseSlot + count] = newWord;
            _setBoostCountOf(config, targetIndex, monIndex, count + 1);
        }

        _applyStatBoostAggregates(config, targetIndex, monIndex, baseStats);
    }

    function _removeStatBoostWithKey(uint256 targetIndex, uint256 monIndex, uint168 key, bool isPerm) private {
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        mapping(uint256 => bytes32) storage words = _boostWordsOf(config, targetIndex);
        uint256 count = _boostCountOf(config, targetIndex, monIndex);
        uint256 baseSlot = monIndex * 16;

        for (uint256 i; i < count; ++i) {
            bytes32 w = words[baseSlot + i];
            (bool wPerm, uint168 wKey) = StatBoostLib.unpackBoostHeader(w);
            if (wKey != key || wPerm != isPerm) {
                continue;
            }
            // Swap-remove (aggregation is commutative; source order is meaningless).
            uint256 last = count - 1;
            if (i != last) {
                words[baseSlot + i] = words[baseSlot + last];
            }
            _setBoostCountOf(config, targetIndex, monIndex, last);

            _applyStatBoostAggregates(
                config, targetIndex, monIndex, _getStatBoostBaseStats(config, targetIndex, monIndex)
            );
            return;
        }
    }

    /// @dev Recompute the mon's aggregate from its source words (the add/remove scans have
    ///      already warmed them) and telescope the deltas. The packed accumulator is the exact
    ///      fast form of the legacy aggregation; on lane overflow the legacy unchecked math is
    ///      the fallback, so both branches agree with the old accumulator-cache results.
    function _applyStatBoostAggregates(
        BattleConfig storage config,
        uint256 targetIndex,
        uint256 monIndex,
        uint32[5] memory baseStats
    ) private {
        mapping(uint256 => bytes32) storage words = _boostWordsOf(config, targetIndex);
        uint256 count = _boostCountOf(config, targetIndex, monIndex);
        uint256 baseSlot = monIndex * 16;
        uint256 acc;
        bool ok = true;
        for (uint256 i; i < count && ok; ++i) {
            (acc, ok) = StatBoostLib.applyWordToAcc(acc, words[baseSlot + i], baseStats, true);
        }
        uint32[5] memory newBoostedStats;
        if (ok) {
            newBoostedStats = StatBoostLib.finalizeAccStats(acc, baseStats);
        } else {
            uint32[5] memory numBoostsPerStat;
            uint256[5] memory accumulatedNumeratorPerStat;
            for (uint256 i; i < count; ++i) {
                (,, uint8[5] memory bp, uint8[5] memory bc, bool[5] memory im) =
                    StatBoostLib.unpackBoostData(words[baseSlot + i]);
                StatBoostLib.accumulateBoosts(baseStats, bp, bc, im, numBoostsPerStat, accumulatedNumeratorPerStat);
            }
            newBoostedStats =
                StatBoostLib.finalizeBoostedStats(baseStats, numBoostsPerStat, accumulatedNumeratorPerStat);
        }
        _applyBoostedStats(config, targetIndex, monIndex, baseStats, newBoostedStats);
    }

    /// @dev Re-apply a mon's aggregated stat boosts by telescoping its monState deltas. The
    ///      stat-boost system is the sole writer of the 5 stat-delta fields, so the current delta
    ///      *is* the previous boost contribution (cleared == sentinel == 0): old boosted stat =
    ///      base + currentDelta. We compute the new boosted stat and feed the difference through
    ///      _updateMonStateInternal, which fires OnUpdateMonState for listeners exactly as before.
    ///      No globalKV snapshot is kept — being inside the Engine we read the delta back directly.
    function _applyBoostedStats(
        BattleConfig storage config,
        uint256 targetIndex,
        uint256 monIndex,
        uint32[5] memory baseStats,
        uint32[5] memory newBoostedStats
    ) private {
        MonState storage st = _getMonState(config, targetIndex, monIndex);

        // Listener gate hoisted ONCE per apply (was paid inside _updateMonStateInternal per stat).
        // OnUpdateMonState has a single listener game-wide, so the common case takes the direct-
        // write path: the stat-boost system is the sole writer of these 5 deltas (updateMonState
        // reverts StatRequiresStatBoost for them), so the stored delta after any telescoped op is
        // exactly newBoosted - base — writing that directly is bit-identical to the dispatcher's
        // sentinel-aware add, minus its 2 TLOADs + 2 mapping keccaks + enum chain per stat.
        if (_monListensAt(config, targetIndex, monIndex, EffectStep.OnUpdateMonState)) {
            for (uint256 i; i < 5; ++i) {
                // old boosted = base + current stat-boost delta (sentinel reads as 0 / "no boost")
                int32 valueToAdd = int32(newBoostedStats[i]) - int32(baseStats[i]) - _statBoostCurrentDelta(st, i);
                if (valueToAdd != 0) {
                    _updateMonStateInternal(
                        targetIndex, monIndex, StatBoostLib.statBoostIndexToMonStateIndex(i), valueToAdd
                    );
                }
            }
            return;
        }

        // Direct path: one read-modify-write of the packed MonState word for all five lanes.
        // Lane offsets follow the MonState layout (hp 0, stamina 32, speed 64, attack 96,
        // defence 128, spAtk 160, spDef 192); boost index 4 is speed, 0-3 map to attack..spDef.
        uint256 word;
        assembly ("memory-safe") {
            word := sload(st.slot)
        }
        uint256 original = word;
        bool speedChanged;
        for (uint256 i; i < 5; ++i) {
            uint256 shift = i == 4 ? 64 : 96 + (i << 5);
            int32 current = int32(uint32(word >> shift));
            if (current == CLEARED_MON_STATE_SENTINEL) {
                current = 0;
            }
            int32 newDelta = int32(newBoostedStats[i]) - int32(baseStats[i]);
            if (newDelta == current) {
                continue;
            }
            word = (word & ~(uint256(0xFFFFFFFF) << shift)) | (uint256(uint32(newDelta)) << shift);
            if (i == 4) {
                speedChanged = true;
            }
        }
        if (word != original) {
            assembly ("memory-safe") {
                sstore(st.slot, word)
            }
            if (speedChanged && config.battleMode != BATTLE_MODE_SINGLES) {
                _markActiveMonSpeedDirty(targetIndex, monIndex);
            }
        }
    }

    /// @dev Current stat-boost delta for boost-index i (0:atk,1:def,2:spatk,3:spdef,4:speed),
    ///      treating the cleared sentinel as 0.
    function _statBoostCurrentDelta(MonState storage st, uint256 i) private view returns (int32) {
        int32 d;
        if (i == 0) {
            d = st.attackDelta;
        } else if (i == 1) {
            d = st.defenceDelta;
        } else if (i == 2) {
            d = st.specialAttackDelta;
        } else if (i == 3) {
            d = st.specialDefenceDelta;
        } else {
            d = st.speedDelta;
        }
        return d == CLEARED_MON_STATE_SENTINEL ? int32(0) : d;
    }

    /// @dev Switch-out expiry: drop EVERY temp source on the mon in one pass (swap-compacting the
    ///      store) and apply the surviving aggregate once. Called directly from the switch path —
    ///      boost sources no longer live in the effect list, so no OnMonSwitchOut pass is involved.
    function _inlineStatBoostSwitchOut(BattleConfig storage config, uint256 targetIndex, uint256 monIndex) private {
        mapping(uint256 => bytes32) storage words = _boostWordsOf(config, targetIndex);
        uint256 count = _boostCountOf(config, targetIndex, monIndex);
        uint256 baseSlot = monIndex * 16;
        uint256 kept = count;
        uint256 i;
        while (i < kept) {
            bytes32 w = words[baseSlot + i];
            if (StatBoostLib.isPerm(w)) {
                ++i;
                continue;
            }
            --kept;
            if (i != kept) {
                words[baseSlot + i] = words[baseSlot + kept];
            }
        }
        if (kept == count) {
            return; // nothing expired: no writes, no telescope
        }
        _setBoostCountOf(config, targetIndex, monIndex, kept);
        _applyStatBoostAggregates(config, targetIndex, monIndex, _getStatBoostBaseStats(config, targetIndex, monIndex));
    }

    function setGlobalKV(uint64 key, uint192 value) external {
        if (battleKeyForWrite == bytes32(0)) {
            revert NoWriteAllowed();
        }
        _setGlobalKV(key, value);
    }

    /// @dev Internal globalKV writer (assumes caller has gated on battleKeyForWrite). Shared by the
    ///      external setGlobalKV and the inlined stat-boost snapshot path.
    function _setGlobalKV(uint64 key, uint192 value) private {
        bytes32 storageKey = storageKeyForWrite;
        BattleConfig storage config = battleConfig[storageKey];
        uint40 timestamp = config.startTimestamp;

        // "Never written in THIS battle" ⇔ stored timestamp ≠ current battle's timestamp.
        // Covers both first-ever write (packed == 0) and first-write after storageKey reuse.
        uint64 existingTs = uint64(uint256(globalKV[storageKey][key]) >> 192);
        if (existingTs != uint64(timestamp)) {
            uint256 idx = config.globalKVCount;
            uint256 slotIdx = idx >> 2;
            uint256 shift = (idx & 3) * 64;
            uint256 slot = globalKVKeySlots[storageKey][slotIdx];
            // Clear the lane, then write the new key into it.
            slot = (slot & ~(uint256(type(uint64).max) << shift)) | (uint256(key) << shift);
            globalKVKeySlots[storageKey][slotIdx] = slot;
            unchecked {
                config.globalKVCount = uint8(idx + 1);
            }
        }

        // Pack timestamp (upper 64 bits) with value (lower 192 bits)
        globalKV[storageKey][key] = bytes32((uint256(timestamp) << 192) | uint256(value));
    }

    /// @notice Check if the KO'd player's team is fully wiped and lock in the winner immediately
    /// @dev Called after each KO to ensure winner is determined by order of KOs, not bitmap check order
    function _checkAndSetWinnerIfGameOver(BattleConfig storage config, uint256 koPlayerIndex) internal {
        BattleData storage battle = battleData[battleKeyForWrite];

        // If winner already set, don't overwrite
        if (battle.winnerIndex != 2) {
            return;
        }

        // Check if KO'd player's team is fully wiped
        uint256 koBitmap = _getKOBitmap(config, koPlayerIndex);
        uint256 teamSize = (koPlayerIndex == 0) ? (config.teamSizes & 0x0F) : (config.teamSizes >> 4);
        uint256 fullMask = (1 << teamSize) - 1;

        if (koBitmap == fullMask) {
            // This player's team is fully wiped, other player wins
            battle.winnerIndex = uint8((koPlayerIndex + 1) % 2);
        }
    }

    function _dealDamageInternal(
        BattleConfig storage config,
        uint256 playerIndex,
        uint256 monIndex,
        int32 damage,
        uint256 source
    ) internal {
        // If game is already over, skip all damage
        BattleData storage battle = battleData[battleKeyForWrite];
        if (battle.winnerIndex != 2) {
            return;
        }

        MonState storage monState = _getMonState(config, playerIndex, monIndex);

        if (monState.isKnockedOut) {
            return;
        }

        // PreDamage pipeline: victim-side mon-local effects can mutate the in-flight damage by
        // calling engine.setPreDamage(). Reuses the standard _runEffects loop; running damage is
        // threaded through the transient `tempPreDamage` slot so the iteration logic doesn't change.
        // One exact per-mon lane read covers both gates, preventing another mon's listener from
        // routing this victim through a non-matching scan.
        uint16 monSteps = _monEffectSteps(config, playerIndex, monIndex);
        bool ranPreDamage;
        if ((monSteps & uint16(1 << uint8(EffectStep.PreDamage))) != 0) {
            tempPreDamage = damage;
            _runEffectsPipeline(config, playerIndex, monIndex, EffectStep.PreDamage, abi.encode(source));
            damage = tempPreDamage;
            tempPreDamage = 0;
            ranPreDamage = true;
        }
        if (damage <= 0) {
            return;
        }

        // If sentinel, replace with -damage; otherwise subtract damage. The damage formula clamps at
        // type(int32).max, so a large hit on an already-damaged mon can carry the delta past int32 —
        // a revert that would wedge the battle. Do the subtraction unchecked and detect the wrap:
        // damage is positive, so a result that did not decrease means it overflowed.
        int32 priorDelta = monState.hpDelta;
        int32 newDelta;
        unchecked {
            newDelta = (priorDelta == CLEARED_MON_STATE_SENTINEL) ? -damage : priorDelta - damage;
        }

        // Set KO flag if the total hpDelta is greater than the original mon HP
        uint32 baseHp = _getTeamMon(config, playerIndex, monIndex).stats.hp;
        if (priorDelta != CLEARED_MON_STATE_SENTINEL && newDelta > priorDelta) {
            newDelta = -int32(baseHp); // past fully-dead; the exact magnitude carries no meaning
        }
        monState.hpDelta = newDelta;
        if (monState.hpDelta + int32(baseHp) <= 0) {
            monState.isKnockedOut = true;
            _setMonKO(config, playerIndex, monIndex);
            koOccurredFlag = 1;

            // Lock in winner immediately if this KO ends the game
            _checkAndSetWinnerIfGameOver(config, playerIndex);
        }
        // AfterDamage gate. The mon lane is re-read ONLY when the PreDamage pipeline actually ran
        // (its effects may have added an AfterDamage listener mid-call); otherwise the shared
        // read above is still authoritative — nothing else can mutate it inside this function.
        if (ranPreDamage) {
            monSteps = _monEffectSteps(config, playerIndex, monIndex);
        }
        if ((monSteps & uint16(1 << uint8(EffectStep.AfterDamage))) != 0) {
            _runEffectsPipeline(config, playerIndex, monIndex, EffectStep.AfterDamage, abi.encode(damage, source));
        }
    }

    function dealDamage(uint256 playerIndex, uint256 monIndex, int32 damage) external {
        bytes32 battleKey = battleKeyForWrite;
        if (battleKey == bytes32(0)) {
            revert NoWriteAllowed();
        }
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        _dealDamageInternal(config, playerIndex, monIndex, damage, uint256(uint160(msg.sender)));
    }

    function setPreDamage(int32 value) external {
        if (battleKeyForWrite == bytes32(0)) {
            revert NoWriteAllowed();
        }
        tempPreDamage = value;
    }

    function _dispatchStandardAttackInternal(
        BattleConfig storage config,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 defenderPlayerIndex,
        uint256 defenderMonIndex,
        uint32 basePower,
        uint32 accuracy,
        uint32 volatility,
        Type moveType,
        MoveClass moveClass,
        uint256 critRate,
        uint8 effectAccuracy,
        IEffect effect,
        uint256 rng,
        uint256 source
    ) internal returns (int32 damage, bytes32 eventType) {
        if (basePower > 0) {
            // Fold attacker index into a single damage hash to break mirror symmetry; rolls read disjoint slices.
            uint256 h = AttackCalculator.mixRngForAttacker(rng, attackerPlayerIndex);

            // Accuracy check (only for damaging moves; status moves have no accuracy gate, matching the external path)
            if (accuracy < 100 && (uint64(h) % 100) >= accuracy) {
                return (0, MOVE_MISS_EVENT_TYPE);
            }

            // Build DamageCalcContext from internal storage (no external callback)
            DamageCalcContext memory ctx = _getDamageCalcContextInternal(
                config, attackerPlayerIndex, attackerMonIndex, defenderPlayerIndex, defenderMonIndex
            );

            // Type effectiveness via TypeCalcLib (internal pure, no external call). Reuse the defender
            // types already loaded into ctx instead of re-resolving the defender Mon from storage.
            uint32 scaledBasePower = TypeCalcLib.getTypeEffectiveness(moveType, ctx.defenderType1, basePower);
            if (ctx.defenderType2 != Type.None) {
                scaledBasePower = TypeCalcLib.getTypeEffectiveness(moveType, ctx.defenderType2, scaledBasePower);
            }

            // Shared damage formula (same function the external path uses)
            (damage, eventType) =
                AttackCalculator._calculateDamageCore(ctx, scaledBasePower, moveClass, volatility, h, critRate);

            if (damage > 0 && scaledBasePower > 0) {
                _dealDamageInternal(config, defenderPlayerIndex, defenderMonIndex, damage, source);
            }
        }

        // Effect gate: status move always eligible; damaging move only if it dealt damage.
        // Roll folds the attacker index (mirror desymmetry), independent of the damage-path rolls.
        if (
            address(effect) != address(0)
                && AttackCalculator.shouldApplyEffect(rng, attackerPlayerIndex, basePower, damage, effectAccuracy)
        ) {
            _addEffectInternal(defenderPlayerIndex, defenderMonIndex, effect, "");
        }
    }

    function _inlineStandardAttack(
        BattleConfig storage config,
        uint256 rawMoveSlot,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 defenderPlayerIndex,
        uint256 defenderMonIndex,
        uint256 rng
    ) internal {
        uint32 basePower = uint32((rawMoveSlot >> 248) & 0xFF);
        uint8 moveClassRaw = uint8((rawMoveSlot >> 246) & 0x3);
        uint8 moveTypeRaw = uint8((rawMoveSlot >> 240) & 0xF);
        uint8 effectAccuracy = uint8((rawMoveSlot >> 228) & 0xFF);
        address effectAddr = address(uint160(rawMoveSlot));

        _dispatchStandardAttackInternal(
            config,
            attackerPlayerIndex,
            attackerMonIndex,
            defenderPlayerIndex,
            defenderMonIndex,
            basePower,
            DEFAULT_ACCURACY,
            DEFAULT_VOL,
            Type(moveTypeRaw),
            MoveClass(moveClassRaw),
            DEFAULT_CRIT_RATE,
            effectAccuracy,
            IEffect(effectAddr),
            rng,
            rawMoveSlot
        );
    }

    function _executeResolvedMove(
        BattleConfig storage config,
        BattleData storage battle,
        uint256 rawMoveSlot,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint256 activesPacked,
        uint16 extraData,
        uint256 rng
    ) private {
        IMoveResolver resolver = IMoveResolver(address(uint160(rawMoveSlot)));
        (uint256 command, uint32 continuation) =
            resolver.resolveMove(0, 0, attackerPlayerIndex, attackerMonIndex, targetBits, activesPacked, extraData, rng);
        int32 result = _executeResolvedMoveCommand(
            config, battle, rawMoveSlot, attackerPlayerIndex, attackerMonIndex, targetBits, command, rng
        );
        if (continuation != 0) {
            (command,) = resolver.resolveMove(
                continuation, result, attackerPlayerIndex, attackerMonIndex, targetBits, activesPacked, extraData, rng
            );
            _executeResolvedMoveCommand(
                config, battle, rawMoveSlot, attackerPlayerIndex, attackerMonIndex, targetBits, command, rng
            );
        }
    }

    function _executeResolvedMoveCommand(
        BattleConfig storage config,
        BattleData storage battle,
        uint256 rawMoveSlot,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint256 command,
        uint256 rng
    ) private returns (int32 result) {
        uint256 op = uint8(command);
        if (op == MoveCommandLib.OP_ATTACK) {
            uint256 targetSlot = TargetLib.lowestSlot(targetBits);
            if (targetSlot == NO_SLOT) {
                return 0;
            }
            uint256 defenderMonIndex = _slotActive(battle, targetSlot);
            if (defenderMonIndex == EMPTY_ACTIVE_LANE) {
                return 0;
            }
            (result,) = _dispatchStandardAttackInternal(
                config,
                attackerPlayerIndex,
                attackerMonIndex,
                targetSlot >> 1,
                defenderMonIndex,
                uint32(command >> 8),
                uint8(command >> 40),
                uint8(command >> 48),
                Type(uint8(command >> 56)),
                MoveClass(uint8(command >> 64)),
                uint8(command >> 72),
                uint8(command >> 80),
                IEffect(address(uint160(command >> 88))),
                rng,
                uint256(uint160(rawMoveSlot))
            );
        } else if (op == MoveCommandLib.OP_SWITCH) {
            _switchActiveMonForSlotInternal(
                uint8(command >> 8), uint8(command >> 16), uint8(command >> 24), config, battle
            );
        }
    }

    function dispatchStandardAttack(
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint32 basePower,
        uint32 accuracy,
        uint32 volatility,
        Type moveType,
        MoveClass moveClass,
        uint256 critRate,
        uint8 effectAccuracy,
        IEffect effect,
        uint256 rng
    ) external returns (int32 damage, bytes32 eventType) {
        if (battleKeyForWrite == bytes32(0)) {
            revert NoWriteAllowed();
        }
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        BattleData storage battle = battleData[battleKeyForWrite];
        // Resolve the target slot to (side, active mon); empty targetBits = fizzled/malformed,
        // report a miss rather than resolving garbage. The attacker is the caller-supplied mon
        // (moves know their own identity) — never a lane read, which would alias slot-1/3
        // attackers onto their slot-0 ally.
        uint256 defSlot = TargetLib.lowestSlot(targetBits);
        if (defSlot == NO_SLOT) {
            return (0, MOVE_MISS_EVENT_TYPE);
        }
        uint256 defenderPlayerIndex = TargetLib.sideOf(defSlot);
        uint256 defenderMonIndex = (defSlot & 1) == 0
            ? _unpackActiveMonIndex(battle.activeMonIndex, defenderPlayerIndex)
            : uint256(uint8(battle.activeMonExt >> (defenderPlayerIndex << 3)));
        // Empty lane = self-constructed target on a vacant slot; miss rather than a phantom
        // mon-255 state write.
        if (defenderMonIndex == EMPTY_ACTIVE_LANE) {
            return (0, MOVE_MISS_EVENT_TYPE);
        }

        return _dispatchStandardAttackInternal(
            config,
            attackerPlayerIndex,
            attackerMonIndex,
            defenderPlayerIndex,
            defenderMonIndex,
            basePower,
            accuracy,
            volatility,
            moveType,
            moveClass,
            critRate,
            effectAccuracy,
            effect,
            rng,
            uint256(uint160(msg.sender))
        );
    }

    /// @notice One-call damage path for custom (Tier 3/4) move contracts. Collapses the old
    ///         AttackCalculator._calculateDamage dance — getDamageCalcContext staticcall + 1-2
    ///         calls to the DEPLOYED TypeCalculator (almost always cold in prod txs, since inline
    ///         attacks use the internal TypeCalcLib and nothing else warms that account) + a
    ///         dealDamage call — into one engine frame REUSING the same internals the inline
    ///         StandardAttack path runs (_getDamageCalcContextInternal / TypeCalcLib /
    ///         _calculateDamageCore / _dealDamageInternal).
    /// @dev Differs from dispatchStandardAttack only in its unconditional accuracy gate and applying
    ///      damage when `damage != 0`.
    function dispatchCustomAttack(
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint32 basePower,
        uint32 accuracy,
        uint256 volatility,
        Type moveType,
        MoveClass moveClass,
        uint256 rng,
        uint256 critRate
    ) external returns (int32 damage, bytes32 eventType) {
        if (battleKeyForWrite == bytes32(0)) {
            revert NoWriteAllowed();
        }
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        BattleData storage battle = battleData[battleKeyForWrite];
        // Same slot resolution + empty-target miss guards as dispatchStandardAttack; attacker is
        // caller-supplied, never a lane read.
        uint256 defSlot = TargetLib.lowestSlot(targetBits);
        if (defSlot == NO_SLOT) {
            return (0, MOVE_MISS_EVENT_TYPE);
        }
        uint256 defenderPlayerIndex = TargetLib.sideOf(defSlot);
        uint256 defenderMonIndex = (defSlot & 1) == 0
            ? _unpackActiveMonIndex(battle.activeMonIndex, defenderPlayerIndex)
            : uint256(uint8(battle.activeMonExt >> (defenderPlayerIndex << 3)));
        if (defenderMonIndex == EMPTY_ACTIVE_LANE) {
            return (0, MOVE_MISS_EVENT_TYPE);
        }

        // Fold attacker index into a single damage hash to break mirror symmetry; rolls read disjoint slices.
        uint256 h = AttackCalculator.mixRngForAttacker(rng, attackerPlayerIndex);

        if ((uint64(h) % 100) >= accuracy) {
            return (0, MOVE_MISS_EVENT_TYPE);
        }

        DamageCalcContext memory ctx = _getDamageCalcContextInternal(
            config, attackerPlayerIndex, attackerMonIndex, defenderPlayerIndex, defenderMonIndex
        );
        uint32 scaledBasePower = TypeCalcLib.getTypeEffectiveness(moveType, ctx.defenderType1, basePower);
        if (ctx.defenderType2 != Type.None) {
            scaledBasePower = TypeCalcLib.getTypeEffectiveness(moveType, ctx.defenderType2, scaledBasePower);
        }
        (damage, eventType) =
            AttackCalculator._calculateDamageCore(ctx, scaledBasePower, moveClass, volatility, h, critRate);
        if (damage != 0) {
            _dealDamageInternal(config, defenderPlayerIndex, defenderMonIndex, damage, uint256(uint160(msg.sender)));
        }
    }

    /// @notice Spread variant: honors `targetBits` as a full slot mask instead of collapsing it to the
    ///         lowest set bit, resolving the attacker's stats once for the whole sweep.
    /// @dev Purely additive — dispatchCustomAttack is untouched, so single-target callers are byte
    ///      identical. Every target rolls its own accuracy and damage variance. Empty lanes and KO'd
    ///      mons are skipped, and the sweep stops the moment a KO ends the battle. Returns summed
    ///      damage only: a single eventType is meaningless across several targets.
    function dispatchCustomAttackMulti(
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint32 basePower,
        uint32 accuracy,
        uint256 volatility,
        Type moveType,
        MoveClass moveClass,
        uint256 rng,
        uint256 critRate
    ) external returns (int32 totalDamage) {
        if (battleKeyForWrite == bytes32(0)) {
            revert NoWriteAllowed();
        }
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        BattleData storage battle = battleData[battleKeyForWrite];

        uint256 baseHash = AttackCalculator.mixRngForAttacker(rng, attackerPlayerIndex);
        uint256 source = uint256(uint160(msg.sender));
        DamageCalcContext memory ctx;
        bool ctxSeeded;

        // Mode-gated lanes, not raw _slotActive: singles leaves activeMonExt at 0, so odd slots
        // would resolve to "mon 0" and let a full mask hit a benched mon (or the active twice).
        uint256 actives = _hookActivesWord(battle);

        for (uint256 s; s < 4;) {
            if (targetBits & (1 << s) != 0) {
                uint256 defenderPlayerIndex = s >> 1;
                uint256 defenderMonIndex = TargetLib.activeAt(actives, s);
                if (
                    defenderMonIndex != EMPTY_ACTIVE_LANE
                        && !_getMonState(config, defenderPlayerIndex, defenderMonIndex).isKnockedOut
                ) {
                    // Per-slot hash, not a per-slot slice: _calculateDamageCore already consumes bits
                    // 64+ for volatility and crit, so slices would collide.
                    uint256 h = uint256(keccak256(abi.encode(baseHash, s)));
                    if ((uint64(h) % 100) < accuracy) {
                        if (ctxSeeded) {
                            _fillDefenderContext(ctx, config, defenderPlayerIndex, defenderMonIndex);
                        } else {
                            ctx = _getDamageCalcContextInternal(
                                config, attackerPlayerIndex, attackerMonIndex, defenderPlayerIndex, defenderMonIndex
                            );
                            ctxSeeded = true;
                        }

                        uint32 scaledBasePower =
                            TypeCalcLib.getTypeEffectiveness(moveType, ctx.defenderType1, basePower);
                        if (ctx.defenderType2 != Type.None) {
                            scaledBasePower =
                                TypeCalcLib.getTypeEffectiveness(moveType, ctx.defenderType2, scaledBasePower);
                        }
                        (int32 damage,) = AttackCalculator._calculateDamageCore(
                            ctx, scaledBasePower, moveClass, volatility, h, critRate
                        );
                        if (damage != 0) {
                            _dealDamageInternal(config, defenderPlayerIndex, defenderMonIndex, damage, source);
                            totalDamage += damage;
                            if (battle.winnerIndex != 2) {
                                return totalDamage;
                            }
                        }
                    }
                }
            }
            unchecked {
                ++s;
            }
        }
    }

    /// @notice Slot-addressed pivot for 2-slot battles (self-switch and force-out moves resolve
    ///         their slot via TargetLib.slotOfMon). Applies the same silent-no-op legality gates
    ///         as the scheduler's switch action; the end-of-turn flag recompute covers the rest.
    function switchActiveMonForSlot(uint256 playerIndex, uint256 slotIndex, uint256 monToSwitchIndex) external {
        bytes32 battleKey = battleKeyForWrite;
        if (battleKey == bytes32(0)) {
            revert NoWriteAllowed();
        }
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        BattleData storage battle = battleData[battleKey];
        _switchActiveMonForSlotInternal(playerIndex, slotIndex, monToSwitchIndex, config, battle);
    }

    function _switchActiveMonForSlotInternal(
        uint256 playerIndex,
        uint256 slotIndex,
        uint256 monToSwitchIndex,
        BattleConfig storage config,
        BattleData storage battle
    ) private {
        bytes32 battleKey = battleKeyForWrite;
        // Flow-aware like the other slot surfaces: singles routes through the legacy switch
        // (whose validation has no ally lane to collide with).
        if (!battle.isTwoSlotMode) {
            _switchActiveMonSingles(battleKey, config, battle, playerIndex, monToSwitchIndex);
            return;
        }
        uint256 absSlot = (playerIndex << 1) | (slotIndex & 1);
        uint256 currentActive = _slotActive(battle, absSlot);
        if (!_isLegalSlotSwitchTarget(config, battle, absSlot, monToSwitchIndex)) {
            return;
        }
        if (battle.turnId != 0 && monToSwitchIndex == currentActive) {
            return;
        }
        _handleSlotSwitch(battleKey, config, battle, absSlot, monToSwitchIndex, currentActive);
    }

    function switchActiveMon(uint256 playerIndex, uint256 monToSwitchIndex) external {
        bytes32 battleKey = battleKeyForWrite;
        if (battleKey == bytes32(0)) {
            revert NoWriteAllowed();
        }
        BattleData storage battle = battleData[battleKey];
        // 2-slot battles must address the vacating slot explicitly (switchActiveMonForSlot);
        // the singles-shaped call cannot say which slot leaves, so it no-ops like any other
        // invalid switch rather than corrupting a lane.
        if (battle.isTwoSlotMode) {
            return;
        }
        _switchActiveMonSingles(battleKey, battleConfig[storageKeyForWrite], battle, playerIndex, monToSwitchIndex);
    }

    function _switchActiveMonSingles(
        bytes32 battleKey,
        BattleConfig storage config,
        BattleData storage battle,
        uint256 playerIndex,
        uint256 monToSwitchIndex
    ) private {
        uint256 activeMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, playerIndex);

        bool isTargetKnockedOut = _getMonState(config, playerIndex, monToSwitchIndex).isKnockedOut;
        bool isValid = ValidatorLogic.validateSwitch(
            battle.turnId, activeMonIndex, monToSwitchIndex, isTargetKnockedOut, DEFAULT_MONS_PER_TEAM
        );
        if (isValid) {
            _handleSwitch(battleKey, config, battle, playerIndex, monToSwitchIndex, activeMonIndex);

            // Check for game over and/or KOs
            (uint256 playerSwitchForTurnFlag, bool isGameOver) = _checkForGameOverOrKO(config, battle, playerIndex);
            if (isGameOver) {
                return;
            }

            // Set the player switch for turn flag
            battle.playerSwitchForTurnFlag = uint8(playerSwitchForTurnFlag);

            // TODO:
            // Also upstreaming more updates from `_handleSwitch` and change it to also add `_handleEffects`
        }
        // If the switch is invalid, we simply do nothing and continue execution
    }

    /// @notice Internal helper to set a player's move
    /// @dev Shared by setMove() and executeWithMoves() to avoid duplication
    function _setMoveInternal(
        BattleConfig storage config,
        uint256 playerIndex,
        uint8 moveIndex,
        uint104 salt,
        uint16 extraData
    ) internal {
        // Pack moveIndex with isRealTurn bit and apply +1 offset for regular moves
        // Regular moves (< SWITCH_MOVE_INDEX) are stored as moveIndex + 1 to avoid zero ambiguity
        uint8 storedMoveIndex = moveIndex < SWITCH_MOVE_INDEX ? moveIndex + MOVE_INDEX_OFFSET : moveIndex;
        MoveDecision memory newMove =
            MoveDecision({packedMoveIndex: storedMoveIndex | IS_REAL_TURN_BIT, extraData: extraData});

        if (playerIndex == 0) {
            config.p0Move = newMove;
            config.p0Salt = salt;
        } else {
            config.p1Move = newMove;
            config.p1Salt = salt;
        }
    }

    function setMove(bytes32 battleKey, uint256 playerIndex, uint8 moveIndex, uint104 salt, uint16 extraData) external {
        bool isForCurrentBattle = battleKeyForWrite == battleKey;
        bytes32 storageKey = isForCurrentBattle ? storageKeyForWrite : _getStorageKey(battleKey);
        if (msg.sender != address(battleConfig[storageKey].moveManager) && !isForCurrentBattle) {
            revert NoWriteAllowed();
        }
        _setMoveViaFlow(battleKey, playerIndex, moveIndex, salt, extraData);
    }

    function _concatTeams(Mon[] memory a, Mon[] memory b) private pure returns (Mon[] memory out) {
        out = new Mon[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) {
            out[i] = a[i];
        }
        for (uint256 i; i < b.length; ++i) {
            out[a.length + i] = b[i];
        }
    }

    /// @notice Multi battle key: keccak over the four SORTED seats + the shared nonce mapping
    ///         (a 4-address preimage cannot collide with computeBattleKey's 2-address one — D33).
    ///         Reverts on duplicate seats (D21): sorting makes that an adjacent-equality check.
    function computePartyKey(address p0, address p1, address p2, address p3)
        public
        view
        returns (bytes32 battleKey, bytes32 partyHash)
    {
        address[4] memory seats = [p0, p1, p2, p3];
        for (uint256 i = 1; i < 4; ++i) {
            address key = seats[i];
            uint256 j = i;
            while (j > 0 && uint160(seats[j - 1]) > uint160(key)) {
                seats[j] = seats[j - 1];
                unchecked {
                    --j;
                }
            }
            seats[j] = key;
        }
        if (seats[0] == seats[1] || seats[1] == seats[2] || seats[2] == seats[3]) {
            revert InvalidBattleConfig();
        }
        partyHash = keccak256(abi.encode(seats[0], seats[1], seats[2], seats[3]));
        battleKey = keccak256(abi.encode(partyHash, pairHashNonces[partyHash]));
    }

    /// @notice Seats in canonical rotation order [p0, p2, p1, p3] (side-major; D18). p2/p3 are
    ///         zero outside Multi.
    function getSeats(bytes32 battleKey) external view returns (address[4] memory seats) {
        BattleData storage data = battleData[battleKey];
        MultiSeatData storage ms = multiSeats[battleKey];
        seats[0] = data.p0;
        seats[1] = ms.p2;
        seats[2] = data.p1;
        seats[3] = ms.p3;
    }

    function computeBattleKey(address p0, address p1) public view returns (bytes32 battleKey, bytes32 pairHash) {
        // Duplicate seats are never valid; a self-battle would double-settle rewards.
        if (p0 == p1) {
            revert InvalidBattleConfig();
        }
        // Order the pair first, hash once (was: hash then conditionally re-hash swapped).
        (address lo, address hi) = uint256(uint160(p0)) > uint256(uint160(p1)) ? (p1, p0) : (p0, p1);
        pairHash = keccak256(abi.encode(lo, hi));
        uint256 pairHashNonce = pairHashNonces[pairHash];
        battleKey = keccak256(abi.encode(pairHash, pairHashNonce));
    }

    /// @notice Check for game over and determine which player(s) need to switch next turn
    /// @dev Game-over detection is now handled immediately at KO time by _checkAndSetWinnerIfGameOver.
    ///      This function only checks if winner was already set, then handles switch flags for KO'd mons.
    function _checkForGameOverOrKO(BattleConfig storage config, BattleData storage battle, uint256 priorityPlayerIndex)
        internal
        view
        returns (uint256 playerSwitchForTurnFlag, bool isGameOver)
    {
        // Winner is set immediately in _dealDamageInternal when a KO results in game over
        if (battle.winnerIndex != 2) {
            return (playerSwitchForTurnFlag, true);
        }

        // Not a game over - check for KOs and set the player switch for turn flag
        playerSwitchForTurnFlag = 2;

        uint256 p0KOBitmap = _getKOBitmap(config, 0);
        uint256 p1KOBitmap = _getKOBitmap(config, 1);

        // Global effect context (priorityPlayerIndex == 2): check both players explicitly
        if (priorityPlayerIndex >= 2) {
            uint256 p0ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 0);
            uint256 p1ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 1);
            bool isP0KO = (p0KOBitmap & (1 << p0ActiveMonIndex)) != 0;
            bool isP1KO = (p1KOBitmap & (1 << p1ActiveMonIndex)) != 0;
            if (isP0KO && !isP1KO) {
                playerSwitchForTurnFlag = 0;
            } else if (!isP0KO && isP1KO) {
                playerSwitchForTurnFlag = 1;
            }
            return (playerSwitchForTurnFlag, false);
        }

        uint256 otherPlayerIndex = (priorityPlayerIndex + 1) % 2;
        uint256 priorityActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, priorityPlayerIndex);
        uint256 otherActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, otherPlayerIndex);
        uint256 priorityKOBitmap = priorityPlayerIndex == 0 ? p0KOBitmap : p1KOBitmap;
        uint256 otherKOBitmap = priorityPlayerIndex == 0 ? p1KOBitmap : p0KOBitmap;
        bool isPriorityPlayerActiveMonKnockedOut = (priorityKOBitmap & (1 << priorityActiveMonIndex)) != 0;
        bool isNonPriorityPlayerActiveMonKnockedOut = (otherKOBitmap & (1 << otherActiveMonIndex)) != 0;

        // If the priority player mon is KO'ed (and the other player isn't), next turn is just for that player to switch
        if (isPriorityPlayerActiveMonKnockedOut && !isNonPriorityPlayerActiveMonKnockedOut) {
            playerSwitchForTurnFlag = priorityPlayerIndex;
        }

        // If the non-priority player mon is KO'ed (and the other player isn't), next turn is just for that player to switch
        if (!isPriorityPlayerActiveMonKnockedOut && isNonPriorityPlayerActiveMonKnockedOut) {
            playerSwitchForTurnFlag = otherPlayerIndex;
        }
    }

    /// @dev `config`/`battle`/`currentActiveMonIndex` are threaded in from the caller (both call sites
    ///      already resolved them, and `battle.activeMonIndex` can't change between then and the switch
    ///      this function performs) so we don't re-resolve the mapping pointers or re-read the index here.
    function _handleSwitch(
        bytes32 battleKey,
        BattleConfig storage config,
        BattleData storage battle,
        uint256 playerIndex,
        uint256 monToSwitchIndex,
        uint256 currentActiveMonIndex
    ) internal {
        // NOTE: We will check for game over after the switch in the engine for two player turns, so we don't do it here
        // But this also means that the current flow of OnMonSwitchOut effects -> OnMonSwitchIn effects -> ability activateOnSwitch
        // will all resolve before checking for KOs or winners
        // (could break this up even more, but that's for a later version / PR)

        MonState storage currentMonState = _getMonState(config, playerIndex, currentActiveMonIndex);

        // If the current mon is not KO'ed
        // Go through each effect to see if it should be cleared after a switch,
        // If so, remove the effect and the extra data.
        // Guard each _runEffects so we don't pay its setup (storage re-resolution + count load) when
        // there's provably nothing to run: the switching mon has no effects (count == 0) or no effect
        // anywhere listens at this step (union bit clear), and the global list is empty.
        if (!currentMonState.isKnockedOut) {
            uint256 outCount = playerIndex == 0
                ? _getMonEffectCount(config.packedP0EffectsCount, currentActiveMonIndex)
                : _getMonEffectCount(config.packedP1EffectsCount, currentActiveMonIndex);
            if (outCount > 0 && _monListensAt(config, playerIndex, currentActiveMonIndex, EffectStep.OnMonSwitchOut)) {
                _runEffects(battleKey, tempRNG, playerIndex, playerIndex, EffectStep.OnMonSwitchOut, "", outCount);
            }

            // Temp stat-boost expiry, called directly (boost sources live in their own store, not
            // the effect list — mons with only boosts skip the whole OnMonSwitchOut pass above).
            // After the pass so switch-out effects observe the outgoing mon's boosted stats.
            if (_boostCountOf(config, playerIndex, currentActiveMonIndex) != 0) {
                _inlineStatBoostSwitchOut(config, playerIndex, currentActiveMonIndex);
            }

            // Then run the global on mon switch out hook as well
            if (config.globalEffectsLength > 0) {
                _runEffects(battleKey, tempRNG, 2, playerIndex, EffectStep.OnMonSwitchOut, "", type(uint256).max);
            }
        }

        // Update to new active mon (we assume validateSwitch already resolved and gives us a valid target)
        battle.activeMonIndex = _setActiveMonIndex(battle.activeMonIndex, playerIndex, monToSwitchIndex);

        // Run onMonSwitchIn hook for local effects (the new active mon is monToSwitchIndex)
        uint256 inCount = playerIndex == 0
            ? _getMonEffectCount(config.packedP0EffectsCount, monToSwitchIndex)
            : _getMonEffectCount(config.packedP1EffectsCount, monToSwitchIndex);
        if (inCount > 0 && _monListensAt(config, playerIndex, monToSwitchIndex, EffectStep.OnMonSwitchIn)) {
            _runEffects(battleKey, tempRNG, playerIndex, playerIndex, EffectStep.OnMonSwitchIn, "", inCount);
        }

        // Run onMonSwitchIn hook for global effects
        if (config.globalEffectsLength > 0) {
            _runEffects(battleKey, tempRNG, 2, playerIndex, EffectStep.OnMonSwitchIn, "", type(uint256).max);
        }

        // Run ability for the newly switched in mon as long as it's not KO'ed and as long as it's not turn 0, (execute() has a special case to run activateOnSwitch after both moves are handled)
        if (battle.turnId != 0 && !_getMonState(config, playerIndex, monToSwitchIndex).isKnockedOut) {
            _activateAbility(
                config,
                battleKey,
                _getTeamMon(config, playerIndex, monToSwitchIndex).ability,
                playerIndex,
                monToSwitchIndex
            );
        }
    }

    function _firstNonKOed(BattleConfig storage config, uint256 playerIndex) private view returns (uint256) {
        uint256 koBitmap = _getKOBitmap(config, playerIndex);
        uint256 teamSize = (playerIndex == 0) ? (config.teamSizes & 0x0F) : (config.teamSizes >> 4);
        for (uint256 i; i < teamSize; ++i) {
            if ((koBitmap & (1 << i)) == 0) {
                return i;
            }
        }
        return 0;
    }

    /// @dev Reads the current-turn move FRESH via _getCurrentTurnMove (rather than reusing the
    ///      _executeInternal top-of-turn p0TurnMove/p1TurnMove snapshot): effects like SleepStatus call
    ///      engine.setMove(...NO_OP...) to overwrite a victim's move mid-turn, so the move can change
    ///      after the snapshot and must be re-read here.
    function _handleMove(
        bytes32 battleKey,
        BattleConfig storage config,
        BattleData storage battle,
        uint256 playerIndex,
        uint256 prevPlayerSwitchForTurnFlag
    ) internal returns (uint256 playerSwitchForTurnFlag) {
        uint256 moveWord = _currentTurnMoveWord(config, playerIndex);
        uint16 extraData = uint16(moveWord >> 8);
        int32 staminaCost;
        playerSwitchForTurnFlag = prevPlayerSwitchForTurnFlag;

        // Unpack moveIndex from packedMoveIndex (lower 7 bits, with +1 offset for regular moves)
        uint8 storedMoveIndex = uint8(moveWord) & MOVE_INDEX_MASK;
        uint8 moveIndex = storedMoveIndex >= SWITCH_MOVE_INDEX ? storedMoveIndex : storedMoveIndex - MOVE_INDEX_OFFSET;

        // One slot-1 read serves every BattleData field below: nothing between here and the
        // move/switch dispatch can mutate the word (the stamina() probe is a staticcall).
        uint256 battleWord = _battleWord(battle);
        uint16 activesWord = uint16(battleWord >> 176);
        uint256 turnId = uint16(battleWord >> 232);

        // Handle shouldSkipTurn flag first and toggle it off if set
        uint256 activeMonIndex = _unpackActiveMonIndex(activesWord, playerIndex);
        MonState storage currentMonState = _getMonState(config, playerIndex, activeMonIndex);
        if (currentMonState.shouldSkipTurn) {
            currentMonState.shouldSkipTurn = false;
            // A forced-switch turn's coerced send-in is not an action the skip flag may eat.
            uint8 storedFlag = uint8(battleWord >> 168);
            if (storedFlag != 0 && storedFlag != 1) {
                return playerSwitchForTurnFlag;
            }
        }

        // If we've already determined next turn only one player has to move,
        // this implies the other player has to switch, so we can just short circuit here
        if (prevPlayerSwitchForTurnFlag == 0 || prevPlayerSwitchForTurnFlag == 1) {
            return playerSwitchForTurnFlag;
        }

        // Coerce to a switch when one is required: turn 0 (initial send-in) or active mon KO'd.
        // Target the first non-KO'd slot so the switch always lands
        if ((turnId == 0 || currentMonState.isKnockedOut) && moveIndex != SWITCH_MOVE_INDEX) {
            moveIndex = SWITCH_MOVE_INDEX;
            extraData = uint16(_firstNonKOed(config, playerIndex));
        }

        // Handle a switch, no-op, or regular move.
        // Note: MonMoves emission moved to the top of execute() so clients always learn
        // each player's submitted move + salt, regardless of any early return below.
        if (moveIndex == SWITCH_MOVE_INDEX) {
            // Validate switch target before mutating state. Each gate silently no-ops — an invalid
            // switch leaves the player stuck (same state machine as if they missed the timeout window).
            uint256 monToSwitchIndex = uint256(extraData & EXTRA_DATA_PAYLOAD_MASK);
            uint256 teamSize = (playerIndex == 0) ? (config.teamSizes & 0x0F) : (config.teamSizes >> 4);
            if (monToSwitchIndex >= teamSize) {
                return playerSwitchForTurnFlag;
            }
            if (_getMonState(config, playerIndex, monToSwitchIndex).isKnockedOut) {
                return playerSwitchForTurnFlag;
            }
            // Disallow switching to the same mon except on turn 0 (initial send-in allows both players to pick mon 0).
            if (turnId != 0 && monToSwitchIndex == activeMonIndex) {
                return playerSwitchForTurnFlag;
            }
            _handleSwitch(battleKey, config, battle, playerIndex, monToSwitchIndex, activeMonIndex);
        } else if (moveIndex == NO_OP_MOVE_INDEX) {
            // No-op: do nothing (e.g. just recover stamina)
        } else {
            // Lane-check the move index, then treat a zero lane as "no move here" — a silent skip,
            // same outcome as the old dynamic array's out-of-bounds guard (missing moves are now
            // zero-filled fixed lanes instead of out-of-bounds indices).
            StoredMon storage activeMon = _getTeamMon(config, playerIndex, activeMonIndex);
            if (moveIndex >= MOVE_LANES_PER_MON) {
                return playerSwitchForTurnFlag;
            }
            // Read raw 256-bit slot for this move
            uint256 rawMoveSlot = activeMon.moves[moveIndex];
            if (rawMoveSlot == 0) {
                return playerSwitchForTurnFlag;
            }

            if (rawMoveSlot & MOVE_META_TAG == 0 && rawMoveSlot >> 160 != 0) {
                // === INLINE PATH ===
                // Stamina from packed params
                uint8 staminaVal = uint8((rawMoveSlot >> 236) & 0xF);
                staminaCost = int32(uint32(staminaVal));

                // Validate stamina
                uint32 baseStamina = activeMon.stats.stamina;
                int32 staminaDelta = currentMonState.staminaDelta;
                int32 currentStamina = (staminaDelta == CLEARED_MON_STATE_SENTINEL)
                    ? int32(baseStamina)
                    : int32(baseStamina) + staminaDelta;
                if (currentStamina < staminaCost) {
                    return playerSwitchForTurnFlag;
                }

                // Deduct stamina and execute (MonMoves already emitted upfront in execute())
                _deductStamina(currentMonState, staminaCost);

                uint256 defenderMonIndex = _unpackActiveMonIndex(activesWord, 1 - playerIndex);
                _inlineStandardAttack(
                    config, rawMoveSlot, playerIndex, activeMonIndex, 1 - playerIndex, defenderMonIndex, tempRNG
                );
            } else {
                // === EXTERNAL PATH ===
                IEngine self = IEngine(address(this));
                IMoveSet moveSet = IMoveSet(address(uint160(rawMoveSlot)));

                // Re-validate stamina affordability at execution time
                {
                    uint32 baseStamina = activeMon.stats.stamina;
                    int32 staminaDelta = currentMonState.staminaDelta;
                    int256 effectiveDelta =
                        staminaDelta == CLEARED_MON_STATE_SENTINEL ? int256(0) : int256(staminaDelta);
                    uint256 currentStamina = uint256(int256(uint256(baseStamina)) + effectiveDelta);
                    // Packed metadata skips the staticcall; the 0xF sentinel calls live.
                    uint256 metaStamina = (rawMoveSlot >> 236) & 0xF;
                    uint32 moveStamina = (rawMoveSlot & MOVE_META_TAG != 0 && metaStamina != MOVE_META_DYNAMIC)
                        ? uint32(metaStamina)
                        : moveSet.stamina(self, battleKey, playerIndex, activeMonIndex);
                    if (moveStamina > currentStamina) {
                        return playerSwitchForTurnFlag;
                    }
                    staminaCost = int32(moveStamina);
                }
                _deductStamina(currentMonState, staminaCost);
                uint256 moveContext = TargetLib.singlesActives(uint8(activesWord), uint8(activesWord >> 8));
                if (rawMoveSlot & MOVE_CONTEXT_STATUS_LANES != 0) {
                    moveContext |= uint256(config.monStatusLanes) << 132;
                }
                uint256 targetBits = TargetLib.impliedSinglesTargetBits(playerIndex);
                if (rawMoveSlot & MOVE_RESOLVER_TAG != 0) {
                    _executeResolvedMove(
                        config,
                        battle,
                        rawMoveSlot,
                        playerIndex,
                        activeMonIndex,
                        targetBits,
                        moveContext,
                        extraData & EXTRA_DATA_PAYLOAD_MASK,
                        tempRNG
                    );
                } else {
                    moveSet.move(
                        self,
                        battleKey,
                        playerIndex,
                        activeMonIndex,
                        targetBits,
                        moveContext,
                        extraData & EXTRA_DATA_PAYLOAD_MASK,
                        tempRNG
                    );
                }
            }
        }

        // Only check for Game Over / KO if a KO occurred during the move
        if (koOccurredFlag != 0) {
            koOccurredFlag = 0;
            (playerSwitchForTurnFlag,) = _checkForGameOverOrKO(config, battle, playerIndex);
        }
        return playerSwitchForTurnFlag;
    }

    /**
     * effect index: the target index to filter effects for (0/1/2)
     * player index: the player to pass into the effects args
     */
    function _runEffects(
        bytes32 battleKey,
        uint256 rng,
        uint256 effectIndex,
        uint256 playerIndex,
        EffectStep round,
        bytes memory extraEffectsData,
        uint256 effectsCountHint
    ) internal {
        BattleData storage battle = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKeyForWrite];

        // Packed actives word (one 8-bit lane per absolute slot) passed to all effect hooks
        uint256 activesPacked = TargetLib.singlesActives(
            _unpackActiveMonIndex(battle.activeMonIndex, 0), _unpackActiveMonIndex(battle.activeMonIndex, 1)
        );

        uint256 monIndex = (playerIndex == 2) ? 0 : _unpackActiveMonIndex(battle.activeMonIndex, playerIndex);

        _runEffectsCore(
            config, rng, effectIndex, playerIndex, monIndex, round, extraEffectsData, effectsCountHint, activesPacked
        );
    }

    /// @dev The effect-iteration protocol shared by singles (_runEffects) and 2-slot
    ///      (_runEffectsForMon): dirty-count re-reads, tombstone skips, and the hoisted step
    ///      filter live ONLY here.
    function _runEffectsCore(
        BattleConfig storage config,
        uint256 rng,
        uint256 effectIndex,
        uint256 playerIndex,
        uint256 monIndex,
        EffectStep round,
        bytes memory extraEffectsData,
        uint256 effectsCountHint,
        uint256 activesPacked
    ) internal {
        // Pre-compute loop metadata once (baseSlot, dirtyBit)
        // Bit 0: global, Bits 1-8: P0 mons 0-7, Bits 9-16: P1 mons 0-7
        uint256 baseSlot;
        uint256 dirtyBit;
        if (effectIndex == 2) {
            dirtyBit = 1;
        } else if (effectIndex == 0) {
            baseSlot = _getEffectSlotIndex(monIndex, 0);
            dirtyBit = 1 << (1 + monIndex);
        } else {
            baseSlot = _getEffectSlotIndex(monIndex, 0);
            dirtyBit = 1 << (9 + monIndex);
        }

        // Callers whose resolved count is for THIS list (the active mon, or the global list) thread it
        // in to skip the initial read; everyone else passes the sentinel and we resolve it here. Note:
        // callers like updateMonState/dealDamage hold a count for a possibly-benched mon, so they MUST
        // pass the sentinel — the count below is always for `monIndex` (this player's active mon).
        uint256 effectsCount = effectsCountHint;
        if (effectsCount == type(uint256).max) {
            effectsCount = _loadEffectsCount(config, effectIndex, monIndex);
        }

        // Iterate directly over storage, skipping tombstones
        uint256 i = 0;
        while (i < effectsCount) {
            // Read effect directly from storage (mapping ref can't be pre-resolved across branches)
            EffectInstance storage eff;
            uint256 slotIndex = (effectIndex == 2) ? i : baseSlot + i;
            if (effectIndex == 2) {
                eff = config.globalEffects[slotIndex];
            } else if (effectIndex == 0) {
                eff = config.p0Effects[slotIndex];
            } else {
                eff = config.p1Effects[slotIndex];
            }

            // Skip tombstones AND entries that don't listen at this step before reading slot-1 data.
            if (address(eff.effect) != TOMBSTONE_ADDRESS && (eff.stepsBitmap & (1 << uint8(round))) != 0) {
                (bytes32 effectData, bool needsFreshContext, bool usesResolver) = _effectDataAndHookContext(eff);
                uint256 hookContext = activesPacked;
                if (needsFreshContext) {
                    if (round == EffectStep.RoundEnd) {
                        // Built immediately before this effect call, after every earlier effect in
                        // the same pass, so status mutations cannot stale the snapshot.
                        hookContext |= uint256(config.monStatusLanes) << 132;
                    } else if (round == EffectStep.AfterDamage) {
                        // Damage has landed and KO state is finalized. The loop already has the
                        // exact effect owner and config, so this needs no dispatch-time lookup.
                        if (_getMonState(config, playerIndex, monIndex).isKnockedOut) {
                            hookContext |= uint256(1) << 32;
                        }
                    } else if (round == EffectStep.PreDamage) {
                        // This transient is updated by every earlier PreDamage effect, so reading
                        // it here gives each callback the current composed signed damage value.
                        hookContext |= uint256(uint32(tempPreDamage)) << 32;
                    } else if (round == EffectStep.AfterMove || round == EffectStep.OnUpdateMonState) {
                        // These hook-specific builders need data resolved at dispatch time. Keep
                        // the request out of the public low-32 active lanes until then.
                        hookContext |= FRESH_HOOK_CONTEXT_REQUEST;
                    }
                }
                _runSingleEffect(
                    config,
                    rng,
                    effectIndex,
                    playerIndex,
                    monIndex,
                    round,
                    extraEffectsData,
                    eff.effect,
                    effectData,
                    uint96(slotIndex),
                    hookContext,
                    usesResolver
                );

                // Re-read count if a new effect was added during this iteration
                if (effectsDirtyBitmap & dirtyBit != 0) {
                    effectsCount = _loadEffectsCount(config, effectIndex, monIndex);
                    effectsDirtyBitmap &= ~dirtyBit;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    function _runSingleEffect(
        BattleConfig storage config,
        uint256 rng,
        uint256 effectIndex,
        uint256 playerIndex,
        uint256 monIndex,
        EffectStep round,
        bytes memory extraEffectsData,
        IEffect effect,
        bytes32 data,
        uint96 slotIndex,
        uint256 activesPacked,
        bool usesResolver
    ) private {
        // Run the effect and get result
        bytes32 updatedExtraData;
        bool removeAfterRun;
        if (round == EffectStep.AfterMove && usesResolver) {
            (updatedExtraData, removeAfterRun) =
                _executeResolvedEffect(effect, rng, data, playerIndex, monIndex, round, activesPacked);
        } else {
            (updatedExtraData, removeAfterRun) = _executeEffectHook(
                battleKeyForWrite, effect, rng, data, playerIndex, monIndex, round, extraEffectsData, activesPacked
            );
        }

        // If we need to remove or update the effect
        if (removeAfterRun || updatedExtraData != data) {
            _updateOrRemoveEffect(
                config, effectIndex, monIndex, effect, data, slotIndex, updatedExtraData, removeAfterRun
            );
        }
    }

    function _executeResolvedEffect(
        IEffect effect,
        uint256 rng,
        bytes32 data,
        uint256 playerIndex,
        uint256 monIndex,
        EffectStep round,
        uint256 activesPacked
    ) private returns (bytes32 updatedExtraData, bool removeAfterRun) {
        uint256 command;
        (updatedExtraData, removeAfterRun, command) = IEffectResolver(address(effect))
            .resolveEffect(round, rng, data, playerIndex, monIndex, _freshHookContext(round, activesPacked));
        _applyEffectCommand(command);
    }

    /// @dev Builds the dispatch-time portion shared by the legacy hook path and resolver prototype.
    function _freshHookContext(EffectStep round, uint256 activesPacked) private view returns (uint256) {
        if (activesPacked & FRESH_HOOK_CONTEXT_REQUEST == 0) {
            return activesPacked;
        }
        activesPacked &= ~FRESH_HOOK_CONTEXT_REQUEST;
        if (round == EffectStep.AfterMove) {
            BattleData storage battle = battleData[battleKeyForWrite];
            if (battle.isTwoSlotMode) {
                activesPacked |= _currentTurnMoveWordForSlot(0, 0) << 32;
                activesPacked |= _currentTurnMoveWordForSlot(0, 1) << 56;
                activesPacked |= _currentTurnMoveWordForSlot(1, 0) << 80;
                activesPacked |= _currentTurnMoveWordForSlot(1, 1) << 104;
            } else {
                BattleConfig storage config = battleConfig[storageKeyForWrite];
                activesPacked |= _currentTurnMoveWord(config, 0) << 32;
                activesPacked |= _currentTurnMoveWord(config, 1) << 80;
            }
            activesPacked |= actedSlotsThisTurnMask << 128;
        }
        return activesPacked;
    }

    function _applyEffectCommand(uint256 command) private {
        uint256 op = uint8(command);
        if (op == 0) {
            return;
        }
        uint256 targetIndex = uint8(command >> 8);
        uint256 monIndex = uint8(command >> 16);
        if (op == EffectCommandLib.OP_CLEAR_STATUS) {
            _clearMonStatus(targetIndex, monIndex, uint8(command >> 24));
        } else if (op == EffectCommandLib.OP_ADD_EFFECT) {
            _addEffectInternal(targetIndex, monIndex, IEffect(address(uint160(command >> 24))), bytes32(0));
        }
    }

    function _executeEffectHook(
        bytes32 battleKey,
        IEffect effect,
        uint256 rng,
        bytes32 data,
        uint256 playerIndex,
        uint256 monIndex,
        EffectStep round,
        bytes memory extraEffectsData,
        uint256 activesPacked
    ) private returns (bytes32 updatedExtraData, bool removeAfterRun) {
        IEngine self = IEngine(address(this));
        if (round == EffectStep.RoundStart) {
            return effect.onRoundStart(self, battleKey, rng, data, playerIndex, monIndex, activesPacked);
        } else if (round == EffectStep.RoundEnd) {
            return effect.onRoundEnd(self, battleKey, rng, data, playerIndex, monIndex, activesPacked);
        } else if (round == EffectStep.OnMonSwitchIn) {
            return effect.onMonSwitchIn(self, battleKey, rng, data, playerIndex, monIndex, activesPacked);
        } else if (round == EffectStep.OnMonSwitchOut) {
            return effect.onMonSwitchOut(self, battleKey, rng, data, playerIndex, monIndex, activesPacked);
        } else if (round == EffectStep.AfterDamage) {
            (int32 damage, uint256 source) = abi.decode(extraEffectsData, (int32, uint256));
            return
                effect.onAfterDamage(self, battleKey, rng, data, playerIndex, monIndex, activesPacked, damage, source);
        } else if (round == EffectStep.PreDamage) {
            uint256 source = abi.decode(extraEffectsData, (uint256));
            return effect.onPreDamage(self, battleKey, rng, data, playerIndex, monIndex, activesPacked, source);
        } else if (round == EffectStep.AfterMove) {
            // Enrich the existing active-lane word with a fresh current-turn snapshot immediately
            // before each callback. An earlier effect may rewrite a move, so this cannot be cached
            // once per pass. Low 32 bits remain the long-standing active-mon ABI; move lanes occupy
            // bits 32..127 and the acted-slot mask bits 128..131.
            if (activesPacked & FRESH_HOOK_CONTEXT_REQUEST != 0) {
                activesPacked &= ~FRESH_HOOK_CONTEXT_REQUEST;
                BattleData storage battle = battleData[battleKey];
                if (battle.isTwoSlotMode) {
                    activesPacked |= _currentTurnMoveWordForSlot(0, 0) << 32;
                    activesPacked |= _currentTurnMoveWordForSlot(0, 1) << 56;
                    activesPacked |= _currentTurnMoveWordForSlot(1, 0) << 80;
                    activesPacked |= _currentTurnMoveWordForSlot(1, 1) << 104;
                } else {
                    BattleConfig storage config = battleConfig[storageKeyForWrite];
                    activesPacked |= _currentTurnMoveWord(config, 0) << 32;
                    activesPacked |= _currentTurnMoveWord(config, 1) << 80;
                }
                activesPacked |= actedSlotsThisTurnMask << 128;
            }
            return effect.onAfterMove(self, battleKey, rng, data, playerIndex, monIndex, activesPacked);
        } else if (round == EffectStep.OnUpdateMonState) {
            (uint256 statePlayerIndex, uint256 stateMonIndex, MonStateIndexName stateVarIndex, int32 valueToAdd) =
                abi.decode(extraEffectsData, (uint256, uint256, MonStateIndexName, int32));
            // The state mutation has already landed before this lifecycle pass. Build the snapshot
            // immediately before each opted-in callback so it observes nested/prior hook writes.
            // Hook-specific context can reuse the AfterMove lanes: max HP is bits 32..63 and the
            // normalized signed HP delta is bits 64..95.
            if (activesPacked & FRESH_HOOK_CONTEXT_REQUEST != 0) {
                activesPacked &= ~FRESH_HOOK_CONTEXT_REQUEST;
                BattleConfig storage config = battleConfig[storageKeyForWrite];
                uint32 maxHp = _getTeamMon(config, statePlayerIndex, stateMonIndex).stats.hp;
                int32 hpDelta = _getMonState(config, statePlayerIndex, stateMonIndex).hpDelta;
                if (hpDelta == CLEARED_MON_STATE_SENTINEL) {
                    hpDelta = 0;
                }
                activesPacked |= uint256(maxHp) << 32;
                activesPacked |= uint256(uint32(hpDelta)) << 64;
            }
            return effect.onUpdateMonState(
                self, battleKey, rng, data, statePlayerIndex, stateMonIndex, activesPacked, stateVarIndex, valueToAdd
            );
        }
    }

    function _updateOrRemoveEffect(
        BattleConfig storage config,
        uint256 effectIndex,
        uint256 monIndex,
        IEffect, // effect - unused with tombstone approach
        bytes32, // originalData - unused with tombstone approach
        uint96 slotIndex,
        bytes32 updatedExtraData,
        bool removeAfterRun
    ) private {
        // With tombstones, indices are stable - use slot index directly for all effect types
        if (removeAfterRun) {
            removeEffect(effectIndex, monIndex, uint256(slotIndex));
        } else {
            // Update the data at the slot
            if (effectIndex == 2) {
                _setEffectData(config.globalEffects[slotIndex], updatedExtraData);
            } else if (effectIndex == 0) {
                _setEffectData(config.p0Effects[slotIndex], updatedExtraData);
            } else {
                _setEffectData(config.p1Effects[slotIndex], updatedExtraData);
            }
        }
    }

    function _handleEffects(
        BattleConfig storage config,
        BattleData storage battle,
        uint256 rng,
        uint256 effectIndex,
        uint256 playerIndex,
        EffectStep round,
        EffectRunCondition condition,
        uint256 prevPlayerSwitchForTurnFlag
    ) private returns (uint256 playerSwitchForTurnFlag) {
        // Check for Game Over and return early if so
        playerSwitchForTurnFlag = prevPlayerSwitchForTurnFlag;
        uint256 battleWord = _battleWord(battle);
        if (uint8(battleWord >> 160) != 2) {
            return playerSwitchForTurnFlag;
        }

        // The same slot-1 read feeds the mon index, the listener/KO gates and the hook context.
        uint256 activeWord = uint16(battleWord >> 176);
        uint256 monIndex = playerIndex == 2 ? 0 : _unpackActiveMonIndex(uint16(activeWord), playerIndex);
        uint256 effectsCount;
        if (effectIndex == 2) {
            effectsCount = config.globalEffectsLength;
        } else {
            // The battle-wide union is only the cheap outer gate. This exact mon lane prevents
            // one listener (including a benched mon's) from routing unrelated active lists.
            if (!_monListensAt(config, effectIndex, monIndex, round)) {
                return playerSwitchForTurnFlag;
            }

            // Check if mon is KOed (reuse monIndex we already computed)
            if (condition == EffectRunCondition.SkipIfGameOverOrMonKO) {
                if (_getMonState(config, playerIndex, monIndex).isKnockedOut) {
                    return playerSwitchForTurnFlag;
                }
            }

            // Check effect count for this mon
            effectsCount = (effectIndex == 0)
                ? _getMonEffectCount(config.packedP0EffectsCount, monIndex)
                : _getMonEffectCount(config.packedP1EffectsCount, monIndex);
        }

        if (effectsCount > 0) {
            _runEffectsCore(
                config,
                rng,
                effectIndex,
                playerIndex,
                monIndex,
                round,
                "",
                effectsCount,
                TargetLib.singlesActives(uint8(activeWord), uint8(activeWord >> 8))
            );
        }

        // Only check for Game Over / KO if a KO actually occurred since last check
        if (koOccurredFlag != 0) {
            koOccurredFlag = 0;
            (playerSwitchForTurnFlag,) = _checkForGameOverOrKO(config, battle, playerIndex);
        }
        return playerSwitchForTurnFlag;
    }

    /// @notice Per-slot "acted (or acting) this turn". Set at action start in both the singles
    ///         turn body and the 2-slot scheduler — the mode-agnostic primitive status effects
    ///         use to decide between an immediate move-cancel and waiting for next RoundStart.
    function hasSlotActedThisTurn(uint256 absSlot) external view returns (bool) {
        return (actedSlotsThisTurnMask >> absSlot) & 1 != 0;
    }

    /// @notice The roster range a slot may switch within (Multi: the seat's quarter) plus the
    ///         side's KO bitmap, so a switch-target search costs one call rather than one per
    ///         candidate. `koBitmap` is bit-per-roster-index and is kept in lockstep with each
    ///         mon's `isKnockedOut`.
    function getSlotSwitchWindow(bytes32 battleKey, uint256 playerIndex, uint256 slotIndex)
        external
        view
        returns (uint256 lo, uint256 hi, uint256 koBitmap)
    {
        BattleConfig storage config = battleConfig[_resolveStorageKey(battleKey)];
        (lo, hi) = _slotRosterBounds(config, (playerIndex << 1) | (slotIndex & 1));
        koBitmap = _getKOBitmap(config, playerIndex);
    }

    /// @dev Internal priority computation that accepts already-resolved storage pointers and
    ///      already-decoded current-turn moves. _executeInternal calls this to avoid re-resolving
    ///      the storage key, re-materializing storage refs, and re-reading both moves from
    ///      transient/storage via _getCurrentTurnMove.
    function _computePriorityPlayerIndex(
        BattleConfig storage config,
        BattleData storage battle,
        bytes32 battleKey,
        uint256 rng,
        uint256 p0TurnMove,
        uint256 p1TurnMove
    ) private view returns (uint256) {
        uint8 p0StoredIndex = uint8(p0TurnMove) & MOVE_INDEX_MASK;
        uint8 p1StoredIndex = uint8(p1TurnMove) & MOVE_INDEX_MASK;
        uint8 p0MoveIndex = p0StoredIndex >= SWITCH_MOVE_INDEX ? p0StoredIndex : p0StoredIndex - MOVE_INDEX_OFFSET;
        uint8 p1MoveIndex = p1StoredIndex >= SWITCH_MOVE_INDEX ? p1StoredIndex : p1StoredIndex - MOVE_INDEX_OFFSET;

        uint256 p0ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 0);
        uint256 p1ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 1);

        uint256 p0Priority = _getMovePriority(config, battleKey, 0, p0MoveIndex, p0ActiveMonIndex);
        uint256 p1Priority = _getMovePriority(config, battleKey, 1, p1MoveIndex, p1ActiveMonIndex);

        // Determine priority based on (in descending order of importance):
        // - the higher priority tier
        // - within same priority, the higher speed
        // - if both are tied, use the rng value
        if (p0Priority > p1Priority) {
            return 0;
        } else if (p0Priority < p1Priority) {
            return 1;
        }
        // Calculate speeds by combining base stats with deltas
        // Note: speedDelta may be sentinel value (CLEARED_MON_STATE_SENTINEL) which should be treated as 0
        int32 p0SpeedDelta = _getMonState(config, 0, p0ActiveMonIndex).speedDelta;
        int32 p1SpeedDelta = _getMonState(config, 1, p1ActiveMonIndex).speedDelta;
        uint32 p0MonSpeed = uint32(
            int32(_getTeamMon(config, 0, p0ActiveMonIndex).stats.speed)
                + (p0SpeedDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : p0SpeedDelta)
        );
        uint32 p1MonSpeed = uint32(
            int32(_getTeamMon(config, 1, p1ActiveMonIndex).stats.speed)
                + (p1SpeedDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : p1SpeedDelta)
        );
        if (p0MonSpeed > p1MonSpeed) {
            return 0;
        } else if (p0MonSpeed < p1MonSpeed) {
            return 1;
        }
        return rng % 2;
    }

    function _getMovePriority(
        BattleConfig storage config,
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 moveIndex,
        uint256 activeMonIndex
    ) private view returns (uint256) {
        if (moveIndex == SWITCH_MOVE_INDEX) {
            return SWITCH_PRIORITY;
        }
        // Resting orders on speed like any ordinary move.
        if (moveIndex == NO_OP_MOVE_INDEX) {
            return DEFAULT_PRIORITY;
        }
        // Out-of-lane moveIndex / zero lane = "no move here"; treat as the same priority as a
        // no-op so _handleMove can silently skip it later.
        StoredMon storage attackerMon = _getTeamMon(config, playerIndex, activeMonIndex);
        if (moveIndex >= MOVE_LANES_PER_MON) {
            return DEFAULT_PRIORITY;
        }
        uint256 raw = attackerMon.moves[moveIndex];
        if (raw == 0) {
            return DEFAULT_PRIORITY;
        }
        if (raw & MOVE_META_TAG != 0) {
            // Deployed move with packed metadata: absolute priority, 0xF = dynamic (call live).
            uint256 p = (raw >> 244) & 0xF;
            if (p != MOVE_META_DYNAMIC) {
                return p;
            }
        } else if (raw >> 160 != 0) {
            return DEFAULT_PRIORITY + ((raw >> 244) & 0x3);
        }
        return IMoveSet(address(uint160(raw))).priority(IEngine(address(this)), battleKey, playerIndex);
    }

    // =====================================================================================
    // 2-slot battles (Doubles; Multi layers seats onto this core)
    // -------------------------------------------------------------------------------------
    // Gated off _executeInternal by BattleConfig.battleMode. Slot-0 lanes live in
    // battle.activeMonIndex (byte-identical to singles); slot-1 lanes in battle.activeMonExt
    // (EMPTY_ACTIVE_LANE = no mon). Submissions are transient-only: per side one word packs
    // [salt: bits 0-103 | slot0 move: 104-127 | slot1 move: 128-151] (each move lane is the
    // singles 24-bit encoding: packedMoveIndex 8 + extraData 16).
    // Turn shape (D1/D27/D29): priorities lock at turn start from the committed moves; the
    // scheduler re-picks the next actor by current speed after every action; effect passes run
    // in current speed order; KOs never cancel the remaining actions (only game over does).
    // =====================================================================================

    /// @notice 2-slot moveManager entrypoint (mirrors executeWithMoves). Per-side wire word:
    ///         [slot0 move 8 | slot0 extraData 16 | slot1 move 8 | slot1 extraData 16 | salt 104].
    ///         Raw move indices; extraData carries the target nibble in its top 4 bits (D16).
    function executeWithSlotMoves(bytes32 battleKey, uint256 side0Packed, uint256 side1Packed)
        external
        returns (address winner)
    {
        bytes32 storageKey = _getStorageKey(battleKey);
        storageKeyForWrite = storageKey;
        battleKeyForWrite = battleKey;
        BattleConfig storage config = battleConfig[storageKey];
        if (msg.sender != config.moveManager) {
            revert WrongCaller();
        }
        _turnP0Packed = _packSideTurn(side0Packed);
        _turnP1Packed = _packSideTurn(side1Packed);
        winner = _executeInternal(battleKey, storageKey, false, true, true);
        emit EngineExecute(battleKey);
    }

    /// @dev Wire word -> transient word: apply MOVE_INDEX_OFFSET + IS_REAL_TURN_BIT per lane and
    ///      move the salt to the low bits. Both lanes are always encoded; non-acting lanes are
    ///      ignored by the flag mask, and exhausted slots are skipped by the engine regardless of
    ///      lane content (D6 — clients submit NO_OP filler there). Side salts are 80 bits so a
    ///      staged turn's two 128-bit wire words share one buffer slot.
    function _packSideTurn(uint256 sidePacked) private pure returns (uint256) {
        uint256 m0 = sidePacked & 0xFF;
        uint256 m1 = (sidePacked >> 24) & 0xFF;
        uint256 enc0 = ((m0 < SWITCH_MOVE_INDEX ? m0 + MOVE_INDEX_OFFSET : m0) | IS_REAL_TURN_BIT)
            | (((sidePacked >> 8) & 0xFFFF) << 8);
        uint256 enc1 = ((m1 < SWITCH_MOVE_INDEX ? m1 + MOVE_INDEX_OFFSET : m1) | IS_REAL_TURN_BIT)
            | (((sidePacked >> 32) & 0xFFFF) << 8);
        return ((sidePacked >> 48) & ((uint256(1) << 80) - 1)) | (enc0 << 104) | (enc1 << 128);
    }

    /// @notice One-tx PvE settlement for 2-slot battles: `entries` holds one (side0, side1)
    ///         wire-word pair per turn, executed in order until game over. Slot analog of
    ///         executeBatchedTurns — same manager gate and client-authored-CPU trust model. No
    ///         per-turn events; when the game concludes, the full replay ships in one
    ///         BattleCompleteWithBatchSlotTurns log.
    function executeBatchedSlotTurns(bytes32 battleKey, uint256[] calldata entries)
        external
        returns (uint64 executed, address winner)
    {
        bytes32 storageKey = _getStorageKey(battleKey);
        storageKeyForWrite = storageKey;
        battleKeyForWrite = battleKey;
        BattleConfig storage config = battleConfig[storageKey];
        if (msg.sender != config.moveManager) {
            revert WrongCaller();
        }
        if (entries.length & 1 != 0) {
            revert InvalidBattleConfig();
        }
        for (uint256 i = 0; i < entries.length; i += 2) {
            _turnP0Packed = _packSideTurn(entries[i]);
            _turnP1Packed = _packSideTurn(entries[i + 1]);
            winner = _executeInternal(battleKey, storageKey, false, false, true);
            executed++;
            if (winner != address(0)) {
                break;
            }
            // Between sub-turns only koOccurredFlag needs a reset (see _resetBatchedTurnTransients);
            // inlined copy for the same inliner reason as executeBatchedTurns (see _executeBatchedEntry).
            koOccurredFlag = 0;
        }
        if (winner != address(0)) {
            emit BattleCompleteWithBatchSlotTurns(battleKey, _packBatchSlotPayload(entries, executed, winner));
        }
    }

    /// @dev Packs the BattleCompleteWithBatchSlotTurns payload: [winner 20B | 25B/turn], each
    ///      turn = side-0 word low 152 bits + side-1 word low 48 bits (salt dropped — always 0
    ///      on the batched path). Same pre-sized single-buffer scheme as _packBatchPayload; the
    ///      final 6-byte-advance mstore writes 26 bytes past the end, hence the +26 slack.
    function _packBatchSlotPayload(uint256[] calldata entries, uint256 numTurns, address winner)
        private
        pure
        returns (bytes memory payload)
    {
        uint256 len = 20 + numTurns * 25;
        payload = new bytes(len + 26);
        assembly ("memory-safe") {
            let ptr := add(payload, 32)
            mstore(ptr, shl(96, winner)) // winner address in the leading 20 bytes
            ptr := add(ptr, 20)
            let src := entries.offset
            for { let i := 0 } lt(i, numTurns) { i := add(i, 1) } {
                mstore(ptr, shl(104, calldataload(add(src, mul(shl(1, i), 0x20)))))
                ptr := add(ptr, 19)
                mstore(ptr, shl(208, calldataload(add(src, add(mul(shl(1, i), 0x20), 0x20)))))
                ptr := add(ptr, 6)
            }
            mstore(payload, len) // drop the slack bytes from the visible length
        }
    }

    /// @notice Mid-execute per-slot move rewrite (e.g. sleep -> NO_OP), mode-agnostic: 2-slot
    ///         battles hit the slot's transient lane; singles routes through the setMove flow.
    function setMoveForSlot(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 slotIndex,
        uint8 moveIndex,
        uint16 extraData
    ) external {
        if (battleKeyForWrite != battleKey) {
            revert NoWriteAllowed();
        }
        if (!battleData[battleKey].isTwoSlotMode) {
            _setMoveViaFlow(battleKey, playerIndex, moveIndex, 0, extraData);
            return;
        }
        uint8 storedMoveIndex = moveIndex < SWITCH_MOVE_INDEX ? moveIndex + MOVE_INDEX_OFFSET : moveIndex;
        uint256 encoded = (uint256(storedMoveIndex) | uint256(IS_REAL_TURN_BIT)) | (uint256(extraData) << 8);
        uint256 shift = 104 + slotIndex * 24;
        if (playerIndex == 0) {
            _turnP0Packed = (_turnP0Packed & ~(uint256(0xFFFFFF) << shift)) | (encoded << shift);
        } else {
            _turnP1Packed = (_turnP1Packed & ~(uint256(0xFFFFFF) << shift)) | (encoded << shift);
        }
    }

    /// @dev The mid-execute half of setMove (transient when populated, storage otherwise).
    /// @dev The one transient-vs-storage routing for move writes: mid-execute the transient is
    ///      the source of truth (and needn't persist); across txs it auto-clears, so the write
    ///      must land in storage for execute() to mirror on entry.
    function _setMoveViaFlow(bytes32 battleKey, uint256 playerIndex, uint8 moveIndex, uint104 salt, uint16 extraData)
        private
    {
        bool isInsideExecute = _turnP0Packed != 0 || _turnP1Packed != 0;
        if (isInsideExecute) {
            uint8 storedMoveIndex = moveIndex < SWITCH_MOVE_INDEX ? moveIndex + MOVE_INDEX_OFFSET : moveIndex;
            uint256 encoded = (uint256(storedMoveIndex) | uint256(IS_REAL_TURN_BIT)) | (uint256(extraData) << 8);
            if (playerIndex == 0) {
                _turnP0Packed = _packTurn(encoded, salt);
            } else {
                _turnP1Packed = _packTurn(encoded, salt);
            }
        } else {
            _setMoveInternal(battleConfig[_resolveStorageKey(battleKey)], playerIndex, moveIndex, salt, extraData);
        }
    }

    /// @dev Current-turn move for (side, slotIndex). 2-slot flows are transient-only, so there
    ///      is no storage fallback; an unpopulated lane decodes to packedMoveIndex == 0.
    function _getCurrentTurnMoveForSlot(uint256 side, uint256 slotIndex) private view returns (MoveDecision memory) {
        return _decodeMove(_currentTurnMoveWordForSlot(side, slotIndex));
    }

    /// @dev Raw 24-bit move lane [extraData 16 | packedMoveIndex 8] — the allocation-free form
    ///      of _getCurrentTurnMoveForSlot for the per-turn hot paths.
    function _currentTurnMoveWordForSlot(uint256 side, uint256 slotIndex) private view returns (uint256) {
        uint256 packed = side == 0 ? _turnP0Packed : _turnP1Packed;
        return (packed >> (104 + slotIndex * 24)) & 0xFFFFFF;
    }

    /// @dev Active roster index of an absolute slot. Slot-0 lanes read the legacy field (so in
    ///      singles this is exactly _unpackActiveMonIndex); slot-1 lanes read activeMonExt.
    function _slotActive(BattleData storage battle, uint256 absSlot) private view returns (uint256) {
        uint256 side = absSlot >> 1;
        if (absSlot & 1 == 0) {
            return _unpackActiveMonIndex(battle.activeMonIndex, side);
        }
        return uint256(uint8(battle.activeMonExt >> (side << 3)));
    }

    function _setSlotActive(BattleData storage battle, uint256 absSlot, uint256 monIndex) private {
        uint256 side = absSlot >> 1;
        if (absSlot & 1 == 0) {
            battle.activeMonIndex = _setActiveMonIndex(battle.activeMonIndex, side, monIndex);
        } else {
            uint256 shift = side << 3;
            battle.activeMonExt =
                uint16((uint256(battle.activeMonExt) & ~(uint256(0xFF) << shift)) | (monIndex << shift));
        }
    }

    /// @dev Mark any active lane currently occupied by this mon. All authored speed changes route
    ///      through the Engine's stat-boost/state chokepoints before reaching this helper.
    function _markActiveMonSpeedDirty(uint256 side, uint256 monIndex) private {
        BattleData storage battle = battleData[battleKeyForWrite];
        uint256 slot = side << 1;
        uint256 dirty;
        if (_slotActive(battle, slot) == monIndex) {
            dirty = 1 << slot;
        }
        if (_slotActive(battle, slot + 1) == monIndex) {
            dirty |= 1 << (slot + 1);
        }
        if (dirty != 0) {
            _speedDirtySlots |= dirty;
        }
    }

    /// @dev The packed actives word passed to effects/moves: one 8-bit lane per absolute slot.
    ///      2-slot only — singles never writes activeMonExt, so its slot-1 lanes would read
    ///      0x00 ("mon 0") instead of EMPTY_ACTIVE_LANE; singles paths use TargetLib.singlesActives.
    function _buildActivesWord(BattleData storage battle) private view returns (uint256) {
        uint256 main = battle.activeMonIndex; // [side0 slot0 : 8 | side1 slot0 : 8]
        uint256 ext = battle.activeMonExt; // [side0 slot1 : 8 | side1 slot1 : 8]
        return (main & 0xFF) | ((ext & 0xFF) << 8) | ((main >> 8) << 16) | ((ext >> 8) << 24);
    }

    /// @dev Mode-gated actives word for the hook sites shared by both modes (onApply/onRemove).
    function _hookActivesWord(BattleData storage battle) private view returns (uint256) {
        if (battle.isTwoSlotMode) {
            return _buildActivesWord(battle);
        }
        return TargetLib.singlesActives(
            _unpackActiveMonIndex(battle.activeMonIndex, 0), _unpackActiveMonIndex(battle.activeMonIndex, 1)
        );
    }

    /// @dev The 2-slot turn body + the duplicated _executeInternal tail (round-end hooks,
    ///      game-over, turn advance). Transient-only flow: no MonMoves emit, no storage move
    ///      slots to clear.
    function _finishSlotTurn(
        bytes32 battleKey,
        BattleConfig storage config,
        BattleData storage battle,
        uint16 hookStepsUnion,
        bool emitBattleComplete
    ) private returns (address winner) {
        uint256 newFlag = _runSlotTurn(battleKey, config, battle);

        if ((hookStepsUnion & (1 << uint8(EngineHookStep.OnRoundEnd))) != 0) {
            uint256 numHooks = config.engineHooksLength;
            for (uint256 i = 0; i < numHooks;) {
                if ((config.engineHooks[i].stepsBitmap & (1 << uint8(EngineHookStep.OnRoundEnd))) != 0) {
                    config.engineHooks[i].hook.onRoundEnd(battleKey);
                }
                unchecked {
                    ++i;
                }
            }
        }

        if (battle.winnerIndex != 2) {
            winner = (battle.winnerIndex == 0) ? battle.p0 : battle.p1;
            _handleGameOver(battleKey, winner, emitBattleComplete);
            return winner;
        }

        _advanceTurn(battle, newFlag);
    }

    /// @dev End-of-turn BattleData update as ONE read-modify-write of slot 1. turnId,
    ///      playerSwitchForTurnFlag and lastExecuteTimestamp share the word, but via-IR emits a
    ///      separate SLOAD+SSTORE per field (measured), so the lanes are masked by hand here.
    ///      Layout: p0 [0..160) | winnerIndex [160..168) | playerSwitchForTurnFlag [168..176) |
    ///      activeMonIndex [176..192) | lastExecuteTimestamp [192..232) | turnId [232..248) |
    ///      numBuffered [248..256). Keep in sync with `forge inspect Engine storage-layout`.
    /// @dev Raw BattleData slot-1 word (layout in _advanceTurn). Hot paths load it once per
    ///      call-free window instead of one SLOAD per field.
    function _battleWord(BattleData storage battle) private view returns (uint256 word) {
        assembly ("memory-safe") {
            word := sload(add(battle.slot, 1))
        }
    }

    function _advanceTurn(BattleData storage battle, uint256 newFlag) private {
        uint256 word;
        assembly ("memory-safe") {
            word := sload(add(battle.slot, 1))
        }
        uint16 nextTurn = uint16(word >> 232) + 1; // checked, mirrors `turnId += 1`
        word = (word & ~((uint256(0xFF) << 168) | (uint256(0xFFFFFFFFFF) << 192) | (uint256(0xFFFF) << 232)))
            | (newFlag << 168) | (uint256(uint40(block.timestamp)) << 192) | (uint256(nextTurn) << 232);
        assembly ("memory-safe") {
            sstore(add(battle.slot, 1), word)
        }
    }

    function _runSlotTurn(bytes32 battleKey, BattleConfig storage config, BattleData storage battle)
        private
        returns (uint256)
    {
        uint256 flagIn = battle.playerSwitchForTurnFlag;

        // Forced-switch turn: only masked slots act (coerced switches), no round effects and no
        // regen — the 2-slot analog of the singles single-switch turn, uniform for 1-4 switchers
        // (D8 blind/simultaneous). Resolution runs in absolute-slot order; the mons being
        // replaced are KO'd, so speed-ordering the send-ins has no gameplay surface.
        if (flagIn != 2) {
            // No fresh turn rng on a forced-switch turn; zero it explicitly (batched sub-turns
            // no longer reset it between turns).
            tempRNG = 0;
            uint256 mask = flagIn & 0x0F;
            for (uint256 s; s < 4;) {
                if (mask & (1 << s) != 0) {
                    _handleSlotAction(battleKey, config, battle, s, true);
                    if (battle.winnerIndex != 2) {
                        return 2;
                    }
                }
                unchecked {
                    ++s;
                }
            }
            return _computeSlotEndFlag(config, battle);
        }

        // --- full turn ---
        uint256 rng;
        {
            uint104 s0 = uint104(_turnP0Packed);
            uint104 s1 = uint104(_turnP1Packed);
            rng = address(config.rngOracle) == address(0)
                ? uint256(keccak256(abi.encode(s0, s1)))
                : config.rngOracle.getRNG(bytes32(uint256(s0)), bytes32(uint256(s1)));
            tempRNG = rng;
        }

        bool turnZero = battle.turnId == 0;
        uint256 lockedPriorities = _lockSlotPriorities(battleKey, config, battle);
        uint8 inlineRegenFlags = config.inlineRegenFlags;

        // RoundStart: global pass, then per-slot lists in current speed order (D29).
        uint256 gLen = config.globalEffectsLength;
        if (gLen != 0) {
            _runEffectsForMon(config, battle, rng, 2, 2, 0, EffectStep.RoundStart, "", gLen);
            if (battle.winnerIndex != 2) {
                return 2;
            }
        }
        if ((config.playerEffectStepsUnion & uint16(1 << uint8(EffectStep.RoundStart))) != 0) {
            _runSlotEffectPass(battleKey, config, battle, rng, EffectStep.RoundStart);
            if (battle.winnerIndex != 2) {
                return 2;
            }
        }

        // Greedy dynamic scheduler (D1/D27): locked priority, live speed, fresh jitter per pick.
        uint256 actedMask;
        uint256 actionOrder;
        uint256 numActed;
        uint256 cachedSpeeds;
        // RoundStart mutations are captured by the first full load; only later mutations need
        // invalidation. Clear stale bits from a prior batched sub-turn here.
        _speedDirtySlots = 0;
        for (uint256 pick; pick < 4;) {
            uint256 slot;
            (slot, cachedSpeeds) =
                _pickNextSlot(config, battle, lockedPriorities, actedMask, rng, pick, turnZero, cachedSpeeds);
            if (slot == NO_SLOT) {
                break;
            }
            actedMask |= (1 << slot);
            actedSlotsThisTurnMask = actedMask;
            actionOrder |= slot << (numActed << 3);
            unchecked {
                ++numActed;
            }
            _handleSlotAction(battleKey, config, battle, slot, false);
            if (battle.winnerIndex != 2) {
                return 2;
            }

            // Actor AfterMove effects (own list if alive, then globals) + rest regen (D6: an
            // exhausted/KO'd actor was skipped above and earns nothing here either).
            uint256 side = slot >> 1;
            uint256 actorMon = _slotActive(battle, slot);
            bool actorAlive = actorMon != EMPTY_ACTIVE_LANE && !_getMonState(config, side, actorMon).isKnockedOut;
            if (actorAlive && _monListensAt(config, side, actorMon, EffectStep.AfterMove)) {
                uint256 cnt = side == 0
                    ? _getMonEffectCount(config.packedP0EffectsCount, actorMon)
                    : _getMonEffectCount(config.packedP1EffectsCount, actorMon);
                if (cnt > 0) {
                    _runEffectsForMon(config, battle, rng, side, side, actorMon, EffectStep.AfterMove, "", cnt);
                }
            }
            gLen = config.globalEffectsLength;
            if (gLen != 0) {
                _runEffectsForMon(config, battle, rng, 2, side, actorMon, EffectStep.AfterMove, "", gLen);
            }
            if (battle.winnerIndex != 2) {
                return 2;
            }
            if (inlineRegenFlags & INLINE_REGEN_REST != 0 && actorAlive) {
                if (StaminaRegenLogic._isRestingMove(uint8(_currentTurnMoveWordForSlot(side, slot & 1)))) {
                    // Re-read the lane: an AfterMove effect may have swapped the rester out, and
                    // the regen follows the lane (matching the singles regen's fresh read).
                    _inlineRegenStaminaForMon(config, side, _slotActive(battle, slot));
                }
            }
            unchecked {
                ++pick;
            }
        }

        // Turn-0: abilities activate only after every lead is in, in action order.
        if (turnZero) {
            for (uint256 k; k < numActed;) {
                uint256 s = (actionOrder >> (k << 3)) & 0xFF;
                uint256 side = s >> 1;
                uint256 mon = _slotActive(battle, s);
                if (mon != EMPTY_ACTIVE_LANE && !_getMonState(config, side, mon).isKnockedOut) {
                    _activateAbility(config, battleKey, _getTeamMon(config, side, mon).ability, side, mon);
                }
                unchecked {
                    ++k;
                }
            }
            if (battle.winnerIndex != 2) {
                return 2;
            }
        }

        // RoundEnd: global pass, per-slot lists in re-evaluated speed order (D29), then regen
        // for every live active.
        gLen = config.globalEffectsLength;
        if (gLen != 0) {
            _runEffectsForMon(config, battle, rng, 2, 2, 0, EffectStep.RoundEnd, "", gLen);
            if (battle.winnerIndex != 2) {
                return 2;
            }
        }
        if ((config.playerEffectStepsUnion & uint16(1 << uint8(EffectStep.RoundEnd))) != 0) {
            _runSlotEffectPass(battleKey, config, battle, rng, EffectStep.RoundEnd);
            if (battle.winnerIndex != 2) {
                return 2;
            }
        }
        if (inlineRegenFlags & INLINE_REGEN_ROUND_END != 0) {
            for (uint256 s; s < 4;) {
                uint256 mon = _slotActive(battle, s);
                if (mon != EMPTY_ACTIVE_LANE && !_getMonState(config, s >> 1, mon).isKnockedOut) {
                    _inlineRegenStaminaForMon(config, s >> 1, mon);
                }
                unchecked {
                    ++s;
                }
            }
        }

        return _computeSlotEndFlag(config, battle);
    }

    /// @dev Locks each slot's action priority from its committed move (D27). Speed is NOT read
    ///      here — the scheduler re-reads it at every pick. Empty lanes (turn-0 send-ins) lock
    ///      SWITCH_PRIORITY. Mirrors the singles quirk of pricing the SUBMITTED move even when
    ///      execution later coerces it to a switch.
    function _lockSlotPriorities(bytes32 battleKey, BattleConfig storage config, BattleData storage battle)
        private
        view
        returns (uint256 locked)
    {
        for (uint256 s; s < 4;) {
            uint256 side = s >> 1;
            uint256 mon = _slotActive(battle, s);
            uint256 prio;
            if (mon == EMPTY_ACTIVE_LANE) {
                prio = SWITCH_PRIORITY;
            } else {
                uint8 stored = uint8(_currentTurnMoveWordForSlot(side, s & 1)) & MOVE_INDEX_MASK;
                uint8 moveIndex = stored == 0
                    ? NO_OP_MOVE_INDEX
                    : (stored >= SWITCH_MOVE_INDEX ? stored : stored - MOVE_INDEX_OFFSET);
                prio = _getMovePriority(config, battleKey, side, moveIndex, mon);
            }
            locked |= prio << (s << 5);
            unchecked {
                ++s;
            }
        }
    }

    /// @dev Greedy pick: the un-acted live slot with the highest (locked priority, current
    ///      speed, per-pick jitter). Returns NO_SLOT when no candidate remains. Empty lanes only
    ///      participate on turn 0 (send-ins, speed 0); KO'd actives never act (D7).
    function _pickNextSlot(
        BattleConfig storage config,
        BattleData storage battle,
        uint256 lockedPriorities,
        uint256 actedMask,
        uint256 rng,
        uint256 pick,
        bool turnZero,
        uint256 cachedSpeeds
    ) private returns (uint256 best, uint256 newSpeeds) {
        best = NO_SLOT;
        newSpeeds = cachedSpeeds;
        uint256 bestPrio;
        uint256 bestSpeed;
        uint256 bestJitter;
        uint256 dirtyMask;
        if (pick == 0) {
            dirtyMask = 0xF;
        } else {
            dirtyMask = _speedDirtySlots;
            if (dirtyMask != 0) {
                _speedDirtySlots = 0;
            }
        }
        uint256 koBitmaps = config.koBitmaps;
        uint256 h = uint256(keccak256(abi.encode(rng, pick)));
        for (uint256 s; s < 4;) {
            if (actedMask & (1 << s) == 0) {
                uint256 mon = _slotActive(battle, s);
                bool candidate;
                uint256 speed;
                if (mon == EMPTY_ACTIVE_LANE) {
                    candidate = turnZero;
                } else {
                    uint256 side = s >> 1;
                    if ((koBitmaps & (1 << ((side << 3) | mon))) == 0) {
                        candidate = true;
                        uint256 shift = s << 6;
                        if (dirtyMask & (1 << s) != 0) {
                            int32 spdDelta = _getMonState(config, side, mon).speedDelta;
                            int256 spd = int256(uint256(_getTeamMon(config, side, mon).stats.speed))
                                + (spdDelta == CLEARED_MON_STATE_SENTINEL ? int256(0) : int256(spdDelta));
                            speed = spd > 0 ? uint256(spd) : 0;
                            newSpeeds = (newSpeeds & ~(uint256(type(uint64).max) << shift)) | (speed << shift);
                        } else {
                            speed = uint64(newSpeeds >> shift);
                        }
                    }
                }
                if (candidate) {
                    uint256 prio = (lockedPriorities >> (s << 5)) & 0xFFFFFFFF;
                    // 64-bit jitter lanes: wide enough that exact ties (which would favor the
                    // lower slot) effectively never happen.
                    uint256 jitter = uint64(h >> (s << 6));
                    if (
                        best == NO_SLOT || prio > bestPrio
                            || (prio == bestPrio && (speed > bestSpeed || (speed == bestSpeed && jitter > bestJitter)))
                    ) {
                        best = s;
                        bestPrio = prio;
                        bestSpeed = speed;
                        bestJitter = jitter;
                    }
                }
            }
            unchecked {
                ++s;
            }
        }
    }

    /// @dev Effect-pass picker with the same rank-dependent jitter as `_pickNextSlot`, but it
    ///      reads each remaining slot's live speed only once while advancing over consecutive
    ///      non-listeners. The caller invokes it again after every listener runs, preserving D29:
    ///      effects may change speed, KO a mon, or replace an active before the next hook.
    function _pickNextEffectSlot(
        BattleConfig storage config,
        BattleData storage battle,
        uint256 stepsWord,
        uint256 doneMask,
        uint256 rng,
        uint256 pickBase,
        uint256 pick,
        EffectStep step
    ) private view returns (uint256 slot, uint256 newDoneMask, uint256 nextPick) {
        uint256 candidateMask;
        uint256 listenerMask;
        uint256 speeds;
        for (uint256 s; s < 4;) {
            if (doneMask & (1 << s) == 0) {
                uint256 side = s >> 1;
                uint256 mon = _slotActive(battle, s);
                if (mon != EMPTY_ACTIVE_LANE) {
                    MonState storage st = _getMonState(config, side, mon);
                    if (!st.isKnockedOut) {
                        candidateMask |= 1 << s;
                        int32 spdDelta = st.speedDelta;
                        int256 spd = int256(uint256(_getTeamMon(config, side, mon).stats.speed))
                            + (spdDelta == CLEARED_MON_STATE_SENTINEL ? int256(0) : int256(spdDelta));
                        if (spd > 0) {
                            speeds |= uint256(spd) << (s << 6);
                        }
                        if (_stepsWordListens(stepsWord, side, mon, step)) {
                            listenerMask |= 1 << s;
                        }
                    }
                }
            }
            unchecked {
                ++s;
            }
        }

        newDoneMask = doneMask;
        nextPick = pick;
        while (nextPick < 4 && candidateMask != 0) {
            uint256 best = NO_SLOT;
            uint256 bestSpeed;
            uint256 bestJitter;
            uint256 h = uint256(keccak256(abi.encode(rng, pickBase + nextPick)));
            for (uint256 s; s < 4;) {
                if (candidateMask & (1 << s) != 0) {
                    uint256 speed = uint64(speeds >> (s << 6));
                    uint256 jitter = uint64(h >> (s << 6));
                    if (best == NO_SLOT || speed > bestSpeed || (speed == bestSpeed && jitter > bestJitter)) {
                        best = s;
                        bestSpeed = speed;
                        bestJitter = jitter;
                    }
                }
                unchecked {
                    ++s;
                }
            }
            uint256 bit = 1 << best;
            candidateMask &= ~bit;
            newDoneMask |= bit;
            unchecked {
                ++nextPick;
            }
            if (listenerMask & bit != 0) {
                return (best, newDoneMask, nextPick);
            }
        }
        return (NO_SLOT, newDoneMask, nextPick);
    }

    /// @dev Resolve one slot's action: coercion (turn-0 / KO'd -> switch), switch legality
    ///      (bounds, KO'd target, ally-slot collision), NO_OP, or move execution with the
    ///      engine-level fizzle rule (D2: stamina spent, dead/empty chosen target skips the move).
    function _handleSlotAction(
        bytes32 battleKey,
        BattleConfig storage config,
        BattleData storage battle,
        uint256 absSlot,
        bool isForcedSwitchTurn
    ) private {
        uint256 side = absSlot >> 1;
        uint256 moveWord = _currentTurnMoveWordForSlot(side, absSlot & 1);
        uint256 moveExtra = moveWord >> 8;
        uint8 stored = uint8(moveWord) & MOVE_INDEX_MASK;
        if (stored == 0) {
            return; // lane not populated
        }
        uint8 moveIndex = stored >= SWITCH_MOVE_INDEX ? stored : stored - MOVE_INDEX_OFFSET;
        uint256 activeMon = _slotActive(battle, absSlot);

        if (activeMon == EMPTY_ACTIVE_LANE) {
            // Empty lane acts only as a turn-0 send-in.
            if (battle.turnId != 0) {
                return;
            }
            moveIndex = SWITCH_MOVE_INDEX;
        } else {
            MonState storage currentMonState = _getMonState(config, side, activeMon);
            if (currentMonState.shouldSkipTurn) {
                currentMonState.shouldSkipTurn = false;
                // A coerced send-in is not an action the skip flag may eat: clear it (it would
                // otherwise linger on the KO'd mon) but let the forced switch proceed.
                if (!isForcedSwitchTurn) {
                    return;
                }
            }
            // D6/D7: on a full turn a KO'd active (exhausted slot or mid-turn casualty) loses
            // its action outright — no stamina, no rest, nothing.
            if (!isForcedSwitchTurn && currentMonState.isKnockedOut) {
                return;
            }
            if ((battle.turnId == 0 || currentMonState.isKnockedOut) && moveIndex != SWITCH_MOVE_INDEX) {
                moveIndex = SWITCH_MOVE_INDEX;
                (uint256 coerced,) = _firstLegalSwitchTarget(config, battle, absSlot);
                moveExtra = coerced;
            }
        }

        if (moveIndex == SWITCH_MOVE_INDEX) {
            uint256 monToSwitchIndex = moveExtra & EXTRA_DATA_PAYLOAD_MASK;
            // A lane that MUST fill — a turn-0 send-in, or a KO'd active on its forced-switch
            // turn — can't be left vacant by an illegal pick: a colliding switch would re-mask
            // the lane every turn (an infinite-stall vector). Coerce to the first legal target;
            // a genuinely empty bench (one survivor) finds none and falls to the no-op guard.
            bool laneMustFill = activeMon == EMPTY_ACTIVE_LANE || _getMonState(config, side, activeMon).isKnockedOut;
            if (laneMustFill && !_isLegalSlotSwitchTarget(config, battle, absSlot, monToSwitchIndex)) {
                (monToSwitchIndex,) = _firstLegalSwitchTarget(config, battle, absSlot);
            }
            if (!_isLegalSlotSwitchTarget(config, battle, absSlot, monToSwitchIndex)) {
                return;
            }
            if (battle.turnId != 0 && monToSwitchIndex == activeMon) {
                return;
            }
            _handleSlotSwitch(battleKey, config, battle, absSlot, monToSwitchIndex, activeMon);
        } else if (moveIndex == NO_OP_MOVE_INDEX) {
            // Rest — the AfterMove regen pass handles the stamina tick.
        } else {
            StoredMon storage attackerMon = _getTeamMon(config, side, activeMon);
            if (moveIndex >= MOVE_LANES_PER_MON) {
                return;
            }
            uint256 rawMoveSlot = attackerMon.moves[moveIndex];
            if (rawMoveSlot == 0) {
                return;
            }

            bool hasMetaTag = rawMoveSlot & MOVE_META_TAG != 0;
            bool isInlineAttack = !hasMetaTag && rawMoveSlot >> 160 != 0;

            // Stamina gate first (unaffordable = silent skip, nothing spent — singles rule).
            // Inline and tagged words share the stamina nibble; the 0xF sentinel calls live.
            MonState storage st = _getMonState(config, side, activeMon);
            int32 staminaCost;
            uint256 metaStamina = (rawMoveSlot >> 236) & 0xF;
            if (isInlineAttack || (hasMetaTag && metaStamina != MOVE_META_DYNAMIC)) {
                staminaCost = int32(uint32(metaStamina));
            } else {
                staminaCost = int32(
                    IMoveSet(address(uint160(rawMoveSlot))).stamina(IEngine(address(this)), battleKey, side, activeMon)
                );
            }
            {
                int32 staminaDelta = st.staminaDelta;
                int32 currentStamina = (staminaDelta == CLEARED_MON_STATE_SENTINEL)
                    ? int32(attackerMon.stats.stamina)
                    : int32(attackerMon.stats.stamina) + staminaDelta;
                if (currentStamina < staminaCost) {
                    return;
                }
            }
            _deductStamina(st, staminaCost);

            // Engine-level fizzle (D2/D28): stamina is committed; a chosen target slot that is
            // dead/empty skips the move. Inline attacks always require a chosen target in
            // 2-slot modes; nibble-less custom moves (no slot target) pass through with
            // targetBits == 0.
            uint256 targetBits = moveExtra >> TARGET_BITS_SHIFT;
            uint256 tSlot;
            uint256 tMon = EMPTY_ACTIVE_LANE;
            if (targetBits != 0) {
                tSlot = TargetLib.lowestSlot(targetBits);
                tMon = _slotActive(battle, tSlot);
                if (tMon == EMPTY_ACTIVE_LANE || _getMonState(config, tSlot >> 1, tMon).isKnockedOut) {
                    return;
                }
            } else if (isInlineAttack) {
                return;
            }

            // Fold odd slots into the combat rng so same-side attackers don't share
            // accuracy/crit/volatility/proc rolls; slot-0 lanes keep the raw stream. The tag
            // domain-separates this from the scheduler jitter and mixForAttacker keccaks.
            uint256 actionRng = tempRNG;
            if (absSlot & 1 != 0) {
                actionRng = uint256(keccak256(abi.encode(actionRng, absSlot, "SLOT_ACTION")));
            }

            if (isInlineAttack) {
                _inlineStandardAttack(config, rawMoveSlot, side, activeMon, tSlot >> 1, tMon, actionRng);
            } else {
                uint256 moveContext = _buildActivesWord(battle);
                if (rawMoveSlot & MOVE_CONTEXT_STATUS_LANES != 0) {
                    moveContext |= uint256(config.monStatusLanes) << 132;
                }
                if (rawMoveSlot & MOVE_RESOLVER_TAG != 0) {
                    _executeResolvedMove(
                        config,
                        battle,
                        rawMoveSlot,
                        side,
                        activeMon,
                        targetBits,
                        moveContext,
                        uint16(moveExtra & EXTRA_DATA_PAYLOAD_MASK),
                        actionRng
                    );
                } else {
                    IMoveSet(address(uint160(rawMoveSlot)))
                        .move(
                            IEngine(address(this)),
                            battleKey,
                            side,
                            activeMon,
                            targetBits,
                            moveContext,
                            uint16(moveExtra & EXTRA_DATA_PAYLOAD_MASK),
                            actionRng
                        );
                }
            }
        }

        // Winner lock-in already happened at the KO site; the end-of-turn flag recompute covers
        // the rest — just clear the per-action KO marker.
        koOccurredFlag = 0;
    }

    /// @dev The roster range a slot may switch within: Multi partitions each side's 8-mon
    ///      roster by seat (slot i owns [4i, 4i+4)); other modes use the whole side roster.
    function _slotRosterBounds(BattleConfig storage config, uint256 absSlot)
        private
        view
        returns (uint256 lo, uint256 hi)
    {
        if (config.battleMode == BATTLE_MODE_MULTI) {
            lo = (absSlot & 1) << 2;
            return (lo, lo + 4);
        }
        uint256 side = absSlot >> 1;
        return (0, (side == 0) ? (config.teamSizes & 0x0F) : (config.teamSizes >> 4));
    }

    /// @dev The silent-no-op legality gates shared by every slot-switch surface: roster bounds
    ///      (Multi quarters), target not KO'd, ally lane not already holding it. Same-mon
    ///      re-switch is checked by callers (turn-0 send-ins legitimately re-pick the lane).
    function _isLegalSlotSwitchTarget(
        BattleConfig storage config,
        BattleData storage battle,
        uint256 absSlot,
        uint256 target
    ) private view returns (bool) {
        (uint256 rosterLo, uint256 rosterHi) = _slotRosterBounds(config, absSlot);
        if (target < rosterLo || target >= rosterHi) {
            return false;
        }
        if (_getMonState(config, absSlot >> 1, target).isKnockedOut) {
            return false;
        }
        return target != _slotActive(battle, absSlot ^ 1);
    }

    /// @dev First legal switch target within the slot's roster bounds: lowest non-KO'd index
    ///      not held by the ally slot.
    function _firstLegalSwitchTarget(BattleConfig storage config, BattleData storage battle, uint256 absSlot)
        private
        view
        returns (uint256 target, bool found)
    {
        (uint256 lo, uint256 hi) = _slotRosterBounds(config, absSlot);
        uint256 allyMon = _slotActive(battle, absSlot ^ 1);
        uint256 koBitmap = _getKOBitmap(config, absSlot >> 1);
        for (uint256 i = lo; i < hi;) {
            if ((koBitmap & (1 << i)) == 0 && i != allyMon) {
                return (i, true);
            }
            unchecked {
                ++i;
            }
        }
        return (0, false);
    }

    /// @dev Slot-addressed switch: out-effects for the leaving mon (skipped for KO'd/empty
    ///      lanes), lane write, in-effects + ability for the arriving mon. Mirrors
    ///      _handleSwitch with explicit slot lanes and the 2-slot effect loop.
    function _handleSlotSwitch(
        bytes32 battleKey,
        BattleConfig storage config,
        BattleData storage battle,
        uint256 absSlot,
        uint256 monToSwitchIndex,
        uint256 currentActive
    ) private {
        uint256 side = absSlot >> 1;
        uint256 rng = tempRNG;
        if (currentActive != EMPTY_ACTIVE_LANE && !_getMonState(config, side, currentActive).isKnockedOut) {
            uint256 outCount = side == 0
                ? _getMonEffectCount(config.packedP0EffectsCount, currentActive)
                : _getMonEffectCount(config.packedP1EffectsCount, currentActive);
            if (outCount > 0 && _monListensAt(config, side, currentActive, EffectStep.OnMonSwitchOut)) {
                _runEffectsForMon(
                    config, battle, rng, side, side, currentActive, EffectStep.OnMonSwitchOut, "", outCount
                );
            }
            uint256 gLen = config.globalEffectsLength;
            if (gLen > 0) {
                _runEffectsForMon(config, battle, rng, 2, side, currentActive, EffectStep.OnMonSwitchOut, "", gLen);
            }
        }

        _setSlotActive(battle, absSlot, monToSwitchIndex);

        uint256 inCount = side == 0
            ? _getMonEffectCount(config.packedP0EffectsCount, monToSwitchIndex)
            : _getMonEffectCount(config.packedP1EffectsCount, monToSwitchIndex);
        if (inCount > 0 && _monListensAt(config, side, monToSwitchIndex, EffectStep.OnMonSwitchIn)) {
            _runEffectsForMon(config, battle, rng, side, side, monToSwitchIndex, EffectStep.OnMonSwitchIn, "", inCount);
        }
        uint256 inGlobals = config.globalEffectsLength;
        if (inGlobals > 0) {
            _runEffectsForMon(config, battle, rng, 2, side, monToSwitchIndex, EffectStep.OnMonSwitchIn, "", inGlobals);
        }

        if (battle.turnId != 0 && !_getMonState(config, side, monToSwitchIndex).isKnockedOut) {
            _activateAbility(
                config, battleKey, _getTeamMon(config, side, monToSwitchIndex).ability, side, monToSwitchIndex
            );
        }
    }

    /// @dev Per-slot RoundStart/RoundEnd lists in current speed order (D29): re-picks by speed
    ///      (priorities zeroed) among live slots, skipping KO'd actives (the singles
    ///      SkipIfGameOverOrMonKO condition) and stopping on game over.
    function _runSlotEffectPass(
        bytes32 battleKey,
        BattleConfig storage config,
        BattleData storage battle,
        uint256 rng,
        EffectStep step
    ) private {
        // One exact word answers both "has effects" and "listens at this step" for all actives.
        // Empty lanes (0xFF) naturally shift beyond the word and read false.
        uint256 stepsWord = config.playerEffectStepsByMon;
        if (
            !_stepsWordListens(stepsWord, 0, _slotActive(battle, 0), step)
                && !_stepsWordListens(stepsWord, 0, _slotActive(battle, 1), step)
                && !_stepsWordListens(stepsWord, 1, _slotActive(battle, 2), step)
                && !_stepsWordListens(stepsWord, 1, _slotActive(battle, 3), step)
        ) {
            return;
        }
        uint256 doneMask;
        // Distinct jitter-seed ranges per pass (and from the action scheduler's 0-3) so the
        // RoundStart and RoundEnd orderings roll independently.
        uint256 pickBase = step == EffectStep.RoundStart ? 16 : 24;
        uint256 pick;
        while (pick < 4) {
            uint256 slot;
            (slot, doneMask, pick) = _pickNextEffectSlot(config, battle, stepsWord, doneMask, rng, pickBase, pick, step);
            if (slot == NO_SLOT) {
                break;
            }
            if (battle.winnerIndex != 2) {
                return;
            }
            uint256 side = slot >> 1;
            uint256 mon = _slotActive(battle, slot);
            uint256 cnt = side == 0
                ? _getMonEffectCount(config.packedP0EffectsCount, mon)
                : _getMonEffectCount(config.packedP1EffectsCount, mon);
            _runEffectsForMon(config, battle, rng, side, side, mon, step, "", cnt);
        }
    }

    /// @dev The 2-slot effect loop: _runEffectsCore with an explicit mon and the real 4-lane
    ///      actives word, rebuilt per call — it must stay fresh across mid-pass switches.
    function _runEffectsForMon(
        BattleConfig storage config,
        BattleData storage battle,
        uint256 rng,
        uint256 effectIndex,
        uint256 playerIndex,
        uint256 monIndex,
        EffectStep round,
        bytes memory extraEffectsData,
        uint256 effectsCountHint
    ) internal {
        _runEffectsCore(
            config,
            rng,
            effectIndex,
            playerIndex,
            monIndex,
            round,
            extraEffectsData,
            effectsCountHint,
            _buildActivesWord(battle)
        );
    }

    /// @dev End-of-turn flag: bit per slot whose active is KO'd AND whose side still has a legal
    ///      replacement for it (exhausted slots stay unmasked and simply stop acting — D6).
    ///      No bits => normal full turn (2).
    function _computeSlotEndFlag(BattleConfig storage config, BattleData storage battle)
        private
        view
        returns (uint256)
    {
        uint256 mask;
        for (uint256 s; s < 4;) {
            uint256 mon = _slotActive(battle, s);
            if (mon != EMPTY_ACTIVE_LANE && _getMonState(config, s >> 1, mon).isKnockedOut) {
                (, bool found) = _firstLegalSwitchTarget(config, battle, s);
                if (found) {
                    mask |= (1 << s);
                }
            }
            unchecked {
                ++s;
            }
        }
        return mask == 0 ? 2 : (0x80 | mask);
    }

    /// @notice Active roster index per absolute slot (EMPTY_ACTIVE_LANE = vacant). Slots 1/3 are
    ///         only meaningful in 2-slot modes.
    function getActiveSlots(bytes32 battleKey) external view returns (uint256[4] memory slots) {
        BattleData storage battle = battleData[battleKey];
        for (uint256 s; s < 4;) {
            slots[s] = _slotActive(battle, s);
            unchecked {
                ++s;
            }
        }
    }

    /// @dev Resolves the storage key for a battle, using the cached transient value during execution
    function _resolveStorageKey(bytes32 battleKey) internal view returns (bytes32) {
        bytes32 cached = storageKeyForWrite;
        return cached != bytes32(0) ? cached : _getStorageKey(battleKey);
    }

    /**
     * - Helper functions for packing/unpacking activeMonIndex
     */
    function _unpackActiveMonIndex(uint16 packed, uint256 playerIndex) internal pure returns (uint256) {
        if (playerIndex == 0) {
            return uint256(uint8(packed));
        } else {
            return uint256(uint8(packed >> 8));
        }
    }

    function _setActiveMonIndex(uint16 packed, uint256 playerIndex, uint256 monIndex) internal pure returns (uint16) {
        if (playerIndex == 0) {
            return (packed & 0xFF00) | uint16(uint8(monIndex));
        } else {
            return (packed & 0x00FF) | (uint16(uint8(monIndex)) << 8);
        }
    }

    // Helper functions for per-mon effect count packing
    function _getMonEffectCount(uint96 packedCounts, uint256 monIndex) private pure returns (uint256) {
        return (uint256(packedCounts) >> (monIndex * PLAYER_EFFECT_BITS)) & EFFECT_COUNT_MASK;
    }

    function _setMonEffectCount(uint96 packedCounts, uint256 monIndex, uint256 count) private pure returns (uint96) {
        uint256 shift = monIndex * PLAYER_EFFECT_BITS;
        uint256 cleared = uint256(packedCounts) & ~(EFFECT_COUNT_MASK << shift);
        return uint96(cleared | (count << shift));
    }

    function _getEffectSlotIndex(uint256 monIndex, uint256 effectIndex) private pure returns (uint256) {
        return EFFECT_SLOTS_PER_MON * monIndex + effectIndex;
    }

    // Helper functions for accessing team and monState mappings
    function _getTeamMon(BattleConfig storage config, uint256 playerIndex, uint256 monIndex)
        private
        view
        returns (StoredMon storage)
    {
        return playerIndex == 0 ? config.p0Team[monIndex] : config.p1Team[monIndex];
    }

    /// @dev Caller passes `config` so each of the 3 call sites per turn doesn't re-resolve
    ///      the `battleConfig[storageKeyForWrite]` mapping separately. The RoundEnd path
    ///      additionally reads `battleData[battleKeyForWrite]`, but that's only one of two
    ///      branches and threading `battle` through `_runSingleEffect` (the other caller)
    ///      added more bytecode/parameter overhead than it saved on external-effect
    ///      benchmarks, so we resolve it locally here.
    function _inlineStaminaRegen(
        BattleConfig storage config,
        EffectStep round,
        uint256 playerIndex,
        uint256 monIndex,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex,
        uint256 prevPlayerSwitchForTurnFlag
    ) private returns (uint256 playerSwitchForTurnFlag) {
        playerSwitchForTurnFlag = prevPlayerSwitchForTurnFlag;
        if (round == EffectStep.RoundEnd) {
            if (!StaminaRegenLogic._shouldRegenOnRoundEnd(battleData[battleKeyForWrite].playerSwitchForTurnFlag)) {
                return playerSwitchForTurnFlag;
            }
            _inlineRegenStaminaForMon(config, 0, p0ActiveMonIndex);
            _inlineRegenStaminaForMon(config, 1, p1ActiveMonIndex);
        } else if (round == EffectStep.AfterMove) {
            // Fetch packedMoveIndex via helper - resolves to transient during executeWithMoves, storage otherwise.
            uint8 packedMoveIndex = uint8(_currentTurnMoveWord(config, playerIndex));
            if (!StaminaRegenLogic._isRestingMove(packedMoveIndex)) {
                return playerSwitchForTurnFlag;
            }
            _inlineRegenStaminaForMon(config, playerIndex, monIndex);
        }

        // A regen tick fires OnUpdateMonState, which an effect (e.g. Somniphobia's nightmare) can
        // turn into dealDamage and KO the mon that just gained stamina. Mirror the koOccurredFlag
        // handling in _handleMove / _handleEffects: without it, a KO landing on the round-end regen
        // (the last thing in the turn) is never observed, so playerSwitchForTurnFlag stays 2 and the
        // engine wrongly runs the next turn as a normal both-sides-act turn instead of a forced switch.
        if (koOccurredFlag != 0) {
            koOccurredFlag = 0;
            (playerSwitchForTurnFlag,) = _checkForGameOverOrKO(config, battleData[battleKeyForWrite], 2);
        }
    }

    /// @dev Mirrors the storage write that StaminaRegenLogic used to do, then fires
    /// OnUpdateMonState so per-mon listeners (e.g. Dreamcatcher) see the +1 stamina —
    /// matching the external StaminaRegen effect path, which goes through updateMonState.
    function _inlineRegenStaminaForMon(BattleConfig storage config, uint256 playerIndex, uint256 monIndex) private {
        MonState storage monState = playerIndex == 0 ? config.p0States[monIndex] : config.p1States[monIndex];
        if (monState.staminaDelta >= 0) {
            return;
        }
        monState.staminaDelta += 1;
        // Exact lane skips unrelated mons without loading their effect count.
        if (_monListensAt(config, playerIndex, monIndex, EffectStep.OnUpdateMonState)) {
            _runEffectsPipeline(
                config,
                playerIndex,
                monIndex,
                EffectStep.OnUpdateMonState,
                abi.encode(playerIndex, monIndex, MonStateIndexName.Stamina, int32(1))
            );
        }
    }

    function _getMonState(BattleConfig storage config, uint256 playerIndex, uint256 monIndex)
        private
        view
        returns (MonState storage)
    {
        return playerIndex == 0 ? config.p0States[monIndex] : config.p1States[monIndex];
    }

    function _deductStamina(MonState storage state, int32 cost) private {
        state.staminaDelta = (state.staminaDelta == CLEARED_MON_STATE_SENTINEL) ? -cost : state.staminaDelta - cost;
    }

    function _emitMonMoves(
        bytes32 battleKey,
        BattleData storage battle,
        uint256 p0Move,
        uint256 p1Move,
        uint104 p0Salt,
        uint104 p1Salt
    ) private {
        // Skip the emit entirely if neither player submitted this turn.
        if (uint8(p0Move) == 0 && uint8(p1Move) == 0) {
            return;
        }

        uint256 p0MonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 0);
        uint256 p1MonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 1);

        // Move words are [packedMoveIndex 8 | extraData 16], so shifting the whole word lands
        // both fields in their MonMoves lanes.
        uint256 packedMoves =
            uint256(uint8(p0MonIndex)) | (p0Move << 8) | (uint256(uint8(p1MonIndex)) << 32) | (p1Move << 40);

        uint256 packedSalts = uint256(p0Salt) | (uint256(p1Salt) << 104);

        emit MonMoves(battleKey, packedMoves, packedSalts);
    }

    // Helper functions for KO bitmap management (packed: lower 8 bits = p0, upper 8 bits = p1)
    function _getKOBitmap(BattleConfig storage config, uint256 playerIndex) private view returns (uint256) {
        return playerIndex == 0 ? (config.koBitmaps & 0xFF) : (config.koBitmaps >> 8);
    }

    function _setMonKO(BattleConfig storage config, uint256 playerIndex, uint256 monIndex) private {
        uint256 bit = 1 << monIndex;
        if (playerIndex == 0) {
            config.koBitmaps = config.koBitmaps | uint16(bit);
        } else {
            config.koBitmaps = config.koBitmaps | uint16(bit << 8);
        }
    }

    function _clearMonKO(BattleConfig storage config, uint256 playerIndex, uint256 monIndex) private {
        uint256 bit = 1 << monIndex;
        if (playerIndex == 0) {
            config.koBitmaps = config.koBitmaps & uint16(~bit);
        } else {
            config.koBitmaps = config.koBitmaps & uint16(~(bit << 8));
        }
    }

    function _loadEffectsCount(BattleConfig storage config, uint256 effectIndex, uint256 monIndex)
        private
        view
        returns (uint256)
    {
        if (effectIndex == 2) {
            return config.globalEffectsLength;
        }
        if (effectIndex == 0) {
            return _getMonEffectCount(config.packedP0EffectsCount, monIndex);
        }
        return _getMonEffectCount(config.packedP1EffectsCount, monIndex);
    }

    /**
     * - Effect filtering helper
     */
    function _getEffectsForTarget(bytes32 storageKey, uint256 targetIndex, uint256 monIndex)
        internal
        view
        returns (EffectInstance[] memory, uint256[] memory)
    {
        BattleConfig storage config = battleConfig[storageKey];

        if (targetIndex == 2) {
            // Global query - allocate max size and populate in single pass
            uint256 globalEffectsLength = config.globalEffectsLength;
            EffectInstance[] memory globalResult = new EffectInstance[](globalEffectsLength);
            uint256[] memory globalIndices = new uint256[](globalEffectsLength);
            uint256 globalIdx = 0;
            for (uint256 i = 0; i < globalEffectsLength;) {
                EffectInstance storage storedEffect = config.globalEffects[i];
                if (address(storedEffect.effect) != TOMBSTONE_ADDRESS) {
                    globalResult[globalIdx] = EffectInstance({
                        effect: storedEffect.effect,
                        stepsBitmap: storedEffect.stepsBitmap,
                        data: _effectData(storedEffect)
                    });
                    globalIndices[globalIdx] = i;
                    unchecked {
                        ++globalIdx;
                    }
                }
                unchecked {
                    ++i;
                }
            }
            // Resize arrays to actual count
            assembly ("memory-safe") {
                mstore(globalResult, globalIdx)
                mstore(globalIndices, globalIdx)
            }
            return (globalResult, globalIndices);
        }

        // Player query - allocate max size and populate in single pass
        uint96 packedCounts = targetIndex == 0 ? config.packedP0EffectsCount : config.packedP1EffectsCount;
        uint256 monEffectCount = _getMonEffectCount(packedCounts, monIndex);
        uint256 baseSlot = _getEffectSlotIndex(monIndex, 0);
        mapping(uint256 => EffectInstance) storage effects = targetIndex == 0 ? config.p0Effects : config.p1Effects;

        EffectInstance[] memory result = new EffectInstance[](monEffectCount);
        uint256[] memory indices = new uint256[](monEffectCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < monEffectCount;) {
            uint256 slotIndex = baseSlot + i;
            EffectInstance storage storedEffect = effects[slotIndex];
            if (address(storedEffect.effect) != TOMBSTONE_ADDRESS) {
                result[idx] = EffectInstance({
                    effect: storedEffect.effect, stepsBitmap: storedEffect.stepsBitmap, data: _effectData(storedEffect)
                });
                indices[idx] = slotIndex;
                unchecked {
                    ++idx;
                }
            }
            unchecked {
                ++i;
            }
        }

        // Resize arrays to actual count
        assembly ("memory-safe") {
            mstore(result, idx)
            mstore(indices, idx)
        }
        return (result, indices);
    }

    /**
     * - Getters to simplify read access for other components
     */
    function getBattle(bytes32 battleKey) external view returns (BattleConfigView memory, BattleData memory) {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleConfig storage config = battleConfig[storageKey];
        BattleData storage data = battleData[battleKey];

        // Build global effects array (single pass, skip tombstones)
        uint256 globalLen = config.globalEffectsLength;
        EffectInstance[] memory globalEffects = new EffectInstance[](globalLen);
        uint256 gIdx = 0;
        for (uint256 i = 0; i < globalLen;) {
            EffectInstance storage storedEffect = config.globalEffects[i];
            if (address(storedEffect.effect) != TOMBSTONE_ADDRESS) {
                globalEffects[gIdx] = EffectInstance({
                    effect: storedEffect.effect, stepsBitmap: storedEffect.stepsBitmap, data: _effectData(storedEffect)
                });
                unchecked {
                    ++gIdx;
                }
            }
            unchecked {
                ++i;
            }
        }
        // Resize array to actual count
        assembly ("memory-safe") {
            mstore(globalEffects, gIdx)
        }

        // Build player effects arrays by iterating through all mons
        uint8 teamSizes = config.teamSizes;
        uint256 p0TeamSize = teamSizes & 0xF;
        uint256 p1TeamSize = (teamSizes >> 4) & 0xF;

        EffectInstance[][] memory p0Effects =
            _buildPlayerEffectsArray(config.p0Effects, config.packedP0EffectsCount, p0TeamSize);
        EffectInstance[][] memory p1Effects =
            _buildPlayerEffectsArray(config.p1Effects, config.packedP1EffectsCount, p1TeamSize);

        // Build teams array from the fixed-lane mappings (rebuilds the public Mon shape)
        Mon[][] memory teams = new Mon[][](2);
        teams[0] = new Mon[](p0TeamSize);
        teams[1] = new Mon[](p1TeamSize);
        for (uint256 i = 0; i < p0TeamSize;) {
            teams[0][i] = _loadStoredMon(config.p0Team[i]);
            unchecked {
                ++i;
            }
        }
        for (uint256 i = 0; i < p1TeamSize;) {
            teams[1][i] = _loadStoredMon(config.p1Team[i]);
            unchecked {
                ++i;
            }
        }

        // Build monStates array from mappings
        MonState[][] memory monStates = new MonState[][](2);
        monStates[0] = new MonState[](p0TeamSize);
        monStates[1] = new MonState[](p1TeamSize);
        for (uint256 i = 0; i < p0TeamSize;) {
            monStates[0][i] = config.p0States[i];
            unchecked {
                ++i;
            }
        }
        for (uint256 i = 0; i < p1TeamSize;) {
            monStates[1][i] = config.p1States[i];
            unchecked {
                ++i;
            }
        }

        // Build globalKV entries from the packed key buffer, bounded by the per-battle count.
        uint256 kvCount = config.globalKVCount;
        GlobalKVEntry[] memory globalKVEntries = new GlobalKVEntry[](kvCount);
        uint256 slotCount = (kvCount + 3) >> 2;
        for (uint256 s; s < slotCount;) {
            uint256 packedSlot = globalKVKeySlots[storageKey][s];
            uint256 base = s << 2;
            uint256 remaining = kvCount - base > 4 ? 4 : kvCount - base;
            for (uint256 j; j < remaining;) {
                uint64 k = uint64(packedSlot >> (j * 64));
                globalKVEntries[base + j] = GlobalKVEntry({key: k, value: globalKV[storageKey][k]});
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++s;
            }
        }

        // Frontend hydration: passthrough to registry for level/exp on both teams.
        // After _handleGameOver -> _freeStorageKey, the storageKey indirection is
        // dropped and a subsequent getBattle(battleKey) reads an empty config row
        // (since the battle had been using a recycled slot). battleData survives
        // (keyed directly by battleKey), so we still return the final state — we
        // just skip the registry call when teamRegistry has zeroed out.
        (TeamLevelInfo memory p0Levels, TeamLevelInfo memory p1Levels) =
            _getTeamLevels(config.teamRegistry, data.p0, data.p0TeamIndex, data.p1, data.p1TeamIndex);

        BattleConfigView memory configView = BattleConfigView({
            rngOracle: config.rngOracle,
            moveManager: config.moveManager,
            globalEffectsLength: config.globalEffectsLength,
            packedP0EffectsCount: config.packedP0EffectsCount,
            packedP1EffectsCount: config.packedP1EffectsCount,
            teamSizes: config.teamSizes,
            startTimestamp: config.startTimestamp,
            p0Salt: config.p0Salt,
            p1Salt: config.p1Salt,
            p0TeamIndex: data.p0TeamIndex,
            p1TeamIndex: data.p1TeamIndex,
            monStatusLanes: config.monStatusLanes,
            playerEffectStepsByMon: config.playerEffectStepsByMon,
            p0Move: config.p0Move,
            p1Move: config.p1Move,
            globalEffects: globalEffects,
            p0StatBoosts: _boostWordsView(config, 0),
            p1StatBoosts: _boostWordsView(config, 1),
            p0Effects: p0Effects,
            p1Effects: p1Effects,
            teams: teams,
            monStates: monStates,
            globalKVEntries: globalKVEntries,
            p0Levels: p0Levels,
            p1Levels: p1Levels
        });

        return (configView, data);
    }

    /// @dev Rebuilds the public `Mon` view shape from Engine-internal StoredMon storage. The
    ///      dynamic moves array's length is derived by dropping trailing zero lanes — matching the
    ///      length the team was stored with, since zero move words are never valid playable moves.
    function _loadStoredMon(StoredMon storage sm) private view returns (Mon memory m) {
        m.stats = sm.stats;
        m.ability = sm.ability;
        uint256 len = MOVE_LANES_PER_MON;
        while (len > 0 && sm.moves[len - 1] == 0) {
            unchecked {
                --len;
            }
        }
        uint256[] memory mv = new uint256[](len);
        for (uint256 k = 0; k < len;) {
            mv[k] = sm.moves[k];
            unchecked {
                ++k;
            }
        }
        m.moves = mv;
    }

    function _buildPlayerEffectsArray(
        mapping(uint256 => EffectInstance) storage effects,
        uint96 packedCounts,
        uint256 teamSize
    ) private view returns (EffectInstance[][] memory) {
        // Allocate outer array for each mon
        EffectInstance[][] memory result = new EffectInstance[][](teamSize);

        for (uint256 m = 0; m < teamSize;) {
            uint256 monCount = _getMonEffectCount(packedCounts, m);
            uint256 baseSlot = _getEffectSlotIndex(m, 0);

            // Allocate max size for this mon's effects
            EffectInstance[] memory monEffects = new EffectInstance[](monCount);
            uint256 idx = 0;
            for (uint256 i = 0; i < monCount;) {
                EffectInstance storage storedEffect = effects[baseSlot + i];
                if (address(storedEffect.effect) != TOMBSTONE_ADDRESS) {
                    monEffects[idx] = EffectInstance({
                        effect: storedEffect.effect,
                        stepsBitmap: storedEffect.stepsBitmap,
                        data: _effectData(storedEffect)
                    });
                    unchecked {
                        ++idx;
                    }
                }
                unchecked {
                    ++i;
                }
            }

            // Resize array to actual count
            assembly ("memory-safe") {
                mstore(monEffects, idx)
            }
            result[m] = monEffects;
            unchecked {
                ++m;
            }
        }

        return result;
    }

    function _getTeamLevels(ITeamRegistry registry, address p0, uint256 p0TeamIndex, address p1, uint256 p1TeamIndex)
        internal
        view
        returns (TeamLevelInfo memory p0Levels, TeamLevelInfo memory p1Levels)
    {
        if (address(registry) == address(0)) {
            uint256[] memory empty = new uint256[](0);
            p0Levels = TeamLevelInfo({monIds: empty, exp: empty, levels: empty});
            p1Levels = TeamLevelInfo({monIds: empty, exp: empty, levels: empty});
            return (p0Levels, p1Levels);
        }
        (
            uint256[] memory p0MonIds,
            uint256[] memory p0Exp,
            uint256[] memory p0LevelArr,
            uint256[] memory p1MonIds,
            uint256[] memory p1Exp,
            uint256[] memory p1LevelArr
        ) = registry.getExpAndLevelsForTeams(p0, p0TeamIndex, p1, p1TeamIndex);
        p0Levels = TeamLevelInfo({monIds: p0MonIds, exp: p0Exp, levels: p0LevelArr});
        p1Levels = TeamLevelInfo({monIds: p1MonIds, exp: p1Exp, levels: p1LevelArr});
    }

    /// @notice Validates a player move, handling both inline validation (when validator is address(0)) and external validators
    /// @dev This allows callers like CPU to validate moves without needing to handle the address(0) case themselves
    function validatePlayerMoveForBattle(bytes32 battleKey, uint256 moveIndex, uint256 playerIndex, uint16 extraData)
        external
        returns (bool)
    {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleConfig storage config = battleConfig[storageKey];

        // Inline validation (the engine is the only validator)
        BattleData storage data = battleData[battleKey];
        uint256 activeMonIndex = _unpackActiveMonIndex(data.activeMonIndex, playerIndex);
        MonState storage activeMonState = _getMonState(config, playerIndex, activeMonIndex);

        // Basic validation (bounds, forced switch checks)
        (, bool isNoOp, bool isSwitch, bool isRegularMove, bool basicValid) = ValidatorLogic.validatePlayerMoveBasics(
            moveIndex, data.turnId, activeMonState.isKnockedOut, DEFAULT_MOVES_PER_MON
        );

        if (!basicValid) {
            return false;
        }

        // No-op is always valid if basic validation passed
        if (isNoOp) {
            return true;
        }

        // Switch validation
        if (isSwitch) {
            uint256 monToSwitchIndex = uint256(extraData & EXTRA_DATA_PAYLOAD_MASK);
            bool isTargetKnockedOut = _getMonState(config, playerIndex, monToSwitchIndex).isKnockedOut;
            return ValidatorLogic.validateSwitch(
                data.turnId, activeMonIndex, monToSwitchIndex, isTargetKnockedOut, DEFAULT_MONS_PER_TEAM
            );
        }

        // Regular move validation
        if (isRegularMove) {
            StoredMon storage activeMon = _getTeamMon(config, playerIndex, activeMonIndex);
            // Out-of-lane index or zero lane = the mon has no move there — invalid selection.
            // (Previously an out-of-bounds index reverted this whole view; false is strictly safer.)
            if (moveIndex >= MOVE_LANES_PER_MON) {
                return false;
            }
            uint256 rawMoveSlot = activeMon.moves[moveIndex];
            if (rawMoveSlot == 0) {
                return false;
            }
            uint32 baseStamina = activeMon.stats.stamina;
            int32 staminaDelta = activeMonState.staminaDelta;
            return ValidatorLogic.validateSpecificMoveSelection(
                IEngine(address(this)),
                battleKey,
                rawMoveSlot,
                playerIndex,
                activeMonIndex,
                extraData,
                baseStamina,
                staminaDelta
            );
        }

        return true;
    }

    function getMonValueForBattle(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 monIndex,
        MonStateIndexName stateVarIndex
    ) external view returns (uint32) {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleConfig storage config = battleConfig[storageKey];
        StoredMon storage mon = _getTeamMon(config, playerIndex, monIndex);
        if (stateVarIndex == MonStateIndexName.Hp) {
            return mon.stats.hp;
        } else if (stateVarIndex == MonStateIndexName.Stamina) {
            return mon.stats.stamina;
        } else if (stateVarIndex == MonStateIndexName.Speed) {
            return mon.stats.speed;
        } else if (stateVarIndex == MonStateIndexName.Attack) {
            return mon.stats.attack;
        } else if (stateVarIndex == MonStateIndexName.Defense) {
            return mon.stats.defense;
        } else if (stateVarIndex == MonStateIndexName.SpecialAttack) {
            return mon.stats.specialAttack;
        } else if (stateVarIndex == MonStateIndexName.SpecialDefense) {
            return mon.stats.specialDefense;
        } else if (stateVarIndex == MonStateIndexName.Type1) {
            return uint32(mon.stats.type1);
        } else if (stateVarIndex == MonStateIndexName.Type2) {
            return uint32(mon.stats.type2);
        } else {
            return 0;
        }
    }

    function getMoveForMonForBattle(bytes32 battleKey, uint256 playerIndex, uint256 monIndex, uint256 moveIndex)
        external
        view
        returns (uint256)
    {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleConfig storage config = battleConfig[storageKey];
        return _getTeamMon(config, playerIndex, monIndex).moves[moveIndex];
    }

    /// @notice Per-slot current-turn move. Effects resolve their mon's slot via
    ///         TargetLib.slotOfMon and read through this — mode-agnostic (singles slot 0
    ///         falls back to the flow-aware singles read).
    function getMoveDecisionForSlot(bytes32 battleKey, uint256 playerIndex, uint256 slotIndex)
        external
        view
        returns (MoveDecision memory)
    {
        if (battleData[battleKey].isTwoSlotMode) {
            return _getCurrentTurnMoveForSlot(playerIndex, slotIndex & 1);
        }
        return _getCurrentTurnMove(battleConfig[_resolveStorageKey(battleKey)], playerIndex);
    }

    function getMonStatsForBattle(bytes32 battleKey, uint256 playerIndex, uint256 monIndex)
        external
        view
        returns (MonStats memory)
    {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleConfig storage config = battleConfig[storageKey];
        return _getTeamMon(config, playerIndex, monIndex).stats;
    }

    function getMonStateForBattle(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 monIndex,
        MonStateIndexName stateVarIndex
    ) external view returns (int32) {
        BattleConfig storage config = battleConfig[_resolveStorageKey(battleKey)];
        return _readMonStateDelta(config, playerIndex, monIndex, stateVarIndex);
    }

    function getMonHpState(bytes32 battleKey, uint256 playerIndex, uint256 monIndex)
        external
        view
        returns (uint32 maxHp, int32 hpDelta)
    {
        BattleConfig storage config = battleConfig[_resolveStorageKey(battleKey)];
        maxHp = _getTeamMon(config, playerIndex, monIndex).stats.hp;
        hpDelta = _getMonState(config, playerIndex, monIndex).hpDelta;
        if (hpDelta == CLEARED_MON_STATE_SENTINEL) {
            hpDelta = 0;
        }
    }

    /// @notice Current (base + delta, sentinel-aware) value of a mon stat in one call — the
    ///         merged form of the getMonValueForBattle + getMonStateForBattle pair. Only
    ///         meaningful for Hp/Stamina and the five stats (booleans have no base value).
    function getMonCurrentValue(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 monIndex,
        MonStateIndexName stateVarIndex
    ) external view returns (int32) {
        BattleConfig storage config = battleConfig[_resolveStorageKey(battleKey)];
        StoredMon storage mon = _getTeamMon(config, playerIndex, monIndex);
        uint32 base;
        if (stateVarIndex == MonStateIndexName.Hp) {
            base = mon.stats.hp;
        } else if (stateVarIndex == MonStateIndexName.Stamina) {
            base = mon.stats.stamina;
        } else if (stateVarIndex == MonStateIndexName.Speed) {
            base = mon.stats.speed;
        } else if (stateVarIndex == MonStateIndexName.Attack) {
            base = mon.stats.attack;
        } else if (stateVarIndex == MonStateIndexName.Defense) {
            base = mon.stats.defense;
        } else if (stateVarIndex == MonStateIndexName.SpecialAttack) {
            base = mon.stats.specialAttack;
        } else if (stateVarIndex == MonStateIndexName.SpecialDefense) {
            base = mon.stats.specialDefense;
        }
        return int32(base) + _readMonStateDelta(config, playerIndex, monIndex, stateVarIndex);
    }

    function _readMonStateDelta(
        BattleConfig storage config,
        uint256 playerIndex,
        uint256 monIndex,
        MonStateIndexName stateVarIndex
    ) private view returns (int32) {
        MonState storage monState = _getMonState(config, playerIndex, monIndex);
        int32 value;

        if (stateVarIndex == MonStateIndexName.Hp) {
            value = monState.hpDelta;
        } else if (stateVarIndex == MonStateIndexName.Stamina) {
            value = monState.staminaDelta;
        } else if (stateVarIndex == MonStateIndexName.Speed) {
            value = monState.speedDelta;
        } else if (stateVarIndex == MonStateIndexName.Attack) {
            value = monState.attackDelta;
        } else if (stateVarIndex == MonStateIndexName.Defense) {
            value = monState.defenceDelta;
        } else if (stateVarIndex == MonStateIndexName.SpecialAttack) {
            value = monState.specialAttackDelta;
        } else if (stateVarIndex == MonStateIndexName.SpecialDefense) {
            value = monState.specialDefenceDelta;
        } else if (stateVarIndex == MonStateIndexName.IsKnockedOut) {
            return monState.isKnockedOut ? int32(1) : int32(0);
        } else if (stateVarIndex == MonStateIndexName.ShouldSkipTurn) {
            return monState.shouldSkipTurn ? int32(1) : int32(0);
        } else {
            return int32(0);
        }

        // Return 0 if sentinel value is encountered
        return (value == CLEARED_MON_STATE_SENTINEL) ? int32(0) : value;
    }

    function getTurnIdForBattleState(bytes32 battleKey) external view returns (uint256) {
        return battleData[battleKey].turnId;
    }

    function getGlobalKV(bytes32 battleKey, uint64 key) external view returns (uint192) {
        return _getGlobalKVValue(_resolveStorageKey(battleKey), key);
    }

    /// @dev Internal timestamp-gated globalKV reader. Returns 0 for stale values left over from a
    ///      prior battle that reused this storageKey. Shared by getGlobalKV and the inlined
    ///      stat-boost snapshot path.
    function _getGlobalKVValue(bytes32 storageKey, uint64 key) private view returns (uint192) {
        bytes32 packed = globalKV[storageKey][key];
        uint64 storedTimestamp = uint64(uint256(packed) >> 192);
        uint64 currentTimestamp = uint64(battleConfig[storageKey].startTimestamp);
        if (storedTimestamp != currentTimestamp) {
            return 0;
        }
        return uint192(uint256(packed));
    }

    function getEffects(bytes32 battleKey, uint256 targetIndex, uint256 monIndex)
        external
        view
        returns (EffectInstance[] memory, uint256[] memory)
    {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        return _getEffectsForTarget(storageKey, targetIndex, monIndex);
    }

    /// @dev View shape of a side's stat-boost store: per-mon arrays of packed source words
    ///      (StatBoostLib layout — clients decode key/perm/lanes off-chain).
    function _boostWordsView(BattleConfig storage config, uint256 side) private view returns (bytes32[][] memory out) {
        uint256 teamSize = side == 0 ? (config.teamSizes & 0x0F) : (config.teamSizes >> 4);
        mapping(uint256 => bytes32) storage words = _boostWordsOf(config, side);
        out = new bytes32[][](teamSize);
        for (uint256 m; m < teamSize; ++m) {
            uint256 cnt = _boostCountOf(config, side, m);
            bytes32[] memory ws = new bytes32[](cnt);
            for (uint256 i; i < cnt; ++i) {
                ws[i] = words[m * 16 + i];
            }
            out[m] = ws;
        }
    }

    /// @notice Class id (stepsBitmap bits 10-13) of the mon's exclusive status; 0 = none.
    function getMonStatusClass(bytes32 battleKey, uint256 targetIndex, uint256 monIndex)
        external
        view
        returns (uint256)
    {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        return (battleConfig[storageKey].monStatusLanes >> _statusLaneShift(targetIndex, monIndex)) & 0xF;
    }

    /// @notice Targeted single-effect lookup. Scans a mon's (or the global) effect list for
    ///         `effectAddr` and returns its slot index + data, WITHOUT materializing the full
    ///         `EffectInstance[]` array. For abilities / move-effects that only need one known
    ///         effect (idempotency guards, reading own state) this avoids the array build + ABI
    ///         round-trip that dominates `getEffects()`. `effectIndex` matches the index that
    ///         `editEffect` expects (absolute slot for players, list index for global).
    function getEffectData(bytes32 battleKey, uint256 targetIndex, uint256 monIndex, address effectAddr)
        external
        view
        returns (bool exists, uint256 effectIndex, bytes32 data)
    {
        BattleConfig storage config = battleConfig[_resolveStorageKey(battleKey)];
        if (targetIndex == 2) {
            uint256 len = config.globalEffectsLength;
            for (uint256 i; i < len;) {
                EffectInstance storage e = config.globalEffects[i];
                if (address(e.effect) == effectAddr) {
                    return (true, i, _effectData(e));
                }
                unchecked {
                    ++i;
                }
            }
            return (false, 0, bytes32(0));
        }
        uint96 packedCounts = targetIndex == 0 ? config.packedP0EffectsCount : config.packedP1EffectsCount;
        uint256 monEffectCount = _getMonEffectCount(packedCounts, monIndex);
        uint256 baseSlot = _getEffectSlotIndex(monIndex, 0);
        mapping(uint256 => EffectInstance) storage effects = targetIndex == 0 ? config.p0Effects : config.p1Effects;
        for (uint256 i; i < monEffectCount;) {
            uint256 slotIndex = baseSlot + i;
            EffectInstance storage e = effects[slotIndex];
            if (address(e.effect) == effectAddr) {
                return (true, slotIndex, _effectData(e));
            }
            unchecked {
                ++i;
            }
        }
        return (false, 0, bytes32(0));
    }

    function getWinner(bytes32 battleKey) external view returns (address) {
        BattleData storage data = battleData[battleKey];
        uint8 winnerIndex = data.winnerIndex;
        if (winnerIndex == 2) {
            return address(0);
        }
        return (winnerIndex == 0) ? data.p0 : data.p1;
    }

    function getKOBitmap(bytes32 battleKey, uint256 playerIndex) external view returns (uint256) {
        return _getKOBitmap(battleConfig[_resolveStorageKey(battleKey)], playerIndex);
    }

    function getBattleContext(bytes32 battleKey) external view returns (BattleContext memory ctx) {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleData storage data = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKey];

        ctx.startTimestamp = config.startTimestamp;
        ctx.p0 = data.p0;
        ctx.p1 = data.p1;
        ctx.winnerIndex = data.winnerIndex;
        ctx.turnId = data.turnId;
        ctx.playerSwitchForTurnFlag = data.playerSwitchForTurnFlag;
        ctx.p0ActiveMonIndex = uint8(data.activeMonIndex & 0xFF);
        ctx.p1ActiveMonIndex = uint8(data.activeMonIndex >> 8);
        ctx.moveManager = config.moveManager;
    }

    function _getDamageCalcContextInternal(
        BattleConfig storage config,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 defenderPlayerIndex,
        uint256 defenderMonIndex
    ) internal view returns (DamageCalcContext memory ctx) {
        ctx.attackerMonIndex = uint8(attackerMonIndex);
        ctx.defenderMonIndex = uint8(defenderMonIndex);

        // Get attacker stats
        StoredMon storage attackerMon = _getTeamMon(config, attackerPlayerIndex, attackerMonIndex);
        MonState storage attackerState = _getMonState(config, attackerPlayerIndex, attackerMonIndex);
        ctx.attackerAttack = attackerMon.stats.attack;
        ctx.attackerAttackDelta =
            attackerState.attackDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : attackerState.attackDelta;
        ctx.attackerSpAtk = attackerMon.stats.specialAttack;
        ctx.attackerSpAtkDelta = attackerState.specialAttackDelta == CLEARED_MON_STATE_SENTINEL
            ? int32(0)
            : attackerState.specialAttackDelta;

        // Get defender stats and types
        StoredMon storage defenderMon = _getTeamMon(config, defenderPlayerIndex, defenderMonIndex);
        MonState storage defenderState = _getMonState(config, defenderPlayerIndex, defenderMonIndex);
        ctx.defenderDef = defenderMon.stats.defense;
        ctx.defenderDefDelta =
            defenderState.defenceDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : defenderState.defenceDelta;
        ctx.defenderSpDef = defenderMon.stats.specialDefense;
        ctx.defenderSpDefDelta = defenderState.specialDefenceDelta == CLEARED_MON_STATE_SENTINEL
            ? int32(0)
            : defenderState.specialDefenceDelta;
        ctx.defenderType1 = defenderMon.stats.type1;
        ctx.defenderType2 = defenderMon.stats.type2;
    }

    /// @dev Re-points an existing ctx's defender half at another slot, so a spread sweep resolves the
    ///      attacker's stats once. Deliberately duplicates the block above rather than both calling a
    ///      shared helper: factoring it out costs every single-target caller ~18-33 gas per turn
    ///      (measured; the helper does not fully inline and the memory struct gets passed by pointer).
    function _fillDefenderContext(
        DamageCalcContext memory ctx,
        BattleConfig storage config,
        uint256 defenderPlayerIndex,
        uint256 defenderMonIndex
    ) private view {
        StoredMon storage defenderMon = _getTeamMon(config, defenderPlayerIndex, defenderMonIndex);
        MonState storage defenderState = _getMonState(config, defenderPlayerIndex, defenderMonIndex);
        ctx.defenderMonIndex = uint8(defenderMonIndex);
        ctx.defenderDef = defenderMon.stats.defense;
        ctx.defenderDefDelta =
            defenderState.defenceDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : defenderState.defenceDelta;
        ctx.defenderSpDef = defenderMon.stats.specialDefense;
        ctx.defenderSpDefDelta = defenderState.specialDefenceDelta == CLEARED_MON_STATE_SENTINEL
            ? int32(0)
            : defenderState.specialDefenceDelta;
        ctx.defenderType1 = defenderMon.stats.type1;
        ctx.defenderType2 = defenderMon.stats.type2;
    }

    function getDamageCalcContext(
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 defenderPlayerIndex,
        uint256 defenderMonIndex
    ) external view returns (DamageCalcContext memory ctx) {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleConfig storage config = battleConfig[storageKey];
        return _getDamageCalcContextInternal(
            config, attackerPlayerIndex, attackerMonIndex, defenderPlayerIndex, defenderMonIndex
        );
    }

    /// @notice Returns the MonState array for one side of a battle. Used by registry-side
    ///         quest opcodes that aggregate over MonState fields (e.g. MIN/MAX_HP_DELTA) so
    ///         they pay 1 extcall + N internal SLOADs instead of N separate getMonStateForBattle
    ///         extcalls. Length = team size for that side.
    function getMonStatesForSide(bytes32 battleKey, uint256 playerIndex)
        external
        view
        returns (MonState[] memory states)
    {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleConfig storage config = battleConfig[storageKey];
        uint8 teamSizes = config.teamSizes;
        uint256 size = playerIndex == 0 ? (teamSizes & 0xF) : (teamSizes >> 4);
        states = new MonState[](size);
        if (playerIndex == 0) {
            for (uint256 i; i < size;) {
                states[i] = config.p0States[i];
                unchecked {
                    ++i;
                }
            }
        } else {
            for (uint256 i; i < size;) {
                states[i] = config.p1States[i];
                unchecked {
                    ++i;
                }
            }
        }
    }

    /// @notice Batched getter for the registry's onBattleEnd hook. Bundles every
    ///         BattleData + BattleConfig field needed at battle end into a single staticcall —
    ///         replaces the older split (getPlayersForBattle + getWinner + getKOBitmap×2).
    function getBattleEndContext(bytes32 battleKey) external view returns (BattleEndContext memory ctx) {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleData storage data = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKey];

        ctx.p0 = data.p0;
        ctx.p1 = data.p1;
        // winner: address(0) when uninitialized OR when it's a draw the engine never
        // explicitly sets to a non-2 winnerIndex; both cases collapse to address(0).
        uint8 wi = data.winnerIndex;
        ctx.winner = wi == 0 ? data.p0 : (wi == 1 ? data.p1 : address(0));

        ctx.p0TeamIndex = data.p0TeamIndex;
        ctx.p1TeamIndex = data.p1TeamIndex;

        uint16 koBitmaps = config.koBitmaps;
        ctx.p0KOBitmap = uint8(koBitmaps & 0xFF);
        ctx.p1KOBitmap = uint8(koBitmaps >> 8);

        ctx.p0ActiveMonIndex = uint8(_unpackActiveMonIndex(data.activeMonIndex, 0));
        ctx.p1ActiveMonIndex = uint8(_unpackActiveMonIndex(data.activeMonIndex, 1));

        ctx.turnId = data.turnId;

        if (data.isMultiMode) {
            ctx.isMultiMode = true;
            MultiSeatData storage ms = multiSeats[battleKey];
            ctx.p2 = ms.p2;
            ctx.p3 = ms.p3;
            ctx.p2TeamIndex = ms.p2TeamIndex;
            ctx.p3TeamIndex = ms.p3TeamIndex;
            ctx.p0ActiveMonExtIndex = uint8(_unpackActiveMonIndex(data.activeMonExt, 0));
            ctx.p1ActiveMonExtIndex = uint8(_unpackActiveMonIndex(data.activeMonExt, 1));
        }
    }
}
