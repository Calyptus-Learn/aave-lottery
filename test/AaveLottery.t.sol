// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {AaveLottery} from "../src/AaveLottery.sol";

// Aave Pool: 0x794a61358D6845594F94dc1DB02A252b5b4814aD
// DAI: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063

contract AaveLotteryTest is Test {
    AaveLottery public main;
    IERC20 public dai;

    Vm VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address AAVE_POOL_ADDRESS = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;

    address alice = address(1);
    address bob = address(2);
    address charlie = address(3);
    address eve = address(4);

    function setUp() public {
        dai = IERC20(0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063);
        main = new AaveLottery(
            3600, // 1h duration,
            address(dai),
            AAVE_POOL_ADDRESS // Polygon Aave Pool
        );
    }

    function testLotteryOnlyOne() public {
        uint256 currentId = main.currentId();
        AaveLottery.Round memory curr = main.getRound(currentId);

        uint256 userStake = 10e18;
        deal(address(dai), alice, userStake);

        // Enters
        assertEq(dai.balanceOf(alice), userStake);
        vm.startPrank(alice);
        dai.approve(address(main), userStake);
        main.enter(userStake);
        vm.stopPrank();
        assertEq(dai.balanceOf(alice), 0);

        // Round ends
        vm.warp(curr.endTime + 1);

        // Exit
        vm.prank(alice);
        main.exit(currentId);
        assertEq(dai.balanceOf(alice), userStake);

        // Claim prize
        vm.prank(alice);
        main.claim(currentId);
        assertTrue(dai.balanceOf(alice) >= userStake);
    }

    function testLotteryMultiple() public {
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;
        uint256[] memory usersStake = new uint256[](3);
        usersStake[0] = 10e18;
        usersStake[1] = 200e18;
        usersStake[2] = 30e18;

        uint256 currentId = main.currentId();
        AaveLottery.Round memory curr = main.getRound(currentId);

        // Users enter
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            deal(address(dai), users[i], usersStake[i]);
            dai.approve(address(main), usersStake[i]);
            main.enter(usersStake[i]);
            vm.stopPrank();
        }

        // Round ends
        vm.warp(curr.endTime + 1);

        // Eve enters into next Round
        vm.startPrank(eve);
        deal(address(dai), eve, 10e18);
        dai.approve(address(main), type(uint256).max);
        main.enter(10e18);
        vm.stopPrank();

        assertEq(main.currentId(), currentId + 1);

        // Search winner
        AaveLottery.Round memory ended = main.getRound(currentId);
        address winner;
        uint256 pointer = 0;
        for (uint256 i = 0; i < users.length; i++) {
            pointer += usersStake[i];
            if (ended.winnerTicket < pointer) {
                winner = users[i];
                break;
            }
        }

        // Claim prize
        uint256 balanceBefore = dai.balanceOf(winner);
        vm.prank(winner);
        main.claim(currentId);
        assertEq(dai.balanceOf(winner) - balanceBefore, ended.award);

        // Users exit
        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            main.exit(currentId);
            assertTrue(dai.balanceOf(users[i]) >= usersStake[i]);
        }
    }
}
