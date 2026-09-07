# Base settlement contracts

This directory publishes the Base compute-settlement contracts used by Skew's
review package.

- `SkewBaseComputeEscrowV1` binds funded USDC to one job, one quoted economic
  effect, one verifier route, and a fixed refund boundary.
- `SkewBaseComputeRouteRegistryV1` pins the verifier address, runtime code hash,
  and fee caps for each route.
- `SkewEcdsaQuorumReceiptVerifierV1` accepts only ordered, unique, low-s quorum
  signatures over an exact execution receipt.
- The test suite covers funding, acceptance, contribution proofs, replay,
  refunds, liability conservation, fee caps, pause behavior, and wrong-chain
  rejection.

Run the contract tests with Foundry:

```bash
forge test --root contracts
```

## Status

The source is public for technical review. It is pre-audit and has no published
Base mainnet deployment address. Do not use it to move real funds. A future
deployment must use a separately reviewed release manifest, isolated signers,
limited canary caps, monitoring, and tested recovery procedures.
