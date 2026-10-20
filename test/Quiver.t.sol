// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Quiver} from "../src/Quiver.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract QuiverTest is Test {
    Quiver token;

    function setUp() public {
        token = new Quiver();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "Sherwood Player");
        assertEq(token.symbol(), "QUIVER");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function testFuzz_transferAndAllowance(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 0, token.totalSupply());
        address holder = address(0xABCD);
        address spender = address(0xBEEF);
        token.transfer(holder, amount);
        assertEq(token.balanceOf(holder), amount);
        vm.prank(holder);
        token.approve(spender, amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, address(this), amount));
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_noMintOrAdmin() public {
        (bool minted,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        (bool owned,) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(minted);
        assertFalse(owned);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_zeroTransfersAndSelfTransfersCannotChangeSupplyOrBalances() public {
        uint256 supply = token.totalSupply();
        address receiver = makeAddr("receiver");
        assertTrue(token.transfer(receiver, 0));
        assertTrue(token.transfer(address(this), supply));
        assertEq(token.balanceOf(address(this)), supply);
        assertEq(token.balanceOf(receiver), 0);
        assertEq(token.totalSupply(), supply);
    }

    function test_transferAndApproveRejectZeroRecipients() public {
        uint256 supply = token.totalSupply();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        assertEq(token.balanceOf(address(this)), supply);
        assertEq(token.totalSupply(), supply);
    }

    function test_unapprovedCallerCannotMoveAnotherHoldersTokens() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, attacker, 0, 1));
        token.transferFrom(address(this), attacker, 1);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_balanceFailureDoesNotConsumeAllowance(uint96 raw) public {
        uint256 amount = bound(raw, 1, token.totalSupply() - 1);
        address holder = makeAddr("holder");
        address spender = makeAddr("spender");
        token.transfer(holder, amount);
        vm.prank(holder);
        token.approve(spender, amount + 1);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, amount, amount + 1)
        );
        token.transferFrom(holder, spender, amount + 1);
        assertEq(token.allowance(holder, spender), amount + 1);
        assertEq(token.balanceOf(holder), amount);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_infiniteApprovalAndFullSupplyRoundTrip() public {
        uint256 supply = token.totalSupply();
        address holder = makeAddr("full supply holder");
        address spender = makeAddr("infinite spender");
        token.transfer(holder, supply);
        vm.prank(holder);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(holder, address(this), supply);
        assertEq(token.allowance(holder, spender), type(uint256).max);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(address(this)), supply);
        assertEq(token.totalSupply(), supply);
    }
}
