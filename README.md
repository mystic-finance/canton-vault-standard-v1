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
vault's favour, and a deposit that would mint zero shares is rejected.

The choices are nonconsuming, so concurrent deposits do not contend on the vault
contract. Each action records what it moved, and the registrar folds those in
when it opens the next rate period.

## Packages

| | |
| --- | --- |
| `api/` | `canton-vault-standard-v1` — the `Vault` interface and its types |
| `reference/` | `canton-vault-reference-v1` — a vault implementing it |
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
