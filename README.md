# Canton vault

A vault implementation for Canton, built on the Splice token standard
(CIP-56 / CIP-112).

A vault accepts deposits of a single underlying instrument and issues share
holdings against them, which can later be redeemed for the underlying. Shares
are ordinary token standard holdings, so anything that handles holdings handles
vault shares.

Design: [Design: Canton Vault standard](https://docs.google.com/document/d/1xQG-5p7m9Rh59QYs8UwL_LyaEWbQDCQBuSajRHXBRFw/edit).

Early. Deposit and redemption work end to end; the interfaces will change.

## How it works

`Vault_Deposit` moves the underlying to the vault's custodian through that
instrument's transfer factory and mints share holdings to the receiver, in one
transaction. A leg that comes back pending rather than completed mints nothing.
Redemption is the reverse. The caller names the holdings funding each leg, in
`extraArgs.context`, since a registry cannot search the ledger for them.

Pricing is a computed rate with optional linear or continuous accrual, fixed for
a rate period published on the vault's view. Every quantity rounds in the
vault's favour, and a deposit that would mint zero shares is rejected. Without
accrual no action reads the clock: the period's end and any expiry are checked
as ledger-time bounds, as the token standard checks its deadlines, so an action
prepared for external signing stays valid until its period ends.

The choices are nonconsuming, so concurrent deposits do not contend on the vault
contract. Each action records what it moved, and the registrar folds those in
when it opens the next rate period, merging them as they accumulate so a roll
stays small. Each action is also reported to the parties who took it and its
receiver, through a log created and archived in the same transaction, as the
token standard's event log does: it shows in their transaction history and
leaves nothing on the ledger.

## Queued requests

A queued-deposit vault takes a request instead of settling at once. The
requester escrows the underlying as a committed allocation, and the receiver
authorizes being issued shares, both under the vault's settlement id
(`requestSettlementId`). The vault records the pair as a registrar-signed
request, whose id is the rate period it was made in.

Once that period closes, executors fulfil requests in batches, settling both
registries' legs in one transaction, at the price struck when the next period
opened: everyone who requested in a period gets one price, which nobody knew
when they requested. A request filled later than that gets the current price if
it is worse for the requester, so a late fill never beats the market. A
requester may set a minimum number of shares, below which the request is not
filled.

A batch settles whole or not at all, so one request that cannot settle, such as
a receiver its registry has blocked, fails the rest. Executors dry-run a batch,
settle the requests that pass, and `Reject` the one that fails, which returns
its escrow and reports why. Every registry accepts batches of up to 25 legs, one
per request per registry; Canton Coin accepts 100.

Fulfilments and rejections are reported to the requester and receiver through a
log created and archived in the same transaction, as the token standard's event
log does, so they leave nothing on the ledger. Requests expire with their escrow.
The registrar folds period flows together as they accumulate
(`PeriodFlow_Merge`) and drops expired requests and old struck prices, so neither
the roll nor the ledger grows with activity.

## Trust and limits

- The registrar is trusted. It strikes the price at each roll from the pool it
  measures, pauses the vault and re-pins its factories, and as admin of the
  share instrument it can issue itself shares and drain the pool. Holders rely
  on it as they rely on a fund's administrator.
- A roll may move the price only within the vault's limits: a rise of so many
  basis points a year, pro rata for the period, and a one-off fall. A move
  beyond them, or a change to them, needs the custodian as well as the
  registrar, so a mistaken measurement cannot reprice the vault on one party's
  word.
- Each vault has its own custodian. Every unlocked holding of the underlying the
  custodian owns counts as the vault's pool, so two vaults sharing one would
  count each other's assets. The ledger cannot check this; the registrar must
  not reuse a custodian.
- Prices are fixed for a rate period. Value that enters or leaves the pool
  outside vault actions, such as yield or a loss, shows only at the next roll:
  roll promptly after one, and use accrual for steady yield. On Canton Coin a
  period is at most 90 days, the longest a transfer may live.
- A redemption names the pool holdings it pays from, and two redemptions naming
  the same holding collide: one fails. Clients pick holdings at random and retry.
  Keeping the pool in several holdings lets redemptions run side by side; merging
  them now and then keeps a roll's read small (a Canton Coin transfer takes at
  most 100 inputs).

## Packages

| | |
| --- | --- |
| `api/canton-vault-v1/` | `canton-vault-v1` — the `Vault` interface and its types, which every vault implements |
| `api/canton-vault-async-deposit-v1/` | `canton-vault-async-deposit-v1` — `VaultAsyncDeposit`, for vaults that queue deposits |
| `reference/` | `canton-vault-reference-v1` — the instant vault, and a queued-deposit vault |
| `test/` | `canton-vault-standard-test` — Daml Script tests and a mock underlying registry |
| `dependencies/` | Vendored Splice DARs; see `dependencies/VERSIONS.md` |

## Build

Requires [dpm](https://docs.canton.network/sdks-tools/cli-tools/dpm) with SDK 3.5.2 and JDK 17.

```sh
dpm install 3.5.2
dpm build --all
cd test && dpm test
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
