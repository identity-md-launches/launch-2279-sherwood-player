// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Quiver} from "src/Quiver.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev A closed ledger of four actors. Ghost balances/approvals come from requested
/// operations, not from reading the token after a transfer.
contract QuiverHandler is Test {
    Quiver public immutable token;
    uint256 public immutable supply;
    address[4] public actors;
    uint256[4] public balances;
    uint256[4][4] public allowances;

    constructor(Quiver token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        supply = token_.totalSupply();
        balances[0] = supply;
    }

    function transfer(uint8 rawFrom, uint8 rawTo, uint96 rawAmount) external {
        uint256 from = uint256(rawFrom) % 4;
        uint256 to = uint256(rawTo) % 4;
        uint256 amount = bound(rawAmount, 0, balances[from]);
        vm.prank(actors[from]);
        assertTrue(token.transfer(actors[to], amount));
        balances[from] -= amount;
        balances[to] += amount;
    }

    function approve(uint8 rawOwner, uint8 rawSpender, uint96 rawAmount, bool infinite) external {
        uint256 owner = uint256(rawOwner) % 4;
        uint256 spender = uint256(rawSpender) % 4;
        uint256 amount = infinite ? type(uint256).max : bound(rawAmount, 0, supply);
        vm.prank(actors[owner]);
        assertTrue(token.approve(actors[spender], amount));
        allowances[owner][spender] = amount;
    }

    function spend(uint8 rawOwner, uint8 rawSpender, uint8 rawTo, uint96 rawAmount) external {
        uint256 owner = uint256(rawOwner) % 4;
        uint256 spender = uint256(rawSpender) % 4;
        uint256 to = uint256(rawTo) % 4;
        uint256 allowed = allowances[owner][spender];
        uint256 maximum = allowed < balances[owner] ? allowed : balances[owner];
        uint256 amount = bound(rawAmount, 0, maximum);
        vm.prank(actors[spender]);
        assertTrue(token.transferFrom(actors[owner], actors[to], amount));
        balances[owner] -= amount;
        balances[to] += amount;
        if (allowed != type(uint256).max) allowances[owner][spender] -= amount;
    }

    function overspend(uint8 rawFrom, uint8 rawTo) external {
        uint256 from = uint256(rawFrom) % 4;
        uint256 to = uint256(rawTo) % 4;
        uint256 amount = balances[from] + 1;
        vm.prank(actors[from]);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, actors[from], balances[from], amount)
        );
        token.transfer(actors[to], amount);
    }

    function exceedAllowance(uint8 rawOwner, uint8 rawSpender) external {
        uint256 owner = uint256(rawOwner) % 4;
        uint256 spender = uint256(rawSpender) % 4;
        // Revocation must take effect immediately, even after infinite approval.
        vm.prank(actors[owner]);
        token.approve(actors[spender], 0);
        allowances[owner][spender] = 0;
        vm.prank(actors[spender]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, actors[spender], 0, 1));
        token.transferFrom(actors[owner], actors[spender], 1);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract QuiverStatefulTest is Test {
    Quiver token;
    QuiverHandler handler;
    address[4] actors;

    function setUp() public {
        token = new Quiver();
        actors = [makeAddr("holder 0"), makeAddr("holder 1"), makeAddr("holder 2"), makeAddr("holder 3")];
        handler = new QuiverHandler(token, actors);
        token.transfer(actors[0], token.totalSupply());
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.spend.selector;
        selectors[3] = handler.overspend.selector;
        selectors[4] = handler.exceedAllowance.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_fixedSupplyMatchesEveryTrackedBalance() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.balances(i));
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, 1_000_000_000 ether);
        assertEq(token.totalSupply(), sum);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_allowancesFollowApprovalsSpendsAndRevocations() public view {
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), handler.allowances(i, j));
            }
        }
    }

    function test_handlerTransfersAndSpendsTheFullSupply() public {
        uint96 supply = uint96(token.totalSupply());
        handler.transfer(0, 1, supply);
        handler.approve(1, 2, supply, true);
        handler.spend(1, 2, 3, supply);
        handler.exceedAllowance(1, 2);
        handler.overspend(1, 3);
        invariant_fixedSupplyMatchesEveryTrackedBalance();
        invariant_allowancesFollowApprovalsSpendsAndRevocations();
        assertEq(token.balanceOf(actors[3]), supply);
    }
}
