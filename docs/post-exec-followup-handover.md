# Post-Exec Follow-Up Handover

## Purpose

This document expands the remaining known limitations of the current branch and describes the most likely follow-up work needed after the wrapper-based post-exec implementation.

## Current state

The branch successfully adds:
- wrapper-based post-exec transaction support in Rust
- post-exec payload/replay support
- receipt-level `opGasRefund`
- op-reth debug replay RPC support
- focused acceptance coverage for SDM behavior using the post-exec transaction

The main architectural goal of the branch is achieved: **the feature works without vendoring upstream transaction/codec crates**.

## Main remaining limitation

### 1. Downstream Go paths do not fully understand the synthetic `0x7d` post-exec transaction

#### Summary
The Rust-side implementation can build, replay, and account for the synthetic post-exec transaction correctly, but some downstream Go-based historical block / payload handling paths still assume all transactions decode through standard go-ethereum transaction types.

That assumption breaks once a block contains the synthetic post-exec transaction type `0x7d`.

#### Observed symptom
The clearest observed downstream failure is:
- `transaction type not supported`

This occurs after a block containing the post-exec tx has already been produced, which is why the focused acceptance tests in this branch can still pass.

#### Most likely cause
A key likely choke point is:
- `op-service/sources/types.go`

That file currently models RPC block transactions as:
- `[]*go-ethereum/core/types.Transaction`

Relevant code:
- `op-service/sources/types.go`
  - `type RPCBlock struct { ... Transactions []*types.Transaction ... }`

This means historical block fetching / payload reconstruction on the Go side still depends on geth transaction decoding. Since geth does not know the synthetic post-exec tx type, the decode path rejects it.

#### Why this is outside the core Rust wrapper work
This branch deliberately solved the extensibility problem on the Rust side by avoiding direct widening of upstream OP tx enums.

The remaining issue is different:
- it is about **downstream Go consumers decoding historical transactions too eagerly into geth transaction types**
- not about the Rust wrapper architecture itself

#### Impact
Impact is expected in any flow that:
- fetches historical blocks with full transactions from RPC
- decodes them through `go-ethereum/core/types.Transaction`
- later reconstructs payload tx bytes from that decoded representation

This is most likely to affect:
- op-node historical payload retrieval paths
- block derivation / parent payload handling paths that revisit already-produced blocks
- any other Go helper that assumes every tx in an OP block is a geth-native supported type

#### Suggested follow-up directions
Potential fixes to evaluate:

1. **Raw transaction preservation path**
   - Fetch historical block transactions in a raw/opaque form instead of decoding them directly into `*types.Transaction`
   - Preserve tx bytes for payload reconstruction rather than round-tripping through geth transaction decoding

2. **Custom decode support in Go paths**
   - Add an OP-aware transaction wrapper/decoder in Go for historical payload handling
   - This is likely more invasive than preserving raw bytes

3. **Narrowed compatibility boundary**
   - If full Go-side decode support is out of scope, explicitly document which downstream components cannot yet consume blocks containing `0x7d`

#### Recommended first investigation
Start by tracing the op-node/op-service path from historical block RPC fetch to payload tx reconstruction, beginning with:
- `op-service/sources/types.go`

The goal is to find where transaction bytes are lost and replaced with eager geth decoding.

---

## Secondary issues / cleanup items

### 2. Naming boundary: SDM vs post-exec

#### Summary
The feature name is **SDM**, while the mechanism it uses is the **post-exec transaction**.

The branch already moved the user-facing flag to:
- `--rollup.sdm-enabled`

But there is still a conceptual split that should remain explicit:
- **SDM** = feature / behavior
- **post-exec tx** = transaction mechanism used to encode canonical refund metadata

#### Guidance
When doing follow-up work:
- keep user-facing config and feature toggles under `sdm`
- keep transaction- and payload-specific structures under `post_exec`

This avoids reintroducing naming confusion.

---

### 3. Acceptance tests still live under `op-acceptance-tests/tests/sdm/`

#### Summary
The restored tests were copied from the PoC and updated for current RPC/response naming, but the directory and some test names still reflect the PoC’s SDM terminology.

That is acceptable for now because the feature is still SDM, but follow-up cleanup may be useful if the project wants a cleaner distinction between:
- SDM as a feature
- post-exec as the transaction mechanism

#### Suggested options
Either:
- leave them as `sdm/` because SDM remains the feature name, or
- rename/move only if the team wants test layout to reflect mechanism rather than feature

---

### 4. RPC compatibility expectations should be treated carefully

#### Summary
This branch already hit one integration mismatch around replay RPC naming and replay response field naming.

Current accepted naming in the updated tests is the post-exec form for response fields, while the debug method is whatever the node currently exposes.

#### Guidance
For follow-up RPC work:
- verify behavior against a real node, not just compile-time traits
- treat RPC method names and JSON field names as compatibility surfaces
- prefer adding compatibility aliases if external tooling has already depended on older names

---

## What is not the main problem anymore

The following are largely solved by this branch and should not be treated as the primary blocker:
- wrapper-based transaction extensibility in Rust
- replay execution itself
- receipt refund plumbing
- post-exec tx production in op-reth
- acceptance coverage for the focused scenarios included in this branch

---

## Recommended next-session checklist

1. Reproduce the downstream `transaction type not supported` failure intentionally
2. Trace the full Go historical block/payload retrieval path
3. Confirm whether `op-service/sources/types.go` is the first decode boundary that rejects `0x7d`
4. Decide whether to:
   - preserve raw tx bytes in Go historical fetch paths, or
   - introduce OP-aware decoding support in Go
5. Add a targeted regression test for the chosen fix
6. If not fixed in the next step, document the unsupported downstream path explicitly in user/developer docs

## Key files to inspect first

Rust side for reference:
- `rust/op-reth/crates/node/src/args.rs`
- `rust/op-reth/crates/rpc/src/witness.rs`
- `rust/op-reth/crates/post-exec-replay/src/replay.rs`
- `rust/op-reth/crates/post-exec-replay/src/types.rs`
- `rust/op-alloy/crates/consensus/src/sdm.rs`
- `rust/op-reth/crates/primitives/src/transaction/ext.rs`

Go side for likely follow-up work:
- `op-service/sources/types.go`
- nearby op-node payload/block retrieval code that consumes `sources.RPCBlock`

## Bottom line

The branch’s main design objective is complete: post-exec support was implemented without vendoring upstream crates.

The main unresolved issue is now an integration boundary in downstream Go consumers that still expect all transactions in historical OP blocks to decode as standard geth transaction types. That follow-up should be treated as a Go payload retrieval / decoding problem, not as a flaw in the Rust wrapper architecture.
