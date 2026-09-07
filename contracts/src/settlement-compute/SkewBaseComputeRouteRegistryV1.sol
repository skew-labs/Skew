// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { ISkewComputeRouteRegistryV1 } from "./ISkewComputeSettlementV1.sol";

/// @notice Append-only verifier routes for Base compute settlement.
/// @dev A route can be disabled permanently, but never edited or re-enabled.
contract SkewBaseComputeRouteRegistryV1 is ISkewComputeRouteRegistryV1 {
    uint256 public constant BASE_MAINNET_CHAIN_ID = 8453;
    bytes32 public constant ROUTE_TYPEHASH = keccak256(
        "SkewComputeRouteV1(uint256 chainId,address registry,bytes32 routeSalt,address verifier,bytes32 verifierCodeHash,uint16 maxProtocolFeeBps,uint16 maxVerifierFeeBps)"
    );
    uint256 private constant MAX_BPS = 10_000;

    address public immutable routeOwner;
    address public immutable pauseGuardian;
    mapping(bytes32 routeId => Route routeConfig) private _routes;

    error WrongChain(uint256 actual);
    error InvalidDeployment();
    error Unauthorized();
    error InvalidRoute();
    error DuplicateRoute(bytes32 routeId);
    error RouteAlreadyDisabled(bytes32 routeId);

    event RouteRegistered(
        bytes32 indexed routeId,
        address indexed verifier,
        bytes32 indexed verifierCodeHash,
        uint16 maxProtocolFeeBps,
        uint16 maxVerifierFeeBps
    );
    event RouteDisabled(bytes32 indexed routeId);

    modifier onlyPinnedChain() {
        if (block.chainid != BASE_MAINNET_CHAIN_ID) revert WrongChain(block.chainid);
        _;
    }

    constructor(address routeOwner_, address pauseGuardian_) {
        if (block.chainid != BASE_MAINNET_CHAIN_ID) revert WrongChain(block.chainid);
        if (routeOwner_.code.length == 0 || pauseGuardian_.code.length == 0 || routeOwner_ == pauseGuardian_) {
            revert InvalidDeployment();
        }
        routeOwner = routeOwner_;
        pauseGuardian = pauseGuardian_;
    }

    function registerRoute(
        bytes32 routeSalt,
        address verifier,
        bytes32 verifierCodeHash,
        uint16 maxProtocolFeeBps,
        uint16 maxVerifierFeeBps
    ) external onlyPinnedChain returns (bytes32 routeId) {
        if (msg.sender != routeOwner) revert Unauthorized();
        if (
            routeSalt == bytes32(0) || verifier.code.length == 0 || verifier.codehash != verifierCodeHash
                || maxProtocolFeeBps > MAX_BPS || maxVerifierFeeBps > MAX_BPS
                || uint256(maxProtocolFeeBps) + uint256(maxVerifierFeeBps) > MAX_BPS
        ) revert InvalidRoute();
        routeId = keccak256(
            abi.encode(
                ROUTE_TYPEHASH,
                BASE_MAINNET_CHAIN_ID,
                address(this),
                routeSalt,
                verifier,
                verifierCodeHash,
                maxProtocolFeeBps,
                maxVerifierFeeBps
            )
        );
        if (_routes[routeId].verifier != address(0)) revert DuplicateRoute(routeId);
        _routes[routeId] = Route({
            verifier: verifier,
            verifierCodeHash: verifierCodeHash,
            maxProtocolFeeBps: maxProtocolFeeBps,
            maxVerifierFeeBps: maxVerifierFeeBps,
            enabled: true
        });
        emit RouteRegistered(routeId, verifier, verifierCodeHash, maxProtocolFeeBps, maxVerifierFeeBps);
    }

    function disableRoute(bytes32 routeId) external onlyPinnedChain {
        if (msg.sender != pauseGuardian) revert Unauthorized();
        Route storage routeConfig = _routes[routeId];
        if (routeConfig.verifier == address(0)) revert InvalidRoute();
        if (!routeConfig.enabled) revert RouteAlreadyDisabled(routeId);
        routeConfig.enabled = false;
        emit RouteDisabled(routeId);
    }

    function route(bytes32 routeId) external view returns (Route memory) {
        return _routes[routeId];
    }
}
