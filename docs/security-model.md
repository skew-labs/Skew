# Security model

Skew assumes machines, networks, data providers, and schedulers can fail. It
does not assume that every anonymous provider is honest or independent.

## Authorities

| Authority | May do | Must not do |
|---|---|---|
| Requester | Define result, budget, deadline, data and acceptance policy | Invent provider capacity or accept a result it did not authorize |
| Provider | Advertise measured capacity and sign a bounded lease | Change the job, acceptance rule or requester budget |
| Scheduler | Match eligible demand and capacity | Sign for either party, accept its own result or release payment |
| Executor | Run one leased attempt and emit evidence | Hold requester wallet or settlement keys |
| Verifier | Evaluate the configured outcome rule | Change contract economics |
| Settlement adapter | Submit the exact accepted effect | Create a new payout, recipient or amount |

## Failure model

The design covers stale state, divergent execution, late results, duplicate
delivery, replay, provider loss, scheduler restart, ambiguous transport,
partial settlement, malicious input, and worker compromise. Stronger profiles
may require independent operators, regions, implementations, TEEs, or proofs.
These properties are paid and explicit; multiple processes on one host are not
presented as independent machines.

## Fail-closed rules

- No funded, signed intent means no paid execution.
- No current capacity lease means no worker start.
- A result outside its deadline or execution profile cannot be accepted.
- Worker self-report cannot create payout eligibility.
- A replayed attempt cannot create a second economic effect.
- A settlement adapter may submit only the accepted amounts and recipients.
- Provider, admission, verification, and payout keys stay off untrusted workers.
- Ranking output has no wallet, execution, acceptance, or payment authority.

## Data handling

Inputs are content-addressed and constrained by a declared confidentiality,
region, retention, and cache policy. Public commitments do not imply public
input data. A worker receives only the capability and artifacts required for
its leased step.

## Current assurance

The system is pre-audit. Public fixtures and internal gates demonstrate design
and implementation progress; they do not establish institutional security or
authorize real funds. Base mainnet settlement remains disabled until contract
review, signer isolation, funded operational limits, monitoring, and recovery
procedures are complete.
