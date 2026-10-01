# PvPad contracts

This contribution delivers the contract stage for the permissionless PvPad launchpad from [the approved source at 13cd1131e20024899e0f0943722cab01ad87ff38](https://github.com/identity-md-launches/launch-565-workflow-contract-stage-context/tree/13cd1131e20024899e0f0943722cab01ad87ff38). The frozen product requirements are in [SPEC.md](SPEC.md). It includes the pinned contracts, genesis-poison recovery and tick-grief defenses, local tests, vendored dependencies and [ABI exports and integration notes](docs/ABI.md). The separate manifest assignment produces `launch.json`; independent review, source publication, attestation, policy admission, Sepolia deployment and the `pvpad` frontend follow this source contribution.

## Build and verify

```sh
forge build
forge test
forge fmt --check
python3 tools/export_abis.py
python3 tools/export_abis.py --check
```

Foundry pins Solidity **0.8.26**, Cancun, optimizer 200, and `bytecode_hash = "none"`. The verifier supplies the compiler. Every imported Solidity dependency is an ordinary file under `lib/`, with revisions in [DEPENDENCIES.json](DEPENDENCIES.json); no installation, submodule, network, FFI, environment variables, or filesystem cheatcodes are needed by the tests. Tests use the actual vendored Uniswap v4 PoolManager locally, not a fork or a funded wallet.

## Economics and lifecycle

| Parameter | Behavior |
| --- | --- |
| Each pad token | 1 billion tokens, 18 decimals, fixed supply; full supply transferred atomically to its curve |
| Genesis | Launch 0, Pepe Values Pepe / PVP, created without a fee in the factory constructor |
| Later launches | Permissionless; exact `0.0005 ETH` create fee goes entirely to WorkerSubsidy |
| Curve and pool fees | 1% of the native ETH leg; half to current king beneficiary, half to creator; odd fee wei to creator |
| Graduation | Permissionless at exactly `4.2 ETH` net curve reserves |
| Graduated pool | Native ETH/token, fee tier 0, tick spacing 60; shared hook charges pad fee |
| LP | Full range; the hook closes the pool to all other liquidity until graduation; permanently factory-owned with no withdrawal |
| King | Bid strictly greater than claim price; starts `0.01 ETH`, price increases 10% per claim; entire bid to workers, no previous-king refund |
| Before first king | King share belongs to the first beneficiary, even if claimed after later crowns |

The factory supports multiple independent launches, creator metadata, curve trading, progress, and graduation. `createLaunch` accepts token name and symbol, with an optional caller-selected salt and immutable metadata URI (up to 2048 bytes for JSON image/social references). Genesis has an empty URI. Names/symbols are display strings, not unique identifiers; use factory address plus launch ID. Token contracts are plain ERC-20s with no mint/admin/fee/upgrade path after construction. Third parties can create their own markets for freely transferable tokens; the pad's canonical pool is the one whose swaps are gated until graduation.

**Identify launches only through the factory**, never through the hook. The hook is shared and `bindPool` authenticates a binding against the token's and the escrow's own `factory()` answers, so any contract can deploy a PvPadToken whose factory is itself, act as its own escrow and registry, bind a canonical-shaped pool to the official hook and collect that pool's 1% fee for itself. Such a pool cannot touch a real launch (a real escrow answers the real factory, bindings and deferred balances are keyed per pool and escrow, and the hook's reentrancy guard blocks a spoof escrow from re-entering a real swap), but `pool.hooks == PvPadHook`, `PoolBound` events and `isRegisteredPool` answers from an unknown registry are not evidence of a PvPad launch. Frontends and indexers must start from `PvPadFactory.launches(id)`, `LaunchCreated` and the factory's `registeredPool`/`getPoolKey(id)`, and use only pool keys obtained that way.

Curve trades support minimum output and deadline parameters. Integrators should use those protected overloads, quote immediately before signing, and display refunded excess input at the threshold. Neither a curve nor the factory accepts plain ETH transfers: the curve has no `receive()` (ETH enters only through `buy`), and the factory's `receive()` admits only a registered curve's graduation sweep (`NotBondingCurve` otherwise), so a mistaken transfer is refunded by the revert instead of being locked forever. Token transfers cannot be refused; donated tokens are not counted as curve reserves, do not accelerate graduation, and stay unrecoverable in the curve.

### Curve formula and graduation

Let `S = 10^27` token units, virtual tokens `Vt = S/8`, virtual ETH `Ve = 2.1 ETH`, and real reserves `(T,E)`, initially `(S,0)`. Constant-product pricing uses `(T + Vt) * (E + Ve)`. Buys charge a fee from accepted gross ETH input; sells charge a fee from gross ETH output. Output rounds down to protect reserves. Buys cap net reserves at `4.2 ETH` and refund unused ETH; sells cannot spend phantom reserves. Repeated rounding can leave small token dust.

At the target reserve, the theoretical real token reserve is `S/4`. Thus the curve's terminal marginal price equals the pool reserve price, `(4.2 ETH)/(S/4)`. The factory fixes this pool initialization price and deposits as much of both reserves as the selected liquidity range can consume. Remainders stay locked in the factory. Both buys and sells stop once accounted reserves reach the threshold, so a dust sell cannot invalidate a pending permissionless graduation. Sell quotes return zero in that state. A failed PoolManager interaction rolls back the sweep and all graduation state; anyone can retry, while curve trading remains closed at the threshold.

Graduation deposits the full-range ticks `[-887220,887220]`. The shared hook's `beforeAddLiquidity` callback keeps every canonical pool **closed to liquidity until graduation**: the PoolManager only accepts a deposit whose caller is the bound factory (the graduation deposit itself) or whose pool the factory has already registered as graduated. Any other pre-graduation deposit reverts `LiquidityClosed`, so nobody can saturate a boundary tick's liquidity cap for dust and force a `TickLiquidityOverflow` or a narrower range. After graduation anyone may add and remove their own positions; the factory's position has no removal path. Pools that name this hook but were never bound by a factory (for example a different fee tier) never open.

The inward-moving boundary scan from the previous revision remains as defense in depth: if a boundary tick were somehow saturated, the factory still moves only that boundary inward by tick spacing 60, keeps the canonical price strictly inside, records `lockedTickLower`/`lockedTickUpper` and emits `LiquidityRangeLocked` (salt is `bytes32(launchId)`), or reverts `LiquidityRangeUnavailable` atomically. With the hook gate in place this path is unreachable through the PoolManager and every launch locks the full range.

The canonical pool is initialized atomically during creation, with swaps disabled until graduation. Because the required shared hook has **no beforeInitialize**, someone who predicts a future token address can preinitialize its pool at a foreign price. `createLaunch` scans up to `MAX_SALT_ATTEMPTS` (16) salt derivations: attempt 0 is the original `keccak256(abi.encode(launchId, creator, name, symbol, userSalt))`, later attempts append the attempt index. A predicted pool that is uninitialized or already at the canonical price is used; a poisoned one is skipped and `LaunchSaltRetried(launchId, attempt, token)` is emitted. Genesis construction uses the same scan. `predictLaunchToken(creator, name, symbol, userSalt)` returns the token address and attempt the next create would use so frontends can display it.

If every bounded candidate is poisoned the create no longer fails: the first candidate is used, the factory binds its pool and then calls `PvPadHook.realignPool(key, canonicalSqrtPriceX96)`, which moves the empty pool back to the canonical price and emits `PoolRealigned`; the factory re-reads the price (the hard stop `UnexpectedPoolPrice` remains) and emits `LaunchPoolRealigned(launchId, foreignSqrtPriceX96)`. This closes the one case the bounded scan could not: the 16 genesis candidates are a pure function of the future factory address, so an attacker who preinitialized all of them (about 0.95M gas) used to make the factory constructor revert on every retry at that address. `test/GenesisPoison.t.sol` is the deployability proof for exactly that case: a service-style CREATE2 deployer announces the factory address, an attacker poisons all 16 genesis candidates at foreign prices (fixed and fuzzed, both sides of canonical), and the factory still deploys at the predicted address with genesis on candidate 0 at the canonical price, zero liquidity, nothing moved, and the siblings left at the attacker's price; a realignment that fails to land on the canonical price aborts the deploy without consuming the CREATE2 address. Realignment is a Uniswap v4 swap by the hook against a pool with zero liquidity: it changes only the stored price, transfers no ETH or tokens, and the PoolManager skips the hook's own callbacks because the hook is the caller. It is restricted to the bound factory, refused unless the pool is initialized at a different price (`NothingToRealign`), refused if the pool has active liquidity (`PoolHasLiquidity`), and the callback reverts `RealignFailed` if the swap delta is not exactly zero. During canonical launch creation the liquidity gate guarantees that the selected pool has no positions. The factory only calls realignment in that creation path and exposes no method to realign a graduated pool. Active liquidity alone is not a proof that no positions exist: a position can become inactive when price leaves its tick range. Realignment never calls back into the factory, so constructor-created genesis can use it. Poisoning therefore costs the attacker pool initializations and gains nothing; a launch is never seeded, graduated or traded at a foreign price.

### Post-graduation trades and delivery

The shared hook takes ETH for both trade directions and supports exact input and exact output. When ETH is the specified amount, fees use `beforeSwapReturnDelta`; when ETH is unspecified, they use the actual ETH delta and `afterSwapReturnDelta`. Exact ETH output is grossed up to preserve the requested net amount; exact token output grosses up the pool's required ETH input. Each gross-up uses fee `(net - 1) / 99` for nonzero net, the smallest gross amount whose rounded 1% fee leaves that net. A specified-ETH partial fill reverts atomically; an unspecified-ETH partial fill charges only actual execution. Standard routers must account for hook deltas and enforce their own output/maximum-input protections.

Escrow recording makes no call to a creator or beneficiary. They withdraw their own credits to a chosen recipient. A rejecting recipient leaves the credit available for retry. If recording fails, curve/hook custody retains deferred ETH, original beneficiary and per-trade rounded shares; anyone may retry delivery without redirecting it. Deferred pre-crown fees still belong to the first beneficiary. No fees are diverted to a house treasury.

## Deployment parameters and responsibilities

All top-level application constructors are nonpayable and use supported static argument types. Deploy in this order:

| Artifact | Constructor arguments / responsibility |
| --- | --- |
| `LaunchToken` | None; protocol-required launch artifact |
| `WorkerSubsidy` | `address initialUpdater`: approved operational role, expressed as `$owner` if policy assigns that role to owner |
| `KingOfThePad` | `address workerSubsidy` |
| `PvPadHook` | `address poolManager`: independently verified target-chain PoolManager |
| `PvPadFactory` | `address poolManager`, `address workerSubsidy`, `address king`, `address hook`, `address genesisCreator` (policy-approved `$owner`) |

Factory construction creates its own immutable FeeEscrow and genesis token/curve; it needs no initialization transaction. Later pad launches deploy PvPadToken and BondingCurve internally, so these dynamic child constructors are not entries in the top-level launch manifest. The hook authenticates each binding against the token's immutable factory and the escrow's immutable factory, and its realignment path likewise makes no call into the factory, supporting constructor-created genesis without callbacks to an unfinished factory.

### Hook flags: 0x08cc

The hook requires CREATE2 address flags **0x08cc**: `beforeAddLiquidity` (0x0800, the pre-graduation liquidity gate), `beforeSwap` (0x0080), `afterSwap` (0x0040), `beforeSwapReturnDelta` (0x0008) and `afterSwapReturnDelta` (0x0004). There is still **no beforeInitialize** and no afterInitialize, remove-liquidity or donate callback. The constant is exported as `PvPadHook.REQUIRED_FLAGS`, `PvPadConstants.HOOK_FLAGS` and `HookMiner.PVPAD_HOOK_FLAGS`; `HookMiner.findPvPadHook(deployer, poolManager)` mines a salt for it locally. An address carrying the previous **0x00cc** layout is rejected by the constructor (`HookAddressNotValid`), so any salt mined for the earlier revision is void. This is a Uniswap v4 protocol rule, not a project choice: the PoolManager derives a hook's permissions from its address bits, so the constraint cannot be relaxed and no arbitrary hook address may be substituted. Only 1 in 16,384 CREATE2 addresses qualifies; a salt yielding different permission bits makes the hook constructor revert, and PvPadFactory (which references the hook) cannot deploy without it.

No `launch.json` is supplied by this source-producing assignment. The separate manifest contributor must generate a fresh manifest from these accepted sources and ABIs with the 0x08cc hook before independent review. The upstream manifest is not carried forward as deployment evidence.

### Deployment prerequisites the service must satisfy

The approved workflow requires services to mine a 0x08cc hook address and run the protected constructor floor on a Sepolia fork against PoolManager **`0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`**. These are service responsibilities, not prerequisites of this source assignment. Local tests exercise constructor execution against the vendored PoolManager. The source preserves both `HookAddressNotValid` and atomic genesis pool initialization.

1. **Mined CREATE2 salt for `PvPadHook`.** The launch manifest schema carries no salt, so the deployer must mine one for its actual CREATE2 deployer address, the attested creation bytes and the ABI-encoded PoolManager argument, and pass it through its deployment mechanism. `script/MineHookSalt.s.sol` produces the evidence offline, without environment variables, keys or broadcasting:

   ```sh
   forge script script/MineHookSalt.s.sol --sig "mine(address,address)" <deployer> <poolManager>
   ```

   It prints the deployer, PoolManager, init-code hash, salt, predicted hook address and its flag bits (`2252` = 0x08cc). Record all of them with the signed artifact. Any change to the attested creation bytes or PoolManager argument requires recomputing the init-code hash and salt. Always check that the actual CREATE2 deployer, init-code hash and predicted address match the deployment evidence. `ProjectDeploymentTest.test_mineHookSaltScriptMatchesTheDeployedHookAndUnminedSaltsFail` deploys with the script's output and shows eight unmined salts failing.

2. **Live PoolManager code during every constructor simulation.** Factory construction binds, inspects and initializes (or realigns) the genesis pool on the PoolManager, so the protected deployment floor, admission and any gas estimate must run on Sepolia (chain ID `11155111`) or a fork of it with the verified PoolManager runtime at the configured address. Merely setting a local chain ID does not supply that code, and in that setting the factory is the one manifest contract whose constructor fails. The genesis pool must be at its canonical price as soon as the factory constructor returns; `GenesisPoison.t.sol` verifies that guarantee even when every candidate was preinitialized. `ProjectDeployment.t.sol` is the local counterpart: it runs the same constructor-only CREATE2 sequence against the vendored PoolManager. Estimate gas for the complete constructor sequence, including the worst case of poisoned genesis candidates; the deployer's per-transaction gas ceiling and the chain's transaction gas cap must accommodate it.

After any artifact or constructor-argument change, recompute addresses and simulate the complete deployment order. The PoolManager address above comes from the approved workflow; its live runtime and fork execution have not been verified by this local contribution. Verify them during admission. The actual CREATE2 deployer, updater, genesis creator, mined salt and resulting project addresses remain service/policy inputs or outputs.

`genesisCreator` is the immutable lifetime beneficiary of genesis's creator half of each curve/hook fee, including odd fee wei. There is no rotation path. Policy must authorize this address as the actual genesis creator; `$owner` must not silently mean a generic deployment wallet. `initialUpdater` is a separate custody role, even if policy assigns the same `$owner` to both. The manifest reviewer must inspect those resolved arguments against policy; this source revision does not supply or edit `launch.json`.

The separate manifest contributor writes `launch.json` from these ABIs and accepted source; source publication, signed artifact linkage, policy allocation, attestation and admission belong to services. Application pools have fee 0 and this hook; the protocol launch-token pool remains subject to its independent pinned policy (including its fee and currency). Do not confuse those pools.

### LaunchToken versus the pad genesis token

The mandated `src/LaunchToken.sol` mints exactly `10^27` units to its deployer, with no arguments or privileged controls. Its allocation is performed by protocol services under the approved pinned policy, not by these application contracts. **It is distinct from launch 0's PvPadToken**, whose whole supply funds its curve as the product requires. Both use the brief's PVP name/symbol; integrations must distinguish addresses. The protocol LaunchToken does not implement the brief's full-supply-to-curve allocation; the factory-created pad tokens do. No application constructor moves the protocol launch supply. PvPad economics do not use a Community Coins allocation template or 20 ETH graduation threshold.

### Sepolia address handoff

No transactions were broadcast and no addresses are claimed as deployed or verified by this contribution.

| Item | Sepolia (chain ID 11155111) |
| --- | --- |
| PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` from approved workflow; service must verify live code and fork execution |
| Protocol LaunchToken | Pending service deployment |
| WorkerSubsidy / KingOfThePad | Pending service deployment |
| Shared PvPadHook / PvPadFactory | Pending service deployment |
| Factory FeeEscrow / genesis PVP / genesis curve | Read factory getters and `LaunchCreated` after service deployment |
| Second token proof | Exercised locally in integration tests; chain proof belongs to deployment service |
| Published source / site / PR | Service handoff; requested site name `pvpad`, IPFS hosting and imd-deployment wiring |

## Worker keeper runbook and custody

1. The off-chain keeper obtains accepted work from `https://api.imd.fun/workers`, resolves seats to payees, and aggregates one amount per payee. Solidity makes no HTTP calls.
2. Prefer the Identity MD oracle workflow (panel 70 / quorum 67) before the trusted updater signs. The contracts do not verify that off-chain attestation.
3. Read next epoch ID and available `workerPot`; construct sorted-pair Merkle trees with double-hashed leaves `keccak256(bytes.concat(keccak256(abi.encode(epochId, payee, amount))))`. The leaf's epoch prevents cross-epoch replay. Publish the complete allocation, proof and epoch metadata for payees.
4. The updater calls `setEpoch(root, windowStart, windowEnd)` with a valid nonzero root, a window at most 90 days long, and a start at most 90 days ahead of the mined transaction's timestamp (`InvalidWindow` otherwise). Choose a future start with inclusion margin: `windowStart` must be at least the timestamp of the mined transaction. It reserves the available pot as that epoch's budget. Allocation sum must fit the budget; newly donated funds remain available for later epochs.
5. Anyone can relay `claimWorker(epochId,payee,amount,proof)`; ETH always goes to the proof's payee. Each payee claims once per epoch. A rejected ETH transfer reverts the claim and leaves it retryable during the window.
6. After expiry, anyone can recycle unclaimed reserved funds into the pot for a later epoch. Updater rotation uses propose/accept, never an implicit deployer role.

The updater can publish a dishonest root and allocate the available worker pot to itself. It can delay the pot, but not park it: the start may be at most 90 days ahead and the window at most 90 days long, so claims open within 90 days and the epoch expires within 180 days of creation. After expiry, `recycleExpiredEpoch` returns what is unclaimed to the pot. Updater rotation cannot cancel an existing epoch. Merkle membership proves inclusion, not fair work or oracle approval. Use a policy-approved multisig, independent allocation/window review and an operational signing policy before production. No updater can withdraw curve reserves, LP, or other accounts' fee credits. There is no pause, upgrade, creator LP withdrawal or hidden fee beneficiary.

## Validation and remaining review

This assignment's local validation completed with `forge build`, `forge test` (**172 passed, 0 failed, 0 skipped**, 22 suites), `forge fmt --check`, and `python3 tools/export_abis.py --check` (all eight exports regenerated and matching the build). The build succeeds with existing compiler/linter advisories; it is not a clean static-analysis report. Historical review findings and current delivery changes are in [CHANGELOG.md](CHANGELOG.md). [test/README.md](test/README.md) documents coverage. ABI exports come from this build's eight contract artifacts.

The local deployment floor checks every application and child runtime for the 24,576-byte limit and forbidden opcodes. PvPadFactory is the largest at 22,410 runtime bytes; its 40,503-byte init code including the five constructor arguments fits the 49,152-byte limit. The separate CREATE2 test preserves all `10^27` protocol token units at the service deployer after every constructor and after the second launch graduates. This is local execution evidence, not the independent protected harness or a live Sepolia deployment.

Tests cover genesis and a second launch, curve round trips and limits, real v4 swaps in all four modes, locked liquidity, shared king fee accounting, permission checks, failed payouts and deferred delivery, reentrancy, worker windows/claims, and token invariants. Regressions cover rejected pre-graduation deposits on either boundary and across many ticks, liquidity opening after graduation, unbound pools staying closed, the defense-in-depth range scan and its rollback, threshold sells of any size, bounded salt retry for poisoned pools, realignment when all candidates are poisoned (including all 16 genesis candidates of the future factory address, the reviewer's proof), realignment from both extreme prices without moving value, the realignment permission and liquidity checks, refused stray ETH, and the bounded epoch start. The protected deployment checks are a baseline for supply, runtime size and forbidden opcodes; local tests do not substitute for the service's signed-artifact checks.

A separate source inspection during this contribution found no confirmed exploitable defect and corrected documentation about active liquidity and init-code size. An independent adversarial review of accepted source plus final manifest remains required before release, especially curve rounding, v4 accounting, constructor roles and updater custody. This contribution does not claim an audit, deployment, or completion of hosting. Slither and Mythril were not run.

MIT for project changes; vendored dependencies retain their own licenses.
