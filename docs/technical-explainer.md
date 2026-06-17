# Skew Technical Explainer

Final-state architecture guide.

**Any token. Any bounded payoff. No unfunded risk.**

## 1. The simple version

Skew is a fully on-chain risk exchange. The short version: it lets people trade any token's risk, but only once the worst possible loss has already been funded.

Most exchanges stay solvent with liquidations, insurance funds, volatility models, market makers, and keepers. That is probabilistic. It works while the asset is liquid and the model is right, and it gets fragile when the market gaps, the oracle is stressed, liquidity disappears, or the token is new.

Skew takes a different default path. Before a trade can go live the protocol asks one question: what is the most this account can owe under the declared settlement domain of this contract? That amount is locked first. If the protocol cannot compute or certify that bound, it rejects the trade.

This does not make every trade cheap. It makes every valid claim funded. Skew is not trying to be the loosest leverage venue; it is trying to be the venue where a token team, a treasury, a market maker, a fund, or a trader can trust that settlement still works when the market is ugly.

## 2. The one rule

Every Skew financial transition is checked against a single conservation rule.

```
funded_claims_after <= funded_sources_after
```

A funded source is value already locked in the correct settlement mint: user collateral, already-realized counterparty debits, explicitly reserved backstop funds, or fees once they have left the user-liability pool.

A funded claim is anything a user can withdraw or receive: free collateral, backed profit, settlement payouts, funding owed, refunds, or backstop receipts.

No instruction may create a withdrawable claim unless a corresponding source is already funded. That rule is the heart of Skew. It applies to forwards, options, RFQs, spreads, perps, secondary transfers, vaults, and margin release.

## 3. What "any token, any payoff" really means

Skew can support any derivative that has a bounded payoff over a declared finite settlement domain and whose worst-case loss can be computed or certified. That is the honest technical definition.

A settlement domain is the world the contract agrees to settle inside. A BTC forward might settle only between 50,000 and 90,000 on a fixed tick grid. A new Solana token option might settle only inside a band chosen by the writer and buyer. A perp epoch has its own risk band for that epoch.

If the payoff is truly unbounded, Skew does not pretend it is safe. The trade becomes a capped/collared version, or it is rejected. This is why Skew can be permissionless without a human risk committee deciding whether a long-tail token is safe.

- The token can be new, illiquid, weird, or highly volatile.
- The protocol does not need a historical volatility table to make the user-funds guarantee.
- The trade only has to declare a finite settlement domain and pass the worst-case loss gate.
- If the domain or payoff cannot be safely bounded within compute limits, the protocol fails closed.

## 4. Worst-case loss

Worst-case loss (WCL) is the maximum an account can lose over the declared settlement domain. It is not a risk estimate and not a margin percentage guessed from recent volatility. It is the true maximum loss the contract can legally produce.

```
WCL(account) = max over S in D of max(0, -payoff(account, S))
```

`D` is the declared settlement domain. `S` is one settlement point inside it. The payoff function says how much the account receives or owes at that point. Skew takes the maximum loss across the whole domain and locks that amount before the trade is live.

For a simple capped forward the worst case is easy to compute from the floor, cap, reference price, and size. For more complex payoffs Skew uses one of three certified paths: an analytic proof, a full grid maximum, or a certified upper bound. If none works, the product does not list.

This is why writers post so much collateral. A writer is selling a funded promise; the premium is the price the buyer pays for that certainty. A writer who wants lower escrow can quote a tighter cap, buy an offsetting hedge, use a spread, or join a vault strategy with structural netting.

## 5. A concrete trade example

Take a BTC collared forward. The buyer wants long exposure to BTC until expiry, but the contract only settles inside a declared range: floor 50,000, cap 90,000, tick size 100. The forward reference price is 68,400. Contract size is one unit.

For the long side, the worst case is BTC settling at the floor. If BTC settles at 50,000 the long loses 18,400 versus the forward reference. That is the long-side required escrow.

For the short side, the worst case is BTC settling at the cap. If BTC settles at 90,000 the short loses 21,600. That is the short-side required escrow.

- The long cannot lose more than 18,400, because settlement is clamped at the floor.
- The short cannot lose more than 21,600, because settlement is clamped at the cap.
- The buyer and writer can negotiate premium, but premium is separate from the payoff-conservation math.
- At expiry the winner is paid from the loser's escrow, and unused escrow is refunded.

This is the experience Skew should expose: required escrow, margin ratio, premium, total cash needed now, possible refund, and the exact reason the escrow is required.

## 6. Settlement: clamp, snap, pay from escrow

At settlement the raw market reference is not used directly. Skew first clamps it into the contract's declared band, then snaps it to the same tick grid used for the WCL calculation.

```
raw reference -> clamp to [floor, cap] -> snap to tick grid -> evaluate payoff
```

This matters because the protocol maximized loss over that exact snapped domain. Once the realized settlement point is forced back into the same domain, the realized loss cannot exceed the escrowed WCL.

Settlement then pays winners only from loser escrow. Loser debits round up, winner credits round down, and any dust is non-negative. The protocol never needs to pay a winner from an insurance fund because the loser was underfunded. Underfunded live positions are not supposed to exist.

- If the reference gaps above the cap, settlement happens at the cap.
- If the reference crashes below the floor, settlement happens at the floor.
- If the reference is stale, invalid, or outside policy, the market can become invalid or close-only instead of giving users generous margin.
- The escrow domain and the settlement domain must be the same, or the guarantee is not valid.

## 7. Why this blocks unbacked-profit attacks

A common exchange failure mode is letting one trader manufacture profit against an account that cannot actually pay, then withdraw the gain before the loss is funded. Skew blocks that by separating pending profit from backed profit.

A trader may have positive mark-to-market PnL. But that PnL is not withdrawable until the corresponding counterparty debit is backed by locked funds. In plain English: no funded loss, no withdrawable gain.

This matters most for perps and cross-margin. If unrealized profit could be used as fresh collateral immediately, a trader could pyramid unbacked claims through volatile markets. Skew's accounting prevents that. It is more conservative, but it keeps the protocol from turning paper PnL into a solvency hole.

## 8. Cross-margin without correlation risk

Skew can still be capital-efficient, but only through structural cancellation. If a user holds long and short positions with the same settlement mint, compatible domain, and compatible timing, Skew computes the worst-case loss of the net book instead of summing each position separately.

```
net escrow = max over S in D of max(0, -sum_of_all_payoffs(S))
```

This is real margin relief because the payoff functions cancel by construction. It is not based on a correlation estimate. A BTC hedge does not reduce SOL risk unless the payoff math, settlement mint, domain, and timing make that cancellation real.

The dangerous case is closing the hedge leg and leaving the risky leg behind. Skew handles that by recomputing the whole book on every add, reduce, close, or transfer. If the surviving book would be underfunded, the operation fails or requires more collateral first.

Example: if an account holds 10 long BTC forwards and then buys 7 matching short BTC forwards, Skew does not keep collateral for all 17 gross legs. It recomputes the net book. If the two sides share the same domain, mint, and timing, the account behaves like roughly 3 net longs. The released amount is not a gift; it is the part of the old escrow that no longer covers any possible legal loss.

## 9. Perps as rolling bounded derivatives

Skew perps are not classical unbounded perps where liquidation speed is the thing keeping the venue solvent. They are rolling bounded derivatives. Each risk epoch has a declared band, funding cap, open-interest cap, reference policy, and fee configuration.

```
E_epoch = max loss over epoch domain + capped funding + fees + open-order exposure
```

An account can enter or renew into the next epoch only if this epoch requirement is funded. If it cannot fund the next epoch it becomes close-only, fails renewal, or is force-reduced under deterministic rules.

Liquidation is still useful, but it is no longer the solvency primitive. It is a liveness and cleanup function. The protocol should not break just because a liquidator is late, a market gaps, or a long-tail token moves 10x before the next keeper transaction.

- Funding is capped per epoch and prepaid into the epoch requirement.
- Unrealized profit is not automatically withdrawable collateral.
- Long-tail markets can have wider bands, lower caps, higher fees, or close-only status.
- Users get a familiar perp-like workflow, but the accounting is funded before risk is created.

This also explains the leverage limit. Maximum leverage is not a universal number like 20x. It depends on the epoch band, open-interest cap, position size, funding cap, fee schedule, and account offsets. A narrow band on a liquid asset means smaller required escrow; a wide band or a long-tail asset means higher required escrow. Leverage is an output of the funded-risk equation, not a marketing parameter.

If a token jumps 10x inside a valid epoch, the protocol should not owe money from its own pocket. Either the move is inside the declared epoch domain and was already funded, or it exceeds the domain and the system moves into close-only, invalid, or renewal-fail behavior.

## 10. Oracles, references, and confidence

Skew does not let the solver or maker choose the confidence score. Reference data must come from an approved oracle or a validated reference policy. Confidence is applied conservatively: collateral is valued lower, liabilities are valued higher, and uncertainty reduces measured health.

For composite references the protocol must protect against divisor-collapse attacks, stale feeds, sudden jumps, invalid decimals, and unsupported token features. The reference firewall should include minimum divisor prices, staleness checks, jump caps, confidence bounds, and exact integer arithmetic.

If the reference fails policy, the protocol should not hand anyone free margin. The correct behavior is invalid, close-only, or fail-closed. This is how Skew avoids the class of oracle bug where a bad composite price liquidates an entire side of a market or drains insurance.

The key design point: the oracle is not trusted to make the protocol solvent. The oracle only chooses a settlement point or a mark inside policy. Solvency comes from the fact that every legal settlement point is already funded. A bad reference can still cause an unfair redistribution inside a market, so the firewall matters, but it cannot create a protocol deficit.

## 11. Matching, RFQ, and MEV

Skew can use RFQ, batch auctions, secondary listings, and maker liquidity surfaces. Discrete batching removes the advantage of being microseconds earlier inside the same batch. It does not magically remove every MEV surface.

The remaining surfaces are censorship, batch-boundary timing, order leakage, and bad reference inputs. Skew handles them explicitly. Forced inclusion lets a user land an eligible order on-chain; a settlement that omits a non-expired forced order is invalid. Reference manipulation is handled by the reference firewall and fail-closed market states.

The important point is that MEV should not become a solvency event. A bad solver might censor or miss an order, but it should not be able to create unfunded profit, change settlement math, or make the vault owe money it does not hold.

## 12. Unified risk accounts and vault custody

User margin is held in program-owned vaults for each settlement mint. User accounts store claims over those vaults: free collateral, locked epoch collateral, locked dated-contract collateral, pending profit, backed profit, claimed profit, fees, dust, and quarantine.

The vault should not have a mysterious surplus. Every atom in the vault needs a classification. Extra value is quarantine until classified; it is not usable collateral. An omnibus vault is safe only if the accounting invariant is stronger than the convenience of pooling.

```
vault.amount = user principal + unclaimed backed profit + protocol fees + dust + quarantine
```

Withdrawals can only debit free collateral. They cannot withdraw locked epoch collateral, locked dated-contract escrow, pending profit, or backed profit directly. Backed profit must first become a claimable/free balance through the proper accounting path.

## 13. How Skew stays compute-bounded

A universal risk exchange cannot scan every account or recompute every possible path inside a hot fill. Skew separates cold certification from hot execution.

- Registration and formation are allowed to do heavier checks: payoff validation, WCL certification, reference-policy registration, and risk-configuration hashing.
- Hot paths use compact account state, fixed-size layouts, content hashes, integer arithmetic, and O(1) local checks.
- A fill does not need to trust a mutable off-chain model; it checks the account's locked collateral against the already-declared risk configuration.
- High-dimensional payoffs use certified upper bounds instead of full grid enumeration when enumeration would exceed compute limits.
- Anything that cannot be verified within the declared compute budget fails closed before it becomes a live market.

This is the engineering reason Skew can aim for a serious on-chain venue rather than a beautiful but impossible math design. The protocol does expensive proof work only where it belongs, then keeps the trading path bounded and deterministic.

## 14. Vaults and strategy builders

Skew can support liquidity vaults or user-created strategy vaults, but they should not be discretionary black boxes. A Skew vault is just another risk account with a strategy wrapper. It can quote, warehouse risk, and backstop liquidity only when its worst-case exposure is funded under the same rules as everyone else.

This is powerful because it lets professional traders build strategies on top of the kernel without receiving a special exemption from solvency. A vault can sell options, quote RFQs, provide perp liquidity, or run structured books, but every position it creates has to pass WCL, epoch, reference, and accounting checks.

The user-facing message is simple: a vault can take risk, but it cannot borrow safety from the protocol.

## 15. Fees and token value

Fees are separated from payoff conservation. The payoff between counterparties stays zero-sum, and protocol fees move into a classified fee pool only after they are no longer user liabilities.

A protocol can charge product-specific fees: perps, RFQ blocks, forwards, options, spreads, secondary transfers, WCL reservation, duration, settlement, builder or vault fees, and treasury capture. But fee policy should be immutable for existing positions. If a fee schedule changes, it should create a new policy for future markets or contracts, never rewrite old receipts.

This is how token value can connect to protocol revenue without giving governance the power to alter settlement. Fee flows and treasury can be owned by the project, while the kernel continues to protect user funds by rule.

## 16. Governance boundaries

Governance can decide growth. It should not decide solvency. Growth-side decisions (future fee policies, asset-tier metadata, listing bonds, incentives, treasury spend, grants, integrations, market caps, staged rollout limits, security procedures) are ordinary governed state.

Governance should not be able to change settlement math, WCL math, rounding policy, receipt finality, backed-profit rules, existing fee interpretation, or custody-accounting invariants. Those are not business knobs. They are the reason users can trust the venue. Changing them is a protocol upgrade, not a vote.

This keeps the protocol compatible with market governance while the kernel stays outside day-to-day political control.

## 17. What Skew does not claim

Skew should be precise about what it does not claim. It does not make every derivative cheap. It does not make off-chain legal claims enforce themselves. It does not delete all MEV. It does not make bad references economically harmless. It does not let governance rescue unsafe math.

What Skew claims is narrower and stronger: for every valid on-chain settlement path, user claims are funded before they are withdrawable. The protocol can still have market risk, UX friction, liquidity shortages, bad listings, weak demand, or governance mistakes. Those are business and product risks. They should not become vault insolvency.

Skew is not saying the universe becomes safe. It is saying the protocol refuses to turn unsupported risk into a live withdrawable claim.

## 18. Why users would choose Skew

A pure degen who wants maximum leverage on unbacked PnL may prefer a looser venue. That is fine. Skew is for users who need risk transfer that survives stress.

- Treasuries can hedge token unlocks or revenue volatility without trusting an OTC counterparty.
- Token teams can structure launch, lockup, or treasury-token deals with explicit on-chain escrow.
- Market makers can quote fully funded risk and transfer positions in secondary markets.
- Funds can trade long-tail token basis, spreads, funding, and event risk with deterministic receipts.
- Vault builders can create liquidity strategies whose risk is visible and funded.
- Retail users can buy capped exposure or protection without understanding counterparty credit.

Skew is not selling magic leverage. It is selling auditable, funded, programmable risk transfer.

## 19. Common technical questions

**Does batching remove all front-running?** No. It removes microsecond ordering priority inside a batch. The remaining MEV surfaces are censorship, batch-boundary timing, order leakage, and bad reference inputs, handled separately.

**Can validators or solvers exclude orders?** They can try to censor, but forced inclusion makes an eligible landed order mandatory for valid settlement until it expires.

**Can funding rates be manipulated high enough to wipe accounts?** Funding is capped per epoch and included in the pre-funded epoch requirement, so it cannot become an unbounded drain.

**Who provides the confidence score?** The oracle or a validated reference policy. The solver does not choose it, and failed confidence checks make the market invalid or close-only rather than generous.

**Why not let unrealized profit be collateral?** Because it may not be backed yet. Skew waits until the corresponding counterparty loss is funded before profit becomes withdrawable or reusable.

**Do writers have to lock the full possible payout?** Yes, unless they reduce the worst case with caps, spreads, structural hedges, or netting. That is what makes the buyer's claim credible.

**Does Skew need market makers?** Yes, for liquidity and pricing. But makers quote funded risk, not unsecured promises.

**What happens if an oracle breaks?** The reference firewall rejects stale, impossible, divisor-collapsed, high-jump, or high-uncertainty references. The market fails closed or close-only.

**Can Skew support RWAs?** It can support bounded exposure to an RWA reference if the reference policy and legal wrapper are valid. Skew settles the derivative claim; it does not custody off-chain assets.

**Can collateral be something other than USDC?** The accounting is per settlement mint. Stable settlement mints are simplest. Other collateral types need strict token-feature controls and conversion rules so custody accounting stays exact.

**Why does halt or close-only exist?** It is a fail-closed safety state. The protocol would rather block new risk than keep trading on invalid data or underfunded renewal.

**Is this bigger than a perp exchange?** Structurally, yes. Perps are one product. The kernel is a general market for bounded risk: options, forwards, spreads, RFQs, vaults, and perps under one funded accounting law.

**What if a user says the margin is too high?** Then the trade's worst-case loss is high. The user can narrow the band, reduce size, buy a hedge, use a spread, find a vault willing to warehouse the risk, or choose a looser venue.

**Can the protocol support every token on day one?** The architecture can support any token whose reference and settlement rules pass policy. Liquidity, UI, fees, and caps should still be staged.

**What is the biggest technical mistake to avoid?** Allowing a mutable parameter, oracle path, fee policy, or margin-release instruction to change the meaning of an existing funded claim.

## 20. The sentence to remember

Skew turns token risk into fully funded on-chain claims. If a payoff is bounded and the worst-case loss is computable or certifiable, Skew can list it. If the loss is not funded, the claim is not withdrawable. That is the whole system.
