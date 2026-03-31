use alloc::vec::Vec;
use alloy_consensus::{
    Sealable, Sealed, Signed, TransactionEnvelope, TxEip1559,
    crypto::RecoveryError,
    transaction::{SignerRecoverable, TxHashRef},
};
use alloy_eips::Encodable2718;
use alloy_primitives::{Address, B256, Signature};
use alloy_rlp::{BufMut, Decodable, Encodable};
use op_alloy_consensus::{
    OpPooledTransaction, OpTransaction, OpTxEnvelope, OpTxType, OpTypedTransaction,
    POST_EXEC_TX_TYPE_ID, TxDeposit, TxPostExec,
};
#[cfg(feature = "reth-codec")]
use reth_codecs::{
    Compact,
    alloy::transaction::{CompactEnvelope, Envelope, FromTxCompact, ToTxCompact},
    txtype::COMPACT_EXTENDED_IDENTIFIER_FLAG,
};
use reth_db_api::{
    DatabaseError,
    table::{Compress, Decompress},
};
#[cfg(feature = "serde-bincode-compat")]
use reth_primitives_traits::serde_bincode_compat::RlpBincode;
use reth_primitives_traits::{InMemorySize, SignedTransaction};

/// A locally-extended OP transaction envelope that adds the synthetic post-exec transaction.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, TransactionEnvelope)]
#[envelope(tx_type_name = OpTxTypeExt, serde_cfg(feature = "serde"))]
pub enum OpTransactionExt {
    /// All standard OP transaction types.
    #[envelope(flatten)]
    Op(OpTxEnvelope),
    /// Synthetic post-execution transaction for warming refunds.
    #[envelope(ty = 0x7D)]
    PostExec(Sealed<TxPostExec>),
}

impl From<OpTxEnvelope> for OpTransactionExt {
    fn from(value: OpTxEnvelope) -> Self {
        Self::Op(value)
    }
}

impl From<alloy_consensus::Signed<op_alloy_consensus::OpTypedTransaction>> for OpTransactionExt {
    fn from(value: alloy_consensus::Signed<op_alloy_consensus::OpTypedTransaction>) -> Self {
        Self::Op(value.into())
    }
}

impl From<alloy_consensus::Signed<alloy_consensus::TxEip1559>> for OpTransactionExt {
    fn from(value: alloy_consensus::Signed<alloy_consensus::TxEip1559>) -> Self {
        Self::Op(value.into())
    }
}

impl From<TxDeposit> for OpTransactionExt {
    fn from(value: TxDeposit) -> Self {
        Self::Op(value.into())
    }
}

impl OpTransactionExt {
    /// Creates a new unhashed standard OP transaction variant.
    pub fn new_unhashed(transaction: OpTypedTransaction, signature: Signature) -> Self {
        Self::Op(OpTxEnvelope::new_unhashed(transaction, signature))
    }

    /// Returns the inner EIP-1559 transaction if this is a standard OP EIP-1559 transaction.
    pub const fn as_eip1559(&self) -> Option<&Signed<TxEip1559>> {
        match self {
            Self::Op(tx) => tx.as_eip1559(),
            Self::PostExec(_) => None,
        }
    }
}

#[cfg(feature = "serde-bincode-compat")]
impl RlpBincode for OpTransactionExt {}

#[cfg(feature = "reth-codec")]
const DEPOSIT_SIGNATURE: Signature =
    Signature::new(alloy_primitives::U256::ZERO, alloy_primitives::U256::ZERO, false);

#[cfg(feature = "reth-codec")]
impl Envelope for OpTransactionExt {
    fn signature(&self) -> &Signature {
        match self {
            Self::Op(tx) => Envelope::signature(tx),
            Self::PostExec(_) => &DEPOSIT_SIGNATURE,
        }
    }

    fn tx_type(&self) -> Self::TxType {
        match self {
            Self::Op(tx) => OpTxTypeExt::Op(tx.tx_type()),
            Self::PostExec(_) => OpTxTypeExt::PostExec,
        }
    }
}

#[cfg(feature = "reth-codec")]
impl FromTxCompact for OpTransactionExt {
    type TxType = OpTxTypeExt;

    fn from_tx_compact(buf: &[u8], tx_type: Self::TxType, signature: Signature) -> (Self, &[u8]) {
        match tx_type {
            OpTxTypeExt::Op(tx_type) => {
                let (tx, buf) = OpTxEnvelope::from_tx_compact(buf, tx_type, signature);
                (Self::Op(tx), buf)
            }
            OpTxTypeExt::PostExec => {
                let mut data = buf;
                let tx = TxPostExec::decode(&mut data).expect("valid post-exec tx body");
                (Self::PostExec(tx.seal_slow()), data)
            }
        }
    }
}

#[cfg(feature = "reth-codec")]
impl ToTxCompact for OpTransactionExt {
    fn to_tx_compact(&self, buf: &mut (impl BufMut + AsMut<[u8]>)) {
        match self {
            Self::Op(tx) => tx.to_tx_compact(buf),
            Self::PostExec(tx) => tx.inner().encode(buf),
        }
    }
}

#[cfg(feature = "reth-codec")]
impl Compact for OpTransactionExt {
    fn to_compact<B>(&self, buf: &mut B) -> usize
    where
        B: BufMut + AsMut<[u8]>,
    {
        <Self as CompactEnvelope>::to_compact(self, buf)
    }

    fn from_compact(buf: &[u8], len: usize) -> (Self, &[u8]) {
        <Self as CompactEnvelope>::from_compact(buf, len)
    }
}

#[cfg(feature = "reth-codec")]
impl Compact for OpTxTypeExt {
    fn to_compact<B>(&self, buf: &mut B) -> usize
    where
        B: bytes::BufMut + AsMut<[u8]>,
    {
        match self {
            Self::Op(ty) => ty.to_compact(buf),
            Self::PostExec => {
                bytes::BufMut::put_u8(buf, POST_EXEC_TX_TYPE_ID);
                COMPACT_EXTENDED_IDENTIFIER_FLAG
            }
        }
    }

    fn from_compact(buf: &[u8], identifier: usize) -> (Self, &[u8]) {
        match identifier {
            COMPACT_EXTENDED_IDENTIFIER_FLAG
                if !buf.is_empty() && buf[0] == POST_EXEC_TX_TYPE_ID =>
            {
                (Self::PostExec, &buf[1..])
            }
            v => {
                let (ty, remaining) = OpTxType::from_compact(buf, v);
                (Self::Op(ty), remaining)
            }
        }
    }
}

impl OpTransaction for OpTransactionExt {
    fn is_deposit(&self) -> bool {
        match self {
            Self::Op(op) => op.is_deposit(),
            Self::PostExec(_) => false,
        }
    }

    fn as_deposit(&self) -> Option<&Sealed<TxDeposit>> {
        match self {
            Self::Op(op) => op.as_deposit(),
            Self::PostExec(_) => None,
        }
    }
}

impl SignerRecoverable for OpTransactionExt {
    fn recover_signer(&self) -> Result<Address, RecoveryError> {
        match self {
            Self::Op(tx) => SignerRecoverable::recover_signer(tx),
            Self::PostExec(_) => Ok(Address::ZERO),
        }
    }

    fn recover_signer_unchecked(&self) -> Result<Address, RecoveryError> {
        match self {
            Self::Op(tx) => SignerRecoverable::recover_signer_unchecked(tx),
            Self::PostExec(_) => Ok(Address::ZERO),
        }
    }

    fn recover_unchecked_with_buf(&self, buf: &mut Vec<u8>) -> Result<Address, RecoveryError> {
        match self {
            Self::Op(tx) => tx.recover_unchecked_with_buf(buf),
            Self::PostExec(_) => Ok(Address::ZERO),
        }
    }
}

impl TxHashRef for OpTransactionExt {
    fn tx_hash(&self) -> &B256 {
        match self {
            Self::Op(tx) => TxHashRef::tx_hash(tx),
            Self::PostExec(tx) => tx.hash_ref(),
        }
    }
}

impl SignedTransaction for OpTransactionExt {
    fn is_system_tx(&self) -> bool {
        self.is_deposit()
    }
}

impl From<OpPooledTransaction> for OpTransactionExt {
    fn from(value: OpPooledTransaction) -> Self {
        Self::Op(value.into())
    }
}

impl TryFrom<OpTransactionExt> for OpPooledTransaction {
    type Error = alloy_consensus::error::ValueError<OpTransactionExt>;

    fn try_from(value: OpTransactionExt) -> Result<Self, Self::Error> {
        match value {
            OpTransactionExt::Op(tx) => {
                tx.try_into_pooled().map_err(|err| err.map(OpTransactionExt::Op))
            }
            OpTransactionExt::PostExec(tx) => Err(alloy_consensus::error::ValueError::new(
                OpTransactionExt::PostExec(tx),
                "PostExec transactions cannot be pooled",
            )),
        }
    }
}

impl Compress for OpTransactionExt {
    type Compressed = Vec<u8>;

    fn compress_to_buf<B: alloy_rlp::bytes::BufMut + AsMut<[u8]>>(&self, buf: &mut B) {
        #[cfg(feature = "reth-codec")]
        {
            let _ = reth_codecs::Compact::to_compact(self, buf);
        }
        #[cfg(not(feature = "reth-codec"))]
        {
            let _ = buf;
            unreachable!("OpTransactionExt DB compression requires reth-codec feature")
        }
    }
}

impl Decompress for OpTransactionExt {
    fn decompress(value: &[u8]) -> Result<Self, DatabaseError> {
        #[cfg(feature = "reth-codec")]
        {
            let (obj, _) = reth_codecs::Compact::from_compact(value, value.len());
            Ok(obj)
        }
        #[cfg(not(feature = "reth-codec"))]
        {
            let _ = value;
            Err(DatabaseError::Decode)
        }
    }
}

impl InMemorySize for OpTransactionExt {
    fn size(&self) -> usize {
        match self {
            Self::Op(tx) => InMemorySize::size(tx),
            Self::PostExec(tx) => tx.inner().size(),
        }
    }
}
