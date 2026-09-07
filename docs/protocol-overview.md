# Protocol overview

Skew's protocol gives one economic job the same meaning across the web client,
external agents, the scheduler, independent machines, verifiers, and a
settlement adapter.

## Design goals

1. A requester signs the result, deadline, maximum budget, and acceptance rule.
2. A quote binds the complete cost, including explicit backup and verification.
3. A lease binds measured capacity to one contract and one validity window.
4. Attempts are fenced so recovery cannot create duplicate economic effects.
5. Payment eligibility follows accepted contribution, never worker self-report.
6. Integer monetary values are conserved exactly.

## Core objects

### Work Intent

The requester's authority. It describes the output, content-addressed inputs,
deadline, budget, permitted execution families, data policy, and verification
policy. A recommendation or detected opportunity is not a Work Intent.

### Quote and acknowledgement

The quote fixes the offered total and the supply facts used to produce it. The
buyer's acknowledgement prevents a scheduler from changing the economic terms
after consent.

### Execution Contract

A sealed, immutable plan that binds the Work Intent to execution profiles,
state references, leases, retries, verification, and settlement. The compiler
can propose a contract; it cannot sign on behalf of the requester or provider.

### Step Receipt

A machine's statement about one bounded attempt. It contains the contract,
node, attempt, lease, profile, input set, state references, output commitment,
usage evidence, and completion time. It is evidence, not acceptance.

### Acceptance Receipt

The terminal decision that the configured outcome rule was satisfied. It binds
the accepted output, verification evidence, eligible contributions, settlement
commitment, and one economic effect identity.

### Settlement Receipt

Evidence that an adapter submitted and finalized the exact accepted economic
effect. Acceptance and settlement are kept separate so the product never calls
an accepted-but-unpaid result “paid.”

## Lifecycle

```text
DRAFT
  → SIGNED
  → QUOTED
  → FUNDED
  → LEASED
  → RUNNING
  → RESULT_COMMITTED
  → ACCEPTED | REJECTED | EXPIRED
  → SETTLED | REFUNDED
```

Terminal and failure transitions are explicit. Silence never means success.
An ambiguous transport outcome is reconciled against durable receipts before a
new attempt is admitted.

## Canonical data

Protocol data uses versioned schemas, domain-separated digests, strict field
sets, bounded strings and arrays, normalized text, and decimal strings for
monetary quantities. Floating-point values are not valid signed money.

The [public fixtures](../examples/) are intentionally readable. They illustrate
the object relationships and exact money conservation; they are not signed
production objects or proof of a deployed escrow.

## What becomes public later

The protocol registry, canonical encoding, cross-language golden corpus, and
receipt verification libraries are designed for public conformance. Production
admission policy, provider economics, ranking, signing services, and operational
recovery data are separate implementations and do not define the wire format.
