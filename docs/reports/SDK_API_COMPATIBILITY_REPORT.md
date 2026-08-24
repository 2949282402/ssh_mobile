> Last updated: 2026-08-21

# SDK API Compatibility Gate

Status: **PASS**

The public entry point remains
`packages/infrastructure/network_sdk/lib/network_sdk.dart`. Its export set is
unchanged, and the existing Network V2 declarations remain available from
`package:network_sdk/network_sdk.dart`. The V2 port and facade implementations
were moved into library parts so the public library identity and import paths
did not change.

## Compatibility checks

| Surface | Result | Evidence |
| --- | --- | --- |
| Public classes and enums | PASS | Existing `NetworkV2*`, request, result, event, `NetworkFacade`, `SessionClient`, realtime, HTTP, and model declarations remain exported |
| Public methods and callbacks | PASS | Existing method names, positional/named parameters, return types, and callback/event stream shapes are unchanged |
| Event model | PASS | `NetworkV2Event` and legacy `SdkEvent` families remain intact; new domain ports reuse the existing typed events |
| Error types | PASS | `NetworkError`, `NetworkErrorCode`, retry fields, and legacy aliases remain unchanged |
| Compatibility aliases | PASS | `NetworkResult`, `NetworkSuccess`, `NetworkFailure`, `NetworkService`, and related aliases remain in `network_clients.dart` |
| Ownership behavior | PASS | `NetworkV2FacadeImpl.dispose()` now releases only facade state and does not stop/dispose the injected App/native-owned port; this corrects the documented ownership contract without changing the signature |

## Additive domain surface

The V2 contract now exposes explicit function-domain ports and adapters:

- `NetworkV2ConnectionPort`
- `NetworkV2IdentityPort`
- `NetworkV2TransferPort`
- `NetworkV2RealtimePort`
- `NetworkV2RelayPort`

`NetworkV2CommandPort` remains the compatibility-preserving App/native command
boundary. `NetworkV2FacadeImpl` delegates through the domain adapters, so
Features keep the existing facade methods while implementation ownership is
separated.

## Regression evidence

- `flutter analyze --no-pub` in `packages/infrastructure/network_sdk`: passed.
- `dart format --output=none --set-exit-if-changed lib test` in
  `packages/infrastructure/network_sdk`: passed with no changes.
- `flutter test --no-pub` in `packages/infrastructure/network_sdk`: 74 tests
  passed, including 23 lifecycle, domain-routing, tracker, value-boundary,
  event, and error-precedence tests in `test/network_v2_facade_test.dart`.
- `bash scripts/network_v2_acceptance.sh strict`: passed; the strict selector
  now executes both V2 SDK test files.
- `git diff --check`: passed after the migration.

No public API breaking change was introduced.
