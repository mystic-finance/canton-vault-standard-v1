# Canton vault standard

A vault standard for Canton, in the spirit of ERC-4626/7540, built on the
Splice token standard (CIP-56 / CIP-112): a set of Daml interfaces any vault
can implement, a reference implementation, and a conformance test suite.

## Packages

- `api/` — `canton-vault-standard-v1`: the interfaces and types.
- `reference/` — `canton-vault-reference-v1`: a reference vault.
- `test/` — `canton-vault-standard-test`: conformance tests.
- `dependencies/` — vendored Splice token-standard DARs (see `dependencies/VERSIONS.md`).

## Build

Requires [dpm](https://docs.canton.network/sdks-tools/cli-tools/dpm) with SDK 3.5.2 and JDK 17.

```sh
dpm build --all
cd test && dpm test
```


## License

Apache 2.0 — see [LICENSE](LICENSE).
