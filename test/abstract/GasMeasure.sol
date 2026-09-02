// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {CommonBase} from "../../lib/forge-std/src/Base.sol";
import {Vm, VmSafe} from "../../lib/forge-std/src/Vm.sol";

import {EFFECT_SLOTS_PER_MON} from "../../src/Constants.sol";

/// @notice Shared production-faithful gas measurement: a deterministic storage/account access
///         tally per measured window (one prod-tx-equivalent unit), plus a synthetic
///         `prodStorageGas` that prices the tally at EIP-2929/2200 production rates.
///
///         WHY the synthetic metric is the headline number (and the measured scalar is only
///         directional): a foundry test function is ONE transaction, so EVM warm/cold and
///         dirty-slot pricing never reset between in-test "turns". `vm.cool` only half-fixes
///         this — measured on forge 1.5.1: a re-cooled slot does re-price cold (2,100), but the
///         account access stays warm (100 vs 2,600), and per-slot resets show scale limits on
///         large contracts. On top of that, recompiles shift via-IR code layout by a few k of
///         pure compute (non-semantic), polluting cross-version scalar diffs. The tally is
///         immune to all three: opcode counts are warmth- and layout-independent.
abstract contract GasMeasure is CommonBase {
    // Engine storage roots and BattleConfig-relative mapping offsets are compiler-layout
    // facts, not production constants. Keep them test-only: the census tests assert the
    // expected reads are non-zero, so a layout change fails loudly instead of silently
    // emitting a misleading zero. See `forge inspect Engine storage-layout`.
    uint256 private constant ENGINE_BATTLE_CONFIG_ROOT = 7;
    uint256 private constant CONFIG_P0_STATES_OFFSET = 9;
    uint256 private constant CONFIG_P1_STATES_OFFSET = 10;
    uint256 private constant CONFIG_P0_EFFECTS_OFFSET = 12;
    uint256 private constant CONFIG_P1_EFFECTS_OFFSET = 13;
    uint256 private constant CONFIG_STEPS_BY_MON_OFFSET = 17;

    struct Tally {
        uint256 totalSload;
        uint256 coldSload; // slot's first touch in the window is this READ
        uint256 warmSload;
        uint256 totalSstore;
        uint256 zToNz; // zero -> nonzero (SSTORE_SET, 20k + cold surcharge)
        uint256 nzToNz; // nonzero -> different nonzero (SSTORE_RESET, 2.9k)
        uint256 nzToZ; // nonzero -> zero (SSTORE_RESET 2.9k; EIP-3529 refund ignored)
        uint256 noop; // value unchanged (~100)
        uint256 coldWriteTouch; // slot's first touch in the window is a WRITE (cold surcharge lands there)
        uint256 extraAccounts; // unique non-precompile accounts beyond the call target (2,600 cold each in prod)
    }

    struct EffectStorageTally {
        uint256 headerReads;
        uint256 dataReads;
        uint256 headerWrites;
        uint256 dataWrites;
    }

    /// @notice Exact accesses to the one-slot packed MonState lanes for one battle config.
    /// @dev The bitmaps use lanes 0..7 for p0 and 8..15 for p1. A write-back frame would load
    ///      each touched lane at most once and commit each written lane at most once.
    struct MonStateStorageTally {
        uint256 reads;
        uint256 writes;
        uint16 readLanes;
        uint16 writtenLanes;
        uint256 uniqueTouchedLanes;
        uint256 uniqueWrittenLanes;
        uint256 frameStorageOps;
        uint256 currentStorageOps;
        uint256 removableStorageOps;
    }

    /// @notice Storage traffic predicted for a lazy frame with legacy flush/invalidate barriers.
    struct MonStateFrameModel {
        uint256 loads;
        uint256 commits;
        uint256 reloadedLanes;
        uint256 dirtyFlushBoundaries;
        uint256 cleanInvalidationBoundaries;
        uint256 modeledStorageOps;
        uint256 removableStorageOps;
    }

    /// @notice Conservative packed-header frame model. Root Engine execution uses a lazy
    ///         memory frame; legacy mechanic callbacks retain their actual storage operations.
    struct PackedHeaderFrameModel {
        uint256 loads;
        uint256 commits;
        uint256 callbackPassthroughOps;
        uint256 reloadedWords;
        uint256 dirtyFlushBoundaries;
        uint256 cleanInvalidationBoundaries;
        uint256 currentStorageOps;
        uint256 modeledStorageOps;
        uint256 removableStorageOps;
    }

    /// @notice Whole-account storage working set for an onchain-kernel ceiling calculation.
    struct StorageWorkingSet {
        uint256 reads;
        uint256 writes;
        uint256 uniqueTouchedSlots;
        uint256 uniqueWrittenSlots;
        uint256 loadCommitFloorOps;
        uint256 removableOps;
    }

    struct CallBoundaryStorageTally {
        uint256 engineRootReads;
        uint256 engineRootWrites;
        uint256 engineCallbackReads;
        uint256 engineCallbackWrites;
        uint256 externalReads;
        uint256 externalWrites;
    }

    uint256 internal constant STORAGE_CATEGORY_COUNT = 9;
    uint8 internal constant STORAGE_OTHER = 0;
    uint8 internal constant STORAGE_SHELL = 1;
    uint8 internal constant STORAGE_BATTLE_DATA = 2;
    uint8 internal constant STORAGE_CONFIG_HEADER = 3;
    uint8 internal constant STORAGE_STATIC_CATALOG = 4;
    uint8 internal constant STORAGE_MON_STATE = 5;
    uint8 internal constant STORAGE_EFFECTS = 6;
    uint8 internal constant STORAGE_BOOSTS = 7;
    uint8 internal constant STORAGE_GLOBAL_KV = 8;

    struct EngineStorageCategoryTally {
        uint256[STORAGE_CATEGORY_COUNT] reads;
        uint256[STORAGE_CATEGORY_COUNT] writes;
        uint256[STORAGE_CATEGORY_COUNT] uniqueTouched;
        uint256[STORAGE_CATEGORY_COUNT] uniqueWritten;
        bytes32 firstOtherSlot;
    }

    /// @dev Classify a state-diff window as ONE transaction: first touch of a slot is cold,
    ///      subsequent touches warm. Call once per prod-tx-equivalent unit (e.g. once per turn)
    ///      so cold/warm reflects a fresh cold-start access list.
    function _tally(Vm.AccountAccess[] memory accesses) internal view returns (Tally memory t) {
        // Size the dedup scratch to the actual access count in THIS window (not a fixed large
        // array), so calling _tally once per turn doesn't blow up cumulative memory across a battle.
        uint256 cap;
        for (uint256 i; i < accesses.length; i++) {
            cap += accesses[i].storageAccesses.length;
        }
        bytes32[] memory keys = new bytes32[](cap);
        uint16[] memory writes = new uint16[](cap);
        bool[] memory reads = new bool[](cap);
        uint256 keyCount;

        // Account dedup: every unique account beyond the window's call target pays a cold-account
        // surcharge in a real tx (the target itself is pre-warmed as tx.to). Precompiles are
        // always warm; the VM/cheatcode address and the test contract are harness artifacts.
        address target = accesses.length > 0 ? accesses[0].account : address(0);
        address[] memory accts = new address[](accesses.length);
        uint256 acctCount;

        for (uint256 i; i < accesses.length; i++) {
            address acct = accesses[i].account;
            if (acct != target && acct != VM_ADDRESS && acct != address(this) && uint160(acct) > 0xff) {
                bool seen;
                for (uint256 k; k < acctCount; k++) {
                    if (accts[k] == acct) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) {
                    accts[acctCount++] = acct;
                    t.extraAccounts++;
                }
            }

            Vm.StorageAccess[] memory sa = accesses[i].storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                Vm.StorageAccess memory a = sa[j];
                bytes32 key = keccak256(abi.encode(a.account, a.slot));
                uint256 idx = keyCount;
                for (uint256 k; k < keyCount; k++) {
                    if (keys[k] == key) {
                        idx = k;
                        break;
                    }
                }
                if (idx == keyCount) {
                    keys[idx] = key;
                    keyCount++;
                }
                if (a.isWrite) {
                    t.totalSstore++;
                    if (!reads[idx] && writes[idx] == 0) {
                        t.coldWriteTouch++;
                    }
                    if (a.previousValue == bytes32(0) && a.newValue != bytes32(0)) {
                        t.zToNz++;
                    } else if (a.previousValue != bytes32(0) && a.newValue == bytes32(0)) {
                        t.nzToZ++;
                    } else if (a.previousValue != a.newValue) {
                        t.nzToNz++;
                    } else {
                        t.noop++;
                    }
                    writes[idx]++;
                } else {
                    t.totalSload++;
                    if (!reads[idx] && writes[idx] == 0) {
                        t.coldSload++;
                        reads[idx] = true;
                    } else {
                        t.warmSload++;
                    }
                }
            }
        }
    }

    function _addTally(Tally memory a, Tally memory b) internal pure returns (Tally memory o) {
        o.totalSload = a.totalSload + b.totalSload;
        o.coldSload = a.coldSload + b.coldSload;
        o.warmSload = a.warmSload + b.warmSload;
        o.totalSstore = a.totalSstore + b.totalSstore;
        o.zToNz = a.zToNz + b.zToNz;
        o.nzToNz = a.nzToNz + b.nzToNz;
        o.nzToZ = a.nzToZ + b.nzToZ;
        o.noop = a.noop + b.noop;
        o.coldWriteTouch = a.coldWriteTouch + b.coldWriteTouch;
        o.extraAccounts = a.extraAccounts + b.extraAccounts;
    }

    /// @notice Count calls matching an exact `(accessor, account, selector)` tuple.
    /// @dev Address zero is a wildcard for either address. Resume records and reverted calls
    ///      are excluded. This operates after the measured bracket, so it cannot perturb gas.
    function _countCalls(Vm.AccountAccess[] memory accesses, address accessor, address account, bytes4 selector)
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < accesses.length; i++) {
            Vm.AccountAccess memory a = accesses[i];
            if (
                !a.reverted && _isCallKind(a.kind) && a.data.length >= 4
                    && (accessor == address(0) || a.accessor == accessor)
                    && (account == address(0) || a.account == account) && bytes4(a.data) == selector
            ) {
                count++;
            }
        }
    }

    /// @notice Count matching ABI calls whose first argument is nonzero.
    /// @dev Used to distinguish continuation calls from initial resolver calls without changing
    ///      production contracts or adding instrumentation to the measured execution path.
    function _countCallsWithNonzeroFirstArg(
        Vm.AccountAccess[] memory accesses,
        address accessor,
        address account,
        bytes4 selector
    ) internal pure returns (uint256 count) {
        for (uint256 i; i < accesses.length; i++) {
            Vm.AccountAccess memory a = accesses[i];
            if (
                !a.reverted && _isCallKind(a.kind) && a.data.length >= 36
                    && (accessor == address(0) || a.accessor == accessor)
                    && (account == address(0) || a.account == account) && bytes4(a.data) == selector
            ) {
                uint256 firstArg;
                bytes memory data = a.data;
                assembly ("memory-safe") {
                    firstArg := mload(add(data, 36))
                }
                if (firstArg != 0) {
                    count++;
                }
            }
        }
    }

    function _isCallKind(VmSafe.AccountAccessKind kind) private pure returns (bool) {
        return kind == VmSafe.AccountAccessKind.Call || kind == VmSafe.AccountAccessKind.StaticCall
            || kind == VmSafe.AccountAccessKind.DelegateCall || kind == VmSafe.AccountAccessKind.CallCode;
    }

    /// @notice Count reads/writes to player EffectInstance header/data slots for one Engine
    ///         storage key. Player effect arrays are mappings at BattleConfig offsets 12/13;
    ///         each EffectInstance occupies two consecutive slots.
    function _effectStorageTally(Vm.AccountAccess[] memory accesses, address engine, bytes32 storageKey)
        internal
        pure
        returns (EffectStorageTally memory t)
    {
        bytes32 configBase = keccak256(abi.encode(storageKey, ENGINE_BATTLE_CONFIG_ROOT));
        bytes32 p0Root = bytes32(uint256(configBase) + CONFIG_P0_EFFECTS_OFFSET);
        bytes32 p1Root = bytes32(uint256(configBase) + CONFIG_P1_EFFECTS_OFFSET);
        (bytes32[] memory slotKeys, uint8[] memory slotKinds) = _buildPlayerEffectSlotTable(p0Root, p1Root);

        for (uint256 i; i < accesses.length; i++) {
            Vm.StorageAccess[] memory sa = accesses[i].storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                Vm.StorageAccess memory a = sa[j];
                if (a.account != engine || a.reverted) {
                    continue;
                }
                uint256 kind = _playerEffectSlotKind(a.slot, slotKeys, slotKinds);
                if (kind == 1) {
                    if (a.isWrite) {
                        t.headerWrites++;
                    } else {
                        t.headerReads++;
                    }
                } else if (kind == 2) {
                    if (a.isWrite) {
                        t.dataWrites++;
                    } else {
                        t.dataReads++;
                    }
                }
            }
        }
    }

    /// @notice Count reads/writes to the 16 possible packed MonState slots for one Engine config.
    function _monStateStorageTally(Vm.AccountAccess[] memory accesses, address engine, bytes32 storageKey)
        internal
        pure
        returns (MonStateStorageTally memory t)
    {
        bytes32 configBase = keccak256(abi.encode(storageKey, ENGINE_BATTLE_CONFIG_ROOT));
        bytes32 p0Root = bytes32(uint256(configBase) + CONFIG_P0_STATES_OFFSET);
        bytes32 p1Root = bytes32(uint256(configBase) + CONFIG_P1_STATES_OFFSET);
        bytes32[16] memory laneSlots;
        for (uint256 mon; mon < 8; mon++) {
            laneSlots[mon] = keccak256(abi.encode(mon, p0Root));
            laneSlots[8 + mon] = keccak256(abi.encode(mon, p1Root));
        }

        for (uint256 i; i < accesses.length; i++) {
            Vm.StorageAccess[] memory sa = accesses[i].storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                Vm.StorageAccess memory a = sa[j];
                if (a.account != engine || a.reverted) {
                    continue;
                }
                for (uint256 lane; lane < 16; lane++) {
                    if (a.slot == laneSlots[lane]) {
                        uint16 laneBit = uint16(1 << lane);
                        if (a.isWrite) {
                            t.writes++;
                            t.writtenLanes |= laneBit;
                        } else {
                            t.reads++;
                            t.readLanes |= laneBit;
                        }
                        break;
                    }
                }
            }
        }

        t.uniqueTouchedLanes = _popcount16(t.readLanes | t.writtenLanes);
        t.uniqueWrittenLanes = _popcount16(t.writtenLanes);
        t.currentStorageOps = t.reads + t.writes;
        t.frameStorageOps = t.uniqueTouchedLanes + t.uniqueWrittenLanes;
        t.removableStorageOps = t.currentStorageOps > t.frameStorageOps ? t.currentStorageOps - t.frameStorageOps : 0;
    }

    /// @notice Count one account's exact storage working set in the recorded transaction.
    /// @dev `loadCommitFloorOps` models loading each touched slot once and committing each written
    ///      slot once. It is an architectural ceiling: static catalog and shell slots cannot all be
    ///      collapsed into a mutable kernel state, but the result bounds the available storage win.
    function _storageWorkingSet(Vm.AccountAccess[] memory accesses, address account)
        internal
        pure
        returns (StorageWorkingSet memory w)
    {
        uint256 accessCount;
        for (uint256 i; i < accesses.length; i++) {
            Vm.StorageAccess[] memory sa = accesses[i].storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                if (sa[j].account == account && !sa[j].reverted) {
                    accessCount++;
                }
            }
        }
        uint256 cap = 1;
        while (cap < accessCount * 2 + 1) {
            cap <<= 1;
        }
        bytes32[] memory slots = new bytes32[](cap);
        bool[] memory occupied = new bool[](cap);
        bool[] memory written = new bool[](cap);
        uint256 mask = cap - 1;

        for (uint256 i; i < accesses.length; i++) {
            Vm.StorageAccess[] memory sa = accesses[i].storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                Vm.StorageAccess memory a = sa[j];
                if (a.account != account || a.reverted) {
                    continue;
                }
                if (a.isWrite) {
                    w.writes++;
                } else {
                    w.reads++;
                }
                uint256 idx = uint256(a.slot) & mask;
                while (occupied[idx] && slots[idx] != a.slot) {
                    idx = (idx + 1) & mask;
                }
                if (!occupied[idx]) {
                    occupied[idx] = true;
                    slots[idx] = a.slot;
                    w.uniqueTouchedSlots++;
                }
                if (a.isWrite && !written[idx]) {
                    written[idx] = true;
                    w.uniqueWrittenSlots++;
                }
            }
        }
        w.loadCommitFloorOps = w.uniqueTouchedSlots + w.uniqueWrittenSlots;
        uint256 currentOps = w.reads + w.writes;
        w.removableOps = currentOps > w.loadCommitFloorOps ? currentOps - w.loadCommitFloorOps : 0;
    }

    /// @notice Split recorded storage operations between the root Engine frame, reentrant Engine
    ///      callback frames entered by mechanics, and mechanic-owned storage.
    function _callBoundaryStorageTally(Vm.AccountAccess[] memory accesses, address engine, address rootCaller)
        internal
        pure
        returns (CallBoundaryStorageTally memory t)
    {
        for (uint256 i; i < accesses.length; i++) {
            Vm.AccountAccess memory frame = accesses[i];
            Vm.StorageAccess[] memory sa = frame.storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                Vm.StorageAccess memory a = sa[j];
                if (a.reverted) {
                    continue;
                }
                if (a.account == engine) {
                    bool callbackFrame = frame.accessor != rootCaller && frame.accessor != engine;
                    if (callbackFrame) {
                        if (a.isWrite) {
                            t.engineCallbackWrites++;
                        } else {
                            t.engineCallbackReads++;
                        }
                    } else {
                        if (a.isWrite) {
                            t.engineRootWrites++;
                        } else {
                            t.engineRootReads++;
                        }
                    }
                } else if (uint160(a.account) > 0xff) {
                    if (a.isWrite) {
                        t.externalWrites++;
                    } else {
                        t.externalReads++;
                    }
                }
            }
        }
    }

    /// @notice Classify the Engine storage working set into kernel-state and shell/static families.
    function _engineStorageCategoryTally(
        Vm.AccountAccess[] memory accesses,
        address engine,
        bytes32 battleKey,
        bytes32 storageKey
    ) internal pure returns (EngineStorageCategoryTally memory t) {
        uint256 cap = 8192;
        bytes32[] memory slots = new bytes32[](cap);
        uint8[] memory categories = new uint8[](cap);
        bool[] memory occupied = new bool[](cap);
        bool[] memory seen = new bool[](cap);
        bool[] memory writtenSeen = new bool[](cap);

        _insertStorageCategory(slots, categories, occupied, bytes32(uint256(1)), STORAGE_SHELL);
        _insertStorageCategory(slots, categories, occupied, keccak256(abi.encode(battleKey, uint256(2))), STORAGE_SHELL);
        for (uint256 i; i < 16; i++) {
            _insertStorageCategory(slots, categories, occupied, keccak256(abi.encode(i, uint256(0))), STORAGE_SHELL);
        }

        bytes32 battleBase = keccak256(abi.encode(battleKey, uint256(5)));
        _insertStorageCategory(slots, categories, occupied, battleBase, STORAGE_BATTLE_DATA);
        _insertStorageCategory(slots, categories, occupied, bytes32(uint256(battleBase) + 1), STORAGE_BATTLE_DATA);
        bytes32 multiBase = keccak256(abi.encode(battleKey, uint256(6)));
        _insertStorageCategory(slots, categories, occupied, multiBase, STORAGE_BATTLE_DATA);
        _insertStorageCategory(slots, categories, occupied, bytes32(uint256(multiBase) + 1), STORAGE_BATTLE_DATA);

        bytes32 configBase = keccak256(abi.encode(storageKey, ENGINE_BATTLE_CONFIG_ROOT));
        for (uint256 offset; offset <= 5; offset++) {
            _insertStorageCategory(
                slots, categories, occupied, bytes32(uint256(configBase) + offset), STORAGE_CONFIG_HEADER
            );
        }
        _insertStorageCategory(
            slots,
            categories,
            occupied,
            bytes32(uint256(configBase) + CONFIG_STEPS_BY_MON_OFFSET),
            STORAGE_CONFIG_HEADER
        );
        _insertStorageCategory(slots, categories, occupied, bytes32(uint256(configBase) + 6), STORAGE_STATIC_CATALOG);

        _insertTeamAndStateCategories(slots, categories, occupied, configBase);
        _insertEffectCategories(slots, categories, occupied, configBase);
        _insertBoostCategories(slots, categories, occupied, configBase);
        _insertGlobalKVCategories(slots, categories, occupied, accesses, engine, storageKey);

        uint256 mask = cap - 1;
        for (uint256 i; i < accesses.length; i++) {
            Vm.StorageAccess[] memory sa = accesses[i].storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                Vm.StorageAccess memory a = sa[j];
                if (a.account != engine || a.reverted) {
                    continue;
                }
                uint256 idx = uint256(a.slot) & mask;
                while (occupied[idx] && slots[idx] != a.slot) {
                    idx = (idx + 1) & mask;
                }
                if (!occupied[idx]) {
                    occupied[idx] = true;
                    slots[idx] = a.slot;
                    categories[idx] = STORAGE_OTHER;
                }
                uint256 category = categories[idx];
                if (category == STORAGE_OTHER && t.firstOtherSlot == bytes32(0)) {
                    t.firstOtherSlot = a.slot;
                }
                if (a.isWrite) {
                    t.writes[category]++;
                } else {
                    t.reads[category]++;
                }
                if (!seen[idx]) {
                    seen[idx] = true;
                    t.uniqueTouched[category]++;
                }
                if (a.isWrite && !writtenSeen[idx]) {
                    writtenSeen[idx] = true;
                    t.uniqueWritten[category]++;
                }
            }
        }
    }

    function _insertTeamAndStateCategories(
        bytes32[] memory slots,
        uint8[] memory categories,
        bool[] memory occupied,
        bytes32 configBase
    ) private pure {
        bytes32 p0TeamRoot = bytes32(uint256(configBase) + 7);
        bytes32 p1TeamRoot = bytes32(uint256(configBase) + 8);
        bytes32 p0StateRoot = bytes32(uint256(configBase) + CONFIG_P0_STATES_OFFSET);
        bytes32 p1StateRoot = bytes32(uint256(configBase) + CONFIG_P1_STATES_OFFSET);
        for (uint256 mon; mon < 8; mon++) {
            bytes32 p0Mon = keccak256(abi.encode(mon, p0TeamRoot));
            bytes32 p1Mon = keccak256(abi.encode(mon, p1TeamRoot));
            for (uint256 word; word < 6; word++) {
                _insertStorageCategory(
                    slots, categories, occupied, bytes32(uint256(p0Mon) + word), STORAGE_STATIC_CATALOG
                );
                _insertStorageCategory(
                    slots, categories, occupied, bytes32(uint256(p1Mon) + word), STORAGE_STATIC_CATALOG
                );
            }
            _insertStorageCategory(
                slots, categories, occupied, keccak256(abi.encode(mon, p0StateRoot)), STORAGE_MON_STATE
            );
            _insertStorageCategory(
                slots, categories, occupied, keccak256(abi.encode(mon, p1StateRoot)), STORAGE_MON_STATE
            );
        }
    }

    function _insertEffectCategories(
        bytes32[] memory slots,
        uint8[] memory categories,
        bool[] memory occupied,
        bytes32 configBase
    ) private pure {
        bytes32 globalRoot = bytes32(uint256(configBase) + 11);
        bytes32 p0Root = bytes32(uint256(configBase) + CONFIG_P0_EFFECTS_OFFSET);
        bytes32 p1Root = bytes32(uint256(configBase) + CONFIG_P1_EFFECTS_OFFSET);
        for (uint256 i; i < 256; i++) {
            bytes32 header = keccak256(abi.encode(i, globalRoot));
            _insertStorageCategory(slots, categories, occupied, header, STORAGE_EFFECTS);
            _insertStorageCategory(slots, categories, occupied, bytes32(uint256(header) + 1), STORAGE_EFFECTS);
        }
        uint256 playerSlots = 8 * EFFECT_SLOTS_PER_MON;
        for (uint256 i; i < playerSlots; i++) {
            bytes32 p0Header = keccak256(abi.encode(i, p0Root));
            bytes32 p1Header = keccak256(abi.encode(i, p1Root));
            _insertStorageCategory(slots, categories, occupied, p0Header, STORAGE_EFFECTS);
            _insertStorageCategory(slots, categories, occupied, bytes32(uint256(p0Header) + 1), STORAGE_EFFECTS);
            _insertStorageCategory(slots, categories, occupied, p1Header, STORAGE_EFFECTS);
            _insertStorageCategory(slots, categories, occupied, bytes32(uint256(p1Header) + 1), STORAGE_EFFECTS);
        }
        bytes32 hookRoot = bytes32(uint256(configBase) + 14);
        for (uint256 i; i < 256; i++) {
            _insertStorageCategory(slots, categories, occupied, keccak256(abi.encode(i, hookRoot)), STORAGE_EFFECTS);
        }
    }

    function _insertBoostCategories(
        bytes32[] memory slots,
        uint8[] memory categories,
        bool[] memory occupied,
        bytes32 configBase
    ) private pure {
        bytes32 p0Root = bytes32(uint256(configBase) + 15);
        bytes32 p1Root = bytes32(uint256(configBase) + 16);
        for (uint256 i; i < 8 * 16; i++) {
            _insertStorageCategory(slots, categories, occupied, keccak256(abi.encode(i, p0Root)), STORAGE_BOOSTS);
            _insertStorageCategory(slots, categories, occupied, keccak256(abi.encode(i, p1Root)), STORAGE_BOOSTS);
        }
    }

    function _insertGlobalKVCategories(
        bytes32[] memory slots,
        uint8[] memory categories,
        bool[] memory occupied,
        Vm.AccountAccess[] memory accesses,
        address engine,
        bytes32 storageKey
    ) private pure {
        bytes32 valuesRoot = keccak256(abi.encode(storageKey, uint256(8)));
        bytes32 keysRoot = keccak256(abi.encode(storageKey, uint256(9)));
        bytes32[16] memory keySlots;
        for (uint256 i; i < 16; i++) {
            keySlots[i] = keccak256(abi.encode(i, keysRoot));
            _insertStorageCategory(slots, categories, occupied, keySlots[i], STORAGE_GLOBAL_KV);
        }
        // Zero-valued probes are deliberately absent from globalKVKeySlots. Decode the getter's
        // key argument so those read-only value slots are still categorized exactly.
        bytes4 getGlobalKVSelector = bytes4(keccak256("getGlobalKV(bytes32,uint64)"));
        for (uint256 i; i < accesses.length; i++) {
            Vm.AccountAccess memory frame = accesses[i];
            if (frame.account != engine || frame.data.length < 68 || bytes4(frame.data) != getGlobalKVSelector) {
                continue;
            }
            uint256 rawKey;
            bytes memory data = frame.data;
            assembly ("memory-safe") {
                rawKey := mload(add(data, 68))
            }
            _insertStorageCategory(
                slots, categories, occupied, keccak256(abi.encode(uint64(rawKey), valuesRoot)), STORAGE_GLOBAL_KV
            );
        }
        for (uint256 i; i < accesses.length; i++) {
            Vm.StorageAccess[] memory sa = accesses[i].storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                Vm.StorageAccess memory a = sa[j];
                if (a.account != engine || a.reverted) {
                    continue;
                }
                for (uint256 k; k < keySlots.length; k++) {
                    if (a.slot != keySlots[k]) {
                        continue;
                    }
                    _insertPackedGlobalKeys(slots, categories, occupied, valuesRoot, uint256(a.previousValue));
                    _insertPackedGlobalKeys(slots, categories, occupied, valuesRoot, uint256(a.newValue));
                    break;
                }
            }
        }
    }

    function _insertPackedGlobalKeys(
        bytes32[] memory slots,
        uint8[] memory categories,
        bool[] memory occupied,
        bytes32 valuesRoot,
        uint256 packed
    ) private pure {
        for (uint256 lane; lane < 4; lane++) {
            uint64 key = uint64(packed >> (lane * 64));
            _insertStorageCategory(
                slots, categories, occupied, keccak256(abi.encode(key, valuesRoot)), STORAGE_GLOBAL_KV
            );
        }
    }

    function _insertStorageCategory(
        bytes32[] memory slots,
        uint8[] memory categories,
        bool[] memory occupied,
        bytes32 slot,
        uint8 category
    ) private pure {
        uint256 mask = slots.length - 1;
        uint256 idx = uint256(slot) & mask;
        while (occupied[idx] && slots[idx] != slot) {
            idx = (idx + 1) & mask;
        }
        if (!occupied[idx]) {
            occupied[idx] = true;
            slots[idx] = slot;
            categories[idx] = category;
        }
    }

    /// @notice Replay the recorded access order through a lazy write-back frame model.
    /// @dev Before every legacy mechanic call, dirty lanes are committed and all loaded lanes are
    ///      invalidated. Resolver calls are deliberately absent from `boundarySelectors` and retain
    ///      the frame. This remains test-only and does not perturb the measured Engine path.
    function _monStateFrameModel(
        Vm.AccountAccess[] memory accesses,
        address engine,
        bytes32 storageKey,
        bytes4[] memory boundarySelectors
    ) internal pure returns (MonStateFrameModel memory m) {
        bytes32 configBase = keccak256(abi.encode(storageKey, ENGINE_BATTLE_CONFIG_ROOT));
        bytes32 p0Root = bytes32(uint256(configBase) + CONFIG_P0_STATES_OFFSET);
        bytes32 p1Root = bytes32(uint256(configBase) + CONFIG_P1_STATES_OFFSET);
        bytes32[16] memory laneSlots;
        for (uint256 mon; mon < 8; mon++) {
            laneSlots[mon] = keccak256(abi.encode(mon, p0Root));
            laneSlots[8 + mon] = keccak256(abi.encode(mon, p1Root));
        }

        uint16 loaded;
        uint16 dirty;
        uint16 everLoaded;
        uint256 currentStorageOps;
        for (uint256 i; i < accesses.length; i++) {
            Vm.AccountAccess memory accountAccess = accesses[i];
            if (_isLegacyBoundary(accountAccess, engine, boundarySelectors)) {
                if (dirty != 0) {
                    m.commits += _popcount16(dirty);
                    m.dirtyFlushBoundaries++;
                } else {
                    m.cleanInvalidationBoundaries++;
                }
                loaded = 0;
                dirty = 0;
            }

            Vm.StorageAccess[] memory sa = accountAccess.storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                Vm.StorageAccess memory a = sa[j];
                if (a.account != engine || a.reverted) {
                    continue;
                }
                for (uint256 lane; lane < 16; lane++) {
                    if (a.slot == laneSlots[lane]) {
                        uint16 laneBit = uint16(1 << lane);
                        currentStorageOps++;
                        if (loaded & laneBit == 0) {
                            m.loads++;
                            if (everLoaded & laneBit != 0) {
                                m.reloadedLanes++;
                            }
                            loaded |= laneBit;
                            everLoaded |= laneBit;
                        }
                        if (a.isWrite) {
                            dirty |= laneBit;
                        }
                        break;
                    }
                }
            }
        }
        if (dirty != 0) {
            m.commits += _popcount16(dirty);
        }
        m.modeledStorageOps = m.loads + m.commits;
        m.removableStorageOps = currentStorageOps > m.modeledStorageOps ? currentStorageOps - m.modeledStorageOps : 0;
    }

    /// @notice Model a lazy memory frame for the two BattleData words and seven direct
    ///         BattleConfig header words (offsets 0..5 and 18).
    /// @dev Legacy external mechanics are barriers: dirty root words flush before the call, root
    ///      words invalidate, and Engine storage touched by callback frames remains passthrough.
    ///      Resolver calls are deliberately not barriers.
    function _packedHeaderFrameModel(
        Vm.AccountAccess[] memory accesses,
        address engine,
        address rootCaller,
        bytes32 battleKey,
        bytes32 storageKey,
        bytes4[] memory boundarySelectors
    ) internal pure returns (PackedHeaderFrameModel memory m) {
        bytes32 battleBase = keccak256(abi.encode(battleKey, uint256(5)));
        bytes32 configBase = keccak256(abi.encode(storageKey, ENGINE_BATTLE_CONFIG_ROOT));
        bytes32[9] memory headerSlots;
        headerSlots[0] = battleBase;
        headerSlots[1] = bytes32(uint256(battleBase) + 1);
        for (uint256 offset; offset <= 5; offset++) {
            headerSlots[2 + offset] = bytes32(uint256(configBase) + offset);
        }
        headerSlots[8] = bytes32(uint256(configBase) + CONFIG_STEPS_BY_MON_OFFSET);

        uint16 loaded;
        uint16 dirty;
        uint16 everLoaded;
        for (uint256 i; i < accesses.length; i++) {
            Vm.AccountAccess memory frame = accesses[i];
            if (_isLegacyBoundary(frame, engine, boundarySelectors)) {
                if (dirty != 0) {
                    m.commits += _popcount16(dirty);
                    m.dirtyFlushBoundaries++;
                } else {
                    m.cleanInvalidationBoundaries++;
                }
                loaded = 0;
                dirty = 0;
            }

            bool callbackFrame = frame.accessor != rootCaller && frame.accessor != engine;
            Vm.StorageAccess[] memory sa = frame.storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                Vm.StorageAccess memory a = sa[j];
                if (a.account != engine || a.reverted) {
                    continue;
                }
                for (uint256 word; word < headerSlots.length; word++) {
                    if (a.slot != headerSlots[word]) {
                        continue;
                    }
                    m.currentStorageOps++;
                    if (callbackFrame) {
                        m.callbackPassthroughOps++;
                        break;
                    }
                    uint16 wordBit = uint16(1 << word);
                    if (loaded & wordBit == 0) {
                        m.loads++;
                        if (everLoaded & wordBit != 0) {
                            m.reloadedWords++;
                        }
                        loaded |= wordBit;
                        everLoaded |= wordBit;
                    }
                    if (a.isWrite) {
                        dirty |= wordBit;
                    }
                    break;
                }
            }
        }
        if (dirty != 0) {
            m.commits += _popcount16(dirty);
        }
        m.modeledStorageOps = m.loads + m.commits + m.callbackPassthroughOps;
        m.removableStorageOps =
            m.currentStorageOps > m.modeledStorageOps ? m.currentStorageOps - m.modeledStorageOps : 0;
    }

    function _isLegacyBoundary(Vm.AccountAccess memory a, address engine, bytes4[] memory selectors)
        private
        pure
        returns (bool)
    {
        if (a.reverted || !_isCallKind(a.kind) || a.accessor != engine || a.data.length < 4) {
            return false;
        }
        bytes4 selector = bytes4(a.data);
        for (uint256 i; i < selectors.length; i++) {
            if (selector == selectors[i]) {
                return true;
            }
        }
        return false;
    }

    function _popcount16(uint16 value) private pure returns (uint256 count) {
        while (value != 0) {
            value &= value - 1;
            count++;
        }
    }

    /// @dev Precompute the player EffectInstance header/data slots for O(1) census lookup.
    function _buildPlayerEffectSlotTable(bytes32 p0Root, bytes32 p1Root)
        private
        pure
        returns (bytes32[] memory keys, uint8[] memory kinds)
    {
        // 8 mons/side, 64 stable effect indices per mon. The mapping key is already the
        // flattened `monIndex * EFFECT_SLOTS_PER_MON + effectIndex` value. A 4096-entry
        // open-addressed table stays at 50% load for the 2048 header+data slots.
        keys = new bytes32[](4096);
        kinds = new uint8[](4096);
        uint256 slotsPerSide = 8 * EFFECT_SLOTS_PER_MON;
        for (uint256 i; i < slotsPerSide; i++) {
            bytes32 p0Header = keccak256(abi.encode(i, p0Root));
            bytes32 p1Header = keccak256(abi.encode(i, p1Root));
            _insertEffectSlot(keys, kinds, p0Header, 1);
            _insertEffectSlot(keys, kinds, bytes32(uint256(p0Header) + 1), 2);
            _insertEffectSlot(keys, kinds, p1Header, 1);
            _insertEffectSlot(keys, kinds, bytes32(uint256(p1Header) + 1), 2);
        }
    }

    function _insertEffectSlot(bytes32[] memory keys, uint8[] memory kinds, bytes32 key, uint8 kind) private pure {
        uint256 mask = keys.length - 1;
        uint256 i = uint256(key) & mask;
        while (kinds[i] != 0) {
            i = (i + 1) & mask;
        }
        keys[i] = key;
        kinds[i] = kind;
    }

    /// @return kind 0 = unrelated, 1 = EffectInstance header, 2 = EffectInstance data.
    function _playerEffectSlotKind(bytes32 slot, bytes32[] memory keys, uint8[] memory kinds)
        private
        pure
        returns (uint256 kind)
    {
        uint256 mask = keys.length - 1;
        uint256 i = uint256(slot) & mask;
        while (kinds[i] != 0) {
            if (keys[i] == slot) {
                return kinds[i];
            }
            i = (i + 1) & mask;
        }
        return 0;
    }

    /// @notice Conservative production storage+account cost for a window, priced from the tally
    ///         as if the window were ONE fresh production transaction. Assumptions, all chosen so
    ///         a code change's benefit is never overstated:
    ///         - tx.to is pre-warm (like a prod tx); every other touched account pays one 2,600
    ///           cold-account surcharge;
    ///         - the 2,100 cold-slot surcharge is charged once per slot regardless of whether its
    ///           first touch is a read or a write — so eliminating a REDUNDANT access to a slot
    ///           the window still touches elsewhere is credited at warm (100), not cold (2,100);
    ///         - EIP-3529 refunds are ignored (clears price at full 2,900);
    ///         - tx intrinsic (21k) + calldata are excluded (constant across code versions);
    ///         - compute/memory/event gas is excluded — use the measured scalar for
    ///           compute-shaped changes; this metric is the guard for storage-shaped ones.
    function _prodStorageGas(Tally memory t) internal pure returns (uint256 g) {
        g = t.coldSload * 2100 + (t.totalSload - t.coldSload) * 100;
        g += t.coldWriteTouch * 2100;
        g += t.zToNz * 20000 + (t.nzToNz + t.nzToZ) * 2900 + t.noop * 100;
        g += t.extraAccounts * 2600;
    }

    /// @dev Cool every listed account's storage (resets the EIP-2929 access list to cold), so the
    ///      next access pays cold prices — modeling a fresh production transaction. NOTE: measured
    ///      on forge 1.5.1 this re-prices slots but NOT the account access itself; treat the
    ///      resulting scalar as directional and `prodStorageGas` as the grounded number.
    function _coolAll(address[] memory addrs) internal {
        for (uint256 i; i < addrs.length; i++) {
            vm.cool(addrs[i]);
        }
    }

    /// @notice Snapshot one scenario: the deterministic access tally, the conservative synthetic
    ///         production storage cost, and the measured (directional) cold-per-tx gas scalar.
    function _snapScenario(string memory name, Tally memory t, uint256 coldGas) internal {
        vm.snapshotValue(string.concat(name, "_prodStorageGas"), _prodStorageGas(t));
        vm.snapshotValue(string.concat(name, "_coldGas"), coldGas);
        vm.snapshotValue(string.concat(name, "_totalSload"), t.totalSload);
        vm.snapshotValue(string.concat(name, "_coldSload"), t.coldSload);
        vm.snapshotValue(string.concat(name, "_totalSstore"), t.totalSstore);
        vm.snapshotValue(string.concat(name, "_zToNz"), t.zToNz);
        vm.snapshotValue(string.concat(name, "_nzToNz"), t.nzToNz);
        vm.snapshotValue(string.concat(name, "_noop"), t.noop);
        vm.snapshotValue(string.concat(name, "_extraAccounts"), t.extraAccounts);
    }
}
