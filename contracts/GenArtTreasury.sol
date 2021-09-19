// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./IGenArtInterface.sol";
import "./IGenArt.sol";

contract GenArtTreasury is Ownable {
    struct Partner {
        uint256 vestingAmount;
        uint256 claimedAmount;
        uint256 vestingBegin;
        uint256 vestingEnd;
    }

    using SafeMath for uint256;

    address genartToken;
    address genArtInterfaceAddress;
    address genArtMembershipAddress;
    uint256 vestingBegin;
    uint256 vestingEnd;

    // 100mm total token supply
    uint256 liqTokenAmount = 10_000_000 * 10**18; // 10mm
    uint256 treasuryTokenAmount = 37_000_000 * 10**18; // 37mm
    uint256 teamMemberTokenAmount = 3_750_000 * 10**18; // 4 team members: 15mm
    uint256 standardMemberTokenAmount = 4_000 * 10**18; // 5k members: 20mm
    uint256 goldMemberTokenAmount = 20_000 * 10**18; // 100 gold members: 2mm
    uint256 marketingTokenAmount = 6_000_000 * 10**18; // 6mm
    uint256 partnerTokenAmount = 10_000_000 * 10**18; // 10mm

    uint256 totalOwnerWithdrawAmount = 0; // total amount withdrawn by withdraw function
    uint256 spendPartnerTokens = 0;

    mapping(address => uint256) nonces;
    mapping(address => uint256) partnerClaims;
    mapping(address => uint256) teamClaimedAmount;
    mapping(uint256 => bool) membershipClaims;
    mapping(address => bool) teamMembers;
    mapping(address => Partner) partners;

    constructor(
        address genArtInterfaceAddress_,
        address genArtMembershipAddress_,
        uint256 vestingBegin_,
        uint256 vestingEnd_,
        address teamMember1_,
        address teamMember2_,
        address teamMember3_,
        address teamMember4_
    ) {
        require(
            vestingBegin_ >= block.timestamp,
            "GenArtTreasury: vesting begin too early"
        );
        require(
            vestingEnd_ > vestingBegin_,
            "GenArtTreasury: vesting end too early"
        );
        genArtMembershipAddress = genArtMembershipAddress_;
        genArtInterfaceAddress = genArtInterfaceAddress_;
        vestingBegin = vestingBegin_;
        vestingEnd = vestingEnd_;

        teamMembers[teamMember1_] = true;
        teamMembers[teamMember2_] = true;
        teamMembers[teamMember3_] = true;
        teamMembers[teamMember4_] = true;
    }

    function claimTokensAllMemberships() public {
        uint256[] memory memberships = IGenArt(genArtMembershipAddress)
            .getTokensByOwner(msg.sender);
        for (uint256 i = 0; i < memberships.length; i++) {
            claimTokensMembership(memberships[i]);
        }
    }

    function claimTokensMembership(uint256 membershipId_) public {
        if (!membershipClaims[membershipId_]) {
            address owner = IGenArt(genArtMembershipAddress).ownerOf(
                membershipId_
            );
            bool isGold = IGenArtInterface(genArtInterfaceAddress).isGoldToken(
                membershipId_
            );
            require(
                owner == msg.sender,
                "GenArtTreasury: only owner can claim tokens"
            );
            IERC20(genartToken).transfer(
                owner,
                (isGold ? goldMemberTokenAmount : standardMemberTokenAmount)
            );
            membershipClaims[membershipId_] = true;
        }
    }

    function withdraw(uint256 _amount, address _to) public onlyOwner {
        uint256 maxWithdrawAmount = liqTokenAmount +
            treasuryTokenAmount +
            marketingTokenAmount;
        uint256 newWithdrawAmount = _amount.add(totalOwnerWithdrawAmount);

        require(
            newWithdrawAmount <= maxWithdrawAmount,
            "GenArtTreasury: amount would excceed limit"
        );
        IERC20(genartToken).transfer(_to, _amount);
        totalOwnerWithdrawAmount = newWithdrawAmount;
    }

    function calcVestedAmount(
        uint256 startDate_,
        uint256 endDate_,
        uint256 amount_
    ) public view returns (uint256) {
        if (block.timestamp >= endDate_) {
            return amount_;
        }
        uint256 fractions = amount_.div(endDate_.sub(startDate_));
        return fractions.mul(block.timestamp.sub(startDate_));
    }

    function claimTokensTeamMember(address to_) public {
        address teamMember = msg.sender;

        require(
            teamMembers[teamMember],
            "GenArtTreasury: caller is not team member"
        );
        require(
            teamClaimedAmount[teamMember] < teamMemberTokenAmount,
            "GenArtTreasury: no tokens to claim"
        );
        uint256 vestedAmount = calcVestedAmount(
            vestingBegin,
            vestingEnd,
            teamMemberTokenAmount
        );

        uint256 payoutAmount = vestedAmount.sub(teamClaimedAmount[teamMember]);
        IERC20(genartToken).transfer(to_, payoutAmount);
        teamClaimedAmount[teamMember] = payoutAmount.add(
            teamClaimedAmount[teamMember]
        );
    }

    function claimTokensPartner(address to_) public {
        Partner memory partner = partners[msg.sender];
        require(
            block.number > nonces[msg.sender],
            "GenArtTreasury: another transaction in progress"
        );
        nonces[msg.sender] = block.number;
        require(
            partner.vestingAmount > 0,
            "GenArtTreasury: caller is not partner"
        );
        require(
            partner.claimedAmount < partner.vestingAmount,
            "GenArtTreasury: no tokens to claim"
        );
        uint256 vestedAmount = calcVestedAmount(
            partner.vestingBegin,
            partner.vestingEnd,
            partner.vestingAmount
        );
        uint256 payoutAmount = vestedAmount.sub(partner.claimedAmount);
        IERC20(genartToken).transfer(to_, payoutAmount);
        partners[msg.sender].claimedAmount = payoutAmount.add(
            partner.claimedAmount
        );
    }

    function addPartner(
        address wallet_,
        uint256 vestingBegin_,
        uint256 vestingEnd_,
        uint256 vestingAmount_
    ) public onlyOwner {
        require(
            partners[wallet_].vestingAmount == 0,
            "GenArtTreasury: partner already added"
        );
        require(spendPartnerTokens.add(vestingAmount_) <= partnerTokenAmount);
        partners[wallet_] = Partner({
            vestingBegin: vestingBegin_,
            vestingEnd: vestingEnd_,
            vestingAmount: vestingAmount_,
            claimedAmount: 0
        });

        spendPartnerTokens = spendPartnerTokens.add(vestingAmount_);
    }

    function updateGenArtInterfaceAddress(address newAddress_)
        public
        onlyOwner
    {
        genArtInterfaceAddress = newAddress_;
    }

    function updateGenArtTokenAddress(address newAddress_) public onlyOwner {
        genartToken = newAddress_;
    }
}
