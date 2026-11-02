# canton-vault-test-conformance-v1

Daml Script properties that check a vault against the Canton vault standard
(`canton-vault-v1`, `canton-vault-async-deposit-v1`,
`canton-vault-async-redeem-v1`, `canton-vault-event-log-v1`). Write one adapter
for your vault, run one script, and every rule the suite can check through the
interfaces is exercised against it.

The suite depends only on the standard's packages, the Splice token-standard
APIs and `daml-script`. It knows nothing about any particular implementation.

## What it checks

| Property | Rule |
| :- | :- |
| `previewsMatchActions` | Each preview is what its action then does. |
| `conversionsBoundPreviews` | Previews never beat the fee-free conversions. |
| `roundTripsDoNotProfit` | Depositing and redeeming, or minting and withdrawing, returns no more than went in. |
| `maxLimitsAreExact` | Each max method's amount goes through and one unit more is refused. |
| `viewQuotesEveryPath` | A wallet quoting from the view alone, by the formulas `Vault` states, gets every read method's answer, midway through a period and with an accruing rate. |
| `slippageLimitsRefuseAndMoveNothing` | An action just past its limit fails with `vaultSlippageExceeded` and moves nothing. |
| `actorsBeyondTheAccountAreRefused` | The actors must be exactly the sender's or owner's parties. |
| `anAccountWithNoOwnerIsRefused` | An account with no owner is refused everywhere, and `maxDeposit`/`maxMint` are zero for it. |
| `aBasicAccountIsAccepted` | A party's basic account deposits and redeems, instantly or through a request as the vault offers each direction, and the instant paths' max methods leave room for it. |
| `thePoolSitsInTheCustodianAccount` | The view's `custodian` account has an owner; a deposit, instant or queued, lands in it, and an instant redemption pays from it. |
| `actionsMoveTheAccountsNamed` | Shares and payouts go to the accounts named. |
| `nothingIsIssuedForNothing` | A deposit or mint that would issue no shares fails. |
| `actionsFailWhenThePeriodEnds` | Every action fails at `rateValidUntil`. |
| `publicReadsServeTheView` | `Vault_PublicFetch` returns the view; `Vault_PublicConvertToAssets` agrees with `convertToAssets`. |
| `instantActionsAreReported` | Each instant action is reported once, with what moved, to both accounts' parties and the actors. |
| `queuedDirectionsHaveNoInstantPath` | A queued direction's previews fail, its maxes are zero and its instant actions fail. |
| `requestsPublishTheirTerms` | A request publishes allocation requests under the vault's executors, committed no later than the period's end plus the window; the async view says when requests are priced. |
| `requestsAreEndedByTheirParties` | The requester and the receiver can decline and the executors can withdraw, each reported with its close reason. |
| `requestsAreFilled` | A funded request is pending until filled, and the receiver is paid. |
| `minimumsAreHonoured` | A request whose minimum no fill can meet stays queued and pays nothing. |
| `requestIdsKeepTheirPromise` | A direction's requests take the id `0` all or none, and two sharing another id are filled together, at one rate. |
| `pendingRebuildsFromEvents` | What a request has queued, rebuilt from the events alone, equals the pending methods at every step. |
| `delegatesActWithinTheirAllowance` | `VaultDelegateAuth` works against the vault, and its allowance is spent. |

Properties that don't apply are skipped, with a `debug` line saying why: the
queued ones on a vault that queues nothing, a fee configuration the vault
doesn't offer, and so on.

## Running it against your vault

Implement a `Harness` (in `Canton.Vault.Testing.V1.Harness`). It is the part
of driving a vault that the standard leaves to you:

- `deploy` creates a fresh vault for a `VaultConfig` (fees, an optional
  deposit cap and an optional accrual), or returns `None` if you don't offer
  that configuration.
- The `Deployment` it returns says who can read the vault on-ledger, finds the
  vault as it stands, funds a party with the underlying, and serves the choice
  context and disclosures your endpoint would serve for an entry or an exit.
  It also rolls the rate period and, if you can, changes the vault's value from
  outside, as yield or a loss would.
- For a vault with a queued direction, `queue` makes allocations as a wallet
  would, accepts a request's funding, fills, rejects, and names a party's
  requests for the pending methods. Each returns the transaction trees it
  submitted, so the suite can read your events.
- `issue` is for test environments where a deposit can't complete through the
  vault, for example a registry that needs the custodian's consent. It gives a
  party shares that your books count, and the properties that need a deposit to
  succeed are then skipped.

Then, in a test package that depends on this one:

```daml
import Canton.Vault.Testing.V1.Suite (conformance)

myVaultConforms : Script ()
myVaultConforms = conformance myHarness
```

`conformance` runs every property and stops at the first failure. To see each
property as its own test, call them one by one from `Canton.Vault.Testing.V1.Suite.properties`.
A run too large for one script, which the script service cancels with
`StatusCancelled`, can be split with `conformanceOf` over parts of `properties`.

Two adapters show the shape: `test`'s `ConformanceReference` runs the
suite against the three reference vaults, and `canton-vault-test-minimal-vault-v1`
is a small independent vault with its adapter.

## Not yet checked

The slippage failure waits on a decision about the standard: the suite
matches the `vaultSlippageExceeded` text, and if the standard moves to a
structured error, the check moves with it.

Partial fills aren't checked, so neither is the rule that requests sharing an
id fill in the same proportion: how and when a vault fills in part is its own,
and the harness has no way to ask for one.
