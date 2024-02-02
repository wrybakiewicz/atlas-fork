// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "forge-std/Test.sol";
import { BaseTest } from "./base/BaseTest.t.sol";
import { AtlasEvents } from "src/contracts/types/AtlasEvents.sol";
import { AtlasErrors } from "src/contracts/types/AtlasErrors.sol";

contract SurchargeTest is BaseTest {
    using stdStorage for StdStorage;

    function testSurchargeRecipient() public {
        // Check if the surcharge recipient is set to the correct address on deploy
        assertEq(atlas.surchargeRecipient(), payee, "surcharge recipient should be set to payee");
        assertEq(atlas.pendingSurchargeRecipient(), address(0), "pending surcharge recipient should be 0x0");
    
        // Check a random cant transfer the surcharge recipient
        vm.expectRevert(AtlasErrors.InvalidAccess.selector);
        atlas.transferSurchargeRecipient(address(this));

        // Check the transfer process works as expected
        vm.startPrank(atlas.surchargeRecipient());
        vm.expectEmit(true, true, true, true);
        emit AtlasEvents.SurchargeRecipientTransferStarted(payee, address(this));
        atlas.transferSurchargeRecipient(address(this));
        assertEq(atlas.surchargeRecipient(), payee, "recipient should not change until accepted by new address");
        assertEq(atlas.pendingSurchargeRecipient(), address(this), "pending surcharge recipient should now be address(this)");

        // Check that only correct recipient can accept the transfer
        vm.expectRevert(AtlasErrors.InvalidAccess.selector);
        atlas.becomeSurchargeRecipient();
        vm.stopPrank();

        // Check transfer acceptance works
        vm.expectEmit(true, true, true, true);
        emit AtlasEvents.SurchargeRecipientTransferred(address(this));
        atlas.becomeSurchargeRecipient();
        assertEq(atlas.surchargeRecipient(), address(this), "recipient should change to new address");
        assertEq(atlas.pendingSurchargeRecipient(), address(0), "pending surcharge recipient should now be 0x0");
    }

    function testSurchargeWithdraw() public {
        // Check a random cant withdraw
        vm.expectRevert(AtlasErrors.InvalidAccess.selector);
        atlas.withdrawSurcharge();

        // Set surcharge for withdrawal
        uint256 surchargeSlot = stdstore.target(address(atlas)).sig("surcharge()").find();
        vm.store(address(atlas), bytes32(surchargeSlot), bytes32(uint256(1 ether)));
        assertEq(atlas.surcharge(), 1 ether, "surcharge should be set to 1 ether");
        deal(address(atlas), 1 ether);

        // Test actual withdrawal
        vm.startPrank(payee);
        uint256 startingBalance = address(payee).balance;
        vm.expectEmit(true, true, true, true);
        emit AtlasEvents.SurchargeWithdrawn(payee, 1 ether);
        atlas.withdrawSurcharge();
        uint256 endingBalance = address(payee).balance;
        assertEq(endingBalance, startingBalance + 1 ether, "payee's balance should increase by 1 ether");
    }
}
