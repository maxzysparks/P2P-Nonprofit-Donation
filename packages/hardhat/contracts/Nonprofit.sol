// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/SignatureChecker.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract P2PNonprofitDonation is 
    Initializable, 
    PausableUpgradeable, 
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable 
{
    using Counters for Counters.Counter;

    // Custom errors
    error InvalidAmount();
    error InvalidAddress();
    error InvalidDeadline();
    error InvalidPercentage();
    error UnauthorizedAccess();
    error DonationNotActive();
    error DeadlinePassed();
    error InsufficientFunds();
    error TransferFailed();
    error InvalidRating();
    error AlreadyRated();
    error EmptyString();
    error ZeroValue();

    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant NONPROFIT_ROLE = keccak256("NONPROFIT_ROLE");
    bytes32 public constant DONOR_ROLE = keccak256("DONOR_ROLE");

    // State variables
    uint256 public constant MIN_DONATION_AMOUNT = 0.1 ether;
    uint256 public constant MAX_DONATION_AMOUNT = 10 ether;
    uint8 public constant MIN_EQUITY_PERCENTAGE = 1;
    uint8 public constant MAX_EQUITY_PERCENTAGE = 10;
    uint256 public constant FUNDING_PERIOD = 30 days;
    uint256 public constant MAX_EXTENSION_PERIOD = 90 days;
    
    Counters.Counter private _donationIds;
    
    // Packed structs for gas optimization
    struct Donation {
        address payable donor;          // 20 bytes
        address payable nonprofit;      // 20 bytes
        uint96 amount;                  // 12 bytes
        uint32 fundingDeadline;        // 4 bytes
        uint8 equityPercentage;        // 1 byte
        bool active;                    // 1 byte
        bool distributed;               // 1 byte
        string nonprofitName;          // 32 bytes (reference)
        string description;            // 32 bytes (reference)
        uint256 valuation;            // 32 bytes
    }

    struct UserReputation {
        uint8 rating;                  // 1 byte
        uint32 lastUpdated;           // 4 bytes
        uint16 totalRatings;          // 2 bytes
        string review;                // 32 bytes (reference)
    }

    // Mappings
    mapping(uint256 => Donation) private _donations;
    mapping(uint256 => uint256) private _escrowBalances;
    mapping(address => UserReputation) private _donorReputations;
    mapping(address => UserReputation) private _nonprofitReputations;
    mapping(address => uint256) private _userDonationCount;
    mapping(address => mapping(uint256 => bool)) private _hasRated;

    // Events
    event DonationCreated(
        uint256 indexed donationId,
        address indexed donor,
        uint256 amount,
        uint8 equityPercentage,
        uint32 fundingDeadline,
        string nonprofitName
    );

    event DonationFunded(
        uint256 indexed donationId,
        address indexed nonprofit,
        uint256 amount
    );

    event DonationDistributed(
        uint256 indexed donationId,
        address indexed nonprofit,
        uint256 amount
    );

    event ReputationUpdated(
        address indexed user,
        address indexed rater,
        uint8 rating,
        string review
    );

    event FundingPeriodExtended(
        uint256 indexed donationId,
        uint32 newDeadline
    );

    event DonationCancelled(
        uint256 indexed donationId,
        address indexed donor,
        uint256 amount
    );

    event EmergencyWithdrawal(
        address indexed admin,
        uint256 amount,
        uint256 timestamp
    );

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        if (admin == address(0)) revert InvalidAddress();

        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(ADMIN_ROLE, admin);
    }

    // Modifiers
    modifier validAmount(uint256 amount) {
        if (amount < MIN_DONATION_AMOUNT || amount > MAX_DONATION_AMOUNT) 
            revert InvalidAmount();
        _;
    }

    modifier validAddress(address addr) {
        if (addr == address(0)) revert InvalidAddress();
        _;
    }

    modifier onlyActiveDonation(uint256 donationId) {
        if (!_donations[donationId].active) revert DonationNotActive();
        _;
    }

    modifier withinDeadline(uint256 donationId) {
        if (block.timestamp > _donations[donationId].fundingDeadline) 
            revert DeadlinePassed();
        _;
    }

    function createDonation(
        uint256 amount,
        uint8 equityPercentage,
        string calldata nonprofitName,
        string calldata description,
        uint256 valuation
    ) 
        external 
        payable
        whenNotPaused
        nonReentrant
        validAmount(amount)
        returns (uint256 donationId)
    {
        if (equityPercentage < MIN_EQUITY_PERCENTAGE || 
            equityPercentage > MAX_EQUITY_PERCENTAGE) revert InvalidPercentage();
        if (bytes(nonprofitName).length == 0) revert EmptyString();
        if (bytes(description).length == 0) revert EmptyString();
        if (valuation == 0) revert ZeroValue();

        donationId = _donationIds.current();
        uint32 deadline = uint32(block.timestamp + FUNDING_PERIOD);

        Donation storage donation = _donations[donationId];
        donation.donor = payable(msg.sender);
        donation.amount = uint96(amount);
        donation.equityPercentage = equityPercentage;
        donation.fundingDeadline = deadline;
        donation.nonprofitName = nonprofitName;
        donation.description = description;
        donation.valuation = valuation;
        donation.active = true;

        _grantRole(DONOR_ROLE, msg.sender);
        _userDonationCount[msg.sender]++;
        _donationIds.increment();

        emit DonationCreated(
            donationId,
            msg.sender,
            amount,
            equityPercentage,
            deadline,
            nonprofitName
        );

        return donationId;
    }

    function fundDonation(uint256 donationId) 
        external 
        payable
        whenNotPaused
        nonReentrant
        onlyActiveDonation(donationId)
        withinDeadline(donationId)
    {
        Donation storage donation = _donations[donationId];
        if (msg.sender == donation.donor) revert UnauthorizedAccess();
        if (msg.value != donation.amount) revert InvalidAmount();

        donation.nonprofit = payable(msg.sender);
        donation.active = false;
        _escrowBalances[donationId] = msg.value;
        
        _grantRole(NONPROFIT_ROLE, msg.sender);

        emit DonationFunded(donationId, msg.sender, msg.value);
    }

    function distributeDonation(uint256 donationId)
        external
        whenNotPaused
        nonReentrant
    {
        Donation storage donation = _donations[donationId];
        if (msg.sender != donation.donor) revert UnauthorizedAccess();
        if (donation.distributed) revert UnauthorizedAccess();

        uint256 amount = _escrowBalances[donationId];
        if (amount == 0) revert InsufficientFunds();

        _escrowBalances[donationId] = 0;
        donation.distributed = true;

        (bool success, ) = donation.nonprofit.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit DonationDistributed(donationId, donation.nonprofit, amount);
    }

    function updateReputation(
        address user,
        uint8 rating,
        string calldata review
    )
        external
        whenNotPaused
        validAddress(user)
    {
        if (rating < 1 || rating > 5) revert InvalidRating();
        if (_hasRated[msg.sender][_userDonationCount[user]]) 
            revert AlreadyRated();
        if (bytes(review).length == 0) revert EmptyString();

        UserReputation storage reputation = hasRole(NONPROFIT_ROLE, user) 
            ? _nonprofitReputations[user]
            : _donorReputations[user];

        reputation.rating = uint8(
            (reputation.rating * reputation.totalRatings + rating) / 
            (reputation.totalRatings + 1)
        );
        reputation.totalRatings++;
        reputation.lastUpdated = uint32(block.timestamp);
        reputation.review = review;

        _hasRated[msg.sender][_userDonationCount[user]] = true;

        emit ReputationUpdated(user, msg.sender, rating, review);
    }

    function extendFundingPeriod(
        uint256 donationId,
        uint32 extensionDays
    )
        external
        whenNotPaused
        onlyActiveDonation(donationId)
        withinDeadline(donationId)
    {
        Donation storage donation = _donations[donationId];
        if (msg.sender != donation.donor) revert UnauthorizedAccess();
        if (extensionDays == 0) revert ZeroValue();

        uint32 extension = uint32(extensionDays * 1 days);
        if (extension > MAX_EXTENSION_PERIOD) revert InvalidDeadline();

        uint32 newDeadline = donation.fundingDeadline + extension;
        donation.fundingDeadline = newDeadline;

        emit FundingPeriodExtended(donationId, newDeadline);
    }

    function cancelDonation(uint256 donationId)
        external
        whenNotPaused
        nonReentrant
        onlyActiveDonation(donationId)
    {
        Donation storage donation = _donations[donationId];
        if (msg.sender != donation.donor) revert UnauthorizedAccess();

        donation.active = false;
        uint256 amount = _escrowBalances[donationId];
        if (amount > 0) {
            _escrowBalances[donationId] = 0;
            (bool success, ) = donation.donor.call{value: amount}("");
            if (!success) revert TransferFailed();
        }

        emit DonationCancelled(donationId, msg.sender, amount);
    }

    function emergencyWithdraw() 
        external 
        onlyRole(ADMIN_ROLE) 
        nonReentrant 
    {
        uint256 balance = address(this).balance;
        if (balance == 0) revert InsufficientFunds();

        (bool success, ) = msg.sender.call{value: balance}("");
        if (!success) revert TransferFailed();

        emit EmergencyWithdrawal(msg.sender, balance, block.timestamp);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function getDonation(uint256 donationId)
        external
        view
        returns (Donation memory)
    {
        return _donations[donationId];
    }

    function getReputation(address user)
        external
        view
        validAddress(user)
        returns (UserReputation memory)
    {
        return hasRole(NONPROFIT_ROLE, user)
            ? _nonprofitReputations[user]
            : _donorReputations[user];
    }

    function getDonationCount() external view returns (uint256) {
        return _donationIds.current();
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(ADMIN_ROLE)
    {}

    receive() external payable {
        emit EmergencyWithdrawal(msg.sender, msg.value, block.timestamp);
    }
}