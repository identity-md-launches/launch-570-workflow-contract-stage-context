// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PvPadConstants} from "./libraries/PvPadConstants.sol";

/// @notice ETH worker pot funded by launch fees, king bids, and donations; allocated via Merkle epochs.
/// @dev The explicit updater is trusted to select payees and amounts off-chain. Solidity never
/// queries the worker API. Epoch budgets are isolated; expired, unclaimed funds return to the pot.
contract WorkerSubsidy is ReentrancyGuard {
    error NotUpdater();
    error InvalidAddress();
    error InvalidWindow();
    error InvalidRoot();
    error EpochNotOpen();
    error EpochNotExpired();
    error InvalidProof();
    error AlreadyClaimed();
    error NothingToFund();
    error NoPendingUpdater();
    error TransferFailed();

    event Funded(address indexed from, uint256 amount);
    event EpochOpened(uint256 indexed epochId, bytes32 root, uint256 budget, uint256 windowStart, uint256 windowEnd);
    event WorkerClaimed(uint256 indexed epochId, address indexed payee, uint256 amount);
    event EpochRecycled(uint256 indexed epochId, uint256 amount);
    event UpdaterProposed(address indexed pending);
    event UpdaterAccepted(address indexed updater);

    address public updater;
    address public pendingUpdater;
    uint256 public workerPot;
    uint256 public reservedForEpochs;
    uint256 public currentEpoch;

    struct Epoch {
        bytes32 root;
        uint256 budget;
        uint256 paid;
        uint256 windowStart;
        uint256 windowEnd;
    }

    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(address => bool)) public claimed;
    mapping(uint256 => bool) public recycled;

    constructor(address initialUpdater) {
        if (initialUpdater == address(0)) revert InvalidAddress();
        updater = initialUpdater;
    }

    modifier onlyUpdater() {
        if (msg.sender != updater) revert NotUpdater();
        _;
    }

    receive() external payable {
        fundWorkers();
    }

    function fundWorkers() public payable {
        if (msg.value == 0) revert NothingToFund();
        workerPot += msg.value;
        emit Funded(msg.sender, msg.value);
    }

    function proposeUpdater(address newUpdater) external onlyUpdater {
        if (newUpdater == address(0)) revert InvalidAddress();
        pendingUpdater = newUpdater;
        emit UpdaterProposed(newUpdater);
    }

    function acceptUpdater() external {
        if (msg.sender != pendingUpdater) revert NoPendingUpdater();
        updater = pendingUpdater;
        pendingUpdater = address(0);
        emit UpdaterAccepted(updater);
    }

    /// @dev Compatible with OpenZeppelin StandardMerkleTree; sorted pairs, one leaf per payee/epoch.
    function leaf(uint256 epochId, address payee, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epochId, payee, amount))));
    }

    /// @dev The window may neither last nor start more than MAX_EPOCH_WINDOW ahead, so an epoch can
    /// delay the reserved pot by at most two windows before claims open or recycling is possible.
    function setEpoch(bytes32 root, uint256 windowStart, uint256 windowEnd) external onlyUpdater nonReentrant {
        if (root == bytes32(0)) revert InvalidRoot();
        if (
            windowStart < block.timestamp || windowStart - block.timestamp > PvPadConstants.MAX_EPOCH_WINDOW
                || windowEnd <= windowStart || windowEnd - windowStart > PvPadConstants.MAX_EPOCH_WINDOW
        ) revert InvalidWindow();
        uint256 budget = workerPot;
        if (budget == 0) revert NothingToFund();
        workerPot = 0;
        reservedForEpochs += budget;
        uint256 epochId = ++currentEpoch;
        epochs[epochId] = Epoch({root: root, budget: budget, paid: 0, windowStart: windowStart, windowEnd: windowEnd});
        emit EpochOpened(epochId, root, budget, windowStart, windowEnd);
    }

    /// @notice Anybody may submit a proof; ETH is paid only to the payee committed in the leaf.
    function claimWorker(uint256 epochId, address payee, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        Epoch storage e = epochs[epochId];
        if (
            e.root == bytes32(0) || recycled[epochId] || block.timestamp < e.windowStart
                || block.timestamp > e.windowEnd
        ) revert EpochNotOpen();
        if (payee == address(0)) revert InvalidAddress();
        if (claimed[epochId][payee]) revert AlreadyClaimed();
        if (amount == 0 || amount > e.budget - e.paid) revert InvalidProof();
        if (!MerkleProof.verifyCalldata(proof, e.root, leaf(epochId, payee, amount))) revert InvalidProof();
        claimed[epochId][payee] = true;
        e.paid += amount;
        reservedForEpochs -= amount;
        (bool ok,) = payee.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit WorkerClaimed(epochId, payee, amount);
    }

    /// @notice Return expired allocations to the pot; never redirects funds to the caller/updater.
    function recycleExpiredEpoch(uint256 epochId) external nonReentrant returns (uint256 amount) {
        Epoch storage e = epochs[epochId];
        if (e.root == bytes32(0) || recycled[epochId] || block.timestamp <= e.windowEnd) {
            revert EpochNotExpired();
        }
        recycled[epochId] = true;
        amount = e.budget - e.paid;
        reservedForEpochs -= amount;
        workerPot += amount;
        emit EpochRecycled(epochId, amount);
    }
}
