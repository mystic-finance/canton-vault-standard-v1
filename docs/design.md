# Design: Canton Vault standard



## Technical Summary

This standard defines a small set of Daml interfaces that utilizes CIP-56/112 that any vault developer can implement to create a vault on Canton while following a unified standard that any ecosystem participant can reuse and that will be composable across the board. It specifies that a single underlying token can be deposited in exchange for share tokens and, in turn, these share tokens can be redeemed for the deposited asset. To be clear - the standard doesn't support ERC-7575-equivalent functionality (depositing multiple tokens in the vault and receiving the same vault share).

It has been built to cover multiple use cases at once: vaults that need instant mint/redeem and ones that need queued mint/redeem, as well as vaults whose price is externally attested or internally computed. In all implementations, it leaves valuation, strategy, access control and roles to the implementer. This document proposes this interface's packages plus a conformance test suite, so that anyone can build their vault product on top of the standard and any integrator can do a single integration that will work for any conformant vault.

## Motivation

Several teams, ourselves included, are already building tokenized vaults on Canton, but we lack a standard vault interface we can all follow to be composable with one another. Lending vaults, strategy vaults, asset issuers and more, each defining their own deposit logic, share accounting and redemption logic. This is the same fragmentation EVM DeFi had before the ERC-4626 standard was introduced, a time in which every vault was reinventing share accounting, a well-known source of rounding and share-inflation bugs that required an audit for each implementation. With multiple parties building different vault interfaces, a vault's shares can't be recognized, quoted, transferred or used as collateral by any other application unless that application integrates with that specific vault issuer. The result is low composability - liquidity is siloed and integrators carry bespoke code per vault.

Just as CIP-56 standardized tokens, this document proposes a CIP to standardize vault interfaces, so that any vault developer can build on the standard with reduced effort and inherit battle-tested logic. Any conformant vault can be integrated by third parties with no vault-specific work.

## Requirement

| Nr. | Requirement |
| --- | --- |
| R1 | **Uniform interface:** Depositing into and redeeming from a vault works differently on every protocol. Vaults also differ fundamentally in pricing (computed vs. attested), settlement timing (instant vs. queued) and access (open vs. permissioned). As such, developers need to build their own vault from zero and integrators need bespoke, per-vault integrations that can't be reused across vaults. |
| R2 | **Composable shares:** A vault's shares can't be transferred, quoted, held by another vault or used as collateral by any other application without an integration built for that specific vault, which silos vault liquidity. |
| R3 | **Execution certainty:** A depositor can't know ahead of time how much they need to deposit to receive a certain number of shares. In other words, share price is not visible to third parties. A wallet reading a vault's published totals also has no way to tell whether they are current or merely last written, and because the vault's state can move between quoting and executing, the depositor has no way to set slippage minimums they are willing to accept. |
| R4 | **Safe settlement:** A deposit or redemption transaction runs the risk of not settling entirely, leaving the user with deposited funds but no minted shares or the other way around. Those funds can stay stranded if the vault never fully settles. |
| R5 | **Async participation:** When a vault doesn't settle immediately, there's no common way for a user to place and track an in-flight request. Each vault invents its own, so wallets can't show a uniform status. |
| R6 | **Delegated access:** An owner has no uniform way to authorize their wallet, custodian or a chosen agent to transact on their behalf across vaults. |
| R7 | **Observability:** There's no uniform way for a wallet to track a vault's total deposits, rate, a user's position and its pending requests, meaning each one requires custom indexing. |
| R8 | **Sound accounting:** Poor accounting logic risks rounding mint/redeem transactions in favour of the user and to the detriment of the vault, risking share-inflation attacks. |

## Status Quo

The two CIPs most applicable to this document are CIP-56 and CIP-112. CIP-56 is the v1 token standard: holdings and transfers, whereas CIP-112 is v2 of the standard, which extends accounts, allocations and settlement. Between them, they provide enough infrastructure for someone to build a vault - a share can be an ordinary token, meaning any wallet that accepts the token standard can accept vault shares. In addition, issuing and redeeming those shares can be implemented as a transfer to and from an account the instrument's admin controls. CIP-112 also allows a Party to lock funds and settle any transactions involving them later (with a deadline), which is what a vault needs for its mint/redeem queue. To note, current token standards also allow several of these locks to settle together in one transaction, all at the same price.

Still, there is no fundamental, common vault logic in all this - there is no notion of depositing into a pool and receiving a share of it, no share accounting, no exchange rate. Everyone is doing their own implementation of this, which is what this document aims to standardize.

The pieces this design uses from both the 56/112 CIPs:

- Holding and InstrumentId, from CIP-56. Both the underlying and the vault's shares are Holding contracts, identified by their InstrumentId;
- AllocationSpecification, the record with `committed : Bool`, `settlementDeadline : Optional Time`, `executors` and `nextIterationFunding`. Committing locks a party's funds until settlement, cancellation or the deadline, which is what makes a request queue possible;
- `AllocationFactory_Allocate` creates an allocation; `Allocation_Settle` and `SettlementFactory_SettleBatch` execute settlement of a trade's legs one at a time or in a batch; `Allocation_Cancel` and `Allocation_Withdraw` are how the vault implementer and the Party can respectively back out of an allocation;
- Account, where `owner = None` marks accounts the instrument admin controls. The mint source and burn target here are exactly those accounts, so in a vault, issuing and burning a token is just another transfer leg;
- EventLog in splice-api-token-transfer-events-v2, a nonconsuming choice that does nothing except make its arguments visible to its observers;
- `actors : [Party]`, allowing both the owner and the provider, enables a custodian to act for an investor.

Two additional things about Canton worth noting that will shape everything below: a) a wallet can't read and act in one transaction and b) interface queries only return Views. On the first, a wallet's queries don't run inside the transactions they inform, so anything a wallet reads may have moved by the time its command commits. As for the second, an interface query returns the View, not the contract, because a participant may hold implementations it doesn't recognise and the View is the only part it can interpret. Nothing is recomputed on read.

## Design

### High-Level Overview

The core ideas:

1. A vault and its shares are two contracts. The vault holds the pool state, and the shares are ordinary token standard holdings that the vault registrar issues, which means the registrar is an issuer. A Daml contract can't own assets, only a Party can, so the pooled underlying sits with either a named custodian or a DecParty. Both Vault Registrar and Custodian are on the View.
2. A wallet can read the vault's View, but it can't call the vault's read methods, which only run inside a transaction. So everything a wallet needs to see share prices or to deposit in a vault sits in one contract View.
3. The package has four interfaces: Vault has the accounting and the instant actions, VaultAsyncDeposit and VaultAsyncRedeem add a request queue if mint/redeem need one, and VaultEventLog has the reporting. A vault implements only the interfaces it needs, so a wallet works out what kind of vault it's looking at based on which interfaces are present in the vault.
4. Deposits and redemptions are configured separately. Each direction is either instant or queued, determined by which interfaces the vault implements. Mint/redeem limits on a single transaction are set by maxDeposit, maxMint, maxWithdraw and maxRedeem. Implementers are responsible for setting their own deadline for queued requests according to their use case and the window is published on the view. Deadlines are recommended because without them, a request can be held indefinitely; that's the problem described in Requirement R4.
5. A queued request locks the investor's funds until it settles, is canceled, or the request's deadline passes (if there is one). The view publishes both the executor set and the deadline window, because a vault with a single executor can terminate a request at will, and a vault with no deadline can hold funds until an executor cancels the request.
6. Every action an investor takes on a sync vault carries a slippage limit, so users don't receive fewer shares than expected because the share price moved between request and settlement.
7. A vault has to declare whether its price is computed or attested.
8. Valuation, strategy, fees, access, roles and deadline window are all defined by the implementer.

### Specifications

The package is called canton-vault-standard-v1 and it has four interfaces - Vault, VaultAsyncDeposit, VaultAsyncRedeem and VaultEventLog. In addition, there are five types and one template - VaultView, Rate, ComputedRate, AttestedRate and Accrual are types, and VaultDelegateAuth is the template. We also use Account and ExtraArgs, which come from the CIP-112 packages, and InstrumentId from CIP-56.

#### The Interface

The package has four interfaces:

- Vault, which has ten read methods and four instant choices. Every vault implements it;
- VaultAsyncDeposit, which requires Vault and adds `Vault_RequestDeposit` and `pendingDepositRequest`;
- VaultAsyncRedeem, which requires Vault and adds `Vault_RequestRedeem` and `pendingRedeemRequest`;
- VaultEventLog, which stands alone and adds the reporting choice.

On Vault, the read methods are convertToShares, convertToAssets, maxDeposit, maxMint, maxWithdraw, maxRedeem, previewDeposit, previewMint, previewWithdraw and previewRedeem. They run inside a transaction and enforce limits and pricing when a choice is executed.

On the async interfaces, a request is identified by the RequestId its request choice returns. pendingDepositRequest and pendingRedeemRequest each take that RequestId and a Party, and return a Decimal: what is still queued for that party under that request. A party with several requests outstanding reads them separately, and finds their IDs in the event log. A user can have multiple mint/redeem requests concurrently.

Every choice takes `actors : [Party]`, the owner and/or an authorized provider, and extraArgs.

On Vault:

| Choice | Consuming? | Takes | Slippage |
| --- | --- | --- | --- |
| `Vault_Deposit` | Yes | assets, receiver | minSharesOut |
| `Vault_Mint` | Yes | shares, receiver | maxAssetsIn |
| `Vault_Withdraw` | Yes | assets, owner, receiver | maxSharesIn |
| `Vault_Redeem` | Yes | shares, owner, receiver | minAssetsOut |

On async interfaces:

| Choice | Interface | Consuming? | Takes | Returns |
| --- | --- | --- | --- | --- |
| `Vault_RequestDeposit` | VaultAsyncDeposit | No | assets, receiver | RequestId |
| `Vault_RequestRedeem` | VaultAsyncRedeem | No | shares, owner, receiver | RequestId |

`Vault_Deposit` and `Vault_Redeem` define what asset can be deposited and redeemed respectively. `Vault_Mint` mints exact shares for the deposited amount, while `Vault_Withdraw` sends exact assets to the user and burns their corresponding shares.

`Vault_RequestDeposit` and `Vault_RequestRedeem` are nonconsuming, meaning shares are not immediately minted/burned, but rather an escrow is placed until fulfillment.

Slippage settings only apply to instant vaults. For all Vault choices above, the caller sets an optional slippage limit and, if that is exceeded, the vault fails with `VAULT_SLIPPAGE_EXCEEDED`. None means any rate is acceptable and no slippage limit has been requested. For async vaults, `Vault_RequestDeposit` and `Vault_RequestRedeem` convert at fulfillment, so requesters can't set a slippage limit.

Because that rate is struck at fulfillment, a queued request can't be quoted in advance either. On an asynchronous deposit vault, previewDeposit and previewMint fail, and on an asynchronous redemption vault, previewWithdraw and previewRedeem fail.

The Vault interface has a max method for every one of its actions: deposit, withdraw, mint and redeem. Each defines the maximum value that action can fulfill for the calling party. Every vault implements Vault, so these answer for queued requests as well as instant ones. When a user wants to transact, their wallet calls maxDeposit before a deposit, maxRedeem before a redemption, maxMint before minting and maxWithdraw before withdrawing. If the amount fits, the transaction will settle. Zero means that party can't do that action right now, whether because the vault is closed, at capacity, or not open to them.

To note, max methods are per-call limits, enforced on-ledger, so a wallet quoting a stale figure gets a failure rather than a wrong fill.

#### The View

Only a contract's signatories and observers can see that contract's View, meaning a wallet can't read the vault's state. It gets the View by explicit disclosure: the vault serves the `created_event_blob` over an OpenAPI endpoint, specified alongside the Daml interfaces the way CIP-56/112 do, and the wallet attaches it to its transaction submissions. The blob is fetched per request, since the vault archives on every state change. Wallets find the endpoint by reading the CNS metadata of the vaultRegistrar party, the same way CIP-56 has them find the registry's URL.

| Field | Type | Purpose |
| --- | --- | --- |
| vaultId | Text | Unique per registrar, stable across archives |
| vaultRegistrar | Party | Vault share instrument admin and settlement executor |
| custodian | Party | Holds the pooled underlying |
| underlyingInstrument | InstrumentId, admin | Vault deposit asset |
| shareInstrument | InstrumentId, admin | Vault share token |
| totalShares | Decimal | Sum of all vault shares minted |
| totalAssets | Decimal | Sum of all vault deposits plus yield accrued |
| rate | Rate | Share price. Defined in this standard, either computed or attested |
| settlementDeadlineWindow | Optional RelTime | Where set, every committed allocation is created with settlementDeadline = requestTime + this. None means requests have no deadline and are recoverable only if an executor acts |
| executors | [Party] | Who can settle or cancel a Pending request |

Rate is a sum type with two variants - ComputedRate and AttestedRate. ComputedRate carries totalAssets as of a timestamp asOf, plus an optional Accrual of a per-second rate that is either simple-linear (APR) or continuously-compounding (APY). When the accrual is present, the rate is continuous, and wallets and the on-ledger methods both accrue totalAssets from asOf to the evaluation time. When it's absent, the rate is discrete: it is calculated only when there is a transaction on the vault. AttestedRate, on the other hand, carries the price in the underlying token per share, the authority that set it, an effectiveAt time and a priceId. Both variants carry depositFeeBps and redeemFeeBps.

#### Settlement

A Daml contract can't own a Holding, so the pooled underlying sits with the custodian party named on the View. The vaultRegistrar is the admin of the share instrument, so issuing and burning shares are transfer legs against the admin-managed accounts CIP-112 reserves with `owner = None`.

On the sync path, a deposit is one exercise: it moves the underlying to the custodian and mints shares to the depositor, subject to minSharesOut. Redeem is the exact opposite - it moves the underlying from the custodian back to the depositor and burns their shares. Neither needs a custom preapproval when the user exercises the choice, since that transaction carries the authority of the user, the registrar and the custodian.

Legs involving the underlying asset can come back as Pending rather than Completed, because that asset's registry may create a TransferInstruction instead of executing the transfer immediately. A vault MUST require Completed, and MUST NOT mint or burn shares against a leg still pending.

On the async path, the requester creates two allocations in one signature: one funded, for assets they deposit or withdraw, and one unfunded, authorizing them to receive something back. Where the vault publishes a settlementDeadlineWindow, the funded escrow carries settlementDeadline = requestTime + settlementDeadlineWindow, and when the deadline passes the requester recovers the escrow with `Allocation_Withdraw`. Where the vault publishes None, there is no deadline and the escrow is released only when an executor settles or cancels. Fulfillment settles both legs through `SettlementFactory_SettleBatch` at one struck rate, delivering to the receiver and leaving any unfilled remainder as Pending. Atomicity across the two admins rests on the executors.

To top up a Pending request, we follow CIP-112: a second allocation with the extra holdings, settled together with the first one in a batch.

#### Valuation

The published totals include any virtual offset, so off-ledger math is bit-identical to on-ledger math. Total deposits come off the View for both: A(t) for computed, price × totalShares for attested.

#### Deferred to Implementation

These are items that belong in the specification section, but we can't pin their exact form until we write the code. They are:

- The normative quoting formulas, which ensure each read method rounds in a fixed direction, so a wallet only has to implement the math once. This is for methods in the View;
- The rounding rules, including the first-depositor inflation mitigation, which every vault carries;
- The VaultEventLog choice and event type, following CIP-112's EventLog pattern: one nonconsuming choice with no side effects, exercised in the same transaction as the action it reports;
- VaultDelegateAuth, the template an owner signs to let a delegate act for them, with a scope, separate deposit and redeem permissions, a cap and an expiry;
- The eligibility rule for permissioned vaults, expressed as max methods returning zero with on-ledger evidence visible to the party;
- The `actors : [Party]` threading for custodians and delegates;
- Contract identity and the rule for re-reading a vault whose contract id has changed.

## Limitations

- Batch fulfillment has a portable ceiling of 25 transfer legs, which CIP-112 requires registries to uphold. This means that, for example, a queue of 200 requests is exactly eight batches, each striking its own rate.
- Consuming choices serialize per vault, so a wallet may submit against an archived contract id.
- A delegated transaction may not survive to submission. The vault contract archives on every deposit, so a transaction prepared for external signing may be stale before it comes back approved. Vaults with meaningful traffic won't support the signing windows CIP-56 asks registries to allow, or CIP-103's asynchronous approval flow.
- A queued request has no slippage limits. The rate is set at fulfillment and the requester either takes it immediately or waits for the deadline (if the vault has a deadline).
- A vault with no settlementDeadlineWindow can indefinitely keep a request without filling it. Funds for these requests are recoverable only when an executor settles or cancels the request, meaning a vault with no deadline gives the user no way out on its own.
- Settlement can fail for multiple external reasons associated with token standards:
  - CIP-112 allows it to fail if context has changed since the allocation was created, blocklisting being the example, and it fails the batch rather than the request;
  - A paused underlying registry blocks both paths regardless of vault state.
  - Recovery after the deadline depends on the registry. CIP-112 says registries should allow the user to withdraw once the deadline passes, but doesn't require it, so whether a requester can actually get their funds back depends on the registry holding the underlying.
- Redeem is limited by the liquidity in the vault, surfaced through maxRedeem and served through the queue.
- There is only one underlying per vault.
- Two-instrument settlement needs cross-admin coordination, since a deposit moves the underlying and the shares under different admins.

## Alternatives Considered

- Shares as internal position contracts rather than a CIP-56 token, i.e. a per-depositor contract holding a share balance. Rejected because it isn't composable, which is R2: a position contract can't be transferred, quoted, held by another vault or posted as collateral without per-vault integration, which is the problem the standard exists to remove.
- A single VaultAsync interface covering both deposits and withdrawal. Rejected because a wallet has to be able to tell that deposits are instant while redemptions queue or vice versa, and one interface collapses that signal. ERC-7540 sets the same precedent with separate interface IDs, one for asynchronous deposit vaults and one for asynchronous redemption vaults.
- Basing the vaults on the pull method, as ERC-7540 does. Rejected because the benefits the pull model enables on EVM don't apply on Canton. The main benefit it brings on EVM is that it makes it cheap to mint tokens because each user mints their own tokens and pays the respective gas fees. That doesn't apply on Canton, as shares are their own contract and thus create ledger state whichever design we pick, negating the gas benefits of the pull model on EVM. In addition, using the pull model would force the user to sign two transactions, whereas with a push model, they need only sign one. As such, push brings more simplicity with nearly the same gas costs, making it the best choice for Canton.
- Making the settlement deadline mandatory. Rejected because vaults may hold illiquid assets. In this case, their registrar can't predict when there will be liquidity to fill a redemption request. If a deadline passes, the request expires and the user has to submit a new one, which might also not get filled during the new deadline. ERC-7540 doesn't have a deadline at all, but this creates a limitation: requests can be stuck in the Pending state indefinitely. ERC-7887 was written to add a way for users to cancel them. In our design, we make the window optional and publish it on the View, so a wallet can tell the user whether the vault they are entering has a deadline or not.
- Specifying the settlement mechanics normatively. Rejected because fixing one call sequence would bind every vault to whatever settlement logic suits a particular registry, and the two-instrument case already admits more than one correct shape. ERC-7540 sets precedent for not enforcing settlement and letting the vault owner determine it. The consequence of this is that we don't specify how a request moves from Pending to fulfilled, but we do define the lifecycle, the escrow, the executor disclosure, the deadline window and one rate per fulfilled set. We leave settlement logic to the implementer.

## Implementation Concerns

### Backwards Compatibility

This package doesn't change how any existing CIP currently works and it is a purely additive addition to the ecosystem. Existing tokens and vaults are unaffected.

There is, however, an exception to this involving vault share tokens. For these tokens to be interoperable with wallets and custodians that only support CIP-56 tokens and not CIP-112, the share registry has to serve the v1 API alongside v2. That's supported by splice-token-standard-utils, but it's an explicit implementation choice rather than something you get automatically with v2.

### Impact Areas

#### API Change Template

| Component | Owning team | Is a change needed? |
| --- | --- | --- |
| splice-sync-connect | Splice | No |
| sv-app | Splice | No |
| scan-app | Splice | No |
| Amulet Daml models | Splice | No |
| DSO governance Daml models | Splice | No |
| Token Standard Daml models | Splice | No |
| Canton Coin configuration | Super Validators | No |
| Canton | Canton | No |
| canton-vault-standard | New | New |

The package name is provisional. The token standard packages are named splice-api-token-* and live in the Splice repo, so if the vault standard is adopted the same way, both the identifier and the owning team in the last row change. That's a question to decide based on who will own the standard moving forward.

#### Documentation Structure

There will be a vault standard section under Application Development, alongside the token standard's, with the same structure: an overview, a guide for Daml developers implementing a vault, and a guide for wallets and aggregators integrating one. The integration guide will use the patterns the Token Standard CLI and splice-wallet-kernel already use.

### NFR Changes

#### Security

- A vault has a registrar and a custodian, so it isn't trustless the way an ERC-4626 vault is. How that is implemented depends on how the custodian is configured: it can be an ordinary party, a decentralized party requiring a quorum, or even a party that can't submit at all and acts only through a governing contract. The standard leaves that choice open.
- The executor set is a trust parameter, not a configuration. That means parties in the executor set can settle or cancel any Pending request, so the set has to be published on the View. The CIP doesn't specify how to avoid the risk of having a single executor with full powers to cancel; that is also left for implementers. Note that users can't cancel their own requests in async vaults with no deadline, rather the executors must do it. If there is a deadline, then that limitation does not apply and users can cancel once the deadline has passed.
- Batch-settlement logic is up to the implementer. CIP-112 requires the implementer to verify that the allocations belong to the settlement being executed, that both sides of the specified transfers are authorized, and that the supplied legs are covered exactly.
- Slippage limits protect users from rate movement between quote and commit on the sync path, and conformance with the token standard requires failure with no state change when a slippage limit is exceeded. A queued request has no slippage limits.
- Every vault mitigates the first-depositor inflation attack by rejecting a deposit that would mint zero shares. Whatever mitigation a vault uses has to be reflected in its published quoting values, so off-ledger math matches on-ledger. We considered exempting the vaults that structurally can't receive an unsolicited transfer, but a self-reported exemption on a security property is worse than a constant in the math.
- Rounding is always done in the vault's favour, with a self-check to enforce it.
- Minting is recorded via on-ledger accounting. Attested vaults have oracles that define the issuer's price, surfaced through {authority, effectiveAt}, though the standard doesn't check the oracle price liveness; that is up to the implementer.
- A delegate acting for an owner has considerable power, so VaultDelegateAuth requires a scope, a cap and an expiry, always scoped by the stable vaultId and never a contract id. Revoking delegation takes effect immediately, and its authorization is validated at exercise time rather than trusted from an earlier check.
- Replay and double-satisfaction attacks are prevented because settling an allocation archives it, so the same allocation can't be settled twice and one escrow can't satisfy two requests.
- The registrar and custodian are signatories on the vault, and the observer set beyond them stays minimal: the owner, the two instrument admins and the executors. The VaultEventLog controls who sees which event and a public observer only gets added if the vault allows it.
- Serving the View over the API makes the vault state readable by whoever fetches it, which suits an open vault but may not suit a permissioned one. To note, CIP-56 leaves API authentication out of scope.

## Requirement Analysis

| Nr. | Requirement |
| --- | --- |
| R1 | One Vault interface, with valuation left to the implementer and so that a single integration covers computed and attested, instant and queued, open and permissioned, sync and async vaults. |
| R2 | Shares are ordinary token standard holdings, so they can be transferred, quoted, held by another vault or used as collateral without custom code. |
| R3 | A depositor sees what they would receive from the View and the formula table, and the most they may transact from maxDeposit, maxMint, maxWithdraw and maxRedeem. They can tell if the figures are current because ComputedRate has a timestamp and an optional accrual model, meaning vaults can communicate APR and APY during certain time periods. For sync vaults, the user sets slippage requirements which limit the vault shares they will receive/give up when doing a transaction. Async vaults have no slippage limits. |
| R4 | Transactions can't partially settle. Sync vaults settle in one exercise and revert if the underlying leg can't complete; shares are never minted or burned against a pending transfer. Async vaults settle both legs together at fulfillment. Transactions can also be cancelled, although how depends on whether there is a deadline or not. When there is a deadline, users can recover their own escrow using `Allocation_Withdraw` once it passes. Where there is no deadline, the executors are the only ones able to cancel requests. The window is on the View, so a depositor knows before committing if the vault has a deadline or not. |
| R5 | Users can place in-flight requests via `Vault_RequestDeposit` and `Vault_RequestRedeem`, and track them through pendingDepositRequest and pendingRedeemRequest, identified by the RequestId the request returns. Every conformant vault reports the same way, so a wallet shows one status across all of them. |
| R6 | Access can be delegated by setting `actors : [Party]` on every choice, the native provider on an account for a custodian, and VaultDelegateAuth for a chosen agent, identified by the vaultId with a cap and an expiry. |
| R7 | A vault's total deposits can be tracked by totalAssets, rates can be tracked by ComputedRate or AttestedRate. A party's position is tracked by their own shareInstrument, and their pending requests are tracked by RequestId. VaultEventLog gives third-parties a way to track the vault's event history in a uniform way across all vaults, and vaultId identifies a vault across archives. |
| R8 | Rounding is always done in the vault's favour, as conformance mandates. The standard also implements a rejection on the minting of zero shares and a virtual offset to mitigate inflation attacks. |

## Testing

### Functional Test Coverage

The test suite consists of a set of Daml Scripts and sandbox tests that together stress test all the logic in this document to ensure its resilience when facing edge cases and to ensure that the standard works the same across use cases.

The Daml script tests are built on splice-token-standard-test and test share accounting, rounding, rate accrual and invariant logic. The set of integration tests is run against LocalNet or DevNet and cover settlement, atomicity, executor authority, delegation and event visibility.

The performance tests should cover throughput and commit latency across both deposit/redeem paths, the additional event-log cost per action, `Allocation_Settle` scaling with leg count and batch size, and ACS growth as the number of concurrent vaults, holdings and pending allocations increases.
