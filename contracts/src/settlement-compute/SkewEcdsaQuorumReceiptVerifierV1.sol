// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { ISkewComputeReceiptVerifierV1 } from "./ISkewComputeSettlementV1.sol";

/// @notice Immutable M-of-N verification route for deterministic and requester-acceptance workloads.
contract SkewEcdsaQuorumReceiptVerifierV1 is ISkewComputeReceiptVerifierV1 {
    uint256 public constant BASE_MAINNET_CHAIN_ID = 8453;
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant NAME_HASH = keccak256("Skew Compute Receipt");
    bytes32 public constant VERSION_HASH = keccak256("2");
    bytes32 public constant RECEIPT_TYPEHASH = keccak256(
        "SkewComputeReceiptV2(bytes32 jobId,bytes32 taskSpecDigest,bytes32 quoteDigest,bytes32 outcomeContractDigest,bytes32 outputDigest,bytes32 contributionRoot,uint128 contributionTotalUsdc,uint32 contributionCount,uint128 workerPoolUsdc,uint128 verifierFeeUsdc,uint128 protocolFeeUsdc,uint64 validUntil)"
    );
    uint256 private constant SECP256K1N_DIV_2 = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;
    uint256 private constant MAX_SIGNERS = 32;

    bytes32 public immutable domainSeparator;
    uint8 public immutable threshold;
    address[] private _signers;
    mapping(address signer => bool trusted) public isSigner;

    error WrongChain(uint256 actual);
    error InvalidConfiguration();
    error InvalidReceipt();
    error ReceiptExpired();
    error InvalidSignature();
    error SignerOrder();
    error QuorumNotMet();

    constructor(address[] memory signers_, uint8 threshold_) {
        if (block.chainid != BASE_MAINNET_CHAIN_ID) revert WrongChain(block.chainid);
        if (threshold_ == 0 || threshold_ > signers_.length || signers_.length > MAX_SIGNERS) {
            revert InvalidConfiguration();
        }
        address previous = address(0);
        for (uint256 i = 0; i < signers_.length; ++i) {
            address signer = signers_[i];
            if (signer == address(0) || signer <= previous) revert InvalidConfiguration();
            previous = signer;
            isSigner[signer] = true;
            _signers.push(signer);
        }
        threshold = threshold_;
        domainSeparator =
            keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, BASE_MAINNET_CHAIN_ID, address(this)));
    }

    function verifyReceipt(Receipt calldata receipt, bytes[] calldata signatures)
        external
        view
        returns (bytes32 receiptDigest)
    {
        if (block.chainid != BASE_MAINNET_CHAIN_ID) revert WrongChain(block.chainid);
        if (
            receipt.jobId == bytes32(0) || receipt.taskSpecDigest == bytes32(0) || receipt.quoteDigest == bytes32(0)
                || receipt.outcomeContractDigest == bytes32(0) || receipt.outputDigest == bytes32(0)
                || receipt.contributionRoot == bytes32(0) || receipt.contributionTotalUsdc == 0
                || receipt.contributionCount == 0 || receipt.workerPoolUsdc == 0
        ) revert InvalidReceipt();
        if (receipt.validUntil < block.timestamp) revert ReceiptExpired();

        receiptDigest = hashReceipt(receipt);
        if (signatures.length < threshold || signatures.length > _signers.length) revert QuorumNotMet();
        address previous = address(0);
        for (uint256 i = 0; i < signatures.length; ++i) {
            address recovered = _recover(receiptDigest, signatures[i]);
            if (!isSigner[recovered]) revert InvalidSignature();
            if (recovered <= previous) revert SignerOrder();
            previous = recovered;
        }
    }

    function hashReceipt(Receipt calldata receipt) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIPT_TYPEHASH,
                receipt.jobId,
                receipt.taskSpecDigest,
                receipt.quoteDigest,
                receipt.outcomeContractDigest,
                receipt.outputDigest,
                receipt.contributionRoot,
                receipt.contributionTotalUsdc,
                receipt.contributionCount,
                receipt.workerPoolUsdc,
                receipt.verifierFeeUsdc,
                receipt.protocolFeeUsdc,
                receipt.validUntil
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function signers() external view returns (address[] memory) {
        return _signers;
    }

    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address signer) {
        if (signature.length != 65) revert InvalidSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (uint256(s) > SECP256K1N_DIV_2 || (v != 27 && v != 28)) revert InvalidSignature();
        signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
    }
}
