// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { DAppControl } from "../../src/contracts/dapp/DAppControl.sol";

import "../../src/contracts/types/DAppApprovalTypes.sol";
import "../../src/contracts/types/UserCallTypes.sol";
import "../../src/contracts/types/SolverCallTypes.sol";

contract DummyDAppControl is DAppControl {
    constructor(
        address escrow,
        address governance
    )
        DAppControl(
            escrow,
            governance,
            CallConfig(
                false,
                false,
                false,
                false,
                false,
                false,
                false,
                false,
                false,
                false,
                false,
                false,
                false,
                false,
                false,
                false
            )
        )
    { }

    function _preOpsCall(UserOperation calldata) internal virtual override returns (bytes memory) { }
    function _allocateValueCall(address, uint256, bytes calldata) internal virtual override { }
    function getBidFormat(UserOperation calldata) public view virtual override returns (address) { }
    function getBidValue(SolverOperation calldata) public view virtual override returns (uint256) { }
}
