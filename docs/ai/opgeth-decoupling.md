# op-geth Decoupling Analysis

This document analyses the dependencies of the optimism monorepo Go services on op-geth–specific
APIs, and proposes decoupling strategies for each. The goal is to depend on upstream go-ethereum
instead of op-geth without opening upstream PRs. The scope is op-node, op-service, and op-batcher
(op-program is explicitly excluded).

The op-geth diff vs. upstream go-ethereum v1.16.9 can be summarised in three kinds of change:

1. **New standalone types/files** – `DepositTx`, `RollupCostData`, the `superchain/` package,
   protocol-version types, eip1559 Holocene/Jovian helpers, `SuperchainSignal`.
2. **Fields/methods added to existing upstream types** – `Transaction` methods (`IsDepositTx`,
   `SourceHash`, `Mint`, `IsSystemTx`, `RollupCostData`), `Receipt` L1-cost fields, `ChainConfig`
   OP hardfork fields and methods, `PayloadAttributes` extensions.
3. **Config/CLI wiring** – how op-geth starts: not relevant to the monorepo.

---

## Target package layout in the monorepo

All op-geth-specific code will be extracted into `op-core/`, with new packages living directly
under that directory (alongside the existing `op-core/forks/` and `op-core/predeploys/`):

| Source (op-geth) | Destination (monorepo) |
|---|---|
| `core/types/deposit_tx.go`, `rollup_cost.go`, `receipt_opstack.go` | `op-core/types/` |
| `params/config_op.go`, `params/superchain.go` (versioning + `OptimismConfig`) | `op-core/params/` |
| `superchain/` package + `sync-superchain.sh` | `op-core/superchain/` |
| `op-service/superutil/` | merged into `op-core/superchain/` |
| `consensus/misc/eip1559/eip1559_optimism.go` | `op-core/consensus/eip1559/` |
| `eth/catalyst/superchain.go` (SuperchainSignal, LogProtocolVersionSupport) | `op-core/superchain/` |

---

## 1. `core/types` – Deposit transaction

### Current usage

`types.DepositTx` (new file in op-geth, type `0x7E`) is used in op-node to construct deposit
transactions. The **universal pattern** is:

```go
opaqueTx, err := types.NewTx(&types.DepositTx{
    SourceHash:          source.SourceHash(),
    From:                someAddr,
    To:                  nil,
    Mint:                big.NewInt(0),
    Value:               big.NewInt(0),
    Gas:                 375_000,
    IsSystemTransaction: false,
    Data:                bytecode,
}).MarshalBinary()
```

Every call immediately calls `.MarshalBinary()` and discards the `*types.Transaction`. The result
is always `[]byte` (opaque RLP for the Engine API payload). Locations:

- `op-node/rollup/derive/deposits.go` – `DeriveDeposits` (user deposits from L1 logs)
- `op-node/rollup/derive/deposit_log.go` – `UnmarshalDepositLogEvent` (returns `*types.DepositTx`)
- `op-node/rollup/derive/*_upgrade_transactions.go` – Ecotone, Fjord, Holocene, Isthmus, Jovian,
  Interop (one `types.NewTx(...).MarshalBinary()` per upgrade deposit)
- `op-node/rollup/interop/indexing/attributes.go` – builds then immediately marshals

The only exception is `DecodeInvalidatedBlockTx` (same file), which decodes an RPC-received tx:

```go
var tx types.Transaction
_ = tx.UnmarshalBinary(raw)
tx.Type()  // checks == types.DepositTxType
tx.From()  // op-geth specific – returns DepositTx.From field
tx.Data()  // standard upstream go-ethereum
```

`types.DepositTxType` (the `0x7E` constant) is used in op-node and op-service to identify
transactions by type byte.

### Proposed decoupling

**Define `DepositTx` in `op-core/types/deposit_tx.go`**. The wire format is `0x7E || RLP(struct)`,
matching the spec and what op-geth implements. No dependency on go-ethereum's `TxData` interface.

```go
const DepositTxType = byte(0x7E)

type DepositTx struct {
    SourceHash          common.Hash
    From                common.Address
    To                  *common.Address
    Mint                *big.Int
    Value               *big.Int
    Gas                 uint64
    IsSystemTransaction bool
    Data                []byte
}

func (d *DepositTx) MarshalBinary() ([]byte, error) { /* 0x7E || RLP(d) */ }
func UnmarshalDepositTx(raw []byte) (*DepositTx, error) { /* strip 0x7E, decode RLP */ }
```

**Wire compatibility test**: add a differential test in `op-core/types/deposit_tx_test.go` that
imports op-geth's `types.DepositTx`, serialises identical structs with both implementations, and
asserts byte-for-byte equality. This test will be removed when the op-geth dependency is migrated
to upstream go-ethereum.

For type-checking without op-geth, `tx.Type()` already exists on upstream `*types.Transaction`.
So:

```go
func IsDepositTx(tx *types.Transaction) bool { return tx.Type() == DepositTxType }
```

For `tx.From()` (single call site in `DecodeInvalidatedBlockTx`): replace with
`UnmarshalDepositTx(rawBytes)` and read `.From` directly.

**All call-sites** that do `types.NewTx(&types.DepositTx{...}).MarshalBinary()` become
`op-core/types.DepositTx{...}.MarshalBinary()`. The `*types.Transaction` wrapper is eliminated;
we go straight from struct to `[]byte`.

**`UnmarshalDepositLogEvent`** returns `*types.DepositTx` today; change to return
`*opcoretypes.DepositTx`. `DeriveDeposits` calls `types.NewTx(dep).MarshalBinary()`; replace
with `dep.MarshalBinary()`.

---

## 2. `core/types` – Transaction methods on RPC-received transactions

### Current usage

The following methods on `*types.Transaction` are op-geth additions, called on transactions that
arrive as raw bytes from the Engine API or ethclient RPC:

| Method | Locations | Purpose |
|--------|-----------|---------|
| `IsDepositTx()` | op-node `payload_util.go`, op-service `sources/types.go`, op-batcher `types.go` | Detect deposit type (type byte == 0x7E) |
| `tx.From()` | op-node `interop/indexing/attributes.go:105` | Read `From` field of a deposit tx |
| `tx.Data()` | op-node `payload_util.go` | Get tx calldata – **exists upstream** |
| `tx.Type()` | op-node, op-service | Get tx type byte – **exists upstream** |
| `IsSystemTx()` | op-node `rollup/engine/build_seal.go` | Detect system deposit flag |
| `SourceHash()` | op-node (multiple derive files) | Read deposit source hash |
| `Mint()` | op-node | Read deposit mint amount |
| `RollupCostData()` | op-service `txinclude/`, op-batcher `types.go` | L1 cost estimation |

### Proposed decoupling

- `tx.Type()` and `tx.Data()` are **standard upstream** – no change needed.
- `IsDepositTx()`: replace with the free function `IsDepositTx(tx)` from `op-core/types`.
- `tx.From()` (one call site): replace with `UnmarshalDepositTx(rawBytes).From`.
- `IsSystemTx()`, `SourceHash()`, `Mint()`: call `UnmarshalDepositTx(rawTxBytes)` and read
  fields from the monorepo struct. Wrap in short helper functions.
- `RollupCostData()`: define `RollupCostData` type and computation in `op-core/types`. The
  computation only requires `tx.Data()` and `tx.Type()`, both upstream.

---

## 3. `core/types` – Receipt L1-cost fields

### Current usage

op-geth adds OP-specific fields to `types.Receipt`. Investigation confirmed they are actively used
in exactly one non-test location: **`op-service/txinclude/txbudget.go::AfterIncluded`**:

```go
receipt := tx.Receipt  // *types.Receipt, fetched via ethclient.TransactionReceipt()

// l1Cost
if receipt.L1BaseFeeScalar != nil {
    l1BaseFeeScalar := new(big.Int).SetUint64(*receipt.L1BaseFeeScalar)
    l1BlobBaseFeeScalar := new(big.Int).SetUint64(*receipt.L1BlobBaseFeeScalar)
    costFunc := types.NewL1CostFuncFjord(receipt.L1GasPrice, receipt.L1BlobBaseFee, ...)
    l1Cost, _ := costFunc(tx.Transaction.RollupCostData())
    actualCost.Add(actualCost, l1Cost)
}
// operatorCost
if receipt.OperatorFeeScalar != nil {
    // uses *receipt.OperatorFeeScalar and *receipt.OperatorFeeConstant
}
```

The receipt travels: `ethclient.TransactionReceipt()` → `EL` interface → `Monitor` → `Persistent`
→ `IncludedTx.Receipt *types.Receipt`. With upstream go-ethereum, the extra fields would be nil
since the standard JSON unmarshaler does not know about them.

Fields used: `L1BaseFeeScalar *uint64`, `L1BlobBaseFeeScalar *uint64`, `L1GasPrice *big.Int`,
`L1BlobBaseFee *big.Int`, `OperatorFeeScalar *uint64`, `OperatorFeeConstant *uint64`.

Note: `op-service/txinclude/isthmus_cost_oracle.go` does **not** fetch receipts. It reads fee
parameters directly from the L1Block predeploy contract via batch `eth_call`. Receipt fields are
not involved there.

Also note: op-node does **not** read receipt fields directly. It reads `L1BlockInfo` from the
deposit transaction calldata in payloads, which encodes the same values.

### Proposed decoupling

**Define `OptimismReceipt` in `op-core/types/`**, embedding `types.Receipt` with the extra fields
and a custom JSON unmarshaler:

```go
type OptimismReceipt struct {
    types.Receipt
    L1GasPrice          *big.Int `json:"l1GasPrice,omitempty"`
    L1BlobBaseFee       *big.Int `json:"l1BlobBaseFee,omitempty"`
    L1BaseFeeScalar     *uint64  `json:"l1BaseFeeScalar,omitempty"`
    L1BlobBaseFeeScalar *uint64  `json:"l1BlobBaseFeeScalar,omitempty"`
    OperatorFeeScalar   *uint64  `json:"operatorFeeScalar,omitempty"`
    OperatorFeeConstant *uint64  `json:"operatorFeeConstant,omitempty"`
}
```

The `EL` interface in `txinclude` returns `*OptimismReceipt` instead of `*types.Receipt`.
`IncludedTx.Receipt` becomes `*OptimismReceipt`. This contains all the changes within
`op-service/txinclude/`.

---

## 4. `core/types` – `RollupCostData` and `NewL1CostFuncFjord`

### Current usage

`types.RollupCostData` is a struct carrying byte counts of transaction fields for L1 cost
calculation. `types.NewL1CostFuncFjord(l1BaseFee, l1BlobBaseFee, l1BaseFeeScalar,
l1BlobBaseFeeScalar)` returns `func(RollupCostData) (*big.Int, bool)`.

Used in:
- `op-service/txinclude/txbudget.go` – to calculate actual L1 cost after receipt receipt
- `op-service/txinclude/isthmus_cost_oracle.go` – to pre-estimate L1 cost before inclusion
- `op-batcher/batcher/types.go` – `tx.RollupCostData()` for DA size estimation

### Proposed decoupling

Move `RollupCostData` and `NewL1CostFuncFjord` to **`op-core/types/`**. The computation is pure
arithmetic on transaction byte sizes and fee scalars (no EVM, no go-ethereum type dependencies
beyond `*big.Int`). The formulas are documented in the Fjord/Isthmus specs.

---

## 5. `params.ChainConfig` – OP hardfork methods

### Current usage

op-geth adds OP hardfork timestamp fields to `params.ChainConfig` (`CanyonTime`, `EcotoneTime`,
`FjordTime`, `GraniteTime`, `HoloceneTime`, `IsthmusTime`, `JovianTime`, `KarstTime`,
`InteropTime`, `BedrockBlock`) and methods like `IsCanyon(t)`, `IsEcotone(t)`, etc.

**Direct calls on `*params.ChainConfig`** (not through op-node's `rollup.Config` wrapper):
- `op-service/eth/types.go:BlockAsPayload` – `config.IsCanyon(t)`, `config.IsIsthmus(t)`

All other hardfork checks in op-node derivation code go through op-node's own `rollup.Config`
type, which has its own `IsCanyon(t)`, `IsHolocene(t)` etc. Those do not touch
`params.ChainConfig`.

`rollup.Config.ChainOpConfig *params.OptimismConfig` carries the OP-specific EIP-1559 parameters.

### Proposed decoupling

**Redefine `OptimismConfig` and an augmented `OPChainConfig` in `op-core/params/`**:

```go
// op-core/params/chain_config.go

// OptimismConfig holds OP Stack–specific EIP-1559 parameters.
// Mirrors params.OptimismConfig from op-geth; JSON tags are identical for wire compatibility.
type OptimismConfig struct {
    EIP1559Elasticity        uint64  `json:"eip1559Elasticity"`
    EIP1559Denominator       uint64  `json:"eip1559Denominator"`
    EIP1559DenominatorCanyon *uint64 `json:"eip1559DenominatorCanyon,omitempty"`
}

// OPChainConfig wraps upstream params.ChainConfig and adds OP Stack–specific fields.
type OPChainConfig struct {
    params.ChainConfig                             // embed upstream
    Optimism       *OptimismConfig `json:"optimism,omitempty"`
    BedrockBlock   *big.Int        `json:"bedrockBlock,omitempty"`
    RegolithTime   *uint64         `json:"regolithTime,omitempty"`
    CanyonTime     *uint64         `json:"canyonTime,omitempty"`
    EcotoneTime    *uint64         `json:"ecotoneTime,omitempty"`
    FjordTime      *uint64         `json:"fjordTime,omitempty"`
    GraniteTime    *uint64         `json:"graniteTime,omitempty"`
    HoloceneTime   *uint64         `json:"holoceneTime,omitempty"`
    IsthmusTime    *uint64         `json:"isthmusTime,omitempty"`
    JovianTime     *uint64         `json:"jovianTime,omitempty"`
    KarstTime      *uint64         `json:"karstTime,omitempty"`
    InteropTime    *uint64         `json:"interopTime,omitempty"`
}

func (c *OPChainConfig) IsOptimism() bool  { return c.Optimism != nil }
func (c *OPChainConfig) IsCanyon(t uint64) bool  { return isTimestampForked(c.CanyonTime, t) }
// ... etc.
```

**`rollup.Config.ChainOpConfig`** changes type from `*params.OptimismConfig` to
`*opparams.OptimismConfig`. JSON field names are identical so wire format is preserved.

**`BlockAsPayload`** in op-service changes its `config *params.ChainConfig` parameter to a
`HardforkConfig` interface:

```go
type HardforkConfig interface {
    IsCanyon(timestamp uint64) bool
    IsIsthmus(timestamp uint64) bool
}
```

`rollup.Config` already satisfies this interface. This removes the only direct dependency on
`*params.ChainConfig` for hardfork detection in op-service.

---

## 6. `params/superchain.go` – Protocol versioning types

### Current usage

op-geth adds to `params` (file `superchain.go`):
- `ProtocolVersion` ([32]byte), `ProtocolVersionV0` struct, `ProtocolVersionComparison` int type
- Constants `AheadMajor`, `OutdatedMajor`, `AheadMinor`, `OutdatedMinor`, etc.
- `OPStackSupport` variable, `NetworkNames` map (populated from superchain registry at init)
- `LoadOPStackChainConfig(chainCfg *superchain.ChainConfig) (*ChainConfig, error)` function

Used across op-node (metrics, node/superchain, runcfg) and op-service (engine_client,
superutil).

### Proposed decoupling

**Move `ProtocolVersion*` types and `LoadOPStackChainConfig` to `op-core/params/`**, alongside
`OptimismConfig` (§5). They belong together as all come from `params/superchain.go` in op-geth.

`NetworkNames` will be populated from the embedded superchain registry in `op-core/superchain`
(§7) and moved there.

`LoadOPStackChainConfig` converts a superchain registry chain config into a `*params.ChainConfig`
with all OP hardfork timestamps set. Post-decoupling it produces an `*opparams.OPChainConfig`
from the embedded registry data. Details in §7.

---

## 7. `superchain/` package – entirely op-geth specific

### Current usage

The op-geth `superchain/` package embeds chain configuration data (TOML configs from the
superchain registry, zipped into `superchain-configs.zip`) and provides `GetChain(chainID)`,
`GetSuperchain(network)`, and supporting types. Used in:

- `op-node/rollup/superchain.go` – `superchain.GetChain`, `superchain.GetSuperchain`
- `op-node/chaincfg/chains.go` – `superchain.GetChain`
- `op-service/superutil/chain_config.go` – `superchain.GetChain` + `params.LoadOPStackChainConfig`

The embedded data is synced from the `ethereum-optimism/superchain-registry` git repo via
`sync-superchain.sh`, which clones the registry at a pinned commit (`superchain-registry-commit.txt`)
and zips the configs. op-geth does **not** depend on `superchain-registry` as a Go module; the
data is embedded as a raw binary blob at compile time via `//go:embed`.

### Proposed decoupling

**Move the entire `superchain/` package and `sync-superchain.sh` to `op-core/superchain/`**,
verbatim from op-geth. This is a self-contained package with no dependencies on other op-geth
internals (it only imports `BurntSushi/toml`, `klauspost/compress/zstd`, and standard library).

**No new Go module dependency is required**: the data remains embedded exactly as in op-geth. The
sync script is also copied.

**`op-service/superutil/`** is merged into `op-core/superchain/`. Its single function:

```go
func LoadOPStackChainConfigFromChainID(chainID uint64) (*params.ChainConfig, error) {
    chain, err := superchain.GetChain(chainID)
    // ...
    return params.LoadOPStackChainConfig(chainCfg)
}
```

becomes:

```go
func LoadOPStackChainConfigFromChainID(chainID uint64) (*opparams.OPChainConfig, error) {
    chain, err := GetChain(chainID)   // local, now in op-core/superchain
    // ...
    return opparams.LoadOPStackChainConfig(chainCfg)  // now in op-core/params
}
```

**Hardfork schedule in `rollup.Config`** (option a.): `rollup.Config` is extended to load and
carry all OP hardfork timestamps from the registry, rather than going through `*params.ChainConfig`.
`rollup.Config.ChainOpConfig *params.OptimismConfig` becomes
`rollup.Config.ChainOpConfig *opparams.OptimismConfig`. The existing hardfork timestamp fields on
`rollup.Config` already cover most forks; any gaps (KarstTime, InteropTime) are filled in.

---

## 8. `eth/catalyst` – `SuperchainSignal` and `LogProtocolVersionSupport`

### Current usage

```go
// op-service/sources/engine_client.go
err := s.RPC.CallContext(ctx, &result, "engine_signalSuperchainV1", &catalyst.SuperchainSignal{
    Recommended: recommended,
    Required:    required,
})
// op-node/node/superchain.go
catalyst.LogProtocolVersionSupport(n.log.New(...), engineSupport, recommended, "recommended")
```

`SuperchainSignal` is a two-field struct. `LogProtocolVersionSupport` is a short log helper.

### Proposed decoupling

**Define both in `op-core/superchain/`** alongside the other superchain types. Since
`ProtocolVersion` will already be in `op-core/params`, `SuperchainSignal` has no external
go-ethereum dependency. `LogProtocolVersionSupport` only requires `log.Logger` (standard upstream).

---

## 9. `consensus/misc/eip1559` – Holocene/Jovian helpers

### Current usage

op-geth adds `eip1559_optimism.go` with self-contained functions for Holocene/Jovian parameter
encoding. Used in op-node:

- `rollup/derive/payload_util.go` – `EncodeHolocene1559Params`
- `rollup/interop/indexing/attributes.go` – `EncodeHolocene1559Params`, `DecodeJovianExtraData`
- `rollup/attributes/engine_consolidate.go` – `DecodeHolocene1559Params`

Signatures operate on `[]byte` and `uint64` scalars only. No go-ethereum type dependencies.

### Proposed decoupling

**Move to `op-core/consensus/eip1559/`**. Copy verbatim; the only import is `errors`.

---

## 10. `beacon/engine` – `PayloadID` type alias

### Current usage

`op-service/eth/types.go` defines `type PayloadID = engine.PayloadID` where `engine.PayloadID` is
`[8]byte`. This is **standard upstream** go-ethereum.

### Proposed decoupling

None needed. Or optionally define `type PayloadID = [8]byte` in the monorepo to cut even this
thin import.

---

## 11. `beacon/engine` – `PayloadAttributes` / `ExecutableData` extensions

### Current status

op-service defines its **own** `PayloadAttributes`, `ExecutionPayload`, and
`ExecutionPayloadEnvelope` types in `op-service/eth/types.go`. These mirror the Engine API types
but are entirely monorepo-defined with the OP-specific extra fields.

The conversion function `BlockAsPayload` accesses only:

```go
bl.Header().WithdrawalsHash   // standard go-ethereum since EIP-4895 / Shanghai
bl.BeaconRoot()               // standard go-ethereum since EIP-4788 / Cancun
```

Both fields exist unchanged in upstream go-ethereum.

### Proposed decoupling

None needed. The `BlockAsPayload` function just needs the `HardforkConfig` interface change
from §5 and will compile against upstream go-ethereum.

---

## Summary table

| Area | op-geth source | Target in monorepo | Effort |
|------|---------------|-------------------|--------|
| `DepositTx` type + `MarshalBinary` | `core/types/deposit_tx.go` | `op-core/types/` | Medium |
| `DepositTxType` constant | `core/types/deposit_tx.go` | `op-core/types/` | Trivial |
| `IsDepositTx()` free function | `core/types/transaction.go` | `op-core/types/` | Trivial |
| `IsSystemTx()`, `SourceHash()`, `Mint()` helpers | `core/types/transaction.go` | `op-core/types/` | Low |
| `RollupCostData`, `NewL1CostFuncFjord` | `core/types/rollup_cost.go` | `op-core/types/` | Low |
| `OptimismReceipt` (receipt L1-cost fields) | `core/types/receipt_opstack.go` | `op-core/types/` | Medium |
| `OptimismConfig` struct | `params/config.go` | `op-core/params/` | Trivial |
| `OPChainConfig` (wraps upstream ChainConfig) | `params/config.go`, `params/config_op.go` | `op-core/params/` | Medium |
| `ProtocolVersion*` types + constants | `params/superchain.go` | `op-core/params/` | Low |
| `LoadOPStackChainConfig` | `params/superchain.go` | `op-core/params/` | Medium |
| `superchain/` package (data + loader) | `superchain/` | `op-core/superchain/` | Low (copy) |
| `sync-superchain.sh` | root | `op-core/superchain/` | Trivial |
| `op-service/superutil/` | monorepo | merged into `op-core/superchain/` | Low |
| `SuperchainSignal`, `LogProtocolVersionSupport` | `eth/catalyst/superchain.go` | `op-core/superchain/` | Trivial |
| EIP-1559 Holocene/Jovian helpers | `consensus/misc/eip1559/eip1559_optimism.go` | `op-core/consensus/eip1559/` | Trivial |
| `HardforkConfig` interface | n/a | `op-service/eth/` (for `BlockAsPayload`) | Trivial |
| `beacon/engine.PayloadID` | upstream | no change needed | None |
| `Header.WithdrawalsHash`, `BeaconRoot()` | upstream since Shanghai/Cancun | no change needed | None |
| `core.FloorDataGas` | upstream (EIP-7623) | no change needed | None |
| `txpool.ErrAlreadyReserved` | upstream | no change needed | None |
| `params.TxGas`, `BlobTxBlobGasPerBlob` | upstream | no change needed | None |

## Implementation notes

### Wire compatibility for `OptimismConfig`

`rollup.Config.ChainOpConfig *params.OptimismConfig` is serialised to JSON (and potentially sent
over the wire between op-node and other services). The new `*opparams.OptimismConfig` must use
identical JSON field names. Current op-geth JSON tags:

```go
EIP1559Elasticity        uint64  `json:"eip1559Elasticity"`
EIP1559Denominator       uint64  `json:"eip1559Denominator"`
EIP1559DenominatorCanyon *uint64 `json:"eip1559DenominatorCanyon,omitempty"`
```

These must be preserved verbatim in `op-core/params.OptimismConfig`.

### DepositTx RLP wire compatibility

The `op-core/types.DepositTx.MarshalBinary` implementation must produce byte-for-byte identical
output to `types.NewTx(&types.DepositTx{...}).MarshalBinary()` in op-geth. This is verified by
the differential test mentioned in §1. The wire format is:

```
0x7E || RLP([sourceHash, from, to, mint, value, gas, isSystemTransaction, data])
```

with `mint` and `to` following the standard RLP optional-pointer encoding.

### Rollup.Config hardfork schedule

`rollup.Config` already carries timestamp fields for all hardforks up through Jovian. The
`op-core/params.OPChainConfig` loader (`LoadOPStackChainConfig`) populates `rollup.Config`
directly from the superchain registry data, bypassing `params.ChainConfig`. Any new hardforks
(Karst, Interop) added since the current `rollup.Config` definition will be added to it.
