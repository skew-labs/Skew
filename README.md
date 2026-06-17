# Skew

Permissionless on-chain derivatives on Solana that can't go insolvent by construction.

Margin is derived from the payoff, not from a volatility model. Each party escrows the exact worst-case loss of its position over a declared, bounded settlement domain. Once both sides are escrowed the contract is fully pre-funded, so there is nothing left to liquidate and nothing for a price oracle to break. The solvency guarantee is an integer inequality, not a risk estimate.

That is the entire thesis. The rest is consequence.

## How it works

A contract is a payoff function over a finite settlement domain: a tick lattice with declared lower and upper bounds. A party's worst-case loss is the maximum of its loss over that finite set. Because the set is finite the maximum is real and attained, so it needs no continuity, no convexity, and no statistical assumption.

- Escrow the maximum, not an estimate. At submission a party locks `WCL = max over S in D of loss(S)`. An order that can't fund its worst case fails at submission. A position that exists is a position that is covered.
- Clamp the reference into the domain. At settlement the realized reference is clamped and snapped onto the same lattice the escrow was taken over. Any reference, stale or manipulated or gapped, can only move escrow between the two counterparties. It never touches the vault.
- Pay from escrow only. The owing side pays out of its own escrow, rounded so residual dust accrues to the protocol and never against it.

Listing is permissionless because it is safe by the same math. Margin comes from the payoff, so any asset is admissible; the only gate is a sound worst-case certificate (a full grid maximum, a solver proof, or an interval bound). A sampled bound or a self-declared flag is rejected, and anything whose worst case can't be soundly and feasibly bounded fails closed at registration.

Matching is an on-chain frequent batch auction. All orders in a slot are treated as simultaneous and clear at one uniform price the program computes over a tick-grid histogram. No off-chain solver, no trade-price oracle, no advantage to being a few milliseconds early.

The cost is stated, not hidden: full collateralization instead of leverage on the default path, and collared (capped) instruments instead of unbounded ones. A data-calibrated leveraged tier exists but is gated, and the solvency guarantee does not rest on it.

## Architecture

Skew runs as a based rollup on Solana. Solana orders the transactions, so there is no separate sequencer and no privileged keeper; ordering and censorship-resistance are inherited from the L1. The protocol kernel is the deterministic state-transition function, so anyone can read the sequenced inputs off Solana and re-derive Skew's state independently. Solvency is not trusted, it is proven: the worst-case-escrow invariant is checked by a succinct proof (Groth16) verified on Solana rather than asserted by an operator.

This is early and incremental. The state-transition function, the L1 inbox, the deriving node, and the on-chain proof verifier exist as working, byte-locked slices and have been run against live Solana blocks. The full chain is not deployed.

## Verification

Claims are checked, not asserted.

- Every on-chain account has one byte layout, implemented independently in Rust, Python, and TypeScript. A mismatch in any lane fails the build.
- Each payoff adapter's solvency is discharged by handing the negation of "escrow dominates worst-case loss" to Z3 and requiring UNSAT, paired with a known-SAT canary so the harness can prove it is able to fail. Control flow and lifecycle go through Kani and TLA+; the core payoff law is in Lean.
- The numeric invariant has run over roughly 1.2M arbitrary bounded payoffs with zero violations.
- Every hot path's compute cost is measured in an in-process VM against Solana's per-account and per-transaction limits, not estimated.

## Status

Pre-audit. Not on mainnet. Do not use with real funds.

Protocol source, proof harnesses, and internal audit notes are private pending external audit. This repository is the public overview.

## License

All rights reserved pending a license decision.
