//! Optimism transaction types

/// Extended local transaction envelope support.
pub mod ext;
mod tx_type;

/// Kept for consistency tests
#[cfg(test)]
mod signed;

pub use ext::{OpTransactionExt, OpTxTypeExt};
pub use op_alloy_consensus::{
    OpTransaction, OpTxType, OpTypedTransaction, POST_EXEC_TX_TYPE_ID, SDMGasEntry, SDMPayload,
    TxPostExec, build_post_exec_tx, extract_post_exec_payload_from_tx,
};

/// Signed transaction.
pub type OpTransactionSigned = OpTransactionExt;
