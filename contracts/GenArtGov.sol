// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/Timers.sol";
import "@openzeppelin/contracts/governance/IGovernor.sol";
import "@openzeppelin/contracts/governance/extensions/IGovernorTimelock.sol";

interface ITimelock {
    receive() external payable;

    function GRACE_PERIOD() external view returns (uint256);

    function MINIMUM_DELAY() external view returns (uint256);

    function MAXIMUM_DELAY() external view returns (uint256);

    function delay() external view returns (uint256);

    function queuedTransactions(bytes32) external view returns (bool);

    function setDelay(uint256) external;

    function acceptAdmin() external;

    function queueTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) external returns (bytes32);

    function cancelTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) external;

    function executeTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) external payable returns (bytes memory);
}

interface IGenArtToken {
    function getPriorVotes(address account, uint32 blockNumber)
        external
        view
        returns (uint96);
}

interface IGenArt {
    function getTokensByOwner(address owner)
        external
        view
        returns (uint256[] memory);

    function ownerOf(uint256 tokenId) external view returns (address);

    function isGoldToken(uint256 _tokenId) external view returns (bool);
}

/**
 * @dev Gen.Art Governance Contract
 */
abstract contract GenArtGov is
    Context,
    ERC165,
    EIP712,
    IGovernor,
    IGovernorTimelock
{
    using SafeCast for uint256;
    using Timers for Timers.BlockNumber;
    using Timers for Timers.Timestamp;

    bytes32 public constant BALLOT_TYPEHASH =
        keccak256("Ballot(uint256 proposalId,uint8 support)");

    enum VoteType {
        Against,
        For,
        Abstain
    }

    struct Proposal {
        Timers.BlockNumber voteStart;
        Timers.BlockNumber voteEnd;
        Timers.Timestamp timer;
        uint256 againstVotes;
        uint256 forVotes;
        uint256 abstainVotes;
        address proposer;
        bool executed;
        bool canceled;
        mapping(address => bool) hasVoted;
    }

    string private _name = "Gen.Art Governance";

    ITimelock private _timelock;
    IGenArtToken private _token;
    IGenArt private _membership;

    /**
     * @dev Emitted when the timelock controller used for proposal execution is modified.
     */
    event TimelockChange(address oldTimelock, address newTimelock);

    mapping(uint256 => Proposal) private _proposals;

    /**
     * @dev Restrict access to governor executing address. Some module might override the _executor function to make
     * sure this modifier is consistant with the execution model.
     */
    modifier onlyGovernance() {
        require(_msgSender() == _executor(), "GenArtGov: onlyGovernance");
        _;
    }

    /**
     * @dev Sets the value for {name} and {version}
     */
    constructor(
        address token_,
        address timelockAddress_,
        address membership_
    ) EIP712(_name, version()) {
        _updateTimelock(timelockAddress_);
        _updateToken(token_);
        _membership = IGenArt(membership_);
    }

    /**
     * @dev Function to receive ETH that will be handled by the governor (disabled if executor is a third party contract)
     */
    receive() external payable virtual {}

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(IERC165, ERC165)
        returns (bool)
    {
        return
            interfaceId == type(IGovernorTimelock).interfaceId ||
            interfaceId == type(IGovernor).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /**
     * @dev See {IGovernor-COUNTING_MODE}.
     */
    function COUNTING_MODE()
        public
        pure
        virtual
        override
        returns (string memory)
    {
        return "support=bravo&quorum=for,abstain";
    }

    /**
     * @dev See {IGovernor-name}.
     */
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    /**
     * @dev See {IGovernor-version}.
     */
    function version() public view virtual override returns (string memory) {
        return "1";
    }

    /**
     * @dev See {IGovernor-hashProposal}.
     *
     * The proposal id is produced by hashing the RLC encoded `targets` array, the `values` array, the `calldatas` array
     * and the descriptionHash (bytes32 which itself is the keccak256 hash of the description string). This proposal id
     * can be produced from the proposal data which is part of the {ProposalCreated} event. It can even be computed in
     * advance, before the proposal is submitted.
     *
     * Note that the chainId and the governor address are not part of the proposal id computation. Consequently, the
     * same proposal (with same operation and same description) will have the same id if submitted on multiple governors
     * accross multiple networks. This also means that in order to execute the same operation twice (on the same
     * governor) the proposer will have to change the description in order to avoid proposal id conflicts.
     */
    function hashProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public pure virtual override returns (uint256) {
        return
            uint256(
                keccak256(
                    abi.encode(targets, values, calldatas, descriptionHash)
                )
            );
    }

    /**
     * @dev See {IGovernor-state}.
     */
    function state(uint256 proposalId)
        public
        view
        virtual
        override
        returns (ProposalState)
    {
        Proposal storage proposal = _proposals[proposalId];
        ProposalState status;
        if (proposal.executed) {
            status = ProposalState.Executed;
        } else if (proposal.canceled) {
            status = ProposalState.Canceled;
        } else if (proposal.voteStart.getDeadline() >= block.number) {
            status = ProposalState.Pending;
        } else if (proposal.voteEnd.getDeadline() >= block.number) {
            status = ProposalState.Active;
        } else if (proposal.voteEnd.isExpired()) {
            status = _quorumReached(proposalId) && _voteSucceeded(proposalId)
                ? ProposalState.Succeeded
                : ProposalState.Defeated;
        } else {
            revert("GenArtGov: unknown proposal id");
        }
        if (status != ProposalState.Succeeded) {
            return status;
        }
        uint256 eta = proposalEta(proposalId);
        if (eta == 0) {
            return status;
        } else if (block.timestamp >= eta + _timelock.GRACE_PERIOD()) {
            return ProposalState.Expired;
        } else {
            return ProposalState.Queued;
        }
    }

    /**
     * @dev See {IGovernor-proposalSnapshot}.
     */
    function proposalSnapshot(uint256 proposalId)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return _proposals[proposalId].voteStart.getDeadline();
    }

    /**
     * @dev See {IGovernor-proposalDeadline}.
     */
    function proposalDeadline(uint256 proposalId)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return _proposals[proposalId].voteEnd.getDeadline();
    }

    /**
     * @dev Part of the Governor Bravo's interface: _"The number of votes required in order for a voter to become a proposer"_.
     */
    function proposalThreshold() public view virtual returns (uint256) {
        return 500_000e18; //0.5% GENART
    }

    /**
     * @dev The delay before voting on a proposal may take place, once proposed
     */
    function votingDelay() public pure override returns (uint256) {
        return 1;
    } // 1 block

    /**
     * @dev The duration of voting on a proposal, in blocks
     */
    function votingPeriod() public pure override returns (uint256) {
        return 40_320;
    } // ~7 days in blocks (assuming 15s blocks)

    /**
     * @dev Amount of votes already cast passes the threshold limit.
     */
    function _quorumReached(uint256 proposalId)
        internal
        view
        virtual
        returns (bool)
    {
        Proposal storage proposalvote = _proposals[proposalId];

        return
            proposalvote.forVotes + proposalvote.abstainVotes >= 4_000_000e18; //4% GENART
    }

    /**
     * @dev Is the proposal successful or not.
     */
    function _voteSucceeded(uint256 proposalId)
        internal
        view
        virtual
        returns (bool)
    {
        Proposal storage proposalvote = _proposals[proposalId];

        return proposalvote.forVotes > proposalvote.againstVotes;
    }

    /**
     * @dev Register a vote with a given support and voting weight.
     *
     * Note: Support is generic and can represent various things depending on the voting system used.
     */
    function _countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 weight
    ) internal virtual {
        Proposal storage proposalvote = _proposals[proposalId];

        require(
            !proposalvote.hasVoted[account],
            "GenArtGov: vote already cast"
        );
        proposalvote.hasVoted[account] = true;

        if (support == uint8(VoteType.Against)) {
            proposalvote.againstVotes += weight;
        } else if (support == uint8(VoteType.For)) {
            proposalvote.forVotes += weight;
        } else if (support == uint8(VoteType.Abstain)) {
            proposalvote.abstainVotes += weight;
        } else {
            revert("GenArtGov: invalid value for enum VoteType");
        }
    }

    /**
     * @dev See {IGovernor-propose}.
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public virtual override returns (uint256) {
        (bool member, ) = isMember(msg.sender);
        require(member, "GenArtGov: Caller not Gen.Art member");
        require(
            getVotes(msg.sender, block.number - 1) >= proposalThreshold(),
            "GenArtGov: proposer votes below proposal threshold"
        );

        uint256 proposalId = hashProposal(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );

        require(
            targets.length == values.length,
            "GenArtGov: invalid proposal length"
        );
        require(
            targets.length == calldatas.length,
            "GenArtGov: invalid proposal length"
        );

        Proposal storage proposal = _proposals[proposalId];

        proposal.proposer = msg.sender;

        require(
            proposal.voteStart.isUnset(),
            "GenArtGov: proposal already exists"
        );

        uint64 snapshot = block.number.toUint64() + votingDelay().toUint64();
        uint64 deadline = snapshot + votingPeriod().toUint64();

        proposal.voteStart.setDeadline(snapshot);
        proposal.voteEnd.setDeadline(deadline);

        emit ProposalCreated(
            proposalId,
            _msgSender(),
            targets,
            values,
            new string[](targets.length),
            calldatas,
            snapshot,
            deadline,
            description
        );

        return proposalId;
    }

    /**
     * @dev Function to queue a proposal to the timelock.
     */
    function queue(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public virtual override returns (uint256) {
        uint256 proposalId = hashProposal(
            targets,
            values,
            calldatas,
            descriptionHash
        );

        require(
            state(proposalId) == ProposalState.Succeeded,
            "GenArtGov: proposal not successful"
        );

        uint256 eta = block.timestamp + _timelock.delay();
        _proposals[proposalId].timer.setDeadline(eta.toUint64());
        for (uint256 i = 0; i < targets.length; ++i) {
            require(
                !_timelock.queuedTransactions(
                    keccak256(
                        abi.encode(targets[i], values[i], "", calldatas[i], eta)
                    )
                ),
                "GenArtGov: identical proposal action already queued"
            );
            _timelock.queueTransaction(
                targets[i],
                values[i],
                "",
                calldatas[i],
                eta
            );
        }

        emit ProposalQueued(proposalId, eta);

        return proposalId;
    }

    /**
     * @dev See {IGovernor-execute}.
     */
    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable virtual override returns (uint256) {
        uint256 proposalId = hashProposal(
            targets,
            values,
            calldatas,
            descriptionHash
        );

        ProposalState status = state(proposalId);
        require(
            status == ProposalState.Succeeded || status == ProposalState.Queued,
            "GenArtGov: proposal not successful"
        );
        _proposals[proposalId].executed = true;

        emit ProposalExecuted(proposalId);

        _execute(proposalId, targets, values, calldatas, descriptionHash);

        return proposalId;
    }

    /**
     * @dev Internal execution mechanism. Can be overriden to implement different execution mechanism
     */
    function _execute(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32
    ) internal virtual {
        uint256 eta = proposalEta(proposalId);
        require(eta > 0, "GenArtGov: proposal not yet queued");
        Address.sendValue(payable(_timelock), msg.value);
        for (uint256 i = 0; i < targets.length; ++i) {
            _timelock.executeTransaction(
                targets[i],
                values[i],
                "",
                calldatas[i],
                eta
            );
        }
    }

    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public {
        uint256 proposalId = hashProposal(
            targets,
            values,
            calldatas,
            descriptionHash
        );
        Proposal storage proposal = _proposals[proposalId];
        require(
            getVotes(proposal.proposer, block.number - 1) < proposalThreshold(),
            "GenArtGov: proposer above threshold"
        );
        _cancel(proposalId, targets, values, calldatas, descriptionHash);
    }

    /**
     * @dev Internal cancel mechanism: locks up the proposal timer, preventing it from being re-submitted. Marks it as
     * canceled to allow distinguishing it from executed proposals.
     *
     * Emits a {IGovernor-ProposalCanceled} event.
     */
    function _cancel(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 /*descriptionHash*/
    ) internal virtual returns (uint256) {
        ProposalState status = state(proposalId);

        require(
            status != ProposalState.Canceled &&
                status != ProposalState.Expired &&
                status != ProposalState.Executed,
            "GenArtGov: proposal not active"
        );
        _proposals[proposalId].canceled = true;

        emit ProposalCanceled(proposalId);

        uint256 eta = proposalEta(proposalId);
        if (eta > 0) {
            for (uint256 i = 0; i < targets.length; ++i) {
                _timelock.cancelTransaction(
                    targets[i],
                    values[i],
                    "",
                    calldatas[i],
                    eta
                );
            }
            _proposals[proposalId].timer.reset();
        }

        return proposalId;
    }

    /**
     * @dev See {IGovernor-castVote}.
     */
    function castVote(uint256 proposalId, uint8 support)
        public
        virtual
        override
        returns (uint256)
    {
        address voter = _msgSender();
        return _castVote(proposalId, voter, support, "");
    }

    /**
     * @dev See {IGovernor-castVoteWithReason}.
     */
    function castVoteWithReason(
        uint256 proposalId,
        uint8 support,
        string calldata reason
    ) public virtual override returns (uint256) {
        address voter = _msgSender();
        return _castVote(proposalId, voter, support, reason);
    }

    /**
     * @dev See {IGovernor-castVoteBySig}.
     */
    function castVoteBySig(
        uint256 proposalId,
        uint8 support,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual override returns (uint256) {
        address voter = ECDSA.recover(
            _hashTypedDataV4(
                keccak256(abi.encode(BALLOT_TYPEHASH, proposalId, support))
            ),
            v,
            r,
            s
        );
        return _castVote(proposalId, voter, support, "");
    }

    /**
     * @dev Internal vote casting mechanism: Check that the vote is pending, that it has not been cast yet, retrieve
     * voting weight using {IGovernor-getVotes} and call the {_countVote} internal function.
     *
     * Emits a {IGovernor-VoteCast} event.
     */
    function _castVote(
        uint256 proposalId,
        address account,
        uint8 support,
        string memory reason
    ) internal virtual returns (uint256) {
        Proposal storage proposal = _proposals[proposalId];
        (bool member, ) = isMember(account);
        require(member, "GenArtGov: Caller not Gen.Art member");
        require(
            state(proposalId) == ProposalState.Active,
            "GenArtGov: vote not currently active"
        );

        uint256 weight = getVotes(account, proposal.voteStart.getDeadline());
        _countVote(proposalId, account, support, weight);

        emit VoteCast(account, proposalId, support, weight, reason);

        return weight;
    }

    /**
     * @dev Address through which the governor executes action. Will be overloaded by module that execute actions
     * through another contract such as a timelock.
     */
    function _executor() internal view virtual returns (address) {
        return address(_timelock);
    }

    /**
     * @dev Public accessor to check the address of the timelock
     */
    function timelock() public view virtual override returns (address) {
        return address(_timelock);
    }

    function proposalEta(uint256 proposalId)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return _proposals[proposalId].timer.getDeadline();
    }

    /**
     * @dev Public endpoint to update the underlying timelock instance. Restricted to the timelock itself, so updates
     * must be proposed, scheduled and executed using the {Governor} workflow.
     *
     * For security reason, the timelock must be handed over to another admin before setting up a new one. The two
     * operations (hand over the timelock) and do the update can be batched in a single proposal.
     *
     * Note that if the timelock admin has been handed over in a previous operation, we refuse updates made through the
     * timelock if admin of the timelock has already been accepted and the operation is executed outside the scope of
     * governance.
     */
    function updateTimelock(address newTimelock)
        external
        virtual
        onlyGovernance
    {
        _updateTimelock(newTimelock);
    }

    function _updateTimelock(address newTimelock) private {
        _timelock = ITimelock(payable(newTimelock));
        emit TimelockChange(address(_timelock), address(newTimelock));
    }

    function updateToken(address token_) external virtual onlyGovernance {
        _updateToken(token_);
    }

    function _updateToken(address token_) private {
        _token = IGenArtToken(token_);
    }

    /**
     * Read the voting weight from the token's built in snapshot mechanism (see {IGovernor-getVotes}).
     */
    function getVotes(address account, uint256 blockNumber)
        public
        view
        virtual
        override
        returns (uint256)
    {
        (bool member, bool goldMember) = isMember(account);
        if (!member) return 0;
        return
            _token.getPriorVotes(account, uint32(blockNumber)) *
            (goldMember ? 5 : 1);
    }

    /**
     * @dev See {IGovernor-hasVoted}.
     */
    function hasVoted(uint256 proposalId, address account)
        public
        view
        virtual
        override
        returns (bool)
    {
        return _proposals[proposalId].hasVoted[account];
    }

    /**
     * @dev Accessor to the internal vote counts.
     */
    function proposalVotes(uint256 proposalId)
        public
        view
        virtual
        returns (
            uint256 againstVotes,
            uint256 forVotes,
            uint256 abstainVotes
        )
    {
        Proposal storage proposalvote = _proposals[proposalId];
        return (
            proposalvote.againstVotes,
            proposalvote.forVotes,
            proposalvote.abstainVotes
        );
    }

    function isMember(address account)
        public
        view
        virtual
        returns (bool, bool)
    {
        uint256[] memory memeberships = _membership.getTokensByOwner(account);
        bool isGoldMember;
        for (uint256 i = 0; i < memeberships.length; i++) {
            isGoldMember = _membership.isGoldToken(memeberships[i]);
            if (isGoldMember) break;
        }

        return (memeberships.length > 0, isGoldMember);
    }
}
