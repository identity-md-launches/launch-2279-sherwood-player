// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Quiver} from "../src/Quiver.sol";

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
}
