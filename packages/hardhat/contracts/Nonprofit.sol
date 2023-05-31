// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0 <0.9.0;

contract P2PNonprofitDonation {
    // The minimum and maximum amount of ETH that can be donated
    uint public constant MIN_DONATION_AMOUNT = 0.1 ether;
    uint public constant MAX_DONATION_AMOUNT = 10 ether;
    // The minimum and maximum equity percentage that can be offered for a donation
    uint public constant MIN_EQUITY_PERCENTAGE = 1;
    uint public constant MAX_EQUITY_PERCENTAGE = 10;

    struct Donation {
        uint amount;
        uint equityPercentage;
        uint fundingDeadline;
        string nonprofitName;
        string description;
        uint valuation;
        address payable donor;
        address payable nonprofit;
        bool active;
        bool distributed;
    }

    struct Reputation {
        uint rating;
        string review;
    }
    mapping(address => Reputation) public donorReputations;
    mapping(address => Reputation) public nonprofitReputations;
    mapping(address => bool) public registeredUsers;
    mapping(address => bytes32) private userPasswords;
    mapping(uint => Donation) public donations;
    uint public donationCount;

    event DonationCreated(
        uint donationId,
        uint amount,
        uint equityPercentage,
        uint fundingDeadline,
        string nonprofitName,
        string description,
        uint valuation,
        address donor,
        address nonprofit
    );

    event DonationFunded(uint donationId, address funder, uint amount);
    event DonationDistributed(uint donationId, uint amount);
    event UserRegistered(address user);
    event UserLoggedIn(address user);

    modifier onlyRegisteredUser() {
        require(registeredUsers[msg.sender], "User is not registered");
        _;
    }

    modifier onlyActiveDonation(uint _donationId) {
        require(donations[_donationId].active, "Donation is not active");
        _;
    }

    modifier onlyDonor(uint _donationId) {
        require(
            msg.sender == donations[_donationId].donor,
            "Only the donor can perform this action"
        );
        _;
    }

    function registerUser(bytes32 _password) external {
        require(!registeredUsers[msg.sender], "User is already registered");
        require(_password != "", "Password cannot be empty");

        registeredUsers[msg.sender] = true;
        userPasswords[msg.sender] = _password;

        emit UserRegistered(msg.sender);
    }

    function login(bytes32 _password) external {
        require(registeredUsers[msg.sender], "User is not registered");
        require(userPasswords[msg.sender] == _password, "Invalid password");

        emit UserLoggedIn(msg.sender);
    }

    function rateDonor(
        address _donor,
        uint _rating,
        string memory _review
    ) external onlyRegisteredUser {
        require(_rating >= 1 && _rating <= 5, "Rating must be between 1 and 5");

        donorReputations[_donor].rating = _rating;
        donorReputations[_donor].review = _review;
    }

    function rateNonprofit(
        address _nonprofit,
        uint _rating,
        string memory _review
    ) external onlyRegisteredUser {
        require(_rating >= 1 && _rating <= 5, "Rating must be between 1 and 5");

        nonprofitReputations[_nonprofit].rating = _rating;
        nonprofitReputations[_nonprofit].review = _review;
    }

    function createDonation(
        uint _amount,
        uint _equityPercentage,
        string memory _nonprofitName,
        string memory _description,
        uint _valuation
    ) external payable {
        require(
            _amount >= MIN_DONATION_AMOUNT && _amount <= MAX_DONATION_AMOUNT,
            "Donation amount must be between MIN_DONATION_AMOUNT and MAX_DONATION_AMOUNT"
        );
        require(
            _equityPercentage >= MIN_EQUITY_PERCENTAGE &&
                _equityPercentage <= MAX_EQUITY_PERCENTAGE,
            "Equity percentage must be between MIN_EQUITY_PERCENTAGE and MAX_EQUITY_PERCENTAGE"
        );
        require(
            bytes(_nonprofitName).length > 0,
            "Nonprofit name cannot be empty"
        );
        require(bytes(_description).length > 0, "Description cannot be empty");
        require(_valuation > 0, "Nonprofit valuation must be greater than 0");

        uint _fundingDeadline = block.timestamp + (1 days);
        uint donationId = donationCount++;

        Donation storage donation = donations[donationId];
        donation.amount = _amount;
        donation.equityPercentage = _equityPercentage;
        donation.fundingDeadline = _fundingDeadline;
        donation.nonprofitName = _nonprofitName;
        donation.description = _description;
        donation.valuation = _valuation;
        donation.donor = payable(msg.sender);
        donation.nonprofit = payable(address(0));
        donation.active = true;
        donation.distributed = false;

        emit DonationCreated(
            donationId,
            _amount,
            _equityPercentage,
            _fundingDeadline,
            _nonprofitName,
            _description,
            _valuation,
            msg.sender,
            address(0)
        );
    }

    function fundDonation(
        uint _donationId
    ) external payable onlyActiveDonation(_donationId) {
        Donation storage donation = donations[_donationId];
        require(
            msg.sender != donation.donor,
            "Donor cannot fund their own donation"
        );
        require(donation.amount == msg.value, "Incorrect donation amount");
        require(
            block.timestamp <= donation.fundingDeadline,
            "Donation funding deadline has passed"
        );
        payable(address(this)).transfer(msg.value);
        donation.nonprofit = payable(msg.sender);
        donation.active = false;

        emit DonationFunded(_donationId, msg.sender, msg.value);
    }

    function distributeDonation(
        uint _donationId
    ) external payable onlyActiveDonation(_donationId) onlyDonor(_donationId) {
        Donation storage donation = donations[_donationId];
        require(msg.value == donation.amount, "Incorrect distribution amount");
        donation.nonprofit.transfer(msg.value);
        donation.distributed = true;
        donation.active = false;

        emit DonationDistributed(_donationId, msg.value);
    }

    function extendFundingPeriod(
        uint _donationId,
        uint _extensionDays
    ) external onlyDonor(_donationId) onlyActiveDonation(_donationId) {
        Donation storage donation = donations[_donationId];
        require(_extensionDays > 0, "Extension days must be greater than 0");

        donation.fundingDeadline += (_extensionDays * 1 days);
    }

    function cancelDonation(
        uint _donationId
    ) external onlyDonor(_donationId) onlyActiveDonation(_donationId) {
        Donation storage donation = donations[_donationId];
        require(
            block.timestamp < donation.fundingDeadline,
            "Donation funding deadline has passed"
        );

        donation.active = false;

        // Return the donation amount to the donor
        payable(donation.donor).transfer(donation.amount);
    }

    function getDonationInfo(
        uint _donationId
    )
        external
        view
        returns (
            uint amount,
            uint equityPercentage,
            uint fundingDeadline,
            string memory nonprofitName,
            string memory description,
            uint valuation,
            address donor,
            address nonprofit,
            bool active,
            bool distributed
        )
    {
        Donation storage donation = donations[_donationId];
        return (
            donation.amount,
            donation.equityPercentage,
            donation.fundingDeadline,
            donation.nonprofitName,
            donation.description,
            donation.valuation,
            donation.donor,
            donation.nonprofit,
            donation.active,
            donation.distributed
        );
    }

    function withdrawDonation(
        uint _donationId
    ) external onlyDonor(_donationId) {
        Donation storage donation = donations[_donationId];
        require(!donation.active);
        payable(msg.sender).transfer(donation.amount);
    }
}
