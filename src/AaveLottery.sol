pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPool} from "@aave-v3-core/contracts/interfaces/IPool.sol";
import {IAToken} from "@aave-v3-core/contracts/interfaces/IAToken.sol";
import {DataTypes} from "@aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol";
import {WadRayMath} from "@aave-v3-core/contracts/protocol/libraries/math/WadRayMath.sol";

// deposit time: 1000 DAI -> 1000 aDAI (scaledBalance 990) ------ store 1000 DAI as principal
// time flies
// withdraw time: 1005 aDAI --> (990 scaledBalance * index = 1005 aDAI) -----
//                                      1000 DAI principal, 1005 aDAI - 1000 = 5 aDAI interest

contract AaveLottery {
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;

    struct Round {
        uint256 endTime;
        uint256 totalStake;
        uint256 award;
        uint256 winnerTicket;
        address winner;
        uint256 scaledBalanceStake;
    }

    struct Ticket {
        uint256 stake;
        uint256 segmentStart;
        bool exited;
    }

    uint256 public roundDuration; // seconds
    uint256 public currentId; // current round
    IERC20 public underlying; // asset

    IPool private aave;
    IAToken private aToken;

    // roundId => Round
    mapping(uint256 => Round) public rounds;

    // roundId => userAddress => Ticket
    mapping(uint256 => mapping(address => Ticket)) public tickets;

    constructor(
        uint256 _roundDuration,
        address _underlying,
        address _aavePool
    ) {
        roundDuration = _roundDuration;
        underlying = IERC20(_underlying);
        aave = IPool(_aavePool);
        DataTypes.ReserveData memory data = aave.getReserveData(_underlying);
        require(data.aTokenAddress != address(0), "ATOKEN_NOT_EXISTS");
        aToken = IAToken(data.aTokenAddress);

        underlying.approve(address(_aavePool), type(uint256).max);

        // Init first round
        rounds[currentId] = Round(
            block.timestamp + _roundDuration,
            0,
            0,
            0,
            address(0),
            0
        );
    }

    function getRound(uint256 roundId) external view returns (Round memory) {
        return rounds[roundId];
    }

    function getTicket(
        uint256 roundId,
        address user
    ) external view returns (Ticket memory) {
        return tickets[roundId][user];
    }

    function enter(uint256 amount) external {
        // Checks
        require(
            tickets[currentId][msg.sender].stake == 0,
            "USER_ALREADY_PARTICIPANT"
        );
        // Update
        _updateState();
        // User enters
        // [totalStake, totalStake + amount)
        tickets[currentId][msg.sender].segmentStart = rounds[currentId]
            .totalStake;
        tickets[currentId][msg.sender].stake = amount;
        rounds[currentId].totalStake += amount;
        // Transfer funds in - user must approve this contract
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        // Deposit funds into Aave Pool
        uint256 scaledBalanceStakeBefore = aToken.scaledBalanceOf(
            address(this)
        );
        aave.deposit(address(underlying), amount, address(this), 0);
        uint256 scaledBalanceStakeAfter = aToken.scaledBalanceOf(address(this));
        rounds[currentId].scaledBalanceStake +=
            scaledBalanceStakeAfter -
            scaledBalanceStakeBefore;
    }

    function exit(uint256 roundId) external {
        // Checks
        require(tickets[roundId][msg.sender].exited == false, "ALREADY_EXITED");
        // Update
        _updateState();
        require(roundId < currentId, "CURRENT_LOTTERY");
        // User exits
        uint256 amount = tickets[roundId][msg.sender].stake;
        tickets[roundId][msg.sender].exited = true;
        rounds[roundId].totalStake -= amount;
        // Transfer funds out
        underlying.safeTransfer(msg.sender, amount);
    }

    function claim(uint256 roundId) external {
        // Checks
        require(roundId < currentId, "CURRENT_LOTTERY");
        Ticket memory ticket = tickets[roundId][msg.sender];
        Round memory round = rounds[roundId];
        // Check winner
        // round.winnerTicket belongs to [ticket.segmentStart, ticket.segmentStart + ticket.stake)
        // <=>
        // ticket.segmentStart <= round.winnerTicket < ticket.segmentStart + ticket.stake
        // <=>
        // 0 <= round.winnerTicket - ticket.segmentStart < ticket.stake
        // <=>
        // round.winnerTicket - ticket.segmentStart < ticket.stake
        require(
            round.winnerTicket - ticket.segmentStart < ticket.stake,
            "NOT_WINNER"
        );
        require(round.winner == address(0), "ALREADY_CLAIMED");
        round.winner = msg.sender;
        // Transfer jackpot
        underlying.safeTransfer(msg.sender, round.award);
    }

    function _drawWinner(uint256 total) internal view returns (uint256) {
        uint256 random = uint256(
            keccak256(
                abi.encodePacked(
                    block.timestamp,
                    rounds[currentId].totalStake,
                    currentId
                )
            )
        ); // [0, 2^256 -1)
        return random % total; // [0, total)
    }

    // Alice 100 tokens -> [0, 99]
    // Bob 50 tokens -> [100, 149]
    // StakeSegment: [0, 99][100, 149]

    // Winner number is 80
    // Alice -> 80 is within [0, 99]

    // Winner number is 100
    // Bob -> 100 is within [100, 149]

    // Winner number cannot be > 149
    // total = totalStake

    function _updateState() internal {
        if (block.timestamp > rounds[currentId].endTime) {
            // award - aave withdraw
            // scaledBalance * index = total amount of aTokens
            uint256 index = aave.getReserveNormalizedIncome(
                address(underlying)
            );
            uint256 aTokenBalance = rounds[currentId].scaledBalanceStake.rayMul(
                index
            );
            uint256 aaveAmount = aave.withdraw(
                address(underlying),
                aTokenBalance,
                address(this)
            );
            // aaveAmount = principal + interest
            rounds[currentId].award = aaveAmount - rounds[currentId].totalStake;

            // Lottery draw
            rounds[currentId].winnerTicket = _drawWinner(
                rounds[currentId].totalStake
            );

            // create a new round
            currentId += 1;
            rounds[currentId].endTime = block.timestamp + roundDuration;
        }
    }
}
