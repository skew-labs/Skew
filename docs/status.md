# Current status

Last reviewed: 2026-09-07

Skew is a pre-audit startup system. This page separates implemented slices,
publicly inspectable material, and activation work.

| Area | Current state | Next acceptance boundary |
|---|---|---|
| Product | Public buyer and provider experience at [skew.deals](https://skew.deals) | Paid pilot using one real accepted job |
| Common protocol | Internal Rust and independent JavaScript reference implementations with versioned receipts and fixtures | Publish the conformance package after license and interface freeze |
| Control plane | Durable intent, lease, result, acceptance, and settlement-state components under integration | One release identity through the full paid path and recovery drill |
| Skew Node | C++20 fixed-function worker path plus Rust economic authority | Native Orange Pi 5 Pro 8GB qualification and signed release update test |
| Flex compute | Signed lease and result-custody integration prototypes | Real provider lease with production input custody and independent acceptance |
| Base | State adapters and public Base settlement contracts with failure-path tests | External review, isolated signer, limited mainnet canary, payout and refund |
| SVM and BNB | Candidate execution and state adapters | Current-source conformance and shared contract integration |
| Ranking | Shadow evaluation and authority-free recommendation design | Calibrated online evaluation before any displayed economic estimate |

## Not claimed

- No production mainnet escrow or real-funds payout is claimed.
- No anonymous GPU is accepted merely because it self-reports a model name.
- No node count, throughput, savings, income, or reliability number is claimed
  without a published measurement boundary.
- No ranking model can authorize spending, execution, result acceptance, or
  settlement.
- No purchase of Skew hardware is required to request work or offer compatible
  third-party hardware.

## Release rule

A feature moves from candidate to live only when its code, exact configuration,
deployment identity, positive path, failure path, recovery path, and economic
authority boundary have been checked together. Documentation alone does not
advance status.
