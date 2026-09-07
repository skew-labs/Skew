# Skew Chain — Based Rollup Architecture

How Skew runs as a chain: who orders transactions, who computes state, and what is actually proven.

This document is the runtime architecture. The protocol rules it enforces (worst-case escrow, clamp-then-snap settlement, the one conservation rule) are in the [technical explainer](./technical-explainer.md). Here the question is narrower: given those rules, how does Skew become a chain without trusting an operator to stay solvent?

## Topology

Skew is a based rollup on Solana. Solana orders Skew's transactions; Skew computes its own state from that ordering and proves the result back to Solana.

It is deliberately **not** a sovereign L1. A sovereign chain would run its own validator set and its own consensus, which means bootstrapping security, liveness, and censorship-resistance from scratch. A based rollup inherits all three from Solana: there is no separate sequencer to trust and no validator set to bribe. The L1 block that includes a Skew transaction is the L1 block that orders it.

The cost of this choice is that Skew has to treat the L1 the way it treats an oracle: as something it does not control. The architecture is built so that an adversarial L1 leader can delay or reorder, but cannot make Skew insolvent or trap a user's funds.

## Trust model

The starting assumption is that the L1 leader is adversarial. Solana offers no binding, slashable guarantee on the order in which a leader includes transactions, so the chain does not rely on one. Safety comes from two places instead:

- **Finality-gating.** Value-bearing state is only finalized once the underlying L1 blocks are finalized. UX can track a faster head, but withdrawals and settlement fold at finalized depth. The depth is a swappable parameter, so a faster finality path can be adopted later without redesign.
- **Forced inclusion.** A user can post a transaction to the on-chain inbox with a deadline. A derived state that omits a non-expired inbox transaction is structurally invalid. This means censorship can delay a user but cannot exclude them.

Everything below follows from "the L1 is useful for ordering and availability, and trusted for nothing else."

## The pipeline

```
  Solana L1                                   off-chain (permissionless)            Solana L1
 ┌──────────────┐    ordered inbox          ┌───────────────────────────┐    root + proof    ┌──────────────────┐
 │ INBOX program│ ─────────────────────────▶│ DERIVATION  next = STF(    │ ──────────────────▶│ SETTLEMENT program│
 │ hash-chain   │                           │   prev, ordered_inbox,     │                    │ groth16 verify    │
 │ + deadline   │                           │   l1_clock )               │                    │ → root registry   │
 └──────────────┘                           │ = apply txs → settle crank │                    └──────────────────┘
        ▲                                    └───────────────────────────┘                            │
        │ forced inclusion                            │ same Rust, compiled to RISC-V                  │ exit on
        │                                             ▼                                                ▼ Merkle proof
   any user                                    SVP PROVER (STARK → Groth16)                    ESCAPE / BRIDGE program
```

**Inbox.** An on-chain program maintains a hash-chain accumulator over submitted transactions (`acc' = H(acc, tx)`) plus a monotonic count and a forced-inclusion deadline. This is the canonical, ordered input log. Omitting a non-expired entry from a derived root is detectable and rejected.

**Derivation.** A permissionless node reads the inbox in L1 order and computes the next state with a deterministic state-transition function: apply the user transactions, then run the settlement crank. The crank is the deterministic tail of every block. There is no keeper and no privileged settler; anyone who reads the L1 can re-derive byte-identical state, and the result does not depend on who derived it.

**State commitment.** Account state is committed in a Merkle-sum tree: every node carries a hash and a subtree balance sum, with per-balance non-negativity and an explicit in-tree overflow/sum range check. All commitment trees use SHA-256, chosen so the in-zkVM hash, the on-chain `sol_sha256` hash, and the host hash are byte-equal by construction.

**Proof.** The same Rust that runs the crank is compiled to RISC-V and executed in a zkVM, producing a STARK that is wrapped to a Groth16 proof. That proof is verified on Solana by an audited base verifier well within the per-transaction compute budget, and the proof plus its public inputs fit in a single transaction. A root that the proof does not attest to does not enter the registry.

## What is actually proven (the honest boundary)

This is the most important section, and the easiest to overstate. The two halves of the guarantee have different strengths, and we state them separately.

**Cryptographic, on every state root:** aggregate solvency. For each settlement mint, funded claims never exceed funded sources. The "print money / negative balance / over-promise" class of failure is *unrepresentable*: no valid proof exists for a root that violates it. The system can never be aggregate-insolvent.

**Optimistic, in the first stage (Stage A):** your specific balance is correct. An aggregate-solvency proof does not by itself prove that a particular user was not debited to credit someone else; a malicious prover could post a root that misallocates between users and still passes the aggregate check. This is a known property of aggregate proofs of reserve, not a hypothetical. In Stage A it is defended optimistically, with three concrete mitigations:

- A **per-user escape hatch**: a user exits on their own Merkle-proven balance, so a misallocating root cannot survive the exit path. This needs no cooperation from any sequencer or prover.
- **User-signed custody commitments**: deposits and withdrawals are authenticated by the user, so a prover cannot unilaterally rewrite a custody balance even inside an aggregate-solvent root.
- **Permissionless watchers plus durable data availability**, so an independent party can always reconstruct per-user state and challenge a bad root within the window.

**Cryptographic, on every root (Stage B):** the full state transition, including the settlement math, followed the STF. Misallocation becomes unrepresentable too, and the optimistic window is removed. Stage B is full zkSVM execution validity and is the prioritized path to a complete per-user guarantee.

We will not describe Stage A as "your funds are protected by a standing solvency proof." The honest statement is: **global solvency is enforced by math from day one; per-user correctness is enforced optimistically, with standard optimistic-rollup assumptions, until Stage B.**

## Exits and censorship resistance

A based rollup is only as trustworthy as its worst case, so the worst case is engineered directly:

- **Forced inclusion** bounds censorship. An eligible order that lands on L1 must be included in a valid settlement before its deadline.
- **The escape hatch** bounds custody risk. A user can withdraw against a Merkle inclusion proof of their own balance, released from the program-owned vault, without any operator's cooperation. "Team goes dark, user still exits" is a design requirement, not an aspiration.
- **State-root proposing and proving are permissionless.** Anyone can post the next root and its proof; liveness does not depend on a single proposer.

## Data availability

Inputs and committed state are anchored to Solana itself, batched so cost scales with transactions rather than raw bytes. Because Solana's base ledger retention is short relative to a challenge window, Skew runs verifiable archival (content-addressed, reconstructable by anyone) plus its own indexer, so per-user state can be rebuilt within the window even if validators have pruned. An external data-availability layer is kept only as a failover, not a dependency.

## Determinism

The executor and the circuit are the same source. One Rust crate runs natively (to derive state) and in the zkVM (to prove it), with a differential fuzz harness that halts on any divergence between the two, plus a shared cross-domain test-vector suite asserting byte-equality across the Solana program, the native executor, and the zkVM guest. Divergence between "what ran" and "what was proven" is the classic rollup defect; here it is a build-breaking, fuzzed-against condition rather than a hope. The code is integer-only, with no floating point and no unchecked casts, and all serialization is alignment-safe.

## Governance boundary

The same line the protocol draws applies to the chain. Growth parameters (fees, listing bonds, market caps, incentives, treasury) can be governed. The rules that protect funds (settlement math, the conservation invariant, the commitment scheme, finality depth) cannot be changed by a vote; changing them is a coordinated protocol upgrade. Governance prices how the chain grows. It does not get to redefine an existing funded claim.

## Status

Early and incremental. The inbox program, the derivation node, the settlement state-transition function, and the on-chain proof verifier exist as working, byte-locked slices, exercised against live Solana blocks on a local and dev setting. Aggregate-solvency proving, the escape hatch, fraud proofs, archival hardening, full zkSVM validity, and a permissionless prover market are staged work, each behind explicit verification gates. The full chain is not deployed, and nothing here is audited yet.

The build order is lifecycle-first and gated, not dated: prove one full lifecycle end-to-end before widening, and let a failed gate cost a fix rather than ship past it. Mainnet safety is ranked above speed on purpose.
