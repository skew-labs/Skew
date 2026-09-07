// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ISkewComputeUsdcV1 {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool);
}

interface ISkewComputeRouteRegistryV1 {
    struct Route {
        address verifier;
        bytes32 verifierCodeHash;
        uint16 maxProtocolFeeBps;
        uint16 maxVerifierFeeBps;
        bool enabled;
    }

    function route(bytes32 routeId) external view returns (Route memory);
}

interface ISkewComputeReceiptVerifierV1 {
    struct Receipt {
        bytes32 jobId;
        bytes32 taskSpecDigest;
        bytes32 quoteDigest;
        bytes32 outcomeContractDigest;
        bytes32 outputDigest;
        bytes32 contributionRoot;
        uint128 contributionTotalUsdc;
        uint32 contributionCount;
        uint128 workerPoolUsdc;
        uint128 verifierFeeUsdc;
        uint128 protocolFeeUsdc;
        uint64 validUntil;
    }

    /// @notice Returns the canonical receipt digest or reverts.
    function verifyReceipt(Receipt calldata receipt, bytes[] calldata signatures)
        external
        view
        returns (bytes32 receiptDigest);
}
