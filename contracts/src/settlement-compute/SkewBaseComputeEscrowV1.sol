// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {
    ISkewComputeReceiptVerifierV1,
    ISkewComputeRouteRegistryV1,
    ISkewComputeUsdcV1
} from "./ISkewComputeSettlementV1.sol";

/// @notice Base USDC escrow for verified machine work.
/// @dev The requester buys an outcome. Worker addresses are committed only in the
///      verifier-approved contribution root, then claimed individually.
contract SkewBaseComputeEscrowV1 {
    uint256 public constant BASE_MAINNET_CHAIN_ID = 8453;
    address public constant BASE_MAINNET_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint64 public constant MAX_JOB_LIFETIME = 30 days;
    uint32 public constant MAX_CONTRIBUTIONS = 256;
    uint256 public constant CONTRIBUTION_TREE_DEPTH = 8;
    bytes32 public constant JOB_TERMS_TYPEHASH =
        keccak256("SkewComputeJobTermsV1(bytes32 deploymentHash,bytes32 requestHash,bytes32 paymentHash)");
    bytes32 public constant DEPLOYMENT_TERMS_TYPEHASH = keccak256(
        "SkewComputeDeploymentTermsV1(uint256 chainId,address escrow,bytes32 routeId,address verifier,bytes32 verifierCodeHash)"
    );
    bytes32 public constant REQUEST_TERMS_TYPEHASH = keccak256(
        "SkewComputeRequestTermsV1(bytes32 clientSalt,bytes32 taskSpecDigest,bytes32 quoteDigest,bytes32 outcomeContractDigest)"
    );
    bytes32 public constant PAYMENT_TERMS_TYPEHASH = keccak256(
        "SkewComputePaymentTermsV1(address payer,address verifierFeeRecipient,address protocolFeeRecipient,uint128 workerPoolUsdc,uint128 verifierFeeUsdc,uint128 protocolFeeUsdc,uint64 refundAfter)"
    );
    bytes32 public constant CONTRIBUTION_TYPEHASH = keccak256(
        "SkewComputeContributionV1(bytes32 jobId,uint256 index,address recipient,uint128 amountUsdc,bytes32 workReceiptDigest)"
    );
    bytes32 public constant CONTRIBUTION_LEAF_NODE_TYPEHASH = keccak256(
        "SkewComputeContributionLeafNodeV2(bytes32 contributionLeaf,uint128 contributionTotalUsdc,uint32 contributionCount)"
    );
    bytes32 public constant CONTRIBUTION_NODE_TYPEHASH = keccak256(
        "SkewComputeContributionNodeV2(bytes32 leftHash,uint128 leftTotalUsdc,uint32 leftCount,bytes32 rightHash,uint128 rightTotalUsdc,uint32 rightCount)"
    );

    struct JobTerms {
        bytes32 routeId;
        bytes32 clientSalt;
        bytes32 taskSpecDigest;
        bytes32 quoteDigest;
        bytes32 outcomeContractDigest;
        address payer;
        address verifierFeeRecipient;
        address protocolFeeRecipient;
        uint128 workerPoolUsdc;
        uint128 verifierFeeUsdc;
        uint128 protocolFeeUsdc;
        uint64 refundAfter;
    }

    struct Job {
        JobTerms terms;
        address verifier;
        bytes32 verifierCodeHash;
        bytes32 receiptDigest;
        bytes32 outputDigest;
        bytes32 contributionRoot;
        uint128 contributionTotalUsdc;
        uint32 contributionCount;
        uint128 claimedWorkerUsdc;
        bool accepted;
        bool refunded;
        bool workerPoolClosed;
    }

    struct ContributionProofNode {
        bytes32 nodeHash;
        uint128 contributionTotalUsdc;
        uint32 contributionCount;
    }

    ISkewComputeUsdcV1 public constant USDC = ISkewComputeUsdcV1(BASE_MAINNET_USDC);
    ISkewComputeRouteRegistryV1 public immutable routeRegistry;
    address public immutable pauseGuardian;
    /// @notice Immutable blast-radius limits for this deployment. Increasing either
    ///         limit requires a new escrow deployment and a new explicit client pin.
    uint128 public immutable maxJobUsdc;
    uint128 public immutable maxTotalLiabilityUsdc;

    bool public paused;
    uint256 private _entered;
    uint256 public escrowLiabilityUsdc;
    uint256 public creditLiabilityUsdc;
    mapping(bytes32 jobId => Job jobState) private _jobs;
    mapping(address recipient => uint256 amountUsdc) public usdcCredits;
    mapping(bytes32 receiptDigest => bool used) public usedReceiptDigests;
    mapping(bytes32 jobId => mapping(uint256 word => uint256 bitmap)) private _claimedContributions;

    error WrongChain(uint256 actual);
    error InvalidDeployment();
    error Unauthorized();
    error Paused();
    error Reentrancy();
    error InvalidTerms();
    error InvalidRoute();
    error FeeCapExceeded();
    error JobCapExceeded(uint256 requested, uint256 maximum);
    error LiabilityCapExceeded(uint256 requested, uint256 maximum);
    error DuplicateJob(bytes32 jobId);
    error UnknownJob(bytes32 jobId);
    error AlreadyTerminal(bytes32 jobId);
    error InvalidReceipt();
    error AcceptanceDeadlinePassed(uint64 refundAfter);
    error Replay();
    error InvalidContribution();
    error ContributionAlreadyClaimed(uint256 index);
    error InvalidMerkleProof();
    error RefundNotAvailable(uint64 refundAfter);
    error WorkerClaimWindowClosed(uint64 refundAfter);
    error WorkerPoolAlreadyClosed(bytes32 jobId);
    error NothingToClaim();
    error TokenTransferFailed();
    error UnsupportedTokenBehavior();
    error Insolvent(uint256 balance, uint256 liability);

    event JobFunded(
        bytes32 indexed jobId,
        bytes32 indexed routeId,
        address indexed payer,
        bytes32 taskSpecDigest,
        bytes32 quoteDigest,
        uint256 totalUsdc,
        uint64 refundAfter
    );
    event JobAccepted(
        bytes32 indexed jobId,
        bytes32 indexed receiptDigest,
        bytes32 indexed outputDigest,
        bytes32 contributionRoot,
        uint128 contributionTotalUsdc,
        uint32 contributionCount
    );
    event ContributionClaimed(
        bytes32 indexed jobId,
        uint256 indexed index,
        address indexed recipient,
        uint256 amountUsdc,
        bytes32 workReceiptDigest
    );
    event JobRefunded(bytes32 indexed jobId, address indexed payer, uint256 amountUsdc);
    event UnclaimedWorkerPoolReclaimed(bytes32 indexed jobId, address indexed payer, uint256 amountUsdc);
    event UsdcCreditClaimed(address indexed recipient, uint256 amountUsdc);
    event PauseUpdated(bool paused);

    modifier onlyPinnedChain() {
        if (block.chainid != BASE_MAINNET_CHAIN_ID) revert WrongChain(block.chainid);
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    constructor(
        ISkewComputeRouteRegistryV1 routeRegistry_,
        address pauseGuardian_,
        uint128 maxJobUsdc_,
        uint128 maxTotalLiabilityUsdc_
    ) {
        if (block.chainid != BASE_MAINNET_CHAIN_ID) revert WrongChain(block.chainid);
        if (address(routeRegistry_).code.length == 0 || pauseGuardian_.code.length == 0) {
            revert InvalidDeployment();
        }
        if (maxJobUsdc_ == 0 || maxTotalLiabilityUsdc_ < maxJobUsdc_) revert InvalidDeployment();
        if (BASE_MAINNET_USDC.code.length == 0 || USDC.decimals() != 6) revert InvalidDeployment();
        routeRegistry = routeRegistry_;
        pauseGuardian = pauseGuardian_;
        maxJobUsdc = maxJobUsdc_;
        maxTotalLiabilityUsdc = maxTotalLiabilityUsdc_;
        _entered = 1;
    }

    function fundJob(JobTerms calldata terms)
        external
        onlyPinnedChain
        whenNotPaused
        nonReentrant
        returns (bytes32 jobId)
    {
        if (
            terms.payer != msg.sender || terms.clientSalt == bytes32(0) || terms.taskSpecDigest == bytes32(0)
                || terms.quoteDigest == bytes32(0) || terms.outcomeContractDigest == bytes32(0)
                || terms.verifierFeeRecipient == address(0) || terms.protocolFeeRecipient == address(0)
                || terms.verifierFeeRecipient == address(this) || terms.protocolFeeRecipient == address(this)
                || terms.verifierFeeRecipient == BASE_MAINNET_USDC || terms.protocolFeeRecipient == BASE_MAINNET_USDC
                || terms.workerPoolUsdc == 0 || terms.refundAfter <= block.timestamp
                || terms.refundAfter > block.timestamp + MAX_JOB_LIFETIME
        ) revert InvalidTerms();
        ISkewComputeRouteRegistryV1.Route memory routeConfig = routeRegistry.route(terms.routeId);
        if (
            !routeConfig.enabled || routeConfig.verifier.code.length == 0
                || routeConfig.verifier.codehash != routeConfig.verifierCodeHash
        ) revert InvalidRoute();
        uint256 totalUsdc = _total(terms);
        if (totalUsdc > maxJobUsdc) revert JobCapExceeded(totalUsdc, maxJobUsdc);
        uint256 nextTotalLiability = escrowLiabilityUsdc + creditLiabilityUsdc + totalUsdc;
        if (nextTotalLiability > maxTotalLiabilityUsdc) {
            revert LiabilityCapExceeded(nextTotalLiability, maxTotalLiabilityUsdc);
        }
        if (
            uint256(terms.protocolFeeUsdc) * 10_000 > totalUsdc * routeConfig.maxProtocolFeeBps
                || uint256(terms.verifierFeeUsdc) * 10_000 > totalUsdc * routeConfig.maxVerifierFeeBps
        ) revert FeeCapExceeded();
        jobId = hashJobTerms(terms, routeConfig.verifier, routeConfig.verifierCodeHash);
        if (_jobs[jobId].terms.payer != address(0)) revert DuplicateJob(jobId);

        uint256 beforeBalance = USDC.balanceOf(address(this));
        _safeTransferFrom(msg.sender, address(this), totalUsdc);
        uint256 afterBalance = USDC.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != totalUsdc) {
            revert UnsupportedTokenBehavior();
        }
        Job storage jobState = _jobs[jobId];
        jobState.terms = terms;
        jobState.verifier = routeConfig.verifier;
        jobState.verifierCodeHash = routeConfig.verifierCodeHash;
        escrowLiabilityUsdc += totalUsdc;
        _assertSolvent();
        emit JobFunded(
            jobId, terms.routeId, msg.sender, terms.taskSpecDigest, terms.quoteDigest, totalUsdc, terms.refundAfter
        );
    }

    function acceptVerifiedResult(
        bytes32 jobId,
        ISkewComputeReceiptVerifierV1.Receipt calldata receipt,
        bytes[] calldata signatures
    ) external onlyPinnedChain whenNotPaused nonReentrant returns (bytes32 receiptDigest) {
        Job storage jobState = _jobs[jobId];
        if (jobState.terms.payer == address(0)) revert UnknownJob(jobId);
        if (jobState.accepted || jobState.refunded) revert AlreadyTerminal(jobId);
        if (block.timestamp >= jobState.terms.refundAfter) {
            revert AcceptanceDeadlinePassed(jobState.terms.refundAfter);
        }
        ISkewComputeRouteRegistryV1.Route memory routeConfig = routeRegistry.route(jobState.terms.routeId);
        if (
            !routeConfig.enabled || routeConfig.verifier != jobState.verifier
                || routeConfig.verifierCodeHash != jobState.verifierCodeHash
                || jobState.verifier.codehash != jobState.verifierCodeHash
        ) revert InvalidRoute();
        if (
            receipt.jobId != jobId || receipt.taskSpecDigest != jobState.terms.taskSpecDigest
                || receipt.quoteDigest != jobState.terms.quoteDigest
                || receipt.outcomeContractDigest != jobState.terms.outcomeContractDigest
                || receipt.workerPoolUsdc != jobState.terms.workerPoolUsdc
                || receipt.verifierFeeUsdc != jobState.terms.verifierFeeUsdc
                || receipt.protocolFeeUsdc != jobState.terms.protocolFeeUsdc || receipt.outputDigest == bytes32(0)
                || receipt.contributionRoot == bytes32(0)
                || receipt.contributionTotalUsdc != jobState.terms.workerPoolUsdc || receipt.contributionCount == 0
                || receipt.contributionCount > MAX_CONTRIBUTIONS || receipt.validUntil > jobState.terms.refundAfter
        ) revert InvalidReceipt();
        receiptDigest = ISkewComputeReceiptVerifierV1(jobState.verifier).verifyReceipt(receipt, signatures);
        if (receiptDigest == bytes32(0) || usedReceiptDigests[receiptDigest]) revert Replay();
        usedReceiptDigests[receiptDigest] = true;
        jobState.accepted = true;
        jobState.receiptDigest = receiptDigest;
        jobState.outputDigest = receipt.outputDigest;
        jobState.contributionRoot = receipt.contributionRoot;
        jobState.contributionTotalUsdc = receipt.contributionTotalUsdc;
        jobState.contributionCount = receipt.contributionCount;

        uint256 totalUsdc = _total(jobState.terms);
        escrowLiabilityUsdc -= totalUsdc;
        creditLiabilityUsdc += totalUsdc;
        usdcCredits[jobState.terms.verifierFeeRecipient] += jobState.terms.verifierFeeUsdc;
        usdcCredits[jobState.terms.protocolFeeRecipient] += jobState.terms.protocolFeeUsdc;
        _assertSolvent();
        emit JobAccepted(
            jobId,
            receiptDigest,
            receipt.outputDigest,
            receipt.contributionRoot,
            receipt.contributionTotalUsdc,
            receipt.contributionCount
        );
    }

    function claimContribution(
        bytes32 jobId,
        uint256 index,
        address recipient,
        uint128 amountUsdc,
        bytes32 workReceiptDigest,
        ContributionProofNode[] calldata merkleProof
    ) external onlyPinnedChain {
        Job storage jobState = _jobs[jobId];
        if (!jobState.accepted || jobState.refunded || jobState.workerPoolClosed) revert InvalidContribution();
        if (block.timestamp >= jobState.terms.refundAfter) {
            revert WorkerClaimWindowClosed(jobState.terms.refundAfter);
        }
        if (index >= jobState.contributionCount || merkleProof.length != CONTRIBUTION_TREE_DEPTH) {
            revert InvalidContribution();
        }
        if (
            recipient == address(0) || recipient == address(this) || recipient == BASE_MAINNET_USDC || amountUsdc == 0
                || workReceiptDigest == bytes32(0)
        ) {
            revert InvalidContribution();
        }
        uint256 word = index >> 8;
        uint256 mask = uint256(1) << (index & 255);
        if (_claimedContributions[jobId][word] & mask != 0) revert ContributionAlreadyClaimed(index);
        bytes32 leaf =
            keccak256(abi.encode(CONTRIBUTION_TYPEHASH, jobId, index, recipient, amountUsdc, workReceiptDigest));
        if (!_verifyMerkleSumProof(jobState, index, amountUsdc, leaf, merkleProof)) revert InvalidMerkleProof();
        uint256 nextClaimed = uint256(jobState.claimedWorkerUsdc) + amountUsdc;
        if (nextClaimed > jobState.terms.workerPoolUsdc) revert InvalidContribution();
        _claimedContributions[jobId][word] |= mask;
        jobState.claimedWorkerUsdc = uint128(nextClaimed);
        usdcCredits[recipient] += amountUsdc;
        emit ContributionClaimed(jobId, index, recipient, amountUsdc, workReceiptDigest);
    }

    /// @notice Returns worker funds that were not claimed before the immutable job boundary.
    /// @dev This changes only credit ownership; total USDC liability was already moved to
    ///      creditLiabilityUsdc when the result was accepted.
    function reclaimUnclaimedWorkerPool(bytes32 jobId) external onlyPinnedChain {
        Job storage jobState = _jobs[jobId];
        if (jobState.terms.payer == address(0)) revert UnknownJob(jobId);
        if (!jobState.accepted || jobState.refunded) revert InvalidContribution();
        if (msg.sender != jobState.terms.payer) revert Unauthorized();
        if (block.timestamp < jobState.terms.refundAfter) revert RefundNotAvailable(jobState.terms.refundAfter);
        if (jobState.workerPoolClosed) revert WorkerPoolAlreadyClosed(jobId);
        jobState.workerPoolClosed = true;
        uint256 amountUsdc = uint256(jobState.terms.workerPoolUsdc) - jobState.claimedWorkerUsdc;
        usdcCredits[jobState.terms.payer] += amountUsdc;
        emit UnclaimedWorkerPoolReclaimed(jobId, jobState.terms.payer, amountUsdc);
    }

    function refundExpiredJob(bytes32 jobId) external onlyPinnedChain {
        Job storage jobState = _jobs[jobId];
        if (jobState.terms.payer == address(0)) revert UnknownJob(jobId);
        if (jobState.accepted || jobState.refunded) revert AlreadyTerminal(jobId);
        if (block.timestamp < jobState.terms.refundAfter) revert RefundNotAvailable(jobState.terms.refundAfter);
        jobState.refunded = true;
        uint256 totalUsdc = _total(jobState.terms);
        escrowLiabilityUsdc -= totalUsdc;
        creditLiabilityUsdc += totalUsdc;
        usdcCredits[jobState.terms.payer] += totalUsdc;
        _assertSolvent();
        emit JobRefunded(jobId, jobState.terms.payer, totalUsdc);
    }

    function claimUsdcCredit() external onlyPinnedChain nonReentrant returns (uint256 amountUsdc) {
        amountUsdc = usdcCredits[msg.sender];
        if (amountUsdc == 0) revert NothingToClaim();
        usdcCredits[msg.sender] = 0;
        creditLiabilityUsdc -= amountUsdc;
        uint256 beforeEscrow = USDC.balanceOf(address(this));
        uint256 beforeRecipient = USDC.balanceOf(msg.sender);
        _safeTransfer(msg.sender, amountUsdc);
        uint256 afterEscrow = USDC.balanceOf(address(this));
        uint256 afterRecipient = USDC.balanceOf(msg.sender);
        if (
            beforeEscrow < afterEscrow || beforeEscrow - afterEscrow != amountUsdc || afterRecipient < beforeRecipient
                || afterRecipient - beforeRecipient != amountUsdc
        ) revert UnsupportedTokenBehavior();
        _assertSolvent();
        emit UsdcCreditClaimed(msg.sender, amountUsdc);
    }

    function setPaused(bool value) external onlyPinnedChain {
        if (msg.sender != pauseGuardian) revert Unauthorized();
        paused = value;
        emit PauseUpdated(value);
    }

    function hashJobTerms(JobTerms memory terms, address verifier, bytes32 verifierCodeHash)
        public
        view
        returns (bytes32)
    {
        bytes32 deploymentHash = keccak256(
            abi.encode(
                DEPLOYMENT_TERMS_TYPEHASH,
                BASE_MAINNET_CHAIN_ID,
                address(this),
                terms.routeId,
                verifier,
                verifierCodeHash
            )
        );
        bytes32 requestHash = keccak256(
            abi.encode(
                REQUEST_TERMS_TYPEHASH,
                terms.clientSalt,
                terms.taskSpecDigest,
                terms.quoteDigest,
                terms.outcomeContractDigest
            )
        );
        bytes32 paymentHash = keccak256(
            abi.encode(
                PAYMENT_TERMS_TYPEHASH,
                terms.payer,
                terms.verifierFeeRecipient,
                terms.protocolFeeRecipient,
                terms.workerPoolUsdc,
                terms.verifierFeeUsdc,
                terms.protocolFeeUsdc,
                terms.refundAfter
            )
        );
        return keccak256(abi.encode(JOB_TERMS_TYPEHASH, deploymentHash, requestHash, paymentHash));
    }

    function job(bytes32 jobId) external view returns (Job memory) {
        return _jobs[jobId];
    }

    function isContributionClaimed(bytes32 jobId, uint256 index) external view returns (bool) {
        return _claimedContributions[jobId][index >> 8] & (uint256(1) << (index & 255)) != 0;
    }

    function totalLiabilityUsdc() external view returns (uint256) {
        return escrowLiabilityUsdc + creditLiabilityUsdc;
    }

    function _total(JobTerms memory terms) private pure returns (uint256) {
        return uint256(terms.workerPoolUsdc) + uint256(terms.verifierFeeUsdc) + uint256(terms.protocolFeeUsdc);
    }

    function _verifyMerkleSumProof(
        Job storage jobState,
        uint256 index,
        uint128 amountUsdc,
        bytes32 contributionLeaf,
        ContributionProofNode[] calldata proof
    ) private view returns (bool) {
        bytes32 nodeHash = keccak256(
            abi.encode(CONTRIBUTION_LEAF_NODE_TYPEHASH, contributionLeaf, amountUsdc, uint32(1))
        );
        uint256 totalUsdc = amountUsdc;
        uint256 count = 1;
        for (uint256 level; level < CONTRIBUTION_TREE_DEPTH; ++level) {
            ContributionProofNode calldata sibling = proof[level];
            uint256 siblingCapacity = uint256(1) << level;
            if (
                sibling.nodeHash == bytes32(0) || sibling.contributionCount > siblingCapacity
                    || (sibling.contributionCount == 0) != (sibling.contributionTotalUsdc == 0)
            ) return false;
            uint256 nextTotal = totalUsdc + sibling.contributionTotalUsdc;
            uint256 nextCount = count + sibling.contributionCount;
            if (
                nextTotal > jobState.contributionTotalUsdc || nextCount > (uint256(1) << (level + 1))
                    || nextCount > MAX_CONTRIBUTIONS
            ) return false;
            if (((index >> level) & 1) == 0) {
                nodeHash = keccak256(
                    abi.encode(
                        CONTRIBUTION_NODE_TYPEHASH,
                        nodeHash,
                        uint128(totalUsdc),
                        uint32(count),
                        sibling.nodeHash,
                        sibling.contributionTotalUsdc,
                        sibling.contributionCount
                    )
                );
            } else {
                nodeHash = keccak256(
                    abi.encode(
                        CONTRIBUTION_NODE_TYPEHASH,
                        sibling.nodeHash,
                        sibling.contributionTotalUsdc,
                        sibling.contributionCount,
                        nodeHash,
                        uint128(totalUsdc),
                        uint32(count)
                    )
                );
            }
            totalUsdc = nextTotal;
            count = nextCount;
        }
        return nodeHash == jobState.contributionRoot && totalUsdc == jobState.contributionTotalUsdc
            && count == jobState.contributionCount;
    }

    function _safeTransfer(address recipient, uint256 amount) private {
        (bool success, bytes memory data) =
            BASE_MAINNET_USDC.call(abi.encodeCall(ISkewComputeUsdcV1.transfer, (recipient, amount)));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TokenTransferFailed();
    }

    function _safeTransferFrom(address owner, address recipient, uint256 amount) private {
        (bool success, bytes memory data) =
            BASE_MAINNET_USDC.call(abi.encodeCall(ISkewComputeUsdcV1.transferFrom, (owner, recipient, amount)));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TokenTransferFailed();
    }

    function _assertSolvent() private view {
        uint256 liability = escrowLiabilityUsdc + creditLiabilityUsdc;
        uint256 balance = USDC.balanceOf(address(this));
        if (balance < liability) revert Insolvent(balance, liability);
    }
}
