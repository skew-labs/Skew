// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {
    ISkewComputeReceiptVerifierV1,
    ISkewComputeUsdcV1
} from "../../src/settlement-compute/ISkewComputeSettlementV1.sol";
import { SkewBaseComputeEscrowV1 } from "../../src/settlement-compute/SkewBaseComputeEscrowV1.sol";
import { SkewBaseComputeRouteRegistryV1 } from "../../src/settlement-compute/SkewBaseComputeRouteRegistryV1.sol";
import { SkewEcdsaQuorumReceiptVerifierV1 } from "../../src/settlement-compute/SkewEcdsaQuorumReceiptVerifierV1.sol";

interface ISkewComputeVm {
    function chainId(uint256) external;
    function etch(address, bytes calldata) external;
    function prank(address) external;
    function warp(uint256) external;
    function addr(uint256 privateKey) external returns (address);
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
}

contract ComputeMockUsdc is ISkewComputeUsdcV1 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public feeOnTransfer;

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function mint(address recipient, uint256 amount) external {
        balanceOf[recipient] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        _move(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool) {
        require(allowance[owner][msg.sender] >= amount, "allowance");
        allowance[owner][msg.sender] -= amount;
        _move(owner, recipient, amount);
        return true;
    }

    function setFeeOnTransfer(bool value) external {
        feeOnTransfer = value;
    }

    function _move(address owner, address recipient, uint256 amount) private {
        require(balanceOf[owner] >= amount, "balance");
        balanceOf[owner] -= amount;
        balanceOf[recipient] += feeOnTransfer && amount > 0 ? amount - 1 : amount;
    }
}

contract ComputeGuardian { }

contract SkewBaseComputeSettlementV1Test {
    ISkewComputeVm private constant VM = ISkewComputeVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant PAYER = address(0xB0B);
    address private constant WORKER_A = address(0xA11CE);
    address private constant WORKER_B = address(0xBEEF);
    address private constant VERIFIER_FEE = address(0xF111);
    address private constant PROTOCOL_FEE = address(0xF222);
    bytes32 private constant CONTRIBUTION_TYPEHASH = keccak256(
        "SkewComputeContributionV1(bytes32 jobId,uint256 index,address recipient,uint128 amountUsdc,bytes32 workReceiptDigest)"
    );
    bytes32 private constant CONTRIBUTION_LEAF_NODE_TYPEHASH = keccak256(
        "SkewComputeContributionLeafNodeV2(bytes32 contributionLeaf,uint128 contributionTotalUsdc,uint32 contributionCount)"
    );
    bytes32 private constant CONTRIBUTION_EMPTY_LEAF_TYPEHASH = keccak256("SkewComputeContributionEmptyLeafV2()");
    bytes32 private constant CONTRIBUTION_NODE_TYPEHASH = keccak256(
        "SkewComputeContributionNodeV2(bytes32 leftHash,uint128 leftTotalUsdc,uint32 leftCount,bytes32 rightHash,uint128 rightTotalUsdc,uint32 rightCount)"
    );
    uint256 private constant SECP256K1N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
    uint128 private constant MAX_JOB_USDC = 1_000_000_000_000;
    uint128 private constant MAX_TOTAL_LIABILITY_USDC = 2_000_000_000_000;

    ComputeMockUsdc private token;
    ComputeGuardian private guardian;
    SkewBaseComputeRouteRegistryV1 private registry;
    SkewEcdsaQuorumReceiptVerifierV1 private verifier;
    SkewBaseComputeEscrowV1 private escrow;
    bytes32 private routeId;
    uint256 private signerKeyA;
    uint256 private signerKeyB;

    struct TestContributionNode {
        bytes32 nodeHash;
        uint128 contributionTotalUsdc;
        uint32 contributionCount;
        uint256 members;
    }

    function setUp() public {
        VM.chainId(8453);
        VM.etch(USDC, type(ComputeMockUsdc).runtimeCode);
        token = ComputeMockUsdc(USDC);
        guardian = new ComputeGuardian();
        signerKeyA = 0xA11CE;
        signerKeyB = 0xB0B;
        address signerA = VM.addr(signerKeyA);
        address signerB = VM.addr(signerKeyB);
        if (signerA > signerB) {
            (signerKeyA, signerKeyB) = (signerKeyB, signerKeyA);
            (signerA, signerB) = (signerB, signerA);
        }
        address[] memory signers = new address[](2);
        signers[0] = signerA;
        signers[1] = signerB;
        verifier = new SkewEcdsaQuorumReceiptVerifierV1(signers, 2);
        registry = new SkewBaseComputeRouteRegistryV1(address(this), address(guardian));
        routeId =
            registry.registerRoute(bytes32("compute-v1"), address(verifier), address(verifier).codehash, 2_000, 2_000);
        escrow = new SkewBaseComputeEscrowV1(registry, address(guardian), MAX_JOB_USDC, MAX_TOTAL_LIABILITY_USDC);
    }

    function testVerifiedOutcomeCreditsOnlyMerkleBoundContributions() public {
        (bytes32 jobId, SkewBaseComputeEscrowV1.JobTerms memory terms) = _fund(bytes32("accepted"), 2 days);
        bytes32 workA = keccak256("work-a");
        bytes32 workB = keccak256("work-b");
        (
            bytes32 root,
            SkewBaseComputeEscrowV1.ContributionProofNode[] memory proofA,
            SkewBaseComputeEscrowV1.ContributionProofNode[] memory proofB
        ) = _doubleTree(jobId, WORKER_A, 400_000, workA, WORKER_B, 400_000, workB);
        ISkewComputeReceiptVerifierV1.Receipt memory receipt = _receipt(jobId, terms, root);
        receipt.contributionCount = 2;
        bytes[] memory signatures = _sign(receipt);

        bytes32 receiptDigest = escrow.acceptVerifiedResult(jobId, receipt, signatures);
        require(receiptDigest == verifier.hashReceipt(receipt), "receipt digest");
        require(escrow.escrowLiabilityUsdc() == 0, "escrow liability");
        require(escrow.creditLiabilityUsdc() == 1_000_000, "credit liability");
        require(escrow.usdcCredits(VERIFIER_FEE) == 100_000, "verifier fee");
        require(escrow.usdcCredits(PROTOCOL_FEE) == 100_000, "protocol fee");

        escrow.claimContribution(jobId, 0, WORKER_A, 400_000, workA, proofA);
        escrow.claimContribution(jobId, 1, WORKER_B, 400_000, workB, proofB);
        require(escrow.usdcCredits(WORKER_A) == 400_000, "worker a credit");
        require(escrow.usdcCredits(WORKER_B) == 400_000, "worker b credit");
        require(token.balanceOf(address(escrow)) == escrow.totalLiabilityUsdc(), "conservation");

        (bool duplicate,) = address(escrow)
            .call(
                abi.encodeCall(SkewBaseComputeEscrowV1.claimContribution, (jobId, 0, WORKER_A, 400_000, workA, proofA))
            );
        require(!duplicate, "duplicate contribution");

        _claim(WORKER_A);
        _claim(WORKER_B);
        _claim(VERIFIER_FEE);
        _claim(PROTOCOL_FEE);
        require(token.balanceOf(address(escrow)) == 0, "escrow dust");
    }

    function testQuorumTamperReplayAndInvalidProofFailClosed() public {
        (bytes32 jobId, SkewBaseComputeEscrowV1.JobTerms memory terms) = _fund(bytes32("guards"), 2 days);
        bytes32 workA = keccak256("work-a");
        bytes32 root = _singleRoot(jobId, WORKER_A, 800_000, workA);
        ISkewComputeReceiptVerifierV1.Receipt memory receipt = _receipt(jobId, terms, root);
        bytes[] memory oneSignature = new bytes[](1);
        oneSignature[0] = _signature(signerKeyA, verifier.hashReceipt(receipt));
        (bool missingQuorum,) = address(escrow)
            .call(abi.encodeCall(SkewBaseComputeEscrowV1.acceptVerifiedResult, (jobId, receipt, oneSignature)));
        require(!missingQuorum, "missing quorum");

        bytes[] memory signatures = _sign(receipt);
        ISkewComputeReceiptVerifierV1.Receipt memory tampered = receipt;
        tampered.outputDigest = keccak256("tampered");
        (bool tamperAccepted,) = address(escrow)
            .call(abi.encodeCall(SkewBaseComputeEscrowV1.acceptVerifiedResult, (jobId, tampered, signatures)));
        require(!tamperAccepted, "tampered receipt");
        // Solidity memory structs alias on assignment; rebuild the signed receipt
        // after the deliberate mutation instead of reusing the aliased value.
        receipt = _receipt(jobId, terms, root);
        escrow.acceptVerifiedResult(jobId, receipt, signatures);
        (bool replay,) = address(escrow)
            .call(abi.encodeCall(SkewBaseComputeEscrowV1.acceptVerifiedResult, (jobId, receipt, signatures)));
        require(!replay, "terminal replay");
    }

    function testInvalidMerkleSumProofFailsClosed() public {
        (bytes32 jobId, SkewBaseComputeEscrowV1.JobTerms memory terms) = _fund(bytes32("bad-proof"), 2 days);
        bytes32 work = keccak256("proof-bound-work");
        (bytes32 root, SkewBaseComputeEscrowV1.ContributionProofNode[] memory badProof) =
            _singleTree(jobId, WORKER_A, 800_000, work);
        ISkewComputeReceiptVerifierV1.Receipt memory receipt = _receipt(jobId, terms, root);
        escrow.acceptVerifiedResult(jobId, receipt, _sign(receipt));
        badProof[0].nodeHash = keccak256("not-a-sibling");
        require(!_tryClaim(jobId, 0, WORKER_A, 800_000, work, badProof), "invalid merkle-sum proof");
    }

    function testDisabledRoutePauseAndTimeoutPreserveRefund() public {
        (bytes32 jobId, SkewBaseComputeEscrowV1.JobTerms memory terms) = _fund(bytes32("refund"), 1 days);
        bytes32 work = keccak256("work");
        ISkewComputeReceiptVerifierV1.Receipt memory receipt =
            _receipt(jobId, terms, _singleRoot(jobId, WORKER_A, 800_000, work));
        bytes[] memory signatures = _sign(receipt);
        VM.prank(address(guardian));
        registry.disableRoute(routeId);
        (bool accepted,) = address(escrow)
            .call(abi.encodeCall(SkewBaseComputeEscrowV1.acceptVerifiedResult, (jobId, receipt, signatures)));
        require(!accepted, "disabled route");
        VM.prank(address(guardian));
        escrow.setPaused(true);
        VM.warp(block.timestamp + 1 days);
        escrow.refundExpiredJob(jobId);
        _claim(PAYER);
        require(token.balanceOf(PAYER) == 1_000_000, "refund");
    }

    function testFeeOnTransferAndFeeCapsFailClosed() public {
        token.setFeeOnTransfer(true);
        (bool feeToken,) = _tryFund(bytes32("fee-token"), 800_000, 100_000, 100_000, 2 days);
        require(!feeToken, "fee-on-transfer token");
        token.setFeeOnTransfer(false);
        (bool feeCap,) = _tryFund(bytes32("fee-cap"), 1, 499_999, 500_000, 2 days);
        require(!feeCap, "fee cap");
    }

    function testImmutableCanaryCapsLimitOneJobAndAggregateCustody() public {
        SkewBaseComputeEscrowV1 capped = new SkewBaseComputeEscrowV1(registry, address(guardian), 1_000_000, 1_500_000);

        SkewBaseComputeEscrowV1.JobTerms memory oversized =
            _terms(bytes32("oversized"), 900_001, 50_000, 50_000, 2 days);
        token.mint(PAYER, 1_000_001);
        VM.prank(PAYER);
        token.approve(address(capped), 1_000_001);
        VM.prank(PAYER);
        (bool oneJobAccepted,) = address(capped).call(abi.encodeCall(SkewBaseComputeEscrowV1.fundJob, (oversized)));
        require(!oneJobAccepted, "one-job cap bypassed");

        SkewBaseComputeEscrowV1.JobTerms memory first = _terms(bytes32("aggregate-a"), 700_000, 50_000, 50_000, 2 days);
        SkewBaseComputeEscrowV1.JobTerms memory second = _terms(bytes32("aggregate-b"), 700_000, 50_000, 50_000, 2 days);
        token.mint(PAYER, 1_600_000);
        VM.prank(PAYER);
        token.approve(address(capped), 1_600_000);
        VM.prank(PAYER);
        capped.fundJob(first);
        VM.prank(PAYER);
        (bool aggregateAccepted,) = address(capped).call(abi.encodeCall(SkewBaseComputeEscrowV1.fundJob, (second)));
        require(!aggregateAccepted, "aggregate custody cap bypassed");
        require(capped.escrowLiabilityUsdc() == 800_000, "capped liability changed");
        require(token.balanceOf(address(capped)) == 800_000, "capped balance changed");
    }

    function testUnclaimableRecipientsAndSharedGovernanceGuardianFailClosed() public {
        SkewBaseComputeEscrowV1.JobTerms memory terms =
            _terms(bytes32("bad-fee-recipient"), 800_000, 100_000, 100_000, 2 days);
        terms.verifierFeeRecipient = address(escrow);
        token.mint(PAYER, 1_000_000);
        VM.prank(PAYER);
        token.approve(address(escrow), 1_000_000);
        VM.prank(PAYER);
        (bool escrowRecipient,) = address(escrow).call(abi.encodeCall(SkewBaseComputeEscrowV1.fundJob, (terms)));
        require(!escrowRecipient, "escrow fee recipient");

        terms.verifierFeeRecipient = USDC;
        VM.prank(PAYER);
        (bool tokenRecipient,) = address(escrow).call(abi.encodeCall(SkewBaseComputeEscrowV1.fundJob, (terms)));
        require(!tokenRecipient, "token fee recipient");

        (bool sharedRoles,) = address(this).call(abi.encodeCall(this.deployRegistryWithSharedRoles, ()));
        require(!sharedRoles, "shared governance guardian");

        (bytes32 jobId, SkewBaseComputeEscrowV1.JobTerms memory fundedTerms) = _fund(bytes32("bad-worker"), 2 days);
        bytes32 work = keccak256("bad-worker");
        ISkewComputeReceiptVerifierV1.Receipt memory receipt =
            _receipt(jobId, fundedTerms, _singleRoot(jobId, address(escrow), 800_000, work));
        escrow.acceptVerifiedResult(jobId, receipt, _sign(receipt));
        (bool workerClaim,) = address(escrow)
            .call(
                abi.encodeCall(
                    SkewBaseComputeEscrowV1.claimContribution, (jobId, 0, address(escrow), 800_000, work, _emptyProof())
                )
            );
        require(!workerClaim, "escrow worker recipient");
    }

    function testAcceptanceDeadlineIsExclusiveAndRefundDeadlineInclusive() public {
        (bytes32 jobId, SkewBaseComputeEscrowV1.JobTerms memory terms) = _fund(bytes32("deadline"), 1 days);
        bytes32 root = _singleRoot(jobId, WORKER_A, 800_000, keccak256("deadline-work"));
        ISkewComputeReceiptVerifierV1.Receipt memory receipt = _receipt(jobId, terms, root);
        bytes[] memory signatures = _sign(receipt);

        VM.warp(terms.refundAfter);
        (bool accepted,) = address(escrow)
            .call(abi.encodeCall(SkewBaseComputeEscrowV1.acceptVerifiedResult, (jobId, receipt, signatures)));
        require(!accepted, "accepted at refund boundary");
        escrow.refundExpiredJob(jobId);
        require(escrow.usdcCredits(PAYER) == 1_000_000, "refund credit missing");
        require(token.balanceOf(address(escrow)) == escrow.totalLiabilityUsdc(), "deadline conservation");
    }

    function testReceiptCannotOutliveJobRefundBoundary() public {
        (bytes32 jobId, SkewBaseComputeEscrowV1.JobTerms memory terms) = _fund(bytes32("receipt-window"), 1 days);
        bytes32 root = _singleRoot(jobId, WORKER_A, 800_000, keccak256("window-work"));
        ISkewComputeReceiptVerifierV1.Receipt memory receipt = _receipt(jobId, terms, root);
        receipt.validUntil = terms.refundAfter + 1;
        bytes[] memory signatures = _sign(receipt);
        (bool accepted,) = address(escrow)
            .call(abi.encodeCall(SkewBaseComputeEscrowV1.acceptVerifiedResult, (jobId, receipt, signatures)));
        require(!accepted, "receipt exceeded job boundary");
    }

    function testSignatureOrderingUniquenessAndLowSFailClosed() public {
        (bytes32 jobId, SkewBaseComputeEscrowV1.JobTerms memory terms) = _fund(bytes32("signature-policy"), 2 days);
        ISkewComputeReceiptVerifierV1.Receipt memory receipt =
            _receipt(jobId, terms, _singleRoot(jobId, WORKER_A, 800_000, keccak256("signature-work")));
        bytes32 digest = verifier.hashReceipt(receipt);
        bytes memory signatureA = _signature(signerKeyA, digest);
        bytes memory signatureB = _signature(signerKeyB, digest);

        bytes[] memory reversed = new bytes[](2);
        reversed[0] = signatureB;
        reversed[1] = signatureA;
        (bool reversedAccepted,) =
            address(verifier).call(abi.encodeCall(SkewEcdsaQuorumReceiptVerifierV1.verifyReceipt, (receipt, reversed)));
        require(!reversedAccepted, "reversed signers");

        bytes[] memory duplicate = new bytes[](2);
        duplicate[0] = signatureA;
        duplicate[1] = signatureA;
        (bool duplicateAccepted,) =
            address(verifier).call(abi.encodeCall(SkewEcdsaQuorumReceiptVerifierV1.verifyReceipt, (receipt, duplicate)));
        require(!duplicateAccepted, "duplicate signer");

        bytes[] memory highS = new bytes[](2);
        highS[0] = _highSSignature(signerKeyA, digest);
        highS[1] = signatureB;
        (bool highSAccepted,) =
            address(verifier).call(abi.encodeCall(SkewEcdsaQuorumReceiptVerifierV1.verifyReceipt, (receipt, highS)));
        require(!highSAccepted, "high-s signature");

        bytes[] memory invalidV = new bytes[](2);
        invalidV[0] = _signatureWithV(signerKeyA, digest, 29);
        invalidV[1] = signatureB;
        (bool invalidVAccepted,) =
            address(verifier).call(abi.encodeCall(SkewEcdsaQuorumReceiptVerifierV1.verifyReceipt, (receipt, invalidV)));
        require(!invalidVAccepted, "invalid-v signature");
    }

    function testExpiredReceiptAndWrongChainFailClosed() public {
        (bytes32 jobId, SkewBaseComputeEscrowV1.JobTerms memory terms) = _fund(bytes32("chain-expiry"), 2 days);
        ISkewComputeReceiptVerifierV1.Receipt memory receipt =
            _receipt(jobId, terms, _singleRoot(jobId, WORKER_A, 800_000, keccak256("expiry-work")));
        bytes[] memory signatures = _sign(receipt);
        VM.warp(receipt.validUntil + 1);
        (bool expiredAccepted,) = address(verifier)
            .call(abi.encodeCall(SkewEcdsaQuorumReceiptVerifierV1.verifyReceipt, (receipt, signatures)));
        require(!expiredAccepted, "expired receipt");

        VM.chainId(1);
        (bool wrongChainVerification,) = address(verifier)
            .call(abi.encodeCall(SkewEcdsaQuorumReceiptVerifierV1.verifyReceipt, (receipt, signatures)));
        require(!wrongChainVerification, "wrong-chain verification");
        (bool wrongChainFunding,) = address(this).call(abi.encodeCall(this.fundOnCurrentChain, (terms)));
        require(!wrongChainFunding, "wrong-chain funding");
        (bool verifierDeployment,) = address(this).call(abi.encodeCall(this.deployVerifierOnCurrentChain, ()));
        require(!verifierDeployment, "wrong-chain verifier deployment");
        (bool registryDeployment,) = address(this).call(abi.encodeCall(this.deployRegistryOnCurrentChain, ()));
        require(!registryDeployment, "wrong-chain registry deployment");
        (bool escrowDeployment,) = address(this).call(abi.encodeCall(this.deployEscrowOnCurrentChain, ()));
        require(!escrowDeployment, "wrong-chain escrow deployment");
    }

    function testContributionLeafBindsEveryEconomicField() public {
        (bytes32 jobId, SkewBaseComputeEscrowV1.JobTerms memory terms) = _fund(bytes32("leaf-fields"), 2 days);
        bytes32 work = keccak256("field-bound-work");
        (bytes32 root, SkewBaseComputeEscrowV1.ContributionProofNode[] memory proof) =
            _singleTree(jobId, WORKER_A, 800_000, work);
        ISkewComputeReceiptVerifierV1.Receipt memory receipt = _receipt(jobId, terms, root);
        escrow.acceptVerifiedResult(jobId, receipt, _sign(receipt));

        (bool wrongIndex,) = address(escrow)
            .call(abi.encodeCall(SkewBaseComputeEscrowV1.claimContribution, (jobId, 1, WORKER_A, 800_000, work, proof)));
        (bool wrongRecipient,) = address(escrow)
            .call(abi.encodeCall(SkewBaseComputeEscrowV1.claimContribution, (jobId, 0, WORKER_B, 800_000, work, proof)));
        (bool wrongAmount,) = address(escrow)
            .call(abi.encodeCall(SkewBaseComputeEscrowV1.claimContribution, (jobId, 0, WORKER_A, 799_999, work, proof)));
        (bool wrongWork,) = address(escrow)
            .call(
                abi.encodeCall(
                    SkewBaseComputeEscrowV1.claimContribution,
                    (jobId, 0, WORKER_A, 800_000, keccak256("different-work"), proof)
                )
            );
        require(!wrongIndex && !wrongRecipient && !wrongAmount && !wrongWork, "unbound contribution field");
        escrow.claimContribution(jobId, 0, WORKER_A, 800_000, work, proof);
    }

    function testMixedLifecycleConservesEveryUsdcUnit() public {
        (bytes32 acceptedJob, SkewBaseComputeEscrowV1.JobTerms memory acceptedTerms) =
            _fund(bytes32("conservation-accepted"), 2 days);
        (bytes32 refundJob, SkewBaseComputeEscrowV1.JobTerms memory refundTerms) =
            _fund(bytes32("conservation-refund"), 1 days);
        require(token.balanceOf(address(escrow)) == 2_000_000, "initial balance");
        require(token.balanceOf(address(escrow)) == escrow.totalLiabilityUsdc(), "initial conservation");

        bytes32 work = keccak256("conservation-work");
        (, SkewBaseComputeEscrowV1.ContributionProofNode[] memory acceptedProof) =
            _singleTree(acceptedJob, WORKER_A, 800_000, work);
        ISkewComputeReceiptVerifierV1.Receipt memory receipt =
            _receipt(acceptedJob, acceptedTerms, _singleRoot(acceptedJob, WORKER_A, 800_000, work));
        escrow.acceptVerifiedResult(acceptedJob, receipt, _sign(receipt));
        escrow.claimContribution(acceptedJob, 0, WORKER_A, 800_000, work, acceptedProof);
        require(token.balanceOf(address(escrow)) == escrow.totalLiabilityUsdc(), "accepted conservation");

        VM.warp(refundTerms.refundAfter);
        escrow.refundExpiredJob(refundJob);
        require(token.balanceOf(address(escrow)) == escrow.totalLiabilityUsdc(), "refund conservation");
        _claim(WORKER_A);
        _claim(VERIFIER_FEE);
        _claim(PROTOCOL_FEE);
        _claim(PAYER);
        require(token.balanceOf(address(escrow)) == 0, "terminal balance");
        require(escrow.totalLiabilityUsdc() == 0, "terminal liability");
    }

    function testFuzzAcceptedSingleContributionConserves(uint96 rawAmount) public {
        uint128 worker = uint128(1 + uint256(rawAmount) % 1_000_000_000_000);
        bytes32 salt = keccak256(abi.encode("fuzz-conservation", rawAmount));
        (bool ok, bytes memory result) = _tryFund(salt, worker, 0, 0, 2 days);
        require(ok, "fuzz fund");
        bytes32 jobId = abi.decode(result, (bytes32));
        SkewBaseComputeEscrowV1.JobTerms memory terms = _terms(salt, worker, 0, 0, 2 days);
        bytes32 work = keccak256(abi.encode("fuzz-work", rawAmount));
        (, SkewBaseComputeEscrowV1.ContributionProofNode[] memory proof) = _singleTree(jobId, WORKER_A, worker, work);
        ISkewComputeReceiptVerifierV1.Receipt memory receipt =
            _receipt(jobId, terms, _singleRoot(jobId, WORKER_A, worker, work));
        escrow.acceptVerifiedResult(jobId, receipt, _sign(receipt));
        escrow.claimContribution(jobId, 0, WORKER_A, worker, work, proof);
        require(token.balanceOf(address(escrow)) == escrow.totalLiabilityUsdc(), "fuzz conservation");
        require(escrow.usdcCredits(WORKER_A) == worker, "fuzz worker credit");
    }

    function testFuzzContributionAbovePoolFails(uint96 rawAmount) public {
        uint128 worker = uint128(1 + uint256(rawAmount) % 1_000_000_000_000);
        uint128 claimed = worker + 1;
        bytes32 salt = keccak256(abi.encode("fuzz-overflow", rawAmount));
        (bool ok, bytes memory result) = _tryFund(salt, worker, 0, 0, 2 days);
        require(ok, "overflow fund");
        bytes32 jobId = abi.decode(result, (bytes32));
        SkewBaseComputeEscrowV1.JobTerms memory terms = _terms(salt, worker, 0, 0, 2 days);
        bytes32 work = keccak256(abi.encode("overflow-work", rawAmount));
        ISkewComputeReceiptVerifierV1.Receipt memory receipt =
            _receipt(jobId, terms, _singleRoot(jobId, WORKER_A, claimed, work));
        receipt.contributionTotalUsdc = claimed;
        (bool accepted,) = address(escrow)
            .call(abi.encodeCall(SkewBaseComputeEscrowV1.acceptVerifiedResult, (jobId, receipt, _sign(receipt))));
        require(!accepted, "over-sum contribution accepted");
        require(token.balanceOf(address(escrow)) == escrow.totalLiabilityUsdc(), "overflow conservation");
    }

    function testUnderSumAndInvalidCountFailAtAcceptance() public {
        (bytes32 jobId, SkewBaseComputeEscrowV1.JobTerms memory terms) = _fund(bytes32("sum-count"), 2 days);
        bytes32 work = keccak256("under-sum-work");
        ISkewComputeReceiptVerifierV1.Receipt memory under =
            _receipt(jobId, terms, _singleRoot(jobId, WORKER_A, 799_999, work));
        under.contributionTotalUsdc = 799_999;
        (bool underAccepted,) = address(escrow)
            .call(abi.encodeCall(SkewBaseComputeEscrowV1.acceptVerifiedResult, (jobId, under, _sign(under))));
        require(!underAccepted, "under-sum contribution accepted");

        ISkewComputeReceiptVerifierV1.Receipt memory zeroCount =
            _receipt(jobId, terms, _singleRoot(jobId, WORKER_A, 800_000, work));
        zeroCount.contributionCount = 0;
        (bool zeroAccepted,) = address(escrow)
            .call(abi.encodeCall(SkewBaseComputeEscrowV1.acceptVerifiedResult, (jobId, zeroCount, _sign(zeroCount))));
        require(!zeroAccepted, "zero contribution count accepted");

        ISkewComputeReceiptVerifierV1.Receipt memory excessiveCount =
            _receipt(jobId, terms, _singleRoot(jobId, WORKER_A, 800_000, work));
        excessiveCount.contributionCount = 257;
        (bool excessiveAccepted,) = address(escrow)
            .call(
                abi.encodeCall(
                    SkewBaseComputeEscrowV1.acceptVerifiedResult, (jobId, excessiveCount, _sign(excessiveCount))
                )
            );
        require(!excessiveAccepted, "excessive contribution count accepted");
    }

    function testPartialClaimsThenPayerReclaimsExactRemainderOnce() public {
        (bytes32 jobId, SkewBaseComputeEscrowV1.JobTerms memory terms) = _fund(bytes32("worker-sweep"), 2 days);
        bytes32 workA = keccak256("sweep-work-a");
        bytes32 workB = keccak256("sweep-work-b");
        (
            bytes32 root,
            SkewBaseComputeEscrowV1.ContributionProofNode[] memory proofA,
            SkewBaseComputeEscrowV1.ContributionProofNode[] memory proofB
        ) = _doubleTree(jobId, WORKER_A, 300_000, workA, WORKER_B, 500_000, workB);
        ISkewComputeReceiptVerifierV1.Receipt memory receipt = _receipt(jobId, terms, root);
        receipt.contributionCount = 2;
        escrow.acceptVerifiedResult(jobId, receipt, _sign(receipt));
        escrow.claimContribution(jobId, 0, WORKER_A, 300_000, workA, proofA);

        VM.warp(terms.refundAfter - 1);
        VM.prank(PAYER);
        (bool earlySweep,) =
            address(escrow).call(abi.encodeCall(SkewBaseComputeEscrowV1.reclaimUnclaimedWorkerPool, (jobId)));
        require(!earlySweep, "early worker-pool sweep");

        VM.warp(terms.refundAfter);
        (bool lateWorkerClaim,) = address(escrow)
            .call(
                abi.encodeCall(SkewBaseComputeEscrowV1.claimContribution, (jobId, 1, WORKER_B, 500_000, workB, proofB))
            );
        require(!lateWorkerClaim, "worker claimed at refund boundary");
        VM.prank(PAYER);
        escrow.reclaimUnclaimedWorkerPool(jobId);
        require(escrow.usdcCredits(PAYER) == 500_000, "payer remainder");
        require(escrow.usdcCredits(WORKER_A) == 300_000, "claimed worker changed");
        VM.prank(PAYER);
        (bool duplicateSweep,) =
            address(escrow).call(abi.encodeCall(SkewBaseComputeEscrowV1.reclaimUnclaimedWorkerPool, (jobId)));
        require(!duplicateSweep, "duplicate worker-pool sweep");
        require(token.balanceOf(address(escrow)) == escrow.totalLiabilityUsdc(), "sweep conservation");
    }

    function fundOnCurrentChain(SkewBaseComputeEscrowV1.JobTerms calldata terms) external {
        escrow.fundJob(terms);
    }

    function deployVerifierOnCurrentChain() external {
        address[] memory signers = new address[](1);
        signers[0] = VM.addr(1);
        new SkewEcdsaQuorumReceiptVerifierV1(signers, 1);
    }

    function deployRegistryOnCurrentChain() external {
        new SkewBaseComputeRouteRegistryV1(address(this), address(guardian));
    }

    function deployRegistryWithSharedRoles() external {
        new SkewBaseComputeRouteRegistryV1(address(guardian), address(guardian));
    }

    function deployEscrowOnCurrentChain() external {
        new SkewBaseComputeEscrowV1(registry, address(guardian), MAX_JOB_USDC, MAX_TOTAL_LIABILITY_USDC);
    }

    function _fund(bytes32 salt, uint64 ttl)
        private
        returns (bytes32 jobId, SkewBaseComputeEscrowV1.JobTerms memory terms)
    {
        (bool ok, bytes memory result) = _tryFund(salt, 800_000, 100_000, 100_000, ttl);
        require(ok, "fund");
        jobId = abi.decode(result, (bytes32));
        terms = _terms(salt, 800_000, 100_000, 100_000, ttl);
    }

    function _tryFund(bytes32 salt, uint128 worker, uint128 verifierAmount, uint128 protocol, uint64 ttl)
        private
        returns (bool, bytes memory)
    {
        SkewBaseComputeEscrowV1.JobTerms memory terms = _terms(salt, worker, verifierAmount, protocol, ttl);
        uint256 total = uint256(worker) + verifierAmount + protocol;
        token.mint(PAYER, total);
        VM.prank(PAYER);
        token.approve(address(escrow), total);
        VM.prank(PAYER);
        return address(escrow).call(abi.encodeCall(SkewBaseComputeEscrowV1.fundJob, (terms)));
    }

    function _terms(bytes32 salt, uint128 worker, uint128 verifierAmount, uint128 protocol, uint64 ttl)
        private
        view
        returns (SkewBaseComputeEscrowV1.JobTerms memory)
    {
        return SkewBaseComputeEscrowV1.JobTerms({
            routeId: routeId,
            clientSalt: salt,
            taskSpecDigest: keccak256(abi.encode("task", salt)),
            quoteDigest: keccak256(abi.encode("quote", salt)),
            outcomeContractDigest: keccak256("outcome-contract/v1"),
            payer: PAYER,
            verifierFeeRecipient: VERIFIER_FEE,
            protocolFeeRecipient: PROTOCOL_FEE,
            workerPoolUsdc: worker,
            verifierFeeUsdc: verifierAmount,
            protocolFeeUsdc: protocol,
            refundAfter: uint64(block.timestamp) + ttl
        });
    }

    function _receipt(bytes32 jobId, SkewBaseComputeEscrowV1.JobTerms memory terms, bytes32 root)
        private
        view
        returns (ISkewComputeReceiptVerifierV1.Receipt memory)
    {
        return ISkewComputeReceiptVerifierV1.Receipt({
            jobId: jobId,
            taskSpecDigest: terms.taskSpecDigest,
            quoteDigest: terms.quoteDigest,
            outcomeContractDigest: terms.outcomeContractDigest,
            outputDigest: keccak256(abi.encode("output", jobId)),
            contributionRoot: root,
            contributionTotalUsdc: terms.workerPoolUsdc,
            contributionCount: 1,
            workerPoolUsdc: terms.workerPoolUsdc,
            verifierFeeUsdc: terms.verifierFeeUsdc,
            protocolFeeUsdc: terms.protocolFeeUsdc,
            validUntil: uint64(block.timestamp + 1 hours)
        });
    }

    function _sign(ISkewComputeReceiptVerifierV1.Receipt memory receipt) private returns (bytes[] memory signatures) {
        bytes32 digest = verifier.hashReceipt(receipt);
        signatures = new bytes[](2);
        signatures[0] = _signature(signerKeyA, digest);
        signatures[1] = _signature(signerKeyB, digest);
    }

    function _signature(uint256 privateKey, bytes32 digest) private returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = VM.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _highSSignature(uint256 privateKey, bytes32 digest) private returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = VM.sign(privateKey, digest);
        return abi.encodePacked(r, bytes32(SECP256K1N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
    }

    function _signatureWithV(uint256 privateKey, bytes32 digest, uint8 forcedV) private returns (bytes memory) {
        (, bytes32 r, bytes32 s) = VM.sign(privateKey, digest);
        return abi.encodePacked(r, s, forcedV);
    }

    function _leaf(bytes32 jobId, uint256 index, address recipient, uint128 amount, bytes32 workReceipt)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(CONTRIBUTION_TYPEHASH, jobId, index, recipient, amount, workReceipt));
    }

    function _singleRoot(bytes32 jobId, address recipient, uint128 amount, bytes32 workReceipt)
        private
        pure
        returns (bytes32 root)
    {
        (root,) = _singleTree(jobId, recipient, amount, workReceipt);
    }

    function _singleTree(bytes32 jobId, address recipient, uint128 amount, bytes32 workReceipt)
        private
        pure
        returns (bytes32 root, SkewBaseComputeEscrowV1.ContributionProofNode[] memory proof)
    {
        address[] memory recipients = new address[](1);
        recipients[0] = recipient;
        uint128[] memory amounts = new uint128[](1);
        amounts[0] = amount;
        bytes32[] memory workReceipts = new bytes32[](1);
        workReceipts[0] = workReceipt;
        SkewBaseComputeEscrowV1.ContributionProofNode[][] memory proofs;
        (root, proofs) = _tree(jobId, recipients, amounts, workReceipts);
        proof = proofs[0];
    }

    function _doubleTree(
        bytes32 jobId,
        address recipientA,
        uint128 amountA,
        bytes32 workReceiptA,
        address recipientB,
        uint128 amountB,
        bytes32 workReceiptB
    )
        private
        pure
        returns (
            bytes32 root,
            SkewBaseComputeEscrowV1.ContributionProofNode[] memory proofA,
            SkewBaseComputeEscrowV1.ContributionProofNode[] memory proofB
        )
    {
        address[] memory recipients = new address[](2);
        recipients[0] = recipientA;
        recipients[1] = recipientB;
        uint128[] memory amounts = new uint128[](2);
        amounts[0] = amountA;
        amounts[1] = amountB;
        bytes32[] memory workReceipts = new bytes32[](2);
        workReceipts[0] = workReceiptA;
        workReceipts[1] = workReceiptB;
        SkewBaseComputeEscrowV1.ContributionProofNode[][] memory proofs;
        (root, proofs) = _tree(jobId, recipients, amounts, workReceipts);
        proofA = proofs[0];
        proofB = proofs[1];
    }

    function _tree(bytes32 jobId, address[] memory recipients, uint128[] memory amounts, bytes32[] memory works)
        private
        pure
        returns (bytes32 root, SkewBaseComputeEscrowV1.ContributionProofNode[][] memory proofs)
    {
        uint256 itemCount = recipients.length;
        require(
            itemCount > 0 && itemCount <= 256 && amounts.length == itemCount && works.length == itemCount, "tree input"
        );
        proofs = new SkewBaseComputeEscrowV1.ContributionProofNode[][](itemCount);
        for (uint256 i; i < itemCount; ++i) {
            proofs[i] = new SkewBaseComputeEscrowV1.ContributionProofNode[](8);
        }
        TestContributionNode[] memory level = new TestContributionNode[](256);
        bytes32 emptyHash = keccak256(abi.encode(CONTRIBUTION_EMPTY_LEAF_TYPEHASH));
        for (uint256 i; i < 256; ++i) {
            if (i < itemCount) {
                bytes32 leaf = _leaf(jobId, i, recipients[i], amounts[i], works[i]);
                level[i] = TestContributionNode({
                    nodeHash: keccak256(abi.encode(CONTRIBUTION_LEAF_NODE_TYPEHASH, leaf, amounts[i], uint32(1))),
                    contributionTotalUsdc: amounts[i],
                    contributionCount: 1,
                    members: uint256(1) << i
                });
            } else {
                level[i] = TestContributionNode({
                    nodeHash: emptyHash, contributionTotalUsdc: 0, contributionCount: 0, members: 0
                });
            }
        }
        uint256 width = 256;
        for (uint256 depth; depth < 8; ++depth) {
            TestContributionNode[] memory next = new TestContributionNode[](width / 2);
            for (uint256 i; i < width; i += 2) {
                TestContributionNode memory left = level[i];
                TestContributionNode memory right = level[i + 1];
                for (uint256 member; member < itemCount; ++member) {
                    uint256 mask = uint256(1) << member;
                    if (left.members & mask != 0) {
                        proofs[member][depth] = _proofNode(right);
                    } else if (right.members & mask != 0) {
                        proofs[member][depth] = _proofNode(left);
                    }
                }
                next[i / 2] = _parent(left, right);
            }
            level = next;
            width /= 2;
        }
        root = level[0].nodeHash;
    }

    function _parent(TestContributionNode memory left, TestContributionNode memory right)
        private
        pure
        returns (TestContributionNode memory)
    {
        return TestContributionNode({
            nodeHash: keccak256(
                abi.encode(
                    CONTRIBUTION_NODE_TYPEHASH,
                    left.nodeHash,
                    left.contributionTotalUsdc,
                    left.contributionCount,
                    right.nodeHash,
                    right.contributionTotalUsdc,
                    right.contributionCount
                )
            ),
            contributionTotalUsdc: left.contributionTotalUsdc + right.contributionTotalUsdc,
            contributionCount: left.contributionCount + right.contributionCount,
            members: left.members | right.members
        });
    }

    function _proofNode(TestContributionNode memory node)
        private
        pure
        returns (SkewBaseComputeEscrowV1.ContributionProofNode memory)
    {
        return SkewBaseComputeEscrowV1.ContributionProofNode({
            nodeHash: node.nodeHash,
            contributionTotalUsdc: node.contributionTotalUsdc,
            contributionCount: node.contributionCount
        });
    }

    function _emptyProof() private pure returns (SkewBaseComputeEscrowV1.ContributionProofNode[] memory proof) {
        proof = new SkewBaseComputeEscrowV1.ContributionProofNode[](0);
    }

    function _claim(address recipient) private {
        VM.prank(recipient);
        escrow.claimUsdcCredit();
    }

    function _tryClaim(
        bytes32 jobId,
        uint256 index,
        address recipient,
        uint128 amount,
        bytes32 workReceipt,
        SkewBaseComputeEscrowV1.ContributionProofNode[] memory proof
    ) private returns (bool accepted) {
        (accepted,) = address(escrow)
            .call(
                abi.encodeCall(
                    SkewBaseComputeEscrowV1.claimContribution, (jobId, index, recipient, amount, workReceipt, proof)
                )
            );
    }
}
