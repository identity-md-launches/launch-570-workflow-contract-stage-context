# PvPad — Project Spec (v4, frozen)

**Status:** Frozen product source of truth for the public repo + swarm petition.  
**Supersedes:** lottery/race draft; Sepolia launch-139 one-shot demo; earlier “straight v4 only” draft.  
**Date:** 2026-09-24  
**Frozen decisions:** fee 50/50 king/creator · launch fee → worker pot · launch path = bonding curve → graduate to locked Uni v4 (anti-snipe)

## One-liner

Permissionless **token launchpad** (Pons v2 / pump.fun-class discovery). Anyone can launch a coin on a **bonding curve**; at threshold it **graduates** into a **locked Uniswap v4** pool behind a shared hook. A cut of **all** launchpad trading fees (curve + post-grad) goes to **King of the Pad**. King-bid ETH funds **Identity MD workers** via merkle epochs. **No house treasury.**

## Product goals

1. **Non-snipe first:** retail can buy without losing block-0 to bots. Curve is the default venue until graduation.
2. Feel like a real pad: browse, create, trade on curve, see graduate progress, trade on v4 after.
3. **King of the Pad** = platform revenue sink across **every** launch (curve + pools).
4. **No house cut** to a private admin wallet. Platform fee share → current king beneficiary.
5. Workers funded by **king claims** (+ launch fees + optional `fundWorkers`); merkle epochs from off-chain IMD attestations. Solidity never calls `api.imd.fun`.
6. Public Foundry repo → swarm petition with pinned commit. Swarm deploys/hosts/reviews; **does not redesign economics.**

## Non-goals (v1)

- Lottery / dice / “Pepe dies” mechanics.
- Day-one open Uni pool as the only venue (that is snipable; rejected for v1).
- Mainnet until audit Highs closed (updater custody, independent skim/curve review).
- On-chain mainnet NFT reads while on Sepolia.

## Frozen economics

| Knob | Value |
|------|--------|
| Trade fee | `feeBps = 100` (1%) on curve buys/sells **and** post-grad hook swaps |
| Fee split | **50% King** (platform) / **50% creator** (per launch) |
| Fee currency | Prefer **quote** (ETH/WETH); never force fee-in-meme on sells when avoidable |
| Launch fee | Default `0.0005 ether` → **100% worker pot** |
| King bid | `msg.value > claimPrice`; **100% → worker pot**; no refund to prior king |
| Initial `claimPrice` | `0.01 ether` |
| `bumpBps` | `1000` (+10% per claim) |
| Unassigned king share | Accrues until first `claimKing`, then assignable to that beneficiary |

## Actors

| Actor | Role |
|--------|------|
| **Creator** | `createLaunch`; receives that launch’s **50% creator fee share** (curve + post-grad). |
| **Trader** | Buys/sells on curve; after graduation, swaps the v4 pool. |
| **King** | Highest bidder; sets **beneficiary** for the **50% platform share** across all launches. |
| **Beneficiary** | Receives pushed/credited platform fees. |
| **Updater** | Publishes merkle epoch roots (trusted; mainnet → multisig). |
| **Worker payee** | Claims from pot with merkle proof. |

## User flows

### Launch

1. Creator sets name, symbol, image/metadata, optional socials.
2. Pays **launch fee** → worker pot.
3. Factory deploys ERC-20; **mints full supply to that launch’s bonding curve** (creator does not hold the bag).
4. Launch listed with curve progress toward graduation threshold.
5. Trading is **curve-only** until graduate.

### Trade (pre-graduation)

1. Buy/sell against the launch’s bonding curve (wallet signs; non-custodial).
2. Curve charges **1%**; split **50/50** king/creator (same escrow rules as post-grad).
3. No separate public “open pool” to snipe before the curve has filled.

### Graduate

1. When curve quote reserves hit **`graduationThreshold`** (default **4.2 ETH** for ETH-quoted launches; document per-asset if multi-quote later).
2. Permissionless `graduate(launchId)` (or auto on next trade): sweep curve → seed **full-range Uni v4** pool; **LP permanently locked**.
3. Curve trading stops (`CurveGraduated`). Post-grad trading is the v4 pool only.
4. Pool fee tier may be **0** so the **shared hook** takes the pad fee (Pons v2 pattern) — one fee story, not Uni fee + pad fee stacked.

### Trade (post-graduation)

1. Normal Uni v4 routers / aggregators.
2. Shared **PvPadHook** skims **1%**, split **50/50** king/creator.
3. Delivery failure must **not** revert the swap (credit / deferred fallbacks).

### King of the Pad

1. `claimKing(beneficiary)` payable with `msg.value > claimPrice`.
2. Update king + beneficiary; bump claim price; bid ETH → worker pot.
3. While crowned, beneficiary receives platform **50%** from **all** launches (curve + graduated pools).

### Workers

1. Keeper: `GET https://api.imd.fun/workers` → map seats → payees → merkle `(payee, amount)`.
2. Prefer Identity MD oracle (panel 70 / quorum 67) before `setEpoch`.
3. Only **updater** `setEpoch`; payees `claimWorker`.
4. Sepolia: keeper off-chain only.

## Token / pool / curve policy (v1 defaults)

| Param | Default |
|--------|---------|
| Supply | `1_000_000_000` tokens, 18 decimals → `10^27` minor units |
| Mint | Full supply to **curve** at create; no owner mint after |
| Quote | Native ETH / WETH for v1 |
| Curve | Constant-product (or documented equivalent) with virtual reserve so price starts non-zero and ends at graduation price |
| `graduationThreshold` | `4.2 ether` (ETH-quoted) |
| Post-grad pool | Uniswap v4; LP locked; no team withdraw |
| Hook permissions | Swap-path only (`beforeSwap` / `afterSwap` / `beforeSwapReturnDelta` as needed) |
| `beforeInitialize` | **Forbidden** on the shared hook (IMD factory lesson — launch-138) |
| Hook constructor | PoolManager-only when attestation requires it; factory binds pad/registry in the create/graduate tx |
| Anti-snipe | **Primary = bonding curve.** Optional extras (max wallet on curve) are v1.1 |

## Architecture (canonical modules)

| Contract | Responsibility |
|----------|----------------|
| `PvPadFactory` | `createLaunch`, deploy token + curve, collect launch fee, register metadata |
| `PvPadToken` | Fixed-supply ERC-20 |
| `BondingCurve` | Per-launch (or clone) curve buy/sell, fee skim to escrow/router, `readyToGraduate` |
| `Graduate` / factory method | Seed locked v4 pool from curve reserves; stop curve |
| `PvPadHook` | Shared post-grad skim; 50/50 split; non-bricking delivery |
| `KingOfThePad` | Claims, beneficiary, bid → worker pot |
| `WorkerSubsidy` | ETH pot, epochs, claims |
| `FeeEscrow` | Pullable creator / king credits (curve + hook) |
| Frontend | Launch, curve trade, graduate progress, post-grad trade, crown, fees, worker claim |

**Petition constraint:** deploy **this** architecture. Do not collapse to a single-token demo. Do not remove the factory or the curve phase.

## Invariants

1. Creator credits + king credits + deferred/unassigned + delivered ≈ fees skimmed (per currency), across curve and hook.
2. Worker pot grows from king bids + launch fees + `fundWorkers`; shrinks only via valid merkle claims.
3. Fee delivery failure never reverts user trades (curve or swap).
4. No admin pause that redirects fees to a hidden treasury.
5. Updater rotation is two-step if implemented.
6. Only factory-registered launches earn/split pad fees (allowlist / registry — avoid foreign-hook grief).
7. After graduation, curve buys/sells revert; liquidity path is v4 only.
8. Graduated LP has **no** withdraw-to-creator path.

## Security / mainnet blockers

- Updater dishonest-root drain → multisig/timelock; custody docs; optional attestation / epoch caps.
- Independent review of curve math, graduate seeding, hook skim / try-catch / deferred paths.
- Updater ≠ long-term personal withdraw EOA.
- Graduate must not be griefable into bad price or stolen reserves.
- Re-entrancy and fee-on-transfer assumptions documented and tested.

## Repo checklist (before petition)

- [ ] Foundry green: multi-launch; fees on curve **and** post-grad both hit **same** king; graduate seeds lock; factory-safe hook init
- [ ] README: economics, keeper runbook, threat model, address placeholders
- [ ] This `SPEC.md` in repo root
- [ ] License (MIT or Apache-2.0); public GitHub
- [ ] Minimal UI optional; swarm may own production site

## Swarm petition (intent)

> Deploy and host **PvPad** from `https://github.com/<org>/pvpad` (pinned commit). Bonding curve → locked Uni v4 graduate; **1% fee 50/50 king/creator**; launch fee → workers; king bids → workers. Do **not** remove factory, curve, or multi-launch. Sepolia first. Site `pvpad`. Keep factory-safe hook rules (no `beforeInitialize`; PoolManager-only constructorArgs if attestation requires).

## Genesis (frozen)

- Launch #0: **`$PVP` / Pepe Values Pepe**, **zero create fee**, full supply to curve, same 1% 50/50 economics.
- Later launches: pay launch fee (default 0.0005 ETH) → worker pot.

## Still open (non-blocking for scaffold)

2. Next chain after Sepolia (Base / Ethereum / other)?
3. Exact curve formula + phantom reserve parameters (implementer chooses; must be tested and documented).

## Reference: Sepolia launch-139

Demo only: one `$PVP` + one hook; 100% skim → beneficiary; king bid → workers; **no** factory of many launches; **no** curve. Reuse skim/king/worker patterns; **do not** treat as the product.
